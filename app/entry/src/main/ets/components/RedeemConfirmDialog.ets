/**
 * RedeemConfirmDialog —— 兑换确认（附录 C §23.4）：商品/权益名 + 价格 + 当前余额 + 扣后余额。
 */
import { AppTheme } from '../util/AppTheme';

@Component
export struct RedeemConfirmDialog {
  @Prop title: string = '';
  @Prop priceText: string = '';
  @Prop balanceText: string = '';
  @Prop afterText: string = '';
  @Prop pending: boolean = false;
  onConfirm: () => void = () => {};
  onCancel: () => void = () => {};

  @Builder
  row(label: ResourceStr, value: string) {
    Row() {
      Text(label).fontSize(AppTheme.FONT_BODY).fontColor(AppTheme.COLOR_TEXT_SECONDARY).layoutWeight(1)
      Text(value).fontSize(AppTheme.FONT_BODY).fontColor(AppTheme.COLOR_TEXT_PRIMARY)
    }
    .width('100%')
  }

  build() {
    Column({ space: AppTheme.CARD_GAP }) {
      Text(this.title)
        .fontSize(AppTheme.FONT_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
        .width('100%')
      this.row($r('app.string.redeem_price'), this.priceText)
      this.row($r('app.string.redeem_balance'), this.balanceText)
      this.row($r('app.string.redeem_after'), this.afterText)
      Row({ space: AppTheme.CARD_GAP }) {
        Text($r('app.string.common_cancel'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .height(AppTheme.BTN_HEIGHT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => this.onCancel())
        Text($r('app.string.common_confirm'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_SURFACE)
          .height(AppTheme.BTN_HEIGHT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.pending ? AppTheme.COLOR_TEXT_HINT : AppTheme.COLOR_PRIMARY)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => {
            if (!this.pending) {
              this.onConfirm();
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
    .alignItems(HorizontalAlign.Start)
  }
}
