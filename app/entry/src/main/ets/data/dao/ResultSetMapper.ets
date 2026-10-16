/**
 * ResultSetMapper —— `ResultSet` → 领域对象的**逐列映射底座**。
 *
 * 职责：
 *  ① 把 `relationalStore.ResultSet` 的列游标封装成带名字的取值方法（`text` / `int` / `real` /
 *     可选列 `optText`），内部只做「`getColumnIndex` + 类型读取」，不做业务判断；
 *  ② 把 ArkTS 的宽联合类型 `ValueType`（`null | number | string | boolean | Uint8Array |
 *     Asset | Assets | Float32Array | bigint`）**窄化**成模型字段的实际类型（`string` / `number`），
 *     避免在上层到处写 `as` 断言；
 *  ③ 提供 `columnValue`：按列名取原始 `ValueType`，供拼装 `ValuesBucket` 之类的场景使用。
 *
 * 依据：附录 B §2 建表 SQL 的列名与类型。**SQLite 没有布尔类型**，`INTEGER` 列的 0/1
 * 就是布尔（`is_deleted` / `settled` / `unlocked` / `is_favorite` / `is_self` 等），
 * 故 `int()` 返回 `number`，语义上的布尔转换由各 Dao 明确写出。
 */
import { relationalStore } from '@kit.ArkData';

export class ResultSetMapper {
  /** 取 TEXT 列。 */
  static text(rs: relationalStore.ResultSet, column: string): string {
    const idx: number = rs.getColumnIndex(column);
    if (idx < 0) {
      throw new Error(`查询结果缺少列 ${column}`);
    }
    if (ResultSetMapper.isColumnNull(rs, idx)) {
      throw new Error(`列 ${column} 为 NULL，但模型要求非空 TEXT`);
    }
    return rs.getString(idx);
  }

  /** 取 TEXT 列，NULL 或列不存在则返回 undefined。 */
  static optText(rs: relationalStore.ResultSet, column: string): string | undefined {
    const idx: number = rs.getColumnIndex(column);
    if (idx < 0 || ResultSetMapper.isColumnNull(rs, idx)) {
      return undefined;
    }
    return rs.getString(idx);
  }

  /** 取 INTEGER / REAL 列（统一窄化成 number）。 */
  static number(rs: relationalStore.ResultSet, column: string): number {
    const v: relationalStore.ValueType = ResultSetMapper.columnValue(rs, column);
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'bigint') {
      return Number(v);
    }
    if (typeof v === 'string') {
      const n: number = Number.parseFloat(v);
      if (Number.isFinite(n)) {
        return n;
      }
    }
    throw new Error(`列 ${column} 期望数值，实际 ${JSON.stringify(v)}`);
  }

  /** 取 INTEGER / REAL 列，NULL 则返回 undefined。 */
  static optNumber(rs: relationalStore.ResultSet, column: string): number | undefined {
    const idx: number = rs.getColumnIndex(column);
    if (idx < 0 || ResultSetMapper.isColumnNull(rs, idx)) {
      return undefined;
    }
    return ResultSetMapper.number(rs, column);
  }

  /** INTEGER 列按布尔语义取（SQLite 无布尔类型，0 = false，非 0 = true）。 */
  static flag(rs: relationalStore.ResultSet, column: string): boolean {
    return ResultSetMapper.number(rs, column) !== 0;
  }

  /** 按列名取原始 `ValueType`（列不存在时返回 null）。 */
  static columnValue(rs: relationalStore.ResultSet, column: string): relationalStore.ValueType {
    const idx: number = rs.getColumnIndex(column);
    if (idx < 0) {
      return null;
    }
    return ResultSetMapper.rawByIndex(rs, idx);
  }

  /**
   * 按列序号读取原始值（公开版：给"列名取不到但知道下标"的聚合场景用）。
   * @param rs 结果集
   * @param idx 列下标
   */
  static rawValueAt(rs: relationalStore.ResultSet, idx: number): relationalStore.ValueType {
    return ResultSetMapper.rawByIndex(rs, idx);
  }

  /**
   * 按列序号读取原始值。
   *
   * 为什么要自己 `isColumnNull` 再按类型分派：SDK 的 `getString` 对 NULL 列会抛异常，
   * 而我们的表里有大量可空列（`note` / `frame_id` / `settled_at` …），
   * 统一在这里判断一次，上层就不必每列都写 try/catch。
   */
  private static rawByIndex(rs: relationalStore.ResultSet, idx: number): relationalStore.ValueType {
    if (ResultSetMapper.isColumnNull(rs, idx)) {
      return null;
    }
    // 逐个类型试读：SDK 没有"取任意类型"的 API，只能按列的实际存储类型分派。
    // 顺序按本项目实际用到的类型排列（TEXT / INTEGER / REAL 三种，覆盖 19 张表全部列）。
    try {
      return rs.getString(idx);
    } catch (e) {
      // 非 TEXT，继续试数值类型
    }
    try {
      return rs.getLong(idx);
    } catch (e) {
      // 非 INTEGER，继续试浮点
    }
    try {
      return rs.getDouble(idx);
    } catch (e) {
      throw new Error(`列 ${idx} 的类型不受支持（仅 TEXT / INTEGER / REAL）`);
    }
  }

  /** NULL 判定：SDK 提供 `isColumnNull`。 */
  private static isColumnNull(rs: relationalStore.ResultSet, idx: number): boolean {
    return rs.isColumnNull(idx);
  }
}
