/**
 * ShopItemCard —— 小铺商品卡（附录 C §4 / §15）：图标 + 名称 + 价格 + 按钮。
 * 按钮三态：已拥有 / 积分不足（置灰 + 还差 n 分）/ 可兑换。判定全部来自 ViewModel 的 ShopRules。
 */
import { ShopItem } from '../model/ShopTypes';
import { AppTheme } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';

export function emptyShopItem(): ShopItem {
  const item: ShopItem = {
    id: '', section: 'frame', name: '', price: 0, icon: '', order: 0, onShelf: 1, isDefaultFree: 0
  };
  return item;
}

@Component
export struct ShopItemCard {
  @Prop item: ShopItem = emptyShopItem();
  @Prop owned: boolean = false;
  @Prop affordable: boolean = true;
  @Prop shortfall: number = 0;
  @Prop inUse: boolean = false;
  onBuy: () => void = () => {};

  build() {
    Column({ space: 6 }) {
      Text('🖼️')
        .fontSize(AppTheme.ICON_LG)
        .width('100%')
        .textAlign(TextAlign.Center)
      Text(this.item.name)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
        .maxLines(1)
      Text(this.item.price === 0 ? $r('app.string.shop_free') : `${Formatter.points(this.item.price)} 分`)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
      if (this.inUse) {
        Text($r('app.string.shop_in_use'))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .borderRadius(AppTheme.BTN_RADIUS)
      } else if (this.owned) {
        Text($r('app.string.shop_owned'))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .borderRadius(AppTheme.BTN_RADIUS)
      } else if (!this.affordable) {
        Text(`积分不足，还差 ${Formatter.points(this.shortfall)} 分`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .borderRadius(AppTheme.BTN_RADIUS)
      } else {
        Text($r('app.string.shop_redeem'))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_SURFACE)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(AppTheme.COLOR_PRIMARY)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => this.onBuy())
      }
    }
    .layoutWeight(1)
    .padding(AppTheme.CARD_PADDING)
    .backgroundColor(AppTheme.COLOR_SURFACE)
    .borderRadius(AppTheme.CARD_RADIUS)
  }
}
