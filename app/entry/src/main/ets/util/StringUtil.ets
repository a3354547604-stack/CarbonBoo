/**
 * StringUtil —— 无运行时依赖的纯字符串工具。
 *
 * 职责：
 *  ① `splitLines`：按行切分（科普 Markdown 渲染、CSV 导出共用）；
 *  ② `isBlank` / `trimOr`：空值口径统一；
 *  ③ `joinCsvLine`：CSV 一个单元格的 RFC 4180 转义（含引号、逗号、换行）。
 *
 * 为什么单独一个文件：本文件**不 import 任何 ArkTS 运行时 API**，
 * 因此可以被离线脚本（esbuild + Node）直接复算，用于验证 CSV 编码与文本处理逻辑。
 */
export class StringUtil {
  /**
   * 按行切分，兼容 `\r\n` / `\n` / `\r` 三种换行。
   * @param text 原文
   */
  static splitLines(text: string): string[] {
    const normalized: string = text.replace(new RegExp('\r\n', 'g'), '\n').replace(new RegExp('\r', 'g'), '\n');
    return normalized.split('\n');
  }

  /** 是否为空串或全空白。 */
  static isBlank(s: string | undefined): boolean {
    if (s === undefined) {
      return true;
    }
    return s.trim().length === 0;
  }

  /**
   * 空值兜底。
   * @param s 原值
   * @param fallback 为空白时返回的值
   */
  static trimOr(s: string | undefined, fallback: string): string {
    if (s === undefined) {
      return fallback;
    }
    const t: string = s.trim();
    return t.length === 0 ? fallback : t;
  }

  /**
   * CSV 单元格转义（RFC 4180）：含 `"`、`,`、`\n` 或 `\r` 时整体加引号并双写内部的 `"`。
   * @param cell 原始值
   */
  static joinCsvLine(cell: string): string {
    let needQuote: boolean = false;
    let i: number = 0;
    while (i < cell.length) {
      const c: string = cell.charAt(i);
      if (c === '"' || c === ',' || c === '\n' || c === '\r') {
        needQuote = true;
        break;
      }
      i = i + 1;
    }
    if (!needQuote) {
      return cell;
    }
    let out: string = '"';
    let j: number = 0;
    while (j < cell.length) {
      const c: string = cell.charAt(j);
      out = out + (c === '"' ? '""' : c);
      j = j + 1;
    }
    return out + '"';
  }

  /**
   * 把若干单元格拼成一行 CSV（自动加 BOM 与否由调用方决定）。
   * @param cells 单元格数组
   */
  static toCsvRow(cells: string[]): string {
    let out: string = '';
    let i: number = 0;
    while (i < cells.length) {
      if (i > 0) {
        out = out + ',';
      }
      out = out + StringUtil.joinCsvLine(cells[i]);
      i = i + 1;
    }
    return out;
  }
}
