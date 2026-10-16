/**
 * AiRecognizeSheet —— 识图录入半模态（附录 C §23.1）。
 *
 * 规则落地：
 *  · 只给候选、必须用户确认才回填表单（`onConfirm` 由录入页处理），绝不自动保存；
 *  · `engine === 'mock'` 时常驻与 SimulationBanner 同级的「模拟识别」提示条；
 *  · **界面不展示置信度数字或准确率**（候选里哪怕带 confidence 也不呈现，只用于排序）；
 *  · 超时/识别失败由 ViewModel 判定，页面直接关闭并提示「识图不可用，请手动选择」。
 */
import { AiCandidate, AiRecognizeResult } from '../model/AiTypes';
import { CategoryKey } from '../model/CarbonTypes';
import { AppTheme } from '../util/AppTheme';
import { categoryIcon } from './RecordItem';
import { SimulationBanner } from './SimulationBanner';

export function emptyAiResult(): AiRecognizeResult {
  const r: AiRecognizeResult = { recognized: false, engine: 'mock' };
  return r;
}

@Component
export struct AiRecognizeSheet {
  @Prop result: AiRecognizeResult = emptyAiResult();
  @Prop imageUri: string = '';
  @Prop amount: number = 0;
  @Prop unit: string = '';
  @Prop pending: boolean = false;
  @State pickedCategory: CategoryKey = 'travel';
  @State pickedSubType: string = '';
  @State pickedName: string = '';
  @State amountText: string = '';
  onRequestImage: () => void = () => {};
  onConfirm: (category: CategoryKey, subType: string, amount: number) => void = () => {};
  onCancel: () => void = () => {};

  private candidateName(c: AiCandidate): string {
    return c.subType;
  }

  build() {
    Column({ space: AppTheme.CARD_GAP }) {
      Row() {
        Text($r('app.string.ai_title'))
          .fontSize(AppTheme.FONT_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .layoutWeight(1)
        Text($r('app.string.common_cancel'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .onClick(() => this.onCancel())
      }
      .width('100%')

      if (this.result.engine === 'mock') {
        SimulationBanner({ mode: 'ai' })
      }

      Row({ space: AppTheme.CARD_GAP }) {
        if (this.imageUri.length > 0) {
          Image(this.imageUri)
            .width(AppTheme.ICON_LG * 2)
            .height(AppTheme.ICON_LG * 2)
            .borderRadius(AppTheme.BTN_RADIUS)
        } else {
          Text('🖼️')
            .fontSize(AppTheme.ICON_LG)
            .width(AppTheme.ICON_LG * 2)
            .height(AppTheme.ICON_LG * 2)
            .textAlign(TextAlign.Center)
            .backgroundColor(AppTheme.COLOR_DISABLED_BG)
            .borderRadius(AppTheme.BTN_RADIUS)
        }
        Column({ space: 4 }) {
          if (this.result.recognized) {
            Text(`识别到：${categoryIcon(this.pickedCategory)} ${this.pickedName}`)
              .fontSize(AppTheme.FONT_BODY)
              .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          } else {
            Text($r('app.string.ai_degraded'))
              .fontSize(AppTheme.FONT_BODY)
              .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          }
          Text($r('app.string.ai_pick_hint'))
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_HINT)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        if (this.result.candidates !== undefined) {
          ForEach(this.result.candidates, (c: AiCandidate) => {
            Text(`${categoryIcon(c.category)} ${this.candidateName(c)}`)
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(this.pickedSubType === c.subType ? AppTheme.COLOR_SURFACE : AppTheme.COLOR_TEXT_PRIMARY)
              .backgroundColor(this.pickedSubType === c.subType ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_SURFACE)
              .borderRadius(AppTheme.BTN_RADIUS)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .margin(4)
              .onClick(() => {
                this.pickedCategory = c.category;
                this.pickedSubType = c.subType;
                this.pickedName = c.subType;
              })
          }, (c: AiCandidate) => c.subType)
        }
      }
      .width('100%')

      Row({ space: AppTheme.CARD_GAP }) {
        TextInput({ placeholder: $r('app.string.record_amount_hint'), text: this.amountText })
          .type(InputType.Number)
          .height(AppTheme.BTN_HEIGHT)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.amountText = v;
          })
        Text(this.unit.length > 0 ? this.unit : '').fontSize(AppTheme.FONT_BODY).fontColor(AppTheme.COLOR_TEXT_SECONDARY)
      }
      .width('100%')

      Row({ space: AppTheme.CARD_GAP }) {
        Text($r('app.string.ai_pick_image'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_PRIMARY)
          .height(AppTheme.BTN_HEIGHT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => this.onRequestImage())
        Text($r('app.string.ai_use'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_SURFACE)
          .height(AppTheme.BTN_HEIGHT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.pickedSubType.length === 0 || this.pending ? AppTheme.COLOR_TEXT_HINT : AppTheme.COLOR_PRIMARY)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => {
            if (this.pickedSubType.length === 0 || this.pending) {
              return;
            }
            const parsed: number = Number.parseFloat(this.amountText.length > 0 ? this.amountText : `${this.amount}`);
            const amount: number = Number.isNaN(parsed) ? this.amount : parsed;
            this.onConfirm(this.pickedCategory, this.pickedSubType, amount);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
    .alignItems(HorizontalAlign.Start)
  }
}
