/**
 * TestContext —— 给设备侧用例取一个**可用的** Context。
 *
 * 为什么需要它（2026-11-01 模拟器实跑 `aa test` 发现）：
 *   原先所有用例统一用 `abilityDelegatorRegistry.getAbilityDelegator().getAppContext()`。
 *   在真机/模拟器上，该 ApplicationContext 被
 *   `relationalStore.getRdbStore(context, config)` 判为非法：
 *     `Parameter error.Illegal context.`
 *   于是凡是需要开库的用例全部 Error，只有纯函数用例通过（10 pass / 38 error）。
 *
 * 取法：优先 `getCurrentTopAbility()`（`aa test` 会把本模块的 TestAbility 拉到前台，
 * 它的 UIAbilityContext 一定可用于建库与文件读写）；取不到再退回 ApplicationContext。
 * 两条路径都写日志，便于下次排查一眼看出走的是哪条。
 */
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarbonBooTest';

/** 取一个可用于 `relationalStore` / 文件读写的 Context。 */
export async function testContext(): Promise<common.Context> {
  const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
  try {
    const ability: UIAbility = await delegator.getCurrentTopAbility();
    const ctx: common.UIAbilityContext = ability.context;
    if (ctx !== undefined && ctx !== null) {
      hilog.info(DOMAIN, TAG, 'testContext: 使用 TestAbility 的 UIAbilityContext');
      return ctx;
    }
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'testContext: getCurrentTopAbility 失败，退回 app context');
  }
  const app: common.Context = delegator.getAppContext();
  hilog.info(DOMAIN, TAG, 'testContext: 使用 ApplicationContext');
  return app;
}
