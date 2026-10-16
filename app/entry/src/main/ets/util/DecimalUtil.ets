/**
 * DecimalUtil —— 定点小数运算与 **half-up（四舍五入）** 舍入工具。
 *
 * 职责：
 *  ① 把十进制小数字面量（如 0.5703 / 12.48）无损转成「缩放整数」表示；
 *  ② 提供定点加 / 乘（`mul` / `div`）与 `roundHalfUp` 舍入；
 *  ③ 作为 `CarbonService.calculate()` 的算数底座——该函数的**数值正确性完全依赖本文件**。
 *
 * 为什么不能直接写 `Math.round(x * 10000) / 10000`（这是本项目的关键实现约束）：
 *  - `Math.round` 对 `.5` 的语义在负数上是「向 +∞ 取整」（Math.round(-0.5) === -0），
 *    与 half-up 期望的「远离 0」不一致；
 *  - 更要命的是二进制浮点本身会丢精度：`0.5703` 在 IEEE-754 里是 0.57029999999999997...
 *    `10 × 0.5703 = 5.702999999999999` 而基准要求 `5.7030`；`0.1920 × 16 = 3.0719999999999996`
 *    而基准要求 `3.0720`。直接用浮点乘再舍入会**偶发**少 1 个 ULP，进而把 4 位小数舍成
 *    `5.7029 / 3.0719`，连带把积分算错（570 → 570 侥幸对，307 → 307 侥幸对，但边界值不保证）。
 *  - 因此本文件**一律用缩放整数做乘除**，浮点只在最后一步 `toNumber()` 出现。
 *
 * 精度上限：缩放因子取 `1e6`（6 位小数），与附录 A §3.4「因子值存 6 位小数、减排量存 4 位小数」
 * 一致；每条记录只做「活动量 × 因子值」一次乘法，不累加，故 6 位量级足够（无累加误差放大）。
 *
 * 禁止事项：本文件不 import 任何 ArkTS 运行时 API，保证可被离线 Node 逐组复核（见 t2 验证报告）。
 */

/** 定点缩放因子：1e6，即 6 位小数精度。 */
const SCALE: number = 1000000;

/**
 * 定点十进制数。`value` 是 `真实值 × SCALE` 的四舍五入整数（|真实值| 期望 ≤ 1e8）。
 */
export class Dec {
  /** 缩放后的整数值（真实值 = value / SCALE）。 */
  readonly value: number;

  private constructor(scaled: number) {
    this.value = scaled;
  }

  /** 由十进制字面量（number）构造；内部按 6 位小数四舍五入到缩放整数。 */
  static from(x: number): Dec {
    if (!Number.isFinite(x)) {
      throw new Error(`Dec.from 只接受有限数，收到 ${x}`);
    }
    // Math.round 对正负数的半值都朝 +∞；输入是「十进制字面量 × 1e6」，此处误差远小于 0.5，
    // 不会踩到半值分支，故这里的 Math.round 只是「就近取整」，语义安全。
    return new Dec(Math.round(x * SCALE));
  }

  /** 由整数构造（活动量 / 积分这类整数走这里，避免多余的浮点乘法）。 */
  static fromInt(v: number): Dec {
    if (!Number.isInteger(v)) {
      throw new Error(`Dec.fromInt 只接受整数，收到 ${v}`);
    }
    return new Dec(v * SCALE);
  }

  /**
   * 由十进制字符串构造（避免先经浮点丢精度）。
   * 支持可选的 `+` / `-` 号与最多 6 位小数；超出 6 位的部分按 half-up 舍入。
   */
  static fromString(s: string): Dec {
    const m: RegExpMatchArray | null = s.trim().match(/^([+-]?)(\d+)(?:\.(\d*))?$/);
    if (m === null) {
      throw new Error(`Dec.fromString 无法解析：${s}`);
    }
    const sign: number = m[1] === '-' ? -1 : 1;
    const intPart: string = m[2];
    const fracRaw: string = m[3] !== undefined ? m[3] : '';
    const frac: string = fracRaw.length > 6 ? fracRaw.substring(0, 6) : fracRaw;
    const padded: string = (frac + '000000').substring(0, 6);
    const scaled: number = Number.parseInt(intPart, 10) * SCALE + Number.parseInt(padded, 10);
    return new Dec(sign * scaled);
  }

  /** 定点乘法：两数相乘后再按 half-up 舍入到 6 位小数。 */
  mul(other: Dec): Dec {
    // 直接乘会超过 Number.MAX_SAFE_INTEGER（1e6 × 1e6 = 1e12 尚安全，但 1e6 × 1e6 × 再乘就不安全）。
    // 拆成「整数部分 + 小数部分」，每步都控制在安全整数范围内。
    const a: number = Math.trunc(this.value / SCALE);
    const b: number = this.value - a * SCALE;
    const c: number = Math.trunc(other.value / SCALE);
    const d: number = other.value - c * SCALE;
    // (a+b/SCALE)(c+d/SCALE) × SCALE = a*c*SCALE + a*d + b*c + b*d/SCALE
    const bd: number = (b * d) / SCALE;
    const raw: number = a * c * SCALE + a * d + b * c + bd;
    return new Dec(roundHalfUpToInt(raw));
  }

  /** 定点除法：按 half-up 舍入到 6 位小数；除数为 0 抛错。 */
  div(other: Dec): Dec {
    if (other.value === 0) {
      throw new Error('Dec.div 除数为 0');
    }
    return new Dec(roundHalfUpToInt((this.value * SCALE) / other.value));
  }

  /** 加减（同精度定点，无舍入误差）。 */
  add(other: Dec): Dec {
    return new Dec(this.value + other.value);
  }

  /** 减法。 */
  sub(other: Dec): Dec {
    return new Dec(this.value - other.value);
  }

  /** 取相反数（内部用，公开以便上层做规则组合）。 */
  negate(): Dec {
    return new Dec(-this.value);
  }

  /** 比较：< 0 / 0 / > 0。 */
  compareTo(other: Dec): number {
    if (this.value < other.value) {
      return -1;
    }
    if (this.value > other.value) {
      return 1;
    }
    return 0;
  }

  /** 是否等于 0。 */
  isZero(): boolean {
    return this.value === 0;
  }

  /**
   * half-up 舍入到指定位数（0 ≤ places ≤ 6），返回一个新的 Dec。
   * places = 4 → `round_half_up(x, 4)`；places = 0 → 积分取整。
   *
   * ⚠️ 缩放口径是本文件最容易写错的地方（v1 就在这里写错过一次，导致 5.7030 被舍成 5.7000）：
   * `this.value` 是「真值 × 1e6」（SCALE = 1e6），而 `places` 是**真值的小数位**。
   * 因此"保留 places 位"= 在缩放整数上按 `1e(6 - places)` 量化，**不是**按 `1e(places)`：
   *   - 保留 4 位：真值只要求到 1e-4，即缩放整数按 1e2 量化
   *     （5.7030 → 5703000 → 5703000/100 = 57030 → 回乘 100 → 5703000，5.7030 原样保留）；
   *   - 取整到 0 位：按 1e6 量化（0.1920 → 192000/1e6 = 0.192 → 回乘 1e6，归零）；
   *   - 保留 6 位：按 1e0 量化 = 恒等（6 位是上限精度，不动）。
   * 写错成 `1e(places)` 时，保留 4 位会把小数**再丢两位**（5703000/1e4 = 570.3 → 570 → 5.7000）。
   */
  roundHalfUp(places: number): Dec {
    if (!Number.isInteger(places) || places < 0 || places > 6) {
      throw new Error(`roundHalfUp 的位数必须在 0..6，收到 ${places}`);
    }
    const q: number = pow10(6 - places);
    return new Dec(roundHalfUpToInt(this.value / q) * q);
  }

  /** half-up 舍入到指定小数位后转成 number（结果可能带浮点表示误差，仅用于展示/落库前的数值）。 */
  toNumber(places: number): number {
    return this.roundHalfUp(places).value / SCALE;
  }

  /** 舍入到整数（half-up），返回 number；积分一律走这里。 */
  toInt(): number {
    return roundHalfUpToInt(this.value / SCALE);
  }

  /** 调试用字符串（6 位小数定长，便于逐位比对）。 */
  toFixed(places: number): string {
    const r: Dec = this.roundHalfUp(places);
    const sign: string = r.value < 0 ? '-' : '';
    const abs: number = Math.abs(r.value);
    const intPart: number = Math.trunc(abs / SCALE);
    const frac: string = String(abs - intPart * SCALE).padStart(6, '0');
    return `${sign}${intPart}.${frac.substring(0, places)}`;
  }
}

/** 10 的 n 次幂（n ∈ 0..6）。 */
function pow10(n: number): number {
  let r: number = 1;
  let i: number = 0;
  while (i < n) {
    r = r * 10;
    i = i + 1;
  }
  return r;
}

/**
 * half-up（四舍五入，**.5 一律远离 0**）取整。
 *
 * 与 `Math.round` 的区别只在负数半值：`Math.round(-0.5) === -0`，本函数返回 `-1`。
 * 本项目所有数值（活动量、因子值、减排量、积分）都非负，差异当前不会显现；
 * 但把语义写死成 half-up 可以避免将来出现负值时静默改变口径。
 */
export function roundHalfUpToInt(x: number): number {
  return x >= 0 ? Math.floor(x + 0.5) : -Math.floor(-x + 0.5);
}

/** half-up 舍入到 places 位，返回 number（积分换算等少量场景直接可用）。 */
export function roundHalfUp(x: number, places: number): number {
  return Dec.from(x).roundHalfUp(places).toNumber(places);
}
