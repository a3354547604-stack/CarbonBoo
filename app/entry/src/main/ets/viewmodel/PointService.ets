/**
 * PointService —— 积分的**唯一写入与查询出口**（铁律 4：流水只增不删、余额可追溯）。
 *
 * 职责：
 *  ① 余额口径：`余额 = 收入合计 − 支出合计`（`point_record` 聚合，不缓存、不估算）；
 *  ② 今日已得记录分 D（封顶计算的输入）：只数 `source_type = 'carbon_record'` 的当日净额
 *     ——「删记录即释放额度」（B1/B2 修复后的口径）；
 *  ③ 幂等写入：`INSERT OR IGNORE` + 业务唯一键 `uq_pr_source(source_type, source_id, flow_kind)`，
 *     同一 `<记录ID>#<revision>` 只会有一条 primary，重复保存不会重复发分；
 *  ④ 冲正：删/改记录时写一条 `flow_kind = 'reverse'` 的负流水，**不改历史行**；
 *  ⑤ `point_daily_stat` 缓存（验收 D3-5：可重建且与流水聚合逐日一致）——
 *     增量写入与重建**共用同一条聚合 SQL**，一致性由此在构造上成立。
 *
 * 为什么余额不用 `point_daily_stat` 求和：缓存是派生物，重建窗口内可能短暂滞后；
 * 余额是用户最信任的数字，必须每次从流水现算（附录 C §16 规则 4）。
 */
import { PointBalance, PointRecord, PointSourceType, PointType } from '../model/PointTypes';
import { StorePort, firstOf, numOf, textOf } from './store/StorePort';
import { RowMapper } from './store/RowMapper';
import { AppConstants } from '../util/AppConstants';
import { DateUtil } from '../util/DateUtil';
import { IdUtil } from './domain/IdUtil';
import { AppState } from './AppState';

/** 追加一条流水所需的最小信息。 */
export interface PointAppendInput {
  type: PointType;
  /** 正 = 收入，负 = 支出。 */
  points: number;
  sourceType: PointSourceType;
  /** 业务幂等键（记录类 `<id>#<rev>`；目标类 `<goalId>:<periodKey>`）。 */
  sourceId: string;
  title: string;
  remark?: string;
  occurredAt: number;
}

/** 流水筛选（积分明细页三个 chip）。 */
export type PointFlowFilter = 'all' | 'income' | 'spend';

/** 每日缓存行。 */
export interface DailyStatRow {
  dayKey: string;
  recordPoints: number;
  goalPoints: number;
  spentPoints: number;
  recordCount: number;
}

export class PointService {
  private readonly store: StorePort;
  private readonly state: AppState;

  constructor(store: StorePort, state: AppState) {
    this.store = store;
    this.state = state;
  }

  /** 余额与今日数字（附录 C §16 顶部）。 */
  async balance(userId: string, now: number): Promise<PointBalance> {
    const rows = await this.store.query(
      'SELECT COALESCE(SUM(CASE WHEN points > 0 THEN points ELSE 0 END), 0) AS inc, ' +
      'COALESCE(SUM(CASE WHEN points < 0 THEN -points ELSE 0 END), 0) AS spent, ' +
      'COALESCE(SUM(points), 0) AS bal FROM point_record WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    const row = firstOf(rows);
    const income: number = row === undefined ? 0 : numOf(row, 'inc');
    const spent: number = row === undefined ? 0 : numOf(row, 'spent');
    const balance: number = row === undefined ? 0 : numOf(row, 'bal');
    const today: number = await this.todayRecordPoint(userId, now);
    const todayEarned: number = await this.todayEarned(userId, now);
    return {
      balance,
      totalIncome: income,
      totalSpent: spent,
      todayEarned,
      todayRecordPoint: today,
      cap: AppConstants.DAILY_RECORD_CAP,
      carbonCoin: Math.floor(balance / AppConstants.CARBON_COIN_RATE),
    };
  }

  /**
   * 今日记录类**净额**（= 已得 D；含冲正，删除记录即释放额度）。
   * 负数按 0 处理：冲正只可能把当日额度退回，不会变成负额度。
   */
  async todayRecordPoint(userId: string, now: number): Promise<number> {
    const from: number = DateUtil.addDays(now, 0);
    const to: number = DateUtil.addDays(from, 1);
    const rows = await this.store.query(
      'SELECT COALESCE(SUM(points), 0) AS v FROM point_record ' +
      "WHERE user_id = ? AND is_deleted = 0 AND source_type = 'carbon_record' " +
      'AND occurred_at >= ? AND occurred_at < ?',
      [userId, from, to]
    );
    const row = firstOf(rows);
    const v: number = row === undefined ? 0 : numOf(row, 'v');
    return v > 0 ? v : 0;
  }

  /** 今日总实得（记录分 + 目标分，可为负则按 0）——首页「今日记录 3 条 · +286 分」用。 */
  async todayEarned(userId: string, now: number): Promise<number> {
    const from: number = DateUtil.addDays(now, 0);
    const to: number = DateUtil.addDays(from, 1);
    const rows = await this.store.query(
      'SELECT COALESCE(SUM(points), 0) AS v FROM point_record ' +
      'WHERE user_id = ? AND is_deleted = 0 AND occurred_at >= ? AND occurred_at < ?',
      [userId, from, to]
    );
    const row = firstOf(rows);
    return row === undefined ? 0 : numOf(row, 'v');
  }

  /**
   * 追加流水（幂等）。返回新建流水 id；若幂等键已存在则返回空串（表示未重复入账）。
   * @param userId 用户
   * @param input 流水信息
   */
  async append(userId: string, input: PointAppendInput): Promise<string> {
    const id: string = this.newId();
    const now: number = Date.now();
    await this.store.exec(
      'INSERT OR IGNORE INTO point_record ' +
      '(id, user_id, type, flow_kind, points, source_type, source_id, title, remark, occurred_at, created_at, updated_at, is_deleted, device_id, sync_state) ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)',
      [
        id, userId, input.type, input.type === 'reverse' ? 'reverse' : 'primary', input.points,
        input.sourceType, input.sourceId, input.title,
        input.remark === undefined ? null : input.remark,
        input.occurredAt, now, now, this.deviceOf(), this.syncOf(),
      ]
    );
    // 回读幂等键：**键必须与 uq_pr_source 的键完全一致**（含 user_id）。
    // t9 缺陷 B：唯一键已改为 (user_id, source_type, source_id, flow_kind)，
    // 而 `source_id` 本身不含账号维度 —— 少了 user_id 就可能命中**别的账号**的同名键
    // （典型：两天/两账号同名目标 'S1:D:2026-11-06'），把"确实写入成功"误判成"重复、未入账"。
    // 对齐索引键之后，"被 IGNORE 的行必是本账号的同一业务事实"才是自洽的。
    const flowKind: string = input.type === 'reverse' ? 'reverse' : 'primary';
    const exists = await this.store.query(
      'SELECT id FROM point_record WHERE user_id = ? AND source_type = ? AND source_id = ? AND flow_kind = ?',
      [userId, input.sourceType, input.sourceId, flowKind]);
    const row = firstOf(exists);
    const actualId: string = row === undefined ? '' : textOf(row, 'id');
    if (actualId === id) {
      await this.rebuildDay(userId, DateUtil.dayKeyOfMs(input.occurredAt));
      return id;
    }
    return '';
  }

  /**
   * 冲正一条原始流水（写负额 `reverse` 行；原始行一条不改）。
   * @param userId 用户
   * @param type 原流水类型
   * @param points 原流水积分（正数表示需要退回的额度）
   * @param sourceId 原幂等键
   * @param title 原标题
   * @param occurredAt 原发生时间（冲正落在同一天，额度当即可用）
   */
  async reverse(userId: string, type: PointType, points: number, sourceId: string, title: string, occurredAt: number): Promise<void> {
    if (points === 0) {
      return;
    }
    await this.append(userId, {
      type: 'reverse',
      points: -points,
      sourceType: type === 'goal' ? 'goal' : this.sourceOf(type),
      sourceId,
      title: `${title}（冲正）`,
      remark: '记录删除释放当日额度',
      occurredAt,
    });
  }

  /** 分页流水（积分明细页）。 */
  async page(userId: string, flow: PointFlowFilter, offset: number, size: number): Promise<PointRecord[]> {
    const cond: string = flow === 'income' ? ' AND points > 0' : (flow === 'spend' ? ' AND points < 0' : '');
    const rows = await this.store.query(
      `SELECT * FROM point_record WHERE user_id = ? AND is_deleted = 0${cond} ORDER BY occurred_at DESC, created_at DESC LIMIT ? OFFSET ?`,
      [userId, size, offset]
    );
    return RowMapper.pointRecords(rows);
  }

  /** 流水总数（分页器用）。 */
  async count(userId: string, flow: PointFlowFilter): Promise<number> {
    const cond: string = flow === 'income' ? ' AND points > 0' : (flow === 'spend' ? ' AND points < 0' : '');
    const rows = await this.store.query(`SELECT COUNT(*) AS n FROM point_record WHERE user_id = ? AND is_deleted = 0${cond}`, [userId]);
    const row = firstOf(rows);
    return row === undefined ? 0 : numOf(row, 'n');
  }

  /** 全部流水（CSV 导出用，按时间升序）。 */
  async all(userId: string): Promise<PointRecord[]> {
    const rows = await this.store.query(
      'SELECT * FROM point_record WHERE user_id = ? AND is_deleted = 0 ORDER BY occurred_at ASC, created_at ASC',
      [userId]
    );
    return RowMapper.pointRecords(rows);
  }

  /** 按来源累计（碳普惠「累计兑换」等）。 */
  async sumBySource(userId: string, sourceType: PointSourceType): Promise<number> {
    const rows = await this.store.query(
      'SELECT COALESCE(SUM(points), 0) AS v FROM point_record WHERE user_id = ? AND is_deleted = 0 AND source_type = ?',
      [userId, sourceType]
    );
    const row = firstOf(rows);
    return row === undefined ? 0 : numOf(row, 'v');
  }

  /** 单日缓存行（无记录返回 0 行）。 */
  async dailyStat(userId: string, dayKey: string): Promise<DailyStatRow | undefined> {
    const rows = await this.store.query(
      'SELECT day_key, record_points, goal_points, spent_points, record_count FROM point_daily_stat WHERE user_id = ? AND day_key = ?',
      [userId, dayKey]
    );
    const row = firstOf(rows);
    if (row === undefined) {
      return undefined;
    }
    return {
      dayKey: textOf(row, 'day_key'),
      recordPoints: numOf(row, 'record_points'),
      goalPoints: numOf(row, 'goal_points'),
      spentPoints: numOf(row, 'spent_points'),
      recordCount: numOf(row, 'record_count'),
    };
  }

  /**
   * 重建某一日的缓存（增量写入路径也走它，保证与重建口径**同一条 SQL**）。
   * @param userId 用户
   * @param dayKey `YYYY-MM-DD`
   */
  async rebuildDay(userId: string, dayKey: string): Promise<void> {
    const now: number = Date.now();
    await this.store.exec('DELETE FROM point_daily_stat WHERE user_id = ? AND day_key = ?', [userId, dayKey]);
    await this.store.exec(
      `${PointService.AGGREGATE_SQL} HAVING day_key = ?`,
      [userId, now, userId, dayKey]
    );
  }

  /**
   * 重建全部缓存（验收 D3-5：`PointService.rebuildDailyStat(userId)`）。
   * @param userId 用户
   * @returns 重建后的行数
   */
  async rebuildDailyStat(userId: string, now: number): Promise<number> {
    await this.store.exec('DELETE FROM point_daily_stat WHERE user_id = ?', [userId]);
    await this.store.exec(PointService.AGGREGATE_SQL, [userId, now, userId]);
    const rows = await this.store.query('SELECT COUNT(*) AS n FROM point_daily_stat WHERE user_id = ?', [userId]);
    const row = firstOf(rows);
    return row === undefined ? 0 : numOf(row, 'n');
  }

  /**
   * 缓存聚合的唯一口径（增量与重建共用）。
   *
   * 口径（与 `point_record` 一一对应）：
   *  - `record_points`：`source_type='carbon_record'` 的净额（record + record_capped + reverse）；
   *  - `goal_points`：`type='goal'`；
   *  - `spent_points`：其余支出（碳小铺购买、碳普惠兑换），**正数存储**；
   *  - `record_count`：记录类笔数（冲正减 1，与「记录数」可加和）。
   * 参数顺序：`[user_id(插入), updated_at, user_id(过滤)]`。
   */
  private static readonly AGGREGATE_SQL: string =
    'INSERT INTO point_daily_stat (user_id, day_key, record_points, goal_points, spent_points, record_count, rebuilt_at, updated_at) ' +
    "SELECT user_id, date(occurred_at / 1000, 'unixepoch', 'localtime') AS day_key, " +
    "  COALESCE(SUM(CASE WHEN source_type = 'carbon_record' THEN points ELSE 0 END), 0), " +
    "  COALESCE(SUM(CASE WHEN type = 'goal' THEN points ELSE 0 END), 0), " +
    "  COALESCE(SUM(CASE WHEN points < 0 AND source_type <> 'carbon_record' AND type <> 'goal' THEN -points ELSE 0 END), 0), " +
    "  COALESCE(SUM(CASE WHEN source_type = 'carbon_record' AND (type = 'record' OR type = 'record_capped') THEN 1 " +
    "                    WHEN source_type = 'carbon_record' AND type = 'reverse' THEN -1 ELSE 0 END), 0), " +
    '  NULL, ? ' +
    'FROM point_record WHERE user_id = ? AND is_deleted = 0 GROUP BY day_key';

  /** 流水主键（客户端生成 UUID）。 */
  private newId(): string {
    return IdUtil.uuid();
  }

  private sourceOf(type: PointType): PointSourceType {
    if (type === 'purchase') {
      return 'shop_item';
    }
    if (type === 'carbon_include') {
      return 'carbon_include';
    }
    return 'carbon_record';
  }

  private deviceOf(): string {
    return this.state.deviceId();
  }

  private syncOf(): string {
    return this.state.syncState();
  }
}
