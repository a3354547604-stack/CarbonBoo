/**
 * PeriodWindow —— 目标周期与看板周期的**窗口口径**（纯函数，无 IO）。
 *
 * 职责：把「周期类型 + 基准时刻」算成 `[startMs, endMs)` 窗口与周期键，
 * 供目标进度（附录 C §13）、看板聚合（§6）共用；`hundred_days` 以注册日为起点。
 *
 * 依据：附录 B §8.1 的 period_key 生成规则（day/week/month/quarter/year/hundred_days）；
 * 周一律按**自然周、周一 00:00 起算**（附录 C §13 规则 3）。
 */
import { DateUtil } from '../../util/DateUtil';
import { GoalPeriod } from '../../model/GoalTypes';

/** 一个周期窗口。 */
export interface PeriodSpan {
  /** 周期键（`D:` / `W:` / `M:` / `Q:` / `Y:` / `L:` 前缀）。 */
  key: string;
  /** 起始（含）。 */
  startMs: number;
  /** 结束（不含）。 */
  endMs: number;
  /** 展示标签，如 `每日` / `本周` / `本月` / `2026-Q4`。 */
  label: string;
}

export class PeriodWindow {
  /**
   * 当前周期窗口。
   * @param period 周期
   * @param ts 基准时刻
   * @param registerDayMs 注册日（仅 `hundred_days` 用；缺省取 `ts`）
   */
  static of(period: GoalPeriod, ts: number, registerDayMs?: number): PeriodSpan {
    if (period === 'day') {
      return PeriodWindow.daySpan(ts);
    }
    if (period === 'week') {
      return PeriodWindow.weekSpan(ts);
    }
    if (period === 'month') {
      return PeriodWindow.monthSpan(ts);
    }
    if (period === 'quarter') {
      return PeriodWindow.quarterSpan(ts);
    }
    if (period === 'year') {
      return PeriodWindow.yearSpan(ts);
    }
    return PeriodWindow.hundredDaySpan(registerDayMs === undefined ? ts : registerDayMs);
  }

  /** 周期中文名（目标卡片上的「每日 / 本周 / 本月 / 本季 / 今年」）。 */
  static labelOf(period: GoalPeriod): string {
    if (period === 'day') {
      return '每日';
    }
    if (period === 'week') {
      return '本周';
    }
    if (period === 'month') {
      return '本月';
    }
    if (period === 'quarter') {
      return '本季';
    }
    if (period === 'year') {
      return '今年';
    }
    return '百天计划';
  }

  /** 剩余时间文案（未达成时显示；已达成不显示）。 */
  static remainingLabel(endMs: number, now: number): string {
    const days: number = DateUtil.diffDays(endMs, now);
    if (days <= 0) {
      return '今天截止';
    }
    return `剩余 ${days} 天`;
  }

  static daySpan(ts: number): PeriodSpan {
    const start: number = DateUtil.addDays(ts, 0);
    return {
      key: DateUtil.periodKeyOf(ts, 'day'),
      startMs: start,
      endMs: DateUtil.addDays(start, 1),
      label: '每日',
    };
  }

  static weekSpan(ts: number): PeriodSpan {
    const d: Date = new Date(DateUtil.addDays(ts, 0));
    const isoDow: number = d.getDay() === 0 ? 7 : d.getDay();
    const start: number = DateUtil.addDays(d.getTime(), -(isoDow - 1));
    return {
      key: DateUtil.periodKeyOf(ts, 'week'),
      startMs: start,
      endMs: DateUtil.addDays(start, 7),
      label: '本周',
    };
  }

  static monthSpan(ts: number): PeriodSpan {
    const d: Date = new Date(DateUtil.addDays(ts, 0));
    const start: Date = new Date(d.getFullYear(), d.getMonth(), 1, 0, 0, 0, 0);
    const end: Date = new Date(d.getFullYear(), d.getMonth() + 1, 1, 0, 0, 0, 0);
    return {
      key: DateUtil.periodKeyOf(ts, 'month'),
      startMs: start.getTime(),
      endMs: end.getTime(),
      label: '本月',
    };
  }

  static quarterSpan(ts: number): PeriodSpan {
    const d: Date = new Date(DateUtil.addDays(ts, 0));
    const q: number = Math.floor(d.getMonth() / 3);
    const start: Date = new Date(d.getFullYear(), q * 3, 1, 0, 0, 0, 0);
    const end: Date = new Date(d.getFullYear(), q * 3 + 3, 1, 0, 0, 0, 0);
    return {
      key: DateUtil.periodKeyOf(ts, 'quarter'),
      startMs: start.getTime(),
      endMs: end.getTime(),
      label: '本季',
    };
  }

  static yearSpan(ts: number): PeriodSpan {
    const d: Date = new Date(DateUtil.addDays(ts, 0));
    const start: Date = new Date(d.getFullYear(), 0, 1, 0, 0, 0, 0);
    const end: Date = new Date(d.getFullYear() + 1, 0, 1, 0, 0, 0, 0);
    return {
      key: DateUtil.periodKeyOf(ts, 'year'),
      startMs: start.getTime(),
      endMs: end.getTime(),
      label: '今年',
    };
  }

  /** 种树百天计划：注册日起 100 个自然日。 */
  static hundredDaySpan(registerDayMs: number): PeriodSpan {
    const start: number = DateUtil.addDays(registerDayMs, 0);
    return {
      key: DateUtil.periodKeyOf(registerDayMs, 'hundred_days'),
      startMs: start,
      endMs: DateUtil.addDays(start, 100),
      label: '百天计划',
    };
  }
}
