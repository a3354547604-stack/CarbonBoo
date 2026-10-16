/**
 * StorePort —— ViewModel 层访问本机数据库的**唯一端口**（深模块接口）。
 *
 * 职责：
 *  ① 定义数据访问的最小接口面：`query` / `exec` / `execBatch` / `transaction` 四个方法；
 *  ② 定义行与参数形态 `RowShape` / `SqlValue`，以及一组**取值访问器**
 *     （`textOf` / `numOf` / `flagOf` / …）——把「ResultSet 里可能是 null / 数字 / 字符串」
 *     这件麻烦事收敛到一处，业务代码只写 `numOf(row, 'reduction_kg')`。
 *
 * 为什么是这四个方法就够：19 张表的读写差异全在 SQL 字符串里，端口不必跟着表数变宽。
 * 「窄接口 + 大实现」正是这个模块的价值：Service 层只需要认识 4 个方法，
 * 换实现（本机 RdbStore / 将来的测试替身）时上层一行不动。
 *
 * 分层约定（AGENTS.md §7.1）：
 *  - **事务边界在服务层**：`transaction(work)` 只提供能力，由 Service 决定包住哪些写入；
 *  - 页面层**不得**接触本文件，一切读写经 ViewModel → Service → 本端口。
 */
import { relationalStore } from '@kit.ArkData';

/** SQL 绑定参数（只允许这三种；`ASSET`/`Uint8Array` 本应用不用）。 */
export type SqlValue = string | number | null;

/** 一行查询结果：列名 → 值（`null` 表示 SQL NULL）。 */
export type RowShape = Record<string, SqlValue>;

/** 数据访问端口。 */
export interface StorePort {
  /**
   * 数据库文件占用的总字节数（**可选**：开发者选项 P10 展示用，内存实现可不提供）。
   * 取不到时返回 0，页面按「—」展示，不编造数字。
   */
  sizeBytes(): Promise<number>;


  /**
   * 查询多行。
   * @param sql 含 `?` 占位符的 SQL
   * @param args 绑定参数
   */
  query(sql: string, args?: SqlValue[]): Promise<RowShape[]>;

  /**
   * 执行一条写语句（INSERT / UPDATE / DELETE / DDL）。
   * @param sql 含 `?` 占位符的 SQL
   * @param args 绑定参数
   */
  exec(sql: string, args?: SqlValue[]): Promise<void>;

  /**
   * 逐条执行多条写语句（建种子、批量清理用；**不开事务**，需要原子性请自行套 `transaction`**）。
   * @param sqls 语句数组
   */
  execBatch(sqls: string[]): Promise<void>;

  /**
   * 把一组写入包成一次原子提交。
   * @param work 事务体
   */
  transaction<T>(work: () => Promise<T>): Promise<T>;
}

// ------------------------------------------------------------------ 取值访问器

/** 文本列（NULL → 空串）。 */
export function textOf(row: RowShape, column: string): string {
  const v: string | number | null = row[column];
  if (v === null || v === undefined) {
    return '';
  }
  return typeof v === 'string' ? v : `${v}`;
}

/** 可空文本列（NULL → undefined）。 */
export function optTextOf(row: RowShape, column: string): string | undefined {
  const v: string | number | null = row[column];
  if (v === null || v === undefined) {
    return undefined;
  }
  return typeof v === 'string' ? v : `${v}`;
}

/** 数值列（NULL → 0）。 */
export function numOf(row: RowShape, column: string): number {
  const v: string | number | null = row[column];
  if (v === null || v === undefined) {
    return 0;
  }
  if (typeof v === 'number') {
    return v;
  }
  const parsed: number = Number.parseFloat(v);
  return Number.isFinite(parsed) ? parsed : 0;
}

/** 可空数值列（NULL → undefined）。 */
export function optNumOf(row: RowShape, column: string): number | undefined {
  const v: string | number | null = row[column];
  if (v === null || v === undefined) {
    return undefined;
  }
  if (typeof v === 'number') {
    return v;
  }
  const parsed: number = Number.parseFloat(v);
  return Number.isFinite(parsed) ? parsed : undefined;
}

/** 布尔标记列（0/1；SQL NULL → false）。 */
export function flagOf(row: RowShape, column: string): boolean {
  return numOf(row, column) !== 0;
}

/** 布尔标记列的 0/1 形态。 */
export function flagNumOf(row: RowShape, column: string): number {
  return flagOf(row, column) ? 1 : 0;
}

/** 行数组 → 单行（无行时返回 `undefined`）。 */
export function firstOf(rows: RowShape[]): RowShape | undefined {
  return rows.length > 0 ? rows[0] : undefined;
}

/**
 * 枚举列读取：非法值立刻抛错，**不静默兜底**（口径写死，错了要能被发现）。
 * @param row 行
 * @param column 列名
 * @param allowed 允许值
 */
export function enumOf(row: RowShape, column: string, allowed: string[]): string {
  const v: string = textOf(row, column);
  if (allowed.indexOf(v) < 0) {
    throw new Error(`列 ${column} 取值非法：${v}（允许 ${allowed.join('|')}）`);
  }
  return v;
}

/** 端口实现共用的参数窄化（把 `SqlValue[]` 交给 SDK 的 `Array<ValueType>`）。 */
export function bindArgs(args?: SqlValue[]): relationalStore.ValueType[] {
  const out: relationalStore.ValueType[] = [];
  if (args === undefined) {
    return out;
  }
  let i: number = 0;
  while (i < args.length) {
    out.push(args[i]);
    i = i + 1;
  }
  return out;
}
