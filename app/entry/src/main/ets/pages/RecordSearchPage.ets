/**
 * RecordSearchPage —— 记录搜索（附录 C §12，二级页 `recordSearch`）。
 *
 * 关键词、分类、时间区间三条件一起下推到 `RecordService.search()`，
 * 行与「合计」用同一组 WHERE，页面不做任何求和（铁律：页面不做业务计算）。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { RouteName, RouteParam, NavParams } from '../viewmodel/RouteName';
import { CarbonRecord, CategoryKey } from '../model/CarbonTypes';
import { SearchResult } from '../viewmodel/RecordService';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { DateUtil } from '../util/DateUtil';
import { PageHeader } from '../components/PageHeader';
import { EmptyView } from '../components/EmptyView';
import { categoryIcon } from '../components/RecordItem';

@Component
export struct RecordSearchPage {
  @Consume('navStack') stack: NavPathStack;
  @State keyword: string = '';
  @State category: CategoryKey | 'all' = 'all';
  @State records: CarbonRecord[] = [];
  @State total: number = 0;
  @State count: number = 0;
  @State fromMs: number = 0;
  @State toMs: number = 0;
  @State searched: boolean = false;
  @State ready: boolean = false;
  private now: number = 0;

  aboutToAppear(): void {
    const param: RouteParam = NavParams.take();
    const category: CategoryKey | undefined = param.category;
    this.now = Date.now();
    this.toMs = this.now;
    this.fromMs = DateUtil.addDays(this.now, -LiteralConstants.BACKDATE_DAYS);
    if (category !== undefined) {
      this.category = category;
    }
    this.ready = true;
    this.search();
  }

  private async search(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const result: SearchResult = await hub.records.search(
      hub.state.userId(), this.keyword, this.category, this.fromMs, this.toMs, 200
    );
    this.records = result.records;
    this.total = result.total;
    this.count = result.count;
    this.searched = true;
  }

  private pickFrom(): void {
    DatePickerDialog.show({
      start: new Date(DateUtil.addDays(this.now, -365)),
      end: new Date(this.now),
      selected: new Date(this.fromMs),
      onDateAccept: (value: Date) => {
        this.fromMs = value.getTime();
        this.search();
      }
    });
  }

  private pickTo(): void {
    DatePickerDialog.show({
      start: new Date(DateUtil.addDays(this.now, -365)),
      end: new Date(this.now),
      selected: new Date(this.toMs),
      onDateAccept: (value: Date) => {
        this.toMs = value.getTime();
        this.search();
      }
    });
  }

  private chips(): string[] {
    return ['all', 'travel', 'utility', 'recycle', 'plate'];
  }

  private chipLabel(key: string): string {
    if (key === 'all') {
      return '全部';
    }
    if (key === 'travel') {
      return '出行';
    }
    if (key === 'utility') {
      return '水电';
    }
    if (key === 'recycle') {
      return '回收';
    }
    return '光盘';
  }

  @Builder
  chipItem(key: string) {
    Text(this.chipLabel(key))
      .fontSize(AppTheme.FONT_CAPTION)
      .fontColor(this.category === key ? AppTheme.COLOR_SURFACE : AppTheme.COLOR_TEXT_SECONDARY)
      .backgroundColor(this.category === key ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_SURFACE)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(AppTheme.BTN_RADIUS)
      .onClick(() => {
        this.category = key === 'all' ? 'all' : RecordSearchPage.toCategory(key);
        this.search();
      })
  }

  private static toCategory(key: string): CategoryKey {
    if (key === 'utility') {
      return 'utility';
    }
    if (key === 'recycle') {
      return 'recycle';
    }
    if (key === 'plate') {
      return 'plate';
    }
    return 'travel';
  }

  private push(recordId: string): void {
    NavParams.set(RouteParam.record(recordId));
    this.stack.pushPath({ name: RouteName.RECORD_DETAIL });
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.record_search_title'),
        onBack: () => this.stack.pop()
      })

      Column({ space: AppTheme.CARD_GAP }) {
        Row({ space: AppTheme.CARD_GAP }) {
          TextInput({ placeholder: $r('app.string.record_search_hint'), text: this.keyword })
            .layoutWeight(1)
            .height(AppTheme.BTN_HEIGHT)
            .fontSize(AppTheme.FONT_BODY)
            .backgroundColor(AppTheme.COLOR_SURFACE)
            .onChange((value: string) => {
              this.keyword = value;
            })
            .onSubmit(() => this.search())
          Button($r('app.string.common_search'))
            .height(AppTheme.BTN_HEIGHT)
            .backgroundColor(AppTheme.COLOR_PRIMARY)
            .fontColor(AppTheme.COLOR_SURFACE)
            .fontSize(AppTheme.FONT_BODY)
            .onClick(() => this.search())
        }
        .width('100%')

        Row() {
          ForEach(this.chips(), (key: string) => {
            this.chipItem(key)
          }, (key: string) => key)
        }
        .width('100%')

        Row({ space: AppTheme.CARD_GAP }) {
          Text(Formatter.monthDay(this.fromMs))
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .height(AppTheme.BTN_HEIGHT)
            .backgroundColor(AppTheme.COLOR_SURFACE)
            .borderRadius(AppTheme.BTN_RADIUS)
            .onClick(() => this.pickFrom())
          Text('—')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_HINT)
          Text(Formatter.monthDay(this.toMs))
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .height(AppTheme.BTN_HEIGHT)
            .backgroundColor(AppTheme.COLOR_SURFACE)
            .borderRadius(AppTheme.BTN_RADIUS)
            .onClick(() => this.pickTo())
        }
        .width('100%')

        Text(`结果 ${this.count} 条 · 减排合计 ${Formatter.reduction(this.total)} kg`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .width('100%')
      }
      .width('100%')
      .padding({ top: AppTheme.CARD_GAP, bottom: AppTheme.CARD_GAP })

      if (this.searched && this.records.length === 0) {
        EmptyView({ text: '没有匹配的记录', hint: '试试换关键词或放宽时间范围' })
      } else {
        List({ space: 0 }) {
          ForEach(this.records, (record: CarbonRecord) => {
            ListItem() {
              Row({ space: AppTheme.CARD_GAP }) {
                Text(categoryIcon(record.category)).fontSize(AppTheme.ICON_MD)
                Column({ space: 2 }) {
                  Text(record.subType)
                    .fontSize(AppTheme.FONT_BODY)
                    .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                  Text(`${record.amount} ${record.unit} · ${Formatter.monthDay(record.occurredAt)}`)
                    .fontSize(AppTheme.FONT_CAPTION)
                    .fontColor(AppTheme.COLOR_TEXT_HINT)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text(`${Formatter.reduction(record.reductionKg)} kg`)
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                Text(`+${Formatter.points(record.pointAwarded)}`)
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_PRIMARY)
              }
              .width('100%')
              .height(AppTheme.BTN_HEIGHT + AppTheme.CARD_GAP)
              .onClick(() => this.push(record.id))
            }
          }, (record: CarbonRecord) => record.id)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
    .backgroundColor(AppTheme.COLOR_BG)
  }
}
