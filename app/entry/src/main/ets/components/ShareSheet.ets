/**
 * ShareSheet —— 分享卡片半模态（附录 C §23.2）。
 *
 * 这一层**只做呈现与选择**：尺寸切换、卡面预览、把「保存」「分享」两个意图交给页面
 * （页面调 `ShareService` 完成离屏渲染与相册写入）。卡面固定不含姓名/学校/队名。
 */
import { AppTheme } from '../util/AppTheme';
import { CardRenderer, CardSize, ShareCardData } from '../util/CardRenderer';
import { SegmentedBar, SegmentOption } from './SegmentedBar';

const CARD_SIZES: SegmentOption[] = [
  SegmentOption.of(CardSize.VERTICAL, '1080×1440 竖版'),
  SegmentOption.of(CardSize.SQUARE, '1080×1080 方版')
];

@Component
export struct ShareSheet {
  @Prop data: ShareCardData = new ShareCardData();
  @Prop pending: boolean = false;
  @Prop message: string = '';
  @State cardSize: string = CardSize.VERTICAL;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  onClose: () => void = () => {};
  onSave: (size: string) => void = () => {};
  onShare: (size: string) => void = () => {};

  /** 预览高度按所选尺寸等比换算（竖版更高）。 */
  private previewHeight(): number {
    const w: number = 240;
    return this.cardSize === CardSize.SQUARE ? w : w * CardSize.VERTICAL_H / CardSize.VERTICAL_W;
  }

  build() {
    Column({ space: AppTheme.CARD_GAP }) {
      Row() {
        Text($r('app.string.share_title'))
          .fontSize(AppTheme.FONT_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .layoutWeight(1)
        Text($r('app.string.common_close'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .onClick(() => this.onClose())
      }
      .width('100%')

      SegmentedBar({
        options: CARD_SIZES,
        selected: this.cardSize,
        onSelect: (key: string) => {
          this.cardSize = key;
        }
      })

      Row() {
        Canvas(this.ctx)
          .width(240)
          .height(this.previewHeight())
          .onReady(() => {
            CardRenderer.draw(this.ctx, this.cardSize, this.data);
          })
          .onAreaChange(() => {
            CardRenderer.draw(this.ctx, this.cardSize, this.data);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      if (this.message.length > 0) {
        Text(this.message).fontSize(AppTheme.FONT_CAPTION).fontColor(AppTheme.COLOR_TEXT_SECONDARY).width('100%')
      }

      Row({ space: AppTheme.CARD_GAP }) {
        Text($r('app.string.share_save_album'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_SURFACE)
          .layoutWeight(1)
          .height(AppTheme.BTN_HEIGHT)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.pending ? AppTheme.COLOR_TEXT_HINT : AppTheme.COLOR_PRIMARY)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => {
            if (!this.pending) {
              this.onSave(this.cardSize);
            }
          })
        Text($r('app.string.share_system'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_PRIMARY)
          .layoutWeight(1)
          .height(AppTheme.BTN_HEIGHT)
          .textAlign(TextAlign.Center)
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => this.onShare(this.cardSize))
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
    .alignItems(HorizontalAlign.Start)
  }
}
