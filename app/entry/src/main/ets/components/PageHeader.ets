/**
 * PageHeader —— 二级页页头（附录 C §4）：返回 + 标题 + 右动作，高 48vp。
 * 右动作走 `@BuilderParam`，页面把自己的按钮 builder 传进来。
 */
import { AppTheme } from '../util/AppTheme';

@Component
export struct PageHeader {
  @Prop title: ResourceStr = '';
  @Prop showBack: boolean = true;
  @BuilderParam rightAction: () => void = this.emptyRight;
  onBack: () => void = () => {};

  @Builder
  emptyRight() {}

  build() {
    Row() {
      if (this.showBack) {
        Text('‹')
          .fontSize(AppTheme.FONT_NUMBER_MD)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .width(AppTheme.ICON_LG)
          .height(AppTheme.HEADER_HEIGHT)
          .textAlign(TextAlign.Center)
          .onClick(() => this.onBack())
      }
      Text(this.title)
        .fontSize(AppTheme.FONT_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      this.rightAction()
    }
    .width('100%')
    .height(AppTheme.HEADER_HEIGHT)
    .alignItems(VerticalAlign.Center)
  }
}
