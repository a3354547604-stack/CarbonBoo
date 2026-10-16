/**
 * 测试页 —— ohosTest 模块的窗口内容页（**纯测试基建，无业务逻辑**）。
 *
 * 职责：TestAbility 加载本页后，在 `aboutToAppear` 里取出 AbilityDelegator 与参数，
 * 把 `ets/test/List.test.ets` 汇总的 hypium 套件交给 `Hypium.hypiumTest` 执行。
 *
 * 与 `OpenHarmonyTestRunner` 的关系：两条入口都能跑同一套用例——
 *  - 本页：测试模块被普通拉起时自动开跑；
 *  - `OpenHarmonyTestRunner`：`aa test -s unittest` 指定 runner 时由框架调用。
 * 二者都只是把 `testsuite` 交给 hypium，用例本身在 `ets/test/` 里。
 *
 * ⚠️ 本机无设备/可用模拟器后端，本页从未被真实执行（见 `CalcSamples.test.ets` 头部说明）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
import testsuite from '../../test/List.test';

const DOMAIN: number = 0x0000;
const TAG: string = 'CarbonBooTestPage';

@Entry
@Component
struct Index {
  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'unit test start');
    const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
    const args: abilityDelegatorRegistry.AbilityDelegatorArgs = abilityDelegatorRegistry.getArguments();
    Hypium.hypiumTest(delegator, args, testsuite);
    hilog.info(DOMAIN, TAG, '%{public}s', 'unit test end');
  }

  build() {
    Column({ space: 8 }) {
      Text($r('app.string.TestAbility_label'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
      Text('L1 单元测试运行中（结果见 hilog）')
        .fontSize(14)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
