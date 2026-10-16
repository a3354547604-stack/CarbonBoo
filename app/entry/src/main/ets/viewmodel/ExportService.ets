/**
 * ExportService —— CSV 报表导出（验收 D5-8）。
 *
 * 职责：把「碳记录 / 积分流水 / 汇总」三张报表落盘为 CSV，返回文件清单与总字节数。
 *  ① 三份文件的列序、编码、BOM 与 `\r\n` 全部由 `CsvRenderer` 决定（本层不拼表头）；
 *  ② 文件写进 `filesDir/export/`，文件名带 `YYYYMMDD-HHmm` 时间戳；
 *  ③ `bundle()` 与 `export()` 走**同一份渲染结果**——用例断言 CSV 文本，页面拿到落盘文件，
 *     两者不可能分叉（附录 C §25 自检 13 的「同一口径」要求）。
 *
 * 为什么 CSV 渲染放在 domain 而不是这里：它是**纯函数**（进记录、出文本），
 * 与文件系统无关，所以能在没有设备的环境里被离线断言——`bundle()` 就是它的唯一出口。
 */
import { CarbonRecord } from '../model/CarbonTypes';
import { PointRecord } from '../model/PointTypes';
import { BadgeProgress } from '../model/BadgeTypes';
import { StorePort } from './store/StorePort';
import { FilesPort, FileEntry } from './store/FilesPort';
import { CsvRenderer, CsvFile } from './domain/CsvRenderer';
import { PointService } from './PointService';
import { StatsService } from './StatsService';
import { RewardService } from './RewardService';
import { AppState } from './AppState';
import { AppResult, fail, ok } from '../model/Result';

/** 三份报表的文本（用例直接断言它）。 */
export interface CsvBundle {
  records: CsvFile;
  points: CsvFile;
  summary: CsvFile;
}

/** 导出结果。 */
export interface ExportOutcome {
  files: FileEntry[];
  totalSize: number;
  rowCount: number;
}

export class ExportService {
  private readonly store: StorePort;
  private readonly state: AppState;
  private readonly files: FilesPort;
  private readonly stats: StatsService;
  private readonly points: PointService;
  private readonly reward: RewardService;

  constructor(store: StorePort, state: AppState, files: FilesPort, stats: StatsService, points: PointService, reward: RewardService) {
    this.store = store;
    this.state = state;
    this.files = files;
    this.stats = stats;
    this.points = points;
    this.reward = reward;
  }

  /**
   * 生成三份报表文本（不落盘）。
   * @param userId 用户
   * @param now 当前时间（徽章进度按此刻计算）
   */
  async bundle(userId: string, now: number): Promise<CsvBundle> {
    const records: CarbonRecord[] = await this.stats.allRecords(userId);
    const rows: PointRecord[] = await this.points.all(userId);
    const badges: BadgeProgress[] = await this.reward.badgeRows(userId, now);
    return {
      records: CsvRenderer.carbonRecords(records),
      points: CsvRenderer.pointRecords(rows),
      summary: CsvRenderer.summary(records, rows, badges),
    };
  }

  /** 导出三份 CSV 到 `filesDir/export/`。 */
  async export(userId: string, now: number): Promise<AppResult<ExportOutcome>> {
    try {
      const bundle: CsvBundle = await this.bundle(userId, now);
      const written: FileEntry[] = [];
      written.push(await this.files.writeText(`${ExportService.DIR}/${bundle.records.fileName}`, bundle.records.content));
      written.push(await this.files.writeText(`${ExportService.DIR}/${bundle.points.fileName}`, bundle.points.content));
      written.push(await this.files.writeText(`${ExportService.DIR}/${bundle.summary.fileName}`, bundle.summary.content));
      let total: number = 0;
      let i: number = 0;
      while (i < written.length) {
        total = total + written[i].size;
        i = i + 1;
      }
      const rows: number = ExportService.lineCount(bundle.records.content) + ExportService.lineCount(bundle.points.content) + ExportService.lineCount(bundle.summary.content);
      return ok<ExportOutcome>({ files: written, totalSize: total, rowCount: rows });
    } catch (e) {
      return fail<ExportOutcome>('EXPORT_FAILED', `导出失败：${ExportService.messageOf(e)}`);
    }
  }

  /** 导出的文件清单。 */
  async list(): Promise<FileEntry[]> {
    return this.files.list(ExportService.DIR);
  }

  /** 数据行数（不含表头，按 `\n` 计）。 */
  private static lineCount(content: string): number {
    if (content.length === 0) {
      return 0;
    }
    let n: number = 0;
    let i: number = 0;
    while (i < content.length) {
      if (content.charCodeAt(i) === 10) {
        n = n + 1;
      }
      i = i + 1;
    }
    return n === 0 ? 0 : n - 1;
  }

  private static messageOf(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return `${e}`;
  }

  /** 导出子目录（`filesDir/export`）。 */
  static readonly DIR: string = 'export';
}
