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
import { RowShape, numOf } from '../../../main/ets/viewmodel/store/StorePort';

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

      // ① 解锁发生在 `save()` **内部**：`RecordService.save()` 经 `RewardService.refresh()`
      //    已经调用过 `unlockBadges`，本次新解锁的徽章由 `SaveOutcome.newBadges` 携带返回
      //    （该字段是徽章**名称**、不是 id，见 `RecordService.badgeNames()`）。
      //    原断言假设"save 之后首次显式 `unlockBadges` 会返回 B_FIRST"，与实现模型不符 —— 是用例写错了，
      //    不是实现错（t44 已直查库证实，见 docs/VERIFICATION.md 相关轮次）。
      const beforeExplicit: BadgeProgress[] = await hub.reward.badgeRows(userId, now);
      let firstName: string = '';
      let firstUnlockAt: number = -1;
      let k: number = 0;
      while (k < beforeExplicit.length) {
        if (beforeExplicit[k].badgeId === 'B_FIRST') {
          firstName = beforeExplicit[k].name;
          firstUnlockAt = beforeExplicit[k].unlockedAt === undefined ? -1 : beforeExplicit[k].unlockedAt;
          expect(beforeExplicit[k].unlocked).assertTrue();     // save 之内就已解锁
        }
        k = k + 1;
      }
      expect(firstName.length > 0).assertTrue();               // 目录里确实有 B_FIRST（否则下一行会退化成恒真）
      expect(firstUnlockAt > 0).assertTrue();                  // save 之内已写入解锁时刻
      const carried: string[] = saved.data === undefined ? [] : saved.data.newBadges;
      expect(carried.indexOf(firstName) >= 0).assertTrue();    // save 把新解锁徽章带回来了

      // ② 之后再**显式**调用 `unlockBadges`：返回空集（幂等）
      const again: BadgeDef[] = await hub.reward.unlockBadges(userId, now);
      const third: BadgeDef[] = await hub.reward.unlockBadges(userId, now + 1000);
      expect(again.length).assertEqual(0);
      expect(third.length).assertEqual(0);

      // ③ 库里确实落了 `unlocked=1` + `unlocked_at`（直查 `user_badge`，不看内存态），
      //    且两次显式调用（`now` / `now+1000`）**没有刷新** `unlocked_at`。
      const ubRows: RowShape[] = await hub.store.query(
        "SELECT unlocked, unlocked_at FROM user_badge WHERE user_id = ? AND badge_id = 'B_FIRST'", [userId]);
      expect(ubRows.length).assertEqual(1);
      expect(numOf(ubRows[0], 'unlocked')).assertEqual(1);
      expect(numOf(ubRows[0], 'unlocked_at')).assertEqual(firstUnlockAt);

      const rows: BadgeProgress[] = await hub.reward.badgeRows(userId, now + 1000);
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
