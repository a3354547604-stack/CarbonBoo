/**
 * ArkData 垫片 —— `relationalStore` 由 **Node v22 内置的 node:sqlite（真 SQLite 引擎）** 支撑。
 *
 * 为什么不是"内存假 store"：本项目的 19 张表、唯一索引（`uq_pr_source` 等）、`INSERT OR IGNORE`
 * 幂等、`revision = revision + 1` 自增、日期函数、`PRAGMA index_info` 迁移判断，全都依赖**真实
 * 的 SQL 语义**。用假 store 只能证明"Service 调了哪几个方法"，不能证明"落库结果对不对"，
 * 那样的通过是自证循环。因此这里用 `node:sqlite` 的 `DatabaseSync` 真跑 SQL。
 *
 * 只替换**平台 API**，不替换被测实现：
 *  - 被测代码（`viewmodel/store/RdbStore.ets` / `data/dao/RdbHelper.ets` / 各 Service）一行未改；
 *  - 本文件提供的是 `relationalStore.getRdbStore / executeSql / querySql / insert / 事务 / ResultSet`。
 *
 * ResultSet 语义按本项目实测踩过的坑对齐真机：
 *  - 列名只能用 `getColumnName(i)` / `getColumnIndex(name)`（**没有** `getColumnNames()`）；
 *  - `getString` 只接受 TEXT，非 TEXT 抛错（`ResultSetMapper.rawByIndex` 正是靠"抛错→换下一个取值器"分派类型）；
 *  - `getLong` 只接受整数、`getDouble` 只接受数值；NULL 列三者都抛错，必须先 `isColumnNull`；
 *  - **DOUBLE / INTEGER 返回 number，绝不返回字符串**（否则 `typeof v === 'number'` 判定会静默走错分支）。
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const SecurityLevel = { S1: 1, S2: 2, S3: 3, S4: 4 };
const ConflictResolution = {
  ON_CONFLICT_NONE: 0,
  ON_CONFLICT_ROLLBACK: 1,
  ON_CONFLICT_ABORT: 2,
  ON_CONFLICT_FAIL: 3,
  ON_CONFLICT_IGNORE: 4,
  ON_CONFLICT_REPLACE: 5,
};

/** 绑定参数归一：node:sqlite 只接受 number/string/bigint/null/Buffer，boolean/undefined 要显式转换。 */
function bindValue(v) {
  if (typeof v === 'undefined') {
    return null;
  }
  if (typeof v === 'boolean') {
    return v ? 1 : 0;
  }
  if (v instanceof Uint8Array) {
    return Buffer.from(v);
  }
  if (v instanceof ArrayBuffer) {
    return Buffer.from(new Uint8Array(v));
  }
  return v;
}

function bindAll(args) {
  if (!args || args.length === 0) {
    return undefined;
  }
  return args.map(bindValue);
}

/**
 * 真机的 relationalStore 对**多余的绑定参数**是宽容的（SQLite 的 `sqlite3_bind_*` 只按索引绑定，
 * 多给的直接被忽略）；而 node:sqlite 会抛 `column index out of range`（SQLITE_RANGE）。
 * 本仓库确有这种调用（`PointService.rebuildDay` 传了 4 个参数、语句只有 3 个 `?`），
 * 所以这里按真机语义**从多到少重试**，只吞掉 SQLITE_RANGE 这一种错误 —— 其它错误照旧上抛。
 */
function isRangeError(e) {
  const msg = e && e.message ? e.message : String(e);
  return msg.indexOf('column index out of range') >= 0 || msg.indexOf('SQLITE_RANGE') >= 0;
}

function runTolerant(db, sql, args) {
  const bound = args || [];
  let last = null;
  for (let n = bound.length; n >= 0; n -= 1) {
    const stmt = db.prepare(sql);
    try {
      const info = stmt.run(...bound.slice(0, n));
      return info;
    } catch (e) {
      if (!isRangeError(e) || n === 0) {
        throw e;
      }
      last = e;
    } finally {
      if (stmt.finalize) {
        stmt.finalize();
      }
    }
  }
  throw last === null ? new Error('执行失败') : last;
}

function allTolerant(db, sql, args) {
  const bound = args || [];
  let last = null;
  for (let n = bound.length; n >= 0; n -= 1) {
    const stmt = db.prepare(sql);
    try {
      const rows = stmt.all(...bound.slice(0, n));
      const cols = stmt.columns().map((c) => c.name);
      return { rows, cols };
    } catch (e) {
      if (!isRangeError(e) || n === 0) {
        throw e;
      }
      last = e;
    } finally {
      if (stmt.finalize) {
        stmt.finalize();
      }
    }
  }
  throw last === null ? new Error('查询失败') : last;
}

class ResultSet {
  constructor(rows, columns) {
    this._rows = rows;
    this._columns = columns;
    this._pos = -1;
  }

  /** 结果行数（真机同名属性）。 */
  get rowCount() {
    return this._rows.length;
  }

  get columnCount() {
    return this._columns.length;
  }

  get isAtFirstRow() {
    return this._pos === 0;
  }

  get isAtLastRow() {
    return this._pos === this._rows.length - 1;
  }

  get isEnded() {
    return this._pos >= this._rows.length;
  }

  goToNextRow() {
    this._pos += 1;
    return this._pos < this._rows.length;
  }

  goToFirstRow() {
    this._pos = 0;
    return this._rows.length > 0;
  }

  goToRow(position) {
    this._pos = position;
    return position >= 0 && position < this._rows.length;
  }

  getRow() {
    return { ...this._rows[this.currentRow()] };
  }

  currentRow() {
    if (this._pos < 0 || this._pos >= this._rows.length) {
      throw new Error(`ResultSet 游标不在有效行上（pos=${this._pos}, rowCount=${this._rows.length}）`);
    }
    return this._pos;
  }

  getColumnIndex(name) {
    return this._columns.indexOf(name);
  }

  getColumnName(index) {
    if (index < 0 || index >= this._columns.length) {
      throw new Error(`列下标越界：${index}（共 ${this._columns.length} 列）`);
    }
    return this._columns[index];
  }

  isColumnNull(index) {
    const row = this._rows[this.currentRow()];
    const key = this._columns[index];
    const v = row === undefined ? null : row[key];
    return v === null || typeof v === 'undefined';
  }

  getValue(index) {
    const row = this._rows[this.currentRow()];
    const v = row[this._columns[index]];
    return typeof v === 'undefined' ? null : v;
  }

  getString(index) {
    if (this.isColumnNull(index)) {
      throw new Error(`列 ${this._columns[index]} 为 NULL，getString 不允许（真机同样抛错）`);
    }
    const v = this.getValue(index);
    if (typeof v !== 'string') {
      throw new Error(`列 ${this._columns[index]} 不是 TEXT（实际 ${typeof v}），getString 不允许`);
    }
    return v;
  }

  getLong(index) {
    if (this.isColumnNull(index)) {
      throw new Error(`列 ${this._columns[index]} 为 NULL，getLong 不允许`);
    }
    const v = this.getValue(index);
    if (typeof v === 'number' && Number.isInteger(v)) {
      return v;
    }
    if (typeof v === 'bigint') {
      return Number(v);
    }
    throw new Error(`列 ${this._columns[index]} 不是 INTEGER（实际 ${typeof v}），getLong 不允许`);
  }

  getDouble(index) {
    if (this.isColumnNull(index)) {
      throw new Error(`列 ${this._columns[index]} 为 NULL，getDouble 不允许`);
    }
    const v = this.getValue(index);
    if (typeof v === 'number') {
      return v;
    }
    throw new Error(`列 ${this._columns[index]} 不是数值（实际 ${typeof v}），getDouble 不允许`);
  }

  getBlob(index) {
    const v = this.getValue(index);
    if (!(v instanceof Uint8Array)) {
      throw new Error(`列 ${this._columns[index]} 不是 BLOB`);
    }
    return v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength);
  }

  close() {
    this._rows = [];
    this._columns = [];
    this._pos = -1;
  }
}

class RdbStoreImpl {
  constructor(dbPath) {
    this._dbPath = dbPath;
    this._db = new DatabaseSync(dbPath);
    this._db.exec('PRAGMA foreign_keys = ON');
    this._closed = false;
  }

  async executeSql(sql, args) {
    const bound = bindAll(args);
    if (bound === undefined || bound.length === 0) {
      this._db.exec(sql);
      return;
    }
    runTolerant(this._db, sql, bound);
  }

  async querySql(sql, args) {
    const bound = bindAll(args);
    if (bound === undefined || bound.length === 0) {
      const stmt = this._db.prepare(sql);
      let rows;
      try {
        rows = stmt.all();
      } finally {
        stmt.finalize ? stmt.finalize() : undefined;
      }
      const plain = rows.map((r) => ({ ...r }));
      const columns = plain.length > 0 ? Object.keys(plain[0]) : this._columnsOf(sql, bound);
      return new ResultSet(plain, columns);
    }
    const res = allTolerant(this._db, sql, bound);
    const plain = res.rows.map((r) => ({ ...r }));
    const columns = plain.length > 0 ? Object.keys(plain[0]) : res.cols;
    return new ResultSet(plain, columns);
  }

  /** 空结果集时用 PRAGMA/语句自身解析列名（真机 ResultSet 即使 0 行也带列信息）。 */
  _columnsOf(sql, bound) {
    try {
      const stmt = this._db.prepare(sql);
      const cols = stmt.columns().map((c) => c.name);
      stmt.finalize ? stmt.finalize() : undefined;
      return cols;
    } catch (e) {
      return [];
    }
  }

  async insert(table, values, conflict) {
    const keys = Object.keys(values);
    const args = keys.map((k) => bindValue(values[k]));
    let head = 'INSERT';
    if (conflict === ConflictResolution.ON_CONFLICT_REPLACE) {
      head = 'INSERT OR REPLACE';
    } else if (conflict === ConflictResolution.ON_CONFLICT_IGNORE) {
      head = 'INSERT OR IGNORE';
    }
    // 列名必须加引号：本仓库有 `order` 这样的列（`goal_def.order` / `shop_item.order` / …），
    // 裸写 `order` 会被 SQLite 当关键字，抛 near "order": syntax error。真机 relationalStore
    // 同样是带引号拼装的，这里与它对齐。
    const quotedKeys = keys.map((k) => `"${String(k).replace(/"/g, '""')}"`);
    const sql = `${head} INTO "${table}" (${quotedKeys.join(', ')}) VALUES (${keys.map(() => '?').join(', ')})`;
    const stmt = this._db.prepare(sql);
    try {
      const info = stmt.run(...args);
      return Number(info.lastInsertRowid);
    } finally {
      stmt.finalize ? stmt.finalize() : undefined;
    }
  }

  async update(values, predicates) {
    throw new Error('relationalStore 垫片未实现 update(values, predicates)：本仓库所有写语句都走 executeSql（见 RdbStore.ets 头注释）');
  }

  async delete(predicates) {
    throw new Error('relationalStore 垫片未实现 delete(predicates)：本仓库所有写语句都走 executeSql');
  }

  async query(predicates, columns) {
    throw new Error('relationalStore 垫片未实现 query(predicates)：本仓库所有查询都走 querySql');
  }

  beginTransaction() {
    this._db.exec('BEGIN');
  }

  commit() {
    this._db.exec('COMMIT');
  }

  rollBack() {
    try {
      this._db.exec('ROLLBACK');
    } catch (e) {
      // 真机在无活动事务时 rollBack 也会抛，这里保持静默以免掩盖原始错误（调用方已抛出原因）。
    }
  }

  isClosed() {
    return this._closed;
  }

  async close() {
    if (!this._closed) {
      this._closed = true;
      this._db.close();
    }
  }

  get version() {
    return 1;
  }
}

const storeByName = new Map();

async function getRdbStore(context, config) {
  const name = config && config.name ? config.name : 'rdb';
  if (storeByName.has(name)) {
    const existing = storeByName.get(name);
    // 真机上 `close()` 之后再次 `getRdbStore` 会重新打开；垫片同样不能返回已关闭的句柄
    // （否则「先 close 再 open」的用例会拿到 "database is not open" 的假红）。
    if (!existing.isClosed()) {
      return existing;
    }
    storeByName.delete(name);
  }
  const dir = context.databaseDir;
  fs.mkdirSync(dir, { recursive: true });
  const dbPath = path.join(dir, `${name}.db`);
  const store = new RdbStoreImpl(dbPath);
  storeByName.set(name, store);
  return store;
}

function deleteRdbStore(context, name) {
  const key = name || 'rdb';
  const existing = storeByName.get(key);
  if (existing !== undefined) {
    existing.close();
    storeByName.delete(key);
  }
  const dbPath = path.join(context.databaseDir, `${key}.db`);
  for (const suffix of ['', '-wal', '-shm', '-journal']) {
    const p = dbPath + suffix;
    if (fs.existsSync(p)) {
      fs.unlinkSync(p);
    }
  }
}

const relationalStore = {
  SecurityLevel,
  ConflictResolution,
  getRdbStore,
  deleteRdbStore,
  /** 仅供执行器：每条用例之间断开全部句柄，等价于「重新打开 App」。 */
  __resetStores() {
    for (const [name, store] of Array.from(storeByName.entries())) {
      try {
        store.close();
      } catch (e) {
        // 忽略关闭失败（进程即将丢弃该临时库）
      }
      storeByName.delete(name);
    }
  },
};

module.exports = { relationalStore };
