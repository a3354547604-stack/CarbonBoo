/**
 * CarbonService —— 减排量的**唯一计算入口**（AGENTS.md §2 铁律 2）。
 *
 * 职责：
 *  ① `calculate(activity, factor)`：**纯函数式**签名——只吃「活动量 + 因子快照」，
 *     吐「减排量 / 应得 C / 实入 A」，不读库、不发网络、不碰 UI 状态；
 *  ② `calculatePreview(...)`：在 ① 之上叠加今日已得 D（D 由调用方从 Dao 查出后传入，
 *     仍保持本方法无副作用），用于录入向导的实时预览；
 *  ③ `saveRecord(...)`：把「碳记录 + 积分流水」的多表写入**在一个事务里**完成
 *     ——**事务边界在 Service 层**（AGENTS.md §7.1），Dao 不开事务；
 *  ④ 落库时写入因子快照四字段 `factor_value` / `factor_version` / `factor_source` / `confidence`
 *     （铁律 3），且**永不回写历史**。
 *
 * 为什么 ① 必须是纯函数：单测（L1）与离线复算脚本都要能在没有设备、没有数据库、
 * 没有 UIAbilityContext 的环境里逐组验证 18 组正向 + 5 组封顶样例。
 * 因此 ① 的参数是**数据**（`ActivityInput` + `FactorSnapshot`），不是 Dao、不是 Context。
 *
 * 数值口径（唯一真相源 `tests/cases/carbon-calc.json`）：
 *   `减排量 = round_half_up(活动量 × 因子值, 4)`
 *   `应得 C = round_half_up(减排量 × 100, 0)`
 *   `实入 A = max(0, min(C, 200 − D))`
 *   舍入一律 half-up；**不用浮点累加**（单笔只做一次乘法，定点整数实现见 `CarbonCalc`）。
 */
import { CarbonRecord, CalculateInput, CalculatePreview, CategoryKey, Confidence } from '../model/CarbonTypes';
import { CarbonCalc, CalcEvaluation, CalcOptions, FactorSnapshot } from './CarbonCalc';
import { AppConstants } from '../util/AppConstants';
import { StringUtil } from '../util/StringUtil';

/** 活动量输入（铁律 2 的入参：只有活动量与行为标识，不含任何因子数值）。 */
export interface ActivityInput {
  category: CategoryKey;
  subType: string;
  /** 活动量；>0 由页面层保证（0/负数在 UI 层禁用保存）。 */
  amount: number;
  occurredAt: number;
}

/** 计算输出（纯函数返回值；字段与 `CalculatePreview` 的前三项同义）。 */
export class CarbonCalculation {
  /** 减排量，4 位小数。 */
  readonly reductionKg: number;
  /** 应得 C。 */
  readonly expectedPoint: number;
  /** 实入 A（未传 D 时等于 C）。 */
  readonly actualPoint: number;
  /** 是否被封顶削减。 */
  readonly capped: boolean;
  /** 是否应生成积分流水。 */
  readonly pointRequired: boolean;

  constructor(reductionKg: number, expectedPoint: number, actualPoint: number, capped: boolean, pointRequired: boolean) {
    this.reductionKg = reductionKg;
    this.expectedPoint = expectedPoint;
    this.actualPoint = actualPoint;
    this.capped = capped;
    this.pointRequired = pointRequired;
  }
}

/** 今日额度视图（封顶进度条用；D 只含记录类，目标分不计入）。 */
export interface DailyQuota {
  todayRecordPoint: number;
  cap: number;
  remaining: number;
}

export class CarbonService {
  /**
   * ① **唯一计算入口（纯函数式）**：活动量 + 因子快照 → 减排量 / 应得 C / 实入 A。
   *
   * 页面层、ViewModel、任何 Service 都只能通过本方法得到减排量；禁止在别处乘因子。
   * @param activity 活动量输入（行为大类、因子 key、活动量、发生时间）
   * @param factor 因子快照（四字段，铁律 3 要求原样落库）
   * @param options 口径覆盖（今日已得 D、日上限等）；缺省取 `AppConstants` 常量
   */
  static calculate(activity: ActivityInput, factor: FactorSnapshot, options?: CalcOptions): CarbonCalculation {
    const evaluation: CalcEvaluation = CarbonCalc.evaluate(
      activity.category,
      activity.subType,
      activity.amount,
      factor,
      options
    );
    return new CarbonCalculation(
      evaluation.reductionKg,
      evaluation.expectedPoint,
      evaluation.actualPoint,
      evaluation.capped,
      evaluation.pointRequired
    );
  }

  /**
   * ② 录入向导预览：`calculate()` 的展示形态。
   * `todayEarned` / `willBeCapped` / `actualPoint` 三项与 `tests/cases/carbon-calc.json → capSamples`
   * 的 `todayEarnedD` / `capped` / `expectedActualA` 一一对应。
   * @param activity 活动量输入
   * @param factor 因子快照
   * @param todayRecordPoint 今日已得记录分 D（由调用方查 `PointRecordDao` 后传入）
   */
  static calculatePreview(
    activity: ActivityInput,
    factor: FactorSnapshot,
    todayRecordPoint: number
  ): CalculatePreview {
    const opts: CalcOptions = { todayRecordPoint };
    const calc: CarbonCalculation = CarbonService.calculate(activity, factor, opts);
    return {
      reductionKg: calc.reductionKg,
      estimatedPoint: calc.expectedPoint,
      todayEarned: todayRecordPoint,
      willBeCapped: calc.capped,
      actualPoint: calc.actualPoint,
    };
  }

  /** 今日剩余额度（封顶进度条）。 */
  static quotaOf(todayRecordPoint: number): DailyQuota {
    const remain: number = AppConstants.DAILY_RECORD_CAP - todayRecordPoint;
    return {
      todayRecordPoint,
      cap: AppConstants.DAILY_RECORD_CAP,
      remaining: remain < 0 ? 0 : remain,
    };
  }

  /**
   * ③ 由计算结果组装一条待落库的碳记录。
   *
   * 刻意把"组装"与"写库"分开：本方法纯函数、可单测；写库由 S2 的记录保存链路调用。
   * 铁律 3：因子快照四字段在这里被写进行对象，之后无论因子库怎么升级都不再变。
   * @param id 新记录主键（UUID v4，客户端生成以保证多设备不冲突）
   * @param activity 活动量输入
   * @param factor 因子快照
   * @param calc 计算结果
   * @param unit 单位（km | kWh | L | m³ | kg | 次）
   * @param isAbnormal 是否超出合理范围（提示但不阻断）
   * @param note 备注（选填）
   */
  static buildRecord(
    id: string,
    activity: ActivityInput,
    factor: FactorSnapshot,
    calc: CarbonCalculation,
    unit: string,
    isAbnormal: number,
    note: string | undefined,
    userId: string,
    now: number,
    deviceId?: string
  ): CarbonRecord {
    const confidence: Confidence = CarbonService.toConfidence(factor.confidence);
    return {
      id,
      userId,
      category: activity.category,
      subType: activity.subType,
      amount: activity.amount,
      unit,
      occurredAt: activity.occurredAt,
      reductionKg: calc.reductionKg,
      factorValue: factor.factorValue,
      factorVersion: factor.factorVersion,
      factorSource: factor.factorSource,
      confidence,
      pointAwarded: calc.actualPoint,
      revision: 0,
      pointCapped: calc.capped ? 1 : 0,
      isAbnormal,
      note,
      createdAt: now,
      updatedAt: now,
      isDeleted: 0,
      deviceId,
      syncState: 'pending',
    };
  }

  /**
   * 因子快照的构造：从因子库条目 + 版本号生成四字段快照。
   * 所有落库路径都必须经这里，避免有人只写 `factor_value` 而漏掉版本与来源。
   * @param factorValue 因子值
   * @param factorVersion 因子库版本（`FactorLibrary.version()`）
   * @param factorSource 来源编号
   * @param confidence verified | provisional
   */
  static snapshotOf(
    factorValue: number,
    factorVersion: string,
    factorSource: string,
    confidence: string
  ): FactorSnapshot {
    return { factorValue, factorVersion, factorSource, confidence };
  }

  /** 记录标题（积分流水 `title` 用，统一走 `Formatter` 之前的原始拼装）。 */
  static titleOf(category: CategoryKey, subType: string, amount: number, unit: string): string {
    return `${StringUtil.trimOr(subType, category)} ${amount} ${unit}`;
  }

  /** 字符串 → `Confidence`（非法值立刻抛错，不静默兜底）。 */
  static toConfidence(v: string): Confidence {
    if (v === 'verified' || v === 'provisional') {
      return v;
    }
    throw new Error(`因子快照 confidence 非法值：${v}`);
  }

  /** `CalculateInput` → `ActivityInput`（两个类型语义相同，保留 `CalculateInput` 以对齐附录 B §4）。 */
  static activityOf(input: CalculateInput): ActivityInput {
    return {
      category: input.category,
      subType: input.subType,
      amount: input.amount,
      occurredAt: input.occurredAt,
    };
  }
}
