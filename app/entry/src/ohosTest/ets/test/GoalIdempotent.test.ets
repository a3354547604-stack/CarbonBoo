/**
 * GoalIdempotent —— L1 单测：目标结算幂等（铁律 4 / 验收 D2 系列）。
 *
 * 职责：同一 `(userId, goalId, periodKey)` 反复结算只发一次积分：
 *  ① 首次结算发出 S1 的 +20；② 再结算返回空集且积分不变；
 *  ③ 反复 `refreshProgress` 不把 `settled` 改回 0、不把 `progress` 清零；
 *  ④ 唯一约束 `uq_pr_source(source_type, source_id, flow_kind)` 是真正的闸门（幂等键 = `<goalId>:<periodKey>`）。
 *
 * **本机未运行**（如实声明）：hypium 依赖 SDK Previewer 进程，本机无真机/模拟器且预览器二进制与
 * glibc 不兼容，断言在本机未真实执行；本地证据只到「随 ohosTest 目标编译通过」。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { FakeHttpClient } from '../../../main/ets/viewmodel/net/HttpPort';
import { MemoryFiles } from '../../../main/ets/viewmodel/store/FilesPort';
import { ServiceHub } from '../../../main/ets/viewmodel/ServiceHub';
import { AppResult } from '../../../main/ets/model/Result';
import { SaveOutcome } from '../../../main/ets/viewmodel/RecordService';
import { GoalCard, SettleDecision } from '../../../main/ets/viewmodel/domain/RewardEngine';

export default function goalIdempotentTest(): void {
  describe('GoalIdempotent', () => {
    it('同一周期目标只结算一次：重复 settle/refresh 不重复发分', 0, async () => {
      const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const now: number = Date.now();
      const hub: ServiceHub = await ServiceHub.init(context, now,
        { http: new FakeHttpClient(), files: new MemoryFiles() });
      await hub.setBreakSave(false, now);
      await hub.auth.logout(now);
      const userId: string = `t-goal-${now}`;
      await hub.state.ensureUser(userId, now);

      // 一笔绿色出行即满足 S1「零碳出行」（当日 1 条）
      const saved: AppResult<SaveOutcome> = await hub.records.save(userId, {
        category: 'travel',
        subType: 'bicycle',
        amount: 5,
        occurredAt: now,
      }, now);
      expect(saved.ok).assertTrue();

      const cards: GoalCard[] = await hub.reward.goalCards(userId, now);
      let s1Settled: boolean = false;
      let i: number = 0;
      while (i < cards.length) {
        if (cards[i].goalId === 'S1') {
          s1Settled = cards[i].settled;
        }
        i = i + 1;
      }
      expect(s1Settled).assertTrue();

      const balanceAfterFirst: number = (await hub.points.balance(userId, now)).balance;
      const goalPointsFirst: number = await hub.points.sumBySource(userId, 'goal');
      expect(goalPointsFirst > 0).assertTrue();

      // 再结算两次：幂等键挡住，不发分
      const second: SettleDecision[] = await hub.reward.settle(userId, now);
      const third: SettleDecision[] = await hub.reward.settle(userId, now);
      expect(second.length).assertEqual(0);
      expect(third.length).assertEqual(0);

      // 反复刷新进度：settled 不回退、progress 不丢
      await hub.reward.refreshProgress(userId, now);
      await hub.reward.refreshProgress(userId, now);
      expect((await hub.points.balance(userId, now)).balance).assertEqual(balanceAfterFirst);
      expect(await hub.points.sumBySource(userId, 'goal')).assertEqual(goalPointsFirst);

      const rows: GoalCard[] = await hub.reward.goalCards(userId, now);
      let j: number = 0;
      let stillSettled: boolean = false;
      let s1Progress: number = 0;
      while (j < rows.length) {
        if (rows[j].goalId === 'S1') {
          stillSettled = rows[j].settled;
          s1Progress = rows[j].progress;
        }
        j = j + 1;
      }
      expect(stillSettled).assertTrue();
      expect(s1Progress >= 1).assertTrue();
    });
  });
}
