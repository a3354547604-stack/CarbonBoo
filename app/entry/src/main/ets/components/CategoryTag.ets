/**
 * CategoryTag —— 分类色小胶囊（附录 C §4.165 `cat_*`）。分类名与分类色都取自 AppTheme，页面不写颜色字面量。
 *
 * 归属（t23 / 验证 F9）：本组件由 `pages/RecordSearchPage.ets` 的「分类筛选」行使用 ——
 * 附录 C §搜索页 的 `[全部] [出行] [水电] [回收] [光盘]` 五个筛选项里，四个分类项（出行/水电/回收/光盘）
 * 走本组件的分类色（= 附录 C §933 的分类色表），选中态由本组件的 `selected` 反色为白底 + 分类色描边。
 * 未选中的「全部」没有分类色，仍由页面自绘 chip。
 * ⚠️ 本组件此前全仓零引用、掉在编译图外（assembleHap 的 BUILD SUCCESSFUL 盖不住它），
 *    接线后它的代码才真正受编译器校验。
 */
import { CategoryKey } from '../model/CarbonTypes';
import { AppTheme } from '../util/AppTheme';

@Component
export struct CategoryTag {
  @Prop category: CategoryKey = 'travel';
  /** 紧凑模式：更小的内边距（列表行内用）。 */
  @Prop compact: boolean = false;
  /** 选中态：反色为白底 + 分类色文字 + 分类色描边；未选中为分类色底 + 白字。 */
  @Prop selected: boolean = false;

  build() {
    Text(AppTheme.categoryName(this.category))
      .fontSize(AppTheme.FONT_CAPTION)
      .fontColor(this.selected ? AppTheme.categoryColor(this.category) : AppTheme.COLOR_SURFACE)
      .backgroundColor(this.selected ? AppTheme.COLOR_SURFACE : AppTheme.categoryColor(this.category))
      .borderRadius(AppTheme.BTN_RADIUS)
      .borderWidth(1)
      .borderColor(this.selected ? AppTheme.categoryColor(this.category) : AppTheme.COLOR_SURFACE)
      .padding({ left: this.compact ? 6 : 8, right: this.compact ? 6 : 8, top: 2, bottom: 2 })
  }
}
