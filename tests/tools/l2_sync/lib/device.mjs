/**
 * device.mjs —— L2 里「**一台设备**」的进程（不是被测实现，是执行器/夹具）。
 *
 * 它做的事与真机 App 冷启动 + 用户操作一一对应，且**全部经真实生产代码**：
 *   ① 目录垫片给 `relationalStore` 一个独立落盘目录 → 每台设备一个 **真 SQLite 库文件**；
 *   ② `RdbHelper.open` → `ServiceHub.init`（真实 `AppState`/`AppConfig`/`AuthService`/`SyncService`）；
 *   ③ 业务写入走真实 `RecordService.save/edit/remove`（四字段因子快照、软删除、冲正流水都是真实现写的）；
 *   ④ 同步走真实 `SyncService.sync()`，HTTP 出口是真实 `HttpClient`（`@kit.NetworkKit` → 真 `fetch`）。
 *
 * 唯一的"夹具"成分（都必须写进报告）：
 *   · `RecordingHttp`：包在真实 `HttpClient` 外面的**录制壳**，只转发+记录请求/响应原文，不改变行为、不做桩；
 *   · `L2_CLOCK_OFFSET_MS`：把本进程的 `Date.now()` 整体平移，用来模拟"设备时钟偏了"；
 *   · `L2_DEVICE_ID`：在 `ServiceHub.init` 之前预置 `app_config.device_id`，让两台设备有不同 deviceId；
 *   · `insert_raw` / `mark_pending`：为协议级用例准备行（跨设备重复的业务键行、把行重新标脏以重放同一批 push）。
 *
 * 用法：node device.mjs <step> '<params json>'
 * 输出：人类可读日志 + 末行 `__L2__{json}`
 */

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const BUILD = process.env.L2_BUILD;
const ROOT = process.env.L2_DEVICE_ROOT;
const BASE_URL = process.env.L2_BASE_URL;
const DEVICE_ID = process.env.L2_DEVICE_ID;
const CLOCK_OFFSET = Number(process.env.L2_CLOCK_OFFSET_MS || '0');
if (!BUILD || !ROOT || !BASE_URL || !DEVICE_ID) {
  console.error('缺少 L2_BUILD / L2_DEVICE_ROOT / L2_BASE_URL / L2_DEVICE_ID');
  process.exit(2);
}

const step = process.argv[2];
const params = process.argv[3] === undefined ? {} : JSON.parse(process.argv[3]);

// ── 模拟"设备时钟偏了"：只平移本进程的 Date.now()，实现代码一行不改 ──────────────
if (CLOCK_OFFSET !== 0) {
  const realNow = Date.now.bind(Date);
  Date.now = () => realNow() + CLOCK_OFFSET;
}

const require_ = createRequire(path.join(BUILD, 'out/__l2_entry.js'));
const OUT = path.join(BUILD, 'out/main/ets');
const PLATFORM = path.join(BUILD, 'platform');

const { context } = require_(path.join(PLATFORM, 'abilitykit.cjs'));
const { RdbHelper } = require_(path.join(OUT, 'data/dao/RdbHelper.js'));
const { RdbStore } = require_(path.join(OUT, 'viewmodel/store/RdbStore.js'));
const { AppConfig, ConfigKeys } = require_(path.join(OUT, 'viewmodel/AppConfig.js'));
const { ServiceHub } = require_(path.join(OUT, 'viewmodel/ServiceHub.js'));
const { HttpClient } = require_(path.join(OUT, 'viewmodel/net/HttpPort.js'));
const { FactorRepository } = require_(path.join(OUT, 'service/FactorRepository.js'));
const { SeedRepository } = require_(path.join(OUT, 'service/SeedRepository.js'));

/** 录制壳：包住真实 HttpPort，转发并记录原文（不改行为、不返回伪造响应）。 */
class RecordingHttp {
  constructor(inner, sink) {
    this.inner = inner;
    this.sink = sink;
  }
  baseUrl() {
    return this.inner.baseUrl();
  }
  async request(req) {
    const res = await this.inner.request(req);
    this.sink.push({
      method: req.method,
      url: req.url,
      hasAuth: req.token !== undefined && req.token !== '',
      reqBody: req.body === undefined ? '' : req.body,
      status: res.status,
      resBody: res.body === undefined ? '' : res.body,
      error: res.error === undefined ? '' : String(res.error),
    });
    return res;
  }
}

const requests = [];

function emit(payload) {
  const out = Object.assign({ step, deviceId: DEVICE_ID, clockOffsetMs: CLOCK_OFFSET }, payload);
  process.stdout.write(`__L2__${JSON.stringify(out)}\n`);
}

function quoteAll(names) {
  return names.map((n) => `"${n}"`).join(', ');
}

async function openDevice() {
  const rdb = RdbHelper.get();
  await rdb.open(context);
  // 与真机冷启动同一套基础步骤：静态字典（幂等）+ 因子库进内存缓存
  // （`CachedFactors.library()` 读的正是 `FactorRepository.peek()` 的静态缓存，每个进程都要装一次）
  await SeedRepository.seedStatic(rdb, context);
  await FactorRepository.load(context);
  const store = new RdbStore(`${context.databaseDir}/rdb`);
  const cfg = new AppConfig(store);
  // ② 预置 deviceId（AppState.ensureDevice 会优先读它，见 app/.../AppState.ets:306）
  if ((await cfg.get(ConfigKeys.DEVICE_ID)) === undefined) {
    await cfg.set(ConfigKeys.DEVICE_ID, DEVICE_ID);
  }
  const http = new RecordingHttp(new HttpClient(BASE_URL), requests);
  const hub = await ServiceHub.init(context, Date.now(), { http });
  return { rdb, store, cfg, hub, http };
}

async function boot() {
  const { store, cfg, hub } = await openDevice();
  const lib = FactorRepository.peek();
  let user = params.username;
  let auth = await hub.auth.login(user, params.password, Date.now());
  let first = 'login';
  if (!auth.ok) {
    auth = await hub.auth.register(user, params.password, Date.now());
    first = 'register';
  }
  const account = await hub.auth.account();
  emit({
    ok: auth.ok === true,
    via: first,
    code: auth.code === undefined ? '' : auth.code,
    message: auth.message === undefined ? '' : auth.message,
    userId: auth.data === undefined ? '' : auth.data.userId,
    loginName: auth.data === undefined ? '' : auth.data.username,
    tokenLen: auth.data === undefined ? 0 : auth.data.token.length,
    migrated: auth.data === undefined ? 0 : auth.data.migrated,
    stateUserId: hub.state.userId(),
    stateDeviceId: hub.state.deviceId(),
    isLoggedIn: hub.state.isLoggedIn(),
    syncState: hub.state.syncState(),
    account,
    factorVersion: lib.version(),
    factorCount: lib.totalCount(),
    seedTables: 'via-openDevice',
    databaseDir: context.databaseDir,
    requests,
  });
}

async function saveRecord() {
  const { hub } = await openDevice();
  const res = await hub.records.save(params.userId, {
    category: params.category,
    subType: params.subType,
    amount: params.amount,
    occurredAt: params.occurredAt,
    note: params.note,
  }, params.at, { settleRewards: params.settleRewards !== false });
  emit({
    ok: res.ok === true,
    code: res.code === undefined ? '' : res.code,
    message: res.message === undefined ? '' : res.message,
    outcome: res.data === undefined ? null : res.data,
  });
}

async function editRecord() {
  const { hub } = await openDevice();
  const res = await hub.records.edit(params.userId, params.recordId, {
    category: params.category,
    subType: params.subType,
    amount: params.amount,
    occurredAt: params.occurredAt,
    note: params.note,
  }, params.at);
  emit({
    ok: res.ok === true,
    code: res.code === undefined ? '' : res.code,
    message: res.message === undefined ? '' : res.message,
    outcome: res.data === undefined ? null : res.data,
  });
}

async function removeRecord() {
  const { hub } = await openDevice();
  const res = await hub.records.remove(params.userId, params.recordId, params.at);
  emit({ ok: res.ok === true, code: res.code === undefined ? '' : res.code, message: res.message === undefined ? '' : res.message });
}

async function insertRaw() {
  const { store } = await openDevice();
  const rows = [];
  for (const spec of params.rows) {
    const cols = Object.keys(spec.values);
    const marks = cols.map(() => '?').join(', ');
    await store.exec(`INSERT INTO ${spec.table} (${quoteAll(cols)}) VALUES (${marks})`,
      cols.map((c) => spec.values[c]));
    rows.push(spec.values);
  }
  emit({ inserted: rows.length, rows });
}

async function setConfig() {
  const { cfg } = await openDevice();
  for (const [k, v] of Object.entries(params.set || {})) {
    await cfg.set(k, String(v));
  }
  const out = {};
  for (const k of params.get || []) {
    const v = await cfg.get(k);
    out[k] = v === undefined ? null : v;
  }
  emit({ config: out });
}

/**
 * 按列改写一行 —— **只用于构造被测输入**（例如把某端那版的 `device_id` 摆成另一个设备的，
 * 因为真实 `RecordService.doEdit` 的 UPDATE 不改 `device_id`，见 RecordService.ets:387-394）。
 * 比较规则本身仍完全走被测实现。
 */
async function setRow() {
  const { store } = await openDevice();
  const cols = Object.keys(params.values);
  const sets = cols.map((c) => `"${c}" = ?`).join(', ');
  await store.exec(`UPDATE ${params.table} SET ${sets} WHERE id = ?`,
    [...cols.map((c) => params.values[c]), params.id]);
  const rows = await store.query(`SELECT * FROM ${params.table} WHERE id = ?`, [params.id]);
  emit({ table: params.table, id: params.id, row: rows.length === 0 ? null : rows[0] });
}

/** 把行重新标脏 —— 模拟"上一次 push 的响应丢了、客户端仍在重试同一批行"。 */
async function markPending() {
  const { store } = await openDevice();
  const touched = [];
  for (const spec of params.rows) {
    await store.exec(`UPDATE ${spec.table} SET "sync_state" = 'pending' WHERE id = ?`, [spec.id]);
    touched.push(`${spec.table}:${spec.id}`);
  }
  emit({ touched });
}

async function sync() {
  const { hub, cfg } = await openDevice();
  const before = await cfg.get(ConfigKeys.LAST_SYNC_AT);
  const res = await hub.sync.sync(params.userId, Date.now());
  const after = await cfg.get(ConfigKeys.LAST_SYNC_AT);
  const syncLog = await hub.sync.logs(params.userId, 5);
  emit({
    ok: res.ok === true,
    code: res.code === undefined ? '' : res.code,
    message: res.message === undefined ? '' : res.message,
    outcome: res.data === undefined ? null : res.data,
    lastSyncAtBefore: before === undefined ? null : before,
    lastSyncAtAfter: after === undefined ? null : after,
    logs: syncLog.ok === true ? syncLog.data : null,
    requests,
  });
}

/** 云端统计（`SyncService.status` → GET /api/v1/sync/status）：服务端侧条数/软删数/最近一次同步日志。 */
async function status() {
  const { hub } = await openDevice();
  const res = await hub.sync.status(params.userId);
  emit({
    ok: res.ok === true,
    code: res.code === undefined ? '' : res.code,
    message: res.message === undefined ? '' : res.message,
    stat: res.data === undefined ? null : res.data,
    requests,
  });
}

async function dump() {
  const { store } = await openDevice();
  const out = {};
  for (const spec of params.tables) {
    const rows = spec.id === undefined
      ? await store.query(`SELECT * FROM ${spec.table} ORDER BY id`)
      : await store.query(`SELECT * FROM ${spec.table} WHERE id = ?`, [spec.id]);
    out[spec.table] = rows;
  }
  emit({ dump: out, databaseDir: context.databaseDir });
}

/** 反证①：不设 L1_ALLOW_NETWORK 时，真实 HttpClient 出网必须被垫片拒绝（贴原始错误）。 */
async function egress() {
  const http = new HttpClient(BASE_URL);
  let message = '';
  let rejected = false;
  try {
    const res = await http.request({ method: 'GET', url: `${BASE_URL}/api/v1/config`, body: '', timeoutMs: 3000 });
    if (res.status === 0) {
      // HttpClient 把平台异常收敛成 {status:0, error}（HttpPort.ets:99-107），所以"被拦截"要从响应看，不是抛异常
      rejected = true;
      message = String(res.error && res.error.message ? res.error.message : res.error);
    } else {
      message = `未被拒绝：status=${res.status}`;
    }
  } catch (e) {
    rejected = true;
    message = e && e.message ? e.message : String(e);
  }
  emit({ rejected, message, allowNetwork: process.env.L1_ALLOW_NETWORK || '(未设置)' });
}

async function main() {
  const table = {
    boot, save_record: saveRecord, edit_record: editRecord, remove_record: removeRecord,
    insert_raw: insertRaw, set_row: setRow, set_config: setConfig, mark_pending: markPending,
    sync, status, dump, egress,
  };
  const fn = table[step];
  if (fn === undefined) {
    console.error(`未知 step：${step}`);
    process.exit(2);
  }
  await fn();
}

main().catch((e) => {
  process.stdout.write(`__L2ERR__${JSON.stringify({ step, errorString: String(e), stack: e && e.stack ? e.stack : '' })}\n`);
  process.exit(1);
});
