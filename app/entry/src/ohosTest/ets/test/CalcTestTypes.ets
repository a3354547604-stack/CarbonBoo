/**
 * CalcTestTypes —— `tests/cases/carbon-calc.json` 基准文件的**落盘形态**类型。
 *
 * 职责：把仓库里的数值基准（唯一真相源）解析成强类型，供 L1 单测**直接逐条断言**，
 * 而不是在测试文件里重复抄一遍数字（`tests/README.md` §3 明确要求「不要重复抄数字」）。
 *
 * 基准文件如何进到测试 HAP：
 *   `tests/` 目录不进 HAP，故按 `tests/README.md` §3 的做法把基准拷进
 *   `app/entry/src/ohosTest/resources/rawfile/carbon-calc.json`，
 *   测试运行期读这份副本；它必须与 `tests/cases/carbon-calc.json` 字节一致
 *   （离线复算脚本会先比对二者再逐条复算，防止副本漂移）。
 *
 * ⚠️ 本文件**不 import 任何 ArkTS 运行时 API**（不用 `resourceManager`），
 *    读取由调用方（测试或离线脚本）把 JSON 文本传进来，因此可被离线 Node 复算。
 */
import * as J from '../../../main/ets/util/JsonUtil';
import { JsonArray, JsonObject } from '../../../main/ets/util/JsonUtil';

/** 计算参数（`meta`）：公式与常量口径的唯一声明处。 */
export interface CalcMeta {
  name: string;
  version: string;
  factorVersion: string;
  /** 基准文件自述的权威性说明（AGENTS.md §1.2 的机器可读镜像）。 */
  authority: string;
  /** 三条公式与舍入口径的原文（`rounding` 在 `formulas` 之下，不在 `meta` 直属）。 */
  formulas: CalcFormula;
  pointsPerKgCo2e: number;
  dailyRecordCap: number;
  /** 基准里写作字符串 "0.005"；解析层转 number，校验层再用 `numLike` 兜一次。 */
  minReductionForPoint: number | string;
  carbonCoinRate: number;
}

/** `meta.formulas`：三条公式 + 舍入口径。 */
export interface CalcFormula {
  reductionKg: string;
  expectedPointC: string;
  actualPointA: string;
  rounding: string;
}

/** 一条正向样例（`samples`，18 组）。 */
export interface PositiveSample {
  id: number;
  behavior: string;
  factorKey: string;
  /** 活动量，字符串形式（避免读 JSON 时就引入浮点误差）。 */
  amount: string;
  unit: string;
  reductionKg: string;
  expectedPointC: number;
  conversion?: string;
}

/** 一条封顶样例（`capSamples`，5 组）。 */
export interface CapSample {
  id: string;
  desc: string;
  todayEarnedD: string;
  expectedC: number;
  expectedActualA: number;
  capped: number;
  countsTowardCap: boolean;
  noPointRow?: boolean;
}

/** 一条边界样例（`boundarySamples`，6 条，`kind` 区分 calc / ui / rule）。 */
export interface BoundarySample {
  id: number;
  desc: string;
  kind: string;
  reductionKg?: string;
  factorKey?: string;
  amount?: string;
  expectedReductionKg?: string;
  expectedPointC?: number;
  todayEarnedD?: string;
  expectedActualA?: number;
  capped?: number;
  noPointRow?: boolean;
}

/** 一条因子基准（`factors`，30 条 + 合成的 `CAR_OWN_FACTOR` = 31 项）。 */
export interface FactorCase {
  key: string;
  category: string;
  unit: string;
  value: string;
  ownValue?: string;
  confidence: string;
  source: string;
  recording: boolean;
}

/** 一条换算规则（`conversions`，2 条）。 */
export interface ConversionCase {
  id: string;
  desc: string;
  input: Record<string, string>;
  amount: string;
  unit: string;
}

/** `rawfile/factors/carbon-factors.json` 里的单条因子（只取与基准比对的字段）。 */
export interface ParseableFactor {
  key: string;
  category: string;
  unit: string;
  value: string;
  confidence: string;
  source: string;
  recording: boolean;
}

/**
 * 解析因子库 rawfile 的 `factors` 数组。
 *
 * 注意 JSON 里字段叫 `subType`（列名口径），基准文件里叫 `key`（测试口径）——
 * 这里把 `subType` 映射成 `key`，使两者可直接逐条比对。
 * 数值统一转成字符串（`0.192` → `"0.192"`），避免与基准里的 `"0.1920"` 因浮点表示而不等。
 * @param json `carbon-factors.json` 全文
 */
export function parseFactors(json: string): ParseableFactor[] {
  const root: JsonObject = J.asObject(JSON.parse(json), 'carbon-factors');
  const arr: JsonArray = J.mustArray(root, 'factors');
  const out: ParseableFactor[] = [];
  let i: number = 0;
  while (i < arr.length) {
    const o: JsonObject = J.asObject(arr[i], `factors[${i}]`);
    out.push({
      key: J.str(o, 'subType', 'factors'),
      category: J.str(o, 'category', 'factors'),
      unit: J.str(o, 'unit', 'factors'),
      value: J.num(o, 'value', 'factors').toString(),
      confidence: J.str(o, 'confidence', 'factors'),
      source: J.str(o, 'source', 'factors'),
      recording: J.bool(o, 'recording', 'factors'),
    });
    i = i + 1;
  }
  return out;
}

/** 基准文件全文（只取本切片用到的字段；`docConflicts` 等其余字段不解析）。 */
export interface CalcBenchmark {
  meta: CalcMeta;
  constants: Record<string, string>;
  factors: FactorCase[];
  conversions: ConversionCase[];
  samples: PositiveSample[];
  capSamples: CapSample[];
  boundarySamples: BoundarySample[];
}

/**
 * 解析基准文件。
 * 逐字段运行时校验：基准文件被改错时立刻报出字段路径，而不是让测试静默变绿/变红。
 * @param json `carbon-calc.json` 全文
 */
export function parseBenchmark(json: string): CalcBenchmark {
  const root: JsonObject = J.asObject(JSON.parse(json), 'carbon-calc');
  const metaObj: JsonObject = J.asObject(J.must(root, 'meta'), 'meta');
  const formulasObj: JsonObject = J.asObject(J.must(metaObj, 'formulas'), 'meta.formulas');
  const meta: CalcMeta = {
    name: J.str(metaObj, 'name', 'meta'),
    version: J.str(metaObj, 'version', 'meta'),
    factorVersion: J.str(metaObj, 'factorVersion', 'meta'),
    authority: J.str(metaObj, 'authority', 'meta'),
    formulas: {
      reductionKg: J.str(formulasObj, 'reductionKg', 'meta.formulas'),
      expectedPointC: J.str(formulasObj, 'expectedPointC', 'meta.formulas'),
      actualPointA: J.str(formulasObj, 'actualPointA', 'meta.formulas'),
      rounding: J.str(formulasObj, 'rounding', 'meta.formulas'),
    },
    pointsPerKgCo2e: J.num(metaObj, 'pointsPerKgCo2e', 'meta'),
    dailyRecordCap: J.num(metaObj, 'dailyRecordCap', 'meta'),
    minReductionForPoint: parseNumberLike(J.str(metaObj, 'minReductionForPoint', 'meta'), 'meta.minReductionForPoint'),
    carbonCoinRate: J.num(metaObj, 'carbonCoinRate', 'meta'),
  };
  return {
    meta,
    constants: readStringMap(J.asObject(J.must(root, 'constants'), 'constants'), 'constants'),
    factors: readFactors(J.mustArray(root, 'factors')),
    conversions: readConversions(J.mustArray(root, 'conversions')),
    samples: readSamples(J.mustArray(root, 'samples')),
    capSamples: readCaps(J.mustArray(root, 'capSamples')),
    boundarySamples: readBoundaries(J.mustArray(root, 'boundarySamples')),
  };
}

/** 基准里数值有时写成字符串（如 `"0.005"`），统一转 number 并校验。 */
export function parseNumberLike(v: string, path: string): number {
  const n: number = Number.parseFloat(v);
  if (!Number.isFinite(n)) {
    throw new Error(`基准字段错误：${path} 期望可解析为数值，实际 "${v}"`);
  }
  return n;
}

function readStringMap(o: JsonObject, path: string): Record<string, string> {
  const out: Record<string, string> = {};
  const keys: string[] = Object.keys(o);
  let i: number = 0;
  while (i < keys.length) {
    const k: string = keys[i];
    out[k] = J.str(o, k, path);
    i = i + 1;
  }
  return out;
}

function readFactors(arr: JsonArray): FactorCase[] {
  const out: FactorCase[] = [];
  let i: number = 0;
  while (i < arr.length) {
    const o: JsonObject = J.asObject(arr[i], `factors[${i}]`);
    out.push({
      key: J.str(o, 'key', 'factors'),
      category: J.str(o, 'category', 'factors'),
      unit: J.str(o, 'unit', 'factors'),
      value: J.str(o, 'value', 'factors'),
      ownValue: J.optStr(o, 'ownValue'),
      confidence: J.str(o, 'confidence', 'factors'),
      source: J.str(o, 'source', 'factors'),
      recording: J.bool(o, 'recording', 'factors'),
    });
    i = i + 1;
  }
  return out;
}

function readConversions(arr: JsonArray): ConversionCase[] {
  const out: ConversionCase[] = [];
  let i: number = 0;
  while (i < arr.length) {
    const o: JsonObject = J.asObject(arr[i], `conversions[${i}]`);
    out.push({
      id: J.str(o, 'id', 'conversions'),
      desc: J.str(o, 'desc', 'conversions'),
      input: readStringMap(J.asObject(J.must(o, 'input'), `conversions[${i}].input`), 'conversions.input'),
      amount: J.str(J.asObject(J.must(o, 'expect'), `conversions[${i}].expect`), 'amount', 'conversions.expect'),
      unit: J.str(J.asObject(J.must(o, 'expect'), `conversions[${i}].expect`), 'unit', 'conversions.expect'),
    });
    i = i + 1;
  }
  return out;
}

function readSamples(arr: JsonArray): PositiveSample[] {
  const out: PositiveSample[] = [];
  let i: number = 0;
  while (i < arr.length) {
    const o: JsonObject = J.asObject(arr[i], `samples[${i}]`);
    out.push({
      id: J.num(o, 'id', 'samples'),
      behavior: J.str(o, 'behavior', 'samples'),
      factorKey: J.str(o, 'factorKey', 'samples'),
      amount: J.str(o, 'amount', 'samples'),
      unit: J.str(o, 'unit', 'samples'),
      reductionKg: J.str(o, 'expectedReductionKg', 'samples'),
      expectedPointC: J.num(o, 'expectedPointC', 'samples'),
      conversion: J.optStr(o, 'conversion'),
    });
    i = i + 1;
  }
  return out;
}

function readCaps(arr: JsonArray): CapSample[] {
  const out: CapSample[] = [];
  let i: number = 0;
  while (i < arr.length) {
    const o: JsonObject = J.asObject(arr[i], `capSamples[${i}]`);
    out.push({
      id: J.str(o, 'id', 'capSamples'),
      desc: J.str(o, 'desc', 'capSamples'),
      todayEarnedD: J.str(o, 'todayEarnedD', 'capSamples'),
      expectedC: J.num(o, 'expectedC', 'capSamples'),
      expectedActualA: J.num(o, 'expectedActualA', 'capSamples'),
      capped: J.num(o, 'capped', 'capSamples'),
      countsTowardCap: J.bool(o, 'countsTowardCap', 'capSamples'),
      noPointRow: J.optBool(o, 'noPointRow'),
    });
    i = i + 1;
  }
  return out;
}

function readBoundaries(arr: JsonArray): BoundarySample[] {
  const out: BoundarySample[] = [];
  let i: number = 0;
  while (i < arr.length) {
    const o: JsonObject = J.asObject(arr[i], `boundarySamples[${i}]`);
    out.push({
      id: J.num(o, 'id', 'boundarySamples'),
      desc: J.str(o, 'desc', 'boundarySamples'),
      kind: J.str(o, 'kind', 'boundarySamples'),
      reductionKg: J.optStr(o, 'reductionKg'),
      factorKey: J.optStr(o, 'factorKey'),
      amount: J.optStr(o, 'amount'),
      expectedReductionKg: J.optStr(o, 'expectedReductionKg'),
      expectedPointC: J.optNum(o, 'expectedPointC'),
      todayEarnedD: J.optStr(o, 'todayEarnedD'),
      expectedActualA: J.optNum(o, 'expectedActualA'),
      capped: J.optNum(o, 'capped'),
      noPointRow: J.optBool(o, 'noPointRow'),
    });
    i = i + 1;
  }
  return out;
}
