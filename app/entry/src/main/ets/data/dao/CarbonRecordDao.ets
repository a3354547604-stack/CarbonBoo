/**
 * CarbonRecordDao —— 碳记录表 `carbon_record` 的数据访问对象（19 张表里唯一写记录的表）。
 *
 * 职责：
 *  ① `insert` / `update`（同时 `bumpRevision`）/ `softDelete` / `getById`：记录行级读写；
 *  ② `listByRange` / `listByCategory` / `search` / `page`：查询；
 *  ③ `sumReduction` / `countTravel` / `sumRecycleKg` / `distinctDays`：供徽章与看板用的**聚合**。
 *
 * 铁律 4 与附录 B §1.3 铁约定：
 *  - 任何 `UPDATE` 必须同时改 `updated_at`，否则同步会漏；
 *  - 软删除 = `is_deleted = 1` + 更新 `updated_at`，**不物理删除**；
 *  - 聚合一律走 SQL `SUM()` / `COUNT()`，**禁止把行取回内存再浮点累加**（AGENTS.md §3）。
 *
 * 分层约定（AGENTS.md §7.1）：**Dao 不开事务**——事务边界在 Service 层
 * （见 `RdbHelper.runInTransaction`）。本文件的每个方法都是"一步写入"，可安全地
 * 被包在 Service 的事务里；需要跨表原子性时由 Service 负责。
 */
import { relationalStore } from '@kit.ArkData';
import { CarbonRecord, CategoryKey, Confidence, SyncState } from '../../model/CarbonTypes';
import { ResultSetMapper } from './ResultSetMapper';

/** 新建碳记录的入参（字段与建表 SQL 一一对应）。 */
export interface CarbonRecordInsert {
  id: string;
  userId: string;
  category: CategoryKey;
  subType: string;
  amount: number;
  unit: string;
  occurredAt: number;
  reductionKg: number;
  /** 铁律 3：因子快照四字段。 */
  factorValue: number;
  factorVersion: string;
  factorSource: string;
  confidence: Confidence;
  pointAwarded: number;
  pointCapped: number;
  isAbnormal: number;
  note?: string;
  deviceId?: string;
  syncState: SyncState;
  now: number;
}

const COLUMNS: string =
  'id, user_id, category, sub_type, amount, unit, occurred_at, reduction_kg, ' +
  'factor_value, factor_version, factor_source, confidence, point_awarded, point_capped, ' +
  'revision, is_abnormal, note, created_at, updated_at, is_deleted, device_id, sync_state';

export class CarbonRecordDao {
  private readonly store: relationalStore.RdbStore;

  /** @param store 已打开的 RdbStore（由 `RdbHelper` 提供） */
  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  /** 插入一条碳记录；`sync_state` 默认由 Service 传 `pending`（待同步）。 */
  async insert(row: CarbonRecordInsert): Promise<void> {
    const values: relationalStore.ValuesBucket = {
      id: row.id,
      user_id: row.userId,
      category: row.category,
      sub_type: row.subType,
      amount: row.amount,
      unit: row.unit,
      occurred_at: row.occurredAt,
      reduction_kg: row.reductionKg,
      factor_value: row.factorValue,
      factor_version: row.factorVersion,
      factor_source: row.factorSource,
      confidence: row.confidence,
      point_awarded: row.pointAwarded,
      point_capped: row.pointCapped,
      revision: 0,
      is_abnormal: row.isAbnormal,
      note: row.note === undefined ? null : row.note,
      created_at: row.now,
      updated_at: row.now,
      is_deleted: 0,
      device_id: row.deviceId === undefined ? null : row.deviceId,
      sync_state: row.syncState,
    };
    // 账本表幂等：跨设备重复拉取同一 rowId 时忽略，靠业务唯一键去重（附录 B §2 / B5）。
    await this.store.insert('carbon_record', values, relationalStore.ConflictResolution.ON_CONFLICT_IGNORE);
  }

  /** 按主键取一条（未删除的）。 */
  async getById(id: string): Promise<CarbonRecord | undefined> {
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT ${COLUMNS} FROM carbon_record WHERE id = ? AND is_deleted = 0`,
      [id]
    );
    try {
      return rs.goToNextRow() ? CarbonRecordDao.map(rs) : undefined;
    } finally {
      rs.close();
    }
  }

  /** 时间区间查询（`fromMs` ≤ `occurred_at` < `toMs`），按发生时间倒序。 */
  async listByRange(userId: string, fromMs: number, toMs: number): Promise<CarbonRecord[]> {
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT ${COLUMNS} FROM carbon_record
       WHERE user_id = ? AND occurred_at >= ? AND occurred_at < ? AND is_deleted = 0
       ORDER BY occurred_at DESC`,
      [userId, fromMs, toMs]
    );
    return CarbonRecordDao.drain(rs);
  }

  /** 按行为大类查询。 */
  async listByCategory(userId: string, category: CategoryKey, limit: number): Promise<CarbonRecord[]> {
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT ${COLUMNS} FROM carbon_record
       WHERE user_id = ? AND category = ? AND is_deleted = 0
       ORDER BY occurred_at DESC LIMIT ?`,
      [userId, category, limit]
    );
    return CarbonRecordDao.drain(rs);
  }

  /** 备注模糊搜索。 */
  async search(userId: string, keyword: string, limit: number): Promise<CarbonRecord[]> {
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT ${COLUMNS} FROM carbon_record
       WHERE user_id = ? AND note LIKE ? AND is_deleted = 0
       ORDER BY occurred_at DESC LIMIT ?`,
      [userId, `%${keyword}%`, limit]
    );
    return CarbonRecordDao.drain(rs);
  }

  /** 分页（页码从 0 开始）。 */
  async page(userId: string, offset: number, size: number): Promise<CarbonRecord[]> {
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT ${COLUMNS} FROM carbon_record
       WHERE user_id = ? AND is_deleted = 0
       ORDER BY occurred_at DESC LIMIT ? OFFSET ?`,
      [userId, size, offset]
    );
    return CarbonRecordDao.drain(rs);
  }

  /**
   * 编辑一条记录：整体重算后的减排量与积分由 Service 传入，
   * **同时 `revision = revision + 1`**（记录类流水幂等键 = `<id>#<revision>`，见附录 B §2/B3）。
   * @param id 记录主键
   * @param reductionKg 重算后的减排量
   * @param amount 重算后的活动量
   * @param pointAwarded 本次实入
   * @param pointCapped 本次是否被削减
   * @param now 当前时间戳（必须用于 `updated_at`）
   */
  async update(
    id: string,
    amount: number,
    reductionKg: number,
    pointAwarded: number,
    pointCapped: number,
    now: number
  ): Promise<void> {
    await this.store.executeSql(
      `UPDATE carbon_record
          SET amount = ?, reduction_kg = ?, point_awarded = ?, point_capped = ?,
              revision = revision + 1, updated_at = ?, sync_state = 'pending'
        WHERE id = ?`,
      [amount, reductionKg, pointAwarded, pointCapped, now, id]
    );
  }

  /** 软删除（必须同时改 `updated_at`，否则删除无法传播给其他设备）。 */
  async softDelete(id: string, now: number): Promise<void> {
    await this.store.executeSql(
      `UPDATE carbon_record SET is_deleted = 1, updated_at = ?, sync_state = 'pending' WHERE id = ?`,
      [now, id]
    );
  }

  /** 累计减排量（徽章 `total_reduction` 用）。 */
  async sumReduction(userId: string): Promise<number> {
    return this.scalar(
      `SELECT COALESCE(SUM(reduction_kg), 0) FROM carbon_record WHERE user_id = ? AND is_deleted = 0`,
      [userId]
    );
  }

  /** 出行类记录条数（徽章 `travel_count` 用）。 */
  async countTravel(userId: string): Promise<number> {
    return this.scalar(
      `SELECT COUNT(*) FROM carbon_record WHERE user_id = ? AND category = 'travel' AND is_deleted = 0`,
      [userId]
    );
  }

  /** 回收类累计重量 kg（徽章 `recycle_kg` 用）。 */
  async sumRecycleKg(userId: string): Promise<number> {
    return this.scalar(
      `SELECT COALESCE(SUM(amount), 0) FROM carbon_record WHERE user_id = ? AND category = 'recycle' AND is_deleted = 0`,
      [userId]
    );
  }

  /** 有记录的自然日数（徽章 `streak` 与目标 `distinct_days` 用）。 */
  async distinctDays(userId: string): Promise<number> {
    return this.scalar(
      `SELECT COUNT(DISTINCT STRFTIME('%Y-%m-%d', occurred_at / 1000, 'unixepoch', 'localtime'))
         FROM carbon_record WHERE user_id = ? AND is_deleted = 0`,
      [userId]
    );
  }

  /** 单值聚合（SUM / COUNT 一律走 SQL，禁止取回内存浮点累加）。 */
  private async scalar(sql: string, args: relationalStore.ValueType[]): Promise<number> {
    const rs: relationalStore.ResultSet = await this.store.querySql(sql, args);
    try {
      if (!rs.goToNextRow()) {
        return 0;
      }
      const v: relationalStore.ValueType = ResultSetMapper.columnValue(rs, rs.getColumnNames()[0]);
      if (typeof v === 'number') {
        return v;
      }
      if (typeof v === 'bigint') {
        return Number(v);
      }
      return 0;
    } finally {
      rs.close();
    }
  }

  /** 结果集 → 模型数组。 */
  private static drain(rs: relationalStore.ResultSet): CarbonRecord[] {
    const out: CarbonRecord[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push(CarbonRecordDao.map(rs));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 逐列映射（列名与附录 B §2 建表 SQL 严格一致）。 */
  private static map(rs: relationalStore.ResultSet): CarbonRecord {
    const category: string = ResultSetMapper.text(rs, 'category');
    const confidence: string = ResultSetMapper.text(rs, 'confidence');
    const syncState: string = ResultSetMapper.text(rs, 'sync_state');
    return {
      id: ResultSetMapper.text(rs, 'id'),
      userId: ResultSetMapper.text(rs, 'user_id'),
      category: CarbonRecordDao.toCategory(category),
      subType: ResultSetMapper.text(rs, 'sub_type'),
      amount: ResultSetMapper.number(rs, 'amount'),
      unit: ResultSetMapper.text(rs, 'unit'),
      occurredAt: ResultSetMapper.number(rs, 'occurred_at'),
      reductionKg: ResultSetMapper.number(rs, 'reduction_kg'),
      factorValue: ResultSetMapper.number(rs, 'factor_value'),
      factorVersion: ResultSetMapper.text(rs, 'factor_version'),
      factorSource: ResultSetMapper.text(rs, 'factor_source'),
      confidence: CarbonRecordDao.toConfidence(confidence),
      pointAwarded: ResultSetMapper.number(rs, 'point_awarded'),
      revision: ResultSetMapper.number(rs, 'revision'),
      pointCapped: ResultSetMapper.number(rs, 'point_capped'),
      isAbnormal: ResultSetMapper.number(rs, 'is_abnormal'),
      note: ResultSetMapper.optText(rs, 'note'),
      createdAt: ResultSetMapper.number(rs, 'created_at'),
      updatedAt: ResultSetMapper.number(rs, 'updated_at'),
      isDeleted: ResultSetMapper.number(rs, 'is_deleted'),
      deviceId: ResultSetMapper.optText(rs, 'device_id'),
      syncState: CarbonRecordDao.toSyncState(syncState),
    };
  }

  /**
   * 数据库里的枚举文本 → `CategoryKey`。
   * 刻意写成显式分支（而不是断言）：万一有人往库里写了非法枚举，
   * 这里会立刻抛错指出具体值，而不是把脏值伪装成合法类型往下传。
   */
  static toCategory(v: string): CategoryKey {
    if (v === 'travel' || v === 'utility' || v === 'recycle' || v === 'plate') {
      return v;
    }
    throw new Error(`carbon_record.category 非法枚举值：${v}`);
  }

  /** `verified` | `provisional` → `Confidence`。 */
  static toConfidence(v: string): Confidence {
    if (v === 'verified' || v === 'provisional') {
      return v;
    }
    throw new Error(`carbon_record.confidence 非法枚举值：${v}`);
  }

  /** `local` | `synced` | `pending` → `SyncState`。 */
  static toSyncState(v: string): SyncState {
    if (v === 'local' || v === 'synced' || v === 'pending') {
      return v;
    }
    throw new Error(`carbon_record.sync_state 非法枚举值：${v}`);
  }
}
