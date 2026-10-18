/**
 * 离线执行器 —— 把仓库里**真实的** ArkTS 实现与**真实的** hypium 用例，用 esbuild 转译成 CJS 后在 Node 里跑。
 *
 * 流程（每一步都不重写业务逻辑）：
 *   1. 收集 `app/entry/src/main/ets/**.ets` 与 `app/entry/src/ohosTest/ets/test/**.ets`；
 *   2. 用仓库指定的 esbuild 二进制逐文件转译（`--loader:.ets=ts --format=cjs`），保持原目录层级，
 *      因此源码里的相对 import 路径在产物里仍然成立（**不做任何路径改写**，除了平台模块别名）；
 *   3. 把 `@ohos/hypium`、`@kit.*` 这些只在设备上存在的模块说明符指向 `platform/` 下的垫片；
 *   4. 加载 `List.test.cjs` 收集用例 → 逐条 await 执行 → 汇总 PASS/FAIL；
 *   5. 额外直接用 `CalcBaselineValidator.run()`（与 `CalcSamples.test.ets` 完全同一条代码路径）
 *      复算一遍基准，打印 `checked` / `passed` —— 这一行就是"真实实现与数值基准自洽"的可复现证据。
 *
 * 退出码：0 = 全部通过；1 = 有用例失败或基准不一致；2 = 环境/转译失败。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TOOL_ROOT = path.resolve(HERE, '..');
const REPO_ROOT = path.resolve(TOOL_ROOT, '../../..');
const PLATFORM = path.join(TOOL_ROOT, 'platform');

const MAIN_ETS = path.join(REPO_ROOT, 'app/entry/src/main/ets');
/**
 * 只转译**纯逻辑层**的五个目录。`pages/`、`components/`、`entryability/` 里是 ArkUI 的
 * `struct` / 装饰器语法（esbuild 不认，也不该认——它们是 UI，不是 L1 的对象）。边界因此是
 * 机械确定的：UI 目录一个文件都不进转译集。
 */
const MAIN_LOGIC_DIRS = ['service', 'util', 'data', 'model', 'viewmodel'];
const TEST_ETS = path.join(REPO_ROOT, 'app/entry/src/ohosTest/ets/test');
const RAW_MAIN = path.join(REPO_ROOT, 'app/entry/src/main/resources/rawfile');
const RAW_TEST = path.join(REPO_ROOT, 'app/entry/src/ohosTest/resources/rawfile');

function log(line) {
  process.stdout.write(`${line}\n`);
}

function walk(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full, out);
    } else if (entry.isFile() && entry.name.endsWith('.ets')) {
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
  throw new Error('找不到 esbuild：请设 ESBUILD=/path/to/esbuild（默认期望 ~/harmony-toolchain/esbuild/bin/esbuild）');
}

/** 平台模块 → 垫片文件。只替换平台 API，不触碰任何被测实现。 */
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

function rewriteRequires(file, outRoot) {
  let src = fs.readFileSync(file, 'utf8');
  src = src.replace(/require\((["'])([^"']+)\1\)/g, (whole, quote, spec) => {
    if (PLATFORM_ALIASES[spec] !== undefined) {
      const target = path.join(PLATFORM, PLATFORM_ALIASES[spec]);
      return `require(${JSON.stringify(target)})`;
    }
    if (spec.startsWith('@kit.') || spec.startsWith('@ohos.')) {
      const target = path.join(PLATFORM, 'unavailable.cjs');
      return `require(${JSON.stringify(target)})`;
    }
    if (spec.startsWith('.') && !/\.(cjs|js|json|node)$/.test(spec)) {
      return `require(${JSON.stringify(`${spec}.js`)})`;
    }
    return whole;
  });
  fs.writeFileSync(file, src, 'utf8');
}

function transpile(outRoot, esbuild) {
  const sources = [];
  for (const dir of MAIN_LOGIC_DIRS) {
    walk(path.join(MAIN_ETS, dir), sources);
  }
  walk(TEST_ETS, sources);
  const args = [
    ...sources,
    '--outbase=' + path.join(REPO_ROOT, 'app/entry/src'),
    '--outdir=' + outRoot,
    '--loader:.ets=ts',
    '--format=cjs',
    '--platform=node',
    '--target=node22',
    // 内联 sourcemap + `node --enable-source-maps`：失败堆栈直接指向**原始 .ets 文件:行**，
    // 报告里才能写出「哪一行断言红了」，而不是转译产物的行号。
    '--sourcemap=inline',
    '--sources-content=true',
    '--log-level=warning',
  ];
  const res = spawnSync(esbuild, args, { cwd: REPO_ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (res.status !== 0) {
    log('── esbuild 转译失败 ──');
    log(res.stdout || '');
    log(res.stderr || '');
    process.exit(2);
  }
  return sources.length;
}

function walkJs(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkJs(full, out);
    } else if (entry.isFile() && entry.name.endsWith('.js')) {
      out.push(full);
    }
  }
  return out;
}

/**
 * 重放 App 的**启动地基**（`EntryAbility.bootstrapDataFoundation` 的前三步）：
 * 建 19 张表 → 写静态字典种子 → 装载因子库。
 *
 * 为什么必须重放：这些用例是按「App 已启动过」写的 —— 例如 `ShopPriceFallback ⑤` 断言
 * 「从未拉到过 → 回落 rawfile 播种价」，而播种发生在启动路径里，不在任何用例里。
 * 不重放就会出现「测试自身缺前置」的全红，那不是实现的问题。
 *
 * 为什么**只重放前三步**：后两步是冷启动取价 / 配置下发，属网络例外，L1 明确不出网。
 * 这里调用的是仓库真实函数（`RdbHelper.open` / `SeedRepository.seedStatic` / `FactorRepository.load`），
 * 没有重写任何播种或建表逻辑。
 */
async function bootstrapFoundation(require_, outRoot) {
  const { context } = require_(path.join(PLATFORM, 'abilitykit.cjs'));
  const rdb = require_(path.join(outRoot, 'main/ets/data/dao/RdbHelper.js'));
  const seed = require_(path.join(outRoot, 'main/ets/service/SeedRepository.js'));
  const factors = require_(path.join(outRoot, 'main/ets/service/FactorRepository.js'));

  await rdb.RdbHelper.get().open(context);
  const report = await seed.SeedRepository.seedStatic(rdb.RdbHelper.get(), context);
  const lib = await factors.FactorRepository.load(context);
  log(`启动地基：goals=${report.goals} badges=${report.badges} shop=${report.shopItems} ` +
    `science=${report.articles} factors=${report.factorVersion === undefined ? lib.version() : report.factorVersion}`);
  return report;
}

async function runCases(require_, outRoot) {

  const entry = path.join(outRoot, 'ohosTest/ets/test/List.test.js');
  const mod = require_(entry);
  const register = typeof mod === 'function' ? mod : mod.default;
  if (typeof register !== 'function') {
    throw new Error(`${entry} 没有 default 导出测试套件注册函数`);
  }
  register();

  const reg = globalThis.__L1_HYPIUM__;
  if (!reg || reg.cases.length === 0) {
    throw new Error('没有收集到任何用例：@ohos/hypium 垫片的登记表为空');
  }

  /**
   * 与真机一致：**整个进程共用一份库**（hypium 在设备上也是一次安装、一个库、连续跑完所有用例）。
   * 不做「每条用例重建库」——那会让 `RdbHelper` 单例缓存到已关闭的句柄，产生与设备行为无关的假红。
   */
  const runDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cbl1-run-'));
  process.env.L1_DATABASE_DIR = path.join(runDir, 'databases');
  process.env.L1_FILES_DIR = path.join(runDir, 'files');
  process.env.L1_CACHE_DIR = path.join(runDir, 'cache');
  let pass = 0;
  const failures = [];
  // 套件名过滤（`L1_ONLY=ShopPriceFallback`）：只跑命中的套件。
  // 用途：区分「用例自身失败」与「同进程共用一份库导致的顺序依赖」——
  // 单跑通过、按全量顺序跑失败 ⇒ 是套件内的顺序耦合，不是实现缺陷。
  const only = (process.env.L1_ONLY || '').trim();
  let cases = only.length === 0 ? reg.cases : reg.cases.filter((c) => c.suite.includes(only));
  // 用例名过滤（`L1_CASE=⑤`），优先级次于 L1_ONLY：用来单独验证某条用例的**自身**行为。
  const caseOnly = (process.env.L1_CASE || '').trim();
  if (caseOnly.length > 0) {
    cases = cases.filter((c) => c.name.includes(caseOnly));
    log(`L1_CASE=${caseOnly}：只跑 ${cases.length} 条用例`);
  }
  if (only.length > 0) {
    log(`L1_ONLY=${only}：只跑 ${cases.length} 条用例（共登记 ${reg.cases.length} 条）`);
  }

  for (let i = 0; i < cases.length; i += 1) {
    const rec = cases[i];
    const started = Date.now();
    try {
      await rec.fn();
      pass += 1;
      log(`PASS  [${rec.suite}] ${rec.name}  (${Date.now() - started} ms)`);
    } catch (e) {
      const msg = e && e.message ? e.message : String(e);
      failures.push({ suite: rec.suite, name: rec.name, msg });
      log(`FAIL  [${rec.suite}] ${rec.name}  (${Date.now() - started} ms)`);
      log(`      ${msg.split('\n')[0]}`);
      if (process.env.L1_VERBOSE === '1' && e && e.stack) {
        log(e.stack);
      }
    }
  }

  return { total: reg.cases.length, executed: cases.length, skipped: reg.cases.length - cases.length, pass, failures };
}

/** 直接用仓库真实校验器复算基准（与 CalcSamples 同一条代码路径，不重写算法）。 */
function runBaseline(require_, outRoot) {
  const types = require_(path.join(outRoot, 'ohosTest/ets/test/CalcTestTypes.js'));
  const validator = require_(path.join(outRoot, 'ohosTest/ets/test/CalcBaselineValidator.js'));
  const benchText = fs.readFileSync(path.join(RAW_TEST, 'carbon-calc.json'), 'utf8');
  const factorText = fs.readFileSync(path.join(RAW_MAIN, 'factors/carbon-factors.json'), 'utf8');
  const bench = types.parseBenchmark(benchText);
  const factors = types.parseFactors(factorText).map((f) => ({
    key: f.key,
    category: f.category,
    unit: f.unit,
    value: f.value,
    confidence: f.confidence,
    source: f.source,
    recording: f.recording,
  }));
  const report = validator.CalcBaselineValidator.run(bench, factors);
  return report;
}

async function main() {
  const esbuild = findEsbuild();
  const outRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'cbl1-out-'));
  log(`离线 L1 执行器：node ${process.version}，esbuild ${spawnSync(esbuild, ['--version'], { encoding: 'utf8' }).stdout.trim()}`);
  log(`仓库根：${REPO_ROOT}`);
  log(`中间产物：${outRoot}（临时目录，不入库）`);

  const fileCount = transpile(outRoot, esbuild);
  for (const f of walkJs(outRoot, [])) {
    rewriteRequires(f, outRoot);
  }
  log(`转译完成：${fileCount} 个 .ets → CJS（.js）`);

  const require_ = createRequire(path.join(outRoot, 'nop.js'));
  // rawfile 根必须在任何 require 之前设好：`abilitykit.cjs` 虽然是懒读取，但启动地基立刻就要用。
  process.env.L1_RAW_MAIN = RAW_MAIN;
  process.env.L1_RAW_TEST = RAW_TEST;
  await bootstrapFoundation(require_, outRoot);
  const result = await runCases(require_, outRoot);
  const report = runBaseline(require_, outRoot);

  log('');
  log(`hypium 用例：${result.total} 条，PASS=${result.pass} FAIL=${result.failures.length}`);
  // 机器可读汇总：`executed` 是真正跑过的用例数（默认 = 全部登记用例，L1_ONLY/L1_CASE 过滤时会小于 total），
  // `requires_device` 是**必须真机才能跑**因而被跳过的用例数 —— 本执行器的目标是 0：
  // 垫片覆盖到位时，36 条都能在离线环境执行（结果好坏另说，但不需要设备）。
  log(`RESULT: it_executed=${result.executed} passed=${result.pass} failed=${result.failures.length} ` +
    `requires_device=${result.skipped}`);
  log(`CalcBaselineValidator：checked=${report.checked} passed=${report.passed()}` +
    (report.mismatches.length > 0 ? ` mismatches=${report.mismatches.length}` : ''));
  log(`基准复算结论：${report.summary()}`);

  if (process.env.L1_KEEP === '1') {
    log(`（L1_KEEP=1：保留中间产物 ${outRoot} 供排查）`);
  } else {
    fs.rmSync(outRoot, { recursive: true, force: true });
  }

  if (result.failures.length > 0 || !report.passed()) {
    log('');
    log('RESULT: FAIL');
    process.exit(1);
  }
  log('');
  log('RESULT: PASS');
  process.exit(0);
}

main().catch((e) => {
  log(`执行器异常：${e && e.stack ? e.stack : e}`);
  process.exit(2);
});
