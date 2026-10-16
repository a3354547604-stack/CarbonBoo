/**
 * DemoModeBanner —— 演示模式常驻黄条（附录 C §4）。仅当 app_config['demo_mode']=1 时挂载。
 */
import { AppTheme } from '../util/AppTheme';

@Component
export struct DemoModeBanner {
  build() {
    Row({ space: 6 }) {
      Text('🧪').fontSize(AppTheme.FONT_BODY)
      Text($r('app.string.banner_demo_mode'))
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_WARNING)
        .layoutWeight(1)
    }
    .width('100%')
    .padding(AppTheme.CARD_GAP)
    .backgroundColor(AppTheme.COLOR_WARNING_BG)
    .borderRadius(AppTheme.BTN_RADIUS)
  }
}
