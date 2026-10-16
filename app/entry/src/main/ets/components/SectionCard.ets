/**
 * SectionCard —— 卡片容器（附录 C §4）：白色底 + 12vp 圆角 + 16vp 内边距 + 可选标题。
 */
import { AppTheme } from '../util/AppTheme';

@Component
export struct SectionCard {
  @Prop title: ResourceStr = '';
  @Prop showTitle: boolean = false;
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {}

  build() {
    Column({ space: AppTheme.CARD_GAP }) {
      if (this.showTitle) {
        Text(this.title)
          .fontSize(AppTheme.FONT_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .width('100%')
      }
      this.content()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AppTheme.CARD_PADDING)
    .backgroundColor(AppTheme.COLOR_SURFACE)
    .borderRadius(AppTheme.CARD_RADIUS)
  }
}
