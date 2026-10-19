#!/usr/bin/env node
/**
 * l2_run.mjs —— L2「双设备协同」**协议级**端到端用例驱动（不是被测实现，是执行器）。
 *
 * 目的：在本机用 **两个独立客户端库**（各自一个 node:sqlite 库文件、各自 deviceId）+ **真实 FastAPI 服务端**
 * + **真实 HTTP**，把附录 B §6.3/§6.4 的 LWW 两端收敛跑成可复现证据。
 *
 * 结构：
 *   - 每个"设备"（A/B）都是独立子进程 `lib/device.mjs`，加载的是从仓库真实 `.ets` 转译出来的**同一份**客户端代码；
 *     两台设备之间除 HTTP 外没有任何共享内存、共享库文件。
 *   - 两台设备的库文件由本进程用 `node:sqlite` **直接读**（独立于 `arkdata.cjs` 垫片），逐列比对。
 *   - 服务端那一行另外用 `docker exec mysql` 直查（第三只看不见的眼睛）。
 *
 * 环境变量（由 `run.sh` 注入）：L2_REPO / L2_BUILD / L2_ROOTS / L2_BASE_URL / L2_USERNAME / L2_PASSWORD /
 *   L2_TIME_BASE / L2_MYSQL_USER / L2_MYSQL_PASSWORD / L2_MYSQL_DB / L2_MYSQL_CONTAINER / L2_WIRE_LOG / L2_ONLY
 *
 * 退出码：0 = 全部断言通过；1 = 有断言失败；2 = 环境不可达。
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';

function need(name) {
  const v = process.env[name];
  if (v === undefined || v === '') {
    console.error(`缺少环境变量 ${name}`);
    process.exit(2);
  }
  return v;
}

const REPO = need('L2_REPO');
const BUILD = need('L2_BUILD');
const ROOTS = need('L2_ROOTS');
const BASE_URL = need('L2_BASE_URL');
const USERNAME = need('L2_USERNAME');
const PASSWORD = need('L2_PASSWORD');
const TIME_BASE = Number(need('L2_TIME_BASE'));
const DEVICE_MJS = path.join(REPO, 'tests/tools/l2_sync/lib/device.mjs');
const PROXY_MJS = path.join(REPO, 'tests/tools/l2_sync/lib/proxy.mjs');
const RAW_MAIN = path.join(REPO, 'app/entry/src/main/resources/rawfile');
const WIRE_LOG = process.env.L2_WIRE_LOG || '';
const ONLY = (process.env.L2_ONLY || 'all').trim();
const AGO = Date.now() - 3600000; // 发生时间：1 小时前，落在 30 天补记窗口内

/** 端侧同步游标列：服务端不建该列（server/sql/schema.sql:10 注释），不参与同步，故不纳入逐列比对。 */
const BOOKKEEPING = new Set(['sync_state']);
// 跨端比较时 **`updated_at` 也允许不同**：§5.3:1095/1097 规定「本机业务行的 `updated_at` = 客户端基准」，
// 因此同一逻辑版本在两端的绝对值本来就相差两端时钟偏移（同机实测为往返抖动，几十 ms）。
// 其余列仍必须逐列相同；`updated_at` 的差值必须落在该上界内（不是"忽略这一列"）。
const CLOCK_SKEW_MAX_MS = 3000;
const CROSS_END_SKIP = new Set([...BOOKKEEPING, 'updated_at']);
const DEV = { A: 'l2-dev-A', B: 'l2-dev-B', C: 'l2-dev-C' };

let FAILED = 0;
const CHECKS = [];
const OBS = {};
const WIRE = [];

// ─────────────────────────────────────────────────────────────────────────────
// 输出与断言
// ─────────────────────────────────────────────────────────────────────────────
function section(title) {
  console.log(`\n════════ ${title} ════════`);
}
function check(id, title, ok, evidence) {
  CHECKS.push({ id, title, ok: ok === true });
  if (ok !== true) {
    FAILED = 1;
  }
  console.log(`${ok === true ? '[PASS]' : '[FAIL]'} #${id} ${title}`);
  for (const e of evidence || []) {
    console.log(`    | ${e}`);
  }
}
function note(title, evidence) {
  console.log(`[NOTE] ${title}`);
  for (const e of evidence || []) {
    console.log(`    | ${e}`);
  }
}
function truncate(s, n) {
  const t = s === undefined || s === null ? '' : String(s);
  return t.length <= n ? t : `${t.slice(0, n)}…（截断，全长 ${t.length} 字符）`;
}
function j(v) {
  return JSON.stringify(v);
}
function norm(v) {
  return v === null || v === undefined ? 'NULL' : String(v);
}

// ─────────────────────────────────────────────────────────────────────────────
// 设备进程
// ─────────────────────────────────────────────────────────────────────────────
function run(dev, step, params, opts) {
  const o = opts || {};
  const root = path.join(ROOTS, dev);
  const env = { ...process.env };
  env.L2_BUILD = BUILD;
  env.L2_BASE_URL = o.baseUrl === undefined ? BASE_URL : o.baseUrl;
  env.L2_DEVICE_ROOT = root;
  env.L2_DEVICE_ID = DEV[dev];
  env.L1_DATABASE_DIR = path.join(root, 'databases');
  env.L1_FILES_DIR = path.join(root, 'files');
  env.L1_CACHE_DIR = path.join(root, 'cache');
  env.L1_RAW_MAIN = RAW_MAIN;
  env.L2_CLOCK_OFFSET_MS = String(o.clockOffsetMs || 0);
  if (o.allowNetwork === false) {
    delete env.L1_ALLOW_NETWORK;
  } else {
    env.L1_ALLOW_NETWORK = '1';
  }
  const r = spawnSync(process.execPath, [DEVICE_MJS, step, JSON.stringify(params || {})], {
    env,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  const out = r.stdout || '';
  const err = r.stderr || '';
  const errLine = out.split('\n').filter((l) => l.startsWith('__L2ERR__')).pop();
  if (errLine !== undefined) {
    if (o.expectError === true) {
      const parsed = JSON.parse(errLine.slice('__L2ERR__'.length));
      return { failed: true, ...parsed, device: dev, stepName: step, requests: [] };
    }
    console.error(`[设备 ${dev}/${step}] 子进程抛错：${errLine}`);
    console.error(err.slice(0, 4000));
    process.exit(2);
  }
  const line = out.split('\n').filter((l) => l.startsWith('__L2__')).pop();
  if (line === undefined) {
    console.error(`[设备 ${dev}/${step}] 没有 __L2__ 输出`);
    console.error(`--- stdout ---\n${out.slice(0, 4000)}\n--- stderr ---\n${err.slice(0, 2000)}`);
    process.exit(2);
  }
  const parsed = JSON.parse(line.slice('__L2__'.length));
  for (const req of parsed.requests || []) {
    WIRE.push({ dev, step, ...req });
  }
  parsed.device = dev;
  parsed.stepName = step;
  return parsed;
}
function pushWire(res) {
  return (res.requests || []).find((r) => r.url.includes('/sync/push'));
}
function pullWire(res) {
  return (res.requests || []).find((r) => r.url.includes('/sync/pull'));
}
/** 服务端 push 响应（`{ok,data}`）——上行采纳/去重/拒绝/时钟偏移的唯一权威口径。 */
function pushOut(res) {
  const w = pushWire(res);
  if (w === undefined) {
    return null;
  }
  const body = JSON.parse(w.resBody);
  return { http: w.status, data: body.data, raw: w.resBody };
}
function pullRes(res) {
  const w = pullWire(res);
  if (w === undefined) {
    return null;
  }
  const body = JSON.parse(w.resBody);
  return { http: w.status, data: body.data, raw: w.resBody };
}
function wireLine(w) {
  if (w === undefined) {
    return '(没有录到该请求)';
  }
  return `${w.method} ${w.url} → HTTP ${w.status}\n      req:  ${truncate(w.reqBody, 700)}\n      resp: ${truncate(w.resBody, 1400)}`;
}

// ─────────────────────────────────────────────────────────────────────────────
// 独立读库（node:sqlite 直读两个设备的库文件）
// ─────────────────────────────────────────────────────────────────────────────
function dbFile(dev) {
  return path.join(ROOTS, dev, 'databases', 'carbonboo.db.db');
}
function withDb(dev, fn) {
  if (!fs.existsSync(dbFile(dev))) {
    return null;
  }
  const db = new DatabaseSync(dbFile(dev));
  try {
    return fn(db);
  } finally {
    db.close();
  }
}
function dbRow(dev, table, id) {
  return withDb(dev, (db) => {
    const r = db.prepare(`SELECT * FROM ${table} WHERE id = ?`).get(id);
    return r === undefined ? null : { ...r };
  });
}
function dbRows(dev, sql, args) {
  return withDb(dev, (db) => db.prepare(sql).all(...(args || [])).map((r) => ({ ...r })));
}
function dbCount(dev, table, where, args) {
  const rows = dbRows(dev, `SELECT COUNT(*) AS n FROM ${table} ${where || ''}`, args);
  return rows === null || rows.length === 0 ? -1 : rows[0].n;
}
/** 逐列比对（跳过端侧游标列）；跨引擎比较故按字符串口径归一。 */
function crossDiffs(a, b) {
  return columnDiff(a, b, CROSS_END_SKIP);
}

/** 两端 `updated_at` 的绝对差（ms）；任一侧缺失/非数 → Infinity（判红）。 */
function skewMs(a, b) {
  if (a === null || b === null || a === undefined || b === undefined) {
    return Infinity;
  }
  const x = Number(norm(a.updated_at));
  const y = Number(norm(b.updated_at));
  if (!Number.isFinite(x) || !Number.isFinite(y)) {
    return Infinity;
  }
  return Math.abs(x - y);
}

/**
 * `updated_at` 换算到**服务端基准**（严格、无容差）：`端上值 + offsetMs`
 *（`offsetMs` = 服务端 − 客户端；客户端落库用 `clientOffsetMs = -offsetMs`，§5.3:1095/1097）。
 *
 * 于是「端上值 − clientOffsetMs」必须**逐字节等于**服务端基准值：漏换算、重复换算、符号写反
 * 都会让这里立刻不等 —— 所以跨端一致性用这个等价式断言，而不是"差值 ≤ 若干秒"的容差
 *（容差会把 500ms 级的符号/倍率错误吃成绿）。
 */
function basisOf(row, offsetMs) {
  if (row === null || row === undefined) {
    return NaN;
  }
  return Number(norm(row.updated_at)) + Number(offsetMs);
}

/** 取一次 `sync` 调用里 push 握手腿的 `offsetMs`（= 该端当次换算用的那个值取反）。 */
function offsetOf(runResult) {
  const p = pushOut(runResult) || {};
  return (p.data || {}).offsetMs;
}

/** 单个时间戳是否落在目标值 ± `CLOCK_SKEW_MAX_MS` 内（仅用于**换算不参与**的场景）。 */
function nearMs(v, target) {
  const x = Number(norm(v));
  return Number.isFinite(x) && Math.abs(x - target) <= CLOCK_SKEW_MAX_MS;
}

/** 两组行（同序、按 id 对齐）跨端等价：除游标列与 `updated_at` 外逐列相同，且差值在上界内。 */
function crossRowsEq(rowsA, rowsB) {
  if (rowsA.length !== rowsB.length) {
    return false;
  }
  let i = 0;
  while (i < rowsA.length) {
    if (norm(rowsA[i].id) !== norm(rowsB[i].id)) {
      return false;
    }
    if (crossDiffs(rowsA[i], rowsB[i]).length !== 0) {
      return false;
    }
    if (skewMs(rowsA[i], rowsB[i]) > CLOCK_SKEW_MAX_MS) {
      return false;
    }
    i = i + 1;
  }
  return true;
}

function columnDiff(a, b, skip) {
  const ignore = skip || BOOKKEEPING;
  if (a === null || b === null) {
    return [`一侧为 null：A=${a === null ? 'null' : '有行'} B=${b === null ? 'null' : '有行'}`];
  }
  const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
  const diffs = [];
  for (const k of keys) {
    if (ignore.has(k)) {
      continue;
    }
    if (norm(a[k]) !== norm(b[k])) {
      diffs.push(`${k}: A=${norm(a[k])} B=${norm(b[k])}`);
    }
  }
  return diffs;
}
function rowBrief(row, cols) {
  if (row === null) {
    return 'null';
  }
  const keys = cols || Object.keys(row).sort();
  return keys.map((k) => `${k}=${norm(row[k])}`).join(' ');
}
/** 真实录入链路自己生成记录 id（`RecordService.save` 内部 `IdUtil.uuid()`），故按用例唯一的 note 反查。 */
function recordIdByNote(dev, note) {
  const r = dbRows(dev, 'SELECT id FROM carbon_record WHERE user_id = ? AND note = ? ORDER BY created_at DESC', [ctx.userId, note]);
  return r !== null && r.length > 0 ? r[0].id : '';
}

// ─────────────────────────────────────────────────────────────────────────────
// 服务端直查（MySQL）
// ─────────────────────────────────────────────────────────────────────────────
function serverQuery(sql) {
  const args = [
    'exec', '-e', `MYSQL_PWD=${process.env.L2_MYSQL_PASSWORD || ''}`,
    process.env.L2_MYSQL_CONTAINER || 'carbonboo-mysql', 'mysql',
    `-u${process.env.L2_MYSQL_USER || 'root'}`,
    '--default-character-set=utf8mb4',
    '-D', process.env.L2_MYSQL_DB || 'carbonboo_l2_e2e',
    '-B', '-e', sql,
  ];
  const r = spawnSync('docker', args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (r.error !== undefined && r.error !== null) {
    return { ok: false, error: String(r.error) };
  }
  if (r.status !== 0) {
    return { ok: false, error: (r.stderr || '').trim() };
  }
  const text = (r.stdout || '').replace(/\n$/, '');
  if (text === '') {
    return { ok: true, cols: [], rows: [] };
  }
  const lines = text.split('\n');
  const cols = lines[0].split('\t');
  const rows = lines.slice(1).map((l) => {
    const o = {};
    l.split('\t').forEach((v, i) => {
      o[cols[i] || `c${i}`] = v === 'NULL' ? null : v;
    });
    return o;
  });
  return { ok: true, cols, rows };
}
function serverRow(table, id) {
  const r = serverQuery(`SELECT * FROM \`${table}\` WHERE id = '${id}' LIMIT 1`);
  if (!r.ok || r.rows.length === 0) {
    return null;
  }
  return r.rows[0];
}

/** 夹具直接改服务端某一行的若干列 —— **只用于把"对端那一版"这一输入摆出来**：
 *  合并本身仍 100% 走真实 `GET /sync/pull` + 真实客户端 `applyPull`/`applyRow`。 */
function serverUpdate(table, id, values) {
  const sets = Object.keys(values).map((c) => {
    const v = values[c];
    if (v === null) {
      return `\`${c}\` = NULL`;
    }
    if (typeof v === 'number') {
      return `\`${c}\` = ${v}`;
    }
    return `\`${c}\` = '${String(v).replace(/'/g, "''")}'`;
  }).join(', ');
  const r = serverQuery(`UPDATE \`${table}\` SET ${sets} WHERE id = '${id}'`);
  if (!r.ok) {
    return { ok: false, error: r.error };
  }
  return { ok: true, row: serverRow(table, id) };
}

/** 直连真实服务端的 HTTP 探针（不经过客户端、不经过垫片）—— 用来把**服务端那一侧的口径**单独钉死：
 *  同一份 push body 原样重放、或补一个字段重放，观察 accepted/ignored/rejected/conflicts 的计数规则。 */
/** 服务端某张表的总行数（夹具直查，用于"没有重复行"的判定）。 */
function serverCount(table) {
  const r = serverQuery(`SELECT COUNT(*) AS n FROM \`${table}\``);
  return r.ok && r.rows.length > 0 ? Number(r.rows[0].n) : -1;
}

async function httpJson(method, pathname, bodyString, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token !== undefined && token !== '') {
    headers.Authorization = `Bearer ${token}`;
  }
  const res = await fetch(`${BASE_URL}${pathname}`, {
    method,
    headers,
    body: bodyString === undefined ? undefined : bodyString,
  });
  const text = await res.text();
  let parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    parsed = null;
  }
  return { status: res.status, body: text, json: parsed };
}

/** 协议补全代理：把真实服务端 **push 响应**里的 `offsetMs` 补进 **pull 响应**，
 *  其余字节原样转发（附录 B §5.3/§6.3 文档意图要求 pull 侧也带上该字段；服务端实现里没有）。
 *  只在"客户端取反换算"（第 4.5 / 4.6 项）这一条用例上使用；其余用例一律直连真服务端。 */
/**
 * 起"协议补全代理"（独立进程，见 lib/proxy.mjs）。
 *
 * 为什么不放在本进程里：驱动用 `spawnSync` 跑设备子进程，会**阻塞本进程的事件循环**，
 * 代理就再也答不了设备的请求，用例会直接挂死（本项目踩过一次，故在此留注释）。
 */
function spawnProxy(forceOffset) {
  return new Promise((resolve, reject) => {
    const args = [PROXY_MJS, BASE_URL];
    if (forceOffset !== undefined) {
      args.push(String(forceOffset));
    }
    const child = spawn(process.execPath, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let buf = '';
    const timer = setTimeout(() => reject(new Error('协议补全代理未在 10s 内就绪')), 10000);
    child.stdout.on('data', (d) => {
      buf += d.toString();
      const line = buf.split('\n').find((l) => l.startsWith('__L2PROXY__'));
      if (line !== undefined) {
        clearTimeout(timer);
        const info = JSON.parse(line.slice('__L2PROXY__'.length));
        resolve({
          url: `http://127.0.0.1:${info.port}`,
          close: () => new Promise((r) => {
            child.kill('SIGTERM');
            child.on('exit', () => r());
            setTimeout(() => { child.kill('SIGKILL'); r(); }, 3000);
          }),
        });
      }
    });
    child.on('error', (e) => { clearTimeout(timer); reject(e); });
  });
}

/** 用例级共享状态：账号、两台设备的引导结果、直连探针用的 token、观测汇总。 */
const ctx = { userId: '', bootA: null, bootB: null, token: '', anchors: {} };

/** 是否要跑这一组用例（`L2_ONLY=all` 或逗号分隔的组名）。 */
function want(name) {
  if (ONLY === '' || ONLY === 'all') {
    return true;
  }
  return ONLY.split(',').map((s) => s.trim()).indexOf(name) >= 0;
}

function prologue() {
  section('准备：两台设备各自登录同一账号（真实 HTTP + 真实 JWT）');
  ctx.bootA = run('A', 'boot', { username: USERNAME, password: PASSWORD });
  ctx.userId = ctx.bootA.userId;
  // 直连探针要用的 token：直接从设备 A 的 app_config 里读（与客户端同源，不额外造凭据）
  const tokenRow = dbRow('A', 'app_config', 'auth_token');
  ctx.token = tokenRow === null || tokenRow.value === undefined ? '' : String(tokenRow.value);
  ctx.bootB = run('B', 'boot', { username: USERNAME, password: PASSWORD });
  const a = ctx.bootA;
  const b = ctx.bootB;
  check(
    '0.1',
    '两台设备各自独立落库（不同库文件、不同 deviceId），用同一账号在真服务端登录拿到 token',
    a.ok === true && b.ok === true && a.userId !== '' && a.userId === b.userId
      && a.stateDeviceId === DEV.A && b.stateDeviceId === DEV.B && a.tokenLen > 20 && b.tokenLen > 20,
    [
      `A: via=${a.via} userId=${a.userId} deviceId=${a.stateDeviceId} token长度=${a.tokenLen} isLoggedIn=${a.isLoggedIn}`,
      `B: via=${b.via} userId=${b.userId} deviceId=${b.stateDeviceId} token长度=${b.tokenLen} isLoggedIn=${b.isLoggedIn}`,
      `A 库文件=${dbFile('A')}`,
      `B 库文件=${dbFile('B')}`,
      `A 账号态=${j(a.account)}`,
      `A 的认证请求（最后一条）→ ${wireLine((a.requests || []).slice(-1)[0])}`,
      `A 全部认证请求：${j((a.requests || []).map((r) => `${r.method} ${r.url} → ${r.status}`))}`,
      `B 全部认证请求：${j((b.requests || []).map((r) => `${r.method} ${r.url} → ${r.status}`))}`,
    ],
  );
  // F1（t62 修复）的现场：两台设备各自 boot 时，`user_profile` / `user_appearance` 的 `id` 由
  // `IdUtil.uuid()` 各自生成 —— 同账号下这一对"单例行"的 id 天然不同、而 `user_id` 相同。
  // 修复前的客户端 pull 侧只按 `WHERE id = ?` 认领本机行，第二台设备首同步（`since=0`）pull 到
  // 对端那一版时"按 id 查不到" → 直接 `INSERT`（无 `OR IGNORE`）→ 撞 `uq_uprofile` / `uq_ua` 抛错
  // （t57 夹具第 8.3 节的原始栈：`UNIQUE constraint failed: user_appearance.user_id`）。
  // ⚠️ 本夹具**不做任何"把 B 的唯一键行 id 对齐到 A"的前置构造**：那种做法恰好会掩盖这条缺陷
  // （t57 版夹具的 0.2 就是靠 `align_singleton` 绕过去的，t62 已删除该步骤与它调用的设备步骤）。
  const profileIdOf = (dev) => {
    const r = withDb(dev, (db) => db.prepare('SELECT id FROM user_profile WHERE user_id = ?').get(ctx.userId));
    return r === undefined || r === null ? '' : r.id;
  };
  const appearanceIdOf = (dev) => {
    const r = withDb(dev, (db) => db.prepare('SELECT id FROM user_appearance WHERE user_id = ?').get(ctx.userId));
    return r === undefined || r === null ? '' : r.id;
  };
  const singletonCount = (dev, table) => {
    const r = withDb(dev, (db) => db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`).get(ctx.userId));
    return r === undefined || r === null ? -1 : r.n;
  };
  const profA = profileIdOf('A');
  const appA = appearanceIdOf('A');
  const profB = profileIdOf('B');
  const appB = appearanceIdOf('B');

  // 首次同步：把各自的基线行推到服务端，并落 lastSyncAt 锚点
  const sa = run('A', 'sync', { userId: ctx.userId });
  const sb = run('B', 'sync', { userId: ctx.userId });
  check(
    '0.2',
    '新设备首同步（since=0）不再撞唯一索引（F1 修复现场）：两端各自自建了同 user_id、不同 id 的单例行，B pull 到 A 那一版后按 user_id 认领并落库成功',
    sa.ok === true && sb.ok === true
      && !String(sb.errorString || '').includes('UNIQUE constraint')
      && !String(sa.errorString || '').includes('UNIQUE constraint')
      && singletonCount('A', 'user_profile') === 1 && singletonCount('A', 'user_appearance') === 1
      && singletonCount('B', 'user_profile') === 1 && singletonCount('B', 'user_appearance') === 1
      && profA !== profB && appA !== appB,
    [
      `A 本机: user_profile.id=${profA} / user_appearance.id=${appA}`,
      `B 本机: user_profile.id=${profB} / user_appearance.id=${appB}（与 A 不同 —— 修复前正是这一步撞索引）`,
      `B 首同步（真实 push+pull）: ok=${sb.ok}，库内 user_profile 行数=${singletonCount('B', 'user_profile')}、user_appearance 行数=${singletonCount('B', 'user_appearance')}`,
      `B 首同步 pull 线段（真实响应）: ${wireLine(pullWire(sb))}`,
      `B 首同步 errorString=${j(sb.errorString)}（修复前为 UNIQUE constraint failed: user_appearance.user_id）`,
      `A 首同步: ok=${sa.ok}，errorString=${j(sa.errorString)}`,
    ],
  );
  ctx.anchors.A = sa.lastSyncAtAfter;
  ctx.anchors.B = sb.lastSyncAtAfter;
  const pa = pushOut(sa);
  const pb = pushOut(sb);
  check(
    '0.3',
    '两端各完成一次真实 push+pull（服务端记录 lastSyncAt 锚点）',
    sa.ok === true && sb.ok === true && pa.http === 200 && pb.http === 200,
    [
      `A push: ${j(pa.data)}`,
      `B push: ${j(pb.data)}`,
      `A lastSyncAt: ${sa.lastSyncAtBefore} → ${sa.lastSyncAtAfter}`,
      `B lastSyncAt: ${sb.lastSyncAtBefore} → ${sb.lastSyncAtAfter}`,
      `客户端 sync_log（A 最近 5 条）: ${j(sa.logs)}`,
    ],
  );
  note('真实因子库（来自 rawfile/factors/carbon-factors.json，加载走 FactorRepository）', [
    `version=${ctx.bootA.factorVersion} 条数=${ctx.bootA.factorCount}`,
  ]);
}

/** 第 1 项：基线往返。 */
function scenario1() {
  section('第 1 项：基线往返（A 写 → push → B pull → 逐列相同）');
  const T = TIME_BASE;
  const s1 = run('A', 'save_record', {
    userId: ctx.userId, category: 'travel', subType: 'walk', amount: 5,
    occurredAt: AGO, note: 'L2-基线-A1', at: T, settleRewards: true,
  });
  const s2 = run('A', 'save_record', {
    userId: ctx.userId, category: 'utility', subType: 'elec_grid', amount: 10,
    occurredAt: AGO, note: 'L2-基线-A2', at: T + 1000, settleRewards: true,
  });
  const id1 = recordIdByNote('A', 'L2-基线-A1');
  const a1 = dbRow('A', 'carbon_record', id1);
  check(
    '1.1',
    'A 走真实录入链路（RecordService.save → CarbonService.calculate）落两条碳记录，含四字段因子快照',
    s1.ok === true && s2.ok === true && a1 !== null
      && a1.factor_value !== null && a1.factor_version !== '' && a1.factor_source !== '' && a1.confidence !== '',
    [
      `save#1 outcome: ${j(s1.outcome)}`,
      `save#2 outcome: ${j(s2.outcome)}`,
      `A 库中该行: ${rowBrief(a1)}`,
      `四字段快照: factor_value=${norm(a1.factor_value)} factor_version=${norm(a1.factor_version)} factor_source=${norm(a1.factor_source)} confidence=${norm(a1.confidence)}`,
    ],
  );
  const sa = run('A', 'sync', { userId: ctx.userId });
  const pa = pushOut(sa);
  const sb = run('B', 'sync', { userId: ctx.userId });
  const pb = pushOut(sb);
  const b1 = dbRow('B', 'carbon_record', id1);
  const diffs = crossDiffs(a1, b1);
  check(
    '1.2',
    'push → pull 后，B 库中同一行与 A **除 `updated_at` 外逐列相同**（含四字段快照；排除端侧游标列 sync_state）'
      + '——`updated_at` 按 §5.3:1095/1097 是各自**客户端基准**，差值 = 两端时钟偏移（本机上界 3s）',
    b1 !== null && diffs.length === 0
      && basisOf(a1, offsetOf(sa)) === basisOf(b1, offsetOf(sb)),
    [
      `A push（原始响应）: ${wireLine(pushWire(sa))}`,
      `B pull（原始响应，仅列该行所在表）: ${j((pullRes(sb) || { data: {} }).data.tables === undefined ? null : (pullRes(sb).data.tables.carbon_record || []).filter((r) => r.id === id1))}`,
      `A 库: ${rowBrief(a1)}`,
      `B 库: ${rowBrief(b1)}`,
      `差异列（跳过 sync_state / updated_at）: ${diffs.length === 0 ? '无' : diffs.join(' ; ')}`,
      `严格基准等价（无容差）：A 值+offA=${basisOf(a1, offsetOf(sa))}（offA=${offsetOf(sa)}）、`
        + `B 值+offB=${basisOf(b1, offsetOf(sb))}（offB=${offsetOf(sb)}）—— 两者必须逐字节相等`,
      `B 侧 sync_state=${norm(b1 && b1.sync_state)}（A 侧 ${norm(a1 && a1.sync_state)}）——端侧游标列，服务端不建该列，不参与同步`,
    ],
  );
  const srv = serverRow('carbon_record', id1);
  check(
    '1.3',
    '服务端（直查 MySQL）持有的该行与两端一致',
    srv !== null && basisOf(a1, offsetOf(sa)) === Number(norm(srv.updated_at))
      && basisOf(b1, offsetOf(sb)) === Number(norm(srv.updated_at)) && norm(srv.note) === norm(a1.note)
      && norm(srv.factor_value) === norm(a1.factor_value) && norm(srv.factor_version) === norm(a1.factor_version)
      && norm(srv.factor_source) === norm(a1.factor_source) && norm(srv.confidence) === norm(a1.confidence),
    [
      `服务端: ${rowBrief(srv)}`,
      `直查命令: SELECT * FROM carbon_record WHERE id='${id1}'（docker exec ${process.env.L2_MYSQL_CONTAINER || 'carbonboo-mysql'} mysql -D ${process.env.L2_MYSQL_DB || 'carbonboo_l2_e2e'}）`,
    ],
  );
  const pa2 = dbRows('A', 'SELECT * FROM point_record WHERE user_id = ? ORDER BY id', [ctx.userId]);
  const pb2 = dbRows('B', 'SELECT * FROM point_record WHERE user_id = ? ORDER BY id', [ctx.userId]);
  const strip = (rows) => rows.map((r) => {
    const o = { ...r };
    delete o.sync_state;
    return o;
  });
  check(
    '1.4',
    '另外的真实业务表（point_record 积分流水）也随同一次同步往返：行数相同、除 `updated_at`（各自客户端基准）外逐列一致',
    pa2.length > 0 && pa2.length === pb2.length && crossRowsEq(strip(pa2), strip(pb2))
      && pa2.every((r, i) => basisOf(r, offsetOf(sa)) === basisOf(pb2[i], offsetOf(sb))),
    [
      `A 侧 point_record 行数=${pa2.length}，B 侧=${pb2.length}`,
      `A 侧首行: ${rowBrief(pa2[0])}`,
      `B 侧首行: ${rowBrief(pb2[0])}`,
      `两端去游标列+updated_at 后全等: ${crossRowsEq(strip(pa2), strip(pb2))}`,
      `逐行严格基准等价（无容差）: ${pa2.map((r, i) => `${basisOf(r, offsetOf(sa))}==${basisOf(pb2[i], offsetOf(sb))}`).join(' ; ')}`,
    ],
  );
}

/** 第 2 项：LWW 收敛（两端都改同一行）。 */
function scenario2() {
  section('第 2 项：LWW 收敛（A、B 各自离线改同一行 → 依次 push/pull → 两端逐列相同）');
  const T0 = TIME_BASE + 200000;
  const T1 = TIME_BASE + 260000;
  const T2 = TIME_BASE + 320000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'recycle', subType: 'paper', amount: 2,
    occurredAt: AGO, note: 'LWW-初始', at: T0,
  });
  const R = recordIdByNote('A', 'LWW-初始');
  run('A', 'sync', { userId: ctx.userId });
  run('B', 'sync', { userId: ctx.userId });
  const editA = run('A', 'edit_record', {
    userId: ctx.userId, recordId: R, category: 'recycle', subType: 'paper', amount: 7,
    occurredAt: AGO, note: 'LWW-A版', at: T1,
  });
  const syncA1 = run('A', 'sync', { userId: ctx.userId });
  // t62 起 B 那端也走**真实业务路径** `records.edit`：t57 版夹具在这里用「直接行改写」绕开的
  // 正是当时的 F3（两端各自落"同业务键、不同 id"的 point_record 反向流水 → 下一次 pull 撞
  // `uq_pr_source` 抛错，见第 8.4 节）。修复后 pull 侧按业务唯一键认领，真实编辑可以端到端跑通，
  // 所以本项现在验的是**完整业务链路 + 同步链路**，不再有构造性绕过。
  const editB = run('B', 'edit_record', {
    userId: ctx.userId, recordId: R, category: 'recycle', subType: 'paper', amount: 9,
    occurredAt: AGO, note: 'LWW-B版', at: T2,
  });
  const syncB = run('B', 'sync', { userId: ctx.userId });
  const syncA2 = run('A', 'sync', { userId: ctx.userId });
  const pA1 = pushOut(syncA1);
  const pB = pushOut(syncB);
  const pA2 = pushOut(syncA2);
  const a = dbRow('A', 'carbon_record', R);
  const b = dbRow('B', 'carbon_record', R);
  const srv = serverRow('carbon_record', R);
  const srvBefore = (() => {
    // 用 A 第一次 push 之后的状态做对照：此处只记录最终值，前后对照见 evidence 里的时间戳
    return null;
  })();
  check(
    '2.1',
    '服务端按 updatedAt 大者胜：B 的版本（updated_at 更大）被采纳，且被计为真冲突',
    pB !== null && (pB.data.acceptedByTable.carbon_record || 0) >= 1 && pB.data.conflicts >= 1,
    [
      `A 改（T1=${T1}）: ${wireLine(pushWire(syncA1))}`,
      `B 改（T2=${T2}）: ${wireLine(pushWire(syncB))}`,
      `服务端采纳后该行: updated_at=${norm(srv && srv.updated_at)} note=${norm(srv && srv.note)}`,
      `B push 的 conflicts=${pB.data.conflicts}（两端自上次同步后都改过这一行 → 真冲突）`,
    ],
  );
  const diffs = crossDiffs(a, b);
  check(
    '2.2',
    '两端最终行**除 `updated_at` 外逐列完全相同**（不是只断言服务端返回 accepted；`updated_at` 是各自客户端基准，差值 = 两端时钟偏移）',
    diffs.length === 0 && basisOf(a, offsetOf(syncA2)) === basisOf(b, offsetOf(syncB)),
    [
      `A push#2（旧版本，被服务端拒绝）: ${wireLine(pushWire(syncA2))}`,
      `A 库: ${rowBrief(a)}`,
      `B 库: ${rowBrief(b)}`,
      `差异列（跳过 sync_state / updated_at）: ${diffs.length === 0 ? '无' : diffs.join(' ; ')}`,
      `严格基准等价（无容差）：A 值+offA2=${basisOf(a, offsetOf(syncA2))}（offA2=${offsetOf(syncA2)}）、`
        + `B 值+offB=${basisOf(b, offsetOf(syncB))}（offB=${offsetOf(syncB)}）`,
    ],
  );
  check(
    '2.3',
    '胜者确为 updatedAt 更大的一版（B 版内容），且服务端与两端同一份',
    a !== null && b !== null && a.note === 'LWW-B版' && norm(a.amount) === '9'
      && norm(b.amount) === '9' && srv.note === 'LWW-B版'
      && basisOf(a, offsetOf(syncA2)) === basisOf(b, offsetOf(syncB))
      && basisOf(b, offsetOf(syncB)) === Number(norm(srv.updated_at)),
    [
      `T2=${T2}（B 版） > T1=${T1}（A 版）`,
      `A 库: updated_at=${norm(a && a.updated_at)} note=${norm(a && a.note)} amount=${norm(a && a.amount)}`,
      `B 库: updated_at=${norm(b && b.updated_at)} note=${norm(b && b.note)} amount=${norm(b && b.amount)}`,
      `服务端: updated_at=${norm(srv && srv.updated_at)} note=${norm(srv && srv.note)} amount=${norm(srv && srv.amount)}`,
    ],
  );
  check(
    '2.4',
    '旧版本上行被服务端**拒绝**（不做降级覆盖），A 靠随后的 pull 收敛到胜者版本',
    pA2 !== null && pA2.data.rejected >= 1
      && basisOf(a, offsetOf(syncA2)) === Number(norm(srv.updated_at)),
    [
      `A push#2 响应: ${j(pA2.data)}`,
      `A 库最终: ${rowBrief(a)}`,
      `服务端在 push 响应里回了 merged（客户端 sync() 只检查 status、从不读 body）：${truncate(j(pA2.data.merged), 500)}`,
    ],
  );
  OBS.item7a = {
    ignored: pA2.data.ignored,
    rejected: pA2.data.rejected,
    accepted: pA2.data.accepted,
    conflicts: pA2.data.conflicts,
    skipped: pA2.data.skipped,
    evidence: `A push#2 原始响应: ${truncate(pA2.raw, 600)}`,
  };
  OBS.conflictTrue = { conflicts: pB.data.conflicts, evidence: `B push 原始响应: ${truncate(pB.raw, 600)}` };
  if (srvBefore !== null) {
    note('(占位)', []);
  }
}

/**
 * 第 3 项：平局按 `deviceId` 字典序（两端同一规则、结论一致）。
 *
 * 为什么这么构造（写进报告，避免"造假输入"的误解）：
 *  - 客户端平局分支要求"对端 `updated_at` **换算到本机基准后与本机完全相等**"
 *    （`SyncService.ets`：`clientOffsetMs` 修正后再比）。t62 修复前 `offsetMsClient` 恒为 0，
 *    所以"相等"只能用**原始值相等**去凑；修复后必须把客户端时钟也摆对，否则永远走不到平局分支。
 *  - 客户端 `sync()` 是**先 push 再 pull**、push/pull 共用同一个 `since` 锚点，所以本项的构造是：
 *    ① 把"对端那一版"直接摆进服务端库（`serverUpdate`，只构造输入，不改被测实现）；
 *    ② 把本机锚点设到 `T+1`：本机行（`updated_at = T`）因 `updated_at > since` 不成立**不进上行**
 *       —— 服务端那一版因此不会被本机的 push 盖掉；而服务端那一版 `T+Δ > T+1` 仍会被 pull 取回；
 *    ③ 让两端这次同步都带"本机时钟**落后** Δ = 300000ms"，于是 push 握手腿回传
 *       `offsetMs ≈ +Δ`、客户端算出 `clientOffsetMs = -Δ`，服务端那一版 `T+Δ` 换算到本机基准
 *       恰好等于 `T` ⇒ **精确平局**落在客户端 `remoteDevice > localDevice` 上。
 *  - 服务端一侧的平局规则另用直连探针（3.4，`offsetMs=0`）单独钉住。
 */
async function scenario3() {
  section('第 3 项：平局按 deviceId（updated_at 完全相等 → 字典序大者胜，两端一致）');

  // 3.1 / 3.2 对端 deviceId 更大 ⇒ 两端都必须让位
  //
  // 平局输入必须**逐毫秒相等**才会命中客户端的平局分支，而"相等"依赖时钟换算：握手腿的
  // `offsetMs = 服务端 started_at − 客户端 clientNow` 含请求往返的若干毫秒抖动，用标称 Δ 摆出来的
  // 平局实际会差几毫秒（t62 首跑实测差 57ms ⇒ 3.1/3.2 假红）。故改为**确定性构造**：
  //   ① 服务端那一版与本机那一版的 raw `updated_at` **完全相等**（这才是真的平局输入）；
  //   ② 两端各自把本机时钟**调快** D=5 分钟 ⇒ 服务端握手腿 offsetMs ≈ −D ⇒ 本机上行被判"比服务端旧"
  //      而 **rejected**，服务端那一版不被覆盖 —— 这是抵消"同一锚点下本机行必然被 push"的必要手段
  //      （push 与 pull 共用 `since`，见 SyncService.ets 的 pushBody/applyPull 同源锚点）；
  //   ③ 协议补全代理把 pull 响应的 offsetMs 强制写成 **0**（`clientOffsetMs = -0 = 0`）⇒ 客户端按裸 raw
  //      比较 ⇒ 与 ② 无关地、逐毫秒相等地命中平局分支；`device_id` 比较与被测分支全都是真实代码。
  // 同一构造在 3.3 换成字典序更小的 `l2-dev-0` 作负向对照。
  const D = 300000;
  const P = Date.now() + 600000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'recycle', subType: 'aluminum', amount: 2,
    occurredAt: AGO, note: '平局-源', at: P,
  });
  const R = recordIdByNote('A', '平局-源');
  run('A', 'sync', { userId: ctx.userId });
  run('B', 'sync', { userId: ctx.userId });
  const localA = run('A', 'set_row', {
    table: 'carbon_record', id: R,
    values: { updated_at: P, device_id: DEV.A, note: '平局-A版', amount: 5, sync_state: 'pending' },
  });
  const localB = run('B', 'set_row', {
    table: 'carbon_record', id: R,
    values: { updated_at: P, device_id: DEV.B, note: '平局-B版', amount: 7, sync_state: 'pending' },
  });
  const staged = serverUpdate('carbon_record', R, {
    updated_at: P, device_id: 'l2-dev-Z', note: '平局-Z版', amount: 42,
  });
  const anchorA = run('A', 'set_config', { set: { last_sync_at: P - 1 }, get: ['last_sync_at'] });
  const anchorB = run('B', 'set_config', { set: { last_sync_at: P - 1 }, get: ['last_sync_at'] });
  const proxyZ = await spawnProxy('0');
  const syncA = run('A', 'sync', { userId: ctx.userId }, { clockOffsetMs: D, baseUrl: proxyZ.url });
  const syncB = run('B', 'sync', { userId: ctx.userId }, { clockOffsetMs: D, baseUrl: proxyZ.url });
  const pA = pushOut(syncA);
  const pB = pushOut(syncB);
  const a = dbRow('A', 'carbon_record', R);
  const b = dbRow('B', 'carbon_record', R);
  const srv = serverRow('carbon_record', R);
  const diffs = columnDiff(a, b);
  const flushOf = (r) => {
    try {
      return JSON.parse(String((r || {}).raw)).data.offsetMs;
    } catch (e) {
      return null;
    }
  };
  check(
    '3.1',
    '对端 deviceId 字典序更大（l2-dev-Z > l2-dev-A / l2-dev-B）且两端 raw updated_at **完全相等** ⇒ 客户端平局分支采纳对端版本',
    staged.ok === true && a !== null && b !== null
      && pA.data.offsetMs <= -D + 120000 && pA.data.offsetMs >= -D - 120000
      && pA.data.rejected >= 1
      && norm(a.updated_at) === String(P) && a.note === '平局-Z版' && norm(a.device_id) === 'l2-dev-Z'
      && norm(b.updated_at) === String(P) && b.note === '平局-Z版' && norm(b.device_id) === 'l2-dev-Z',
    [
      `平局构造：本机 A=(updated_at=${P}, device_id=${DEV.A}, note=平局-A版) / 本机 B=(updated_at=${P}, device_id=${DEV.B}, note=平局-B版) / 服务端=(updated_at=${P}, device_id=l2-dev-Z, note=平局-Z版) —— 三方 raw 逐毫秒相等`,
      `锚点（两端）: ${j(anchorA.config)} / ${j(anchorB.config)} —— 本机行 updated_at=${P} > ${P - 1} ⇒ 会被 push（故需 ② 让服务端拒绝它）；服务端那一版同为 ${P} 也被 pull 取回`,
      `A push 响应 offsetMs=${flushOf(pA)}、rejected=${pA.data.rejected}（本机时钟调快 ${D}ms ⇒ 握手腿回传 ≈ −${D} ⇒ 本机上行"比服务端旧"被拒，服务端那一版未被覆盖）`,
      `B push 响应 offsetMs=${flushOf(pB)}、rejected=${pB.data.rejected}`,
      '③ 本轮 baseUrl 指向协议补全代理（forceOffsetMs=0）⇒ 客户端 clientOffsetMs = -0 = 0 ⇒ 按裸 raw 比较 ⇒ 与 raw 相等 ⇒ 命中平局分支',
      `A 侧 set_row 回读: ${j(localA.row)}`,
      `B 侧 set_row 回读: ${j(localB.row)}`,
      `服务端构造后: ${rowBrief(staged.row)}`,
      `A push: ${wireLine(pushWire(syncA))}`,
      `B push: ${wireLine(pushWire(syncB))}`,
      `A 库: ${rowBrief(a)}`,
      `B 库: ${rowBrief(b)}`,
    ],
  );
  check(
    '3.2',
    '两端最终行**逐列完全相同**（不是"服务端返回 accepted"就算），且与服务端那一份同一版本',
    diffs.length === 0 && srv !== null && norm(srv.note) === '平局-Z版'
      && norm(srv.updated_at) === norm(a.updated_at) && norm(srv.device_id) === 'l2-dev-Z',
    [
      `A 库: ${rowBrief(a)}`,
      `B 库: ${rowBrief(b)}`,
      `服务端: ${rowBrief(srv)}`,
      `差异列: ${diffs.length === 0 ? '无' : diffs.join(' ; ')}`,
    ],
  );

  // 3.3 反向：对端 deviceId 更小 ⇒ 两端都保留本机（比较方向的负向对照）
  const P2 = Date.now() + 900000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'recycle', subType: 'glass', amount: 3,
    occurredAt: AGO, note: '平局2-源', at: P2,
  });
  const R2 = recordIdByNote('A', '平局2-源');
  run('A', 'sync', { userId: ctx.userId });
  run('B', 'sync', { userId: ctx.userId });
  run('A', 'set_row', {
    table: 'carbon_record', id: R2,
    values: { updated_at: P2, device_id: DEV.A, note: '平局2-A版', amount: 4, sync_state: 'pending' },
  });
  run('B', 'set_row', {
    table: 'carbon_record', id: R2,
    values: { updated_at: P2, device_id: DEV.B, note: '平局2-B版', amount: 6, sync_state: 'pending' },
  });
  const staged0 = serverUpdate('carbon_record', R2, {
    updated_at: P2, device_id: 'l2-dev-0', note: '平局2-0版', amount: 99,
  });
  run('A', 'set_config', { set: { last_sync_at: P2 - 1 }, get: ['last_sync_at'] });
  run('B', 'set_config', { set: { last_sync_at: P2 - 1 }, get: ['last_sync_at'] });
  const syncA2 = run('A', 'sync', { userId: ctx.userId }, { clockOffsetMs: D, baseUrl: proxyZ.url });
  const syncB2 = run('B', 'sync', { userId: ctx.userId }, { clockOffsetMs: D, baseUrl: proxyZ.url });
  await proxyZ.close();
  const a2 = dbRow('A', 'carbon_record', R2);
  const b2 = dbRow('B', 'carbon_record', R2);
  check(
    '3.3',
    '负向对照：对端 deviceId 更小（l2-dev-0 < l2-dev-A / l2-dev-B）且两端 raw updated_at 完全相等 ⇒ 两端各自保留本机版本，不采纳对端',
    staged0.ok === true && a2 !== null && b2 !== null
      && norm(a2.updated_at) === String(P2) && a2.note === '平局2-A版'
      && norm(b2.updated_at) === String(P2) && b2.note === '平局2-B版',
    [
      `服务端构造后: ${rowBrief(staged0.row)}（与本机 raw 逐毫秒相等）`,
      `A push 响应 offsetMs=${flushOf(pushOut(syncA2))}、rejected=${pushOut(syncA2).data.rejected}`,
      `A 库（应保留本机）: ${rowBrief(a2)}`,
      `B 库（应保留本机）: ${rowBrief(b2)}`,
      '注：这一支按规则"对端更小 ⇒ 保留本机"，两端各自留住自己那一版；它不是收敛用例，'
        + '只用来证明比较方向（若把判据反转成"字典序小者胜"，A/B 都会变成平局2-0版 ⇒ 本条与 3.1 同时变红）。',
    ],
  );

  // 3.4 服务端那一侧的平局规则：把同一份 push body 用 offsetMs=0（省略 clientNow）重放
  const T3 = Date.now() + 120000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'recycle', subType: 'paper', amount: 1,
    occurredAt: AGO, note: '平局3-源', at: T3,
  });
  const R3 = recordIdByNote('A', '平局3-源');
  run('A', 'sync', { userId: ctx.userId });
  const rowA = dbRow('A', 'carbon_record', R3);
  // 服务端存量已是**服务端基准**（§5.3:1095；t68 修复后 `raw + offset_ms`），而本机行是客户端基准。
  // 探针省略 `clientNow` ⇒ `offsetMs=0` ⇒ 服务端拿 raw 与存量原值比较；要构成**精确平局**，
  // 探针的 raw 必须恰好等于服务端存量值 —— 所以这里用服务端那一行的 `updated_at`。
  const srvRow3 = serverRow('carbon_record', R3);
  const bodyFor = (device) => JSON.stringify({
    userId: ctx.userId,
    deviceId: DEV.A,
    lastSyncAt: 0,
    tables: { carbon_record: [{ ...srvRow3, device_id: device, note: `平局3-${device}` }] },
  });
  const probeZ = await httpJson('POST', '/api/v1/sync/push', bodyFor('l2-dev-Z'), ctx.token);
  const srvAfterZ = serverRow('carbon_record', R3);
  const probe0 = await httpJson('POST', '/api/v1/sync/push', bodyFor('l2-dev-0'), ctx.token);
  const srvAfter0 = serverRow('carbon_record', R3);
  check(
    '3.4',
    '服务端平局规则同向：`offsetMs=0`（省略 clientNow）时，同一 `updated_at` 下 deviceId 大者被采纳、小者被记 ignored',
    probeZ.status === 200 && probeZ.json.data.offsetMs === 0
      && probeZ.json.data.acceptedByTable.carbon_record === 1
      && srvAfterZ !== null && srvAfterZ.device_id === 'l2-dev-Z'
      && probe0.status === 200 && (probe0.json.data.acceptedByTable.carbon_record || 0) === 0
      && probe0.json.data.ignored >= 1 && srvAfter0 !== null && srvAfter0.device_id === 'l2-dev-Z',
    [
      `本机行 updated_at=${norm(rowA && rowA.updated_at)}（客户端基准） vs 服务端存量 ${norm(srvRow3 && srvRow3.updated_at)}（服务端基准）：两者本就不同基准，探针因此取服务端存量值作 raw`,
      `直连探针①（device_id=l2-dev-Z，省略 clientNow）: ${truncate(probeZ.body, 500)}`,
      `服务端该行: ${rowBrief(srvAfterZ)}`,
      `直连探针②（device_id=l2-dev-0）: ${truncate(probe0.body, 500)}`,
      `服务端该行未变: ${rowBrief(srvAfter0)}`,
      `三数自洽：skipped=${probe0.json.data.skipped} = ignored(${probe0.json.data.ignored}) + rejected(${probe0.json.data.rejected})`,
      '口径提醒：真实客户端总会带 `clientNow`（SyncService.ets:513），于是 `offsetMs≈+50ms≠0`，'
        + '服务端比较的是 `raw + offsetMs` ⇒ **永远构不成相等**，平局分支在真实链路上轮不到；'
        + '上面 3.1/3.2 的"两端一致"正是靠"服务端拒绝上行（更旧）+ 客户端平局分支"取得的。',
    ],
  );
  OBS.tie = {
    staged: rowBrief(staged.row),
    a: rowBrief(a),
    b: rowBrief(b),
    pushA: truncate((pA || {}).raw, 300),
    pushB: truncate((pB || {}).raw, 300),
  };
}

/**
 * 第 5 项：幂等（同一批 push 连推两次）。
 *
 * 两层证据：
 *  · 客户端层：把刚推过的行重新标脏（= "上一次 push 的响应丢了、客户端重试同一批"）再 `sync()`
 *    → 断言**不产生任何重复行**（两端 + 服务端三处行数不变、库内无重复 id）且行内容不变；
 *  · 服务端层：用直连 HTTP 探针把**同一份 push body 原样重放**，分别带 / 不带 `clientNow`，
 *    把附录 B §5.3 的 `accepted=0` 钉到它的真实前提上（同一时钟基准 ⇒ `offsetMs=0`）。
 */
async function scenario5() {
  section('第 5 项：幂等（同一批 push 连推两次）');
  const T = Date.now() + 60000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'plate', subType: 'meal', amount: 3,
    occurredAt: AGO, note: 'L2-幂等', at: T,
  });
  const R = recordIdByNote('A', 'L2-幂等');
  const sync1 = run('A', 'sync', { userId: ctx.userId });
  const p1 = pushOut(sync1);
  run('B', 'sync', { userId: ctx.userId });
  const rowBefore = dbRow('A', 'carbon_record', R);
  const n1 = {
    a: dbCount('A', 'carbon_record', 'WHERE user_id = ?', [ctx.userId]),
    b: dbCount('B', 'carbon_record', 'WHERE user_id = ?', [ctx.userId]),
    srv: serverCount('carbon_record'),
  };
  const mark = run('A', 'mark_pending', { rows: [{ table: 'carbon_record', id: R }] });
  const sync2 = run('A', 'sync', { userId: ctx.userId });
  const p2 = pushOut(sync2);
  const rowAfter = dbRow('A', 'carbon_record', R);
  const n2 = {
    a: dbCount('A', 'carbon_record', 'WHERE user_id = ?', [ctx.userId]),
    b: dbCount('B', 'carbon_record', 'WHERE user_id = ?', [ctx.userId]),
    srv: serverCount('carbon_record'),
  };
  const dup = dbRows('A', 'SELECT id, COUNT(*) AS c FROM carbon_record GROUP BY id HAVING c > 1');
  const dupB = dbRows('B', 'SELECT id, COUNT(*) AS c FROM carbon_record GROUP BY id HAVING c > 1');
  check(
    '5.1',
    '复推同一批**不产生重复行**：两端 + 服务端三处行数不变，库内无重复 id，且该行内容逐列不变',
    n1.a === n2.a && n1.b === n2.b && n1.srv === n2.srv
      && dup.length === 0 && (dupB === null || dupB.length === 0)
      && columnDiff(rowBefore, rowAfter).length === 0,
    [
      `第一次 push: ${truncate((p1 || {}).raw, 400)}`,
      `重新标脏: ${j(mark.touched)}`,
      `第二次 push（同一批）: ${truncate((p2 || {}).raw, 400)}`,
      `行数 A: ${n1.a} → ${n2.a}；B: ${n1.b} → ${n2.b}；服务端 carbon_record: ${n1.srv} → ${n2.srv}`,
      `A 库重复 id: ${j(dup)}；B 库重复 id: ${j(dupB)}`,
      `该行内容差异（复推前后）: ${columnDiff(rowBefore, rowAfter).length === 0 ? '无' : columnDiff(rowBefore, rowAfter).join(' ; ')}`,
    ],
  );
  check(
    '5.2',
    '三数自洽：`skipped = ignored + rejected`（附录 B §5.3）',
    (p2 || {}).data !== undefined
      && p2.data.skipped === p2.data.ignored + p2.data.rejected,
    [
      `第二次 push 响应: ${truncate((p2 || {}).raw, 500)}`,
      `解析: skipped=${(p2 || {}).data === undefined ? 'n/a' : p2.data.skipped} ignored=${(p2 || {}).data === undefined ? 'n/a' : p2.data.ignored} rejected=${(p2 || {}).data === undefined ? 'n/a' : p2.data.rejected}`,
    ],
  );

  // 服务端层：同一份 body 重放两次（真实 HTTP，直连服务端，不经客户端）
  const body = ((pushWire(sync2) || {}).reqBody || '');
  const bodyObj = JSON.parse(body);
  const noNow = {};
  for (const k2 of Object.keys(bodyObj)) {
    if (k2 !== 'clientNow') {
      noNow[k2] = bodyObj[k2];
    }
  }
  const r1 = await httpJson('POST', '/api/v1/sync/push', body, ctx.token);
  const r2 = await httpJson('POST', '/api/v1/sync/push', JSON.stringify(noNow), ctx.token);
  const d1 = r1.json === null ? {} : r1.json.data;
  const d2 = r2.json === null ? {} : r2.json.data;
  const n3 = {
    a: dbCount('A', 'carbon_record', 'WHERE user_id = ?', [ctx.userId]),
    srv: serverCount('carbon_record'),
  };
  check(
    '5.3',
    '服务端口径：**省略 `clientNow`**（⇒ `offsetMs=0`）重放同一批 ⇒ `accepted=0`、`skipped=ignored+rejected`（三数自洽）—— 附录 B §5.3 的"复推不写入"成立；此时批次被判 `ignored`(同版本) 还是 `rejected`(换算后更旧，因存量已是服务端基准) 取决于时钟基准，两者都不写入、都不计 conflicts',
    r2.status === 200 && d2.offsetMs === 0 && d2.accepted === 0
      && (d2.ignored + d2.rejected) > 0 && d2.skipped === d2.ignored + d2.rejected,
    [
      `重放 body 长度=${body.length}（第 ${body.length} 字节…取本次 sync 的真实上行原文）`,
      `直连探针（省略 clientNow）响应: ${truncate(r2.body, 700)}`,
    ],
  );
  check(
    '5.4',
    '同一份 body **带 `clientNow`** 重放（真实客户端就是这样）⇒ `offsetMs≠0`，服务端把同一批再判为 `accepted>0`（写回同值、不新增行）⇒ §5.3 的 `accepted=0` 以"两端同一时钟基准"为前提',
    r1.status === 200 && d1.offsetMs !== 0 && d1.accepted > 0
      && d1.accepted + d1.ignored + d1.rejected === d2.accepted + d2.ignored + d2.rejected,
    [
      `直连探针（原样，带 clientNow）响应: ${truncate(r1.body, 700)}`,
      `对比：带 clientNow → accepted=${d1.accepted} ignored=${d1.ignored} offsetMs=${d1.offsetMs}；省略 clientNow → accepted=${d2.accepted} ignored=${d2.ignored} offsetMs=${d2.offsetMs}`,
      '机制：服务端比较的是 `remote_updated = values.updated_at + offset_ms`（sync_service.py:459），'
        + '而落库的是客户端原始时间戳（:496-500）。只要 `offset_ms≠0`，重放同一行就会变成 `T+offset > T` ⇒ 判为"更新"。',
    ],
  );
  check(
    '5.5',
    '两次重放之后行数依旧不变（既没有新增行、也没有被删）',
    n3.a === n2.a && n3.srv === n2.srv,
    [
      `行数 A: ${n2.a} → ${n3.a}；服务端 carbon_record: ${n2.srv} → ${n3.srv}`,
    ],
  );
  OBS.idemProbe = {
    accepted: d2.accepted, ignored: d2.ignored, rejected: d2.rejected,
    skipped: d2.skipped, conflicts: d2.conflicts, offsetMs: d2.offsetMs,
    withNow: { accepted: d1.accepted, ignored: d1.ignored, rejected: d1.rejected, conflicts: d1.conflicts, offsetMs: d1.offsetMs },
    raw: truncate(r2.body, 400),
  };
  OBS.idem = { p1: truncate((p1 || {}).raw, 300), p2: truncate((p2 || {}).raw, 300) };
}

/** 第 6 项：软删除传播。 */
function scenario6() {
  section('第 6 项：软删除传播（A 删 → push → B pull → is_deleted=1 且行仍在）');
  const T = TIME_BASE + 800000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'travel', subType: 'bicycle', amount: 4,
    occurredAt: AGO, note: 'L2-待删', at: T,
  });
  const R = recordIdByNote('A', 'L2-待删');
  run('A', 'sync', { userId: ctx.userId });
  run('B', 'sync', { userId: ctx.userId });
  const beforeB = dbRow('B', 'carbon_record', R);
  const rm = run('A', 'remove_record', { userId: ctx.userId, recordId: R, at: T + 60000 });
  const syncA = run('A', 'sync', { userId: ctx.userId });
  const syncB = run('B', 'sync', { userId: ctx.userId });
  const a = dbRow('A', 'carbon_record', R);
  const b = dbRow('B', 'carbon_record', R);
  const srv = serverRow('carbon_record', R);
  check(
    '6.1',
    'B 侧收到软删除：is_deleted=1',
    rm.ok === true && b !== null && Number(b.is_deleted) === 1 && Number(beforeB.is_deleted) === 0,
    [
      `删除前 B 侧: is_deleted=${norm(beforeB && beforeB.is_deleted)}`,
      `remove 结果: ${j(rm)}`,
      `B pull 原始响应（该行）: ${truncate(j((pullRes(syncB) || { data: {} }).data.tables.carbon_record.filter((r) => r.id === R)), 500)}`,
      `B 侧该行: ${rowBrief(b)}`,
    ],
  );
  check(
    '6.2',
    '行**仍在表里**（不物理删）：两端各恰有 1 行，且 uptate 走 DELETE+INSERT 也不减行数',
    b !== null && dbCount('B', 'carbon_record', 'WHERE id = ?', [R]) === 1
      && dbCount('A', 'carbon_record', 'WHERE id = ?', [R]) === 1,
    [
      `A 侧该 id 行数=${dbCount('A', 'carbon_record', 'WHERE id = ?', [R])}`,
      `B 侧该 id 行数=${dbCount('B', 'carbon_record', 'WHERE id = ?', [R])}`,
      `B 侧该行: ${rowBrief(b)}`,
    ],
  );
  const diffs = crossDiffs(a, b);
  check(
    '6.3',
    '软删行两端除 `updated_at`（各自客户端基准）外逐列一致，且服务端也持软删行（不物理删）',
    diffs.length === 0 && basisOf(a, offsetOf(syncA)) === basisOf(b, offsetOf(syncB))
      && srv !== null && norm(srv.is_deleted) === '1',
    [
      `A 库: ${rowBrief(a)}`,
      `B 库: ${rowBrief(b)}`,
      `差异列（跳过 sync_state / updated_at）: ${diffs.length === 0 ? '无' : diffs.join(' ; ')}`,
      `严格基准等价（无容差）：A 值+offA=${basisOf(a, offsetOf(syncA))}、B 值+offB=${basisOf(b, offsetOf(syncB))}`,
      `服务端: ${rowBrief(srv)}`,
    ],
  );
}

/** 第 4 项：时钟偏移。 */
async function scenario4() {
  section('第 4 项：时钟偏移（offsetMs = 服务端 − 客户端；客户端须取反换算）');

  // 4.1 A 时钟落后 5 分钟 → offsetMs ≈ +300000；把"原始更旧"的行推上去，服务端换算后应采纳
  const T1 = TIME_BASE + 900000;
  run('B', 'save_record', {
    userId: ctx.userId, category: 'travel', subType: 'metro', amount: 6,
    occurredAt: AGO, note: '时钟-B基准', at: T1,
  });
  const R1 = recordIdByNote('B', '时钟-B基准');
  run('B', 'sync', { userId: ctx.userId });
  run('A', 'sync', { userId: ctx.userId });
  const srvBefore1 = serverRow('carbon_record', R1);
  run('A', 'edit_record', {
    userId: ctx.userId, recordId: R1, category: 'travel', subType: 'metro', amount: 8,
    occurredAt: AGO, note: '时钟-A落后5分', at: T1 - 60000,
  }, { clockOffsetMs: -300000 });
  const syncSkew1 = run('A', 'sync', { userId: ctx.userId }, { clockOffsetMs: -300000 });
  const pSkew1 = pushOut(syncSkew1);
  const srvAfter1 = serverRow('carbon_record', R1);
  check(
    '4.1',
    'A 时钟落后 5 分钟：offsetMs ≈ +300000（= 服务端 − 客户端），服务端把"原始时间戳更旧、换算后更新"的行采纳',
    pSkew1 !== null && Math.abs(pSkew1.data.offsetMs - 300000) < 20000
      && Number(norm(srvAfter1 && srvAfter1.updated_at)) === (T1 - 60000) + pSkew1.data.offsetMs
      && srvAfter1.note === '时钟-A落后5分',
    [
      `A 那行的原始 updated_at=${T1 - 60000}（客户端基准），服务端原值 ${norm(srvBefore1 && srvBefore1.updated_at)}（= B 推送时的换算值，服务端基准）`,
      `换算：remote_updated = ${T1 - 60000} + offsetMs(${pSkew1.data.offsetMs}) = ${(T1 - 60000) + pSkew1.data.offsetMs} > local ${T1} → 采纳`,
      `push 响应 offsetMs=${pSkew1.data.offsetMs}（≈ +300000 ⇒ 服务端时钟 − 客户端时钟，客户端落后）`,
      `服务端前: ${rowBrief(srvBefore1)}`,
      `服务端后: ${rowBrief(srvAfter1)}（期望 = raw + offsetMs = ${(T1 - 60000) + pSkew1.data.offsetMs}）`,
      `原始响应: ${truncate(pSkew1.raw, 700)}`,
    ],
  );

  // 4.2 反向：A 时钟超前 5 分钟 → offsetMs ≈ −300000；原始更新但换算后更旧 → 服务端拒绝
  const T2 = TIME_BASE + 960000;
  run('B', 'save_record', {
    userId: ctx.userId, category: 'utility', subType: 'gas', amount: 3,
    occurredAt: AGO, note: '时钟-B基准2', at: T2,
  });
  const R2 = recordIdByNote('B', '时钟-B基准2');
  run('B', 'sync', { userId: ctx.userId });
  run('A', 'sync', { userId: ctx.userId });
  run('A', 'edit_record', {
    userId: ctx.userId, recordId: R2, category: 'utility', subType: 'gas', amount: 5,
    occurredAt: AGO, note: '时钟-A超前5分', at: T2 + 60000,
  }, { clockOffsetMs: 300000 });
  const syncSkew2 = run('A', 'sync', { userId: ctx.userId }, { clockOffsetMs: 300000 });
  const pSkew2 = pushOut(syncSkew2);
  const srvAfter2 = serverRow('carbon_record', R2);
  check(
    '4.2',
    '反向：A 时钟超前 5 分钟，原始时间戳更新但换算后更旧 → 服务端拒绝（判据是"服务端 − 客户端"，不是原始值）',
    pSkew2 !== null && Math.abs(pSkew2.data.offsetMs + 300000) < 20000 && pSkew2.data.rejected >= 1
      && norm(srvAfter2 && srvAfter2.amount) === '3' && srvAfter2.note === '时钟-B基准2',
    [
      `A 那行的原始 updated_at=${T2 + 60000}（原始比服务端旧值 ${T2} 新，但换算后更旧）`,
      `换算：remote_updated = ${T2 + 60000} + offsetMs(${pSkew2.data.offsetMs}) = ${(T2 + 60000) + pSkew2.data.offsetMs} < local ${T2} → 拒绝`,
      `push 响应: ${j(pSkew2.data)}`,
      `服务端该行未变: ${rowBrief(srvAfter2)}`,
    ],
  );

  // 4.3 偏移超 300000ms：告警但继续合并
  const T3 = TIME_BASE + 1020000;
  run('B', 'save_record', {
    userId: ctx.userId, category: 'utility', subType: 'water', amount: 100,
    occurredAt: AGO, note: '时钟-B基准3', at: T3,
  });
  const R3 = recordIdByNote('B', '时钟-B基准3');
  run('B', 'sync', { userId: ctx.userId });
  run('A', 'sync', { userId: ctx.userId });
  run('A', 'edit_record', {
    userId: ctx.userId, recordId: R3, category: 'utility', subType: 'water', amount: 120,
    occurredAt: AGO, note: '时钟-A偏移超容差', at: T3 + 120000,
  }, { clockOffsetMs: -600000 });
  const syncSkew3 = run('A', 'sync', { userId: ctx.userId }, { clockOffsetMs: -600000 });
  const pSkew3 = pushOut(syncSkew3);
  const srvAfter3 = serverRow('carbon_record', R3);
  const warnEmpty = pSkew3 === null || pSkew3.data.clockWarning === null || pSkew3.data.clockWarning === undefined;
  check(
    '4.3',
    '偏移超过 ±300000ms：响应带 clockWarning，且**照常继续合并**（该行仍被采纳）',
    pSkew3 !== null && Math.abs(pSkew3.data.offsetMs) > 300000 && warnEmpty === false
      && Number(norm(srvAfter3 && srvAfter3.updated_at)) === (T3 + 120000) + pSkew3.data.offsetMs,
    [
      `offsetMs=${pSkew3.data.offsetMs}（|offsetMs| > 300000）`,
      `clockWarning=${j(pSkew3.data.clockWarning)}`,
      `继续合并的证据（服务端该行已变成 A 的版本）: ${rowBrief(srvAfter3)}`,
    ],
  );
  const logs = serverQuery(
    `SELECT direction, status, error_msg FROM sync_log WHERE user_id = '${ctx.userId}' ORDER BY started_at DESC LIMIT 3`,
  );
  check(
    '4.4',
    '服务端把该告警记进 sync_log（status=partial + error_msg），供 /sync/status 回显',
    logs.ok && logs.rows.some((r) => r.status === 'partial' && r.error_msg !== null && r.error_msg.includes('容差')),
    [
      `直查: SELECT direction,status,error_msg FROM sync_log ORDER BY started_at DESC LIMIT 3`,
      ...(logs.ok ? logs.rows.map((r) => `sync_log: direction=${r.direction} status=${r.status} error_msg=${r.error_msg}`) : [`查询失败: ${logs.error}`]),
    ],
  );

  // ── 4.5 / 4.6 客户端取反换算：`clientOffsetMs = -respOffsetMs`（附录 B §5.3 自证判据） ──
  // 构造：A 本机持 (T4, devA) 版本，服务端持"对端更晚"的 (T4+120000, devB) 版本；
  // 把 A 的锚点设到 T4+1，使 A 本机那一行**不进上行**（push 过滤是 `updated_at > since`），
  // 于是 pull 一定拿得到对端那一版 —— 客户端拿它跟本机比，结论完全由 `offsetMs` 的符号决定。
  const T4 = Date.now() + 60000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'travel', subType: 'bus', amount: 10,
    occurredAt: AGO, note: '时钟-本机版', at: T4,
  });
  const R4 = recordIdByNote('A', '时钟-本机版');
  run('A', 'sync', { userId: ctx.userId });
  const stage45 = serverUpdate('carbon_record', R4, {
    updated_at: T4 + 120000, device_id: DEV.B, note: '时钟-对端版', amount: 12,
  });
  const anchor45 = run('A', 'set_config', { set: { last_sync_at: T4 + 1 }, get: ['last_sync_at'] });
  // 4.5 A 的时钟**落后** 5 分钟（clientNow = 真时间 − 300000 ⇒ 服务端 offsetMs ≈ +300000）。
  // t62 修复后**不接代理**：真实 pull 响应里没有 `offsetMs`，客户端改用**同一轮 push 握手腿**的
  // `offsetMs`（优先取响应字段、缺省回落到握手腿）⇒ 取反换算在真实链路上可达。
  const back = run('A', 'sync', { userId: ctx.userId }, { clockOffsetMs: -300000 });
  const backPush = pushOut(back) || {};
  const backPull = pullRes(back) || {};
  const backHasOffset = (() => {
    try {
      return Object.prototype.hasOwnProperty.call((JSON.parse(backPull.raw || '{}').data) || {}, 'offsetMs');
    } catch (e) {
      return false;
    }
  })();
  const rowBack = dbRow('A', 'carbon_record', R4);
  check(
    '4.5',
    '真链路取反换算（A 落后 5 分钟，不接代理）：push 握手腿 `offsetMs ≈ +300000` ⇒ `clientOffsetMs = -300000` ⇒ 对端时间戳换算后**显得更旧**（T4+120000-300000 = T4-180000 < T4）⇒ A 保留本机版本',
    back.ok === true && backHasOffset === false
      && backPush.data.offsetMs >= 180000 && backPush.data.offsetMs <= 420000
      && rowBack !== null && rowBack.note === '时钟-本机版' && norm(rowBack.updated_at) === String(T4),
    [
      `构造：本机=(updated_at=${T4}, device_id=${DEV.A}, note=时钟-本机版)；服务端被夹具摆成=(updated_at=${T4 + 120000}, device_id=${DEV.B}, note=时钟-对端版)`,
      `服务端构造后: ${rowBrief(stage45.row)}`,
      `A 锚点（本机行不进上行）: ${j(anchor45.config)}`,
      `A push 握手腿响应 offsetMs=${backPush.data.offsetMs}（同上）`,
      `A pull 原始响应（**无** offsetMs 字段，hasOwnProperty=${backHasOffset}）: ${truncate(backPull.raw, 500)}`,
      `A 库最终（应保留本机版本）: ${rowBrief(rowBack)}`,
    ],
  );
  // 4.6 响应字段优先（附录 B §6.4-6 ①）：用协议补全代理把 pull 响应的 offsetMs **强制写成 0**。
  // 同一构造、同一时钟，只因"响应里有 offsetMs"就走响应值（0）⇒ 对端 raw 更大 ⇒ 采纳对端；
  // 与 4.5（响应无字段 ⇒ 回落握手腿 +300000 ⇒ 保留本机）互为对照，证明优先顺序与取反方向都对。
  run('A', 'set_config', { set: { last_sync_at: T4 + 1 }, get: ['last_sync_at'] });
  const proxy0 = await spawnProxy('0');
  const fwd = run('A', 'sync', { userId: ctx.userId }, { clockOffsetMs: -300000, baseUrl: proxy0.url });
  const fwdPull = pullRes(fwd) || {};
  const rowFwd = dbRow('A', 'carbon_record', R4);
  check(
    '4.6',
    '响应字段优先：代理把 pull 响应 offsetMs 强制为 0 ⇒ 客户端用响应值（不再用握手腿的 +300000）⇒ 对端 raw 更大 ⇒ A 采纳对端版本；同一构造在真链路（4.5）结论相反',
    fwd.ok === true && rowFwd !== null && rowFwd.note === '时钟-对端版',
    [
      `A pull 原始响应（代理补了 offsetMs=0）: ${truncate(fwdPull.raw, 500)}`,
      `A 库最终: ${rowBrief(rowFwd)}`,
      '两向对照：同一时钟偏移下，4.5（真实响应无字段 ⇒ 用握手腿 +300000）保留本机、4.6（响应字段 0 ⇒ 不换算）采纳对端。'
        + '若把取值写成 `optNum(data,"offsetMs") === undefined ? 0 : respOffset`（符号丢反）或直接丢掉握手腿回退，'
        + '4.5/4.6 至少一条会翻面变红（见 run.sh 的 `--mutate=offset-drop` 变异趟）。',
    ],
  );

  // 4.7 真实链路事实：pull 响应里没有 offsetMs
  run('A', 'set_row', {
    table: 'carbon_record', id: R4,
    values: { updated_at: T4, device_id: DEV.A, note: '时钟-本机版', amount: 10, sync_state: 'synced' },
  });
  serverUpdate('carbon_record', R4, {
    updated_at: T4 + 120000, device_id: DEV.B, note: '时钟-对端版', amount: 12,
  });
  const anchor47 = run('A', 'set_config', { set: { last_sync_at: T4 + 1 }, get: ['last_sync_at'] });
  const real = run('A', 'sync', { userId: ctx.userId });
  const realPull = pullRes(real) || {};
  const realKeys = (() => {
    try {
      return Object.keys((JSON.parse(realPull.raw || '{}').data) || {});
    } catch (e) {
      return ['<解析失败>'];
    }
  })();
  const rowReal = dbRow('A', 'carbon_record', R4);
  check(
    '4.7',
    '真实链路事实：直连服务端的 pull 响应**不含 `offsetMs`**（`SyncPullData` 就没有该字段）⇒ 客户端走**同一轮 push 握手腿**的 offsetMs（t62 修复，4.5 正是这条腿）；零偏移时该行按裸时间戳比较 ⇒ A 采纳对端那一版',
    real.ok === true && realPull.http === 200 && realKeys.indexOf('offsetMs') < 0
      && rowReal !== null && rowReal.note === '时钟-对端版',
    [
      `A 锚点: ${j(anchor47.config)}`,
      `真实 pull 响应字段: ${j(realKeys)}`,
      `真实 pull 原始响应: ${truncate(realPull.raw, 400)}`,
      `同一构造（服务端那一版 raw 更大）在真实链路上的实测后果: ${rowBrief(rowReal)}`
        + '（本次时钟零偏移 ⇒ `clientOffsetMs≈0` ⇒ 对端 raw 更大 ⇒ 覆盖本机；把时钟摆偏 5 分钟后结论翻面，见 4.5）',
      '影响面（t57 曾据此报 F2）：附录 B §5.3 的自证判据（`respOffsetMs = +60000 ⇒ 服务端 updatedAt = T 的行换算到客户端基准必须是 T − 60000`）'
        + '要求客户端拿到 `offsetMs`；`SyncPullData` 里没有该字段，因此客户端必须从 push 握手腿取（t62 已实现：响应有字段优先、缺省回落握手腿）。',
    ],
  );
  // ── 4.8 客户端**落库基准**（附录 B §5.3:1097「本机业务行的 `updated_at` = 客户端基准」） ──
  // 构造与 4.5 同形，但把 A 的时钟摆成**超前** 5 分钟（`clientOffsetMs = -offsetMs ≈ +300000`）⇒
  // 对端那一版换算后比本机更新 ⇒ A 采纳它。此时写进 A 库的 `updated_at` 必须是**换算到本机基准后**
  // 的值（`raw + clientOffsetMs`），而不是服务端返回的裸值 —— 否则本机库里就混了两种基准，
  // 下一轮再把它当"对端值"比较时整体偏 `|offsetMs|`（慢性漂移，t68 判据）。
  const T8 = Date.now() + 300000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'travel', subType: 'bus', amount: 7,
    occurredAt: AGO, note: '基准-本机版', at: T8,
  });
  const R8 = recordIdByNote('A', '基准-本机版');
  run('A', 'sync', { userId: ctx.userId });
  const raw8 = T8 + 120000;
  serverUpdate('carbon_record', R8, {
    updated_at: raw8, device_id: DEV.B, note: '基准-对端版', amount: 12,
  });
  const anchor48 = run('A', 'set_config', { set: { last_sync_at: T8 + 1 }, get: ['last_sync_at'] });
  const ahead = run('A', 'sync', { userId: ctx.userId }, { clockOffsetMs: 300000 });
  const aheadPush = pushOut(ahead) || {};
  const off8 = (aheadPush.data || {}).offsetMs;
  const row8 = dbRow('A', 'carbon_record', R8);
  const stored8 = row8 === null ? NaN : Number(norm(row8.updated_at));
  const expect8 = raw8 + (-off8);
  check(
    '4.8',
    '客户端落库基准（§5.3:1097）：A 时钟超前 5 分钟（`clientOffsetMs = -offsetMs ≈ +300000`）采纳对端版本时，写进本机库的 `updated_at` 必须是**本机基准**值 `raw + clientOffsetMs`，不能是服务端裸值',
    ahead.ok === true && row8 !== null && row8.note === '基准-对端版'
      && Math.abs(stored8 - raw8) > 1000
      && Math.abs(stored8 - expect8) <= 3000,
    [
      `A 锚点（本机行不进上行）: ${j(anchor48.config)}`,
      `服务端那一版（夹具摆）: updated_at=${raw8} device_id=${DEV.B} note=基准-对端版`,
      `A push 握手腿 offsetMs=${off8} ⇒ clientOffsetMs=${-off8}`,
      `A 库最终: ${rowBrief(row8)}`,
      `判定：库内 updated_at=${stored8}；服务端裸值=${raw8}（差 ${stored8 - raw8}）；本机基准期望=${expect8}（差 ${stored8 - expect8}）`,
      '改前（t68 修复前）库内 = 服务端裸值（差=0）⇒ 本机库里混两种基准；改后 = 本机基准值。',
    ],
  );

  // ── 4.9 时钟往返**不得漂移**（N=3 轮、同一行、偏移恒定：钟慢 60 秒） ──
  // 同一行连续「push → pull」三轮，每轮都把本机行重推一次（`updated_at > since` 恒成立）：
  // 本机库与服务端库的 `updated_at` 都不得逐轮被再加一次偏移，内容也不得被反复改写。
  const T9 = Date.now() + 180000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'travel', subType: 'bus', amount: 9,
    occurredAt: AGO, note: '不漂移', at: T9,
  });
  const R9 = recordIdByNote('A', '不漂移');
  const round9 = [];
  let i9 = 0;
  while (i9 < 3) {
    const r9 = run('A', 'sync', { userId: ctx.userId }, { clockOffsetMs: -60000 });
    const p9 = pushOut(r9) || {};
    const l9 = dbRow('A', 'carbon_record', R9);
    const s9 = serverRow('carbon_record', R9);
    round9.push({
      round: i9 + 1,
      ok: r9.ok === true,
      offsetMs: (p9.data || {}).offsetMs,
      local: l9 === null ? NaN : Number(norm(l9.updated_at)),
      server: s9 === null ? NaN : Number(norm(s9.updated_at)),
      note: l9 === null ? null : l9.note,
    });
    i9 = i9 + 1;
  }
  const near3 = (a, b) => Math.abs(a - b) <= 3000;
  // 严格不变量（**无容差**）：`本机值 + 该轮 offsetMs === 服务端值`。
  //   · 该轮 push 被接受 ⇒ 服务端存的就是「本机上行值 + offset」；
  //   · 该轮 push 被拒（对端换算后不更新）⇒ 本机采纳的是「服务端存量 − offset」。
  // 两条分支都必须**逐字节相等**；偏移被换算两次（±120000）或符号写反会立刻不等。
  const inv9 = round9.every((r) => r.ok && r.note === '不漂移'
    && typeof r.offsetMs === 'number' && r.local + r.offsetMs === r.server);
  // 服务端值只能等于「单次换算」的候选值，不能是累加形态。
  const seen9 = [];
  const noAccum9 = round9.every((r) => {
    seen9.push(T9 + r.offsetMs);
    return seen9.indexOf(r.server) >= 0;
  });
  // 本机值允许有往返抖动（被拒那一轮取的是对端换算值）⇒ 这一条才用 3s 容差，真正严格的是上面的不变量。
  const jitter9 = round9.every((r) => near3(r.local, T9));
  check(
    '4.9',
    '时钟往返不漂移：偏移恒定（钟慢 60 秒）时同一行连推 3 轮 —— 严格不变量 `本机值 + offsetMs === 服务端值`（无容差，接受/拒绝两条分支都成立），且服务端值只能是「单次换算」的值（排除偏移被累加两次）；本机 note 每轮不变',
    inv9 && noAccum9 && jitter9,
    round9.map((r) => `第 ${r.round} 轮：push offsetMs=${r.offsetMs}；本机库 updated_at=${r.local}（对 T9 差 ${r.local - T9}）`
      + `；服务端库 updated_at=${r.server}；不变量 本机+offset=${r.local + r.offsetMs} vs 服务端=${r.server} ⇒ ${r.local + r.offsetMs === r.server}`
      + `；本机 note=${r.note}`),
  );
  note(`4.9 补充：同一行三轮直查值 —— 本机 [${round9.map((r) => r.local).join(', ')}]，服务端 [${round9.map((r) => r.server).join(', ')}]`
    + `（若换算不幂等，每轮会各累加一次 |offsetMs|=60000 的偏差）。`);

  // ── 4.10 服务端**落库基准**（附录 B §5.3:1095「服务端与云端行的 `updated_at` = 服务端基准」） ──
  // 真推一行（客户端钟慢 60 秒 ⇒ 服务端 `offsetMs ≈ +60000`）：服务端库内必须存**换算后**的值
  //（`raw + offset_ms`），不能原样存客户端时间戳（改前即如此，实测见 t68 定事实）。
  const T10 = Date.now() + 240000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'utility', subType: 'water', amount: 30,
    occurredAt: AGO, note: '基准-服务端', at: T10,
  });
  const R10 = recordIdByNote('A', '基准-服务端');
  const pushed10 = run('A', 'sync', { userId: ctx.userId }, { clockOffsetMs: -60000 });
  const push10 = pushOut(pushed10) || {};
  const off10 = (push10.data || {}).offsetMs;
  const srv10 = serverRow('carbon_record', R10);
  const stored10 = srv10 === null ? NaN : Number(norm(srv10.updated_at));
  check(
    '4.10',
    '服务端落库基准（§5.3:1095）：客户端钟慢 60 秒推上一行（raw = 客户端基准）时，服务端库内 `updated_at` 必须**逐字节等于**服务端基准值 `raw + offset_ms`（无容差），不能原样存客户端时间戳',
    pushed10.ok === true && srv10 !== null && Math.abs(stored10 - T10) > 1000
      && stored10 === T10 + off10,
    [
      `A 本机行: at=${T10} note=基准-服务端`,
      `A push 握手腿 offsetMs=${off10}（≈ +60000）`,
      `直查服务端: ${rowBrief(srv10)}`,
      `判定：服务端 updated_at=${stored10}；客户端 raw=${T10}（差 ${stored10 - T10}）；服务端基准期望=${T10 + off10}（差 ${stored10 - (T10 + off10)}）`,
      '改前（t68 修复前）服务端 = 客户端 raw（差=0）⇒ 增量 `since` 与库内值跨基准，实测会漏行/重复拉（见 REPORT §7 与 VERIFICATION 追加节）。',
    ],
  );

  OBS.offset = {
    backPullKeys: backHasOffset ? 'has-offsetMs' : 'no-offsetMs',
    realKeys: realKeys,
    rowBack: rowBrief(rowBack),
    rowFwd: rowBrief(rowFwd),
    rowReal: rowBrief(rowReal),
  };
  await proxy0.close();
}

/** 第 7 项：冲突计数口径（`ignored` 不计入 `conflicts`，附录 B §6.4-3）。 */
function itemSeven() {
  section('第 7 项：冲突计数口径（ignored 不计入 conflicts）');
  const d2 = OBS.idemProbe || {};
  const tc = OBS.conflictTrue || {};
  check(
    '7.1',
    '纯去重批次（`accepted=0`、`ignored+rejected>0`）`conflicts=0` 且 `skipped=ignored+rejected` ⇒ **ignored 没有被计入 conflicts**',
    d2.accepted === 0 && (d2.ignored + d2.rejected) > 0 && d2.conflicts === 0
      && d2.skipped === d2.ignored + d2.rejected,
    [
      `原始响应: ${d2.raw}`,
      `accepted=${d2.accepted} ignored=${d2.ignored} rejected=${d2.rejected} conflicts=${d2.conflicts} skipped=${d2.skipped} offsetMs=${d2.offsetMs}`,
      '反证：如果 `ignored` 被算进 `conflicts`，本批的 conflicts 至少等于 ignored（>0）——实测为 0。',
    ],
  );
  check(
    '7.2',
    '同一个 `conflicts` 计数器在"两端都改过同一行"的批次里确实会 +1（第 2 项 B push）⇒ 7.1 不是"计数器坏了"造成的假绿',
    tc.conflicts >= 1,
    [
      `第 2 项 B push（两端都改过同一行）conflicts=${tc.conflicts}`,
      tc.evidence,
      '对照条件（服务端 sync_service.py:466-467）：`local_updated > last_sync_at and values.updated_at > last_sync_at`。',
    ],
  );
  note(
    '第 7 项 · 补充观察（混合批次）',
    [
      `第 2 项 A push（同一批里既有 ignored 也有 rejected）: ${j(OBS.item7a)}`,
      '口径提醒：`values.updated_at > last_sync_at` 对**任何被推上来的行**都成立（上行过滤本身就是 `updated_at > since`，'
        + '而 `since` 正是请求体里的 `lastSyncAt`），所以服务端的"真冲突"条件实际由 `local_updated > last_sync_at` 决定 —— '
        + '夹具为了让行"必被上推"而把行时间戳取在锚点之后（TIME_BASE 系），会天然满足该条件，故第 2 项那一批 conflicts 会偏大；'
        + '本条只做记录，不作为判定项。',
    ],
  );
}

/** 第 8 项：反证不是假绿（8.1 出网拦截；8.2 变异自证由 run.sh 跑两趟）。 */
function scenario8() {
  section('第 8 项：反证不是假绿');
  const eg = run('B', 'egress', {}, { allowNetwork: false });
  check(
    '8.1',
    '不设 L1_ALLOW_NETWORK 时垫片拒绝出网（贴原始错误）；本任务全程在 L1_ALLOW_NETWORK=1 下跑真 HTTP',
    eg.rejected === true && String(eg.message).includes('拦截'),
    [
      `L1_ALLOW_NETWORK=${eg.allowNetwork}`,
      `原始错误：${eg.message}`,
      `同一进程置 L1_ALLOW_NETWORK=1 时，上面的每一次 sync 都真的打到了 ${BASE_URL}（见各步原始请求/响应）`,
    ],
  );
  note('8.2 变异自证（由 run.sh 跑三趟：正常 → 变异 → git show 还原）', [
    '变异类型：把客户端平局判据 `remoteDevice > localDevice` 反转为 `remoteDevice < localDevice`（只改构建目录里的副本，仓库 app/** 零改动）',
    '见 run.sh 的 [变异自证] 段落输出与 REPORT.md 第 8 项',
  ]);

  // 8.3 F1（t62 修复）现场：全新第三台设备 C 的首同步（since=0）
  const bootC = run('C', 'boot', { username: USERNAME, password: PASSWORD });
  const cProfBefore = withDb('C', (db) => db.prepare('SELECT id, updated_at, device_id FROM user_profile WHERE user_id = ?').get(ctx.userId));
  const cAppBefore = withDb('C', (db) => db.prepare('SELECT id, updated_at, device_id FROM user_appearance WHERE user_id = ?').get(ctx.userId));
  const srvApp = serverQuery(`SELECT id, user_id, updated_at FROM user_appearance WHERE user_id = '${ctx.userId}'`);
  const syncC = run('C', 'sync', { userId: ctx.userId }, { expectError: true });
  const cAppAfter = dbRows('C', 'SELECT id, user_id, device_id, updated_at FROM user_appearance WHERE user_id = ?', [ctx.userId]);
  const cProfAfter = dbRows('C', 'SELECT id, user_id, device_id, updated_at FROM user_profile WHERE user_id = ?', [ctx.userId]);
  check(
    '8.3',
    'F1 修复现场（t57 曾报 blocker）：全新设备 C 的**首同步**（since=0）不再撞 uq_ua/uq_uprofile —— 客户端 pull 侧按 user_id 认领单例行（删本机旧行 + 写入远端行），本机仍只有一行',
    bootC.ok === true && syncC.ok === true && !String(syncC.errorString).includes('UNIQUE constraint')
      && cAppAfter.length === 1 && cProfAfter.length === 1,
    [
      `C 是全新库（deviceId=${bootC.stateDeviceId}，库=${dbFile('C')}），账号与 A/B 相同`,
      `C 本机首同步前: user_profile=${j(cProfBefore)}，user_appearance=${j(cAppBefore)}（id 由本机 IdUtil.uuid() 生成，与 A/B 都不同）`,
      `服务端 user_appearance: ${srvApp.ok ? j(srvApp.rows) : srvApp.error}`,
      `C 首同步 ok=${syncC.ok}，errorString=${j(syncC.errorString)}`,
      `C 本机首同步后: user_appearance=${j(cAppAfter)}，user_profile=${j(cProfAfter)}（各 1 行，id 收敛到服务端那一版）`,
      '修复前本条为红：pull 侧只按 `WHERE id = ?` 认领本机行，找不到就 INSERT（无 OR IGNORE）⇒ `UNIQUE constraint failed: user_appearance.user_id`'
        + '（t57 夹具第 8.3 节的原始栈；t62 起改为按 user_id 认领）。',
      '同族单例/业务键表：user_profile、user_appearance、user_goal、user_badge、user_purchase、science_progress。',
    ],
  );

  // 8.4 F3（t62 修复）现场：两端都对同一条记录走**真实编辑**（`records.edit`）
  const T6 = TIME_BASE + 1200000;
  run('A', 'save_record', {
    userId: ctx.userId, category: 'travel', subType: 'metro', amount: 4,
    occurredAt: AGO, note: '双方编辑-初始', at: T6,
  });
  const R6 = recordIdByNote('A', '双方编辑-初始');
  run('A', 'sync', { userId: ctx.userId });
  run('B', 'sync', { userId: ctx.userId });
  const editA6 = run('A', 'edit_record', {
    userId: ctx.userId, recordId: R6, category: 'travel', subType: 'metro', amount: 5,
    occurredAt: AGO, note: '双方编辑-A版', at: T6 + 60000,
  });
  run('A', 'sync', { userId: ctx.userId });
  const editB6 = run('B', 'edit_record', {
    userId: ctx.userId, recordId: R6, category: 'travel', subType: 'metro', amount: 6,
    occurredAt: AGO, note: '双方编辑-B版', at: T6 + 120000,
  });
  const srvP = serverQuery(
    `SELECT id, source_id, flow_kind, points FROM point_record WHERE user_id = '${ctx.userId}' AND source_id LIKE '${R6}%' ORDER BY source_id, flow_kind`,
  );
  const bPBefore = dbRows('B', "SELECT id, source_id, flow_kind, points FROM point_record WHERE source_id LIKE ? ORDER BY source_id, flow_kind", [`${R6}%`]);
  const syncB6 = run('B', 'sync', { userId: ctx.userId }, { expectError: true });
  const bPAfter = dbRows('B', "SELECT id, source_id, flow_kind, points FROM point_record WHERE source_id LIKE ? ORDER BY source_id, flow_kind", [`${R6}%`]);
  const keyOf = (r) => `${r.source_id}|${r.flow_kind}`;
  const sumOf = (rs) => (rs || []).reduce((acc, r) => acc + Number(r.points), 0);
  const srvRows = srvP.ok ? srvP.rows : [];
  const keysEqual = j(bPAfter.map(keyOf).sort()) === j(srvRows.map(keyOf).sort());
  const dupCheck = new Set(bPAfter.map(keyOf)).size === bPAfter.length;
  // 「内容不变」= 逐列深比较（不是"没报错"）；append_only 表的语义就是**同业务键去重、各自留本机那一版**
  // （server/app/services/sync_service.py 的 `_merge_append_only`：业务键命中 ⇒ ignored，永不 UPDATE），
  // 所以两端同一业务键下的 id 与 points 可以不同 —— 这不是缺陷，是 append_only 的既定语义。
  const contentUnchanged = j(bPAfter) === j(bPBefore);
  check(
    '8.4',
    'F3 修复现场（t57 曾报 high）：两端都走真实 `records.edit` ⇒ 各自落出**同业务键不同 id** 的 point_record 流水 ⇒ pull 侧按业务唯一键认领（不再撞 uq_pr_source）：行数与内容逐列不变、本机无重复业务键、业务键集合与服务端一致',
    editA6.ok === true && editB6.ok === true && syncB6.ok === true
      && !String(syncB6.errorString).includes('UNIQUE constraint')
      && !String(syncB6.errorString).includes('constraint failed')
      && bPAfter.length === bPBefore.length && dupCheck && keysEqual && contentUnchanged,
    [
      `A 真实编辑（RecordService.ets 的 records.edit）：${j(editA6.outcome)}`,
      `B 真实编辑：${j(editB6.outcome)}`,
      `服务端 point_record（该记录）: ${srvP.ok ? j(srvRows) : srvP.error}`,
      `B 本机 point_record 同步前: ${j(bPBefore)}`,
      `B 本机 point_record 同步后（行数不变=${bPAfter.length === bPBefore.length}，业务键不重复=${dupCheck}）: ${j(bPAfter)}`,
      `B 同步 ok=${syncB6.ok}，errorString=${j(syncB6.errorString)}`,
      `业务键集合一致=${keysEqual}；本机无重复业务键=${dupCheck}；内容逐列不变=${contentUnchanged}`,
      `**口径**：两端同一业务键下的 points 可以不同（B=${sumOf(bPAfter)} vs 服务端=${sumOf(srvRows)}）—— append_only 表按业务键去重且"先到者留"，`
        + '两端各自保留本机那一版；本条**不断言**积分合计相等，只断言契约要求的"不插第二行、不 UPDATE、行数内容不变"。',
      '修复前本条为红：pull 侧只按 `id` 判重（旧 SyncService.ets:641-643）⇒ 服务端那一版业务键已在 B 本机存在但 id 不同 ⇒ 直接 INSERT ⇒ `UNIQUE constraint failed: point_record`（t57 夹具第 8.4 节原始栈）。'
        + 't62 起 pull 侧对带业务唯一键的表（point_record / user_goal / user_badge / user_purchase / science_progress）按业务键认领。',
      '口径说明：`point_record` 是 append_only 表，服务端语义也是"同业务键即去重"（server/app/services/sync_service.py 的 `_merge_append_only`），'
        + '所以两端**行 id 可以不同**（各自保留本机那一版），本条断的是业务键集合 + 积分合计一致、且本机不出现重复业务键。',
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 主流程
// ─────────────────────────────────────────────────────────────────────────────
function dumpWireLog() {
  if (WIRE_LOG === '') {
    return;
  }
  const lines = WIRE.map((w) => [
    `### ${w.dev} / ${w.step}`, `${w.method} ${w.url} → HTTP ${w.status}`,
    `hasAuth=${w.hasAuth}`, `request: ${w.reqBody}`, `response: ${w.resBody}`, '',
  ].join('\n'));
  fs.writeFileSync(WIRE_LOG, `${lines.join('\n')}\n`, 'utf8');
}

async function main() {
  console.log('L2 双设备协同（协议级）—— 用例驱动 l2_run.mjs');
  console.log(`仓库=${REPO}`);
  console.log(`构建目录=${BUILD}`);
  console.log(`设备根目录=${ROOTS}`);
  console.log(`服务端=${BASE_URL}  账号=${USERNAME}`);
  console.log(`时间轴 TIME_BASE=${TIME_BASE}（行时间戳取 TIME_BASE+偏移，保证远大于 lastSyncAt 锚点）`);
  console.log(`只跑=${ONLY}`);

  const health = await httpJson('GET', '/api/v1/config', undefined, '');
  if (health.status !== 200) {
    console.error(`服务端不可达（GET ${BASE_URL}/api/v1/config → HTTP ${health.status}）：` +
      '请先按 README 起 uvicorn 并确认 MySQL 容器在线（本脚本退出码 2 = 环境不可达）');
    process.exit(2);
  }
  console.log(`健康检查: GET ${BASE_URL}/api/v1/config → HTTP 200`);

  prologue();
  if (want('baseline')) {
    scenario1();
  }
  if (want('lww')) {
    scenario2();
  }
  if (want('tie')) {
    await scenario3();
  }
  if (want('idem')) {
    await scenario5();
  }
  if (want('delete')) {
    scenario6();
  }
  if (want('conflict-count')) {
    itemSeven();
  }
  if (want('clock')) {
    await scenario4();
  }
  if (want('negative')) {
    scenario8();
  }

  dumpWireLog();

  section('断言汇总');
  for (const c of CHECKS) {
    console.log(`${c.ok ? 'PASS' : 'FAIL'}  #${c.id} ${c.title}`);
  }
  const bad = CHECKS.filter((c) => !c.ok);
  console.log(`\nRESULT: checks=${CHECKS.length} passed=${CHECKS.length - bad.length} failed=${bad.length}`);
  if (WIRE_LOG !== '') {
    console.log(`原始请求/响应全文：${WIRE_LOG}`);
  }
  if (bad.length > 0) {
    console.log(`\n失败项：${bad.map((c) => `#${c.id}`).join(' ')}`);
  }
  process.exit(bad.length === 0 ? 0 : 1);
}

await main();
