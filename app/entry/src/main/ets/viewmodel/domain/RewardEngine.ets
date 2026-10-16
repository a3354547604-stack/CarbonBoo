/**
 * RewardEngine —— 目标进度与结算判定的**纯函数核**（不读库、不发分）。
 *
 * 职责：
 *  ① `progressOf(def, records)`：按 `metric` 口径算进度
 *     （count / sum_amount / sum_reduction / distinct_days）；
 *  ② `decide(rows, now)`：**幂等结算判定**——只对「已达阈值 且 未结算」的行产出一次结算指令；
 *     同一份输入重复调用结果相同，`settled = true` 的行永不再产出（附录 B §8.1「周期内只结算一次」）；
 *  ③ `progressRows(...)`：给目标页组装展示行（含 0~100 截顶百分比与周期标签）。
 *
 * 为什么单独成文件：L1 用例「目标幂等」要能在**没有数据库**的环境下断言。
 * 判定与落库分离后，幂等性是关于这个纯函数的定理，而不是"看起来没重复发分"。
 */
import { CarbonRecord } from '../../model/CarbonTypes';
import { GoalDef, GoalProgress, GoalPeriod } from '../../model/GoalTypes';
import { DateUtil } from '../../util/DateUtil';
import { PeriodWindow, PeriodSpan } from './PeriodWindow';

/** 一条用户目标行的输入形态（来自 `user_goal` 表）。 */
export interface GoalRowInput {
  goalId: string;
  periodKey: string;
  progress: number;
  threshold: number;
  /** 该目标的奖励分（来自 `goal_def.reward`）。 */
  reward: number;
  /** 1 = 已发分。 */
  settled: boolean;
}

/** 一次结算指令（Service 据此写 `point_record(goal)` 并把 `user_goal.settled` 置 1）。 */
export interface SettleDecision {
  goalId: string;
  periodKey: string;
  reward: number;
}

/** 目标页展示行（`GoalProgress` 的展示扩展）。 */
export interface GoalCard extends GoalProgress {
  /** 周期中文名（每日/本周/本月…）。 */
  periodLabel: string;
  unit: string;
  /** 未达成时的剩余时间文案。 */
  remainLabel: string;
}

export class RewardEngine {
  /**
   * 按目标口径算进度。`records` 必须**已按周期窗口过滤**。
   * @param def 目标定义
   * @param records 窗口内的碳记录
   */
  static progressOf(def: GoalDef, records: CarbonRecord[]): number {
    let i: number = 0;
    if (def.metric === 'count') {
      let n: number = 0;
      while (i < records.length) {
        if (RewardEngine.matches(def, records[i])) {
          n = n + 1;
        }
        i = i + 1;
      }
      return n;
    }
    if (def.metric === 'sum_amount') {
      let sum: number = 0;
      while (i < records.length) {
        if (RewardEngine.matches(def, records[i])) {
          sum = sum + records[i].amount;
        }
        i = i + 1;
      }
      return RewardEngine.round2(sum);
    }
    if (def.metric === 'sum_reduction') {
      let sum: number = 0;
      while (i < records.length) {
        if (RewardEngine.matches(def, records[i])) {
          sum = sum + records[i].reductionKg;
        }
        i = i + 1;
      }
      return RewardEngine.round4(sum);
    }
    // distinct_days：按发生日的自然日去重
    const days: string[] = [];
    while (i < records.length) {
      const r: CarbonRecord = records[i];
      if (RewardEngine.matches(def, r)) {
        const key: string = DateUtil.dayKeyOfMs(r.occurredAt);
        if (days.indexOf(key) < 0) {
          days.push(key);
        }
      }
      i = i + 1;
    }
    return days.length;
  }

  /**
   * 幂等结算判定。
   * @param rows 当前周期内的目标行
   */
  static decide(rows: GoalRowInput[]): SettleDecision[] {
    const out: SettleDecision[] = [];
    let i: number = 0;
    while (i < rows.length) {
      const row: GoalRowInput = rows[i];
      if (!row.settled && row.progress >= row.threshold) {
        out.push({ goalId: row.goalId, periodKey: row.periodKey, reward: row.reward });
      }
      i = i + 1;
    }
    return out;
  }

  /**
   * 组装目标页展示行。
   * @param defs 目标定义（来自 `goal_def`，按 order）
   * @param progressMap goalId → 当前周期进度
   * @param settledMap `goalId:periodKey` → 已结算
   * @param spanOf 目标 → 周期窗口（由 Service 提供注册日等上下文）
   * @param now 当前时刻
   */
  static progressRows(
    defs: GoalDef[],
    progressMap: Map<string, number>,
    settledMap: Map<string, boolean>,
    spanOf: (def: GoalDef) => PeriodSpan,
    now: number
  ): GoalCard[] {
    const out: GoalCard[] = [];
    let i: number = 0;
    while (i < defs.length) {
      const def: GoalDef = defs[i];
      const span: PeriodSpan = spanOf(def);
      const pv: number | undefined = progressMap.get(def.id);
      const progress: number = pv === undefined ? 0 : pv;
      const settled: boolean = settledMap.get(`${def.id}:${span.key}`) === true;
      const percent: number = def.threshold <= 0 ? 0 : Math.min(100, Math.round((progress / def.threshold) * 100));
      out.push({
        goalId: def.id,
        name: def.name,
        tier: def.tier,
        periodKey: span.key,
        progress,
        threshold: def.threshold,
        reward: def.reward,
        settled,
        percent,
        periodLabel: RewardEngine.periodLabelOf(def.period),
        unit: def.unit === undefined ? '' : def.unit,
        remainLabel: settled ? '' : PeriodWindow.remainingLabel(span.endMs, now),
      });
      i = i + 1;
    }
    return out;
  }

  /** 目标卡片的周期标签（每日 / 本周 / … + 周目标注明自然周口径）。 */
  static periodLabelOf(period: GoalPeriod): string {
    if (period === 'week') {
      return '本周（周一 00:00 起算）';
    }
    return PeriodWindow.labelOf(period);
  }

  /** 记录是否命中目标限定（大类 + 小类）。 */
  private static matches(def: GoalDef, r: CarbonRecord): boolean {
    if (def.category !== undefined && def.category !== r.category) {
      return false;
    }
    if (def.subTypes !== undefined && def.subTypes.length > 0) {
      return def.subTypes.indexOf(r.subType) >= 0;
    }
    return true;
  }

  private static round2(v: number): number {
    return Math.round(v * 100) / 100;
  }

  private static round4(v: number): number {
    return Number.parseFloat((Math.round(v * 10000) / 10000).toFixed(4));
  }
}
