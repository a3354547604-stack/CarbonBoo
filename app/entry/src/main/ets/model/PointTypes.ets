/**
 * PointTypes —— 积分域类型（流水 / 余额口径）。
 *
 * 职责：
 *  ① 冻结积分流水类型枚举 `PointType` 与流向枚举 `FlowKind`；
 *  ② 冻结来源枚举 `PointSourceType`（**不含 `adjust`**：无产生方，见附录 B §7.1）；
 *  ③ 定义流水行 `PointRecord` 与余额快照 `PointBalance`。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §4 + §2 建表 SQL 注释 + PLAN §9。
 * 铁律 4：流水只增不删，`余额 = 收入合计 − 支出合计`，每条流水可回溯来源。
 * `flow_kind` 派生规则（唯一定义，附录 B §7.1）：
 *   `flow_kind = (type === 'reverse' ? 'reverse' : 'primary')`。
 */
import { BaseRow } from './CarbonTypes';

export type PointType =
  | 'record' | 'record_capped' | 'goal'
  | 'purchase' | 'carbon_include' | 'reverse';

/** 同一业务事实只允许一条 `primary`；冲正走 `reverse`，可与 `primary` 并存。 */
export type FlowKind = 'primary' | 'reverse';

export type PointSourceType =
  | 'carbon_record' | 'goal' | 'shop_item' | 'carbon_include';

export interface PointRecord extends BaseRow {
  type: PointType;
  flowKind: FlowKind;
  /** 正 = 收入，负 = 支出。 */
  points: number;
  sourceType: PointSourceType;
  /** 取值口径见附录 B §2 建表 SQL 注释（记录类为 `<id>#<revision>`）。 */
  sourceId: string;
  title: string;
  remark?: string;
  occurredAt: number;
}

export interface PointBalance {
  /** 收入 − 支出。 */
  balance: number;
  totalIncome: number;
  totalSpent: number;
  /** 记录分 + 目标分（用于展示"今日已得"）。 */
  todayEarned: number;
  /** 仅记录分，用于封顶进度条；封顶判定只认这个口径。 */
  todayRecordPoint: number;
  /** 每日记录分上限，固定 200（PLAN §9.2）。 */
  cap: number;
  /** 碳币余额 = floor(积分余额 / 100)。 */
  carbonCoin: number;
}
