/**
 * Probe —— 最小探针：设备侧到底能不能拿到可用的 Context 去建库。
 *
 * 存在理由：2026-11-01 在模拟器上跑 `aa test` 时，38 条依赖 `relationalStore` 的用例
 * 全部报 `Parameter error.Illegal context.`（code 401），而 10 条纯逻辑用例通过。
 * 为了把「是我们的取 context 方式不对」和「是 `aa test` 进程本身不让建库」区分开，
 * 这里只做一件事：用几种途径各建一次库，把结果打出来。
 *
 * 结论（实测）：
 *   - `delegator.getAppContext()`      → 401 Illegal context
 *   - `delegator.getCurrentTopAbility()` → 抛 16000100（`aa test` 不启动 TestAbility）
 *   故设备侧只能跑纯逻辑用例；需要真库的用例由离线执行器（node:sqlite 垫片）覆盖。
 * 探针保留在仓库里，供以后换设备/换 SDK 时重跑复核，别删。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarbonBooProbe';

export default function probeTest() {
  describe('Probe', () => {
    it('设备侧是否能用 aa test 的 Context 建库', 0, async () => {
      const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();

      let topFailed: boolean = false;
      try {
        await delegator.getCurrentTopAbility();
      } catch (err) {
        topFailed = true;
      }
      hilog.info(DOMAIN, TAG, 'getCurrentTopAbility failed=%{public}s', `${topFailed}`);

      const ctx: common.Context = delegator.getAppContext();
      let appOpenOk: boolean = false;
      let appOpenMsg: string = '';
      try {
        const cfg: relationalStore.StoreConfig = {
          name: 'probe-app.db',
          securityLevel: relationalStore.SecurityLevel.S1,
        };
        await relationalStore.getRdbStore(ctx, cfg);
        appOpenOk = true;
      } catch (err) {
        appOpenMsg = `${err}`;
      }
      hilog.info(DOMAIN, TAG, 'appContext open ok=%{public}s msg=%{public}s', `${appOpenOk}`, appOpenMsg);

      // 探针不断言「必须成功」：它只是把环境事实记下来，避免误报红。
      expect(topFailed || appOpenOk).assertTrue();
    });
  });
}
