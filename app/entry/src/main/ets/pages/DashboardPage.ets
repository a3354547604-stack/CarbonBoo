/**
 * DashboardPage —— 看板（附录 C §6，Tab1）：三图同屏 + 周期统计。
 * 分桶与占比全部由 `ChartModel`（纯函数）算好；本页只负责切换粒度/筛选与画布。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { CarbonRecord } from '../model/CarbonTypes';
import { ChartBucket, ChartFilter, ChartModel, DashboardModel, Grain, PieSlice } from '../viewmodel/domain/ChartModel';
import { AppTheme } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { SegmentedBar, SegmentOption, Segments } from '../components/SegmentedBar';
import { SectionCard } from '../components/SectionCard';
import { ChartCanvas } from '../components/ChartCanvas';
import { EmptyView } from '../components/EmptyView';
import { DemoModeBanner } from '../components/DemoModeBanner';

@Component
export struct DashboardPage {
  @Prop @Watch('onTick') tick: number = 0;
  @State model: DashboardModel = emptyDashboard();
  @State grain: Grain = 'day';
  @State filter: ChartFilter = 'all';
  @State isDemo: boolean = false;
  @State ready: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const records: CarbonRecord[] = await hub.stats.allRecords(hub.state.userId());
    this.model = ChartModel.build(records, this.grain, this.filter, Date.now());
    this.isDemo = await hub.state.demoFlag();
    this.ready = true;
  }

  build() {
    Scroll() {
      Column({ space: AppTheme.CARD_GAP }) {
        if (this.isDemo) {
          DemoModeBanner()
        }

        SegmentedBar({
          options: Segments.GRAIN, selected: this.grain,
          onSelect: (key: string) => {
            this.grain = toGrain(key);
            this.reload();
          }
        })

        Row({ space: 8 }) {
          Text($r('app.string.dashboard_filter')).fontSize(AppTheme.FONT_CAPTION).fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          ForEach(Segments.CATEGORY, (opt: SegmentOption) => {
            Text(opt.label)
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(this.filter === opt.key ? AppTheme.COLOR_SURFACE : AppTheme.COLOR_TEXT_SECONDARY)
              .backgroundColor(this.filter === opt.key ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_SURFACE)
              .borderRadius(AppTheme.BTN_RADIUS)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .onClick(() => {
                this.filter = toFilter(opt.key);
                this.reload();
              })
          }, (opt: SegmentOption) => opt.key)
        }
        .width('100%')

        if (this.model.empty) {
          EmptyView({ text: '本周期还没有记录', hint: '去记一笔，看板立刻有数据' })
        } else {
          SectionCard({ title: $r('app.string.dashboard_line'), showTitle: true }) {
            ChartCanvas({ kind: 'line', buckets: this.model.line, chartHeight: 140 })
            Text(this.model.rangeLabel).fontSize(AppTheme.FONT_CAPTION).fontColor(AppTheme.COLOR_TEXT_HINT)
          }

          SectionCard({ title: $r('app.string.dashboard_pie'), showTitle: true }) {
            Row({ space: AppTheme.CARD_GAP }) {
              ChartCanvas({ kind: 'pie', slices: this.visibleSlices(), chartHeight: 120 })
              Column({ space: 4 }) {
                ForEach(this.visibleSlices(), (slice: PieSlice) => {
                  Row({ space: 6 }) {
                    Text('●').fontSize(AppTheme.FONT_CAPTION).fontColor(slice.color)
                    Text(`${slice.name} ${Formatter.percent(slice.ratio)}`)
                      .fontSize(AppTheme.FONT_CAPTION)
                      .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                      .onClick(() => {
                        this.filter = slice.category;
                        this.reload();
                      })
                  }
                  .width('100%')
                }, (slice: PieSlice) => slice.category)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
          }

          SectionCard({ title: $r('app.string.dashboard_bars'), showTitle: true }) {
            ChartCanvas({ kind: 'bar', buckets: this.model.bars, chartHeight: 130 })
          }

          SectionCard({ title: $r('app.string.dashboard_period'), showTitle: true }) {
            this.statRow($r('app.string.dashboard_total'), `${Formatter.reduction(this.model.totalReduction)} kgCO₂e`)
            this.statRow($r('app.string.dashboard_records'), `${this.model.recordCount} 条`)
            this.statRow($r('app.string.dashboard_avg'), `${Formatter.reduction(this.model.dailyAvg)} kg`)
            this.statRow($r('app.string.dashboard_peak'), `${this.model.peakLabel} ${Formatter.reduction(this.model.peakValue)} kg`)
          }
        }
      }
      .width('100%')
      .padding(AppTheme.PAGE_PADDING)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor(AppTheme.COLOR_BG)
  }

  /** 饼图只画占比 > 0 的四类（图例点击=按该分类筛选）。 */
  private visibleSlices(): PieSlice[] {
    const out: PieSlice[] = [];
    for (const slice of this.model.pie) {
      if (slice.ratio > 0) {
        out.push(slice);
      }
    }
    return out;
  }

  @Builder
  statRow(label: ResourceStr, value: string) {
    Row() {
      Text(label).fontSize(AppTheme.FONT_BODY).fontColor(AppTheme.COLOR_TEXT_SECONDARY).layoutWeight(1)
      Text(value).fontSize(AppTheme.FONT_BODY).fontColor(AppTheme.COLOR_TEXT_PRIMARY)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }
}

/** 看板初始模型（首帧不出现空指针）。 */
export function emptyDashboard(): DashboardModel {
  const bars: ChartBucket[] = [];
  const slices: PieSlice[] = [];
  const model: DashboardModel = {
    grain: 'day', filter: 'all', line: [], bars: bars, pie: slices, totalReduction: 0, recordCount: 0,
    dailyAvg: 0, peakLabel: '—', peakValue: 0, rangeLabel: '', empty: true
  };
  return model;
}

/** 字符串 → 粒度（不用 `as` 断言，逐项窄化）。 */
export function toGrain(key: string): Grain {
  if (key === 'week') {
    return 'week';
  }
  if (key === 'month') {
    return 'month';
  }
  if (key === 'year') {
    return 'year';
  }
  return 'day';
}

/** 字符串 → 分类筛选。 */
export function toFilter(key: string): ChartFilter {
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
