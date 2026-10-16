/**
 * FactorLibrary —— 因子库 JSON 的**纯解析与查询**核心。
 *
 * 职责（两个）：
 *  ① `parse(json)`：把 `tests/cases/carbon-calc.json` / `APPENDIX-A §7` 的 JSON 文本
 *     解析成强类型 `FactorLibrary`（逐字段运行时校验，见 `JsonUtil`）；
 *  ② 查询：`factorOf` / `recordingFactors` / `ownFactorValue` / `points` / `limits`
 *     —— `CarbonService` 与录入表单都从这里取因子，别处不得硬编码因子值。
 *
 * ⚠️ 本文件**不读文件**（不 import resourceManager），所以能被离线 Node 逐字段复算；
 *    读 rawfile 的 I/O 在 `FactorRepository` 里。
 *
 * "31 项因子"的口径说明（重要，避免后来者数出来是 30 就对不上）：
 *  - `APPENDIX-A §7` 的 `factors` 数组实际是 **30 条**（含 10 条 `recording: false` 对照镜像）；
 *  - `tests/cases/carbon-calc.json → factors` 是同样 30 条，**另加**第 31 项
 *    `{ key: 'CAR_OWN_FACTOR', recording: false }`——它是"燃油车自身排放"这个
 *    **换算常量**（同时在 `conversions.CAR_OWN_FACTOR` 里），服务于样例 8「少开一天车」；
 *  - 因此本文件把第 31 项作为**合成因子行**（`factorKey = 'CAR_OWN_FACTOR'`）暴露给调用方，
 *    数值取自 `conversions.CAR_OWN_FACTOR`，**不重复写死**。二者永远一致。
 */
import { CategoryKey, Confidence, FactorItem } from '../model/CarbonTypes';
import { JsonArray, JsonObject } from '../util/JsonUtil';
import * as J from '../util/JsonUtil';
import {
  FactorCategoryRow,
  FactorConversions,
  FactorEquivalents,
  FactorLibrary as FactorLibraryShape,
  FactorLimits,
  FactorMeta,
  FactorPoints,
  FactorSeedRow,
  FactorSourceRow,
} from '../model/SeedTypes';

/** 合成因子行的 key：燃油车自身排放（附录 A §2.5 镜像关系）。 */
export const CAR_OWN_FACTOR_KEY: string = 'CAR_OWN_FACTOR';

export class FactorLibrary {
  private readonly metaValue: FactorMeta;
  private readonly sourceRows: FactorSourceRow[];
  private readonly categoryRows: FactorCategoryRow[];
  private readonly factorRows: FactorSeedRow[];
  private readonly conversionValues: FactorConversions;
  private readonly equivalentValues: FactorEquivalents;
  private readonly limitValues: FactorLimits;
  private readonly pointValues: FactorPoints;

  private constructor(shape: FactorLibraryShape) {
    this.metaValue = shape.meta;
    this.sourceRows = shape.sources;
    this.categoryRows = shape.categories;
    this.factorRows = shape.factors;
    this.conversionValues = shape.conversions;
    this.equivalentValues = shape.equivalents;
    this.limitValues = shape.limits;
    this.pointValues = shape.points;
  }

  /**
   * 从 JSON 文本构造（**逐字段校验**，任何缺字段/类型不对都会抛出带路径的错，
   * 而不是静默拿到 undefined 再落库成 0）。
   * @param json `carbon-factors.json` 全文
   */
  static parse(json: string): FactorLibrary {
    const root: JsonObject = J.asObject(JSON.parse(json), 'factors');
    const metaObj: JsonObject = J.asObject(J.must(root, 'meta'), 'factors.meta');
    const meta: FactorMeta = {
      version: J.str(metaObj, 'version', 'meta'),
      updatedAt: J.str(metaObj, 'updatedAt', 'meta'),
      owner: J.str(metaObj, 'owner', 'meta'),
      note: J.str(metaObj, 'note', 'meta'),
    };
    const sources: FactorSourceRow[] = FactorLibrary.readSources(J.mustArray(root, 'sources'));
    const categories: FactorCategoryRow[] = FactorLibrary.readCategories(J.mustArray(root, 'categories'));
    const factors: FactorSeedRow[] = FactorLibrary.readFactors(J.mustArray(root, 'factors'));
    const convObj: JsonObject = J.asObject(J.must(root, 'conversions'), 'factors.conversions');
    const conversions: FactorConversions = {
      AVG_ITEM_WEIGHT_KG: J.num(convObj, 'AVG_ITEM_WEIGHT_KG', 'conversions'),
      AVG_CAR_TRIP_KM: J.num(convObj, 'AVG_CAR_TRIP_KM', 'conversions'),
      KWH_PER_KG: J.num(convObj, 'KWH_PER_KG', 'conversions'),
      CAR_OWN_FACTOR: J.num(convObj, 'CAR_OWN_FACTOR', 'conversions'),
    };
    const eqObj: JsonObject = J.asObject(J.must(root, 'equivalents'), 'factors.equivalents');
    const equivalents: FactorEquivalents = {
      TREE_ABSORB_KG_PER_YEAR: J.num(eqObj, 'TREE_ABSORB_KG_PER_YEAR', 'equivalents'),
      CAR_KM_PER_KG: J.num(eqObj, 'CAR_KM_PER_KG', 'equivalents'),
      PHONE_CHARGE_KG: J.num(eqObj, 'PHONE_CHARGE_KG', 'equivalents'),
    };
    const limObj: JsonObject = J.asObject(J.must(root, 'limits'), 'factors.limits');
    const limits: FactorLimits = {
      travelKm: J.num(limObj, 'travelKm', 'limits'),
      elecKwh: J.num(limObj, 'elecKwh', 'limits'),
      waterL: J.num(limObj, 'waterL', 'limits'),
      gasM3: J.num(limObj, 'gasM3', 'limits'),
      recycleKg: J.num(limObj, 'recycleKg', 'limits'),
      plateTimes: J.num(limObj, 'plateTimes', 'limits'),
    };
    const ptObj: JsonObject = J.asObject(J.must(root, 'points'), 'factors.points');
    const points: FactorPoints = {
      perKgCo2e: J.num(ptObj, 'perKgCo2e', 'points'),
      dailyRecordCap: J.num(ptObj, 'dailyRecordCap', 'points'),
      minReductionForPoint: J.num(ptObj, 'minReductionForPoint', 'points'),
      carbonCoinRate: J.num(ptObj, 'carbonCoinRate', 'points'),
    };
    return new FactorLibrary({
      meta,
      sources,
      categories,
      factors,
      conversions,
      equivalents,
      limits,
      points,
    });
  }

  private static readSources(arr: JsonArray): FactorSourceRow[] {
    const out: FactorSourceRow[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const o: JsonObject = J.asObject(arr[i], `sources[${i}]`);
      out.push({ id: J.str(o, 'id', 'sources'), name: J.str(o, 'name', 'sources'), level: J.str(o, 'level', 'sources') });
      i = i + 1;
    }
    return out;
  }

  private static readCategories(arr: JsonArray): FactorCategoryRow[] {
    const out: FactorCategoryRow[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const o: JsonObject = J.asObject(arr[i], `categories[${i}]`);
      out.push({
        key: J.str(o, 'key', 'categories'),
        name: J.str(o, 'name', 'categories'),
        unit: J.str(o, 'unit', 'categories'),
        icon: J.str(o, 'icon', 'categories'),
        color: J.str(o, 'color', 'categories'),
        order: J.num(o, 'order', 'categories'),
      });
      i = i + 1;
    }
    return out;
  }

  private static readFactors(arr: JsonArray): FactorSeedRow[] {
    const out: FactorSeedRow[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const o: JsonObject = J.asObject(arr[i], `factors[${i}]`);
      const category: string = J.str(o, 'category', 'factors');
      const confidence: string = J.str(o, 'confidence', 'factors');
      out.push({
        category: FactorLibrary.toCategory(category),
        subType: J.str(o, 'subType', 'factors'),
        name: J.str(o, 'name', 'factors'),
        unit: J.str(o, 'unit', 'factors'),
        value: J.num(o, 'value', 'factors'),
        ownValue: J.optNum(o, 'ownValue'),
        source: J.str(o, 'source', 'factors'),
        confidence: FactorLibrary.toConfidence(confidence),
        recording: J.bool(o, 'recording', 'factors'),
      });
      i = i + 1;
    }
    return out;
  }

  // ---------------------------------------------------------------- 查询
  /** 因子库版本号（铁律 3 的快照字段 `factor_version` 取自这里）。 */
  version(): string {
    return this.metaValue.version;
  }

  /** 元信息。 */
  meta(): FactorMeta {
    return this.metaValue;
  }

  /** 全部因子行（30 条，含对照镜像）。 */
  all(): FactorItem[] {
    const out: FactorItem[] = [];
    let i: number = 0;
    while (i < this.factorRows.length) {
      out.push(this.toItem(this.factorRows[i], this.factorRows[i].subType));
      i = i + 1;
    }
    return out;
  }

  /** 可录入的因子行（`recording = true`，共 21 条）——录入向导只用这个。 */
  recordingFactors(): FactorItem[] {
    const out: FactorItem[] = [];
    let i: number = 0;
    while (i < this.factorRows.length) {
      if (this.factorRows[i].recording) {
        out.push(this.toItem(this.factorRows[i], this.factorRows[i].subType));
      }
      i = i + 1;
    }
    return out;
  }

  /**
   * 按 key 取因子。`CAR_OWN_FACTOR` 是**合成行**（取自 `conversions`，见文件头说明）。
   * @param key 因子 key，即建表 SQL 里的 `sub_type`
   */
  factorOf(key: string): FactorItem | undefined {
    if (key === CAR_OWN_FACTOR_KEY) {
      const own: FactorItem = {
        category: 'travel',
        subType: CAR_OWN_FACTOR_KEY,
        name: '燃油车自身排放',
        unit: 'km',
        value: this.conversionValues.CAR_OWN_FACTOR,
        source: 'SRC-CALC',
        confidence: 'provisional',
        recording: false,
      };
      return own;
    }
    let i: number = 0;
    while (i < this.factorRows.length) {
      if (this.factorRows[i].subType === key) {
        return this.toItem(this.factorRows[i], key);
      }
      i = i + 1;
    }
    return undefined;
  }

  /**
   * 某 factor key 的"自身排放"值（附录 A §2.5 镜像关系：净减排 = 基准 − 自身排放）。
   * `CAR_OWN_FACTOR` 与 `car` 都回落到 `conversions.CAR_OWN_FACTOR`。
   * @param key 因子 key
   */
  ownFactorValue(key: string): number | undefined {
    if (key === CAR_OWN_FACTOR_KEY || key === 'car') {
      return this.conversionValues.CAR_OWN_FACTOR;
    }
    let i: number = 0;
    while (i < this.factorRows.length) {
      if (this.factorRows[i].subType === key) {
        return this.factorRows[i].ownValue;
      }
      i = i + 1;
    }
    return undefined;
  }

  /** 因子条目总数，含合成的 `CAR_OWN_FACTOR` → **31**。 */
  totalCount(): number {
    return this.factorRows.length + 1;
  }

  /** 换算常量（`AVG_ITEM_WEIGHT_KG` / `AVG_CAR_TRIP_KM` / `KWH_PER_KG` / `CAR_OWN_FACTOR`）。 */
  conversions(): FactorConversions {
    return this.conversionValues;
  }

  /** 等效文案常量（首页与分享卡片使用）。 */
  equivalents(): FactorEquivalents {
    return this.equivalentValues;
  }

  /** 输入合理范围（超限提示但不阻断）。 */
  limits(): FactorLimits {
    return this.limitValues;
  }

  /** 积分参数（与 `tests/cases/carbon-calc.json → meta` 同源）。 */
  points(): FactorPoints {
    return this.pointValues;
  }

  /** 来源表（含 2 条 `deprecated`：已停用依据，保留追溯）。 */
  sources(): FactorSourceRow[] {
    return this.sourceRows;
  }

  /** 四大类元信息。 */
  categories(): FactorCategoryRow[] {
    return this.categoryRows;
  }

  private toItem(row: FactorSeedRow, key: string): FactorItem {
    return {
      category: row.category,
      subType: key,
      name: row.name,
      unit: row.unit,
      value: row.value,
      source: row.source,
      confidence: row.confidence,
      recording: row.recording,
    };
  }

  private static toCategory(v: string): CategoryKey {
    if (v === 'travel' || v === 'utility' || v === 'recycle' || v === 'plate') {
      return v;
    }
    throw new Error(`因子库 category 非法枚举值：${v}`);
  }

  private static toConfidence(v: string): Confidence {
    if (v === 'verified' || v === 'provisional') {
      return v;
    }
    throw new Error(`因子库 confidence 非法枚举值：${v}`);
  }
}
