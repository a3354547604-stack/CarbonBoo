/**
 * RdbStore —— `StorePort` 的**本机 relationalStore 实现**（19 张表都由它落库）。
 *
 * 职责：
 *  ① 用 `RdbHelper.get().store()` 拿到已打开的 `RdbStore`，把端口四方法翻译成
 *     `querySql` / `executeSql` / `runInTransaction`；
 *  ② 把 `ResultSet` 逐行转成 `RowShape`（一次 `getRow()` 拿到原生类型的 ValuesBucket，
 *     避免"整数被读成字符串"这类静默类型事故）；
 *  ③ 统一 `rowCount` / `close()` 的释放，异常路径也不漏关结果集。
 *
 * 铁律 1：本机库是唯一真相源；本文件只做搬运，不做任何业务判定。
 * 为什么写语句一律走 `executeSql` 而不是 `insert/update(RdbPredicates)`：
 *  - `INSERT OR IGNORE` / `INSERT OR REPLACE` 是**幂等键**（uq_pr_source、uq_ug、uq_ub、
 *    uq_up、uq_ua、uq_sp、uq_uprofile）落地的方式，用原生 SQL 才能把这些约束语义写清；
 *  - UPDATE 需要 `revision = revision + 1` 这类自增表达式，ValuesBucket 表达不了。
 */
import { fileIo } from '@kit.CoreFileKit';
import { relationalStore } from '@kit.ArkData';
import { RdbHelper } from '../../data/dao/RdbHelper';
import { RowShape, SqlValue, StorePort, bindArgs } from './StorePort';

export class RdbStore implements StorePort {
  /** relationalStore 的落盘目录（`context.databaseDir + '/rdb'`），只用于统计体积。 */
  private readonly dbDir: string;

  constructor(dbDir: string) {
    this.dbDir = dbDir;
  }

  /** 数据库文件总字节数（开发者选项 P10）；目录不可读时返回 0。 */
  async sizeBytes(): Promise<number> {
    if (this.dbDir.length === 0) {
      return 0;
    }
    let total: number = 0;
    try {
      const names: string[] = fileIo.listFileSync(this.dbDir);
      let i: number = 0;
      while (i < names.length) {
        const full: string = `${this.dbDir}/${names[i]}`;
        if (fileIo.accessSync(full)) {
          total = total + fileIo.statSync(full).size;
        }
        i = i + 1;
      }
    } catch (e) {
      return 0;
    }
    return total;
  }

  async query(sql: string, args?: SqlValue[]): Promise<RowShape[]> {
    const store: relationalStore.RdbStore = RdbHelper.get().store();
    const rs: relationalStore.ResultSet = await store.querySql(sql, bindArgs(args));
    try {
      return RdbStore.mapRows(rs);
    } finally {
      rs.close();
    }
  }

  async exec(sql: string, args?: SqlValue[]): Promise<void> {
    const store: relationalStore.RdbStore = RdbHelper.get().store();
    await store.executeSql(sql, bindArgs(args));
  }

  async execBatch(sqls: string[]): Promise<void> {
    const store: relationalStore.RdbStore = RdbHelper.get().store();
    let i: number = 0;
    while (i < sqls.length) {
      await store.executeSql(sqls[i]);
      i = i + 1;
    }
  }

  async transaction<T>(work: () => Promise<T>): Promise<T> {
    return RdbHelper.get().runInTransaction<T>(work);
  }

  /** `ResultSet` → 行数组（当前游标之后的所有行）。 */
  private static mapRows(rs: relationalStore.ResultSet): RowShape[] {
    const rows: RowShape[] = [];
    while (rs.goToNextRow()) {
      rows.push(RdbStore.mapRow(rs));
    }
    return rows;
  }

  /** 当前行 → `RowShape`：只保留 number / string / boolean 三类，其余记为 NULL。 */
  private static mapRow(rs: relationalStore.ResultSet): RowShape {
    const bucket: relationalStore.ValuesBucket = rs.getRow();
    const keys: string[] = Object.keys(bucket);
    const row: RowShape = {};
    let i: number = 0;
    while (i < keys.length) {
      const key: string = keys[i];
      const value: relationalStore.ValueType = bucket[key];
      if (typeof value === 'number' || typeof value === 'string') {
        row[key] = value;
      } else if (typeof value === 'boolean') {
        row[key] = value ? 1 : 0;
      } else {
        row[key] = null;
      }
      i = i + 1;
    }
    return row;
  }
}
