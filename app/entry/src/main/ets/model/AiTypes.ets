/**
 * AiTypes —— 端侧识图接口类型（S7 预留）。
 *
 * 职责：定义识图候选 `AiCandidate` 与识图结果 `AiRecognizeResult`。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §4。
 * ⚠️ 口径（B30）：**界面不展示置信度数字或准确率**；识图半模态必须带「模拟识别」提示条。
 *    `engine = 'mock'` 表示桩实现（图标网格降级路径）；`confidence` 仅供内部排序，
 *    不得直接渲染成百分比给人看。
 */
import { CategoryKey } from './CarbonTypes';

export interface AiCandidate {
  category: CategoryKey;
  subType: string;
  /** 仅供内部排序，不展示。 */
  confidence: number;
}

export interface AiRecognizeResult {
  recognized: boolean;
  category?: CategoryKey;
  subType?: string;
  /** 仅供内部排序，不展示。 */
  confidence?: number;
  candidates?: AiCandidate[];
  /** 'mock' = 桩实现；'napi-model' = 真实端侧模型（S7 视情况接入）。 */
  engine: string;
}
