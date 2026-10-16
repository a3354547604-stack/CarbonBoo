/**
 * StatsService —— 跨页共用的**统计口径**（首页总览 / 看板 / 徽章判定 / 分享卡片 / CSV）。
 *
 * 职责：把「累计减排、记录数、出行条数、回收公斤数、有记录的天、连续天数、头像框数、
 * 已解锁徽章数、等量换算」这些数字**只算一次**，页面都从这里取。
 *
 * 为什么要独立成一层：同一个「累计减排」出现在首页、我的、看板、分享卡片、summary.csv
 * 五处（验收 A3/A10/A11 都要求它们一致）。多处各写一条 SUM 是分叉的开始。
 *
 * 精度：金额类一律 SQL 聚合（禁止浮点累加，AGENTS §3），只在末尾按 4 位小数收口。
 */
import { CarbonRecord, CategoryKey } from '../model/CarbonTypes';
import { BadgeEngine, BadgeStats } from './domain/BadgeEngine';
import { StorePort, firstOf, numOf, textOf } from './store/StorePort';
import { RowMapper } from './store/RowMapper';
import { PointService } from './PointService';
import { LiteralConstants } from '../util/AppTheme';
import { DateUtil } from '../util/DateUtil';

/** 首页 / 我的页共用的总览数字。 */
export interface OverviewStats {
  /** 累计减排 kgCO₂e（4 位小数）。 */
  totalReduction: number;
  recordCount: number;
  balance: number;
  totalIncome: number;
  carbonCoin: number;
  todayCount: number;
  todayReduction: number;
  todayEarned: number;
  travelCount: number;
  recycleKg: number;
  streak: number;
  frameCount: number;
  badgeUnlocked: number;
  badgeTotal: number;
  /** 等量换算：≈ 多少棵树一年的吸收量。 */
  treeEquivalent: number;
  /** 等量换算：≈ 少开多少公里车。 */
  carKmEquivalent: number;
  hasRecord: boolean;
}

export class StatsService {
  private readonly store: StorePort;
  private readonly points: PointService;

  constructor(store: StorePort, points: PointService) {
    this.store = store;
    this.points = points;
  }

  /**
   * 总览（一次查询拿全，避免首页发 8 条 SQL）。
   * @param userId 用户
   * @param now 当前时刻
   */
  async overview(userId: string, now: number): Promise<OverviewStats> {
    const agg = await this.store.query(
      'SELECT COUNT(*) AS n, COALESCE(SUM(reduction_kg), 0) AS red, ' +
      "COALESCE(SUM(CASE WHEN category = 'travel' THEN 1 ELSE 0 END), 0) AS travel, " +
      "COALESCE(SUM(CASE WHEN category = 'recycle' THEN amount ELSE 0 END), 0) AS recycle " +
      'FROM carbon_record WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    const row = firstOf(agg);
    const count: number = row === undefined ? 0 : numOf(row, 'n');
    const total: number = row === undefined ? 0 : numOf(row, 'red');
    const todayFrom: number = DateUtil.addDays(now, 0);
    const todayTo: number = DateUtil.addDays(todayFrom, 1);
    const today = await this.store.query(
      'SELECT COUNT(*) AS n, COALESCE(SUM(reduction_kg), 0) AS red FROM carbon_record ' +
      'WHERE user_id = ? AND is_deleted = 0 AND occurred_at >= ? AND occurred_at < ?',
      [userId, todayFrom, todayTo]
    );
    const tRow = firstOf(today);
    const balance = await this.points.balance(userId, now);
    const dayKeys: string[] = await this.dayKeysOf(userId);
    const frames = await this.store.query(
      "SELECT COUNT(*) AS n FROM user_purchase p JOIN shop_item s ON s.id = p.item_id " +
      "WHERE p.user_id = ? AND p.is_deleted = 0 AND s.section = 'frame'",
      [userId]
    );
    const fRow = firstOf(frames);
    const badges = await this.store.query('SELECT COUNT(*) AS n FROM user_badge WHERE user_id = ? AND is_deleted = 0 AND unlocked = 1', [userId]);
    const bRow = firstOf(badges);
    const totalBadges = await this.store.query('SELECT COUNT(*) AS n FROM badge_def', []);
    const tbRow = firstOf(totalBadges);
    return {
      totalReduction: StatsService.round4(total),
      recordCount: count,
      balance: balance.balance,
      totalIncome: balance.totalIncome,
      carbonCoin: balance.carbonCoin,
      todayCount: tRow === undefined ? 0 : numOf(tRow, 'n'),
      todayReduction: tRow === undefined ? 0 : StatsService.round4(numOf(tRow, 'red')),
      todayEarned: balance.todayEarned,
      travelCount: row === undefined ? 0 : numOf(row, 'travel'),
      recycleKg: row === undefined ? 0 : StatsService.round4(numOf(row, 'recycle')),
      streak: BadgeEngine.streakOf(dayKeys, now),
      frameCount: fRow === undefined ? 0 : numOf(fRow, 'n'),
      badgeUnlocked: bRow === undefined ? 0 : numOf(bRow, 'n'),
      badgeTotal: tbRow === undefined ? 0 : numOf(tbRow, 'n'),
      treeEquivalent: StatsService.round4(total / LiteralConstants.TREE_ABSORB_KG_PER_YEAR),
      carKmEquivalent: StatsService.round4(total * LiteralConstants.CAR_KM_PER_KG),
      hasRecord: count > 0,
    };
  }

  /** 徽章判定统计量（`BadgeEngine.evaluate` 的输入）。 */
  async badgeStats(userId: string, now: number): Promise<BadgeStats> {
    const o: OverviewStats = await this.overview(userId, now);
    return {
      hasRecord: o.hasRecord,
      streak: o.streak,
      totalReduction: o.totalReduction,
      travelCount: o.travelCount,
      recycleKg: o.recycleKg,
      frameCount: o.frameCount,
    };
  }

  /** 有记录的日期集合（`YYYY-MM-DD`，升序）。 */
  async dayKeysOf(userId: string): Promise<string[]> {
    const rows = await this.store.query(
      "SELECT DISTINCT date(occurred_at / 1000, 'unixepoch', 'localtime') AS d " +
      'FROM carbon_record WHERE user_id = ? AND is_deleted = 0 ORDER BY d ASC',
      [userId]
    );
    const out: string[] = [];
    let i: number = 0;
    while (i < rows.length) {
      const d: string = textOf(rows[i], 'd');
      if (d.length > 0) {
        out.push(d);
      }
      i = i + 1;
    }
    return out;
  }

  /** 时间区间内的记录（看板 / 目标进度 / 分享卡片共用）。 */
  async recordsInRange(userId: string, fromMs: number, toMs: number): Promise<CarbonRecord[]> {
    const rows = await this.store.query(
      'SELECT * FROM carbon_record WHERE user_id = ? AND is_deleted = 0 AND occurred_at >= ? AND occurred_at < ? ' +
      'ORDER BY occurred_at ASC',
      [userId, fromMs, toMs]
    );
    return RowMapper.carbonRecords(rows);
  }

  /** 全部记录（看板 / CSV 用；本机账本量级（千条内）一次读入是可接受的）。 */
  async allRecords(userId: string): Promise<CarbonRecord[]> {
    const rows = await this.store.query(
      'SELECT * FROM carbon_record WHERE user_id = ? AND is_deleted = 0 ORDER BY occurred_at DESC',
      [userId]
    );
    return RowMapper.carbonRecords(rows);
  }

  /** 最近 n 条（首页 / 记录页首页）。 */
  async recentRecords(userId: string, limit: number): Promise<CarbonRecord[]> {
    const rows = await this.store.query(
      'SELECT * FROM carbon_record WHERE user_id = ? AND is_deleted = 0 ORDER BY occurred_at DESC LIMIT ?',
      [userId, limit]
    );
    return RowMapper.carbonRecords(rows);
  }

  /** 某个分类最近 n 条（记录页分类 chip）。 */
  async recordsOfCategory(userId: string, category: CategoryKey, limit: number): Promise<CarbonRecord[]> {
    const rows = await this.store.query(
      'SELECT * FROM carbon_record WHERE user_id = ? AND is_deleted = 0 AND category = ? ORDER BY occurred_at DESC LIMIT ?',
      [userId, category, limit]
    );
    return RowMapper.carbonRecords(rows);
  }

  /** 记录总数（分页器）。 */
  async countRecords(userId: string, category: CategoryKey | 'all'): Promise<number> {
    const cond: string = category === 'all' ? '' : ' AND category = ?';
    const args: (string | number | null)[] = category === 'all' ? [userId] : [userId, category];
    const rows = await this.store.query(`SELECT COUNT(*) AS n FROM carbon_record WHERE user_id = ? AND is_deleted = 0${cond}`, args);
    const row = firstOf(rows);
    return row === undefined ? 0 : numOf(row, 'n');
  }

  /** 累计减排（分享卡片 / 我的页）。 */
  async totalReduction(userId: string): Promise<number> {
    const rows = await this.store.query(
      'SELECT COALESCE(SUM(reduction_kg), 0) AS red FROM carbon_record WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    const row = firstOf(rows);
    return row === undefined ? 0 : StatsService.round4(numOf(row, 'red'));
  }

  private static round4(v: number): number {
    return Math.round(v * 10000) / 10000;
  }
}
