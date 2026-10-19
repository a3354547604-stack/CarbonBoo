#!/usr/bin/env node
/**
 * 「未登录 = 纯单机」的**两段方向相反**的可执行证据（t58）。
 *
 * 同一套真实实现（`ServiceHub` 里的 RecordService / ScienceService / ShopService / BackupService /
 * PointService / SyncService / AuthService / ShopPriceFetcher / ServerConfigFetcher），换掉**只有网络口**
 * 的实现，跑两段：
 *
 *   第一段（断网）：http 端口 = `PortTrap('offline')`，一律返回 `status:0` + 一句「离线陷阱」错误；
 *                    `@kit.NetworkKit` 也被平台层陷阱包住。要求：
 *                   · 录入碳记录 / 科普列表+正文+已读进度 / 本地小铺购买 / 本地备份快照 **全部跑通**；
 *                   · 期间**零出网**（端口层与平台层命中数都为 0）；
 *                   · 五个网络例外各撞一次陷阱，且都是**优雅降级**（`ok:false` + 可读原因），不抛未捕获异常。
 *   第二段（有网）：http 端口 = `PortTrap('stub')`，只对五个例外端点预置响应。要求：
 *                   · 本机流程照样不需要网；
 *                   · 五个例外**各自真的发出请求**（打印方法 + URL + 是否带 Bearer），且响应被真正消费
 *                     （登录成功 → 拿到 token；取价成功 → 目录写入；配置下发 → 封顶生效；备份成功 → stored>0）。
 *
 * 另含两条**陷阱非空转**自证：
 *   S0.1 真实 `HttpClient` 打真端口 → 得到 `l1_offline` 垫片的原始拒绝文本（证明端口确实通向平台陷阱）；
 *   S0.2 `L1_ALLOW_NETWORK=1` 的子进程真的发起 TCP（ECONNREFUSED）→ 证明「被拦住」是陷阱干的、不是垫片坏了。
 *
 * 边界（写死在 README/REPORT 里）：这是**离线执行器**（esbuild 转译 + Node 垫片），不是真机 hypium；
 * `pages/` 与 `components/` 不进转译集，所以它证明的是 **Service 层**的本机优先，不是界面层。
 *
 * 退出码：0 = 两段全过；1 = 有断言失败；2 = 环境/转译失败。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../../..');
const L1 = path.join(REPO, 'tests/tools/l1_offline');
const L1_PLATFORM = path.join(L1, 'platform');
const OUR_PLATFORM = path.join(HERE, 'platform');
const MAIN_ETS = path.join(REPO, 'app/entry/src/main/ets');
const ART = path.join(HERE, 'artifacts');

/** 只转译**纯逻辑层**五个目录（与 `l1_offline/runners/offline_run.mjs` 同一口径：UI 目录一个文件都不进）。 */
const MAIN_LOGIC_DIRS = ['service', 'util', 'data', 'model', 'viewmodel'];

const NOW = Number(process.env.OF_NOW || '1792380000000');

// rawfile 根（`l1_offline/platform/abilitykit.cjs` 的 ResourceManager 靠这两个环境变量定位 rawfile）。
process.env.L1_RAW_MAIN = path.join(REPO, 'app/entry/src/main/resources/rawfile');
process.env.L1_RAW_TEST = path.join(REPO, 'app/entry/src/ohosTest/resources/rawfile');
const ONLY = process.env.OFFLINE_FIRST_ONLY === undefined ? 'all' : process.env.OFFLINE_FIRST_ONLY;

const results = [];
function log(line) {
  process.stdout.write(`${line}\n`);
}
function check(name, ok, detail) {
  results.push({ name, ok: ok === true });
  const tag = ok === true ? 'PASS' : 'FAIL';
  log(`${tag} ${name}${detail === undefined || detail === '' ? '' : ` —— ${detail}`}`);
}

function walk(dir, out, suffix) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full, out, suffix);
    } else if (entry.isFile() && entry.name.endsWith(suffix)) {
      out.push(full);
    }
  }
  return out;
}

function findEsbuild() {
  const candidates = [
    process.env.ESBUILD,
    path.join(os.homedir(), 'harmony-toolchain/esbuild/bin/esbuild'),
    '/usr/bin/esbuild',
  ].filter(Boolean);
  for (const c of candidates) {
    if (fs.existsSync(c)) {
      return c;
    }
  }
  const which = spawnSync('which', ['esbuild'], { encoding: 'utf8' });
  if (which.status === 0 && which.stdout.trim().length > 0) {
    return which.stdout.trim();
  }
  throw new Error('找不到 esbuild：请设 ESBUILD=/path/to/esbuild');
}

/** 平台模块 → 垫片。**唯一**与 l1_offline 不同的地方：NetworkKit 指向本工具的平台层陷阱。 */
const PLATFORM_ALIASES = {
  '@ohos/hypium': path.join(L1_PLATFORM, 'hypium.cjs'),
  '@ohos/hamock': path.join(L1_PLATFORM, 'hypium.cjs'),
  '@kit.AbilityKit': path.join(L1_PLATFORM, 'abilitykit.cjs'),
  '@kit.ArkData': path.join(L1_PLATFORM, 'arkdata.cjs'),
  '@kit.ArkTS': path.join(L1_PLATFORM, 'arkts.cjs'),
  '@kit.CoreFileKit': path.join(L1_PLATFORM, 'corefilekit.cjs'),
  '@kit.TestKit': path.join(L1_PLATFORM, 'testkit.cjs'),
  '@kit.PerformanceAnalysisKit': path.join(L1_PLATFORM, 'logging.cjs'),
  '@kit.BasicServicesKit': path.join(L1_PLATFORM, 'logging.cjs'),
  '@kit.NetworkKit': path.join(OUR_PLATFORM, 'networkkit_trap.cjs'),
};

function rewriteRequires(outRoot) {
  for (const file of walk(outRoot, [], '.js')) {
    let src = fs.readFileSync(file, 'utf8');
    src = src.replace(/require\((["'])([^"']+)\1\)/g, (whole, quote, spec) => {
      if (PLATFORM_ALIASES[spec] !== undefined) {
        return `require(${JSON.stringify(PLATFORM_ALIASES[spec])})`;
      }
      if (spec.startsWith('@kit.') || spec.startsWith('@ohos.')) {
        return `require(${JSON.stringify(path.join(L1_PLATFORM, 'unavailable.cjs'))})`;
      }
      if (spec.startsWith('.') && !/\.(cjs|js|json|node)$/.test(spec)) {
        return `require(${JSON.stringify(`${spec}.js`)})`;
      }
      return whole;
    });
    fs.writeFileSync(file, src, 'utf8');
  }
}

function transpile(outRoot) {
  const sources = [];
  for (const dir of MAIN_LOGIC_DIRS) {
    walk(path.join(MAIN_ETS, dir), sources, '.ets');
  }
  const esbuild = findEsbuild();
  const args = [
    ...sources,
    `--outbase=${path.join(REPO, 'app/entry/src')}`,
    `--outdir=${outRoot}`,
    '--loader:.ets=ts',
    '--format=cjs',
    '--platform=node',
    '--target=node22',
    '--sourcemap=inline',
    '--log-level=warning',
  ];
  const res = spawnSync(esbuild, args, { cwd: REPO, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (res.status !== 0) {
    log('── esbuild 转译失败 ──');
    log(res.stdout || '');
    log(res.stderr || '');
    process.exit(2);
  }
  log(`[ENV] 转译完成：${sources.length} 个 .ets → CJS（只含 service/util/data/model/viewmodel）`);
  rewriteRequires(outRoot);
  return sources.length;
}

/** 启动地基（与 l1_offline 同一口径）：建 19 表 → 静态种子 → 装载因子库。 */
async function bootstrapFoundation(require_, outRoot) {
  const { context } = require_(path.join(L1_PLATFORM, 'abilitykit.cjs'));
  const rdb = require_(path.join(outRoot, 'main/ets/data/dao/RdbHelper.js'));
  const seed = require_(path.join(outRoot, 'main/ets/service/SeedRepository.js'));
  const factors = require_(path.join(outRoot, 'main/ets/service/FactorRepository.js'));
  await rdb.RdbHelper.get().open(context);
  const report = await seed.SeedRepository.seedStatic(rdb.RdbHelper.get(), context);
  const lib = await factors.FactorRepository.load(context);
  log(`[ENV] 启动地基：goals=${report.goals} badges=${report.badges} shop=${report.shopItems} ` +
    `science=${report.articles} factors=${report.factorVersion === undefined ? lib.version() : report.factorVersion}`);
}

/* ────────────────────────── 网络端口陷阱 / 平台层陷阱记录 ────────────────────────── */

const NET = { port: [], platform: [], violations: [], phase: 'local' };

/**
 * `HttpPort` 的**陷阱实现**：只实现 `baseUrl()` + `request()` 两个方法（端口只有这两个）。
 * - `offline` 模式：一律 `status:0` + 「离线陷阱」错误 —— 等价于断网（`HttpClient` 也是把网络异常
 *   折成 `status:0` + error，所以调用方的降级路径完全一样）；
 * - `stub` 模式：只对五个例外端点返回预置响应，其它路径依旧拒绝（防止"其实还有别的出网"被掩盖）。
 */
class PortTrap {
  constructor(mode, stubs) {
    this.mode = mode;
    this.stubs = stubs === undefined ? {} : stubs;
  }

  baseUrl() {
    return 'http://127.0.0.1:8000';
  }

  async request(req) {
    const method = String(req.method === undefined ? 'GET' : req.method);
    const url = String(req.url === undefined ? '' : req.url);
    const rec = {
      method,
      url,
      bodyLength: String(req.body === undefined ? '' : req.body).length,
      tokenLength: req.token === undefined ? 0 : String(req.token).length,
    };
    NET.port.push(rec);
    log(`[TRAP-PORT] ${method} ${url}（body=${rec.bodyLength}B，` +
      `${rec.tokenLength > 0 ? `Bearer ${rec.tokenLength} 字符` : '无 token'}）`);
    if (this.mode === 'offline') {
      if (NET.phase === 'local') {
        NET.violations.push(rec);
      }
      return { status: 0, body: '', error: `离线陷阱（未登录 = 纯单机）：拦截 ${method} ${url}，本机流程不得出网` };
    }
    const key = `${method} ${url.split('?')[0]}`;
    const stub = this.stubs[key];
    if (stub === undefined) {
      log(`[TRAP-PORT] 未预置响应：${key}（按失败处理，防止掩盖意外出网）`);
      return { status: 0, body: '', error: `离线陷阱：未预置响应 ${key}` };
    }
    log(`[TRAP-PORT] 命中预置响应 ${key} → HTTP ${stub.status}`);
    return { status: stub.status, body: stub.body, error: '' };
  }
}

/* ────────────────────────── 取值辅助（行对象 → 数字/字符串） ────────────────────────── */

function pick(row, key) {
  if (row === undefined || row === null) {
    return undefined;
  }
  if (row[key] !== undefined) {
    return row[key];
  }
  const lower = key.toLowerCase();
  for (const k of Object.keys(row)) {
    if (k.toLowerCase() === lower) {
      return row[k];
    }
  }
  return undefined;
}

function numOf(row, key) {
  const v = pick(row, key);
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

function strOf(row, key) {
  const v = pick(row, key);
  return v === undefined || v === null ? '' : String(v);
}

/** 安全调用：异常折成 `{ok:false, code:'THREW', message}`，让「异常」表现为一条 FAIL 断言（退出码 1）。 */
async function safe(fn) {
  try {
    return await fn();
  } catch (e) {
    const msg = e === undefined || e === null ? 'unknown' : (e.message === undefined ? String(e) : e.message);
    return { ok: false, code: 'THREW', message: `抛异常：${msg}`, data: undefined };
  }
}

function hitsSince(mark) {
  return NET.port.slice(mark);
}

function findHit(from, method, path_) {
  return NET.port.slice(from).some((r) => r.method === method && r.url.indexOf(path_) >= 0);
}

/* ────────────────────────── 环境装配 ────────────────────────── */

async function freshEnv(outRoot, tag, mode, stubs) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `cbof-${tag}-`));
  process.env.L1_DATABASE_DIR = path.join(dir, 'databases');
  process.env.L1_FILES_DIR = path.join(dir, 'files');
  process.env.L1_CACHE_DIR = path.join(dir, 'cache');
  globalThis.__OFFLINE_FIRST_MODE__ = mode === 'offline' ? 'throw' : 'stub';
  globalThis.__PLATFORM_TRAP__ = NET.platform;
  const require_ = createRequire(import.meta.url);
  await bootstrapFoundation(require_, outRoot);
  const { context } = require_(path.join(L1_PLATFORM, 'abilitykit.cjs'));
  const files = require_(path.join(outRoot, 'main/ets/viewmodel/store/FilesPort.js'));
  const hubMod = require_(path.join(outRoot, 'main/ets/viewmodel/ServiceHub.js'));
  const trap = new PortTrap(mode, stubs);
  const hub = await hubMod.ServiceHub.init(context, NOW, { http: trap, files: new files.MemoryFiles() });
  log(`[ENV] ServiceHub 就绪（http=${mode} 陷阱，files=MemoryFiles）：${path.basename(dir)}`);
  return { hub, trap, require_, outRoot };
}

/* ────────────────────────── S0：陷阱非空转自证 ────────────────────────── */

async function selfProof(outRoot) {
  log('=== S0 陷阱非空转自证（平台层真的在拦，且逃生舱存在） ===');
  globalThis.__PLATFORM_TRAP__ = NET.platform;
  globalThis.__OFFLINE_FIRST_MODE__ = 'stub';
  const require_ = createRequire(import.meta.url);
  const { HttpClient } = require_(path.join(outRoot, 'main/ets/viewmodel/net/HttpPort.js'));
  const before = NET.platform.length;
  const client = new HttpClient('http://127.0.0.1:59998');
  const res = await client.request({ method: 'GET', url: 'http://127.0.0.1:59998/self-proof', body: '', timeoutMs: 2000 });
  const touched = NET.platform.length > before;
  const statusNum = Number(res.status === undefined ? NaN : res.status);
  check('S0.1 真实 HttpClient 被平台层陷阱拦住，且保留 l1_offline 的原始错误文本',
    (Number.isFinite(statusNum) ? statusNum : 0) <= 0 &&
    String(res.error).indexOf('离线执行（L1）不出网') >= 0 && touched,
    `status=${res.status} error=${res.error}`);

  const script =
    `const { http } = require(${JSON.stringify(path.join(L1_PLATFORM, 'networkkit.cjs'))});` +
    `http.createHttp().request('http://127.0.0.1:59998/hatch', {}).then(r => console.log('OK ' + r.responseCode))` +
    `.catch(e => console.log('ERR ' + e.message));`;
  const child = spawnSync(process.execPath, ['-e', script], {
    encoding: 'utf8',
    env: { ...process.env, L1_ALLOW_NETWORK: '1' },
  });
  const line = String(child.stdout).trim();
  check('S0.2 逃生舱存在：L1_ALLOW_NETWORK=1 时真的发起 TCP（ECONNREFUSED），说明「被拦」是陷阱而非垫片损坏',
    /ERR /u.test(line) && /(ECONNREFUSED|fetch failed)/iu.test(line),
    line);
}

/* ────────────────────────── 第一段：断网下本机流程跑通 ────────────────────────── */

async function segment1(outRoot) {
  log('');
  log('=== 第一段：断网陷阱下跑通本机流程（真实实现，零出网） ===');
  NET.port.length = 0;
  NET.platform.length = 0;
  NET.violations.length = 0;
  NET.phase = 'local';
  const { hub } = await freshEnv(outRoot, 'seg1', 'offline', {});
  const UID = 'of_local_user_1';
  await hub.state.ensureUser(UID, NOW);

  /* ① 录入碳记录 */
  const save = await hub.records.save(UID, { category: 'travel', subType: 'bicycle', amount: 5, occurredAt: NOW }, NOW);
  check('S1.1 录入碳记录（RecordService.save：真实计算 → 落库 → 积分 → 目标/徽章）',
    save.ok === true, `ok=${save.ok} code=${save.code === undefined ? '' : save.code} message=${save.message === undefined ? '' : save.message}`);
  const recRow = (await hub.store.query('SELECT * FROM carbon_record WHERE user_id = ?', [UID]))[0];
  const recKeys = recRow === undefined ? '(无行)' : Object.keys(recRow).join(',');
  log(`  carbon_record 行：${recKeys}`);
  check('S1.2 因子快照四字段随记录落库（铁律 3：永不回写）',
    recRow !== undefined && strOf(recRow, 'factor_value').length > 0 && strOf(recRow, 'factor_version').length > 0 &&
    strOf(recRow, 'factor_source').length > 0 && strOf(recRow, 'confidence').length > 0,
    `factor_value=${strOf(recRow, 'factor_value')} version=${strOf(recRow, 'factor_version')} ` +
    `source=${strOf(recRow, 'factor_source')} confidence=${strOf(recRow, 'confidence')}`);
  const bal1 = await hub.points.balance(UID, NOW);
  check('S1.3 记录入账后可读到余额（PointService.balance）', bal1.balance > 0, `余额=${bal1.balance}`);

  /* ①-b 目标 / 徽章：同一次 save 触发的本机结算链路，逐行落库断言 */
  const goalRows = (await hub.store.query('SELECT * FROM user_goal WHERE user_id = ?', [UID])) || [];
  const goalReached = goalRows.filter((r) => numOf(r, 'progress') > 0);
  check('S1.3a 目标进度随录入落库（user_goal 有行，且至少一条 progress > 0）',
    goalRows.length > 0 && goalReached.length > 0,
    `user_goal=${goalRows.length} 行；progress>0 ${goalReached.length} 条：` +
    goalReached.map((r) => `${strOf(r, 'goal_id')}=${numOf(r, 'progress')}`).join(','));
  const badgeRows = (await hub.store.query('SELECT * FROM user_badge WHERE user_id = ?', [UID])) || [];
  const firstBadge = badgeRows.filter((r) => strOf(r, 'badge_id') === 'B_FIRST')[0];
  check('S1.3b 徽章解锁落库（user_badge.unlocked=1 且 unlocked_at>0，铁律 4 可追溯）',
    firstBadge !== undefined && numOf(firstBadge, 'unlocked') === 1 && numOf(firstBadge, 'unlocked_at') > 0,
    `user_badge=${badgeRows.length} 行；B_FIRST=` +
    (firstBadge === undefined ? '(无)' : `unlocked=${numOf(firstBadge, 'unlocked')} unlocked_at=${numOf(firstBadge, 'unlocked_at')}`));

  /* ② 科普列表 / 正文 / 已读进度 */
  const arts = await hub.science.list();
  check('S1.4 科普列表（ScienceService.list，读 rawfile 索引）',
    Array.isArray(arts) && arts.length > 0, `${Array.isArray(arts) ? arts.length : 0} 篇`);
  const art = arts[0];
  const artId = strOf(art, 'id');
  const body = await hub.science.body(artId);
  check('S1.5 科普正文（ScienceService.body → rawfile）',
    typeof body === 'string' && body.length > 0, `id=${artId} 正文 ${body.length} 字符`);
  await hub.science.markProgress(UID, artId, NOW);
  const prog = await hub.science.progressMap(UID);
  const progHit = prog instanceof Map
    ? prog.has(artId) || Array.from(prog.keys()).some((k) => String(k) === artId)
    : JSON.stringify(prog === undefined ? null : prog).indexOf(artId) >= 0;
  const progText = prog instanceof Map
    ? `Map(${prog.size}) {${Array.from(prog.entries()).map((e) => `${e[0]}=${e[1]}`).join(', ')}}`
    : JSON.stringify(prog === undefined ? null : prog);
  check('S1.6 已读进度落库（markProgress → progressMap）', progHit, `progressMap=${progText.slice(0, 160)}`);

  /* ③ 本地小铺：真实购买（余额用真实补记路径累积，不做假账） */
  const cheap = await hub.store.query('SELECT id, name, price FROM shop_item ORDER BY price ASC LIMIT 1');
  const itemId = strOf(cheap[0], 'id');
  const price = numOf(cheap[0], 'price');
  let bal = (await hub.points.balance(UID, NOW)).balance;
  let days = 0;
  for (let d = 1; bal < price && d <= 30; d += 1) {
    // 补记落在过去的日子：每天的封顶额度互不影响（真实功能，不是造假）
    const back = await hub.records.save(UID, { category: 'travel', subType: 'bicycle', amount: 9, occurredAt: NOW - d * 86400000 }, NOW);
    if (back.ok !== true) {
      log(`  （补记 d=${d} 失败：${back.message}）`);
      break;
    }
    days = d;
    bal = (await hub.points.balance(UID, NOW)).balance;
  }
  check('S1.7 用真实补记路径把余额攒到可买（30 天补记窗口内）', bal >= price,
    `余额=${bal} 最便宜商品=${itemId}/${price} 补记 ${days} 天`);
  const buy = await safe(() => hub.shop.purchase(UID, itemId));
  check('S1.8 本地小铺购买（ShopService.purchase：user_purchase + 负向流水，全程无网）',
    buy.ok === true, `ok=${buy.ok} message=${buy.message === undefined ? '' : buy.message}`);
  const purchases = await hub.store.query('SELECT id, item_id, price_paid FROM user_purchase WHERE user_id = ?', [UID]);
  const spend = await hub.store.query("SELECT points FROM point_record WHERE user_id = ? AND type = 'purchase'", [UID]);
  check('S1.9 购买留痕可回溯（user_purchase 一行 + point_record 一条负向流水）',
    purchases.length === 1 && spend.length === 1,
    `user_purchase=${purchases.length} 条，purchase 流水=${spend.length} 条（points=${spend.length > 0 ? numOf(spend[0], 'points') : '-'}）`);

  /* ④ 云端备份「端点」的本地部分 */
  const bak = await hub.backup.create(Date.now());
  check('S1.10 本地备份快照（BackupService.create：只写本机文件，不联网）',
    bak.ok === true, `ok=${bak.ok} name=${bak.data === undefined ? '' : String(bak.data.name || '')}`);
  const stored = await hub.files.list('backup');
  check('S1.11 备份文件确实落在本机（FilesPort.list("backup")）',
    Array.isArray(stored) && stored.length > 0,
    `${Array.isArray(stored) ? stored.length : 0} 份：${(Array.isArray(stored) ? stored : []).map((f) => strOf(f, 'name')).join(' ')}`);

  /* ⑤ 本机流程零出网 */
  check('S1.12 第一段本机流程零出网（端口层陷阱零违规）', NET.violations.length === 0,
    `违规 ${NET.violations.length} 次${NET.violations.length === 0 ? '' : `：${NET.violations.map((v) => `${v.method} ${v.url}`).join(' | ')}`}`);
  check('S1.13 第一段平台层（@kit.NetworkKit）零触碰', NET.platform.length === 0,
    `平台层命中 ${NET.platform.length} 次`);

  /* ⑥ 五个网络例外：断网时必须「只降级、不崩」 */
  NET.phase = 'exception';
  const mark = NET.port.length;
  const ex1 = await safe(() => hub.auth.register('of_e2e_1', 'secret123', NOW));
  const ex2 = await safe(() => hub.sync.sync(UID, Date.now()));
  const ex3 = await safe(() => hub.shopPrices.fetchAndStore());
  const ex4 = await safe(() => hub.sync.fullUpload(UID, Date.now()));
  const ex5 = await safe(() => hub.serverConfig.fetchAndStore());
  const ex = [
    ['登录/注册', ex1, 'POST /api/v1/auth/register'],
    ['多设备同步', ex2, 'POST /api/v1/sync/push'],
    ['商品取价', ex3, 'GET /api/v1/shop/items'],
    ['云端备份', ex4, 'POST /api/v1/sync/backup'],
    ['配置下发', ex5, 'GET /api/v1/config'],
  ];
  check('S1.14 断网 + 未登录：只有免 token 的三处真的发起请求（登录/注册、商品取价、配置下发）',
    hitsSince(mark).length === 3,
    `命中 ${hitsSince(mark).length} 次：${hitsSince(mark).map((r) => `${r.method} ${r.url}`).join(' | ')}`);
  check('S1.14b 未登录时「多设备同步」「云端备份」连请求都不发（NOT_LOGGED_IN 前置守卫，铁律 1 的更严形态）',
    ex2.ok === false && ex4.ok === false && String(ex2.code) === 'NOT_LOGGED_IN' && String(ex4.code) === 'NOT_LOGGED_IN' &&
    hitsSince(mark).filter((r) => r.url.indexOf('/sync/') >= 0).length === 0,
    `sync.code=${ex2.code} fullUpload.code=${ex4.code} sync 相关请求=${hitsSince(mark).filter((r) => r.url.indexOf('/sync/') >= 0).length} 次`);
  for (const [label, res, endpoint] of ex) {
    const text = JSON.stringify(res === undefined ? null : res);
    check(`S1.15 ${label}：断网时优雅降级（ok:false + 可读原因，不含未捕获异常）`,
      res !== undefined && res.ok === false && String(res.message === undefined ? '' : res.message).length > 0,
      `${endpoint} → ok=${res === undefined ? '-' : res.ok} ` +
      `code=${res === undefined ? '-' : (res.code === undefined ? '' : res.code)} reason=${text.length > 160 ? `${text.slice(0, 160)}…` : text}`);
  }
  const stillOk = await hub.records.save(UID, { category: 'travel', subType: 'bicycle', amount: 3, occurredAt: NOW }, NOW);
  check('S1.16 例外全部失败之后，本机录入仍然可用（可用性不依赖网络）',
    stillOk.ok === true, `ok=${stillOk.ok} 余额=${(await hub.points.balance(UID, NOW)).balance}`);
}

/* ────────────────────────── 第二段：只在这五处出网 ────────────────────────── */

function segment2Stubs() {
  const json = (data) => JSON.stringify({ ok: true, data });
  return {
    'POST http://127.0.0.1:8000/api/v1/auth/register': {
      status: 200,
      body: json({ userToken: 'tok-of-e2e-1', userId: 'acc-of-e2e-1', username: 'of_e2e_1' }),
    },
    'POST http://127.0.0.1:8000/api/v1/sync/push': {
      status: 200,
      body: json({ serverTime: NOW, accepted: 0, skipped: 0, conflicts: 0, ignored: 0, rejected: 0, offsetMs: 0, rows: [] }),
    },
    'GET http://127.0.0.1:8000/api/v1/sync/pull': {
      status: 200,
      body: json({ serverTime: NOW, rows: [], offsetMs: 0 }),
    },
    'GET http://127.0.0.1:8000/api/v1/shop/items': {
      status: 200,
      body: json({
        version: 'of-e2e-1',
        items: [
          {
            id: 'frame_01', section: 'frame', name: '校样相框（预置响应）', price: 1200,
            icon: 'frame_01', order: 1, onShelf: 1, isDefaultFree: 0, description: 't58 预置响应',
          },
        ],
      }),
    },
    'POST http://127.0.0.1:8000/api/v1/sync/backup': {
      status: 200,
      body: json({ stored: 19, path: '/backup/of-e2e-1.json' }),
    },
    'GET http://127.0.0.1:8000/api/v1/config': {
      status: 200,
      body: json({ version: 'of-e2e-cfg', pointsDailyCap: 180, badgesEnabled: true, goalRewards: [], serverTime: NOW }),
    },
  };
}

async function segment2(outRoot) {
  log('');
  log('=== 第二段：五个例外各自真的出网（预置响应，其余路径仍拒绝） ===');
  NET.port.length = 0;
  NET.platform.length = 0;
  NET.violations.length = 0;
  NET.phase = 'exception';
  const { hub } = await freshEnv(outRoot, 'seg2', 'stub', segment2Stubs());
  const UID = 'of_local_user_2';
  await hub.state.ensureUser(UID, NOW);

  const local = await hub.records.save(UID, { category: 'travel', subType: 'bicycle', amount: 5, occurredAt: NOW }, NOW);
  check('S2.1 有网环境下本机录入依然不需要网（先落库，再谈例外）',
    local.ok === true && NET.port.length === 0, `ok=${local.ok} 此前出网 ${NET.port.length} 次`);

  /* ① 登录/注册 */
  let mark = NET.port.length;
  const reg = await safe(() => hub.auth.register('of_e2e_1', 'secret123', NOW));
  const regToken = reg.data === undefined ? undefined
    : (reg.data.token !== undefined ? reg.data.token : reg.data.userToken);
  check('S2.2 登录/注册发出 POST /api/v1/auth/register 并消费响应（拿到 token）',
    reg.ok === true && findHit(mark, 'POST', '/api/v1/auth/register') &&
    regToken !== undefined && String(regToken).length > 0,
    `ok=${reg.ok} outcome=${JSON.stringify(reg.data === undefined ? null : reg.data).slice(0, 120)} ` +
    `requests=${hitsSince(mark).map((r) => `${r.method} ${r.url}`).join(' | ')}`);

  /* ② 多设备同步 */
  mark = NET.port.length;
  const sync = await safe(() => hub.sync.sync(UID, Date.now()));
  check('S2.3 多设备同步发出 POST /api/v1/sync/push 并消费响应（带 Bearer）',
    sync.ok === true && findHit(mark, 'POST', '/api/v1/sync/push') &&
    hitsSince(mark).some((r) => r.tokenLength > 0),
    `ok=${sync.ok} requests=${hitsSince(mark).map((r) => `${r.method} ${r.url}(token=${r.tokenLength})`).join(' | ')}`);

  /* ③ 商品取价（免 token） */
  mark = NET.port.length;
  const price = await safe(() => hub.shopPrices.fetchAndStore());
  const cat = await hub.shop.catalog();
  check('S2.4 商品取价发出 GET /api/v1/shop/items（免 token）并整份覆盖目录',
    price.ok === true && findHit(mark, 'GET', '/api/v1/shop/items') &&
    hitsSince(mark).every((r) => r.tokenLength === 0) && cat.get('frame_01') !== undefined,
    `ok=${price.ok} catalog(frame_01)=${cat.get('frame_01') === undefined ? '无' : cat.get('frame_01').price} ` +
    `requests=${hitsSince(mark).map((r) => `${r.method} ${r.url}(token=${r.tokenLength})`).join(' | ')}`);

  /* ④ 云端备份 */
  mark = NET.port.length;
  const up = await safe(() => hub.sync.fullUpload(UID, Date.now()));
  check('S2.5 云端备份发出 POST /api/v1/sync/backup 并消费响应（stored>0，带 Bearer）',
    up.ok === true && findHit(mark, 'POST', '/api/v1/sync/backup') && numOf({ stored: up.data }, 'stored') > 0 &&
    hitsSince(mark).some((r) => r.tokenLength > 0),
    `ok=${up.ok} stored=${up.data === undefined ? '-' : up.data} requests=${hitsSince(mark).map((r) => `${r.method} ${r.url}(token=${r.tokenLength})`).join(' | ')}`);

  /* ⑤ 配置下发（免 token） */
  mark = NET.port.length;
  const cfgRes = await safe(() => hub.serverConfig.fetchAndStore());
  const cfgNow = await hub.serverConfig.constructor.effectiveFrom(hub.store);
  const capNow = 0;
  check('S2.6 配置下发发出 GET /api/v1/config（免 token）并让封顶真的生效',
    cfgRes.ok === true && findHit(mark, 'GET', '/api/v1/config') &&
    hitsSince(mark).every((r) => r.tokenLength === 0) &&
    cfgNow !== undefined && cfgNow.pointsDailyCap === 180,
    `ok=${cfgRes.ok} effective.pointsDailyCap=${cfgNow === undefined ? '-' : cfgNow.pointsDailyCap} ` +
    `badgesEnabled=${cfgNow === undefined ? '-' : cfgNow.badgesEnabled} capNow=${capNow} ` +
    `requests=${hitsSince(mark).map((r) => `${r.method} ${r.url}(token=${r.tokenLength})`).join(' | ')}`);

  /* ⑥ 第二段总共只在五处出网 */
  const all = NET.port.slice();
  check('S2.7 第二段总共只在五个例外端点出网（其余路径即便有请求也会被拒）',
    all.length <= 8 && all.every((r) => /\/api\/v1\/(auth\/register|sync\/push|sync\/pull|shop\/items|sync\/backup|config)/u.test(r.url)),
    `出网 ${all.length} 次：${all.map((r) => `${r.method} ${r.url}`).join(' | ')}`);
}

/* ────────────────────────── main ────────────────────────── */

async function main() {
  fs.mkdirSync(ART, { recursive: true });
  log(`[ENV] 仓库根：${REPO}`);
  log(`[ENV] node=${process.version} 平台=${process.platform} L1_ALLOW_NETWORK=${process.env.L1_ALLOW_NETWORK === undefined ? '（未设）' : process.env.L1_ALLOW_NETWORK}`);
  const outRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'cbof-out-'));
  const count = transpile(outRoot);

  await selfProof(outRoot);
  if (ONLY === 'all' || ONLY === '1') {
    await segment1(outRoot);
  }
  if (ONLY === 'all' || ONLY === '2') {
    await segment2(outRoot);
  }

  const pass = results.filter((r) => r.ok).length;
  const fail = results.length - pass;
  log('');
  log(`[ENV] 转译 ${count} 个文件；断言 ${results.length} 条`);
  log(`RESULT: PASS=${pass} FAIL=${fail}`);
  if (fail > 0) {
    for (const r of results.filter((x) => !x.ok)) {
      log(`  FAILED: ${r.name}`);
    }
    process.exit(1);
  }
  process.exit(0);
}

main().catch((e) => {
  log(`[ENV] 异常：${e === undefined || e === null ? 'unknown' : e.stack || e.message || String(e)}`);
  process.exit(2);
});
