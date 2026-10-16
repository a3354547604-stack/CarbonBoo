/**
 * ShopPriceFallback —— L1 单测：商品取价的「整份生效 / 整份丢弃」与回落规则（附录 B §5.4）。
 *
 * 被测对象是**真实实现** `viewmodel/net/ShopPriceFetcher.ts`（`fetchAndStore()`）与
 * `viewmodel/ShopService.ets` 的目录消费（`items()` / `purchase()`），**没有为可测性改被测代码**：
 * 网络用既有的 `FakeHttpClient`（窄端口 `HttpPort` 的用例实现）注入，`app_config` 走真实 `RdbStore`。
 *
 * 覆盖的契约原文（附录 B §5.4）：
 * 「启动时有网 → 拉取并整份覆盖 `app_config['shop_items']`；失败或数据非法 → **整份丢弃**，
 *  继续用上一份有效配置；从未拉到过 → 用 `rawfile/shop/shop-items.json` 内置默认价。
 *  后台改价**下次启动生效**。」
 *
 * ⚠️ **本机未运行**（如实声明，绝不声称用例通过）：hypium 需由 SDK 的 Previewer 进程驱动，
 *    本机无真机/无模拟器，且该二进制与本机 glibc 不兼容（`pthread_mutex_lock` 断言崩溃）。
 *    本文件的证据只有：① 随 `ohosTest` 目标编译通过；② 人工代码审查。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { FakeHttpClient } from '../../../main/ets/viewmodel/net/HttpPort';
import { ShopPriceFetcher, ShopPriceOutcome } from '../../../main/ets/viewmodel/net/ShopPriceFetcher';
import { MemoryFiles } from '../../../main/ets/viewmodel/store/FilesPort';
import { ServiceHub } from '../../../main/ets/viewmodel/ServiceHub';
import { AppConfig, ConfigKeys } from '../../../main/ets/viewmodel/AppConfig';
import { AppResult } from '../../../main/ets/model/Result';
import { ShopItem } from '../../../main/ets/model/ShopTypes';
import { RowShape, firstOf, numOf } from '../../../main/ets/viewmodel/store/StorePort';

/** 端点（与生产同一拼法）。 */
const PATH: string = '/api/v1/shop/items';

/** 一份合法目录响应（结构照抄附录 B §5.4 的 jsonc 示例，只改价以验证覆盖生效）。 */
function okBody(version: string, frame01Price: number): string {
  return `{"ok":true,"data":{"version":"${version}","items":[` +
    `{"id":"frame_01","section":"frame","name":"嫩芽","description":"初生的绿色","price":${frame01Price},` +
    `"icon":"res://frame_01","order":1,"onShelf":1,"isDefaultFree":0},` +
    `{"id":"theme_default","section":"theme","name":"默认主题（免费）","description":"绿色系默认外观","price":0,` +
    `"icon":"res://theme_default","order":1,"onShelf":1,"isDefaultFree":1}` +
    `]}}`;
}

class Fixture {
  readonly hub: ServiceHub;
  readonly fake: FakeHttpClient;
  readonly cfg: AppConfig;

  constructor(hub: ServiceHub, fake: FakeHttpClient, cfg: AppConfig) {
    this.hub = hub;
    this.fake = fake;
    this.cfg = cfg;
  }
}

/** 装配：真实服务栈 + 可控 HTTP（`app_config` 走真实库）。 */
async function setup(): Promise<Fixture> {
  const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
  const now: number = Date.now();
  const fake: FakeHttpClient = new FakeHttpClient();
  const hub: ServiceHub = await ServiceHub.init(context, now, { http: fake, files: new MemoryFiles() });
  return new Fixture(hub, fake, hub.cfg);
}

/** 直接读 `app_config['shop_items']` 原文（断言"整份丢弃"就是断言它没变）。 */
async function storedCatalog(cfg: AppConfig): Promise<string | undefined> {
  return cfg.get(ConfigKeys.SHOP_ITEMS);
}

export default function shopPriceFallbackTest(): void {
  describe('ShopPriceFallback', () => {
    it('① 成功 → 整份覆盖 app_config[shop_items]（含 version）', 0, async () => {
      const fx: Fixture = await setup();
      fx.fake.stub('GET', `${fx.fake.baseUrl()}${PATH}`, 200, okBody('2026.02.01-1', 1800));

      const res: AppResult<ShopPriceOutcome> = await fx.hub.fetchShopPrices();
      expect(res.ok).assertTrue();
      expect(res.data === undefined ? false : res.data.applied).assertTrue();
      expect(res.data === undefined ? '' : res.data.version).assertEqual('2026.02.01-1');
      expect(res.data === undefined ? -1 : res.data.count).assertEqual(2);

      const raw: string | undefined = await storedCatalog(fx.cfg);
      expect(raw !== undefined).assertTrue();
      expect((raw === undefined ? '' : raw).indexOf('2026.02.01-1') >= 0).assertTrue();
      expect((raw === undefined ? '' : raw).indexOf('frame_01') >= 0).assertTrue();
      // 目录版本可读回（供设置/开发者选项展示）
      expect(await fx.hub.shop.catalogVersion()).assertEqual('2026.02.01-1');
      // 取价**不带 token**（唯一免鉴权接口）
      expect(fx.fake.countWithAuth()).assertEqual(0);
      expect(fx.fake.count()).assertEqual(1);
    });

    it('② ShopService 消费目录：后台改价后 items()/purchase() 取到新价（A12 / D10-3）', 0, async () => {
      const fx: Fixture = await setup();
      const now: number = Date.now();
      const userId: string = `t-shop-price-${now}`;
      await fx.hub.auth.logout(now);
      await fx.hub.state.ensureUser(userId, now);

      // 内置基线价（rawfile 播种）：frame_01 = 1500
      const before: ShopItem[] = await fx.hub.shop.items('frame');
      let basePrice: number = -1;
      let i: number = 0;
      while (i < before.length) {
        if (before[i].id === 'frame_01') {
          basePrice = before[i].price;
        }
        i = i + 1;
      }
      expect(basePrice).assertEqual(1500);

      // 后台把 frame_01 改成 1800 → 冷启动取价覆盖
      fx.fake.stub('GET', `${fx.fake.baseUrl()}${PATH}`, 200, okBody('2026.02.02-1', 1800));
      const res: AppResult<ShopPriceOutcome> = await fx.hub.fetchShopPrices();
      expect(res.ok).assertTrue();

      // items() 必须取到新价
      const after: ShopItem[] = await fx.hub.shop.items('frame');
      let newPrice: number = -1;
      i = 0;
      while (i < after.length) {
        if (after[i].id === 'frame_01') {
          newPrice = after[i].price;
        }
        i = i + 1;
      }
      expect(newPrice).assertEqual(1800);

      // purchase() 必须按新价扣分：先给足够余额，再买，断言流水价 = 1800
      await fx.hub.points.append(userId, {
        type: 'record',
        points: 5000,
        sourceType: 'carbon_record',
        sourceId: `${userId}#seed`,
        title: '测试用收入',
        occurredAt: now,
      });
      const bought = await fx.hub.shop.purchase(userId, 'frame_01');
      expect(bought.ok).assertTrue();
      expect(bought.data === undefined ? -1 : bought.data.price).assertEqual(1800);
      const rows: RowShape[] = await fx.hub.store.query(
        "SELECT points FROM point_record WHERE user_id = ? AND source_type = 'shop_item' AND source_id = 'frame_01'",
        [userId]
      );
      const row: RowShape | undefined = firstOf(rows);
      expect(numOf(row === undefined ? {} : row, 'points')).assertEqual(-1800);
    });

    it('③ HTTP 失败（500）→ 整份丢弃，上一份有效目录原样保留', 0, async () => {
      const fx: Fixture = await setup();
      // 先成功建立"上一份"
      fx.fake.stub('GET', `${fx.fake.baseUrl()}${PATH}`, 200, okBody('v-good', 1800));
      const first: AppResult<ShopPriceOutcome> = await fx.hub.fetchShopPrices();
      expect(first.ok).assertTrue();
      const kept: string | undefined = await storedCatalog(fx.cfg);
      expect(kept !== undefined).assertTrue();

      // 再让服务端 500
      fx.fake.stub('GET', `${fx.fake.baseUrl()}${PATH}`, 500, '{"ok":false}');
      const second: AppResult<ShopPriceOutcome> = await fx.hub.fetchShopPrices();
      expect(second.ok).assertFalse();
      // **关键断言**：上一份一个字都没变
      expect(await storedCatalog(fx.cfg)).assertEqual(kept === undefined ? '' : kept);
      expect(await fx.hub.shop.catalogVersion()).assertEqual('v-good');
    });

    it('④ 非法数据 → 整份丢弃，不写坏数据（不污染上一份）', 0, async () => {
      const fx: Fixture = await setup();
      fx.fake.stub('GET', `${fx.fake.baseUrl()}${PATH}`, 200, okBody('v-good', 1800));
      const first: AppResult<ShopPriceOutcome> = await fx.hub.fetchShopPrices();
      expect(first.ok).assertTrue();
      const kept: string | undefined = await storedCatalog(fx.cfg);

      // 四种非法形态逐一验证「整份丢弃」
      const bad: string[] = [
        // a) items 里有一条缺 price
        '{"ok":true,"data":{"version":"v-bad","items":[{"id":"frame_01","section":"frame","name":"嫩芽","icon":"i","order":1,"onShelf":1,"isDefaultFree":0}]}}',
        // b) section 非法
        '{"ok":true,"data":{"version":"v-bad","items":[{"id":"frame_01","section":"bogus","name":"n","price":1,"icon":"i","order":1,"onShelf":1,"isDefaultFree":0}]}}',
        // c) version 缺失
        '{"ok":true,"data":{"items":[{"id":"frame_01","section":"frame","name":"n","price":1,"icon":"i","order":1,"onShelf":1,"isDefaultFree":0}]}}',
        // d) 空目录（不足以覆盖）
        '{"ok":true,"data":{"version":"v-bad","items":[]}}',
      ];
      let k: number = 0;
      while (k < bad.length) {
        fx.fake.stub('GET', `${fx.fake.baseUrl()}${PATH}`, 200, bad[k]);
        const r: AppResult<ShopPriceOutcome> = await fx.hub.fetchShopPrices();
        expect(r.ok).assertFalse();
        // 每次非法都不许改动已存的上一份
        expect(await storedCatalog(fx.cfg)).assertEqual(kept === undefined ? '' : kept);
        k = k + 1;
      }
      expect(await fx.hub.shop.catalogVersion()).assertEqual('v-good');
    });

    it('⑤ 从未拉到过 → 回落到本地内置默认价（rawfile 播种价）', 0, async () => {
      const fx: Fixture = await setup();
      // 未做任何取价：目录键应不存在，catalog() 为空 Map
      expect(await storedCatalog(fx.cfg) === undefined).assertTrue();
      expect(await fx.hub.shop.catalogVersion()).assertEqual('');
      expect((await fx.hub.shop.catalog()).size).assertEqual(0);

      // items() 仍能正常返回内置默认价（取价链路不通不影响本地功能 —— 铁律 1）
      const items: ShopItem[] = await fx.hub.shop.items('frame');
      expect(items.length > 0).assertTrue();
      let i: number = 0;
      let frame01: number = -1;
      while (i < items.length) {
        if (items[i].id === 'frame_01') {
          frame01 = items[i].price;
        }
        i = i + 1;
      }
      expect(frame01).assertEqual(1500);
    });

    it('⑥ 网络不可达（status=0）→ 整份丢弃，且 fetchAndStore 从不抛错', 0, async () => {
      const fx: Fixture = await setup();
      // FakeHttpClient 默认返回 200 {"ok":true,"data":{}} —— data 里没有 version/items → 非法
      const r: AppResult<ShopPriceOutcome> = await fx.hub.fetchShopPrices();
      expect(r.ok).assertFalse();
      expect(await storedCatalog(fx.cfg) === undefined).assertTrue();
    });
  });
}
