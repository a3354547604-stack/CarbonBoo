/**
 * UnlockCelebrationDialog —— 目标达成 / 徽章解锁庆祝（附录 C §23.5）。
 * 徽章是纯荣誉：`points === 0` 时显示「荣誉徽章，不发放积分」（与 §24 文案一致）。
 */
import { AppTheme } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';

@Component
export struct UnlockCelebrationDialog {
  @Prop icon: string = '🏅';
  @Prop name: string = '';
  @Prop points: number = 0;
  @Prop badge: boolean = false;
  onClose: () => void = () => {};

  build() {
    Column({ space: AppTheme.CARD_GAP }) {
      Text(this.icon.length > 0 ? this.icon : '🏅')
        .fontSize(AppTheme.FONT_NUMBER_LG * 1.6)
        .width(AppTheme.AVATAR_SIZE * 1.6)
        .height(AppTheme.AVATAR_SIZE * 1.6)
        .textAlign(TextAlign.Center)
        .backgroundColor(AppTheme.COLOR_DISABLED_BG)
        .borderRadius(AppTheme.AVATAR_SIZE)
      Text(this.name)
        .fontSize(AppTheme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
      if (this.badge) {
        Text($r('app.string.badge_honor_only'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
      } else {
        Text(`已获得 +${Formatter.points(this.points)} 分`)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_PRIMARY)
      }
      Text($r('app.string.common_got_it'))
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_SURFACE)
        .width('100%')
        .height(AppTheme.BTN_HEIGHT)
        .textAlign(TextAlign.Center)
        .backgroundColor(AppTheme.COLOR_PRIMARY)
        .borderRadius(AppTheme.BTN_RADIUS)
        .onClick(() => this.onClose())
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
    .alignItems(HorizontalAlign.Center)
  }
}
