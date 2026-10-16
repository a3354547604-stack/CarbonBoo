/**
 * CarbonTypes —— 碳领域核心类型（碳记录 / 因子 / 计算输入输出）。
 *
 * 职责：
 *  ① 定义碳行为大类 `CategoryKey`、可信度 `Confidence`、同步态 `SyncState` 三个枚举口径；
 *  ② 定义所有业务表的公共列 `BaseRow`（与附录 B §1.3 通用字段约定一一对应）；
 *  ③ 定义因子条目 `FactorItem`、碳记录 `CarbonRecord` 与计算输入输出
 *     `CalculateInput` / `CalculatePreview` / `SaveRecordResult`。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §4「TypeScript 模型（客户端）」——**照抄，不自由发挥**。
 * 铁律 2：减排量字段 `reductionKg` 只能由 `CarbonService.calculate()` 产出，别处不得赋值。
 * 铁律 3：`CarbonRecord` 的 `factorValue`/`factorVersion`/`factorSource`/`confidence`
 *        四字段是落库时的因子快照，因子库升级永不回写。
 */
export type CategoryKey = 'travel' | 'utility' | 'recycle' | 'plate';
export type Confidence = 'verified' | 'provisional';
export type SyncState = 'local' | 'synced' | 'pending';

/** 所有业务表的公共列（附录 B §1.3）。 */
export interface BaseRow {
  id: string;
  userId: string;
  createdAt: number;
  updatedAt: number;
  isDeleted: number;
  deviceId?: string;
  syncState: SyncState;
}

/**
 * 因子条目。数值口径以 `tests/cases/carbon-calc.json → factors` 为唯一真相源。
 * `recording = false` 的条目**不进录入表单**，只作对照表展示（附录 A §2.5 镜像关系）。
 */
export interface FactorItem {
  category: CategoryKey;
  subType: string;
  name: string;
  unit: string;
  value: number;
  source: string;
  confidence: Confidence;
  recording: boolean;
}

/** 碳记录——19 张表里的头号表 `carbon_record`。 */
export interface CarbonRecord extends BaseRow {
  category: CategoryKey;
  subType: string;
  amount: number;
  unit: string;
  occurredAt: number;
  reductionKg: number;
  factorValue: number;
  factorVersion: string;
  factorSource: string;
  confidence: Confidence;
  pointAwarded: number;
  revision: number;
  pointCapped: number;
  isAbnormal: number;
  note?: string;
}

/** 计算输入：活动量 + 发生时间（因子快照由调用方另行传入，见 `CarbonService`）。 */
export interface CalculateInput {
  category: CategoryKey;
  subType: string;
  amount: number;
  occurredAt: number;
}

/** 计算预览：应得 C 与实入 A 的完整口径，供录入向导实时展示。 */
export interface CalculatePreview {
  reductionKg: number;
  estimatedPoint: number;
  todayEarned: number;
  willBeCapped: boolean;
  actualPoint: number;
}

/** 保存结果：S2 记录闭环的返回值契约（本切片只冻结类型，不实现保存链路）。 */
export interface SaveRecordResult {
  record: CarbonRecord;
  reductionKg: number;
  pointExpected: number;
  pointAwarded: number;
  capped: boolean;
  newGoals: string[];
  newBadges: string[];
}
