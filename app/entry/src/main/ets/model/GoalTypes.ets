/**
 * GoalTypes —— 目标域类型（11 个目标的定义与进度口径）。
 *
 * 职责：定义目标档位 `GoalTier`、周期 `GoalPeriod`、判定口径 `GoalMetric`，
 * 以及静态定义 `GoalDef` 与运行期进度 `GoalProgress`。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §4 + §8.1；数值唯一来源是 PLAN §10.1。
 * `period_key` 生成规则（附录 B §8.1 表下注）：
 *   day → `D:YYYY-MM-DD`；week → `W:YYYY-Www`（ISO 周，周一 00:00 起）；
 *   month → `M:YYYY-MM`；quarter → `Q:YYYY-Qn`；year → `Y:YYYY`；
 *   hundred_days → `L:YYYY-MM-DD`（注册日，窗口 = 注册日起 100 天）。
 */
import { CategoryKey } from './CarbonTypes';

export type GoalTier = 'short' | 'mid' | 'long';
export type GoalPeriod = 'day' | 'week' | 'month' | 'quarter' | 'year' | 'hundred_days';
export type GoalMetric = 'count' | 'sum_amount' | 'sum_reduction' | 'distinct_days';

/** 目标静态定义，与 `rawfile/goals/goal-defs.json` 逐字段对应。 */
export interface GoalDef {
  id: string;
  name: string;
  tier: GoalTier;
  period: GoalPeriod;
  metric: GoalMetric;
  /** 限定的行为大类；`undefined` = 不限。 */
  category?: CategoryKey;
  /** 限定的小类；`undefined` = 不限。 */
  subTypes?: string[];
  unit?: string;
  threshold: number;
  reward: number;
  icon: string;
  order: number;
}

export interface GoalProgress {
  goalId: string;
  name: string;
  tier: GoalTier;
  periodKey: string;
  progress: number;
  threshold: number;
  reward: number;
  settled: boolean;
  /** 0~100，已按 threshold 截顶。 */
  percent: number;
}
