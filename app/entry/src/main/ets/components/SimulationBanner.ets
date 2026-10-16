/**
 * SimulationBanner —— 「模拟演示」黄条（附录 C §4 / §19）。
 * 两段文案都取自 string 资源（§24 文案清单），页面不写字面量。
 *
 * mode='include' 碳普惠提示条；mode='ai' 识图模拟识别提示条。
 */
import { AppTheme } from '../util/AppTheme';

@Component
export struct SimulationBanner {
  @Prop mode: string = 'include';

  build() {
    Row({ space: 6 }) {
      Text('⚠️').fontSize(AppTheme.FONT_BODY)
      Text(this.mode === 'ai' ? $r('app.string.banner_ai_mock') : $r('app.string.banner_include'))
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
