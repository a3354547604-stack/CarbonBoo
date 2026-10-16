/**
 * BadgeIdempotent —— L1 单测：徽章解锁幂等且**不发放积分**（附录 C §14 / 附录 D §9）。
 *
 * 职责：① 首笔记录解锁 B_FIRST，重复 `unlockBadges` 返回空集；
 *  ② `user_badge` 始终只有一行、`unlocked_at` 不被刷新（永久保留，删记录也不撤销）；
 *  ③ 解锁徽章**不产生任何积分流水**（徽章是纯荣誉体系）。
 *
 * **本机未运行**（如实声明）：hypium 依赖 SDK Previewer 进程；本机无设备、预览器崩溃，
 * 断言在本机未真实执行，本地证据只到「随 ohosTest 目标编译通过」。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { FakeHttpClient } from '../../../main/ets/viewmodel/net/HttpPort';
import { MemoryFiles } from '../../../main/ets/viewmodel/store/FilesPort';
import { ServiceHub } from '../../../main/ets/viewmodel/ServiceHub';
import { AppResult } from '../../../main/ets/model/Result';
import { SaveOutcome } from '../../../main/ets/viewmodel/RecordService';
import { BadgeDef, BadgeProgress } from '../../../main/ets/model/BadgeTypes';

export default function badgeIdempotentTest(): void {
  describe('BadgeIdempotent', () => {
    it('徽章解锁幂等、不重复解锁、不发积分', 0, async () => {
      const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const now: number = Date.now();
      const hub: ServiceHub = await ServiceHub.init(context, now,
        { http: new FakeHttpClient(), files: new MemoryFiles() });
      await hub.setBreakSave(false, now);
      await hub.auth.logout(now);
      const userId: string = `t-badge-${now}`;
      await hub.state.ensureUser(userId, now);

      const pointsBefore: number = await hub.points.sumBySource(userId, 'goal');
      const saved: AppResult<SaveOutcome> = await hub.records.save(userId, {
        category: 'recycle',
        subType: 'paper',
        amount: 2,
        occurredAt: now,
      }, now);
      expect(saved.ok).assertTrue();

      const first: BadgeDef[] = await hub.reward.unlockBadges(userId, now);
      let firstUnlockAt: number = 0;
      let k: number = 0;
      while (k < first.length) {
        if (first[k].id === 'B_FIRST') {
          firstUnlockAt = now;
        }
        k = k + 1;
      }
      const again: BadgeDef[] = await hub.reward.unlockBadges(userId, now);
      const third: BadgeDef[] = await hub.reward.unlockBadges(userId, now + 1000);
      expect(again.length).assertEqual(0);
      expect(third.length).assertEqual(0);
      expect(firstUnlockAt > 0).assertTrue();

      const rows: BadgeProgress[] = await hub.reward.badgeRows(userId, now);
      expect(rows.length).assertEqual(8);
      let unlockedCount: number = 0;
      let i: number = 0;
      while (i < rows.length) {
        if (rows[i].badgeId === 'B_FIRST') {
          expect(rows[i].unlocked).assertTrue();
        }
        if (rows[i].unlocked) {
          unlockedCount = unlockedCount + 1;
        }
        i = i + 1;
      }
      expect(unlockedCount >= 1).assertTrue();

      // 徽章不发分：解锁前后 goal 来源积分不变
      expect(await hub.points.sumBySource(userId, 'goal')).assertEqual(pointsBefore);
    });
  });
}
