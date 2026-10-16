/**
 * ShopService —— 碳小铺（S4 外观闭环）：商品列表、购买幂等、头像框授权。
 *
 * 职责：
 *  ① 商品：从 `shop_item` 读上架商品，按 `section`（头像框 / 主题）分组；
 *  ② 购买：**一个事务**里写 `user_purchase` + 负额 `point_record(purchase)`，
 *     幂等键 `source_id = 商品 id`（`uq_up` 保证不可重复购买），并刷新当日缓存；
 *  ③ 授权：已购头像框列表供外观页使用；集齐 8 个头像框由 `RewardService` 解锁「种树人」；
 *  ④ 定价：价格可能被后台下发覆盖（`app_config['shop_prices']`），
 *     取价失败时**整份丢弃**回退内置默认价（铁律 1 的网络例外之一）。
 *
 * 铁律 4：扣分只能写流水，不能直接改余额——余额永远是流水聚合的结果。
 */
import { ShopItem } from '../model/ShopTypes';
import { ShopRules, PurchaseCheck } from './domain/ShopRules';
import { StorePort, firstOf, numOf, textOf } from './store/StorePort';
import { RowMapper } from './store/RowMapper';
import { PointService } from './PointService';
import { AppState } from './AppState';
import { IdUtil } from './domain/IdUtil';
import { AppResult, fail, ok } from '../model/Result';
import { JsonObject, asObject, optNum } from '../util/JsonUtil';

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

  constructor(store: StorePort, state: AppState, points: PointService) {
    this.store = store;
    this.state = state;
    this.points = points;
  }

  /** 某分区的上架商品（按 order）。 */
  async items(section: 'frame' | 'theme'): Promise<ShopItem[]> {
    const rows = await this.store.query('SELECT * FROM shop_item WHERE section = ? AND on_shelf = 1 ORDER BY "order" ASC', [section]);
    const items: ShopItem[] = RowMapper.shopItems(rows);
    const prices = await this.remotePrices();
    const out: ShopItem[] = [];
    let i: number = 0;
    while (i < items.length) {
      const item: ShopItem = items[i];
      const remote: number | undefined = prices.get(item.id);
      if (remote !== undefined && remote >= 0) {
        item.price = remote;
      }
      out.push(item);
      i = i + 1;
    }
    return out;
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
    const remote: number | undefined = (await this.remotePrices()).get(itemId);
    if (remote !== undefined && remote >= 0) {
      item.price = remote;
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
   * 后台下发的价格（`app_config['shop_prices']`，JSON：`{itemId: price}`）。
   * 解析失败或字段非法 → **整份丢弃**（回退内置价），不做部分应用。
   */
  async remotePrices(): Promise<Map<string, number>> {
    const out = new Map<string, number>();
    const rows = await this.store.query("SELECT value FROM app_config WHERE id = 'shop_prices'", []);
    const row = firstOf(rows);
    if (row === undefined) {
      return out;
    }
    const text: string = textOf(row, 'value');
    if (text.length === 0) {
      return out;
    }
    try {
      const parsed: Object = JSON.parse(text);
      const obj: JsonObject = asObject(parsed, 'shop_prices');
      const keys: string[] = Object.keys(obj);
      let i: number = 0;
      while (i < keys.length) {
        const v: number | undefined = optNum(obj, keys[i]);
        if (v !== undefined && Number.isFinite(v) && v >= 0) {
          out.set(keys[i], Math.round(v));
        }
        i = i + 1;
      }
      return out;
    } catch (e) {
      return new Map<string, number>();
    }
  }

  private static messageOf(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return `${e}`;
  }
}
