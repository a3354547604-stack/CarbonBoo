/**
 * LoadingOverlay —— 加载中遮罩（附录 C §4 通用组件）。
 *
 * 职责：首帧与耗时操作（数据库打开、同步、备份）期间给一个不阻塞理解的反馈；
 * `text` 走资源或调用方给的文案，颜色与字号只用 `AppTheme` 令牌。
 */
import { AppTheme } from '../util/AppTheme';

@Component
export struct LoadingOverlay {
  /** 是否显示（false 时整个组件不渲染任何内容）。 */
  @Prop visible: boolean = false;
  /** 提示文案（可传资源或字符串）。 */
  @Prop text: ResourceStr = '';

  build() {
    Column({ space: 12 }) {
      LoadingProgress().width(AppTheme.ICON_LG).height(AppTheme.ICON_LG).color(AppTheme.COLOR_PRIMARY)
      if (this.text !== '') {
        Text(this.text)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
      }
    }
    .width('100%')
    .padding({ top: 40, bottom: 40 })
  }
}
