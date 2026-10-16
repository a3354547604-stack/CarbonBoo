/**
 * CarbonCalc —— **减排量纯函数计算核心**（铁律 2 的算数底座）。
 *
 * 职责（本文件只有这一个职责）：
 *  ① `reductionOf`：`减排量 = round_half_up(活动量 × 因子值, 4)`；
 *  ② `expectedPointOf`：`应得 C = round_half_up(减排量 × 100, 0)`；
 *  ③ `actualPointOf`：`实入 A = max(0, min(C, 200 − D))`；
 *  ④ `evaluate`：把三者串起来，并给出 `willBeCapped` / `capped` 与「不生成积分流水」判定。
 *
 * 为什么独立于 `CarbonService`：本文件**不 import 任何 ArkTS 运行时 API**，
 * 因此可以被离线 Node 脚本（esbuild 转译后）直接逐组复算 `tests/cases/carbon-calc.json`，
 * 而不需要真机或模拟器。`CarbonService` 只做「取因子快照 + 调本文件 + 落库」。
 *
 * 数值口径（唯一真相源 `tests/cases/carbon-calc.json → meta.formulas`）：
 *  - 舍入一律 **half-up（四舍五入）**，禁止语言默认的 banker's rounding；
 *  - **禁止浮点累加**：本文件全程用 6 位小数定点整数运算（见 `DecimalUtil.Dec`）；
 *  - `round(x, n)` 表示对 10 的负数次幂做 half-up 量化。
 */
import { Dec } from '../util/DecimalUtil';
import { AppConstants } from '../util/AppConstants';

/** 因子快照（铁律 3 要求落库的四字段）。 */
export interface FactorSnapshot {
  /** 因子值，6 位小数定点。 */
  factorValue: number;
  /** 因子库版本号，当前 `CF-2026.2`。 */
  factorVersion: string;
  /** 来源编号（如 `SRC-DERIVED`）。 */
  factorSource: string;
  /** verified | provisional。 */
  confidence: string;
}

/** 计算评估选项。 */
export interface CalcOptions {
  /** 今日已得记录分 D（**只含记录类**，不含目标分）。缺省 0。 */
  todayRecordPoint?: number;
  /** 每日记录分上限；缺省 `AppConstants.DAILY_RECORD_CAP`（200）。 */
  dailyCap?: number;
  /** 每 kgCO₂e 折算积分；缺省 `AppConstants.POINTS_PER_KG`（100）。 */
  pointsPerKg?: number;
  /** 产生积分流水的最小减排量；缺省 `AppConstants.MIN_REDUCTION_FOR_POINT`（0.005）。 */
  minReductionForPoint?: number;
}

/** 一次计算的完整评估结果。 */
export class CalcEvaluation {
  /** 减排量，4 位小数。 */
  readonly reductionKg: number;
  /** 应得 C（未受封顶影响）。 */
  readonly expectedPoint: number;
  /** 今日已得 D。 */
  readonly todayRecordPoint: number;
  /** 本次实入 A。 */
  readonly actualPoint: number;
  /** 是否被日封顶削减（`A < C`）。 */
  readonly capped: boolean;
  /** 本次是否应当生成积分流水（`C > 0`）。 */
  readonly pointRequired: boolean;
  /** 是否应提示「距离较大，请确认是否填错」（`is_abnormal` 判定，不阻断保存）。 */
  readonly isAbnormal: boolean;

  constructor(
    reductionKg: number,
    expectedPoint: number,
    todayRecordPoint: number,
    actualPoint: number,
    capped: boolean,
    pointRequired: boolean,
    isAbnormal: boolean
  ) {
    this.reductionKg = reductionKg;
    this.expectedPoint = expectedPoint;
    this.todayRecordPoint = todayRecordPoint;
    this.actualPoint = actualPoint;
    this.capped = capped;
    this.pointRequired = pointRequired;
    this.isAbnormal = isAbnormal;
  }
}

/**
 * 无浮点误差的四舍五入转换：`Dec` → `number`。
 * 直接 `value / SCALE` 会引入 IEEE-754 表示误差（如 0.3500 变 0.35000000000000003），
 * 落库后展示会多出无意义尾数，故一律经十进制字符串往返。
 * @param d 定点数
 * @param places 小数位（0..6）
 */
function toNumber(d: Dec, places: number): number {
  return Number.parseFloat(d.toFixed(places));
}

export class CarbonCalc {
  /**
   * ① 减排量：`round_half_up(活动量 × 因子值, 4)`。
   * @param amount 活动量（>0 由调用方保证；0/负数在 UI 层被禁用保存）
   * @param factorValue 因子值
   */
  static reductionOf(amount: number, factorValue: number): number {
    // 单笔只做一次乘法，全程在 6 位小数定点整数上完成（`Dec`），**不碰二进制浮点**：
    //   活动量 × 因子值 → 定点整数乘法（内部按 6 位小数舍入）→ `roundHalfUp(4)` 量化到 4 位。
    // 注意 `Dec.roundHalfUp(places)` 的 `places` 是**真值的小数位**（内部按 1e(6-places) 量化），
    // 因此这里传 4 就是 `round_half_up(x, 4)`；不要把它误解成"缩放单位的位数"。
    const product: Dec = Dec.from(amount).mul(Dec.from(factorValue));
    return product.roundHalfUp(AppConstants.REDUCTION_DECIMALS).toNumber(AppConstants.REDUCTION_DECIMALS);
  }

  /**
   * ② 应得积分 C：`round_half_up(减排量 × 100, 0)`。
   * @param reductionKg 减排量（4 位小数）
   * @param pointsPerKg 每 kg 折算积分，缺省 100
   */
  static expectedPointOf(reductionKg: number, pointsPerKg?: number): number {
    const rate: number = pointsPerKg === undefined ? AppConstants.POINTS_PER_KG : pointsPerKg;
    return Dec.from(reductionKg).mul(Dec.fromInt(rate)).toInt();
  }

  /**
   * ③ 实入积分 A：`max(0, min(C, cap − D))`。
   * @param expectedPoint 应得 C
   * @param todayRecordPoint 今日已得 D
   * @param dailyCap 日上限，缺省 200
   */
  static actualPointOf(expectedPoint: number, todayRecordPoint: number, dailyCap?: number): number {
    const cap: number = dailyCap === undefined ? AppConstants.DAILY_RECORD_CAP : dailyCap;
    const remain: number = cap - todayRecordPoint;
    const limit: number = remain < 0 ? 0 : remain;
    return expectedPoint < limit ? expectedPoint : limit;
  }

  /**
   * 边界样例 21/22 的判据：`减排量 < 0.005 kg` 时**碳记录可存但不得生成积分流水**。
   * @param reductionKg 减排量
   * @param minReduction 阈值，缺省 0.005
   */
  static isPointRequired(reductionKg: number, minReduction?: number): boolean {
    const min: number = minReduction === undefined ? AppConstants.MIN_REDUCTION_FOR_POINT : minReduction;
    return (
      Dec.from(reductionKg).compareTo(Dec.from(min)) >= 0
    );
  }

  /**
   * 输入合理范围判定（附录 A §4：超限**提示但不阻断**，落库置 `is_abnormal = 1`）。
   * 判定按**行为大类**取上限：出行 km / 用电 kWh / 用水 L / 燃气 m³ / 回收 kg / 光盘 次。
   * @param category 行为大类
   * @param subType 因子小类（区分「天然气 m³」与「液化石油气 kg」等同大类不同单位）
   * @param amount 活动量
   */
  static isAbnormalInput(category: string, subType: string, amount: number): boolean {
    let limit: number = AppConstants.LIMIT_TRAVEL_KM;
    if (category === 'utility') {
      if (subType === 'water' || subType === 'water_treat') {
        limit = AppConstants.LIMIT_WATER_L;
      } else if (subType === 'gas') {
        limit = AppConstants.LIMIT_GAS_M3;
      } else {
        limit = AppConstants.LIMIT_ELEC_KWH;
      }
    } else if (category === 'recycle') {
      limit = AppConstants.LIMIT_RECYCLE_KG;
    } else if (category === 'plate') {
      limit = AppConstants.LIMIT_PLATE_TIMES;
    }
    return amount > limit;
  }

  /**
   * 完整评估：一次算清减排量 / 应得 C / 实入 A / 封顶与异常标记。
   * @param category 行为大类（只用于异常范围判定）
   * @param subType 因子小类
   * @param amount 活动量
   * @param factor 因子快照
   * @param options 可选口径覆盖
   */
  static evaluate(
    category: string,
    subType: string,
    amount: number,
    factor: FactorSnapshot,
    options?: CalcOptions
  ): CalcEvaluation {
    const todayD: number = options !== undefined && options.todayRecordPoint !== undefined ? options.todayRecordPoint : 0;
    const cap: number | undefined = options === undefined ? undefined : options.dailyCap;
    const rate: number | undefined = options === undefined ? undefined : options.pointsPerKg;
    const minRed: number | undefined = options === undefined ? undefined : options.minReductionForPoint;

    const reduction: number = CarbonCalc.reductionOf(amount, factor.factorValue);
    const expected: number = CarbonCalc.expectedPointOf(reduction, rate);
    const actual: number = CarbonCalc.actualPointOf(expected, todayD, cap);
    return new CalcEvaluation(
      reduction,
      expected,
      todayD,
      actual,
      actual < expected,
      CarbonCalc.isPointRequired(reduction, minRed),
      CarbonCalc.isAbnormalInput(category, subType, amount)
    );
  }

  /**
   * 换算：少开一天车 —— `活动量(km) = 天数 × AVG_CAR_TRIP_KM`。
   * @param days 天数（整数）
   * @param kmPerDay 单程平均里程，缺省取因子库 `conversions.AVG_CAR_TRIP_KM`（8.0）
   */
  static amountOfCarFreeDays(days: number, kmPerDay: number): number {
    return toNumber(Dec.fromInt(days).mul(Dec.from(kmPerDay)), AppConstants.REDUCTION_DECIMALS);
  }

  /**
   * 换算：回收按件 —— `活动量(kg) = 件数 × AVG_ITEM_WEIGHT_KG`。
   * @param pieces 件数（整数）
   * @param kgPerPiece 单件平均重量，缺省取因子库 `conversions.AVG_ITEM_WEIGHT_KG`（0.5）
   */
  static amountOfRecyclePieces(pieces: number, kgPerPiece: number): number {
    return toNumber(Dec.fromInt(pieces).mul(Dec.from(kgPerPiece)), AppConstants.REDUCTION_DECIMALS);
  }
}
