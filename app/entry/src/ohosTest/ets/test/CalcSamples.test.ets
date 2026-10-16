/**
 * CalcSamples —— L1 单测：碳计算与封顶样例（`tests/cases/carbon-calc.json` 逐条）。
 *
 * 职责：把数值基准文件**原样喂进**计算实现并逐条断言：
 *  - `samples`（18 组正向）：`reductionKg`（4 位小数）与应得 C；
 *  - `capSamples`（5 组封顶）：实入 A、`capped` 标记、`< 0.005 kg` 不生成流水；
 *  - `boundarySamples`（21/22/23）：0.0049 与 0.005 的分界、供暖 30 m²·月 封顶到 200；
 *  - `conversions`（2 条）：少开一天车、回收按件。
 *
 * **不在测试里重复抄数字**（`tests/README.md` §3 的硬要求）：
 *  基准文件按 `tests/README.md` §3 拷进 `app/entry/src/ohosTest/resources/rawfile/carbon-calc.json`，
 *  测试运行期从 rawfile 读它。副本与 `tests/cases/carbon-calc.json` 必须字节一致
 *  （离线复算脚本会先比对 md5 再复算，防副本漂移）。
 *
 * 校验逻辑在 `CalcBaselineValidator`（无 hypium、无 ArkTS 运行时依赖），
 * 因此同一份逻辑也能被 `esbuild + Node` 离线执行 —— 本机没有真机/模拟器时，
 * 离线复算是唯一能真正运行它的途径（如实标注，不冒充"L1 全绿"）。
 *
 * 本机限制（已知，不隐瞒）：这些用例随 `ohosTest` 目标**编译通过**；
 * 但 hypium 需要由 SDK 的 Previewer 进程驱动，该二进制与本机 glibc 不兼容
 * （`pthread_mutex_lock` 断言崩溃 / 超时），**这些断言在本机未被真实执行过**。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { util } from '@kit.ArkTS';
import { CalcBaselineValidator, ValidationReport } from './CalcBaselineValidator';
import { CalcBenchmark, FactorCase, ParseableFactor, parseBenchmark, parseFactors } from './CalcTestTypes';
import { CarbonCalc } from '../../../main/ets/service/CarbonCalc';
import { CarbonService } from '../../../main/ets/service/CarbonService';

/** 基准副本路径（相对 `resources/rawfile/`）。 */
const BENCH_RAW: string = 'carbon-calc.json';
/** 因子库路径（与 App 主代码读的是同一份）。 */
const FACTOR_RAW: string = 'factors/carbon-factors.json';
const VERSION: string = 'CF-2026.2';

/** 读 rawfile 全文。 */
async function readRaw(path: string): Promise<string> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const bytes: Uint8Array = await delegator.getAppContext().resourceManager.getRawFileContent(path);
  return new util.TextDecoder().decodeToString(bytes);
}

/** 把因子库 rawfile 解析成与基准可比对的形态（只取比对需要的字段）。 */
function factorsOf(json: string): FactorCase[] {
  const parsed: ParseableFactor[] = parseFactors(json);
  const out: FactorCase[] = [];
  let i: number = 0;
  while (i < parsed.length) {
    out.push({
      key: parsed[i].key,
      category: parsed[i].category,
      unit: parsed[i].unit,
      value: parsed[i].value,
      confidence: parsed[i].confidence,
      source: parsed[i].source,
      recording: parsed[i].recording,
    });
    i = i + 1;
  }
  return out;
}

export default function calcSamples(): void {
  describe('CalcSamples', () => {
    it('基准逐条复算：18 组正向 + 5 组封顶 + 边界 21/22/23 + 2 条换算 + 31 项因子', 0, async () => {
      const benchJson: string = await readRaw(BENCH_RAW);
      const bench: CalcBenchmark = parseBenchmark(benchJson);

      // 基准自检：条数必须与文档一致，防止"基准被删了几组还照样全绿"
      expect(bench.samples.length).assertEqual(18);
      expect(bench.capSamples.length).assertEqual(5);
      expect(bench.conversions.length).assertEqual(2);
      expect(bench.factors.length).assertEqual(30);
      expect(bench.meta.factorVersion).assertEqual(VERSION);
      expect(bench.meta.dailyRecordCap).assertEqual(200);
      expect(bench.meta.pointsPerKgCo2e).assertEqual(100);

      const appFactors: FactorCase[] = factorsOf(await readRaw(FACTOR_RAW));
      expect(appFactors.length).assertEqual(30);

      const report: ValidationReport = CalcBaselineValidator.run(bench, appFactors);
      // 失败时把全部不一致项拼进断言消息，便于定位（不是只报第一条）
      let detail: string = '';
      let i: number = 0;
      while (i < report.mismatches.length) {
        detail = `${detail}\n${report.mismatches[i].scope}.${report.mismatches[i].field}: 期望 ${report.mismatches[i].expected}，实际 ${report.mismatches[i].actual}`;
        i = i + 1;
      }
      expect(report.passed()).assertTrue();
      expect(detail).assertEqual('');
      expect(report.checked > 100).assertTrue();
    });

    it('唯一计算入口：CarbonService.calculate 与 CarbonCalc 结果一致', 0, () => {
      // 样例 9：节约用电 10 kWh × 0.5703 = 5.7030 kg → 570 分
      const r9: number[] = CalcBaselineValidator.viaService(
        'utility', 'elec_grid', 10, 0.5703, VERSION, 'SRC-MEE-GRID-2022', 'verified', 0
      );
      expect(r9[0]).assertEqual(5.7030);
      expect(r9[1]).assertEqual(570);
      expect(r9[2]).assertEqual(570);

      // 样例 8：少开一天车 16 km × CAR_OWN_FACTOR 0.1920 = 3.0720 kg → 307 分
      const r8: number[] = CalcBaselineValidator.viaService(
        'travel', 'CAR_OWN_FACTOR', 16, 0.1920, VERSION, 'SRC-CALC', 'provisional', 0
      );
      expect(r8[0]).assertEqual(3.0720);
      expect(r8[1]).assertEqual(307);

      // 封顶：D=150 时同一笔 96 分只入 50
      const rCap: number[] = CalcBaselineValidator.viaService(
        'travel', 'walk', 5, 0.1920, VERSION, 'SRC-DERIVED', 'provisional', 150
      );
      expect(rCap[1]).assertEqual(96);
      expect(rCap[2]).assertEqual(50);
    });

    it('舍入一律 half-up（防 banker 默认舍入）', 0, () => {
      // 129.6 → 130（而不是 129）
      expect(CarbonCalc.expectedPointOf(1.2960)).assertEqual(130);
      // 半值一律进位：0.005→1、0.015→2、0.025→3（银行家舍入会给出 0/2/2）
      expect(CarbonCalc.expectedPointOf(0.005)).assertEqual(1);
      expect(CarbonCalc.expectedPointOf(0.015)).assertEqual(2);
      expect(CarbonCalc.expectedPointOf(0.025)).assertEqual(3);
    });

    it('定点乘法不丢精度：0.5703×10 = 5.7030、0.1920×16 = 3.0720', 0, () => {
      expect(CarbonCalc.reductionOf(10, 0.5703)).assertEqual(5.7030);
      expect(CarbonCalc.reductionOf(16, 0.1920)).assertEqual(3.0720);
      expect(CarbonCalc.reductionOf(0.5, 12.0000)).assertEqual(6.0000);
    });

    it('输入合理范围：超限置 is_abnormal（提示但不阻断保存）', 0, () => {
      expect(CarbonCalc.isAbnormalInput('travel', 'bicycle', 300)).assertTrue();
      expect(CarbonCalc.isAbnormalInput('travel', 'bicycle', 200)).assertFalse();
      expect(CarbonCalc.isAbnormalInput('utility', 'water', 2500)).assertTrue();
      expect(CarbonCalc.isAbnormalInput('utility', 'elec_grid', 250)).assertTrue();
      expect(CarbonCalc.isAbnormalInput('recycle', 'paper', 100)).assertFalse();
      expect(CarbonCalc.isAbnormalInput('plate', 'meal', 21)).assertTrue();
    });

    it('目标奖励不封顶、不计入 D', 0, () => {
      // 目标奖励 20 分：以 D=0 参与判定 → 全额 20；若错误地把 D=200 代进去会被削成 0
      expect(CarbonCalc.actualPointOf(20, 0)).assertEqual(20);
      expect(CarbonCalc.actualPointOf(20, 200)).assertEqual(0);
      expect(CarbonService.quotaOf(150).remaining).assertEqual(50);
      expect(CarbonService.quotaOf(250).remaining).assertEqual(0);
    });
  });
}
