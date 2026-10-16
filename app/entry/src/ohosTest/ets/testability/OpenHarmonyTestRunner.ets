/**
 * 单元测试执行器（L1 · hypium）。
 *
 * 职责：把 hypium 测试套件挂到 OpenHarmony 的测试执行框架上。
 *  ① `onPrepare` —— 测试环境准备（仅打日志）；
 *  ② `onRun` —— 取 AbilityDelegator 与测试参数，把 `List.test.ets` 汇总的套件
 *     交给 `Hypium.hypiumTest` 执行。
 *
 * 说明：这是官方 hypium 的标准执行器骨架（本身不含业务逻辑）。
 * 真实触发方式（真机 / 模拟器）：
 *   `hdc shell aa test -b com.carbonboo.app -m entry -s unittest OpenHarmonyTestRunner -s class <套件名>`
 * **本机无任何设备**（`hdc list targets` 失败），所以本文件只保证「测试 HAP 能构建出来」，
 * 不代表用例已真实执行。
 *
 * 本执行器**不读 mock 配置**：mock 由 `aa test -s mock` 参数与 hypium 自行处理，
 * L1 的碳计算与封顶样例都是纯函数用例，不需要 mock。
 */
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Hypium } from '@ohos/hypium';
import testsuite from '../test/List.test';

const DOMAIN: number = 0x0000;
const TAG: string = 'CarbonBooTest';

export default class OpenHarmonyTestRunner implements TestRunner {
  constructor() {
  }

  onPrepare(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'OpenHarmonyTestRunner onPrepare');
  }

  onRun(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'OpenHarmonyTestRunner onRun start');
    const abilityDelegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
    const abilityDelegatorArguments: abilityDelegatorRegistry.AbilityDelegatorArgs = abilityDelegatorRegistry.getArguments();
    hilog.info(DOMAIN, TAG, 'start run testcase, module=%{public}s', String(abilityDelegatorArguments.parameters['-m']));
    Hypium.hypiumTest(abilityDelegator, abilityDelegatorArguments, testsuite);
    hilog.info(DOMAIN, TAG, '%{public}s', 'OpenHarmonyTestRunner onRun end');
  }
}
