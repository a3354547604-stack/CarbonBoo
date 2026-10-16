/**
 * DevOptionsSheet —— 开发者选项半模态（附录 C §23.6）。**不提供任何绕过业务规则的开关。**
 * 触发：设置 → 关于与合规 → 连续点击版本号 7 次（LiteralConstants.DEV_TAP_COUNT）。
 */
import { AppTheme } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';

@Component
export struct DevOptionsSheet {
  @Prop breakSave: boolean = false;
  @Prop dbSizeBytes: number = 0;
  @Prop recordCount: number = 0;
  @Prop pointBalance: number = 0;
  @Prop busy: boolean = false;
  @Prop lastMessage: ResourceStr = '';
  onToggleBreakSave: (on: boolean) => void = () => {};
  onRebuildDailyStat: () => void = () => {};
  onSeedDemo: () => void = () => {};
  onClearDemo: () => void = () => {};
  onClose: () => void = () => {};

  build() {
    Column({ space: AppTheme.CARD_GAP }) {
      Row() {
        Text($r('app.string.dev_options_title'))
          .fontSize(AppTheme.FONT_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .layoutWeight(1)
        Text($r('app.string.common_close'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .onClick(() => this.onClose())
      }
      .width('100%')

      Text($r('app.string.dev_options_note'))
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_HINT)
        .width('100%')

      Row({ space: AppTheme.CARD_GAP }) {
        Column({ space: 2 }) {
          Text($r('app.string.dev_break_save'))
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          Text($r('app.string.dev_break_save_hint'))
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_HINT)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.breakSave })
          .selectedColor(AppTheme.COLOR_PRIMARY)
          .onChange((on: boolean) => this.onToggleBreakSave(on))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Text($r('app.string.dev_db_size')).fontSize(AppTheme.FONT_BODY).fontColor(AppTheme.COLOR_TEXT_SECONDARY).layoutWeight(1)
        Text(Formatter.fileSize(this.dbSizeBytes)).fontSize(AppTheme.FONT_BODY).fontColor(AppTheme.COLOR_TEXT_PRIMARY)
      }
      .width('100%')

      Row() {
        Text($r('app.string.dev_counts')).fontSize(AppTheme.FONT_BODY).fontColor(AppTheme.COLOR_TEXT_SECONDARY).layoutWeight(1)
        Text(`${this.recordCount} / ${Formatter.points(this.pointBalance)}`)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
      }
      .width('100%')

      Row({ space: AppTheme.CARD_GAP }) {
        Text($r('app.string.dev_rebuild'))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_PRIMARY)
          .layoutWeight(1)
          .height(AppTheme.BTN_HEIGHT)
          .textAlign(TextAlign.Center)
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => this.onRebuildDailyStat())
        Text($r('app.string.dev_seed'))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_PRIMARY)
          .layoutWeight(1)
          .height(AppTheme.BTN_HEIGHT)
          .textAlign(TextAlign.Center)
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => this.onSeedDemo())
        Text($r('app.string.dev_clear'))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_DANGER)
          .layoutWeight(1)
          .height(AppTheme.BTN_HEIGHT)
          .textAlign(TextAlign.Center)
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => this.onClearDemo())
      }
      .width('100%')

      if (this.lastMessage !== '') {
        Text(this.lastMessage).fontSize(AppTheme.FONT_CAPTION).fontColor(AppTheme.COLOR_TEXT_SECONDARY).width('100%')
      }
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
    .alignItems(HorizontalAlign.Start)
  }
}
