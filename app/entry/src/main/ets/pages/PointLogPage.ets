/**
 * PointLogPage —— 积分明细（附录 C §16，二级页 `pointLog`）。
 *
 * 流水只增不删（铁律 4）：页面按今天/昨天分组展示，分页 20 条，下拉刷新。
 * 被封顶的流水由 `PointItem` 显示 ⚠️ 与括注。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { PointBalance, PointRecord } from '../model/PointTypes';
import { PointFlowFilter } from '../viewmodel/PointService';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { DateUtil } from '../util/DateUtil';
import { PageHeader } from '../components/PageHeader';
import { SegmentedBar, Segments } from '../components/SegmentedBar';
import { PointItem } from '../components/PointItem';
import { EmptyView } from '../components/EmptyView';
import { LoadingOverlay } from '../components/LoadingOverlay';

/** 一页流水的分组（今天 / 昨天 / 更早）。 */
class PointGroup {
  label: string = '';
  rows: PointRecord[] = [];
}

@Component
export struct PointLogPage {
  @Consume('navStack') stack: NavPathStack;
  @State balance: PointBalance | undefined = undefined;
  @State flow: PointFlowFilter = 'all';
  @State groups: PointGroup[] = [];
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State ready: boolean = false;
  private listOffset: number = 0;
  private done: boolean = false;
  private all: PointRecord[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    const now: number = Date.now();
    this.balance = await hub.points.balance(userId, now);
    this.all = await hub.points.page(userId, this.flow, 0, LiteralConstants.PAGE_SIZE);
    this.listOffset = this.all.length;
    this.done = this.all.length < LiteralConstants.PAGE_SIZE;
    this.groups = this.group(this.all);
    this.ready = true;
  }

  private async loadMore(): Promise<void> {
    if (this.done || this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    const hub: ServiceHub = ServiceHub.get();
    const more: PointRecord[] = await hub.points.page(hub.state.userId(), this.flow, this.listOffset, LiteralConstants.PAGE_SIZE);
    let i: number = 0;
    while (i < more.length) {
      this.all.push(more[i]);
      i = i + 1;
    }
    this.listOffset = this.all.length;
    this.done = more.length < LiteralConstants.PAGE_SIZE;
    this.groups = this.group(this.all);
    this.loadingMore = false;
  }

  private group(rows: PointRecord[]): PointGroup[] {
    const out: PointGroup[] = [];
    const now: number = Date.now();
    let i: number = 0;
    while (i < rows.length) {
      const label: string = this.labelOf(rows[i].occurredAt, now);
      if (out.length === 0 || out[out.length - 1].label !== label) {
        const g: PointGroup = new PointGroup();
        g.label = label;
        out.push(g);
      }
      const last: PointGroup = out[out.length - 1];
      last.rows.push(rows[i]);
      i = i + 1;
    }
    return out;
  }

  /** 今天是 / 昨天 / MM月DD日（分组标题，真实日期由 DateUtil 判断）。 */
  private labelOf(ts: number, now: number): string {
    const label: string = Formatter.dayGroupLabel(ts, now);
    if (label === '今天' || label === '昨天') {
      return label;
    }
    return Formatter.monthDay(ts);
  }

  private async refresh(): Promise<void> {
    this.refreshing = true;
    await this.reload();
    this.refreshing = false;
  }

  private async selectFlow(key: string): Promise<void> {
    this.flow = key === 'income' ? 'income' : (key === 'spend' ? 'spend' : 'all');
    this.ready = false;
    await this.reload();
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.point_log_title'),
        onBack: () => this.stack.pop()
      }) {
        Text(this.balance === undefined ? '' : `余额 ${Formatter.points(this.balance.balance)} 分`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .height(AppTheme.HEADER_HEIGHT)
      }

      Column({ space: AppTheme.CARD_GAP }) {
        SegmentedBar({
          options: Segments.FLOW,
          selected: this.flow,
          onSelect: (key: string) => {
            this.selectFlow(key);
          }
        })
      }
      .width('100%')
      .padding({ top: AppTheme.CARD_GAP, bottom: AppTheme.CARD_GAP })

      if (!this.ready) {
        LoadingOverlay({ visible: true, text: '' })
      } else if (this.groups.length === 0) {
        EmptyView({ text: '还没有积分流水', hint: '记一笔就会有积分入账' })
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 0 }) {
            ForEach(this.groups, (group: PointGroup) => {
              ListItemGroup({ header: this.groupHeader(group.label) }) {
                ForEach(group.rows, (row: PointRecord) => {
                  ListItem() {
                    PointItem({ record: row })
                  }
                }, (row: PointRecord) => row.id)
              }
            }, (group: PointGroup) => group.label)
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .onReachEnd(() => this.loadMore())
        }
        .layoutWeight(1)
        .onRefreshing(() => this.refresh())
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
    .backgroundColor(AppTheme.COLOR_BG)
  }

  @Builder
  groupHeader(label: string) {
    Text(label)
      .fontSize(AppTheme.FONT_CAPTION)
      .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
      .width('100%')
      .padding({ top: AppTheme.CARD_GAP, bottom: 6 })
  }
}
