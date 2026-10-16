/**
 * ShopTypes —— 碳小铺与外观域类型。
 *
 * 职责：定义商品 `ShopItem`（8 个头像框 + 1 套免费默认主题）与外观设置 `Appearance`。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §4 + §8.3 + §8.4。
 * 规则：购买永久拥有、不可重复购买、不允许透支、不退款；8 个头像框总价 51,000 分，
 *       集齐解锁徽章 `B_TREE`「种树人」；8 个头像全部免费，不支持上传。
 */
export interface ShopItem {
  id: string;
  section: 'frame' | 'theme';
  name: string;
  description?: string;
  price: number;
  icon: string;
  order: number;
  onShelf: number;
  /** 默认免费主题 = 1。 */
  isDefaultFree: number;
}

export interface Appearance {
  avatarId: string;
  /** `undefined` = 不佩戴。 */
  frameId?: string;
  themeId: string;
  /** 选填，分享卡片用；留空显示「碳小布用户」。 */
  nickname?: string;
}
