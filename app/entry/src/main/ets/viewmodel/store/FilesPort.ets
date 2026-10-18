/**
 * FilesPort —— 应用私有目录下的**文件读写窄接口**（备份、恢复、CSV 导出用它）。
 *
 * 职责：把「备份文件写到哪里、怎么列目录、怎么删」和业务逻辑分开；
 * 生产实现落在 `context.filesDir` 下（`backup/` 与 `export/`），
 * 用例可以给内存实现（`MemoryFiles`），从而在没有设备的情况下断言备份往返。
 *
 * 为什么不用 `preferences`：备份是一个**可被用户看到、可被导出、可恢复**的实体文件
 *（验收 D5-1 要求 Toast 里带路径与文件大小），必须真的落盘。
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

/** 一个文件的元信息。 */
export interface FileEntry {
  /** 完整路径。 */
  path: string;
  /** 文件名。 */
  name: string;
  /** 字节数。 */
  size: number;
  /** 最后修改时间。 */
  modifiedAt: number;
}

export interface FilesPort {
  /** 应用私有根目录（展示用绝对路径）。 */
  baseDir(): string;
  /** 写文本文件（覆盖）。 */
  writeText(relativePath: string, text: string): Promise<FileEntry>;
  /** 读文本文件。 */
  readText(relativePath: string): Promise<string>;
  /** 列出某目录下的文件（按修改时间倒序）。 */
  list(relativeDir: string): Promise<FileEntry[]>;
  /** 删除文件。 */
  remove(relativePath: string): Promise<void>;
  /** 文件是否存在。 */
  exists(relativePath: string): Promise<boolean>;
  /** 文件大小（不存在返回 0）。 */
  sizeOf(relativePath: string): Promise<number>;
}

/** 生产实现：`context.filesDir` 之下的普通文件。 */
export class ContextFiles implements FilesPort {
  private readonly ctx: common.Context;

  constructor(ctx: common.Context) {
    this.ctx = ctx;
  }

  baseDir(): string {
    return this.ctx.filesDir;
  }

  async writeText(relativePath: string, text: string): Promise<FileEntry> {
    const full: string = this.full(relativePath);
    await ContextFiles.mkdirs(this.full(ContextFiles.dirOf(relativePath)));
    const file = fileIo.openSync(full, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
    const stat = fileIo.statSync(full);
    return { path: full, name: ContextFiles.nameOf(relativePath), size: stat.size, modifiedAt: stat.mtime * 1000 };
  }

  async readText(relativePath: string): Promise<string> {
    const full: string = this.full(relativePath);
    const stat = fileIo.statSync(full);
    const buf: ArrayBuffer = new ArrayBuffer(stat.size);
    const file = fileIo.openSync(full, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buf);
    } finally {
      fileIo.closeSync(file);
    }
    return ContextFiles.decode(buf);
  }

  async list(relativeDir: string): Promise<FileEntry[]> {
    const dir: string = this.full(relativeDir);
    if (!fileIo.accessSync(dir)) {
      return [];
    }
    const names: string[] = fileIo.listFileSync(dir);
    const out: FileEntry[] = [];
    let i: number = 0;
    while (i < names.length) {
      const full: string = `${dir}/${names[i]}`;
      const stat = fileIo.statSync(full);
      if (stat.isFile()) {
        out.push({ path: full, name: names[i], size: stat.size, modifiedAt: stat.mtime * 1000 });
      }
      i = i + 1;
    }
    out.sort((a: FileEntry, b: FileEntry): number => b.modifiedAt - a.modifiedAt);
    return out;
  }

  async remove(relativePath: string): Promise<void> {
    const full: string = this.full(relativePath);
    if (fileIo.accessSync(full)) {
      fileIo.unlinkSync(full);
    }
  }

  async exists(relativePath: string): Promise<boolean> {
    return fileIo.accessSync(this.full(relativePath));
  }

  async sizeOf(relativePath: string): Promise<number> {
    const full: string = this.full(relativePath);
    if (!fileIo.accessSync(full)) {
      return 0;
    }
    return fileIo.statSync(full).size;
  }

  /**
   * 相对路径 → 绝对路径。
   *
   * 同时接受**已经是完整路径**的入参：`FileEntry.path` 的契约就是"完整路径"，而
   * `BackupService.list()` 把它直接交给 `restore(path)` → `readText(path)`。
   * 若这里无脑拼前缀，就会得到 `<filesDir>/<filesDir>/backup/x.json` 而读不到
   * ——「从备份列表点一条恢复」这个唯一入口会直接失效（t43 离线执行实测到，
   * `BackupRoundTrip` 的 `restore().ok` 为 false 正是此因）。
   */
  private full(relativePath: string): string {
    const base: string = this.ctx.filesDir;
    if (relativePath.startsWith(`${base}/`)) {
      return relativePath;
    }
    return `${base}/${relativePath}`;
  }

  private static dirOf(relativePath: string): string {
    const idx: number = relativePath.lastIndexOf('/');
    return idx < 0 ? '' : relativePath.substring(0, idx);
  }

  private static nameOf(relativePath: string): string {
    const idx: number = relativePath.lastIndexOf('/');
    return idx < 0 ? relativePath : relativePath.substring(idx + 1);
  }

  private static async mkdirs(dir: string): Promise<void> {
    if (dir.length === 0 || fileIo.accessSync(dir)) {
      return;
    }
    const parent: string = ContextFiles.dirOf(dir);
    if (parent.length > 0 && parent !== dir) {
      await ContextFiles.mkdirs(parent);
    }
    fileIo.mkdirSync(dir);
  }

  private static decode(buf: ArrayBuffer): string {
    const decoder = new util.TextDecoder();
    return decoder.decodeToString(new Uint8Array(buf));
  }
}

/**
 * 内存实现（用例用；`baseDir` 用伪路径，便于断言展示文案）。
 *
 * **必须与 `ContextFiles` 同契约**（t43 离线执行发现这里曾经违约）：`list()` 的 `name` 是
 * **不带目录前缀的 basename**（`ContextFiles.list` 用的是 `listFileSync` 的裸文件名）、
 * 只列**直接子项**（不递归）、结果按 `modifiedAt` **倒序**；`writeText()` 返回的 `name` 同样是
 * basename。违反这条会让消费方（`BackupCodec` 按 `backup/${name}` 拼路径）读到空串，
 * 用真机跑同一套用例却又是绿的 —— 那是最坏的一种"用例失真"。
 *
 * `size` 用字符数（真实实现是字节数）：内存实现只服务展示与排序断言，不做字节级断言。
 */
export class MemoryFiles implements FilesPort {
  private readonly files: Map<string, string> = new Map<string, string>();
  /** 写入时刻（`modifiedAt` 的来源）；排序必须基于它，不能用"读到的那一刻"。 */
  private readonly at: Map<string, number> = new Map<string, number>();

  baseDir(): string {
    return '/mem/files';
  }

  /** 相对路径的最后一段（与 `ContextFiles.nameOf` 同义）。 */
  private static nameOf(relativePath: string): string {
    const parts: string[] = relativePath.split('/');
    let i: number = parts.length - 1;
    while (i >= 0) {
      if (parts[i].length > 0) {
        return parts[i];
      }
      i = i - 1;
    }
    return relativePath;
  }

  /** 目录前缀归一化（`backup` 与 `backup/` 等价），避免把 `backup2/x` 误配到 `backup`。 */
  private static prefixOf(relativeDir: string): string {
    if (relativeDir.length === 0) {
      return '';
    }
    return relativeDir.endsWith('/') ? relativeDir : `${relativeDir}/`;
  }

  /**
   * 与 `ContextFiles.full` 同语义：相对路径与「已经带 baseDir 前缀的完整路径」都接受
   * （`BackupService.list()` 给出的 `path` 就是后者，`restore(path)` 原样传进来）。
   */
  private rel(relativePath: string): string {
    const base: string = `${this.baseDir()}/`;
    return relativePath.startsWith(base) ? relativePath.substring(base.length) : relativePath;
  }

  async writeText(relativePath: string, text: string): Promise<FileEntry> {
    const rel: string = this.rel(relativePath);
    this.files.set(rel, text);
    this.at.set(rel, Date.now());
    return {
      path: `${this.baseDir()}/${rel}`,
      name: MemoryFiles.nameOf(rel),
      size: text.length,
      modifiedAt: this.at.get(rel) ?? Date.now(),
    };
  }

  async readText(relativePath: string): Promise<string> {
    const v: string | undefined = this.files.get(this.rel(relativePath));
    return v === undefined ? '' : v;
  }

  async list(relativeDir: string): Promise<FileEntry[]> {
    const prefix: string = MemoryFiles.prefixOf(relativeDir);
    const out: FileEntry[] = [];
    this.files.forEach((value: string, key: string) => {
      if (!key.startsWith(prefix)) {
        return;
      }
      const name: string = key.substring(prefix.length);
      // 目录项与更深层路径不算文件：`fileIo.listFileSync` 只返回直接子项。
      if (name.length === 0 || name.indexOf('/') >= 0) {
        return;
      }
      const at: number | undefined = this.at.get(key);
      out.push({
        path: `${this.baseDir()}/${key}`,
        name,
        size: value.length,
        modifiedAt: at === undefined ? 0 : at,
      });
    });
    out.sort((a: FileEntry, b: FileEntry): number => b.modifiedAt - a.modifiedAt);
    return out;
  }

  async remove(relativePath: string): Promise<void> {
    const rel: string = this.rel(relativePath);
    this.files.delete(rel);
    this.at.delete(rel);
  }

  async exists(relativePath: string): Promise<boolean> {
    return this.files.has(this.rel(relativePath));
  }

  async sizeOf(relativePath: string): Promise<number> {
    const v: string | undefined = this.files.get(this.rel(relativePath));
    return v === undefined ? 0 : v.length;
  }
}

