/**
 * BackupCodec —— 本地备份快照的**编解码与完整性校验**（纯函数，不碰文件系统）。
 *
 * 职责：
 *  ① `snapshotOf(tables)`：把各表行数组打包成 `BackupSnapshot`；
 *  ② `encode(snapshot)`：JSON 文本（供 `BackupService` 写 `filesDir/backup/*.json`）；
 *  ③ `decode(text)`：反解并**校验格式与校验和**，不合法立刻抛错（恢复不允许"半个文件"）；
 *  ④ `countRows` / `fileName`：备份成功提示里的条数与文件名（附录 C §21 / D5-1）。
 *
 * 为什么校验和是必需项：验收 A9 要求「备份 → 清空 → 恢复后记录数、积分数、徽章数、
 * 已购商品数完全一致」。没有校验和时，一个被截断的 JSON 会静默恢复出一半数据。
 *
 * 格式（`carbonboo-backup-v1`）：`{format, checksum, snapshot:{app,version,createdAt,tables:[{name,rows}]}}`。
 */
import { RowShape } from '../store/StorePort';
import { JsonArray, JsonObject, asArray, asObject, must, mustArray, num, str } from '../../util/JsonUtil';

/** 一张表的转储。 */
export interface BackupTable {
  name: string;
  rows: RowShape[];
}

/** 快照主体。 */
export interface BackupSnapshot {
  app: string;
  version: string;
  createdAt: number;
  tables: BackupTable[];
}

/** 落盘信封。 */
export interface BackupEnvelope {
  format: string;
  checksum: string;
  snapshot: BackupSnapshot;
}

export class BackupCodec {
  /** 格式标识（解码时强校验，防止把别的 JSON 当备份恢复）。 */
  static readonly FORMAT: string = 'carbonboo-backup';
  /** 格式版本。 */
  static readonly FORMAT_VERSION: string = 'v1';
  /** 应用标识。 */
  static readonly APP: string = 'carbonboo';

  /** 打包快照。 */
  static snapshotOf(tables: BackupTable[], now: number): BackupSnapshot {
    return { app: BackupCodec.APP, version: BackupCodec.FORMAT_VERSION, createdAt: now, tables };
  }

  /** 编码为可落盘的 JSON 文本（紧凑，无多余空白）。 */
  static encode(snapshot: BackupSnapshot): string {
    const envelope: BackupEnvelope = {
      format: BackupCodec.FORMAT,
      checksum: BackupCodec.checksumOf(snapshot),
      snapshot,
    };
    return JSON.stringify(envelope);
  }

  /**
   * 解码并校验。
   * @param text 备份文件全文
   */
  static decode(text: string): BackupEnvelope {
    const root: JsonObject = asObject(JSON.parse(text), 'backup');
    const format: string = str(root, 'format', 'backup');
    if (format !== BackupCodec.FORMAT) {
      throw new Error(`不是碳小布备份文件（format=${format}）`);
    }
    const checksum: string = str(root, 'checksum', 'backup');
    const snapNode: JsonObject = asObject(must(root, 'snapshot'), 'backup.snapshot');
    const snapshot: BackupSnapshot = {
      app: str(snapNode, 'app', 'backup.snapshot'),
      version: str(snapNode, 'version', 'backup.snapshot'),
      createdAt: num(snapNode, 'createdAt', 'backup.snapshot'),
      tables: BackupCodec.tablesOf(mustArray(snapNode, 'tables')),
    };
    const actual: string = BackupCodec.checksumOf(snapshot);
    if (actual !== checksum) {
      throw new Error(`备份文件校验和不匹配（期望 ${checksum}，实际 ${actual}）`);
    }
    return { format, checksum, snapshot };
  }

  /** 行数合计（备份成功提示用）。 */
  static countRows(snapshot: BackupSnapshot): number {
    let n: number = 0;
    let i: number = 0;
    while (i < snapshot.tables.length) {
      n = n + snapshot.tables[i].rows.length;
      i = i + 1;
    }
    return n;
  }

  /** 表名清单（恢复时按此顺序写库）。 */
  static tableNames(snapshot: BackupSnapshot): string[] {
    const out: string[] = [];
    let i: number = 0;
    while (i < snapshot.tables.length) {
      out.push(snapshot.tables[i].name);
      i = i + 1;
    }
    return out;
  }

  /** 备份文件名（附录 C §21：`carbonboo-backup-YYYYMMDD-HHmm.json`）。 */
  static fileName(stamp: string): string {
    return `carbonboo-backup-${stamp}.json`;
  }

  /**
   * 确定性校验和（djb2 变体，对规范化 JSON 文本取模为 8 位十六进制）。
   * 要求：同一份快照在任何一次运行里都得到同一个值。
   */
  static checksumOf(snapshot: BackupSnapshot): string {
    const text: string = BackupCodec.canonical(snapshot);
    let hash: number = 5381;
    let i: number = 0;
    while (i < text.length) {
      hash = (hash * 33 + text.charCodeAt(i)) % 4294967296;
      i = i + 1;
    }
    return hash.toString(16);
  }

  /** 规范化文本（键序固定：app/version/createdAt/tables，行内按键出现顺序）。 */
  private static canonical(snapshot: BackupSnapshot): string {
    const parts: string[] = [];
    parts.push(`app=${snapshot.app}`);
    parts.push(`version=${snapshot.version}`);
    parts.push(`createdAt=${snapshot.createdAt}`);
    let i: number = 0;
    while (i < snapshot.tables.length) {
      const t: BackupTable = snapshot.tables[i];
      parts.push(`table=${t.name}`);
      let j: number = 0;
      while (j < t.rows.length) {
        const row: RowShape = t.rows[j];
        const keys: string[] = Object.keys(row);
        let k: number = 0;
        while (k < keys.length) {
          parts.push(`${keys[k]}=${row[keys[k]]}`);
          k = k + 1;
        }
        j = j + 1;
      }
      i = i + 1;
    }
    return parts.join('|');
  }

  private static tablesOf(arr: JsonArray): BackupTable[] {
    const out: BackupTable[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const node: JsonObject = asObject(arr[i], `tables[${i}]`);
      const rowsNode: JsonArray = asArray(must(node, 'rows'), `tables[${i}].rows`);
      out.push({ name: str(node, 'name', `tables[${i}]`), rows: BackupCodec.rowsOf(rowsNode) });
      i = i + 1;
    }
    return out;
  }

  private static rowsOf(arr: JsonArray): RowShape[] {
    const out: RowShape[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const obj: JsonObject = asObject(arr[i], `rows[${i}]`);
      const keys: string[] = Object.keys(obj);
      const row: RowShape = {};
      let k: number = 0;
      while (k < keys.length) {
        const v: Object = obj[keys[k]];
        if (typeof v === 'number' || typeof v === 'string') {
          row[keys[k]] = v;
        } else {
          row[keys[k]] = null;
        }
        k = k + 1;
      }
      out.push(row);
      i = i + 1;
    }
    return out;
  }
}
