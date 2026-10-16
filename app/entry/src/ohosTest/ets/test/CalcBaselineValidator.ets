/**
 * CalcBaselineValidator —— 把 `tests/cases/carbon-calc.json` 基准**逐条**在 `CarbonCalc` 上复算，
 * 返回结构化的差异清单。
 *
 * 职责：
 *  ① 正向样例（18 组）：`减排量 = round_half_up(活动量 × 因子值, 4)`、`应得 C = round_half_up(减排量 × 100, 0)`；
 *  ② 封顶样例（5 组）：`实入 A = max(0, min(C, 200 − D))`、`capped` 标记、`< 0.005 kg` 不生成流水；
 *  ③ 边界样例（21/22/23）：减排量 0.0049 与 0.005 的分界、供暖 30 m²·月 应得 9300 实入 200；
 *  ④ 换算规则（2 条）：少开一天车、回收按件；
 *  ⑤ 因子表自检：30 条基准因子 vs `rawfile/factors/carbon-factors.json` 的 30 条逐条一致，
 *     加上合成的 `CAR_OWN_FACTOR` 共 **31 项**。
 *
 * 为什么独立于 hypium 测试文件：本模块**不 import hypium、不 import ArkTS 运行时 API**，
 * 因此同一份校验逻辑既能被 `CalcSamples.test.ets`（真机/hypium）调用，
 * 也能被 `esbuild + Node` 离线脚本调用 —— 本机无设备时，离线复算是唯一能真实执行它的途径。
 *
 * 返回值刻意做成「差异清单」而非「直接抛错」：这样离线脚本能一次打印全部不一致项，
 * 而不是撞到第一条就退出。
 */
import { CarbonCalc, FactorSnapshot } from '../../../main/ets/service/CarbonCalc';
import { CarbonService } from '../../../main/ets/service/CarbonService';
import { CategoryKey } from '../../../main/ets/model/CarbonTypes';
import {
  CalcBenchmark,
  CapSample,
  ConversionCase,
  FactorCase,
  PositiveSample,
} from './CalcTestTypes';

/** 一条不一致。 */
export interface Mismatch {
  /** 用例标识，如 `sample#9` / `cap-1` / `boundary#23`。 */
  scope: string;
  /** 校验项名称，如 `reductionKg` / `expectedPointC` / `actualPoint`。 */
  field: string;
  expected: string;
  actual: string;
}

/** 复算报告。 */
export class ValidationReport {
  readonly checked: number;
  readonly mismatches: Mismatch[];

  constructor(checked: number, mismatches: Mismatch[]) {
    this.checked = checked;
    this.mismatches = mismatches;
  }

  /** 是否全部一致。 */
  passed(): boolean {
    return this.mismatches.length === 0;
  }

  /** 人可读的单行摘要。 */
  summary(): string {
    return this.passed()
      ? `全部一致：共复算 ${this.checked} 个断言点`
      : `发现 ${this.mismatches.length} 处不一致（共复算 ${this.checked} 个断言点）`;
  }
}

/**
 * `round_half_up(x, places)` 的参考实现（**独立于被测代码**）。
 *
 * 输入是十进制**字符串**，全程整数缩放，无二进制浮点参与 —— 这样它既验证
 * `DecimalUtil`/`CarbonCalc` 的数值结果，又能独立证明"基准里写的那个 4 位小数"
 * 确实是按 half-up 算出来的（而不是被实现的 bug 牵着走）。
 */
function referenceRoundHalfUp(x: string, places: number): string {
  const neg: boolean = x.charAt(0) === '-';
  const body: string = neg ? x.substring(1) : x;
  const dot: number = body.indexOf('.');
  const intPart: string = dot < 0 ? body : body.substring(0, dot);
  const fracPart: string = dot < 0 ? '' : body.substring(dot + 1);
  // 统一按 6 位小数缩放（与项目 SCALE 一致：因子存 6 位、减排量存 4 位）
  const scaledFrac: string = (fracPart + '000000').substring(0, 6);
  const scaled: number = Number.parseInt(intPart + scaledFrac, 10);
  // "保留 places 位" = 在 6 位缩放整数上按 1e(6-places) 量化，半值远离 0
  const q: number = 10 ** (6 - places);
  const rounded: number = Math.floor(scaled / q + 0.5) * q;
  const digits: string = `${rounded}`.padStart(7, '0');
  const ip: string = digits.substring(0, digits.length - 6);
  const fp: string = digits.substring(digits.length - 6);
  return `${neg ? '-' : ''}${ip}.${fp.substring(0, places)}`;
}

/** 数值 → 固定 4 位小数字符串（比对用，避免浮点尾数干扰）。 */
function fixed4(v: number): string {
  return v.toFixed(4);
}

/**
 * 基准字段的「数值 或 数值字符串」统一取数（**本文件自足，不依赖解析层的转换**）。
 *
 * 为什么必须在这里再做一次：基准 JSON 里数值有两种写法 ——
 * `pointsPerKgCo2e: 100`（number）与 `minReductionForPoint: "0.005"`（**字符串**）。
 * `CalcTestTypes.parseBenchmark` 会把后者转成 number，但校验逻辑不该依赖那一步：
 * 一旦解析层出问题（漏编译、离线脚本跳过转换、字段被改成别的写法），
 * 传进来的就是字符串，`Dec.from("0.005")` 会抛「只接受有限数」，
 * 于是"校验器"变成"崩溃器"——这是本切片实测踩到过的坑。
 * 这里按运行期类型分派：number 直接用；string 才 parseFloat；两条调用路径结果一致。
 * @param v 基准字段原值
 * @param path 出错时用于定位的字段路径
 */
function numLike(v: number | string, path: string): number {
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) {
      throw new Error(`基准字段错误：${path} 期望有限数值，实际 ${v}`);
    }
    return v;
  }
  const n: number = Number.parseFloat(v);
  if (!Number.isFinite(n)) {
    throw new Error(`基准字段错误：${path} 期望可解析为数值，实际 "${v}"`);
  }
  return n;
}

export class CalcBaselineValidator {
  /**
   * 逐条复算基准。
   * @param bench 解析后的基准
   * @param appFactors `rawfile/factors/carbon-factors.json` 的因子条目（30 条），用于因子表交叉校验；
   *                   传空数组则跳过该项
   */
  static run(bench: CalcBenchmark, appFactors: FactorCase[]): ValidationReport {
    const mismatches: Mismatch[] = [];
    let checked: number = 0;

    // ---------------- 1) 18 组正向样例 ----------------
    let i: number = 0;
    while (i < bench.samples.length) {
      const s: PositiveSample = bench.samples[i];
      const scope: string = `sample#${s.id}`;
      const amount: number = Number.parseFloat(s.amount);
      const factorValue: number = Number.parseFloat(CalcBaselineValidator.factorValueOf(bench, s.factorKey));

      const reduction: number = CarbonCalc.reductionOf(amount, factorValue);
      checked = checked + 1;
      if (fixed4(reduction) !== fixed4(Number.parseFloat(s.reductionKg))) {
        mismatches.push({
          scope,
          field: 'reductionKg',
          expected: fixed4(Number.parseFloat(s.reductionKg)),
          actual: fixed4(reduction),
        });
      }

      const expectedC: number = CarbonCalc.expectedPointOf(reduction);
      checked = checked + 1;
      if (expectedC !== s.expectedPointC) {
        mismatches.push({
          scope,
          field: 'expectedPointC',
          expected: `${s.expectedPointC}`,
          actual: `${expectedC}`,
        });
      }

      // 独立参考实现交叉验证减排量（不经过被测代码）
      const ref: string = referenceRoundHalfUp(
        CalcBaselineValidator.decimalProduct(s.amount, CalcBaselineValidator.factorValueOf(bench, s.factorKey)),
        4
      );
      checked = checked + 1;
      if (ref !== fixed4(Number.parseFloat(s.reductionKg))) {
        mismatches.push({
          scope,
          field: 'reductionKg(参考实现)',
          expected: fixed4(Number.parseFloat(s.reductionKg)),
          actual: ref,
        });
      }

      // 生产路径交叉验证：经 `CarbonService.calculate()`（铁律 2 的唯一入口）走一遍，
      // 断言它与直调 `CarbonCalc` 得到同一个数 —— 防止"唯一入口"与算数核心分叉。
      const viaSvc: number[] = CalcBaselineValidator.viaService(
        CalcBaselineValidator.categoryOf(appFactors, bench, s.factorKey),
        s.factorKey,
        amount,
        factorValue,
        bench.meta.factorVersion,
        'SRC',
        'provisional',
        0
      );
      checked = checked + 1;
      if (fixed4(viaSvc[0]) !== fixed4(reduction)) {
        mismatches.push({
          scope,
          field: 'reductionKg(CarbonService 与 CarbonCalc 不一致)',
          expected: fixed4(reduction),
          actual: fixed4(viaSvc[0]),
        });
      }
      checked = checked + 1;
      if (viaSvc[1] !== expectedC) {
        mismatches.push({
          scope,
          field: 'expectedPointC(CarbonService 与 CarbonCalc 不一致)',
          expected: `${expectedC}`,
          actual: `${viaSvc[1]}`,
        });
      }
      i = i + 1;
    }

    // ---------------- 2) 5 组封顶样例 ----------------
    let k: number = 0;
    while (k < bench.capSamples.length) {
      const c: CapSample = bench.capSamples[k];
      const scope: string = `${c.id}`;
      const d: number = Number.parseFloat(c.todayEarnedD);
      // 用确定性输入复现 (C, A) 三元组：A 公式必须按 countsTowardCap 决定 D 的参与方式。
      const dEffective: number = c.countsTowardCap ? d : 0;
      const actual: number = CarbonCalc.actualPointOf(c.expectedC, dEffective, bench.meta.dailyRecordCap);
      checked = checked + 1;
      if (actual !== c.expectedActualA) {
        mismatches.push({
          scope,
          field: 'actualPointA',
          expected: `${c.expectedActualA}`,
          actual: `${actual}`,
        });
      }
      const capped: number = actual < c.expectedC ? 1 : 0;
      checked = checked + 1;
      if (capped !== c.capped) {
        mismatches.push({ scope, field: 'capped', expected: `${c.capped}`, actual: `${capped}` });
      }
      // noPointRow 样例：C = 0 → 不生成流水
      if (c.noPointRow === true) {
        checked = checked + 1;
        if (c.expectedC !== 0) {
          mismatches.push({
            scope,
            field: 'noPointRow 要求 C=0',
            expected: '0',
            actual: `${c.expectedC}`,
          });
        }
      }
      k = k + 1;
    }

    // ---------------- 3) 边界样例 21/22/23 ----------------
    let b: number = 0;
    while (b < bench.boundarySamples.length) {
      const bd = bench.boundarySamples[b];
      if (bd.kind === 'calc' && bd.reductionKg !== undefined && bd.expectedPointC !== undefined) {
        const scope: string = `boundary#${bd.id}`;
        const red: number = Number.parseFloat(bd.reductionKg);
        const pointC: number = CarbonCalc.expectedPointOf(red);
        checked = checked + 1;
        if (pointC !== bd.expectedPointC) {
          mismatches.push({
            scope,
            field: 'expectedPointC',
            expected: `${bd.expectedPointC}`,
            actual: `${pointC}`,
          });
        }
        const required: boolean = CarbonCalc.isPointRequired(red, numLike(bench.meta.minReductionForPoint, 'meta.minReductionForPoint'));
        const expectRequired: boolean = bd.noPointRow !== true;
        checked = checked + 1;
        if (required !== expectRequired) {
          mismatches.push({
            scope,
            field: 'noPointRow(不生成流水)',
            expected: `${!expectRequired}`,
            actual: `${!required}`,
          });
        }
      }
      if (bd.kind === 'calc' && bd.factorKey !== undefined && bd.amount !== undefined && bd.expectedReductionKg !== undefined) {
        const scope: string = `boundary#${bd.id}`;
        const red: number = CarbonCalc.reductionOf(
          Number.parseFloat(bd.amount),
          Number.parseFloat(CalcBaselineValidator.factorValueOf(bench, bd.factorKey))
        );
        checked = checked + 1;
        if (fixed4(red) !== fixed4(Number.parseFloat(bd.expectedReductionKg))) {
          mismatches.push({
            scope,
            field: 'reductionKg',
            expected: fixed4(Number.parseFloat(bd.expectedReductionKg)),
            actual: fixed4(red),
          });
        }
        if (bd.expectedActualA !== undefined) {
          const d: number = bd.todayEarnedD === undefined ? 0 : Number.parseFloat(bd.todayEarnedD);
          const actual: number = CarbonCalc.actualPointOf(bd.expectedPointC === undefined ? 0 : bd.expectedPointC, d, bench.meta.dailyRecordCap);
          checked = checked + 1;
          if (actual !== bd.expectedActualA) {
            mismatches.push({
              scope,
              field: 'actualPointA',
              expected: `${bd.expectedActualA}`,
              actual: `${actual}`,
            });
          }
        }
      }
      b = b + 1;
    }

    // ---------------- 4) 2 条换算规则 ----------------
    let n: number = 0;
    while (n < bench.conversions.length) {
      const cv: ConversionCase = bench.conversions[n];
      const scope: string = `conversion:${cv.id}`;
      const keys: string[] = Object.keys(cv.input);
      let produced: number = -1;
      if (cv.id === 'car-free-days') {
        produced = CarbonCalc.amountOfCarFreeDays(
          Number.parseFloat(cv.input['days']),
          Number.parseFloat(cv.input['kmPerDay'])
        );
      } else if (cv.id === 'recycle-by-piece') {
        produced = CarbonCalc.amountOfRecyclePieces(
          Number.parseFloat(cv.input['pieces']),
          Number.parseFloat(cv.input['kgPerPiece'])
        );
      }
      checked = checked + 1;
      if (produced < 0) {
        mismatches.push({ scope, field: 'conversion 未被覆盖', expected: cv.id, actual: keys.join(',') });
      } else if (fixed4(produced) !== fixed4(Number.parseFloat(cv.amount))) {
        mismatches.push({
          scope,
          field: 'amount',
          expected: fixed4(Number.parseFloat(cv.amount)),
          actual: fixed4(produced),
        });
      }
      n = n + 1;
    }

    // ---------------- 5) 因子表交叉校验 + 31 项计数 ----------------
    // 口径：基准 `factors` 是 30 条（含 10 条 recording:false 对照镜像）；
    // `appFactors` 取 `rawfile/factors/carbon-factors.json` 的 30 条，与基准逐条对应。
    // 第 **31 项** 是合成的 `CAR_OWN_FACTOR`（A §2.5 镜像常量），不在 rawfile 的 factors 数组里，
    // 故这里对 rawfile 的期望条数是 30；第 31 项单独在下面校验。
    const BENCH_FACTOR_ROWS: number = 30;
    if (appFactors.length > 0) {
      checked = checked + 1;
      if (appFactors.length !== BENCH_FACTOR_ROWS) {
        mismatches.push({
          scope: 'factors',
          field: 'rawfile 因子条数',
          expected: `${BENCH_FACTOR_ROWS}`,
          actual: `${appFactors.length}`,
        });
      }
      checked = checked + 1;
      if (bench.factors.length !== BENCH_FACTOR_ROWS + 1) {
        mismatches.push({
          scope: 'factors',
          field: '基准因子条数（30 行 + 合成 CAR_OWN_FACTOR = 31 项）',
          expected: `${BENCH_FACTOR_ROWS + 1}`,
          actual: `${bench.factors.length}`,
        });
      }
      let f: number = 0;
      while (f < appFactors.length) {
        const got: FactorCase = appFactors[f];
        const want: FactorCase | undefined = CalcBaselineValidator.findFactor(bench.factors, got.key);
        const scope: string = `factor:${got.key}`;
        checked = checked + 1;
        if (want === undefined) {
          mismatches.push({ scope, field: '基准里缺该因子', expected: got.key, actual: 'undefined' });
        } else {
          // 数值字段按数值比对：基准写 "0.1920"、因子库 JSON 写 0.192 —— 二者是同一个数，
          // 不该因为小数位写法不同而报不一致（其余字段仍是字符串精确比对）。
          const fields: string[] = ['category', 'unit', 'confidence', 'source'];
          let x: number = 0;
          while (x < fields.length) {
            const fld: string = fields[x];
            const a: string = CalcBaselineValidator.factorField(want, fld);
            const bb: string = CalcBaselineValidator.factorField(got, fld);
            checked = checked + 1;
            if (a !== bb) {
              mismatches.push({ scope, field: fld, expected: a, actual: bb });
            }
            x = x + 1;
          }
          checked = checked + 1;
          if (fixed4(Number.parseFloat(want.value)) !== fixed4(Number.parseFloat(got.value))) {
            mismatches.push({
              scope,
              field: 'value',
              expected: want.value,
              actual: got.value,
            });
          }
          checked = checked + 1;
          if (want.recording !== got.recording) {
            mismatches.push({
              scope,
              field: 'recording',
              expected: `${want.recording}`,
              actual: `${got.recording}`,
            });
          }
        }
        f = f + 1;
      }
      // 第 31 项：合成的 CAR_OWN_FACTOR == conversions.CAR_OWN_FACTOR
      checked = checked + 1;
      const ownInConversions: number = Number.parseFloat(
        CalcBaselineValidator.constantOf(bench, 'CAR_OWN_FACTOR')
      );
      const ownAsFactor: number = Number.parseFloat(
        CalcBaselineValidator.factorValueOf(bench, 'CAR_OWN_FACTOR')
      );
      if (fixed4(ownInConversions) !== fixed4(ownAsFactor)) {
        mismatches.push({
          scope: 'CAR_OWN_FACTOR',
          field: '合成因子值 == conversions 值',
          expected: fixed4(ownInConversions),
          actual: fixed4(ownAsFactor),
        });
      }
      // 镜像常量值必须与 A §2.5 写死的 0.1920 一致（样例 8「少开一天车」依赖它）
      checked = checked + 1;
      if (fixed4(ownAsFactor) !== fixed4(0.1920)) {
        mismatches.push({
          scope: 'CAR_OWN_FACTOR',
          field: '镜像常量值（A §2.5）',
          expected: fixed4(0.1920),
          actual: fixed4(ownAsFactor),
        });
      }
    }

    return new ValidationReport(checked, mismatches);
  }

  /**
   * 走一次 `CarbonService.calculate()`（铁律 2 的唯一入口），返回减排量与应得 C。
   * 与 `CarbonCalc` 直调互为交叉验证：前者是产品路径，后者是算数核心。
   */
  static viaService(
    category: CategoryKey,
    subType: string,
    amount: number,
    factorValue: number,
    factorVersion: string,
    factorSource: string,
    confidence: string,
    todayRecordPoint: number
  ): number[] {
    const factor: FactorSnapshot = { factorValue, factorVersion, factorSource, confidence };
    const r = CarbonService.calculate(
      { category, subType, amount, occurredAt: 1767225600000 },
      factor,
      { todayRecordPoint }
    );
    return [r.reductionKg, r.expectedPoint, r.actualPoint];
  }

  /**
   * 由因子 key 反查行为大类（`CarbonService.calculate` 只把它用于异常范围判定）。
   * 优先查因子库 rawfile；`CAR_OWN_FACTOR` 这类合成常量不在因子表里，回落到 `travel`。
   * @param appFactors 因子库条目
   * @param bench 基准
   * @param key 因子 key
   */
  static categoryOf(appFactors: FactorCase[], bench: CalcBenchmark, key: string): CategoryKey {
    let i: number = 0;
    while (i < appFactors.length) {
      if (appFactors[i].key === key) {
        return CalcBaselineValidator.toCategory(appFactors[i].category);
      }
      i = i + 1;
    }
    let j: number = 0;
    while (j < bench.factors.length) {
      if (bench.factors[j].key === key) {
        return CalcBaselineValidator.toCategory(bench.factors[j].category);
      }
      j = j + 1;
    }
    return 'travel';
  }

  private static toCategory(v: string): CategoryKey {
    if (v === 'travel' || v === 'utility' || v === 'recycle' || v === 'plate') {
      return v;
    }
    throw new Error(`因子库 category 非法枚举值：${v}`);
  }

  /** 封顶公式的公开入口（转发到 `CarbonCalc.actualPointOf`，供离线脚本按 cap 口径逐条打印）。 */
  static actualPointOfPublic(expectedPoint: number, todayRecordPoint: number, dailyCap: number): number {
    return CarbonCalc.actualPointOf(expectedPoint, todayRecordPoint, dailyCap);
  }

  /** 基准里的因子值（字符串）；`CAR_OWN_FACTOR` 从 `constants` 取，与 `conversions` 同源。 */
  static factorValueOf(bench: CalcBenchmark, key: string): string {
    let i: number = 0;
    while (i < bench.factors.length) {
      if (bench.factors[i].key === key) {
        return bench.factors[i].value;
      }
      i = i + 1;
    }
    const direct: string = CalcBaselineValidator.constantOf(bench, key);
    if (direct.length > 0) {
      return direct;
    }
    throw new Error(`基准里找不到因子 key：${key}`);
  }

  /** 从 `constants` 取常量（不存在返回空串）。 */
  static constantOf(bench: CalcBenchmark, key: string): string {
    const v: string | undefined = bench.constants[key];
    return v === undefined ? '' : v;
  }

  private static findFactor(list: FactorCase[], key: string): FactorCase | undefined {
    let i: number = 0;
    while (i < list.length) {
      if (list[i].key === key) {
        return list[i];
      }
      i = i + 1;
    }
    return undefined;
  }

  private static factorField(f: FactorCase, field: string): string {
    if (field === 'category') {
      return f.category;
    }
    if (field === 'unit') {
      return f.unit;
    }
    if (field === 'value') {
      return f.value;
    }
    if (field === 'confidence') {
      return f.confidence;
    }
    if (field === 'source') {
      return f.source;
    }
    return '';
  }

  /**
   * 十进制乘法（字符串输入、字符串输出，**不经过浮点**），用于独立参考实现。
   * 只做"整数 × 6 位小数"这一类本项目实际用到的乘法：把两数各按 6 位小数缩放成整数再相乘。
   */
  static decimalProduct(a: string, b: string): string {
    const ai: number = CalcBaselineValidator.scaled(a, 6);
    const bi: number = CalcBaselineValidator.scaled(b, 6);
    // (ai / 1e6) × (bi / 1e6) = (ai × bi) / 1e12 → 再乘 1e6 得到"真实值 × 1e6"
    const product: number = (ai * bi) / 1000000;
    return CalcBaselineValidator.unscaled(product, 6);
  }

  private static scaled(s: string, places: number): number {
    const neg: boolean = s.charAt(0) === '-';
    const body: string = neg ? s.substring(1) : s;
    const dot: number = body.indexOf('.');
    const intPart: string = dot < 0 ? body : body.substring(0, dot);
    const frac: string = dot < 0 ? '' : body.substring(dot + 1);
    const padded: string = (frac + '000000').substring(0, places);
    const v: number = Number.parseInt(intPart + padded, 10);
    return neg ? -v : v;
  }

  private static unscaled(v: number, places: number): string {
    const neg: boolean = v < 0;
    const abs: number = Math.abs(v);
    const digits: string = `${abs}`.padStart(places + 1, '0');
    const ip: string = digits.substring(0, digits.length - places);
    const fp: string = digits.substring(digits.length - places);
    return `${neg ? '-' : ''}${ip}.${fp}`;
  }
}
