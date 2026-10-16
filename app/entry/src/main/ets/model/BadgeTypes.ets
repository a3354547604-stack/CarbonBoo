/**
 * BadgeTypes —— 徽章域类型（8 枚徽章的定义与进度口径）。
 *
 * 职责：定义徽章判定口径 `BadgeMetric`，以及静态定义 `BadgeDef` 与运行期进度 `BadgeProgress`。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §4 + §8.2。
 * 规则：**徽章一律不发积分**；未解锁也显示条件与进度条；解锁后永久保留（删记录不撤销）。
 */
export type BadgeMetric =
  | 'first_record' | 'streak' | 'total_reduction'
  | 'travel_count' | 'recycle_kg' | 'frame_count';

export interface BadgeDef {
  id: string;
  name: string;
  description: string;
  tier: 'bronze' | 'silver' | 'gold';
  icon: string;
  metric: BadgeMetric;
  threshold: number;
  order: number;
}

export interface BadgeProgress {
  badgeId: string;
  name: string;
  description: string;
  icon: string;
  unlocked: boolean;
  unlockedAt?: number;
  progress: number;
  threshold: number;
  /** 0~100。 */
  percent: number;
}
