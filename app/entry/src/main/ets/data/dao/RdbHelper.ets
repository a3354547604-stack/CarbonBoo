/**
 * RdbHelper —— 本机 `relationalStore` 的**唯一**打开/建表/事务入口。
 *
 * 职责：
 *  ① 单例持有 `RdbStore`：`open(context)` 幂等打开 `carbonboo.db`（S1 安全级）；
 *  ② 首次打开时逐条执行 `ClientSchema.DDL` 建 19 张表与索引，并写入 `schema_version`；
 *  ③ 提供 `store()` 给 Dao 使用，`close()` 供 Ability 销毁时释放；
 *  ④ 提供 `runInTransaction(work)` —— **事务边界的唯一实现点**。
 *
 * 铁律 1：本机 `relationalStore` 是唯一真相源；云端与分布式只做搬运，不参与业务计算。
 * 分层约定（AGENTS.md §7.1）：**事务边界在 Service 层**，不在 Dao、更不在页面层。
 *   因此本文件只**暴露**事务能力，不自行发起事务；Service 通过 `runInTransaction`
 *   把「碳记录 + 积分流水 + 目标 + 徽章」这类多表写入包成一次原子提交。
 *
 * 迁移（附录 B §9）：`schemaVersion` 存 `app_config['schema_version']`；升版只加表/加列。
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ClientSchema } from '../schema/ClientSchema';
import { AppConstants } from '../../util/AppConstants';

/** 建表结果的对账信息，供启动自检与测试断言使用。 */
export class SchemaReport {
  /** 实际已建的表（按 `ClientSchema.TABLES` 顺序对账）。 */
  readonly tables: string[];
  /** 期望的表数（19）。 */
  readonly expected: number;
  /** DDL 执行条数（建表 + 建索引）。 */
  readonly statements: number;

  constructor(tables: string[], expected: number, statements: number) {
    this.tables = tables;
    this.expected = expected;
    this.statements = statements;
  }

  /** 19 张表是否齐全。 */
  isComplete(): boolean {
    return this.tables.length === this.expected;
  }
}

export class RdbHelper {
  private static instance: RdbHelper | undefined = undefined;
  private rdb: relationalStore.RdbStore | undefined = undefined;
  private opening: Promise<relationalStore.RdbStore> | undefined = undefined;

  /** 单例获取。 */
  static get(): RdbHelper {
    if (RdbHelper.instance === undefined) {
      RdbHelper.instance = new RdbHelper();
    }
    return RdbHelper.instance;
  }

  /** 是否已打开。 */
  isOpen(): boolean {
    return this.rdb !== undefined;
  }

  /**
   * 打开数据库（幂等）：已打开直接返回；正在打开则复用同一个 Promise，避免并发重复建库。
   * @param context Ability 的 context（`UIAbilityContext` 或 `ApplicationContext`）
   */
  async open(context: common.Context): Promise<relationalStore.RdbStore> {
    if (this.rdb !== undefined) {
      return this.rdb;
    }
    if (this.opening !== undefined) {
      return this.opening;
    }
    this.opening = this.doOpen(context);
    try {
      const store: relationalStore.RdbStore = await this.opening;
      this.rdb = store;
      return store;
    } finally {
      this.opening = undefined;
    }
  }

  private async doOpen(context: common.Context): Promise<relationalStore.RdbStore> {
    const config: relationalStore.StoreConfig = {
      name: AppConstants.DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    await RdbHelper.applySchema(store);
    return store;
  }

  /**
   * 建 19 张表与索引，并写入 `schema_version`。
   * 独立为静态方法：离线单测可直接对已打开的 store 调用，不必走单例。
   * @param store 已打开的 RdbStore
   */
  static async applySchema(store: relationalStore.RdbStore): Promise<SchemaReport> {
    const statements: string[] = ClientSchema.DDL;
    let i: number = 0;
    while (i < statements.length) {
      await store.executeSql(statements[i]);
      i = i + 1;
    }
    // 索引口径迁移（t9）：旧版本建的是 uq_pr_source(source_type, source_id, flow_kind)，
    // 而 `CREATE UNIQUE INDEX IF NOT EXISTS` **不会**替换已存在的同名索引 ——
    // 于是"覆盖安装"的机器会继续用旧索引，缺陷在新老机器上表现不一致。
    // 这里显式判断：若现存 uq_pr_source 不含 user_id，则删掉重建为含 user_id 的形态。
    await RdbHelper.migrateUqPrSource(store);
    const now: number = Date.now();
    // schema 版本只写一次：已存在就不覆盖（升版逻辑在后续切片按 §9 实现）。
    const existing: relationalStore.ResultSet = await store.querySql(
      'SELECT value FROM app_config WHERE id = ?',
      [AppConstants.CONFIG_KEY_SCHEMA_VERSION]
    );
    let hasVersion: boolean = false;
    try {
      hasVersion = existing.rowCount > 0;
    } finally {
      existing.close();
    }
    if (!hasVersion) {
      const row: relationalStore.ValuesBucket = {
        id: AppConstants.CONFIG_KEY_SCHEMA_VERSION,
        value: `${AppConstants.DB_VERSION}`,
        version: null,
        fetched_at: null,
        created_at: now,
        updated_at: now,
      };
      await store.insert('app_config', row, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    }
    const tables: string[] = await RdbHelper.listTables(store);
    return new SchemaReport(tables, ClientSchema.TABLES.length, statements.length);
  }

  /** 读 `sqlite_master` 列出全部业务表（排除 SQLite 内部表）。 */
  static async listTables(store: relationalStore.RdbStore): Promise<string[]> {
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name`
    );
    const out: string[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push(rs.getString(0));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /**
   * 幂等迁移：把 `uq_pr_source` 统一成**含 `user_id`** 的口径（t9 / 缺陷 B）。
   *
   * 为什么不能只靠 `ClientSchema.DDL` 里的 `CREATE UNIQUE INDEX IF NOT EXISTS`：
   * 该语句对**已存在**的同名索引是空操作，所以老库升级后仍会保留旧口径
   * （`source_type, source_id, flow_kind`），导致"新装机器正常、覆盖安装丢积分"这种
   * 最难查的不一致。这里对照 `PRAGMA index_info` 的真实列序判断，必要时 DROP 后重建。
   *
   * 幂等性：索引不存在 → 什么都不做（交给 DDL 建）；已含 `user_id` → 什么都不做；
   * 仅"存在且不含 user_id"这一种情况才 DROP + CREATE。
   * @param store 已打开的 RdbStore
   * @returns 是否真的做过迁移（供启动日志/用例断言）
   */
  static async migrateUqPrSource(store: relationalStore.RdbStore): Promise<boolean> {
    const rs: relationalStore.ResultSet = await store.querySql(`PRAGMA index_info('uq_pr_source')`);
    const columns: string[] = [];
    try {
      while (rs.goToNextRow()) {
        // index_info 的列序：seqno(0) / cid(1) / name(2)
        columns.push(rs.getString(2));
      }
    } finally {
      rs.close();
    }
    if (columns.length === 0) {
      return false;
    }
    let hasUser: boolean = false;
    let i: number = 0;
    while (i < columns.length) {
      if (columns[i] === 'user_id') {
        hasUser = true;
      }
      i = i + 1;
    }
    if (hasUser) {
      return false;
    }
    await store.executeSql('DROP INDEX IF EXISTS uq_pr_source');
    await store.executeSql(
      'CREATE UNIQUE INDEX IF NOT EXISTS uq_pr_source ON point_record(user_id, source_type, source_id, flow_kind)'
    );
    return true;
  }

  /** 取已打开的 store；未打开时抛错（调用方必须先 `open`）。 */
  store(): relationalStore.RdbStore {
    if (this.rdb === undefined) {
      throw new Error('RdbHelper 尚未 open()；请在 Ability 启动或测试 setUp 中先打开数据库');
    }
    return this.rdb;
  }

  /**
   * 在**一个事务**里执行多表写入（事务边界的唯一实现点）。
   *
   * 语义：`work` 内任意一步抛错 → 整体 `rollBack`，已写入的行全部撤销；
   * 全部成功才 `commit`。这保证「碳记录 + 积分流水 + 目标结算 + 徽章解锁」
   * 要么全落库、要么全不落库，不会出现"记录存了但积分没发"的半成品。
   * @param work 事务体内要做的写入
   */
  async runInTransaction<T>(work: () => Promise<T>): Promise<T> {
    const store: relationalStore.RdbStore = this.store();
    store.beginTransaction();
    try {
      const result: T = await work();
      store.commit();
      return result;
    } catch (e) {
      store.rollBack();
      // ArkTS 不允许 `throw` 任意类型的值（`arkts-limited-throw`），
      // 必须重新包成 `Error` 再抛；原始信息用 `String(e)` 保留，不做静默吞掉。
      throw new Error(`事务已回滚，原因：${String(e)}`);
    }
  }

  /** 关闭数据库并清空单例状态（Ability `onDestroy` 调用）。 */
  async close(): Promise<void> {
    if (this.rdb === undefined) {
      return;
    }
    const store: relationalStore.RdbStore = this.rdb;
    this.rdb = undefined;
    await store.close();
  }
}
