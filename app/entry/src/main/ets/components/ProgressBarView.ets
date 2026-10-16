/**
 * ProgressBarView —— 细进度条（附录 C §4）。percent 已由 ViewModel 截顶到 0~100。
 */
import { AppTheme } from '../util/AppTheme';

@Component
export struct ProgressBarView {
  @Prop percent: number = 0;
  @Prop color: string = AppTheme.COLOR_PRIMARY;

  build() {
    Row() {
      Row()
        .width(`${this.percent <= 0 ? 0 : (this.percent > 100 ? 100 : this.percent)}%`)
        .height(6)
        .backgroundColor(this.color)
        .borderRadius(3)
    }
    .width('100%')
    .height(6)
    .backgroundColor(AppTheme.COLOR_DIVIDER)
    .borderRadius(3)
  }
}
