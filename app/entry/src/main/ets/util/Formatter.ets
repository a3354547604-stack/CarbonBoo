/**
 * Formatter —— 全应用**唯一**的数字与时间格式化入口（附录 C §3.4）。
 *
 * 职责：
 *  ① `number(value, kind)`：减排量（固定 4 位小数）/ 积分（整数 + 千分位）/
 *     碳币（整数）/ 因子值（固定 4 位小数）四种口径；
 *  ② `pointsSigned(n)`：流水用 `+96` / `−1,500`（正加号、负用 U+2212）；
 *  ③ `dateTime(ms)` / `timeOfDay(ms)`：`YYYY-MM-DD HH:mm` 与 `HH:mm`；
 *  ④ `fileSize(bytes)`：备份与数据库体积（`128 KB` / `1.4 MB`）；
 *  ⑤ `dayGroupLabel(ms, now)`：记录页分组标题「今天 / 昨天 / MM月DD日」。
 *
 * 为什么不各页自己 `toFixed()`：附录 C §3.4 明确「页面禁止自行 toFixed()」——
 * 四处口径不一致（3 位/4 位、有无千分位）是这类账本应用最常见的显示事故。
 * 本文件**不 import 任何 ArkTS 运行时 API**（只用 `DateUtil` 与 `DecimalUtil`），
 * 因此可被离线脚本（esbuild + Node）直接复算。
 */
import { Dec } from './DecimalUtil';
import { DateUtil } from './DateUtil';

/** 数字口径（附录 C §3.4 表）。 */
export type NumberKind = 'reduction' | 'factor' | 'points' | 'coin' | 'amount' | 'progress';

/** 千分位分隔符。 */
const THOUSAND: string = ',';
/** Unicode U+2212 MINUS SIGN（与附录 C 线框里的 `−1,500` 一致）。 */
const MINUS: string = '\u2212';

export class Formatter {
  /**
   * 按口径格式化数字。
   * @param value 原值
   * @param kind 口径
   */
  static number(value: number, kind: NumberKind): string {
    if (kind === 'reduction') {
      // 附录 A §4 / PLAN §10.4：存 4 位、展示 2 位；小于 1 kg 时展示 3 位（避免 0.01 这种把差别抹平）
      return Math.abs(value) < 1 ? Dec.from(value).toFixed(3) : Dec.from(value).toFixed(2);
    }
    if (kind === 'factor') {
      // 因子值可能很小（水 0.000168），保留 6 位有效小数再裁掉末尾 0
      return Formatter.trimZeros(value, 6);
    }
    if (kind === 'amount') {
      // 活动量：条/次/天 这类计数显示整数，km/L/kWh/kg 最多 2 位
      return Formatter.trimZeros(value, 2);
    }
    if (kind === 'progress') {
      // 目标与徽章进度：同上，不做四位小数
      return Formatter.trimZeros(value, 2);
    }
    const int: number = Math.round(value);
    if (kind === 'coin') {
      return `${int}`;
    }
    return Formatter.thousands(int);
  }

  /** 固定 2 位小数的减排量口径（CSV / 报表等需要固定位宽时用）。 */
  static reductionFixed(kg: number): string {
    return Dec.from(kg).toFixed(2);
  }

  /** 活动量文本（`80 L` / `1.5 km` / `2 次`）。 */
  static amount(v: number): string {
    return Formatter.number(v, 'amount');
  }

  /** 目标/徽章进度文本（`1/1` / `0.26/5` / `10.1/20`）。 */
  static progress(v: number): string {
    return Formatter.number(v, 'progress');
  }

  /**
   * 保留至多 `places` 位小数并裁掉末尾的 0 与孤立小数点（`80.0000`→`80`、`1.5000`→`1.5`）。
   * 用 `Dec` 定点舍入，避免 `1.005` 这类二进制浮点误差。
   */
  static trimZeros(value: number, places: number): string {
    const fixed: string = Dec.from(value).toFixed(places);
    if (fixed.indexOf('.') < 0) {
      return fixed;
    }
    let end: number = fixed.length;
    while (end > 0 && fixed.charAt(end - 1) === '0') {
      end = end - 1;
    }
    if (end > 0 && fixed.charAt(end - 1) === '.') {
      end = end - 1;
    }
    return fixed.substring(0, end);
  }

  /** 减排量：固定 4 位小数，千位不加分隔符（`12.4800`）。 */
  static reduction(kg: number): string {
    return Formatter.number(kg, 'reduction');
  }

  /** 积分：整数 + 千分位（`4,820`）。 */
  static points(n: number): string {
    return Formatter.number(n, 'points');
  }

  /** 积分流水：`+96` / `−1,500`。 */
  static pointsSigned(n: number): string {
    if (n < 0) {
      return `${MINUS}${Formatter.thousands(-n)}`;
    }
    return `+${Formatter.thousands(n)}`;
  }

  /** 碳币：整数、无小数（`48`）。 */
  static coin(n: number): string {
    return Formatter.number(n, 'coin');
  }

  /** 百分比（整数，用于进度与占比）。 */
  static percent(ratio: number): string {
    const p: number = Math.round(ratio * 100);
    return `${p}%`;
  }

  /** `YYYY-MM-DD HH:mm`（列表）。 */
  static dateTime(ms: number): string {
    const d: Date = new Date(ms);
    return `${DateUtil.dayKeyOfMs(ms)} ${Formatter.pad2(d.getHours())}:${Formatter.pad2(d.getMinutes())}`;
  }

  /** `HH:mm`（同日）。 */
  static timeOfDay(ms: number): string {
    const d: Date = new Date(ms);
    return `${Formatter.pad2(d.getHours())}:${Formatter.pad2(d.getMinutes())}`;
  }

  /**
   * 记录页分组标题（附录 C §7 规则 1）。
   * @param ms 记录发生时间
   * @param now 当前时间
   */
  static dayGroupLabel(ms: number, now: number): string {
    const diff: number = DateUtil.diffDays(now, ms);
    if (diff <= 0) {
      return '今天';
    }
    if (diff === 1) {
      return '昨天';
    }
    const d: Date = new Date(ms);
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }

  /** `YYYYMMDD-HHmm`（备份文件名，附录 C §21）。 */
  static fileStamp(ms: number): string {
    const d: Date = new Date(ms);
    return `${d.getFullYear()}${Formatter.pad2(d.getMonth() + 1)}${Formatter.pad2(d.getDate())}` +
      `-${Formatter.pad2(d.getHours())}${Formatter.pad2(d.getMinutes())}`;
  }

  /** `MM-DD`（搜索页右列）。 */
  static monthDay(ms: number): string {
    const d: Date = new Date(ms);
    return `${Formatter.pad2(d.getMonth() + 1)}-${Formatter.pad2(d.getDate())}`;
  }

  /** 备份与数据库体积（验收 D5-1 要求必须显示文件大小）。 */
  static fileSize(bytes: number): string {
    if (bytes < 1024) {
      return `${Math.round(bytes)} B`;
    }
    const kb: number = bytes / 1024;
    if (kb < 1024) {
      return `${Math.round(kb)} KB`;
    }
    return `${Dec.from(kb / 1024).toFixed(1)} MB`;
  }

  /** 数字千分位（不四舍五入小数部分）。 */
  static thousands(n: number): string {
    const neg: boolean = n < 0;
    const s: string = `${Math.abs(Math.round(n))}`;
    let out: string = '';
    let i: number = 0;
    while (i < s.length) {
      if (i > 0 && (s.length - i) % 3 === 0) {
        out = out + THOUSAND;
      }
      out = out + s.charAt(i);
      i = i + 1;
    }
    return neg ? `${MINUS}${out}` : out;
  }

  private static pad2(v: number): string {
    return v < 10 ? `0${v}` : `${v}`;
  }
}
