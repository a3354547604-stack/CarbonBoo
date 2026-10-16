/**
 * BadgeEngine —— 8 枚徽章的进度与解锁判定（纯函数核，**不发积分**）。
 *
 * 职责：
 *  ① `statsOf(...)`：把原始计数整理成判定用的 `BadgeStats`（含连续天数 streak）；
 *  ② `evaluate(defs, stats, unlockedIds)`：返回**本次新解锁**的徽章定义
 *     —— 已解锁的永不再返回（幂等，附录 D「徽章幂等」）；
 *  ③ `progressRows(...)`：徽章墙展示行——未解锁也必须给进度与条件（附录 C §14 规则）。
 *
 * 口径：徽章是纯荣誉体系，不发放积分、不可消费；解锁后永久保留，删除记录不撤销
 *（`user_badge.unlocked = 1` 之后不再回落）。
 */
import { BadgeDef, BadgeProgress, BadgeMetric } from '../../model/BadgeTypes';
import { DateUtil } from '../../util/DateUtil';

/** 徽章判定所需的统计量。 */
export interface BadgeStats {
  /** 是否已有至少 1 条记录。 */
  hasRecord: boolean;
  /** 连续记录天数（含今天或昨天为终点）。 */
  streak: number;
  /** 累计减排量 kgCO₂e。 */
  totalReduction: number;
  /** 出行类记录条数。 */
  travelCount: number;
  /** 回收类累计 kg。 */
  recycleKg: number;
  /** 已拥有的头像框数（集齐 8 个解锁「种树人」）。 */
  frameCount: number;
}

export class BadgeEngine {
  /** 空统计（新装用户）。 */
  static emptyStats(): BadgeStats {
    return { hasRecord: false, streak: 0, totalReduction: 0, travelCount: 0, recycleKg: 0, frameCount: 0 };
  }

  /**
   * 连续记录天数：给定「有记录的日期集合」与当前时刻，从今天（或昨天）往回数。
   * 为什么允许从昨天起算：今天还没记录不代表中断（否则每天早上进度都归零）。
   * @param dayKeys 有记录的日期（`YYYY-MM-DD`）
   * @param now 当前时刻
   */
  static streakOf(dayKeys: string[], now: number): number {
    if (dayKeys.length === 0) {
      return 0;
    }
    let cursor: number = DateUtil.addDays(now, 0);
    if (dayKeys.indexOf(DateUtil.dayKeyOfMs(cursor)) < 0) {
      cursor = DateUtil.addDays(cursor, -1);
      if (dayKeys.indexOf(DateUtil.dayKeyOfMs(cursor)) < 0) {
        return 0;
      }
    }
    let n: number = 0;
    while (dayKeys.indexOf(DateUtil.dayKeyOfMs(cursor)) >= 0) {
      n = n + 1;
      cursor = DateUtil.addDays(cursor, -1);
    }
    return n;
  }

  /** 指标当前值。 */
  static valueOf(metric: BadgeMetric, stats: BadgeStats): number {
    if (metric === 'first_record') {
      return stats.hasRecord ? 1 : 0;
    }
    if (metric === 'streak') {
      return stats.streak;
    }
    if (metric === 'total_reduction') {
      return stats.totalReduction;
    }
    if (metric === 'travel_count') {
      return stats.travelCount;
    }
    if (metric === 'recycle_kg') {
      return stats.recycleKg;
    }
    return stats.frameCount;
  }

  /**
   * 本次新解锁的徽章（已解锁的不会再次返回）。
   * @param defs 徽章定义（按 order）
   * @param stats 统计量
   * @param unlockedIds 已解锁徽章 id
   */
  static evaluate(defs: BadgeDef[], stats: BadgeStats, unlockedIds: string[]): BadgeDef[] {
    const out: BadgeDef[] = [];
    let i: number = 0;
    while (i < defs.length) {
      const def: BadgeDef = defs[i];
      if (unlockedIds.indexOf(def.id) < 0 && BadgeEngine.valueOf(def.metric, stats) >= def.threshold) {
        out.push(def);
      }
      i = i + 1;
    }
    return out;
  }

  /**
   * 徽章墙展示行。
   * @param defs 徽章定义
   * @param stats 统计量
   * @param unlockedIds 已解锁徽章 id
   * @param unlockedAtMap 徽章 id → 解锁时间
   */
  static progressRows(
    defs: BadgeDef[],
    stats: BadgeStats,
    unlockedIds: string[],
    unlockedAtMap: Map<string, number>
  ): BadgeProgress[] {
    const out: BadgeProgress[] = [];
    let i: number = 0;
    while (i < defs.length) {
      const def: BadgeDef = defs[i];
      const value: number = BadgeEngine.valueOf(def.metric, stats);
      const unlocked: boolean = unlockedIds.indexOf(def.id) >= 0;
      const row: BadgeProgress = {
        badgeId: def.id,
        name: def.name,
        description: def.description,
        icon: def.icon,
        unlocked,
        progress: value,
        threshold: def.threshold,
        percent: def.threshold <= 0 ? 0 : Math.min(100, Math.round((value / def.threshold) * 100)),
      };
      const at: number | undefined = unlockedAtMap.get(def.id);
      if (at !== undefined) {
        row.unlockedAt = at;
      }
      out.push(row);
      i = i + 1;
    }
    return out;
  }

  /** 徽章条件文案（未解锁时展示，如「累计 100 kg」「集齐 8 头像框」）。 */
  static conditionOf(def: BadgeDef): string {
    if (def.metric === 'first_record') {
      return '完成第 1 条记录';
    }
    if (def.metric === 'streak') {
      return `连续 ${def.threshold} 天记录`;
    }
    if (def.metric === 'total_reduction') {
      return `累计 ${def.threshold} kgCO₂e`;
    }
    if (def.metric === 'travel_count') {
      return `出行记录 ${def.threshold} 条`;
    }
    if (def.metric === 'recycle_kg') {
      return `回收 ${def.threshold} kg`;
    }
    return `集齐 ${def.threshold} 个头像框`;
  }
}
