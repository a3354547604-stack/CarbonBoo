/**
 * ShopService —— 碳小铺（S4 外观闭环）：商品列表、购买幂等、头像框授权。
 *
 * 职责：
 *  ① 商品：从 `shop_item` 读上架商品，按 `section`（头像框 / 主题）分组；
 *  ② 购买：**一个事务**里写 `user_purchase` + 负额 `point_record(purchase)`，
 *     幂等键 `source_id = 商品 id`（`uq_up` 保证不可重复购买），并刷新当日缓存；
 *  ③ 授权：已购头像框列表供外观页使用；集齐 8 个头像框由 `RewardService` 解锁「种树人」；
 *  ④ 定价：价格可被**后台下发目录**覆盖 —— 目录由 `ShopPriceFetcher` 在冷启动时整份写入
 *     `app_config['shop_items']`（附录 B §5.4），本层只**读**它并在返回商品时叠加价格；
 *     目录缺失/非法 → 原样用本地 `shop_item` 的行价（= `rawfile/shop/shop-items.json` 内置默认价）。
 *
 * 键名收敛（t12）：本文件原先读 `app_config['shop_prices']`，该键在 `docs/` 中并不存在，
 * 与附录 B §5.4 的 `shop_items`、`ConfigKeys.SHOP_ITEMS` 都不一致；
 * 现统一为 `ConfigKeys.SHOP_ITEMS`（附录 B 优先，AGENTS §1.2）。
 *
 * 为什么"覆盖 `app_config`"而不覆盖 `shop_item` 表：
 * 附录 B §5.4 原文只要求整份覆盖 `app_config['shop_items']`，未要求改写 `shop_item`。
 * 本地表是**内置基线**（由 `rawfile/shop/shop-items.json` 播种），保留它可让
 * 「从未拉到过 → 用内置默认价」自然成立；服务端目录只提供**同一批商品**的权威价格/文案，
 * 本层叠加时不新增商品、不删商品 —— 与 `ShopService.items()` 的既有语义一致，改动面最小。
 *
 * 铁律 4：扣分只能写流水，不能直接改余额——余额永远是流水聚合的结果。
 */
import { ShopItem } from '../model/ShopTypes';
import { ShopRules, PurchaseCheck } from './domain/ShopRules';
import { StorePort, firstOf, numOf, textOf } from './store/StorePort';
import { RowMapper } from './store/RowMapper';
import { PointService } from './PointService';
import { AppState } from './AppState';
import { AppConfig, ConfigKeys } from './AppConfig';
import { IdUtil } from './domain/IdUtil';
import { AppResult, fail, ok } from '../model/Result';
import { JsonArray, JsonObject, asArray, asObject, optNum, optStr } from '../util/JsonUtil';
import { ShopPriceFetcher } from './net/ShopPriceFetcher';

/** 一次购买的结果。 */
export interface PurchaseOutcome {
  itemId: string;
  price: number;
  balanceAfter: number;
  /** 购买后是否集齐全部头像框（解锁「种树人」）。 */
  treeReady: boolean;
}

export class ShopService {
  private readonly store: StorePort;
  private readonly state: AppState;
  private readonly points: PointService;
  private readonly cfg: AppConfig;

  /**
   * @param store 数据端口
   * @param state 会话态
   * @param points 积分（唯一写入口）
   * @param cfg `app_config` 门面（读后台下发的商品目录）
   */
  constructor(store: StorePort, state: AppState, points: PointService, cfg: AppConfig) {
    this.store = store;
    this.state = state;
    this.points = points;
    this.cfg = cfg;
  }

  /**
   * 把后台下发的目录**按 id 叠加**到本地商品行上（只改同 id 的字段，不增不删）。
   * 目录缺失/非法/为空 → 原样返回本地行（= 内置默认价）。
   * @param items 本地行（已按 section + 上架过滤）
   */
  private async overlayCatalog(items: ShopItem[]): Promise<ShopItem[]> {
    const catalog: Map<string, ShopItem> = await this.catalog();
    if (catalog.size === 0) {
      return items;
    }
    const out: ShopItem[] = [];
    let i: number = 0;
    while (i < items.length) {
      const local: ShopItem = items[i];
      const remote: ShopItem | undefined = catalog.get(local.id);
      if (remote === undefined) {
        out.push(local);
      } else {
        // 只叠加"后台可改"的四项（附录 B §5.4：改价 / 改描述 / 排序 / 上下架）；
        // section / icon / id 属商品身份，本地为准。
        out.push({
          id: local.id,
          section: local.section,
          name: remote.name,
          description: remote.description,
          price: remote.price,
          icon: local.icon,
          order: remote.order,
          onShelf: remote.onShelf,
          isDefaultFree: remote.isDefaultFree,
        });
      }
      i = i + 1;
    }
    return out;
  }

  /** 某分区的上架商品（按 order；后台下发目录若有同 id 项则叠加其价格/文案）。 */
  async items(section: 'frame' | 'theme'): Promise<ShopItem[]> {
    const rows = await this.store.query('SELECT * FROM shop_item WHERE section = ? AND on_shelf = 1 ORDER BY "order" ASC', [section]);
    return this.overlayCatalog(RowMapper.shopItems(rows));
  }

  /** 已购商品 id（本机账本；`uq_up` 保证每件最多一条）。 */
  async ownedIds(userId: string): Promise<string[]> {
    const rows = await this.store.query('SELECT item_id FROM user_purchase WHERE user_id = ? AND is_deleted = 0', [userId]);
    const out: string[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(textOf(rows[i], 'item_id'));
      i = i + 1;
    }
    return out;
  }

  /** 已购头像框数（「种树人」徽章判定用）。 */
  async ownedFrameCount(userId: string): Promise<number> {
    const rows = await this.store.query(
      "SELECT COUNT(*) AS n FROM user_purchase p JOIN shop_item s ON s.id = p.item_id " +
      "WHERE p.user_id = ? AND p.is_deleted = 0 AND s.section = 'frame'",
      [userId]
    );
    const row = firstOf(rows);
    return row === undefined ? 0 : numOf(row, 'n');
  }

  /** 一次购买（事务：`user_purchase` + 负额流水）。 */
  async purchase(userId: string, itemId: string): Promise<AppResult<PurchaseOutcome>> {
    const itemRows = await this.store.query('SELECT * FROM shop_item WHERE id = ?', [itemId]);
    const itemRow = firstOf(itemRows);
    if (itemRow === undefined) {
      return fail<PurchaseOutcome>('ITEM_MISSING', '商品不存在');
    }
    const item: ShopItem = RowMapper.shopItem(itemRow);
    // 后台下发目录里的同 id 项优先（承载验收 A12：后台改价 → 冷启动后按新价扣分）
    const remote: ShopItem | undefined = (await this.catalog()).get(itemId);
    if (remote !== undefined) {
      item.price = remote.price;
      item.name = remote.name;
    }
    const balance = await this.points.balance(userId, Date.now());
    const owned: string[] = await this.ownedIds(userId);
    const check: PurchaseCheck = ShopRules.check(item, balance.balance, owned.indexOf(itemId) >= 0);
    if (!check.allowed) {
      return fail<PurchaseOutcome>(check.code === undefined ? 'DENIED' : check.code, check.message.length === 0 ? '不可购买' : check.message);
    }
    try {
      return await this.store.transaction<AppResult<PurchaseOutcome>>(async () => {
        const now: number = Date.now();
        await this.store.exec(
          'INSERT OR IGNORE INTO user_purchase (id, user_id, item_id, price_paid, purchased_at, created_at, updated_at, is_deleted, device_id, sync_state) ' +
          'VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)',
          [IdUtil.uuid(), userId, itemId, item.price, now, now, now, this.state.deviceId(), this.state.syncState()]
        );
        const confirm = await this.store.query('SELECT id FROM user_purchase WHERE user_id = ? AND item_id = ? AND is_deleted = 0', [userId, itemId]);
        if (confirm.length === 0) {
          throw new Error('购买记录未写入');
        }
        const written: string = await this.points.append(userId, {
          type: 'purchase',
          points: -item.price,
          sourceType: 'shop_item',
          sourceId: itemId,
          title: `兑换「${item.name}」`,
          occurredAt: now,
        });
        if (written.length === 0) {
          // 流水已存在（重复购买）：整笔回滚，避免「扣了分没拿到」
          const already = await this.store.query(
            "SELECT id, points FROM point_record WHERE source_type = 'shop_item' AND source_id = ? AND flow_kind = 'primary'",
            [itemId]
          );
          const row = firstOf(already);
          if (row === undefined || numOf(row, 'points') >= 0) {
            throw new Error('购买流水异常');
          }
        }
        const frames: number = await this.ownedFrameCount(userId);
        const after = await this.points.balance(userId, now);
        return ok<PurchaseOutcome>({
          itemId,
          price: item.price,
          balanceAfter: after.balance,
          treeReady: ShopRules.treeUnlocked(frames, 8),
        });
      });
    } catch (e) {
      return fail<PurchaseOutcome>('PURCHASE_FAILED', `购买失败：${ShopService.messageOf(e)}`);
    }
  }

  /**
   * 后台下发的商品目录（读 `ConfigKeys.SHOP_ITEMS`，即 `app_config['shop_items']`）。
   *
   * 落盘形态由 `ShopPriceFetcher` 决定：`{ version: string, items: [{…附录 B §5.4 字段…}] }`。
   * **解析失败 / 结构非法 / 空目录 → 整份丢弃**（返回空 Map），调用方据此回落到本地行价。
   * 与写入侧同一口径：要么整份可信，要么当没有——不做部分应用。
   */
  async catalog(): Promise<Map<string, ShopItem>> {
    const out = new Map<string, ShopItem>();
    const raw: string | undefined = await this.cfg.get(ConfigKeys.SHOP_ITEMS);
    if (raw === undefined || raw.length === 0) {
      return out;
    }
    try {
      const root: JsonObject = asObject(JSON.parse(raw), 'shop_items');
      const version: string | undefined = optStr(root, 'version');
      if (version === undefined || version.length === 0) {
        return out;
      }
      const arr: JsonArray = asArray(ShopPriceFetcher.mustField(root, 'items'), 'shop_items.items');
      let i: number = 0;
      while (i < arr.length) {
        const o: JsonObject = asObject(arr[i], `shop_items.items[${i}]`);
        const id: string | undefined = optStr(o, 'id');
        const price: number | undefined = optNum(o, 'price');
        const section: string | undefined = optStr(o, 'section');
        // 单条非法即整份丢弃（与写入侧一致；不做"跳过坏行、应用好行"的部分应用）
        if (id === undefined || id.length === 0 || price === undefined || !Number.isFinite(price) || price < 0
          || (section !== 'frame' && section !== 'theme')) {
          return new Map<string, ShopItem>();
        }
        const name: string | undefined = optStr(o, 'name');
        const icon: string | undefined = optStr(o, 'icon');
        const order: number | undefined = optNum(o, 'order');
        const item: ShopItem = {
          id,
          section: section === 'theme' ? 'theme' : 'frame',
          name: name === undefined ? id : name,
          price: Math.round(price),
          icon: icon === undefined ? '' : icon,
          order: order === undefined || !Number.isFinite(order) ? 0 : Math.round(order),
          onShelf: optNum(o, 'onShelf') === 0 ? 0 : 1,
          isDefaultFree: optNum(o, 'isDefaultFree') === 0 ? 0 : 1,
        };
        const description: string | undefined = optStr(o, 'description');
        if (description !== undefined) {
          item.description = description;
        }
        out.set(id, item);
        i = i + 1;
      }
      return out;
    } catch (e) {
      return new Map<string, ShopItem>();
    }
  }

  /**
   * 当前生效的目录版本号（未取到过为空串）。
   * 供设置页/开发者选项展示"当前价目表来自哪一份后台目录"。
   */
  async catalogVersion(): Promise<string> {
    const raw: string | undefined = await this.cfg.get(ConfigKeys.SHOP_ITEMS);
    if (raw === undefined || raw.length === 0) {
      return '';
    }
    try {
      const root: JsonObject = asObject(JSON.parse(raw), 'shop_items');
      const version: string | undefined = optStr(root, 'version');
      return version === undefined ? '' : version;
    } catch (e) {
      return '';
    }
  }

  private static messageOf(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return `${e}`;
  }
}
