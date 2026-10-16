/**
 * ResourcePort —— 读取内置资源的**窄接口**（rawfile 里的种子字典与科普正文）。
 *
 * 职责：把「怎么读 rawfile」与「谁来读」分开：生产能力由 `ContextResources` 提供
 *（`resourceManager.getRawFileContent`），测试/离线场景可以给一个假的实现。
 *
 * 为什么单独成端口：`FactorRepository` / `SeedRepository`（app-core）已经证明了这条路径，
 * 本层再读的只有「12 篇科普 Markdown」和「app_config 里的头像/权益 JSON」，
 * 因此接口只留两个方法，不跟着文件数变宽。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

export interface ResourcePort {
  /** 读 rawfile 文本（UTF-8 解码）。 */
  readRawText(path: string): Promise<string>;
  /** 读 rawfile 原始字节（需要落盘二进制时用）。 */
  readRawBytes(path: string): Promise<Uint8Array>;
}

/** 基于 UIAbilityContext / ApplicationContext 的实现。 */
export class ContextResources implements ResourcePort {
  private readonly ctx: common.Context;

  constructor(ctx: common.Context) {
    this.ctx = ctx;
  }

  async readRawText(path: string): Promise<string> {
    const bytes: Uint8Array = await this.ctx.resourceManager.getRawFileContent(path);
    return new util.TextDecoder().decodeToString(bytes);
  }

  async readRawBytes(path: string): Promise<Uint8Array> {
    return this.ctx.resourceManager.getRawFileContent(path);
  }
}

/**
 * 固定文本实现（用例与离线复算用）：按路径给固定内容，未注册路径返回空串。
 * 生产代码不使用它，避免"读不到就当空"的静默降级。
 */
export class MapResources implements ResourcePort {
  private readonly files: Map<string, string>;

  constructor(files: Map<string, string>) {
    this.files = files;
  }

  async readRawText(path: string): Promise<string> {
    const v: string | undefined = this.files.get(path);
    return v === undefined ? '' : v;
  }

  async readRawBytes(path: string): Promise<Uint8Array> {
    return new Uint8Array(0);
  }
}
