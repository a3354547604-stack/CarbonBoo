/**
 * build.mjs —— L2 双设备协同验证的**转译阶段**（不是被测实现，是执行器）。
 *
 * 职责（与 `tests/tools/l1_offline/runners/offline_run.mjs` 同一机制，不重写任何业务逻辑）：
 *   ① 把仓库真实 `.ets` 源**原样复制**到构建目录（逐文件 sha256 比对，证明是同一份字节）；
 *   ② 复用 `tests/tools/l1_offline/platform/` 的 9 个平台垫片（**原样复制**，不改一行）；
 *   ③ 用 esbuild 把复制出来的真实源转成 CJS，并把 `@kit.*` / `@ohos.*` 说明符重写到垫片；
 *   ④ 断言 esbuild 的输入集合全部落在构建目录内（= 转译产物由**复制出来的真实源**决定）；
 *   ⑤ 可选：对**构建目录里的副本**做一次变异（`--mutate=tie-flip`），用于「改真实比较规则必红」的自证。
 *      变异只作用于构建目录，仓库 `app/**` 一个字节都不动；还原走 `git show`（见 run.sh）。
 *
 * 用法：node lib/build.mjs <repo_root> <build_dir> [--mutate=tie-flip]
 * 输出：人类可读日志 + 末行 `__L2BUILD__{json}`
 */

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

const [REPO_ROOT, BUILD_DIR, ...flags] = process.argv.slice(2);
if (!REPO_ROOT || !BUILD_DIR) {
  console.error('用法：node lib/build.mjs <repo_root> <build_dir> [--mutate=tie-flip] [--skip-copy]');
  process.exit(2);
}
const skipCopy = flags.includes('--skip-copy');
const mutate = flags.find((f) => f.startsWith('--mutate='));
const mutateKind = mutate === undefined ? '' : mutate.slice('--mutate='.length);

const HERE = path.dirname(new URL(import.meta.url).pathname);
const TOOL_ROOT = path.resolve(HERE, '..');
const L1_PLATFORM = path.join(REPO_ROOT, 'tests/tools/l1_offline/platform');

/** 只转译纯逻辑层五目录（`pages/`、`components/` 是 ArkUI `struct`，esbuild 不认也不该认）。 */
const LOGIC_DIRS = ['service', 'util', 'data', 'model', 'viewmodel'];
const MAIN_ETS = path.join(REPO_ROOT, 'app/entry/src/main/ets');

/** 平台模块 → 垫片文件（与 l1_offline 逐字一致）。 */
const PLATFORM_ALIASES = {
  '@ohos/hypium': 'hypium.cjs',
  '@ohos/hamock': 'hypium.cjs',
  '@kit.AbilityKit': 'abilitykit.cjs',
  '@kit.ArkData': 'arkdata.cjs',
  '@kit.ArkTS': 'arkts.cjs',
  '@kit.CoreFileKit': 'corefilekit.cjs',
  '@kit.TestKit': 'testkit.cjs',
  '@kit.PerformanceAnalysisKit': 'logging.cjs',
  '@kit.BasicServicesKit': 'logging.cjs',
  '@kit.NetworkKit': 'networkkit.cjs',
};

function log(line) {
  process.stdout.write(`${line}\n`);
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function findEsbuild() {
  const candidates = [
    process.env.ESBUILD,
    path.join(process.env.HOME || '', 'harmony-toolchain/esbuild/bin/esbuild'),
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
  throw new Error('找不到 esbuild（设 ESBUILD=...）');
}

function walk(dir, out, ext) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full, out, ext);
    } else if (entry.isFile() && entry.name.endsWith(ext)) {
      out.push(full);
    }
  }
  return out;
}

/** ① 复制真实源（逐字节）+ ② 复制垫片。 */
function copySources() {
  const srcRoot = path.join(BUILD_DIR, 'src');
  const copied = [];
  for (const dir of LOGIC_DIRS) {
    const from = path.join(MAIN_ETS, dir);
    if (!fs.existsSync(from)) {
      throw new Error(`缺少源目录 ${from}`);
    }
    if (skipCopy && fs.existsSync(srcRoot)) {
      // 原处重转译：src/ 里的副本可能是被 git show 还原过的（见 run.sh 的变异自证段），不再从仓库覆盖
      for (const file of walk(path.join(srcRoot, 'main/ets'), [], '.ets')) {
        copied.push({ rel: path.posix.join('main/ets', path.relative(path.join(srcRoot, 'main/ets'), file).split(path.sep).join('/')) });
      }
      log('① 原样复制真实源 : 跳过（--skip-copy，沿用构建目录里的副本）');
    } else {
    for (const file of walk(from, [], '.ets')) {
      const rel = path.relative(MAIN_ETS, file);
      const to = path.join(srcRoot, 'main/ets', rel);
      fs.mkdirSync(path.dirname(to), { recursive: true });
      fs.copyFileSync(file, to);
      const same = sha256(file) === sha256(to);
      if (!same) {
        throw new Error(`复制不一致：${file}`);
      }
      copied.push({ rel: path.posix.join('main/ets', rel.split(path.sep).join('/')), sha256: sha256(file) });
    }
    }
  }
  const platform = path.join(BUILD_DIR, 'platform');
  fs.mkdirSync(platform, { recursive: true });
  const shims = [];
  for (const shim of fs.readdirSync(L1_PLATFORM)) {
    if (!shim.endsWith('.cjs')) {
      continue;
    }
    fs.copyFileSync(path.join(L1_PLATFORM, shim), path.join(platform, shim));
    if (sha256(path.join(L1_PLATFORM, shim)) !== sha256(path.join(platform, shim))) {
      throw new Error(`垫片复制不一致：${shim}`);
    }
    shims.push(shim);
  }
  return { copied, shims };
}

/** ⑤ 变异：只改构建目录里的副本。 */
function applyMutation(srcRoot) {
  const target = path.join(srcRoot, 'main/ets/viewmodel/net/SyncService.ets');
  const before = fs.readFileSync(target, 'utf8');
  let after = before;
  if (mutateKind === 'tie-flip') {
    // 真实比较规则：`remoteDevice > localDevice`（字典序大者胜）→ 反转为「小者胜」
    const from = 'if (remoteDevice > localDevice) {';
    const to = 'if (remoteDevice < localDevice) {';
    if (before.indexOf(from) < 0) {
      throw new Error(`变异锚点未命中：${from}`);
    }
    after = before.replace(from, to);
  } else if (mutateKind === 'offset-drop') {
    // 真实比较规则：`remoteUpdated = remoteRaw + offsetMs`（取反后的偏移）→ 丢掉偏移换算
    const from = 'const remoteUpdated: number = remoteRaw + offsetMs;';
    const to = 'const remoteUpdated: number = remoteRaw;';
    if (before.indexOf(from) < 0) {
      throw new Error(`变异锚点未命中：${from}`);
    }
    after = before.replace(from, to);
  } else if (mutateKind === 'offset-1000') {
    // t68 严格基准断言的负向对照：客户端**落库换算**多 1000ms（`clientOffsetMs` 用错 1 秒的形态）。
    // 严格式 `端上值 + offsetMs === 服务端值` 必须立刻不等；若用 ±3s 容差则会被吃成绿。
    const from = "out['updated_at'] = updatedAt;";
    const to = "out['updated_at'] = updatedAt + 1000;";
    if (before.indexOf(from) < 0) {
      throw new Error(`变异锚点未命中：${from}`);
    }
    after = before.replace(from, to);
  } else {
    throw new Error(`未知变异类型：${mutateKind}`);
  }
  fs.writeFileSync(target, after, 'utf8');
  const diff = spawnSync('diff', ['-u',
    path.join(REPO_ROOT, 'app/entry/src/main/ets/viewmodel/net/SyncService.ets'), target],
    { encoding: 'utf8' });
  return { kind: mutateKind, diff: diff.stdout || '' };
}

/** ③ esbuild 逐文件转译（不 bundle，保持目录层级）。 */
function transpile(esbuild, entries) {
  const outRoot = path.join(BUILD_DIR, 'out');
  fs.mkdirSync(outRoot, { recursive: true });
  const metaPath = path.join(BUILD_DIR, 'esbuild-meta.json');
  const res = spawnSync(esbuild, [
    ...entries,
    '--outbase=' + path.join(BUILD_DIR, 'src'),
    '--outdir=' + outRoot,
    '--loader:.ets=ts',
    '--format=cjs',
    '--platform=node',
    '--target=node22',
    '--sourcemap=inline',
    '--sources-content=true',
    '--metafile=' + metaPath,
    '--log-level=warning',
  ], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (res.status !== 0) {
    log('── esbuild 转译失败 ──');
    log(res.stdout || '');
    log(res.stderr || '');
    process.exit(2);
  }
  return metaPath;
}

/** 说明符重写：`@kit.*`/`@ohos.*` → 垫片；相对 import 补 `.js`。 */
function rewriteRequires(dir) {
  const platform = path.join(BUILD_DIR, 'platform');
  const files = walk(dir, [], '.js');
  for (const file of files) {
    let src = fs.readFileSync(file, 'utf8');
    src = src.replace(/require\((["'])([^"']+)\1\)/g, (whole, quote, spec) => {
      if (PLATFORM_ALIASES[spec] !== undefined) {
        return `require(${JSON.stringify(path.join(platform, PLATFORM_ALIASES[spec]))})`;
      }
      if (spec.startsWith('@kit.') || spec.startsWith('@ohos.')) {
        return `require(${JSON.stringify(path.join(platform, 'unavailable.cjs'))})`;
      }
      if (spec.startsWith('.') && !/\.(cjs|js|json|node)$/.test(spec)) {
        return `require(${JSON.stringify(`${spec}.js`)})`;
      }
      return whole;
    });
    fs.writeFileSync(file, src, 'utf8');
  }
  return files.length;
}

const esbuild = findEsbuild();
log(`-- 转译阶段（L2） --`);
log(`仓库根    : ${REPO_ROOT}`);
log(`构建目录  : ${BUILD_DIR}`);
log(`esbuild   : ${esbuild} (${spawnSync(esbuild, ['--version'], { encoding: 'utf8' }).stdout.trim()})`);

const { copied, shims } = copySources();
const copyCount = new Set(copied.map((c) => c.rel)).size;
log(`① 原样复制真实源 : ${copyCount} 个 .ets（逐文件 sha256 一致）`);
log(`② 原样复制垫片   : ${shims.length} 个（来自 tests/tools/l1_offline/platform/，未改一行）`);

let mutation = null;
if (mutateKind.length > 0) {
  mutation = applyMutation(path.join(BUILD_DIR, 'src'));
  log(`⑤ 变异已注入（仅构建目录副本）: ${mutation.kind}`);
  log(mutation.diff);
}

const srcFiles = walk(path.join(BUILD_DIR, 'src'), [], '.ets');
const metaPath = transpile(esbuild, srcFiles);
log(`③ esbuild 转译   : ${srcFiles.length} 个 .ets → CJS`);

const jsCount = rewriteRequires(path.join(BUILD_DIR, 'out'));
log(`④ 说明符重写     : ${jsCount} 个 .js 的平台说明符已指向垫片`);

// 断言：转译输入全部落在构建目录内
const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
const inputs = Object.keys(meta.inputs);
// esbuild 的 metafile 输入键相对进程 cwd（run.sh 里 cwd=仓库根）
const escaped = inputs.filter((f) => {
  const abs = path.resolve(process.cwd(), f);
  return !abs.startsWith(path.resolve(BUILD_DIR) + path.sep);
});
if (escaped.length > 0) {
  log(`FAIL: 转译输入越出构建目录：${escaped.join(', ')}`);
  process.exit(3);
}
const syncIn = inputs.find((f) => f.endsWith('viewmodel/net/SyncService.ets'));
if (syncIn === undefined) {
  log('FAIL: 转译输入里没有 SyncService.ts（被测实现未被消费）');
  process.exit(3);
}

const repoSync = path.join(REPO_ROOT, 'app/entry/src/main/ets/viewmodel/net/SyncService.ets');
const summary = {
  esbuild: spawnSync(esbuild, ['--version'], { encoding: 'utf8' }).stdout.trim(),
  sourceCount: new Set(copied.map((c) => c.rel)).size,
  inputs: inputs.length,
  syncServiceRepoPath: 'app/entry/src/main/ets/viewmodel/net/SyncService.ets',
  syncServiceRepoSha256: sha256(repoSync),
  syncServiceBuildSha256: sha256(path.join(BUILD_DIR, 'src/main/ets/viewmodel/net/SyncService.ets')),
  mutation: mutation === null ? null : { kind: mutation.kind, diff: mutation.diff },
};
log(`   转译输入 ${inputs.length} 个，全部位于构建目录内（含 ${syncIn}）`);
log(`   仓库 SyncService.ets sha256 = ${summary.syncServiceRepoSha256}`);
log(`   构建副本 sha256             = ${summary.syncServiceBuildSha256}`);
log(`__L2BUILD__${JSON.stringify(summary)}`);
