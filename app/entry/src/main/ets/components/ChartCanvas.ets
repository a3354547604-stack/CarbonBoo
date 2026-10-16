/**
 * ChartCanvas —— Canvas 自绘图表（附录 C §4 / §6）：折线 / 柱状 / 饼，三种同屏使用。
 *
 * 为什么自研：AGENTS §7.1 禁止任何第三方 npm/HAR 包，图表只能手绘。
 * 数据形状由 `ChartModel.build()` 提供（折线最多 31 个点、饼固定 4 类），本组件只负责画。
 * 所有颜色取自 AppTheme，本文件不含颜色字面量。
 */
import { CategoryKey } from '../model/CarbonTypes';
import { ChartBucket, PieSlice } from '../viewmodel/domain/ChartModel';
import { AppTheme } from '../util/AppTheme';

const AXIS_FONT: string = '10vp sans-serif';

@Component
export struct ChartCanvas {
  @Prop kind: string = 'line';
  @Prop buckets: ChartBucket[] = [];
  @Prop slices: PieSlice[] = [];
  @Prop chartHeight: number = 140;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height(this.chartHeight)
      .onReady(() => {
        this.draw();
      })
  }

  private draw(): void {
    this.ctx.clearRect(0, 0, this.ctx.width, this.ctx.height);
    if (this.kind === 'pie') {
      this.drawPie();
    } else if (this.kind === 'bar') {
      this.drawBars();
    } else {
      this.drawLine();
    }
  }

  private maxOf(): number {
    let max: number = 0;
    for (const b of this.buckets) {
      if (b.value > max) {
        max = b.value;
      }
    }
    return max;
  }

  private drawLine(): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    const padBottom: number = 16;
    const padTop: number = 8;
    const max: number = this.maxOf();
    if (this.buckets.length === 0 || max <= 0) {
      return;
    }
    this.ctx.strokeStyle = AppTheme.COLOR_DIVIDER;
    this.ctx.lineWidth = 1;
    this.ctx.beginPath();
    this.ctx.moveTo(0, h - padBottom);
    this.ctx.lineTo(w, h - padBottom);
    this.ctx.stroke();

    const step: number = this.buckets.length > 1 ? (w - 8) / (this.buckets.length - 1) : 0;
    const usable: number = h - padBottom - padTop;
    this.ctx.strokeStyle = AppTheme.COLOR_PRIMARY;
    this.ctx.lineWidth = 2;
    this.ctx.beginPath();
    let idx: number = 0;
    for (const b of this.buckets) {
      const x: number = 4 + step * idx;
      const y: number = h - padBottom - (b.value / max) * usable;
      if (idx === 0) {
        this.ctx.moveTo(x, y);
      } else {
        this.ctx.lineTo(x, y);
      }
      idx = idx + 1;
    }
    this.ctx.stroke();

    this.ctx.fillStyle = AppTheme.COLOR_PRIMARY;
    let i: number = 0;
    for (const b of this.buckets) {
      const x: number = 4 + step * i;
      const y: number = h - padBottom - (b.value / max) * usable;
      this.ctx.beginPath();
      this.ctx.arc(x, y, 2, 0, Math.PI * 2);
      this.ctx.fill();
      i = i + 1;
    }
    this.ctx.fillStyle = AppTheme.COLOR_TEXT_HINT;
    this.ctx.font = AXIS_FONT;
    this.ctx.fillText(this.buckets[0].label, 0, h - 4);
    const lastLabel: string = this.buckets[this.buckets.length - 1].label;
    this.ctx.fillText(lastLabel, w - 30, h - 4);
  }

  private drawBars(): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    const padBottom: number = 16;
    const max: number = this.maxOf();
    if (this.buckets.length === 0 || max <= 0) {
      return;
    }
    const slot: number = w / this.buckets.length;
    const barW: number = slot * 0.5;
    const usable: number = h - padBottom - 8;
    let i: number = 0;
    this.ctx.font = AXIS_FONT;
    for (const b of this.buckets) {
      const barH: number = max <= 0 ? 0 : (b.value / max) * usable;
      const x: number = slot * i + (slot - barW) / 2;
      const y: number = h - padBottom - barH;
      const cat: CategoryKey | undefined = b.category;
      this.ctx.fillStyle = cat === undefined ? AppTheme.COLOR_PRIMARY : AppTheme.categoryColor(cat);
      this.ctx.fillRect(x, y, barW, barH);
      this.ctx.fillStyle = AppTheme.COLOR_TEXT_HINT;
      this.ctx.fillText(b.label, x, h - 4);
      i = i + 1;
    }
  }

  private drawPie(): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    let total: number = 0;
    for (const s of this.slices) {
      total = total + s.value;
    }
    if (total <= 0) {
      return;
    }
    const cx: number = h / 2 + 4;
    const cy: number = h / 2;
    const radius: number = h / 2 - 8;
    let start: number = -Math.PI / 2;
    for (const s of this.slices) {
      const angle: number = (s.value / total) * Math.PI * 2;
      this.ctx.fillStyle = s.color.length > 0 ? s.color : AppTheme.COLOR_PRIMARY;
      this.ctx.beginPath();
      this.ctx.moveTo(cx, cy);
      this.ctx.arc(cx, cy, radius, start, start + angle);
      this.ctx.closePath();
      this.ctx.fill();
      start = start + angle;
    }
  }
}
