/**
 * BackupService —— 本地备份 / 恢复 / 清理（S5，验收 D5-1 / D5-10）。
 *
 * 职责：
 *  ① 备份：把 19 张表全部转储为一份 JSON 明文，落盘到 `filesDir/backup/carbonboo-backup-YYYYMMDD-HHmm.json`，
 *     返回**路径 + 字节数 + 行数**（验收 D5-1 要求提示里同时出现路径与大小）；
 *  ② 备份记录：按修改时间倒序列出 `backup/` 目录，每条含**时间 + 文件大小**（验收 D5-10）；
 *  ③ 清理旧备份：只保留最近 `LiteralConstants.BACKUP_KEEP`（3）份，返回删除份数；
 *  ④ 恢复：解码 + 校验 + **一个事务内**「先清空再写入」，任一表失败整单回滚；
 *     云端备份的「立即恢复」在恢复前自动生成一份本地快照（附录 C §21 规则）。
 *
 * 为什么备份是整库而不是按用户过滤：本机是唯一真相源（铁律 1），备份的语义是
 * 「把这台设备上的账本原样存下来」，恢复后必须与备份那一刻完全一致——按用户过滤会
 * 让演示数据（user_id='demo-user'）在恢复后消失，反而破坏往返一致性。
 */
import { ClientSchema } from '../data/schema/ClientSchema';
import { StorePort, RowShape, SqlValue, numOf } from './store/StorePort';
import { FilesPort, FileEntry } from './store/FilesPort';
import { BackupCodec, BackupSnapshot, BackupTable } from './domain/BackupCodec';
import { AppState } from './AppState';
import { Formatter } from '../util/Formatter';
import { LiteralConstants } from '../util/AppTheme';
import { AppResult, fail, ok } from '../model/Result';

/** 一条备份记录（BackupListSheet 的一行）。 */
export interface BackupItem {
  path: string;
  name: string;
  /** 字节数。 */
  size: number;
  /** 修改时间（毫秒）。 */
  modifiedAt: number;
}

/** 备份成功的结果。 */
export interface BackupOutcome {
  path: string;
  name: string;
  size: number;
  rowCount: number;
  tableCount: number;
}

/** 恢复的结果。 */
export interface RestoreOutcome {
  tableCount: number;
  rowCount: number;
  /** 恢复前自动生成的本地快照路径（未生成时为空串）。 */
  safetyPath: string;
}

export class BackupService {
  private readonly store: StorePort;
  private readonly state: AppState;
  private readonly files: FilesPort;

  constructor(store: StorePort, state: AppState, files: FilesPort) {
    this.store = store;
    this.state = state;
    this.files = files;
  }

  /** 生成一份新的本地备份。 */
  async create(now: number): Promise<AppResult<BackupOutcome>> {
    try {
      const tables: BackupTable[] = await this.dumpAll();
      const snapshot: BackupSnapshot = BackupCodec.snapshotOf(tables, now);
      const text: string = BackupCodec.encode(snapshot);
      const name: string = await this.uniqueName(Formatter.fileStamp(now));
      const entry: FileEntry = await this.files.writeText(`${BackupService.DIR}/${name}`, text);
      return ok<BackupOutcome>({
        path: entry.path,
        name,
        size: entry.size,
        rowCount: BackupCodec.countRows(snapshot),
        tableCount: tables.length,
      });
    } catch (e) {
      return fail<BackupOutcome>('BACKUP_FAILED', `备份失败：${BackupService.messageOf(e)}`);
    }
  }

  /**
   * 同一分钟内多次备份不互相覆盖。
   *
   * 文件名契约是 `carbonboo-backup-YYYYMMDD-HHmm.json`（附录 C §21 / D5-1 / PLAN），但
   * **恢复前的安全快照**与刚生成的手动备份经常落在同一分钟：直接写同名文件会把目标备份
   * 覆盖掉（`ContextFiles` 与 `MemoryFiles` 都是覆盖写），于是「恢复前先自保一份」反而
   * 毁掉了被恢复的那份。撞名时追加 `-2` / `-3` 后缀，首个文件仍严格符合文档口径。
   */
  private async uniqueName(stamp: string): Promise<string> {
    const base: string = BackupCodec.fileName(stamp);
    const suffix: string = '.json';
    let candidate: string = base;
    let n: number = 2;
    while (await this.files.exists(`${BackupService.DIR}/${candidate}`)) {
      candidate = `${base.substring(0, base.length - suffix.length)}-${n}${suffix}`;
      n = n + 1;
      if (n > 100) {
        break;
      }
    }
    return candidate;
  }

  /** 备份记录（时间倒序；每行含时间与大小）。 */
  async list(): Promise<BackupItem[]> {
    const entries: FileEntry[] = await this.files.list(BackupService.DIR);
    const out: BackupItem[] = [];
    let i: number = 0;
    while (i < entries.length) {
      if (entries[i].name.endsWith('.json')) {
        out.push({ path: entries[i].path, name: entries[i].name, size: entries[i].size, modifiedAt: entries[i].modifiedAt });
      }
      i = i + 1;
    }
    return out;
  }

  /** 最近一份备份（「从备份恢复」默认选中项）；没有则 undefined。 */
  async latest(): Promise<BackupItem | undefined> {
    const all: BackupItem[] = await this.list();
    return all.length === 0 ? undefined : all[0];
  }

  /**
   * 清理旧备份，只保留最近 `LiteralConstants.BACKUP_KEEP` 份。
   * @returns 删除的份数
   */
  async cleanOld(): Promise<number> {
    const all: BackupItem[] = await this.list();
    let removed: number = 0;
    let i: number = LiteralConstants.BACKUP_KEEP;
    while (i < all.length) {
      await this.files.remove(BackupService.DIR + '/' + all[i].name);
      removed = removed + 1;
      i = i + 1;
    }
    return removed;
  }

  /** 删除单份备份。 */
  async remove(path: string): Promise<void> {
    await this.files.remove(path);
  }

  /**
   * 从备份恢复（覆盖式；恢复前可选自动生成本地快照）。
   * @param path 备份文件路径
   * @param safetyCopy 恢复前是否自动生成快照（云端恢复传 true）
   */
  async restore(path: string, safetyCopy: boolean): Promise<AppResult<RestoreOutcome>> {
    let text: string = '';
    try {
      text = await this.files.readText(path);
    } catch (e) {
      return fail<RestoreOutcome>('BACKUP_UNREADABLE', `备份文件读不到：${BackupService.messageOf(e)}`);
    }
    let snapshot: BackupSnapshot;
    try {
      snapshot = BackupCodec.decode(text).snapshot;
    } catch (e) {
      return fail<RestoreOutcome>('BACKUP_INVALID', `备份文件不合法：${BackupService.messageOf(e)}`);
    }
    let safetyPath: string = '';
    if (safetyCopy) {
      const safety: AppResult<BackupOutcome> = await this.create(Date.now());
      if (safety.ok && safety.data !== undefined) {
        safetyPath = safety.data.path;
      }
    }
    try {
      const counts: RestoreOutcome = await this.store.transaction<RestoreOutcome>(async () => {
        let tables: number = 0;
        let rows: number = 0;
        let i: number = 0;
        while (i < snapshot.tables.length) {
          const t: BackupTable = snapshot.tables[i];
          if (BackupService.isKnownTable(t.name)) {
            await this.store.exec(`DELETE FROM ${BackupService.quoted(t.name)}`, []);
            const written: number = await this.insertRows(t);
            rows = rows + written;
            tables = tables + 1;
          }
          i = i + 1;
        }
        return { tableCount: tables, rowCount: rows, safetyPath };
      });
      return ok<RestoreOutcome>(counts);
    } catch (e) {
      return fail<RestoreOutcome>('RESTORE_FAILED', `恢复失败，已回滚：${BackupService.messageOf(e)}`);
    }
  }

  /** 备份文件总占用（设置页展示）。 */
  /**
   * 清空该用户的全部数据（附录 C §21「清空所有数据」，需页面二次确认 + 输入「删除」）。
   * 只删**用户数据**（9 张同步表 + 日统计 + 分享记录 + 同步日志）；字典表与本机配置保留。
   * 返回删除的行数合计。
   */
  async clearAll(userId: string): Promise<number> {
    const tables: string[] = [
      'carbon_record', 'point_record', 'user_goal', 'user_badge', 'user_purchase',
      'user_appearance', 'science_progress', 'carbon_include', 'user_profile',
      'point_daily_stat', 'share_record', 'sync_log',
    ];
    let removed: number = 0;
    let i: number = 0;
    await this.store.transaction(async () => {
      while (i < tables.length) {
        const rows: RowShape[] = await this.store.query(
          `SELECT COUNT(*) AS c FROM ${tables[i]} WHERE user_id = ?`, [userId]
        );
        removed = removed + (rows.length > 0 ? numOf(rows[0], 'c') : 0);
        await this.store.exec(`DELETE FROM ${tables[i]} WHERE user_id = ?`, [userId]);
        i = i + 1;
      }
    });
    return removed;
  }

  async totalSize(): Promise<number> {
    const all: BackupItem[] = await this.list();
    let n: number = 0;
    let i: number = 0;
    while (i < all.length) {
      n = n + all[i].size;
      i = i + 1;
    }
    return n;
  }

  /** 19 张表全量转储。 */
  private async dumpAll(): Promise<BackupTable[]> {
    const out: BackupTable[] = [];
    let i: number = 0;
    while (i < ClientSchema.TABLES.length) {
      const name: string = ClientSchema.TABLES[i];
      const rows: RowShape[] = await this.store.query(`SELECT * FROM ${name}`, []);
      out.push({ name, rows });
      i = i + 1;
    }
    return out;
  }

  /** 按行内键序拼一条 INSERT（列集合取该表的键并集）。 */
  private async insertRows(table: BackupTable): Promise<number> {
    if (table.rows.length === 0) {
      return 0;
    }
    const columns: string[] = BackupService.columnsOf(table.rows);
    if (columns.length === 0) {
      return 0;
    }
    const quoted: string[] = BackupService.quotedAll(columns);
    const sql: string = `INSERT INTO ${BackupService.quoted(table.name)} (${quoted.join(', ')}) ` +
      `VALUES (${BackupService.placeholders(columns.length)})`;
    let written: number = 0;
    let i: number = 0;
    while (i < table.rows.length) {
      const row: RowShape = table.rows[i];
      const args: SqlValue[] = [];
      let k: number = 0;
      while (k < columns.length) {
        const v: string | number | null | undefined = row[columns[k]];
        args.push(v === undefined ? null : v);
        k = k + 1;
      }
      await this.store.exec(sql, args);
      written = written + 1;
      i = i + 1;
    }
    return written;
  }

  /** 行内键并集（保持首次出现顺序）。 */
  private static columnsOf(rows: RowShape[]): string[] {
    const seen = new Map<string, number>();
    const out: string[] = [];
    let i: number = 0;
    while (i < rows.length) {
      const keys: string[] = Object.keys(rows[i]);
      let k: number = 0;
      while (k < keys.length) {
        if (!seen.has(keys[k])) {
          seen.set(keys[k], 1);
          out.push(keys[k]);
        }
        k = k + 1;
      }
      i = i + 1;
    }
    return out;
  }

  /**
   * SQL 标识符加双引号。
   *
   * 起因（t46）：`ClientSchema` 里 4 张表用了保留字列名 `"order"`（建表 DDL 自己加了引号，
   * 见 `ClientSchema.ets:10` 的注释），而恢复路径拼 INSERT 时直接 `columns.join(', ')`
   * ⇒ 语句里出现裸 `order` ⇒ SQLite 报 `near "order": syntax error` ⇒ 任何备份都恢复不了
   * （真机同一条代码路径，同错；恢复是换机/重装后唯一的数据通道）。
   *
   * 修法是**逐列/逐个表名**加引号，不是给 `order` 打特例补丁：这样以后任何保留字列名
   * （`index` / `key` / `group` / `default` …）都不会再踩同一个坑。
   */
  private static quoted(name: string): string {
    return '"' + name + '"';
  }

  private static quotedAll(names: string[]): string[] {
    const out: string[] = [];
    let i: number = 0;
    while (i < names.length) {
      out.push(BackupService.quoted(names[i]));
      i = i + 1;
    }
    return out;
  }

  private static placeholders(n: number): string {
    const parts: string[] = [];
    let i: number = 0;
    while (i < n) {
      parts.push('?');
      i = i + 1;
    }
    return parts.join(', ');
  }

  private static isKnownTable(name: string): boolean {
    let i: number = 0;
    while (i < ClientSchema.TABLES.length) {
      if (ClientSchema.TABLES[i] === name) {
        return true;
      }
      i = i + 1;
    }
    return false;
  }

  private static messageOf(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return `${e}`;
  }

  /** 备份子目录（`filesDir/backup`）。 */
  static readonly DIR: string = 'backup';
}
