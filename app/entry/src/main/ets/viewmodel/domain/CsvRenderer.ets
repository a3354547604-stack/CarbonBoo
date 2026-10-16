/**
 * CsvRenderer —— 三份 CSV 报表的**纯渲染**（列头与格式按附录 D §10）。
 *
 * 职责：把已在内存里的碳记录 / 积分流水渲染成
 *  ① `carbon-records.csv`（11 列，含因子快照，**无「修正系数」列**）；
 *  ② `point-records.csv`（7 列，含逐行余额）；
 *  ③ `summary.csv`（9 列，四类之和必须等于总减排）。
 *
 * 编码要求（附录 D §10）：UTF-8 **with BOM**、换行 `\r\n`、含逗号/引号的字段双引号包裹转义
 *（转义由 `StringUtil.toCsvRow` 统一实现，本文件不自己拼引号）。
 *
 * 为什么纯函数：验收 D5-8 要求「减排量列与页面一致」——只要两边都走 `Formatter`，
 * 这条就是可断言的等式，而不是靠人眼比对。
 */
import { CarbonRecord, CategoryKey } from '../../model/CarbonTypes';
import { PointRecord, PointType } from '../../model/PointTypes';
import { BadgeProgress } from '../../model/BadgeTypes';
import { StringUtil } from '../../util/StringUtil';
import { Formatter } from '../../util/Formatter';
import { AppTheme } from '../../util/AppTheme';
import { Dec } from '../../util/DecimalUtil';

/** 一份待落盘的报表。 */
export interface CsvFile {
  fileName: string;
  content: string;
}

export class CsvRenderer {
  /** UTF-8 BOM（Excel 打开中文不乱码的前提）。 */
  static readonly BOM: string = '\uFEFF';
  /** 行分隔（附录 D §10 明确 `\r\n`）。 */
  static readonly CRLF: string = '\r\n';

  /** ① 碳记录报表。 */
  static carbonRecords(records: CarbonRecord[]): CsvFile {
    const sorted: CarbonRecord[] = CsvRenderer.sortByTime(records);
    const lines: string[] = [];
    lines.push(StringUtil.toCsvRow([
      '记录ID', '发生时间', '大类', '类型', '数量', '单位',
      '减排量(kgCO₂e)', '因子值', '因子库版本', '备注', '异常标记',
    ]));
    let i: number = 0;
    while (i < sorted.length) {
      const r: CarbonRecord = sorted[i];
      lines.push(StringUtil.toCsvRow([
        r.id,
        Formatter.dateTime(r.occurredAt),
        AppTheme.categoryName(r.category),
        r.subType,
        Dec.from(r.amount).toFixed(1),
        r.unit,
        Formatter.reduction(r.reductionKg),
        Formatter.number(r.factorValue, 'factor'),
        r.factorVersion,
        r.note === undefined ? '' : r.note,
        r.isAbnormal === 1 ? '是' : '否',
      ]));
      i = i + 1;
    }
    return { fileName: 'carbon-records.csv', content: CsvRenderer.wrap(lines) };
  }

  /** ② 积分流水报表（余额为逐行累计，支出为负）。 */
  static pointRecords(rows: PointRecord[]): CsvFile {
    const sorted: PointRecord[] = CsvRenderer.sortPoints(rows);
    const lines: string[] = [];
    lines.push(StringUtil.toCsvRow(['记录ID', '时间', '积分', '余额', '来源', '来源ID', '说明']));
    let running: number = 0;
    let i: number = 0;
    while (i < sorted.length) {
      const p: PointRecord = sorted[i];
      running = running + p.points;
      lines.push(StringUtil.toCsvRow([
        p.id,
        Formatter.dateTime(p.occurredAt),
        Formatter.pointsSigned(p.points),
        Formatter.points(running),
        CsvRenderer.sourceNameOf(p.type),
        p.sourceId,
        p.title,
      ]));
      i = i + 1;
    }
    return { fileName: 'point-records.csv', content: CsvRenderer.wrap(lines) };
  }

  /**
   * ③ 汇总报表（区间 / 总减排 / 分类四项 / 累计积分 / 解锁徽章数）。
   * @param records 碳记录
   * @param points 积分流水
   * @param badges 徽章进度（只数已解锁）
   */
  static summary(records: CarbonRecord[], points: PointRecord[], badges: BadgeProgress[]): CsvFile {
    const sorted: CarbonRecord[] = CsvRenderer.sortByTime(records);
    let total: number = 0;
    const byCat: number[] = [0, 0, 0, 0];
    let i: number = 0;
    while (i < sorted.length) {
      total = total + sorted[i].reductionKg;
      byCat[CsvRenderer.catIndex(sorted[i].category)] = byCat[CsvRenderer.catIndex(sorted[i].category)] + sorted[i].reductionKg;
      i = i + 1;
    }
    let balance: number = 0;
    let j: number = 0;
    while (j < points.length) {
      balance = balance + points[j].points;
      j = j + 1;
    }
    let unlocked: number = 0;
    let k: number = 0;
    while (k < badges.length) {
      if (badges[k].unlocked) {
        unlocked = unlocked + 1;
      }
      k = k + 1;
    }
    const from: string = sorted.length === 0 ? '' : Formatter.dateTime(sorted[0].occurredAt).substring(0, 10);
    const to: string = sorted.length === 0 ? '' : Formatter.dateTime(sorted[sorted.length - 1].occurredAt).substring(0, 10);
    const lines: string[] = [];
    lines.push(StringUtil.toCsvRow(['统计区间', '总减排(kgCO₂e)', '记录数', '出行(kgCO₂e)', '水电燃气(kgCO₂e)', '旧物回收(kgCO₂e)', '光盘行动(kgCO₂e)', '累计积分', '解锁徽章数']));
    lines.push(StringUtil.toCsvRow([
      `${from} ~ ${to}`,
      Formatter.reduction(CsvRenderer.round4(total)),
      `${sorted.length}`,
      Formatter.reduction(CsvRenderer.round4(byCat[0])),
      Formatter.reduction(CsvRenderer.round4(byCat[1])),
      Formatter.reduction(CsvRenderer.round4(byCat[2])),
      Formatter.reduction(CsvRenderer.round4(byCat[3])),
      Formatter.points(balance),
      `${unlocked}`,
    ]));
    return { fileName: 'summary.csv', content: CsvRenderer.wrap(lines) };
  }

  /** 流水类型 → 中文来源（附录 C §16 映射表）。 */
  static sourceNameOf(type: PointType): string {
    if (type === 'record' || type === 'record_capped') {
      return '记录行为';
    }
    if (type === 'goal') {
      return '目标达成';
    }
    if (type === 'purchase') {
      return '碳小铺';
    }
    if (type === 'carbon_include') {
      return '碳普惠';
    }
    return '调整';
  }

  /** 拼 BOM + `\r\n` 收尾。 */
  private static wrap(lines: string[]): string {
    return `${CsvRenderer.BOM}${lines.join(CsvRenderer.CRLF)}${CsvRenderer.CRLF}`;
  }

  private static catIndex(category: CategoryKey): number {
    if (category === 'travel') {
      return 0;
    }
    if (category === 'utility') {
      return 1;
    }
    if (category === 'recycle') {
      return 2;
    }
    return 3;
  }

  private static round4(v: number): number {
    return Number.parseFloat(Dec.from(v).toFixed(4));
  }

  private static sortByTime(records: CarbonRecord[]): CarbonRecord[] {
    const copy: CarbonRecord[] = [];
    let i: number = 0;
    while (i < records.length) {
      copy.push(records[i]);
      i = i + 1;
    }
    copy.sort((a: CarbonRecord, b: CarbonRecord): number => a.occurredAt - b.occurredAt);
    return copy;
  }

  private static sortPoints(rows: PointRecord[]): PointRecord[] {
    const copy: PointRecord[] = [];
    let i: number = 0;
    while (i < rows.length) {
      copy.push(rows[i]);
      i = i + 1;
    }
    copy.sort((a: PointRecord, b: PointRecord): number => a.occurredAt - b.occurredAt);
    return copy;
  }
}
