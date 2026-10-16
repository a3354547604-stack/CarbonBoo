/**
 * RecordDetailPage —— 记录明细（附录 C §11，二级页 `recordDetail`）。
 *
 * 因子快照四行**必须逐项展示**（铁律 3）：因子值 / 因子版本 / 数据来源 / 可信度。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { RouteParam, NavParams, RouteName } from '../viewmodel/RouteName';
import { CarbonRecord } from '../model/CarbonTypes';
import { PointBalance } from '../model/PointTypes';
import { AppTheme } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { PageHeader } from '../components/PageHeader';
import { SectionCard } from '../components/SectionCard';
import { EmptyView } from '../components/EmptyView';
import { LoadingOverlay } from '../components/LoadingOverlay';
import { categoryIcon } from '../components/RecordItem';

@Component
export struct RecordDetailPage {
  @Consume('navStack') stack: NavPathStack;
  @State record: CarbonRecord | undefined = undefined;
  @State balance: PointBalance | undefined = undefined;
  @State loaded: boolean = false;
  @State ready: boolean = false;
  @State showDelete: boolean = false;
  @State busy: boolean = false;
  private recordId: string = '';

  aboutToAppear(): void {
    const param: RouteParam = NavParams.take();
    const id: string | undefined = param.recordId;
    this.recordId = id === undefined ? '' : id;
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    this.record = await hub.records.detail(userId, this.recordId);
    this.balance = await hub.points.balance(userId, Date.now());
    this.loaded = true;
    this.ready = true;
  }

  private async deleteRecord(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const hub: ServiceHub = ServiceHub.get();
    const result = await hub.records.remove(hub.state.userId(), this.recordId, Date.now());
    this.busy = false;
    this.showDelete = false;
    if (result.ok) {
      this.stack.pop();
    } else {
      this.getUIContext().getPromptAction().showToast({
        message: result.message === undefined ? '删除失败' : result.message
      });
    }
  }

  private factorLabel(): string {
    if (this.record === undefined) {
      return '';
    }
    return `${this.record.factorSource}`;
  }

  @Builder
  infoRow(label: ResourceStr, value: string) {
    Row() {
      Text(label)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
        .layoutWeight(1)
      Text(value)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.record_detail_title'),
        onBack: () => this.stack.pop()
      })

      if (!this.ready) {
        LoadingOverlay({ visible: true, text: '' })
      } else if (this.record === undefined) {
        EmptyView({ text: '记录不存在或已删除', hint: '返回列表刷新看看' })
      } else {
        Scroll() {
          Column({ space: AppTheme.CARD_GAP }) {
            SectionCard({ showTitle: false }) {
              Row({ space: AppTheme.CARD_GAP }) {
                Text(categoryIcon(this.record.category)).fontSize(AppTheme.ICON_LG)
                Column({ space: 4 }) {
                  Text(`${this.record.subType}`)
                    .fontSize(AppTheme.FONT_SECTION)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                  Text(`${this.record.amount} ${this.record.unit}`)
                    .fontSize(AppTheme.FONT_BODY)
                    .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              Text(`减排 ${Formatter.reduction(this.record.reductionKg)} kgCO₂e`)
                .fontSize(AppTheme.FONT_NUMBER_MD)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.COLOR_PRIMARY)
                .width('100%')
            }

            SectionCard({ title: $r('app.string.record_point_card'), showTitle: true }) {
              this.infoRow($r('app.string.record_point_actual'),
                `${Formatter.points(this.record.pointAwarded)} 分`)
              this.infoRow($r('app.string.record_point_expected'),
                `${Formatter.points(ServiceHub.get().records.pointExpectedOf(this.record))} 分`)
              if (this.balance !== undefined) {
                this.infoRow($r('app.string.record_point_today'),
                  `${Formatter.points(this.balance.todayRecordPoint)} / ${Formatter.points(this.balance.cap)} 分`)
              }
              if (this.record.pointCapped === 1) {
                Text($r('app.string.record_point_capped_hint'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_WARNING)
                  .width('100%')
              }
            }

            SectionCard({ title: $r('app.string.record_snapshot'), showTitle: true }) {
              this.infoRow($r('app.string.record_snapshot_value'),
                `${Formatter.number(this.record.factorValue, 'factor')} kg/${this.record.unit}`)
              this.infoRow($r('app.string.record_snapshot_version'), this.record.factorVersion)
              this.infoRow($r('app.string.record_snapshot_source'), this.factorLabel())
              this.infoRow($r('app.string.record_snapshot_confidence'), this.record.confidence)
            }

            SectionCard({ showTitle: false }) {
              this.infoRow($r('app.string.record_occurred_at'), Formatter.dateTime(this.record.occurredAt))
              this.infoRow($r('app.string.record_created_at'), Formatter.dateTime(this.record.createdAt))
              if (this.record.note !== undefined && this.record.note.length > 0) {
                this.infoRow($r('app.string.record_note'), this.record.note)
              }
            }

            Row({ space: AppTheme.CARD_GAP }) {
              Button($r('app.string.common_edit'))
                .layoutWeight(1)
                .height(AppTheme.BTN_HEIGHT)
                .backgroundColor(AppTheme.COLOR_SURFACE)
                .fontColor(AppTheme.COLOR_PRIMARY)
                .onClick(() => {
                  NavParams.set(RouteParam.record(this.recordId));
                  this.stack.pushPath({ name: RouteName.RECORD_EDIT });
                })
              Button($r('app.string.common_delete'))
                .layoutWeight(1)
                .height(AppTheme.BTN_HEIGHT)
                .backgroundColor(AppTheme.COLOR_DANGER)
                .fontColor(AppTheme.COLOR_SURFACE)
                .onClick(() => {
                  this.showDelete = true;
                })
            }
            .width('100%')
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
    .backgroundColor(AppTheme.COLOR_BG)
    .bindSheet($$this.showDelete, this.deleteSheetBuilder(), {
      detents: [SheetSize.MEDIUM],
      dragBar: true,
      title: { title: $r('app.string.record_delete_confirm_title') }
    })
  }

  @Builder
  deleteSheetBuilder() {
    Column({ space: AppTheme.CARD_GAP }) {
      Text($r('app.string.record_delete_confirm_msg'))
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
        .width('100%')
      Row({ space: AppTheme.CARD_GAP }) {
        Button($r('app.string.common_cancel'))
          .layoutWeight(1)
          .height(AppTheme.BTN_HEIGHT)
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .onClick(() => {
            this.showDelete = false;
          })
        Button($r('app.string.common_confirm'))
          .layoutWeight(1)
          .height(AppTheme.BTN_HEIGHT)
          .backgroundColor(AppTheme.COLOR_DANGER)
          .fontColor(AppTheme.COLOR_SURFACE)
          .onClick(() => this.deleteRecord())
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
  }
}
