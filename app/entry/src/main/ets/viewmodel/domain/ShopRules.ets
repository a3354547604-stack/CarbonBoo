/**
 * ShopRules —— 碳小铺购买的**纯判定**（不允许透支、不可重复购买、不退款）。
 *
 * 职责：把「能不能买」与「买完余额是多少」变成可断言的三行代码，
 * 页面只负责把结果画成按钮置灰与提示文案（附录 C §15）。
 *
 * 依据：附录 C §15 规则——已拥有显示「已拥有」且置灰；余额不足按钮置灰并提示
 * 「积分不足，还差 {n} 分」；集齐 8 个头像框立即解锁 `B_TREE`。
 */
import { ShopItem } from '../../model/ShopTypes';

/** 购买判定结果。 */
export interface PurchaseCheck {
  allowed: boolean;
  /** 机器可读原因：`ok` / `owned` / `insufficient` / `off_shelf`。 */
  code: string;
  /** 给人看的一句话（按钮下方或 Toast）。 */
  message: string;
  /** 还差多少分（仅 `insufficient` 时有意义）。 */
  shortfall: number;
}

export class ShopRules {
  /**
   * 购买前判定。
   * @param item 商品
   * @param balance 当前积分余额
   * @param owned 是否已拥有
   */
  static check(item: ShopItem, balance: number, owned: boolean): PurchaseCheck {
    if (item.onShelf !== 1) {
      return { allowed: false, code: 'off_shelf', message: '该商品已下架', shortfall: 0 };
    }
    if (owned) {
      return { allowed: false, code: 'owned', message: '已拥有', shortfall: 0 };
    }
    if (balance < item.price) {
      return {
        allowed: false,
        code: 'insufficient',
        message: `积分不足，还差 ${ShopRules.shortfall(balance, item.price)} 分`,
        shortfall: ShopRules.shortfall(balance, item.price),
      };
    }
    return { allowed: true, code: 'ok', message: '', shortfall: 0 };
  }

  /** 还差多少分（不足时为正数）。 */
  static shortfall(balance: number, price: number): number {
    const diff: number = price - balance;
    return diff > 0 ? diff : 0;
  }

  /** 购买后余额（调用方已确认可买）。 */
  static balanceAfter(balance: number, price: number): number {
    return balance - price;
  }

  /** 集齐头像框是否解锁「种树人」（8/8）。 */
  static treeUnlocked(frameCount: number, total: number): boolean {
    return frameCount >= total;
  }

  /** 已拥有的商品 id 集合（来自 `user_purchase`）。 */
  static ownedIds(purchasedIds: string[]): string[] {
    return purchasedIds;
  }
}
