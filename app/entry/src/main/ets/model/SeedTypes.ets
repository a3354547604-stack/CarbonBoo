/**
 * SeedTypes —— rawfile 静态字典种子的**落盘形态**类型。
 *
 * 职责：为 `rawfile/` 下 7 份种子 JSON 各定义一个"逐字段对应"的接口，
 * 供 `SeedRepository` 解析后写库。这些类型刻意与 `model/*Types.ets` 分开：
 *  - `model/*` 是**运行期**形态（已转换成 number / 数组，字段对齐表列）；
 *  - 本文件是**磁盘**形态（JSON 原始写法：金额是 number，`subTypes`/`tags` 是数组，
 *    `order` 是 JSON 关键字同名键），两者之间的换算集中在 `SeedRepository` 一处。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §8 与 `docs/APPENDIX-A-carbon-factors.md` §7。
 */
import { CategoryKey, Confidence } from './CarbonTypes';
import { GoalMetric, GoalPeriod, GoalTier } from './GoalTypes';
import { BadgeMetric } from './BadgeTypes';
import { ScienceCategory } from './ScienceTypes';

/** 因子库来源表条目（A §7 `sources`）。 */
export interface FactorSourceRow {
  id: string;
  name: string;
  /** verified | provisional | deprecated（`deprecated` = 已停用依据，保留追溯）。 */
  level: string;
}

/** 因子库大类条目（A §7 `categories`）。 */
export interface FactorCategoryRow {
  key: string;
  name: string;
  unit: string;
  icon: string;
  color: string;
  order: number;
}

/** 因子库因子条目（A §7 `factors`）——与 `FactorItem` 对应，额外带来源与名称。 */
export interface FactorSeedRow {
  category: CategoryKey;
  subType: string;
  name: string;
  unit: string;
  value: number;
  /** 对照行的"自身排放"值（A §2.5 镜像关系用），仅出行类有。 */
  ownValue?: number;
  source: string;
  confidence: Confidence;
  recording: boolean;
}

/** 因子库换算常量（A §7 `conversions`）。 */
export interface FactorConversions {
  AVG_ITEM_WEIGHT_KG: number;
  AVG_CAR_TRIP_KM: number;
  KWH_PER_KG: number;
  CAR_OWN_FACTOR: number;
}

/** 因子库等效文案常量（A §7 `equivalents`，首页与分享卡片使用）。 */
export interface FactorEquivalents {
  TREE_ABSORB_KG_PER_YEAR: number;
  CAR_KM_PER_KG: number;
  PHONE_CHARGE_KG: number;
}

/** 因子库输入合理范围（A §7 `limits`，超限提示但不阻断）。 */
export interface FactorLimits {
  travelKm: number;
  elecKwh: number;
  waterL: number;
  gasM3: number;
  recycleKg: number;
  plateTimes: number;
}

/** 因子库积分参数（A §7 `points`）——与 `tests/cases/carbon-calc.json → meta` 同源。 */
export interface FactorPoints {
  perKgCo2e: number;
  dailyRecordCap: number;
  minReductionForPoint: number;
  carbonCoinRate: number;
}

/** 因子库元信息（A §7 `meta`）。 */
export interface FactorMeta {
  version: string;
  updatedAt: string;
  owner: string;
  note: string;
}

/** `rawfile/factors/carbon-factors.json` 全文形态。 */
export interface FactorLibrary {
  meta: FactorMeta;
  sources: FactorSourceRow[];
  categories: FactorCategoryRow[];
  factors: FactorSeedRow[];
  conversions: FactorConversions;
  equivalents: FactorEquivalents;
  limits: FactorLimits;
  points: FactorPoints;
}

/** `rawfile/goals/goal-defs.json` 单条（JSON 里的小类数组叫 `subTypes`）。 */
export interface GoalSeedRow {
  id: string;
  name: string;
  tier: GoalTier;
  period: GoalPeriod;
  metric: GoalMetric;
  category?: CategoryKey;
  subTypes?: string[];
  unit?: string;
  threshold: number;
  reward: number;
  icon: string;
  order: number;
}

/** `rawfile/badges/badge-defs.json` 单条。 */
export interface BadgeSeedRow {
  id: string;
  name: string;
  description: string;
  tier: 'bronze' | 'silver' | 'gold';
  icon: string;
  metric: BadgeMetric;
  threshold: number;
  order: number;
}

/** `rawfile/shop/shop-items.json` 单条（JSON 用驼峰 `onShelf` / `isDefaultFree`）。 */
export interface ShopSeedRow {
  id: string;
  section: 'frame' | 'theme';
  name: string;
  description?: string;
  price: number;
  icon: string;
  order: number;
  onShelf: number;
  isDefaultFree: number;
}

/** `rawfile/appearance/avatars.json` 单条（全部免费）。 */
export interface AvatarSeedRow {
  id: string;
  name: string;
  icon: string;
  default: boolean;
}

/** `rawfile/include/benefits.json` 单条（模拟权益）。 */
export interface BenefitSeedRow {
  id: string;
  name: string;
  description: string;
  coinCost: number;
  icon: string;
}

/** `rawfile/science/science-index.json` 单条。 */
export interface ScienceSeedRow {
  id: string;
  title: string;
  category: ScienceCategory;
  summary: string;
  cover: string;
  readMinutes: number;
  tags: string[];
  order: number;
}
