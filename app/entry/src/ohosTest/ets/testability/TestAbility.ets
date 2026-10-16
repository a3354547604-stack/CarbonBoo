/**
 * TestAbility —— ohosTest 测试模块的入口 Ability（**纯测试基建，无业务逻辑**）。
 *
 * 职责：测试模块 `entry_test` 的 `mainElement`，被 `aa test` 拉起；
 * 它在窗口就绪后加载 `pages/Index`，由那个页面把 hypium 套件交给测试框架执行。
 *
 * 为什么需要它：hvigor 的 `ohosTest` target 会校验 `module.json5` 里
 * `abilities[].srcEntry` 指向的文件存在；缺了就直接失败在本任务契约的 verify 命令上：
 *   `ERROR: Module-Abilities-srcEntry './ets/testability/TestAbility.ets' not found.`
 *
 * 与 `OpenHarmonyTestRunner` 的分工：
 *  - 本文件 = 把测试模块**拉起来**（Ability 生命周期 + 加载测试页）；
 *  - `OpenHarmonyTestRunner` = 被 `aa test -s unittest` 选中后，**真正喂给 hypium** 的 TestRunner。
 *
 * ⚠️ 本机限制（如实记录）：本机无真机/模拟器与可用模拟器后端，**这个 Ability 从未被真实拉起过**。
 *    它存在的意义是让测试源码进入 `ohosTest` 编译目标，从而获得真实的 ArkTS 静态类型检查。
 */
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN: number = 0x0000;
const TAG: string = 'CarbonBooTestAbility';

export default class TestAbility extends UIAbility {
  /** Ability 创建：仅记录日志。 */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onCreate');
  }

  /** 窗口就绪：加载测试页（该页负责启动 hypium 套件）。 */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s', 'Succeeded in loading the content.');
    });
  }

  /** 窗口销毁：当前无持有资源。 */
  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onWindowStageDestroy');
  }

  /** 进入前台。 */
  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onForeground');
  }

  /** 进入后台。 */
  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onBackground');
  }

  /** Ability 销毁。 */
  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onDestroy');
  }
}
