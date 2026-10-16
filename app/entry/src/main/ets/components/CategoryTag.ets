/**
 * CategoryTag —— 分类小标签（附录 C §4）。分类名与分类色都取自 AppTheme，页面不写颜色字面量。
 */
import { CategoryKey } from '../model/CarbonTypes';
import { AppTheme } from '../util/AppTheme';

@Component
export struct CategoryTag {
  @Prop category: CategoryKey = 'travel';
  @Prop compact: boolean = false;

  build() {
    Text(AppTheme.categoryName(this.category))
      .fontSize(AppTheme.FONT_CAPTION)
      .fontColor(AppTheme.COLOR_SURFACE)
      .backgroundColor(AppTheme.categoryColor(this.category))
      .borderRadius(AppTheme.BTN_RADIUS)
      .padding({ left: this.compact ? 6 : 8, right: this.compact ? 6 : 8, top: 2, bottom: 2 })
  }
}
