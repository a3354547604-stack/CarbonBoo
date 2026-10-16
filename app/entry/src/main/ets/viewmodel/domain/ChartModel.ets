/**
 * ChartModel —— 看板三图（折线 / 柱状 / 饼）与周期统计的**数据准备**（纯函数）。
 *
 * 职责：
 *  ① 按粒度 `日 / 周 / 月 / 年` 把碳记录分桶成折线数据；
 *  ② 生成柱状数据（四个分类的减排量）与饼图数据（四类占比，图例可点击筛掉）；
 *  ③ 折线点数超过 `CHART_MAX_POINTS`（31）时自动**聚合成周/月**（附录 C §6 规则 1）；
 *  ④ 周期统计四项：减排总量 / 记录数 / 日均 / 最活跃（含对应标签）。
 *
 * 为什么与 Canvas 分开：分桶、平均值、占比都是可断言的数字；坐标与像素属于组件。
 * 两者分开后，「折线最多 31 个点」「饼图四类占比之和为 1」都能被离线复算验证。
 */
import { CarbonRecord, CategoryKey } from '../../model/CarbonTypes';
import { AppTheme, LiteralConstants } from '../../util/AppTheme';
import { Formatter } from '../../util/Formatter';
import { DateUtil } from '../../util/DateUtil';

/** 时间粒度（看板 SegmentButton 四项）。 */
export type Grain = 'day' | 'week' | 'month' | 'year';

/** 分类筛选（`all` = 全部）。 */
export type ChartFilter = CategoryKey | 'all';

/** 折线 / 柱状的一个数据点。 */
export interface ChartBucket {
  label: string;
  value: number;
  startMs: number;
  endMs: number;
  /** 分类柱状图专用（折线/柱状的周期桶没有分类）。 */
  category?: CategoryKey;
}

/** 饼图一片。 */
export interface PieSlice {
  category: CategoryKey;
  name: string;
  color: string;
  value: number;
  /** 0~1，四片之和为 1（无数据时全 0）。 */
  ratio: number;
}

/** 看板整页模型。 */
export interface DashboardModel {
  grain: Grain;
  filter: ChartFilter;
  line: ChartBucket[];
  bars: ChartBucket[];
  pie: PieSlice[];
  totalReduction: number;
  recordCount: number;
  dailyAvg: number;
  peakLabel: string;
  peakValue: number;
  rangeLabel: string;
  /** 无数据（渲染 EmptyView）。 */
  empty: boolean;
}

export class ChartModel {
  /** 四个粒度，顺序固定（日 / 周 / 月 / 年）。 */
  static grains(): Grain[] {
    return ['day', 'week', 'month', 'year'];
  }

  /** 粒度中文名。 */
  static grainName(grain: Grain): string {
    if (grain === 'day') {
      return '日';
    }
    if (grain === 'week') {
      return '周';
    }
    if (grain === 'month') {
      return '月';
    }
    return '年';
  }

  /** 筛选中文名。 */
  static filterName(filter: ChartFilter): string {
    if (filter === 'all') {
      return '全部';
    }
    return AppTheme.categoryName(filter);
  }

  /**
   * 构建看板模型。
   * @param records 全部碳记录（已按用户过滤）
   * @param grain 粒度
   * @param filter 分类筛选
   * @param now 当前时刻
   */
  static build(records: CarbonRecord[], grain: Grain, filter: ChartFilter, now: number): DashboardModel {
    const scoped: CarbonRecord[] = ChartModel.filterBy(records, filter);
    const line: ChartBucket[] = ChartModel.fold(ChartModel.bucketsOf(scoped, grain, now), LiteralConstants.CHART_MAX_POINTS);
    const bars: ChartBucket[] = ChartModel.categoryBars(ChartModel.windowOf(scoped, grain, now));
    const pie: PieSlice[] = ChartModel.pieOf(bars);
    let total: number = 0;
    let i: number = 0;
    while (i < scoped.length) {
      total = total + scoped[i].reductionKg;
      i = i + 1;
    }
    let peakLabel: string = '';
    let peakValue: number = 0;
    let j: number = 0;
    while (j < line.length) {
      if (line[j].value > peakValue) {
        peakValue = line[j].value;
        peakLabel = line[j].label;
      }
      j = j + 1;
    }
    const bucketCount: number = line.length === 0 ? 1 : line.length;
    return {
      grain,
      filter,
      line,
      bars,
      pie,
      totalReduction: ChartModel.round4(total),
      recordCount: scoped.length,
      dailyAvg: ChartModel.round4(total / bucketCount),
      peakLabel,
      peakValue: ChartModel.round4(peakValue),
      rangeLabel: ChartModel.rangeLabelOf(grain),
      empty: records.length === 0,
    };
  }

  /** 粒度说明（图上方一行小字）。 */
  static rangeLabelOf(grain: Grain): string {
    if (grain === 'day') {
      return '今天 00:00 – 24:00（按小时）';
    }
    if (grain === 'week') {
      return '最近 7 天（按天）';
    }
    if (grain === 'month') {
      return '最近 30 天（按天）';
    }
    return '最近 12 个月（按月）';
  }

  /** 按分类筛选记录。 */
  static filterBy(records: CarbonRecord[], filter: ChartFilter): CarbonRecord[] {
    if (filter === 'all') {
      return records;
    }
    const out: CarbonRecord[] = [];
    let i: number = 0;
    while (i < records.length) {
      if (records[i].category === filter) {
        out.push(records[i]);
      }
      i = i + 1;
    }
    return out;
  }

  /** 粒度窗口起点。 */
  static windowStart(grain: Grain, now: number): number {
    if (grain === 'day') {
      return DateUtil.addDays(now, 0);
    }
    if (grain === 'week') {
      return DateUtil.addDays(now, -6);
    }
    if (grain === 'month') {
      return DateUtil.addDays(now, -29);
    }
    const d: Date = new Date(DateUtil.addDays(now, 0));
    return new Date(d.getFullYear(), d.getMonth() - 11, 1, 0, 0, 0, 0).getTime();
  }

  /** 粒度窗口内（含起点）的记录。 */
  static windowOf(records: CarbonRecord[], grain: Grain, now: number): CarbonRecord[] {
    const from: number = ChartModel.windowStart(grain, now);
    const out: CarbonRecord[] = [];
    let i: number = 0;
    while (i < records.length) {
      if (records[i].occurredAt >= from) {
        out.push(records[i]);
      }
      i = i + 1;
    }
    return out;
  }

  /** 按粒度分桶（桶数固定，空桶补 0，保证折线连续）。 */
  static bucketsOf(records: CarbonRecord[], grain: Grain, now: number): ChartBucket[] {
    const buckets: ChartBucket[] = ChartModel.emptyBuckets(grain, now);
    const from: number = ChartModel.windowStart(grain, now);
    let i: number = 0;
    while (i < records.length) {
      const r: CarbonRecord = records[i];
      if (r.occurredAt >= from) {
        const idx: number = ChartModel.indexOf(r.occurredAt, grain, now, buckets.length);
        if (idx >= 0 && idx < buckets.length) {
          buckets[idx].value = ChartModel.round4(buckets[idx].value + r.reductionKg);
        }
      }
      i = i + 1;
    }
    return buckets;
  }

  /** 空桶骨架（日 = 24 小时；周 = 7 天；月 = 30 天；年 = 12 月）。 */
  static emptyBuckets(grain: Grain, now: number): ChartBucket[] {
    const out: ChartBucket[] = [];
    if (grain === 'day') {
      const base: number = DateUtil.addDays(now, 0);
      let h: number = 0;
      while (h < 24) {
        out.push({ label: `${h}时`, value: 0, startMs: base + h * 3600000, endMs: base + (h + 1) * 3600000 });
        h = h + 1;
      }
      return out;
    }
    if (grain === 'week') {
      let d: number = -6;
      while (d <= 0) {
        const start: number = DateUtil.addDays(now, d);
        const day: Date = new Date(start);
        out.push({ label: ChartModel.weekdayName(day.getDay()), value: 0, startMs: start, endMs: DateUtil.addDays(start, 1) });
        d = d + 1;
      }
      return out;
    }
    if (grain === 'month') {
      let d: number = -29;
      while (d <= 0) {
        const start: number = DateUtil.addDays(now, d);
        out.push({ label: Formatter.monthDay(start), value: 0, startMs: start, endMs: DateUtil.addDays(start, 1) });
        d = d + 1;
      }
      return out;
    }
    const cur: Date = new Date(DateUtil.addDays(now, 0));
    let m: number = -11;
    while (m <= 0) {
      const start: Date = new Date(cur.getFullYear(), cur.getMonth() + m, 1, 0, 0, 0, 0);
      const end: Date = new Date(cur.getFullYear(), cur.getMonth() + m + 1, 1, 0, 0, 0, 0);
      out.push({ label: `${start.getMonth() + 1}月`, value: 0, startMs: start.getTime(), endMs: end.getTime() });
      m = m + 1;
    }
    return out;
  }

  /** 周几中文（折线横轴）。 */
  static weekdayName(day: number): string {
    if (day === 0) {
      return '周日';
    }
    if (day === 1) {
      return '周一';
    }
    if (day === 2) {
      return '周二';
    }
    if (day === 3) {
      return '周三';
    }
    if (day === 4) {
      return '周四';
    }
    if (day === 5) {
      return '周五';
    }
    return '周六';
  }

  /** 四个分类的减排量（柱状图；**不受筛选影响**，始终给全部四类）。 */
  static categoryBars(records: CarbonRecord[]): ChartBucket[] {
    const cats: CategoryKey[] = ['travel', 'utility', 'recycle', 'plate'];
    const out: ChartBucket[] = [];
    let c: number = 0;
    while (c < cats.length) {
      let sum: number = 0;
      let i: number = 0;
      while (i < records.length) {
        if (records[i].category === cats[c]) {
          sum = sum + records[i].reductionKg;
        }
        i = i + 1;
      }
      out.push({ label: AppTheme.categoryName(cats[c]), value: ChartModel.round4(sum), startMs: 0, endMs: 0, category: cats[c] });
      c = c + 1;
    }
    return out;
  }

  /** 柱状数据 → 饼图（占比，四片之和为 1；无数据时 ratio = 0）。 */
  static pieOf(bars: ChartBucket[]): PieSlice[] {
    const cats: CategoryKey[] = ['travel', 'utility', 'recycle', 'plate'];
    let total: number = 0;
    let i: number = 0;
    while (i < bars.length) {
      total = total + bars[i].value;
      i = i + 1;
    }
    const out: PieSlice[] = [];
    let c: number = 0;
    while (c < cats.length && c < bars.length) {
      out.push({
        category: cats[c],
        name: bars[c].label,
        color: AppTheme.categoryColor(cats[c]),
        value: bars[c].value,
        ratio: total <= 0 ? 0 : bars[c].value / total,
      });
      c = c + 1;
    }
    return out;
  }

  /**
   * 点数超限时折叠：把相邻两点合成一个（标签合并为「a~b」），直到不超过 max。
   * @param buckets 原始桶
   * @param max 上限（31）
   */
  static fold(buckets: ChartBucket[], max: number): ChartBucket[] {
    let cur: ChartBucket[] = buckets;
    while (cur.length > max) {
      const next: ChartBucket[] = [];
      let i: number = 0;
      while (i < cur.length) {
        if (i + 1 < cur.length) {
          next.push({
            label: `${cur[i].label}~${cur[i + 1].label}`,
            value: ChartModel.round4(cur[i].value + cur[i + 1].value),
            startMs: cur[i].startMs,
            endMs: cur[i + 1].endMs,
          });
        } else {
          next.push(cur[i]);
        }
        i = i + 2;
      }
      cur = next;
    }
    return cur;
  }

  /** 某时刻落在哪个桶（越界返回 -1）。 */
  private static indexOf(ms: number, grain: Grain, now: number, size: number): number {
    if (grain === 'day') {
      const h: number = new Date(ms).getHours();
      return h;
    }
    if (grain === 'week' || grain === 'month') {
      const daysAgo: number = DateUtil.diffDays(now, ms);
      const idx: number = size - 1 - daysAgo;
      return idx;
    }
    const cur: Date = new Date(DateUtil.addDays(now, 0));
    const d: Date = new Date(ms);
    const months: number = (cur.getFullYear() - d.getFullYear()) * 12 + (cur.getMonth() - d.getMonth());
    return 11 - months;
  }

  private static round4(v: number): number {
    return Math.round(v * 10000) / 10000;
  }
}
