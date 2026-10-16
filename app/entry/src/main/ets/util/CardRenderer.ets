/**
 * CardRenderer —— 减排分享卡片的自绘引擎（附录 C §23.2，AGENTS §7.1 禁第三方图形库）。
 *
 * 职责边界：
 *  · `ShareCardModel.build()` 是**纯函数**：给它减排量与徽章数，产出卡面上的全部文案行
 *    （含等效换算），不发 IO、不查库 —— 因此可以离线断言「卡面不含姓名/学校/队名」；
 *  · `CardRenderer.draw()` 只把文案画到任意 2D 上下文上（屏幕预览与 1080 像素离屏共用同一份画法），
 *    两种尺寸（1080×1440 竖版 / 1080×1080 方版）按比例缩放。
 *
 * 隐私：卡面固定是「碳小布 · carbonboo / 我的累计减排 / 减排量 / 等效换算 / 徽章 / OpenHarmony」，
 * 结构上就没有姓名、学校、队名、指导教师这些字段；`ShareCardModel.violations()` 是给用例用的自检。
 */
import { Formatter } from './Formatter';
import { AppTheme, LiteralConstants } from './AppTheme';

/** 卡片尺寸常量（与 share_record.card_size 取值一致）。 */
export class CardSize {
  static readonly VERTICAL: string = '1080x1440';
  static readonly SQUARE: string = '1080x1080';
  static readonly VERTICAL_W: number = 1080;
  static readonly VERTICAL_H: number = 1440;
  static readonly SQUARE_W: number = 1080;
  static readonly SQUARE_H: number = 1080;

  static widthOf(size: string): number {
    return size === CardSize.SQUARE ? CardSize.SQUARE_W : CardSize.VERTICAL_W;
  }

  static heightOf(size: string): number {
    return size === CardSize.SQUARE ? CardSize.SQUARE_H : CardSize.VERTICAL_H;
  }

  static nameOf(size: string): string {
    return size === CardSize.SQUARE ? '1080×1080 方版' : '1080×1440 竖版';
  }
}

/** 卡面数据（纯数据，无 IO）。 */
export class ShareCardData {
  reductionKg: number = 0;
  treeText: string = '';
  carText: string = '';
  badgeCount: number = 0;
  badgeTotal: number = 8;
  brand: string = '碳小布 · carbonboo';
  brandFoot: string = 'OpenHarmony';

  /** 卡面上的全部文字行（自检与用例都读它）。 */
  lines(): string[] {
    const out: string[] = [];
    out.push(this.brand);
    out.push('我的累计减排');
    out.push(`${Formatter.reduction(this.reductionKg)} kgCO₂e`);
    out.push(this.treeText);
    out.push(this.carText);
    out.push(`已解锁徽章 ${this.badgeCount}/${this.badgeTotal}`);
    out.push(this.brandFoot);
    return out;
  }
}

export class ShareCardModel {
  /** 由减排量产出卡面数据（等效换算常量来自因子库 equivalents 的镜像常量）。 */
  static build(reductionKg: number, badgeCount: number, badgeTotal: number): ShareCardData {
    const data: ShareCardData = new ShareCardData();
    data.reductionKg = reductionKg;
    data.badgeCount = badgeCount;
    data.badgeTotal = badgeTotal;
    const trees: number = reductionKg / LiteralConstants.TREE_ABSORB_KG_PER_YEAR;
    const km: number = reductionKg * LiteralConstants.CAR_KM_PER_KG;
    data.treeText = `≈ ${Formatter.number(trees, 'factor')} 棵树一年的吸收量`;
    data.carText = `≈ 少开 ${Formatter.number(km, 'factor')} km 车`;
    return data;
  }

  /** 卡面文字里出现的隐私词（应为空数组；非空即为缺陷）。 */
  static violations(data: ShareCardData): string[] {
    const hits: string[] = [];
    for (const line of data.lines()) {
      for (const word of LiteralConstants.PRIVACY_FORBIDDEN) {
        if (line.indexOf(word) >= 0) {
          hits.push(word);
        }
      }
    }
    return hits;
  }
}

export class CardRenderer {
  /** 把卡片画到任意 2D 上下文（屏幕预览 / 1080 像素离屏画布共用）。 */
  static draw(ctx: CanvasRenderer, size: string, data: ShareCardData): void {
    const w: number = CardSize.widthOf(size);
    const h: number = CardSize.heightOf(size);
    const unit: number = w / 100;
    ctx.fillStyle = AppTheme.COLOR_PRIMARY;
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = AppTheme.COLOR_SURFACE;
    const margin: number = unit * 6;
    ctx.fillRect(margin, margin, w - margin * 2, h - margin * 2);

    ctx.fillStyle = AppTheme.COLOR_TEXT_PRIMARY;
    ctx.font = `bold ${unit * 5}px sans-serif`;
    ctx.fillText(data.brand, margin * 1.6, margin * 2.4);

    ctx.fillStyle = AppTheme.COLOR_TEXT_SECONDARY;
    ctx.font = `${unit * 3.2}px sans-serif`;
    ctx.fillText('我的累计减排', margin * 1.6, margin * 3.6);

    ctx.fillStyle = AppTheme.COLOR_PRIMARY;
    ctx.font = `bold ${unit * 9}px sans-serif`;
    ctx.fillText(`${Formatter.reduction(data.reductionKg)} kgCO₂e`, margin * 1.6, margin * 5.4);

    ctx.fillStyle = AppTheme.COLOR_TEXT_SECONDARY;
    ctx.font = `${unit * 3.2}px sans-serif`;
    ctx.fillText(data.treeText, margin * 1.6, margin * 6.4);
    ctx.fillText(data.carText, margin * 1.6, margin * 7.2);

    const badges: string = data.badgeCount > 0 ? '◎'.repeat(data.badgeCount) : '—';
    ctx.fillStyle = AppTheme.COLOR_ACCENT;
    ctx.font = `${unit * 4}px sans-serif`;
    ctx.fillText(badges, margin * 1.6, h - margin * 2.4);

    ctx.fillStyle = AppTheme.COLOR_TEXT_HINT;
    ctx.font = `${unit * 2.6}px sans-serif`;
    ctx.fillText(`已解锁徽章 ${data.badgeCount}/${data.badgeTotal}`, margin * 1.6, h - margin * 1.8);
    ctx.fillText(data.brandFoot, margin * 1.6, h - margin * 1.2);
  }
}
