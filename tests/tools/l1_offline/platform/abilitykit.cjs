/**
 * AbilityKit 垫片 —— 只提供 `common.Context` 的最小可用形态。
 *
 * 真实 `common.Context` 是系统注入的 Ability 上下文；离线执行时它必须提供三样东西：
 *   ① 目录：`databaseDir`（relationalStore 落盘）/ `filesDir`（备份与导出）/ `cacheDir`；
 *   ② `resourceManager.getRawFileContent(path)`：读内置 rawfile（因子库、种子字典、科普正文、基准副本）；
 *   ③ 一个稳定的身份（`bundleName`），仅用于日志。
 *
 * rawfile 查找顺序：**ohosTest 的 rawfile 优先，再退 app 的 rawfile**。
 *   - 为什么两个都要：`CalcSamples.test.ets:40` 读的是 `carbon-calc.json`（只存在于
 *     `app/entry/src/ohosTest/resources/rawfile/`，是主基准的副本），而 `SeedRepository` /
 *     `FactorRepository` 读的是 `factors/…`、`goals/…`（只存在于 `app/entry/src/main/resources/rawfile/`）。
 *   - 真实的 `abilityDelegator.getAppContext()` 只解析 **app** 侧的 rawfile，因此真机上
 *     `CalcSamples` 读 `carbon-calc.json` 会 `9001005 not found`；垫片把两棵树都挂上以便把
 *     逻辑跑到，这一点已如实登记进 docs/VERIFICATION.md §R9 的缺口清单。
 *
 * 目录来源：环境变量 `L1_DATABASE_DIR` / `L1_FILES_DIR` / `L1_CACHE_DIR`（由执行器为每条用例
 * 建一个空目录，等价于「每条用例重新安装 App」）；未设置时落到 `os.tmpdir()` 下的临时目录。
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function dirOf(envName, sub) {
  const given = process.env[envName];
  const base = given && given.length > 0 ? given : path.join(os.tmpdir(), `cbl1-${process.pid}`, sub);
  fs.mkdirSync(base, { recursive: true });
  return base;
}

function rawRoots() {
  const roots = [];
  const testRoot = process.env.L1_RAW_TEST;
  const mainRoot = process.env.L1_RAW_MAIN;
  if (testRoot) {
    roots.push(testRoot);
  }
  if (mainRoot) {
    roots.push(mainRoot);
  }
  return roots;
}

class ResourceManager {
  /**
   * 读 rawfile（按 ohosTest → app 的顺序找第一个存在的文件）。
   * @param {string} rawPath 相对 `resources/rawfile/` 的路径
   * @returns {Promise<Uint8Array>}
   */
  async getRawFileContent(rawPath) {
    const roots = rawRoots();
    for (const root of roots) {
      const full = path.join(root, rawPath);
      if (fs.existsSync(full) && fs.statSync(full).isFile()) {
        return new Uint8Array(fs.readFileSync(full));
      }
    }
    // 与真机行为对齐：找不到就抛错（不让「读不到 → 空串」的静默降级污染用例）
    const err = new Error(
      `rawfile 不存在：${rawPath}（已查找 ${roots.length} 个根：${roots.join(', ') || '未设置 L1_RAW_MAIN/L1_RAW_TEST'}）`
    );
    err.code = 9001005;
    throw err;
  }

  getRawFileContentSync(rawPath) {
    const roots = rawRoots();
    for (const root of roots) {
      const full = path.join(root, rawPath);
      if (fs.existsSync(full) && fs.statSync(full).isFile()) {
        return new Uint8Array(fs.readFileSync(full));
      }
    }
    throw new Error(`rawfile 不存在：${rawPath}`);
  }

  getRawFileListSync(rawDir) {
    const out = [];
    for (const root of rawRoots()) {
      const full = path.join(root, rawDir);
      if (fs.existsSync(full) && fs.statSync(full).isDirectory()) {
        out.push(...fs.readdirSync(full));
      }
    }
    return out;
  }
}

const context = {
  bundleName: 'com.carbonboo.app',
  get databaseDir() {
    return dirOf('L1_DATABASE_DIR', 'databases');
  },
  get filesDir() {
    return dirOf('L1_FILES_DIR', 'files');
  },
  get cacheDir() {
    return dirOf('L1_CACHE_DIR', 'cache');
  },
  get tempDir() {
    return dirOf('L1_CACHE_DIR', 'temp');
  },
  get resourceManager() {
    return resourceManager;
  },
};

const resourceManager = new ResourceManager();

const common = {
  /** 类型占位：ArkTS 侧只把它当类型注解用，运行期不需要构造。 */
  Context: function Context() {},
  UIAbilityContext: function UIAbilityContext() {},
  ApplicationContext: function ApplicationContext() {},
  AbilityStageContext: function AbilityStageContext() {},
};

const AbilityConstant = {
  LaunchReason: { UNKNOWN: 0, START_ABILITY: 1 },
  LastExitReason: { UNKNOWN: 0, NORMAL: 1 },
};

module.exports = { common, AbilityConstant, context, resourceManager };
