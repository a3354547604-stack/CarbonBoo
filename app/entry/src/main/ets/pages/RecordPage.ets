/**
 * RecordPage —— 记录列表（附录 C §7，Tab2）。
 * 分组（今天/昨天/MM月DD日）、左滑编辑删除、点行进明细、🔍进搜索、分页 20 条滚动加载。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { CarbonRecord, CategoryKey } from '../model/CarbonTypes';
import { RouteName, RouteParam, NavParams } from '../viewmodel/RouteName';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { SegmentedBar, SegmentOption, Segments } from '../components/SegmentedBar';
import { RecordItem, emptyRecord } from '../components/RecordItem';
import { EmptyView } from '../components/EmptyView';
import { DemoModeBanner } from '../components/DemoModeBanner';

/** 一天的记录分组。 */
class DayGroup {
  label: string = '';
  records: CarbonRecord[] = [];
}

@Component
export struct RecordPage {
  @Prop @Watch('onTick') tick: number = 0;
  scroller: Scroller = new Scroller();
  @Consume('navStack') stack: NavPathStack;
  @State groups: DayGroup[] = [];
  @State filter: CategoryKey | 'all' = 'all';
  @State isDemo: boolean = false;
  @State loading: boolean = false;
  @State hasMore: boolean = true;
  @State empty: boolean = false;
  private listOffset: number = 0;
  private names: Map<string, string> = new Map<string, string>();

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.listOffset = 0;
    this.hasMore = true;
    const hub: ServiceHub = ServiceHub.get();
    const page: CarbonRecord[] = await hub.records.page(hub.state.userId(), this.filter, 0, LiteralConstants.PAGE_SIZE);
    this.groups = this.group(page);
    this.empty = page.length === 0;
    this.listOffset = page.length;
    this.isDemo = await hub.state.demoFlag();
  }

  private async loadMore(): Promise<void> {
    if (this.loading || !this.hasMore) {
      return;
    }
    this.loading = true;
    const hub: ServiceHub = ServiceHub.get();
    const page: CarbonRecord[] = await hub.records.page(hub.state.userId(), this.filter, this.listOffset, LiteralConstants.PAGE_SIZE);
    if (page.length < LiteralConstants.PAGE_SIZE) {
      this.hasMore = false;
    }
    this.listOffset = this.listOffset + page.length;
    const merged: CarbonRecord[] = [];
    for (const g of this.groups) {
      for (const r of g.records) {
        merged.push(r);
      }
    }
    for (const r of page) {
      merged.push(r);
    }
    this.groups = this.group(merged);
    this.loading = false;
  }

  /** 按今天/昨天/日期分组（组内 occurredAt 倒序，查询已排序）。 */
  private group(records: CarbonRecord[]): DayGroup[] {
    const now: number = Date.now();
    const out: DayGroup[] = [];
    for (const r of records) {
      const label: string = Formatter.dayGroupLabel(r.occurredAt, now);
      let target: DayGroup | undefined = undefined;
      for (const g of out) {
        if (g.label === label) {
          target = g;
        }
      }
      if (target === undefined) {
        const g: DayGroup = new DayGroup();
        g.label = label;
        g.records = [];
        out.push(g);
        target = g;
      }
      target.records.push(r);
    }
    return out;
  }

  private nameOf(subType: string): string {
    const cached: string | undefined = this.names.get(subType);
    if (cached !== undefined) {
      return cached;
    }
    const item = ServiceHub.get().records.factorItemOf(subType);
    const name: string = item === undefined ? subType : item.name;
    this.names.set(subType, name);
    return name;
  }

  private push(name: string, param?: RouteParam): void {
    NavParams.set(param);
    this.stack.pushPath({ name: name });
  }

  private async removeRecord(record: CarbonRecord): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const result = await hub.records.remove(hub.state.userId(), record.id, Date.now());
    if (result.ok) {
      this.getUIContext().getPromptAction().showToast({ message: '已删除（积分已按差额冲正）' });
      this.reload();
    } else {
      this.getUIContext().getPromptAction().showToast({ message: result.message !== undefined ? result.message : '删除失败' });
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: AppTheme.CARD_GAP }) {
        if (this.isDemo) {
          DemoModeBanner()
        }
        Row({ space: AppTheme.CARD_GAP }) {
          Text($r('app.string.tab_record'))
            .fontSize(AppTheme.FONT_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
            .layoutWeight(1)
          Text('🔍').fontSize(AppTheme.ICON_MD).onClick(() => this.push(RouteName.RECORD_SEARCH))
        }
        .width('100%')

        SegmentedBar({
          options: Segments.CATEGORY, selected: this.filter,
          onSelect: (key: string) => {
            this.filter = toCategoryFilter(key);
            this.reload();
          }
        })

        if (this.empty) {
          EmptyView({ text: '记录第一笔，开始你的碳足迹', hint: '点右下角「＋ 记一笔」' })
        } else {
          List({ space: 0, scroller: this.scroller }) {
            ForEach(this.groups, (group: DayGroup) => {
              ListItemGroup({ header: this.groupHeader(group.label) }) {
                ForEach(group.records, (record: CarbonRecord) => {
                  ListItem() {
                    RecordItem({ record: record, name: this.nameOf(record.subType) })
                  }
                  .swipeAction({ end: this.swipeButtons(record) })
                  .onClick(() => this.push(RouteName.RECORD_DETAIL, RouteParam.record(record.id)))
                }, (record: CarbonRecord) => record.id)
              }
            }, (group: DayGroup) => group.label)
          }
          .width('100%')
          .layoutWeight(1)
          .onReachEnd(() => {
            this.loadMore();
          })
        }
      }
      .width('100%')
      .height('100%')
      .padding(AppTheme.PAGE_PADDING)

      Text($r('app.string.fab_record'))
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_SURFACE)
        .height(AppTheme.FAB_SIZE)
        .padding({ left: AppTheme.CARD_PADDING, right: AppTheme.CARD_PADDING })
        .textAlign(TextAlign.Center)
        .backgroundColor(AppTheme.COLOR_PRIMARY)
        .borderRadius(AppTheme.FAB_SIZE / 2)
        .margin({ right: AppTheme.PAGE_PADDING, bottom: AppTheme.PAGE_PADDING + AppTheme.TAB_HEIGHT })
        .onClick(() => this.push(RouteName.RECORD_EDIT, RouteParam.of(this.filter === 'all' ? undefined : this.filter)))
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.COLOR_BG)
  }

  @Builder
  groupHeader(label: string) {
    Text(label)
      .fontSize(AppTheme.FONT_CAPTION)
      .fontColor(AppTheme.COLOR_TEXT_HINT)
      .width('100%')
      .padding({ top: 10, bottom: 6 })
  }

  @Builder
  swipeButtons(record: CarbonRecord) {
    Row() {
      Text($r('app.string.common_edit'))
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_SURFACE)
        .width(72)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor(AppTheme.COLOR_PRIMARY)
        .onClick(() => this.push(RouteName.RECORD_EDIT, RouteParam.record(record.id)))
      Text($r('app.string.common_delete'))
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_SURFACE)
        .width(72)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor(AppTheme.COLOR_DANGER)
        .onClick(() => {
          this.getUIContext().showAlertDialog({
            title: $r('app.string.record_delete_confirm_title'),
            message: $r('app.string.record_delete_confirm_msg'),
            primaryButton: {
              value: $r('app.string.common_cancel'),
              action: () => {}
            },
            secondaryButton: {
              value: $r('app.string.common_delete'),
              action: () => {
                this.removeRecord(record);
              }
            }
          });
        })
    }
    .height('100%')
  }
}

/** 记录页的分类筛选窄化。 */
export function toCategoryFilter(key: string): CategoryKey | 'all' {
  if (key === 'travel') {
    return 'travel';
  }
  if (key === 'utility') {
    return 'utility';
  }
  if (key === 'recycle') {
    return 'recycle';
  }
  if (key === 'plate') {
    return 'plate';
  }
  return 'all';
}
