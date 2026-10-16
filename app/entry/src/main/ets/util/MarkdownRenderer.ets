/**
 * MarkdownRenderer —— 极简 Markdown 解析器（**不引任何第三方库**，AGENTS §7.1）。
 *
 * 职责：把 `rawfile/science/sci-*.md` 的原文解析成**块序列**（`MdBlock[]`），
 * 由 `ScienceDetailPage` 用 ArkUI 原生组件渲染。支持附录 C §17 要求的五种块：
 * 标题（#/##/###）、段落、无序/有序列表、引用（>）、表格（GFM 管道表）、分割线（---），
 * 外加**行内粗体** `**x**` 的片段切分（`MdInline[]`）。
 *
 * 为什么解析与渲染分离：解析是纯函数（无 ArkTS 运行时 API），可被离线脚本复算，
 * 也能被 ohosTest 断言；渲染留在页面里，只用内置组件，不引入富文本依赖。
 */
import { StringUtil } from './StringUtil';

/** 块类型。 */
export type MdKind = 'h1' | 'h2' | 'h3' | 'p' | 'ul' | 'ol' | 'quote' | 'table' | 'divider';

/** 解析后的一个块。字段用可选值，调用方按 `kind` 取用。 */
export interface MdBlock {
  kind: MdKind;
  /** 段落/标题/引用的一段文本 */
  text?: string;
  /** 列表项（`ul` / `ol`） */
  items?: string[];
  /** 表格表头 */
  header?: string[];
  /** 表格数据行 */
  rows?: string[][];
}

/** 行内片段：普通文本或粗体。 */
export interface MdInline {
  bold: boolean;
  text: string;
}

export class MarkdownRenderer {
  /**
   * 解析整篇 Markdown。
   * @param text 原文
   */
  static parse(text: string): MdBlock[] {
    const lines: string[] = StringUtil.splitLines(text);
    const out: MdBlock[] = [];
    let i: number = 0;
    while (i < lines.length) {
      const raw: string = lines[i];
      const line: string = raw.trim();
      if (line.length === 0) {
        i = i + 1;
        continue;
      }
      if (line === '---' || line === '***') {
        out.push({ kind: 'divider' });
        i = i + 1;
        continue;
      }
      if (line.startsWith('### ')) {
        out.push({ kind: 'h3', text: line.substring(4) });
        i = i + 1;
        continue;
      }
      if (line.startsWith('## ')) {
        out.push({ kind: 'h2', text: line.substring(3) });
        i = i + 1;
        continue;
      }
      if (line.startsWith('# ')) {
        out.push({ kind: 'h1', text: line.substring(2) });
        i = i + 1;
        continue;
      }
      if (line.startsWith('> ')) {
        // 连续引用合并成一段
        let quote: string = line.substring(2);
        i = i + 1;
        while (i < lines.length && lines[i].trim().startsWith('> ')) {
          quote = `${quote} ${lines[i].trim().substring(2)}`;
          i = i + 1;
        }
        out.push({ kind: 'quote', text: quote });
        continue;
      }
      if (MarkdownRenderer.isTableStart(lines, i)) {
        const header: string[] = MarkdownRenderer.splitRow(lines[i]);
        i = i + 2;
        const rows: string[][] = [];
        while (i < lines.length && lines[i].trim().startsWith('|')) {
          rows.push(MarkdownRenderer.splitRow(lines[i]));
          i = i + 1;
        }
        out.push({ kind: 'table', header, rows });
        continue;
      }
      if (line.startsWith('- ') || line.startsWith('* ')) {
        const items: string[] = [];
        while (i < lines.length) {
          const t: string = lines[i].trim();
          if (!t.startsWith('- ') && !t.startsWith('* ')) {
            break;
          }
          items.push(t.substring(2));
          i = i + 1;
        }
        out.push({ kind: 'ul', items });
        continue;
      }
      if (MarkdownRenderer.olIndex(line) > 0) {
        const items: string[] = [];
        while (i < lines.length && MarkdownRenderer.olIndex(lines[i].trim()) > 0) {
          const t: string = lines[i].trim();
          items.push(t.substring(t.indexOf('.') + 1).trim());
          i = i + 1;
        }
        out.push({ kind: 'ol', items });
        continue;
      }
      // 普通段落：合并到下一个空行
      let para: string = line;
      i = i + 1;
      while (i < lines.length) {
        const t: string = lines[i].trim();
        if (t.length === 0 || MarkdownRenderer.isBlockStart(lines, i)) {
          break;
        }
        para = `${para} ${t}`;
        i = i + 1;
      }
      out.push({ kind: 'p', text: para });
    }
    return out;
  }

  /**
   * 行内解析：按 `**粗体**` 切成片段。
   * @param text 一行文本
   */
  static inline(text: string): MdInline[] {
    const out: MdInline[] = [];
    let rest: string = text;
    while (true) {
      const a: number = rest.indexOf('**');
      if (a < 0) {
        break;
      }
      const b: number = rest.indexOf('**', a + 2);
      if (b < 0) {
        break;
      }
      if (a > 0) {
        out.push({ bold: false, text: rest.substring(0, a) });
      }
      out.push({ bold: true, text: rest.substring(a + 2, b) });
      rest = rest.substring(b + 2);
    }
    if (rest.length > 0 || out.length === 0) {
      out.push({ bold: false, text: rest });
    }
    return out;
  }

  /** 列表项 / 段落里的 `**粗体**` 去掉标记（纯文本展示用）。 */
  static plain(text: string): string {
    const parts: MdInline[] = MarkdownRenderer.inline(text);
    let out: string = '';
    let i: number = 0;
    while (i < parts.length) {
      out = out + parts[i].text;
      i = i + 1;
    }
    return out;
  }

  /** 粗体行数（离线复算与用例断言用：验证行内解析确实生效）。 */
  static countBold(text: string): number {
    let n: number = 0;
    let i: number = 0;
    const parts: MdInline[] = MarkdownRenderer.inline(text);
    while (i < parts.length) {
      if (parts[i].bold) {
        n = n + 1;
      }
      i = i + 1;
    }
    return n;
  }

  // ---------------------------------------------------------------- 内部判定
  /** 表格起始：本行含 `|` 且下一行是 `|---|` 分隔行。 */
  private static isTableStart(lines: string[], i: number): boolean {
    if (i + 1 >= lines.length) {
      return false;
    }
    const head: string = lines[i].trim();
    const sep: string = lines[i + 1].trim();
    if (!head.startsWith('|') || !sep.startsWith('|')) {
      return false;
    }
    return sep.indexOf('---') >= 0;
  }

  /** 是否是「块开头」（用于终止段落合并）。 */
  private static isBlockStart(lines: string[], i: number): boolean {
    const t: string = lines[i].trim();
    if (t === '---' || t === '***') {
      return true;
    }
    if (t.startsWith('#') || t.startsWith('> ') || t.startsWith('- ') || t.startsWith('* ')) {
      return true;
    }
    if (MarkdownRenderer.olIndex(t) > 0) {
      return true;
    }
    return MarkdownRenderer.isTableStart(lines, i);
  }

  /** 有序列表序号（不是则返回 0）。 */
  private static olIndex(line: string): number {
    const dot: number = line.indexOf('. ');
    if (dot <= 0) {
      return 0;
    }
    const num: string = line.substring(0, dot);
    let i: number = 0;
    while (i < num.length) {
      const c: string = num.charAt(i);
      if (c < '0' || c > '9') {
        return 0;
      }
      i = i + 1;
    }
    return Number.parseInt(num, 10);
  }

  /** 切分一个表格行（去掉首尾空单元）。 */
  private static splitRow(line: string): string[] {
    let t: string = line.trim();
    if (t.startsWith('|')) {
      t = t.substring(1);
    }
    if (t.endsWith('|')) {
      t = t.substring(0, t.length - 1);
    }
    const cells: string[] = t.split('|');
    const out: string[] = [];
    let i: number = 0;
    while (i < cells.length) {
      out.push(cells[i].trim());
      i = i + 1;
    }
    return out;
  }
}
