/**
 * EmptyView —— 空态（附录 C §4）。文案由页面传入（§24 文案清单里的原文）。
 */
import { AppTheme } from '../util/AppTheme';

@Component
export struct EmptyView {
  @Prop icon: string = '🌱';
  @Prop text: ResourceStr = '';
  @Prop hint: string = '';

  build() {
    Column({ space: 8 }) {
      Text(this.icon).fontSize(AppTheme.ICON_LG)
      Text(this.text)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
        .textAlign(TextAlign.Center)
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding({ top: 40, bottom: 40, left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
  }
}
