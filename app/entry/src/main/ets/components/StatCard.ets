/**
 * StatCard —— 小统计卡（附录 C §4）：标题 + 大数字 + 副文案 + 可选点击。
 */
import { AppTheme } from '../util/AppTheme';

@Component
export struct StatCard {
  @Prop label: ResourceStr = '';
  @Prop value: string = '';
  @Prop sub: string = '';
  onTap?: () => void;

  build() {
    Column({ space: 4 }) {
      Text(this.label).fontSize(AppTheme.FONT_CAPTION).fontColor(AppTheme.COLOR_TEXT_SECONDARY)
      Text(this.value)
        .fontSize(AppTheme.FONT_NUMBER_MD)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
      if (this.sub.length > 0) {
        Text(this.sub).fontSize(AppTheme.FONT_CAPTION).fontColor(AppTheme.COLOR_TEXT_HINT)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .padding(AppTheme.CARD_PADDING)
    .backgroundColor(AppTheme.COLOR_SURFACE)
    .borderRadius(AppTheme.CARD_RADIUS)
    .onClick(() => {
      if (this.onTap !== undefined) {
        this.onTap();
      }
    })
  }
}
