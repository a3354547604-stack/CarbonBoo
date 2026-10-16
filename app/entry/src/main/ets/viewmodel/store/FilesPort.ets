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

  private full(relativePath: string): string {
    return `${this.ctx.filesDir}/${relativePath}`;
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

/** 内存实现（用例用；`baseDir` 用伪路径，便于断言展示文案）。 */
export class MemoryFiles implements FilesPort {
  private readonly files: Map<string, string> = new Map<string, string>();

  baseDir(): string {
    return '/mem/files';
  }

  async writeText(relativePath: string, text: string): Promise<FileEntry> {
    this.files.set(relativePath, text);
    return { path: `${this.baseDir()}/${relativePath}`, name: relativePath, size: text.length, modifiedAt: Date.now() };
  }

  async readText(relativePath: string): Promise<string> {
    const v: string | undefined = this.files.get(relativePath);
    return v === undefined ? '' : v;
  }

  async list(relativeDir: string): Promise<FileEntry[]> {
    const out: FileEntry[] = [];
    this.files.forEach((value: string, key: string) => {
      if (key.startsWith(relativeDir)) {
        out.push({ path: `${this.baseDir()}/${key}`, name: key, size: value.length, modifiedAt: Date.now() });
      }
    });
    return out;
  }

  async remove(relativePath: string): Promise<void> {
    this.files.delete(relativePath);
  }

  async exists(relativePath: string): Promise<boolean> {
    return this.files.has(relativePath);
  }

  async sizeOf(relativePath: string): Promise<number> {
    const v: string | undefined = this.files.get(relativePath);
    return v === undefined ? 0 : v.length;
  }
}

