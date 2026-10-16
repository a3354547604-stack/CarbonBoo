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
export type NumberKind = 'reduction' | 'factor' | 'points' | 'coin';

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
      return Dec.from(value).toFixed(4);
    }
    if (kind === 'factor') {
      return Dec.from(value).toFixed(4);
    }
    const int: number = Math.round(value);
    if (kind === 'coin') {
      return `${int}`;
    }
    return Formatter.thousands(int);
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
