/**
 * AiAssistService —— 端侧识图录入（创新项 Ⅱ；附录 C §23.1 的六条规则）。
 *
 * 职责与边界（逐条对应 §23.1）：
 *  ① 接口形态：`recognize(uri): Promise<AiRecognizeResult>`；
 *  ② 超时 3 秒：超时或 `recognized=false` → 页面自动关闭半模态、退回图标网格并提示
 *     「识图不可用，请手动选择」；
 *  ③ **图片不落盘、不上传**：本层只拿 uri 做一次本地推断，不读写网络（`HttpPort` 都没注入）；
 *  ④ **只给候选、必须用户确认**：返回的 `candidates` 只是候选，预填表单由页面在用户点
 *     「使用此结果」之后才做；
 *  ⑤ 本期是「接口层 + 假数据兜底」：`engine = 'mock'`（本地启发式），拿到真模型只换
 *     `AiEngine` 实现；
 *  ⑥ **不展示置信度数字或准确率**：`AiCandidate.confidence` 只用来在本地排序候选，
 *     页面渲染时不得读取它（`AiRecognizeResult.confidence` 同理）。
 *
 * 为什么把引擎做成 `AiEngine` 接口：识图是本仓库唯一「算法会被替换」的地方，
 * 用一个适配器把 NAPI 模型和本地启发式隔开，页面与测试都只依赖接口。
 */
import { AiCandidate, AiRecognizeResult } from '../model/AiTypes';
import { CategoryKey } from '../model/CarbonTypes';
import { ResourcePort } from './store/ResourcePort';
import { LiteralConstants } from '../util/AppTheme';

/** 识图引擎（可替换）。 */
export interface AiEngine {
  /** 引擎名：`mock` = 本地启发式；`napi-model` = 端侧真模型。 */
  name(): string;
  recognize(uri: string): Promise<AiRecognizeResult>;
}

/** 候选行为表（与录入页图标网格的 9 项同源，顺序即优先级）。 */
interface BehaviourSeed {
  category: CategoryKey;
  subType: string;
  label: string;
  icon: string;
}

/**
 * 本地启发式引擎（`engine = 'mock'`）。
 *
 * 诚实声明：它**不识别图像内容**，只用 uri 生成一组稳定（同一张图同一结果）、
 * 可复现的候选，用途是让「识图 → 候选 → 用户确认 → 预填」这条链路在没有模型时
 * 也能被完整走通与验收（附录 D §7）。真模型到位后替换本类即可，上层无需改动。
 */
export class MockAiEngine implements AiEngine {
  name(): string {
    return 'mock';
  }

  async recognize(uri: string): Promise<AiRecognizeResult> {
    if (uri.length === 0) {
      return { recognized: false, engine: this.name() };
    }
    const seeds: BehaviourSeed[] = MockAiEngine.seeds();
    const start: number = MockAiEngine.hash(uri) % seeds.length;
    const candidates: AiCandidate[] = [];
    let i: number = 0;
    while (i < seeds.length && candidates.length < LiteralConstants.AI_MAX_CANDIDATES) {
      const s: BehaviourSeed = seeds[(start + i) % seeds.length];
      candidates.push({
        category: s.category,
        subType: s.subType,
        // 仅用于本地排序/调试；界面禁止展示（附录 C §23.1 规则 6 / B30）
        confidence: 0.9 - i * 0.11,
      });
      i = i + 1;
    }
    const top: AiCandidate = candidates[0];
    return {
      recognized: true,
      category: top.category,
      subType: top.subType,
      confidence: top.confidence,
      candidates,
      engine: this.name(),
    };
  }

  /** 9 项候选（与录入页图标网格一致）。 */
  static seeds(): BehaviourSeed[] {
    return [
      { category: 'travel', subType: 'walk', label: '步行', icon: '🚶' },
      { category: 'travel', subType: 'bicycle', label: '骑行', icon: '🚲' },
      { category: 'travel', subType: 'bus', label: '公交', icon: '🚌' },
      { category: 'travel', subType: 'metro', label: '地铁', icon: '🚇' },
      { category: 'travel', subType: 'carpool', label: '拼车', icon: '🚗' },
      { category: 'utility', subType: 'elec_grid', label: '节电', icon: '💡' },
      { category: 'utility', subType: 'water', label: '节水', icon: '💧' },
      { category: 'recycle', subType: 'paper', label: '回收', icon: '♻️' },
      { category: 'plate', subType: 'meal', label: '光盘', icon: '🍽️' },
    ];
  }

  /** 行为中文名（页面展示候选按钮文字）。 */
  static labelOf(subType: string): string {
    const seeds: BehaviourSeed[] = MockAiEngine.seeds();
    let i: number = 0;
    while (i < seeds.length) {
      if (seeds[i].subType === subType) {
        return seeds[i].label;
      }
      i = i + 1;
    }
    return subType;
  }

  /** 稳定哈希（同一 uri 恒定，换模型前先保证可复现）。 */
  private static hash(text: string): number {
    let h: number = 5381;
    let i: number = 0;
    while (i < text.length) {
      h = (h * 33 + text.charCodeAt(i)) % 4294967296;
      i = i + 1;
    }
    return h;
  }
}

export class AiAssistService {
  private readonly resources: ResourcePort;
  private readonly engine: AiEngine;

  constructor(resources: ResourcePort, engine: AiEngine) {
    this.resources = resources;
    this.engine = engine;
  }

  /** 当前引擎名（页面据此决定是否显示「模拟识别」提示条）。 */
  engineName(): string {
    return this.engine.name();
  }

  /** 是否为模拟引擎（`engine = 'mock'` → 半模态常驻「模拟识别」提示条）。 */
  isMock(): boolean {
    return this.engine.name() === 'mock';
  }

  /**
   * 识别一个本地图片 uri。
   * @param uri 图片 uri（**只读一次像素**，不落盘、不上传）
   * @param enabled 设置页的「端侧识图」开关；关闭时直接失败，页面走手动选择
   */
  async recognize(uri: string, enabled: boolean): Promise<AiRecognizeResult> {
    if (!enabled) {
      return { recognized: false, engine: this.engine.name() };
    }
    const started: number = Date.now();
    const result: AiRecognizeResult = await this.engine.recognize(uri);
    const elapsed: number = Date.now() - started;
    if (elapsed > LiteralConstants.AI_TIMEOUT_MS) {
      return { recognized: false, engine: this.engine.name() };
    }
    return result;
  }

  /** 降级文案（附录 C §24：识图不可用，请手动选择）。 */
  static fallbackText(): string {
    return '识图不可用，请手动选择';
  }
}
