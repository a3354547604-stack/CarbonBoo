/**
 * IncludeTypes —— 碳普惠模拟域类型（积分 → 碳币 → 权益）。
 *
 * 职责：定义碳币余额 `CarbonCoin`、模拟权益 `IncludeBenefit`、兑换记录 `CarbonIncludeRecord`。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §4 + §8.5。
 * 规则：汇率固定 **100 积分 = 1 碳币**；全部权益均为**模拟演示**，不做真实对接、
 *       不可提现、不可退，界面强制标注「模拟演示」。
 */
import { BaseRow } from './CarbonTypes';

export interface CarbonCoin {
  /** 可用碳币。 */
  balance: number;
  /** 历史累计兑换。 */
  totalExchanged: number;
  /** 历史累计消耗。 */
  totalSpent: number;
  /** floor(积分余额 / 100)。 */
  exchangeable: number;
}

/** 模拟权益，与 `rawfile/include/benefits.json` 逐字段对应。 */
export interface IncludeBenefit {
  id: string;
  name: string;
  description: string;
  coinCost: number;
  icon: string;
}

export interface CarbonIncludeRecord extends BaseRow {
  /** exchange = 积分→碳币；redeem = 碳币→权益。 */
  action: 'exchange' | 'redeem';
  /** 消耗积分（正数存储）。 */
  pointsSpent: number;
  /** 获得 / 消耗碳币数。 */
  coinAmount: number;
  /** 权益编码（redeem 时有值）。 */
  benefitId?: string;
  benefitName?: string;
  occurredAt: number;
}
