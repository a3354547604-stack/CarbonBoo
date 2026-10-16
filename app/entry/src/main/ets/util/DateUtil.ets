/**
 * DateUtil —— 时间与日期维度格式化（AGENTS.md §7.1：统一走 DateUtil，别处不写格式化代码）。
 *
 * 职责：
 *  ① `dayKeyOf` / `dayKeyOfMs`：毫秒时间戳 → `YYYY-MM-DD`（本地时区，日粒度）；
 *  ② `periodKeyOf`：毫秒时间戳 + 目标周期 → 目标幂等键 `period_key`；
 *  ③ `addDays` / `diffDays`：按自然日加减与天数差（连续记录、百天窗口都要用）。
 *
 * 依据：附录 B §8.1 表下注的 `period_key` 生成规则：
 *   day → `D:YYYY-MM-DD`；week → `W:YYYY-Www`（**ISO 周，周一 00:00 起**）；
 *   month → `M:YYYY-MM`；quarter → `Q:YYYY-Qn`；year → `Y:YYYY`；
 *   hundred_days → `L:YYYY-MM-DD`（注册日，窗口 = 注册日起 100 天）。
 * 铁律：所有入库时间戳**一律毫秒整数**，禁止字符串日期入库（附录 B §1.3 铁约定 1）。
 * 本文件不 import 任何 ArkTS 运行时 API，可被离线脚本复算。
 */
import { GoalPeriod } from '../model/GoalTypes';

const MS_PER_DAY: number = 86400000;

export class DateUtil {
  /** 毫秒/秒自适应：把秒级时间戳也当毫秒处理会错 1000 倍，故取阈值 1e12。 */
  private static normalize(ts: number): number {
    return ts < 1000000000000 ? ts * 1000 : ts;
  }

  /** `YYYY-MM-DD`（本地时区）。 */
  static dayKeyOfMs(ts: number): string {
    const d: Date = new Date(DateUtil.normalize(ts));
    return DateUtil.formatYmd(DateUtil.year(d), DateUtil.month(d), DateUtil.day(d));
  }

  /** 当天 `YYYY-MM-DD`。 */
  static todayKey(now: number): string {
    return DateUtil.dayKeyOfMs(now);
  }

  /** 补齐 2 位。 */
  private static pad2(v: number): string {
    return v < 10 ? `0${v}` : `${v}`;
  }

  private static formatYmd(y: number, m: number, d: number): string {
    return `${y}-${DateUtil.pad2(m)}-${DateUtil.pad2(d)}`;
  }

  private static year(d: Date): number {
    return d.getFullYear();
  }

  private static month(d: Date): number {
    return d.getMonth() + 1;
  }

  private static day(d: Date): number {
    return d.getDate();
  }

  /** 目标周期键：`D:` / `W:` / `M:` / `Q:` / `Y:` / `L:` 前缀 + 周期体。 */
  static periodKeyOf(ts: number, period: GoalPeriod): string {
    const d: Date = new Date(DateUtil.normalize(ts));
    if (period === 'day') {
      return `D:${DateUtil.dayKeyOfMs(ts)}`;
    }
    if (period === 'week') {
      return `W:${DateUtil.isoYear(d)}-W${DateUtil.pad2(DateUtil.isoWeek(d))}`;
    }
    if (period === 'month') {
      return `M:${DateUtil.year(d)}-${DateUtil.pad2(DateUtil.month(d))}`;
    }
    if (period === 'quarter') {
      return `Q:${DateUtil.year(d)}-Q${Math.floor((DateUtil.month(d) - 1) / 3) + 1}`;
    }
    if (period === 'year') {
      return `Y:${DateUtil.year(d)}`;
    }
    // hundred_days：起点是注册日，调用方应传注册日时间戳（本函数对传入值取当天的日期体）
    return `L:${DateUtil.dayKeyOfMs(ts)}`;
  }

  /**
   * ISO-8601 周数（周一为一周首日，周四所属年即为 ISO 年）。
   * 标准算法：把日期归一到「当周周四」，用它在年内的天数算周序号。
   */
  static isoWeek(d: Date): number {
    const t: Date = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    // getDay(): 0=周日 … 6=周六 → 转成 ISO 的 1=周一 … 7=周日
    const isoDow: number = t.getDay() === 0 ? 7 : t.getDay();
    // 挪到本周周四（ISO 周以周四定归属年）
    t.setDate(t.getDate() + (4 - isoDow));
    const yearStart: Date = new Date(t.getFullYear(), 0, 1);
    const dayOfYear: number = Math.floor((t.getTime() - yearStart.getTime()) / MS_PER_DAY) + 1;
    return Math.floor((dayOfYear - 1) / 7) + 1;
  }

  /** ISO 周所属年份（跨年周要用周四所在的年）。 */
  static isoYear(d: Date): number {
    const t: Date = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    const isoDow: number = t.getDay() === 0 ? 7 : t.getDay();
    t.setDate(t.getDate() + (4 - isoDow));
    return t.getFullYear();
  }

  /**
   * 按自然日加减（**先归一到当日 00:00 再加减**，避免夏令时/时分秒漂移）。
   * @param ts 基准时间戳（毫秒）
   * @param days 正数向后、负数向前
   */
  static addDays(ts: number, days: number): number {
    const d: Date = new Date(DateUtil.normalize(ts));
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() + days);
    return d.getTime();
  }

  /** 自然日天数差（`a - b`，按当地 00:00 归一后计算，结果可能为负）。 */
  static diffDays(a: number, b: number): number {
    const da: Date = new Date(DateUtil.normalize(a));
    da.setHours(0, 0, 0, 0);
    const db: Date = new Date(DateUtil.normalize(b));
    db.setHours(0, 0, 0, 0);
    return Math.round((da.getTime() - db.getTime()) / MS_PER_DAY);
  }
}
