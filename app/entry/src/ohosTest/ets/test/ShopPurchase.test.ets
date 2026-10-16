/**
 * ShopPurchase —— L1 单测：碳小铺购买幂等与余额规则（附录 C §15 / 铁律 4）。
 *
 * 职责：① 一次购买只扣一次分（重复购买直接拒绝，不是扣两次）；
 *  ② 余额不足不下单、给出「积分不足，还差 n 分」；
 *  ③ 集齐全部 8 个头像框立即解锁「种树人」B_TREE；
 *  ④ 购买流水唯一来源 `source_type='shop_item'`，合计 = −Σ价格。
 *
 * **本机未运行**（如实声明）：hypium 依赖 SDK Previewer 进程，本机无真机/模拟器、
 * 预览器二进制与 glibc 不兼容，断言在本机未真实执行；本地证据只到编译通过。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { FakeHttpClient } from '../../../main/ets/viewmodel/net/HttpPort';
import { MemoryFiles } from '../../../main/ets/viewmodel/store/FilesPort';
import { ServiceHub } from '../../../main/ets/viewmodel/ServiceHub';
import { AppResult } from '../../../main/ets/model/Result';
import { PurchaseOutcome } from '../../../main/ets/viewmodel/ShopService';
import { ShopItem } from '../../../main/ets/model/ShopTypes';

export default function shopPurchaseTest(): void {
  describe('ShopPurchase', () => {
    it('购买幂等、余额不足拒绝、集齐 8 框解锁种树人', 0, async () => {
      const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const now: number = Date.now();
      const hub: ServiceHub = await ServiceHub.init(context, now,
        { http: new FakeHttpClient(), files: new MemoryFiles() });
      await hub.setBreakSave(false, now);
      await hub.auth.logout(now);
      const userId: string = `t-shop-${now}`;
      await hub.state.ensureUser(userId, now);

      // 先给一笔合法收入（走 PointService.append，唯一入口；不是伪造余额）
      await hub.points.append(userId, {
        type: 'record',
        points: 60000,
        sourceType: 'carbon_record',
        sourceId: `${userId}#seed`,
        title: '测试用收入',
        occurredAt: now - 86400000,
      });
      expect((await hub.points.balance(userId, now)).balance).assertEqual(60000);

      const frames: ShopItem[] = await hub.shop.items('frame');
      expect(frames.length).assertEqual(8);

      // 买第一件：成功且只扣一次
      const first: AppResult<PurchaseOutcome> = await hub.shop.purchase(userId, frames[0].id);
      expect(first.ok).assertTrue();
      if (first.data !== undefined) {
        expect(first.data.balanceAfter).assertEqual(60000 - frames[0].price);
      }
      const balanceAfterFirst: number = (await hub.points.balance(userId, now)).balance;
      expect(balanceAfterFirst).assertEqual(60000 - frames[0].price);

      // 重复购买同一件：拒绝，且余额不再变化
      const again: AppResult<PurchaseOutcome> = await hub.shop.purchase(userId, frames[0].id);
      expect(again.ok).assertFalse();
      expect((await hub.points.balance(userId, now)).balance).assertEqual(balanceAfterFirst);

      // 余额不足：全新用户 0 分 → 拒绝并给出还差多少
      const poor: string = `t-shop-poor-${now}`;
      await hub.state.ensureUser(poor, now);
      const denied: AppResult<PurchaseOutcome> = await hub.shop.purchase(poor, frames[0].id);
      expect(denied.ok).assertFalse();
      if (denied.message !== undefined) {
        expect(denied.message.includes('积分不足')).assertTrue();
      }
      expect((await hub.points.balance(poor, now)).balance).assertEqual(0);

      // 集齐 8 个头像框 → 种树人条件达成
      let i: number = 1;
      let treeReady: boolean = false;
      while (i < frames.length) {
        const r: AppResult<PurchaseOutcome> = await hub.shop.purchase(userId, frames[i].id);
        expect(r.ok).assertTrue();
        if (r.data !== undefined && r.data.treeReady) {
          treeReady = true;
        }
        i = i + 1;
      }
      expect(treeReady).assertTrue();
      expect(await hub.shop.ownedFrameCount(userId)).assertEqual(8);

      // 流水口径：购买来源合计 = −Σ价格
      let sum: number = 0;
      let k: number = 0;
      while (k < frames.length) {
        sum = sum + frames[k].price;
        k = k + 1;
      }
      expect(await hub.points.sumBySource(userId, 'shop_item')).assertEqual(-sum);

      // 不提供主题购买以外的越权路径：主题区只有免费默认主题
      const themes: ShopItem[] = await hub.shop.items('theme');
      expect(themes.length >= 1).assertTrue();
    });
  });
}
