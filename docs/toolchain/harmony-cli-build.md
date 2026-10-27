# CarbonBoo 鸿蒙命令行构建环境 —— 实测笔记

> 由队长在 2026-10-16 亲手安装并**逐项实测验证**。所有结论都有命令与结果支撑。
> 这份笔记在仓库之外（`~/harmony-toolchain/`），避免与任务 inScope 冲突；内容本身可直接抄进仓库。

## 0. 一句话用法

每个跑鸿蒙构建的 shell，**第一件事**：

```bash
source ~/harmony-toolchain/env.sh
```

它导出 `JAVA_HOME` / `DEVECO_SDK_HOME` / `OHOS_BASE_SDK_HOME` / `PATH`（含工具链自带 node），以及 **`LD_LIBRARY_PATH`**（Previewer 缺库垫片，见 §7.1）。

## 1. 装了什么

| 组件 | 版本 | 位置 |
|---|---|---|
| 命令行工具 (CLT) | `5.0.3.906` | `~/harmony-toolchain/clt/command-line-tools/` |
| ohpm | `5.0.8` | `.../command-line-tools/bin/ohpm` |
| hvigor | `5.8.9` | `.../command-line-tools/hvigor/` |
| SDK | **API 12** (`5.0.0.71`) | `.../command-line-tools/sdk/default/openharmony/` |
| OpenJDK | `21` (21+35-2513) | `~/harmony-toolchain/jdk-21/` |
| 工具链自带 Node | `v18.20.1` | `.../command-line-tools/tool/node/` |

CLT 校验和：`c6fe61299e1b05e4023e643a319ee74c3eb369af7edecd5c3f1795b16f9db6af`（sha256sum -c 通过）。

## 2. 六个坑，全部已解决（照做即可）

### 坑 1：压缩包解出来没有执行位
```bash
cd ~/harmony-toolchain/clt/command-line-tools
find . -path "*/bin/*" -type f -exec chmod +x {} \;
chmod +x ohpm/bin/* hvigor/bin/* 2>/dev/null
chmod -R +x tool/node/bin
chmod +x sdk/12/toolchains/*          # 否则 syscap_tool 跑不起来
```

### 坑 2：工具链自带 npm 是坏的 shim
原始 `tool/node/bin/npm` 只有 38 字节，内容是 `../lib/node_modules/npm/bin/npm-cli.js`（缺 shebang），
跑起来报 `npm-cli.js: not found`。**hvigor 首次运行会用它装 pnpm，必然失败**。已修：

```bash
TC=~/harmony-toolchain/clt/command-line-tools/tool/node
printf '#!/bin/sh\nexec "$(dirname "$0")/node" "$(dirname "$0")/../lib/node_modules/npm/bin/npm-cli.js" "$@"\n' > $TC/bin/npm
printf '#!/bin/sh\nexec "$(dirname "$0")/node" "$(dirname "$0")/../lib/node_modules/npm/bin/npx-cli.js" "$@"\n' > $TC/bin/npx
chmod +x $TC/bin/npm $TC/bin/npx
```

### 坑 3：SDK 目录布局与 hvigor 期望不符（**这是最阴的一个**）
CLT 解出来是**扁平布局** `sdk/default/openharmony/{ets,js,native,previewer,toolchains}`，
但 hvigor 的 `OhLocalComponentLoader` 期望**按 API 版本分层**：`sdk/<apiVersion>/<component>`。
不修就报 `The SDK management mode has changed.`，还会建议你去删 SDK —— **别删**。

实测报错原文（debug 日志）：
```
Component ArkTS:5.0.0.71 has been placed in the wrong place,
expect .../sdk/12/ets, actual .../sdk/default/openharmony/ets
```

解法（**幂等，可重复执行**）：
```bash
cd $DEVECO_SDK_HOME          # = .../command-line-tools/sdk
mkdir -p 12
for c in ets js native previewer toolchains; do
  ln -sfn "$DEVECO_SDK_HOME/default/openharmony/$c" "$DEVECO_SDK_HOME/12/$c"
done
```

### 坑 4：`hvigor-config.json5` 的位置与依赖来源
必须在 **`<项目>/hvigor/hvigor-config.json5`**（不是项目根）。根目录放一个同名的不会生效，报
`Error: Hvigor config file .../hvigor/hvigor-config.json5 does not exist.`

而且依赖**要指向本地 CLT**，否则会去 npm 拉插件（本机 npm 源慢且易失败）：
```json5
{
  "modelVersion": "5.0.0",
  "dependencies": {
    "@ohos/hvigor-ohos-plugin": "file:/home/qinyixiang/harmony-toolchain/clt/command-line-tools/hvigor/hvigor-ohos-plugin",
    "@ohos/hvigor": "file:/home/qinyixiang/harmony-toolchain/clt/command-line-tools/hvigor/hvigor"
  },
  "execution": {},
  "logging": { "level": "info" },
  "debugging": { "stacktrace": false },
  "nodeOptions": { "maxOldSpaceSize": 8192 }
}
```

**⚠️ 换机器必改：上面两行的 `file:` 路径里含本机用户名**（t70 补）

`app/hvigor/hvigor-config.json5:14-15` 是**整个仓库里唯一「会被构建直接读取、且写死了本机家目录」的绝对路径**
——`git grep -n '/home/qinyixiang' -- .` 的其余命中全在 `docs/VERIFICATION.md`、`tests/tools/l2_sync/REPORT.md`
与**本文档上面这段示例**里，那些是留档文字（改了不影响运行，也别改）。
换机器 / 换用户名 / 把 `harmony-toolchain` 装到别处时，**一条命令改完**：

```bash
sed -i "s#/home/qinyixiang#$HOME#g" app/hvigor/hvigor-config.json5
```

- 前提：工具链装在 `$HOME/harmony-toolchain`（`env.sh` 的默认位置）。装在别处就手改这两行，
  改完用 `grep -n 'file:' app/hvigor/hvigor-config.json5` 对一眼——两行都必须指向**存在的**目录。
- **不改的后果（三段对照实测，2026-10-19）**：① 基线 `BUILD SUCCESSFUL in 28 s 5 ms` / `EXIT=0`；
  ② 把前缀换成不存在的 `/tmp/cb_no_such_user` ⇒ **`BUILD FAILED` / `EXIT=255`**，原文
  `Error: ENOENT: no such file .../node_modules/@ohos/hvigor/bin/hvigor.js,delete ... and retry.`
  （证明这两行真的被读）；③ 用上面那条 `sed` 换回 `$HOME` ⇒ 恢复 `BUILD SUCCESSFUL in 4 s 637 ms` / `EXIT=0`，
  且 `git diff --stat app/hvigor/hvigor-config.json5` 为空（与仓库里的 `$HOME` 版**逐字节相同**）。
- 这是**唯一**一处「照文档复现仍会在构建门禁失败」的机器锁定项（`docs/VERIFICATION.md §R15.8-F2`）。

#### 坑 4-W：Windows + DevEco Studio 形态（不适用上面那条 `sed`）

上面那条 `sed` 的前提是「工具链装在 `$HOME/harmony-toolchain`」。Windows 上装的是 **DevEco Studio 自带的
hvigor**，路径与 `$HOME` 没有任何前缀关系，`sed` 换不出来。这两行改成：

```json5
"@ohos/hvigor-ohos-plugin": "file:C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor-ohos-plugin",
"@ohos/hvigor":             "file:C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor"
```

三个踩过的写法（每个报不同的错）：

| 写法 | 结果 |
|---|---|
| `file:/home/qinyixiang/...`（Linux 版原样） | pnpm 解成 `C:/home/qinyixiang/...` → 装成 `0.0.0` 桩包 → `ENOENT .../@ohos/hvigor/bin/hvigor.js` |
| `file:/c/Program Files/...`（MSYS 风格） | pnpm 解成 `C:/c/Program Files/...` → 同上 |
| **`file:C:/Program Files/...`**（盘符直接跟冒号） | ✅ 可用 |

Windows 独有的两条前置条件：
- **用户目录必须有 `~/.npmrc`**，否则 hvigor 报 `ERROR: 00303137 Configuration Error ... No npmrc file is matched in the current user folder`。最小内容：`registry=https://registry.npmjs.org/`。
- **`app/local.properties` 必须写 `sdk.dir`**，否则报 `00303208 ... Unable to find 'sdk.dir' in 'local.properties' or 'OHOS_BASE_SDK_HOME'`。该文件已在 `.gitignore:39` 忽略，**不入库**。

**⚠️ 这个文件在 Windows 上「只许本地改，永不许提交」**

原因：`@ohos/hvigor` / `@ohos/hvigor-ohos-plugin`（6.26.8）在 `registry.npmjs.org`、`registry.npmmirror.com`、
`repo.huaweicloud.com/repository/npm/` 全是 **404**，`repo.harmonyos.com/npm/` 是 **401**（需华为账号）；
hvigor 的 json5 既不支持环境变量展开、也不接受相对路径。所以**只能写本机绝对路径**，
不存在一份能让两台机器同时可用的内容。vendor 进仓库也不可行：`hvigor` 79.7 MB +
`hvigor-ohos-plugin` 145.8 MB = **225 MB / 1.7 万文件**。

因此约定（**Windows 侧一次设置**）：

```powershell
git update-index --skip-worktree app/hvigor/hvigor-config.json5
```

- 仓库里**保留队友的 `/home/qinyixiang` 版**，他的 `sed` 规则继续有效，对 Linux 侧零影响。
- 设好之后该文件的本地改动**不会被 `git add -A` 带走**，杜绝误提交把队友构建打挂。
- 查询 / 撤销：`git ls-files -v app/hvigor/hvigor-config.json5`（首列 `S` = 已设置）；
  `git update-index --no-skip-worktree app/hvigor/hvigor-config.json5`。
- **代价（必须知道）**：队友若改了这个文件并推上来，你 `pull` 时 git 会**跳过它**而不是合并。
  所以每次 `pull` 后若发现 hvigor 版本变了（看 `tools/hvigor/hvigor/package.json` 的 `version`），
  先 `--no-skip-worktree` → `git checkout -- app/hvigor/hvigor-config.json5` →
  重跑 `scripts/set-hvigor-local.ps1`（见该脚本头注释）。

### 坑 5：`build-profile.json5` 三个坑
```json5
{
  "app": {
    "signingConfigs": [],
    "products": [
      { "name": "default",
        // ① 必须是 integer，不能写 "5.0.0(12)"
        "compatibleSdkVersion": 12,
        // ② 必须显式给，否则报 Please configure compileSdkVersion in the product
        "compileSdkVersion": 12,
        "targetSdkVersion": 12,
        "runtimeOS": "OpenHarmony"
        // ③ 不要写 signingConfig —— signingConfigs 为空时引用它会报
        //    "Cannot read properties of undefined (reading 'app')"
      }
    ],
    "buildModeSet": [ { "name": "debug" }, { "name": "release" } ]
  },
  "modules": [
    { "name": "entry", "srcPath": "./entry",
      "targets": [ { "name": "default", "applyToProducts": ["default"] } ] }
  ]
}
```

### 坑 6：**必须有 `AppScope/app.json5`**
没有它就报 `Cannot read properties of undefined (reading 'app')`，栈在
`integrated-hsp-utils.js → initIntegratedHspCache`（读 `getAppRes().getAppResOpt()`）。
这个错误信息完全没提 AppScope，极难猜。必须有：
```
AppScope/app.json5                      # bundleName / versionCode / versionName / icon / label
AppScope/resources/base/element/string.json   # app_name
AppScope/resources/base/media/app_icon.png
```

## 3. hypium 版本上限：**≤ 1.0.21**（实测）

| hypium | 结果 |
|---|---|
| `1.0.19` | ✅ BUILD SUCCESSFUL |
| `1.0.21` | ✅ BUILD SUCCESSFUL |
| `1.0.24` | ❌ `The compatibleSdkVersion 12 cannot be smaller than version 17 declared in library [:hypium]` |
| `1.0.27` | ❌ 同上 |
| `1.0.29`（ohpm 默认最新） | ❌ 同上 |

**结论：`@ohos/hypium: 1.0.21` 是 API 12 下的最高可用版本。** 用 `ohpm install` 装：
```bash
source ~/harmony-toolchain/env.sh
ohpm install @ohos/hypium@1.0.21      # 会写进 oh-package.json5 与 oh_modules/
```

## 4. 实测通过的命令

```bash
source ~/harmony-toolchain/env.sh

# 主 HAP
hvigorw --no-daemon assembleHap
#   => BUILD SUCCESSFUL；产物 entry/build/default/outputs/default/entry-default-unsigned.hap

# 测试 HAP
hvigorw --no-daemon --mode module -p module=entry@ohosTest -p buildMode=test assembleHap
#   => BUILD SUCCESSFUL；产物 entry/build/default/outputs/ohosTest/entry-ohosTest-unsigned.hap
```

SDK 路径两种方式都实测可用：
- 项目根写 `local.properties` → `sdk.dir=<...>/sdk`
- 或环境变量 `OHOS_BASE_SDK_HOME=<...>/sdk`（已由 `env.sh` 导出，**推荐**，团队不用往仓库塞机器相关路径）——**唯一例外**是 `app/hvigor/hvigor-config.json5:14-15` 的两行 `file:` 依赖路径，它必须写本机 `$HOME`（换机器必改，见 §坑 4）

## 5. 编译门禁是真的有效（不是摆设）

故意把 `fontSize(20)` 改成 `fontSize(NOT_DEFINED_CONST)`：
```
ArkTS:ERROR File: .../Index.ets:6:40  Cannot find name 'NOT_DEFINED_CONST'.
BUILD FAILED
```
恢复后 `BUILD SUCCESSFUL`。**所以 `assembleHap` 是一条真实的静态类型门禁**，能抓出 ArkTS 类型错误、
`any`/`as` 之类的违规要靠后续审查（编译器不一定拦）。

> ⚠️ **门禁只覆盖「进入编译图」的文件**（2026-10-16 实测补充，血的教训）。
> `assembleHap` 从 entry 的入口页（`pages/Index.ets`）与 `EntryAbility` 出发做可达性分析，
> **没被任何入口 import 的模块根本不参与编译**。实测：
> - `pages/Index.ets` 是占位页、不 import 业务代码时：给 `service/CarbonService.ets`
>   注入 `const X: number = THIS_IS_UNDEFINED_ABC;` → 仍 **BUILD SUCCESSFUL**（没编译它）；
>   同样的错误注入 `pages/Index.ets` → **BUILD FAILED**。
> - 后果：整个 `service/`、`data/` 写错了编译器也一声不吭，「BUILD SUCCESSFUL」是**假绿**。
> - 实测抓到的真错误：`data/dao/CarbonRecordDao.ets` 用了 API 12 不存在的
>   `rs.getColumnNames()`（应为 `rs.getColumnName(0)`），报
>   `Property 'getColumnNames' does not exist on type 'ResultSet'. Did you mean 'getColumnName'?`
>   —— 在未入图状态下这句话永远不会出现。
> - **做法**：让入口页/Ability 真实 import 并引用主要业务模块后再编译；用「注入未定义常量 →
>   必须 BUILD FAILED」自证该链路有效。**未入图的 BUILD SUCCESSFUL 不算通过。**

## 6. 目前**不能**做的事（务必如实报告，不要声称通过）

- **不能跑 hypium 测试**。注意 `hvigorw` **确实有** `test` 任务，但它不是设备测试：
  - `hvigorw test --mode module -p module=entry@default -p buildMode=test` 是 **localTest**，
    被测代码必须放 `entry/src/test/`（不是 `entry/src/ohosTest/`）并默认导出 `function testsuite()`。
    任务链到 `UnitTestArkTS` 完成后，由 `hvigor-ohos-plugin/src/tasks/unitTest/generate-unit-test-result.js`
    → `@ohos/coverage/lib/src/commandLine/localTest/previewer.js` 的 `executeCoverageTest()`
    **spawn SDK 里的 `Previewer` 二进制**（参数含 `-j <abcDir>`、`-f phoneSettingConfig_*.json`、
    `-url ../../../.test/testability/pages/Index`、`-lws <port>`），**不用 hdc、不用真机**。
  - 本机这条路走不通：Previewer 启动后崩在 **glibc 断言**
    （`Fatal glibc error: pthread_mutex_lock.c:426: __pthread_mutex_lock_full: Assertion 'e != ESRCH || !robust' failed`），
    `hvigorw test` 表现为长时间无输出直至超时（EXIT=124）。
  - 走真机/模拟器也不行：`hdc list targets` => `Connect server failed`，**没有任何设备**；
    CLT 里**没有模拟器**；Windows 侧也没装 DevEco/模拟器；`/dev/kvm` 存在但当前用户**不可写**
    （`ls -l` 是 `crw-rw---- root kvm`），docker 挂载后可见，真跑模拟器这条路未打通。
- 因此 **L1「真实运行」= 未运行**。可用的替代证据（必须明确标注为「静态/离线」）：
  - `assembleHap` 编译通过（真实静态类型门禁，但**仅限已入图的文件**，见 §5 的警告）
  - 把纯逻辑（`CarbonService` 计算部分，不 import ArkTS 运行时 API）用 esbuild 转成 ESM 后用
    Node 跑，与 `tests/cases/carbon-calc.json` 的 18+5+6 组样例比对。
    实测可行：`esbuild x.ets --loader:.ets=ts --outfile=x.mjs --format=esm --platform=node` → `node x.mjs`。
  - 注意：系统 `/usr/bin/node` 是 v22.22.1，**编译时没带 TypeScript 支持**
    （`ERR_NO_TYPESCRIPT: Node.js is not compiled with TypeScript support`），
    `--experimental-strip-types` 用不了，所以必须走 esbuild。
  - **坑：`npm i esbuild` 会 404**。`~/.npmrc` 被 hvigor 引导 pnpm 时写成了华为源
    （`registry=https://repo.harmonyos.com/npm/`），该源没有 esbuild。已装好的副本在
    `~/harmony-toolchain/esbuild/bin/esbuild`（**持久位置，后续任务直接复用**；
    若丢失用 `npm i --registry=https://registry.npmjs.org/ esbuild` 重装）。
  - 转出来的 `.mjs` 里 `import "../util/DecimalUtil"` 这类**无后缀相对路径** Node 解析不了，
    需改写成本地 `./DecimalUtil.mjs`（`~/cb-verify/run.sh` 已内置这一步）。
  - **坑：`npm i esbuild` 会 404**。`~/.npmrc` 被 hvigor 引导 pnpm 时写成了华为源
    （`registry=https://repo.harmonyos.com/npm/`），该源没有 esbuild。已装好的副本在
    `~/harmony-toolchain/esbuild/bin/esbuild`（**持久位置，后续任务直接复用**；
    若丢失用 `npm i --registry=https://registry.npmjs.org/ esbuild` 重装）。
  - 转出来的 `.mjs` 里 `import "../util/DecimalUtil"` 这类**无后缀相对路径** Node 解析不了，
    需改写成本地 `./DecimalUtil.mjs`（`~/cb-verify/run.sh` 已内置这一步）。

### 6.1 现成的离线一致性检查（直接用，别重造）

```bash
sh ~/cb-verify/run.sh      # 退出码 0 = 全部一致
```

它做的事：用 `~/harmony-toolchain/esbuild/bin/esbuild` 把 app 侧的
`util/DecimalUtil.ets`、`util/AppConstants.ets`、`service/CarbonCalc.ets`、`service/CarbonService.ets`
转成 ESM 到 `~/cb-verify/build/`，补全 import 后缀，再由 `~/cb-verify/verify.mjs` 读
`tests/cases/carbon-calc.json` 逐条比对（18 正向 / 5 封顶 / 边界 21-23 / 8 组定点抽查）。

**实测输出**：`样本: 18 正向 / 5 封顶 / 6 边界 / 31 因子` → `PASS=34  FAIL=0`。

⚠️ 这是**一致性回归**（脚本 import 的是被测代码 `CarbonCalc`），**不是独立复算**。
真正的独立复算（不调用被测代码）由 t7 用 Python `Decimal` + `ROUND_HALF_UP` 另做。

## 7. 其他环境事实

- WSL Ubuntu 26.04，用户 `qinyixiang`（非 root，但**在 docker 组且 sudo 免密可用**）。
- 有 docker 27.5.1；`/tmp` 是 tmpfs 仅 3.7G —— **别把大文件放 /tmp**（CLT 3.2G 放在 `$HOME`）。
- WSL 内 Python 3.14.4 **无 pip**；`pypi.org`/清华源不可达，阿里云源可用：
  `https://mirrors.aliyun.com/pypi/simple/`。
- 推送只能走 Windows git：
  `/mnt/c/Program Files/Git/cmd/git.exe -C "C:/Users/Administrator/Desktop/CarbonBoo" push origin main`

### 7.1 Previewer 缺库垫片（`env.sh` 里的 `LD_LIBRARY_PATH`）

CLT 里的 `Previewer` 直接运行会缺四个共享库：`libshared_libz.so`、`libhilog.so`、
`libbrotli_shared.so`、`libc_ares.so`。已建垫片目录 `~/harmony-toolchain/previewer-libs/`（4 个软链）：

| 垫片 | 指向 |
|---|---|
| `libshared_libz.so` | `$CLT/sdk/12/ets/build-tools/ets-loader/bin/ark/build/bin/libshared_libz.so` |
| `libhilog.so` | `$CLT/sdk/12/previewer/common/bin/libhilog_linux.so` |
| `libbrotli_shared.so` | `/usr/lib/x86_64-linux-gnu/libbrotlidec.so.1`（**必须用 dec**，用 common 会报 `undefined symbol: BrotliDecoderCreateInstance`） |
| `libc_ares.so` | `/usr/lib/x86_64-linux-gnu/libcares.so.2` |

`env.sh` 会把它拼进 `LD_LIBRARY_PATH`，此后 `ldd -r Previewer` 未解析符号为 0、缺库为 0。
**但这只解决加载问题**——Previewer 起来之后仍会崩在 glibc 断言（见 §6），
所以 **localTest 在本机依然不可用**，垫片不是「L1 能跑了」的证据。

### 7.2 Windows 侧：用 DevEco 预览器批量截图（已跑通）+ 它的硬限制

**能做什么**：在 DevEco Studio 里打开工程 → `Ctrl+Shift+A` 搜 `preview` → 打开**预览器**工具窗口
（目标文件必须是 `app/entry/src/main/ets/pages/Index.ets`，全工程唯一的 `@Entry`）→ 双击标签页最大化，
即可渲染真实页面。之后用仓库里的脚本抓图，无需手动截屏：

```powershell
# 查询窗口与页面矩形
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\preview-run.ps1 -Action info
# 抓一张
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\preview-run.ps1 -Action capture -OutFile docs\screenshots\01-home.png
# 点页面内某点（坐标就是 PNG 上的像素坐标），可顺带再抓一张
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\preview-run.ps1 -Action click -PageX 148 -PageY 610 -OutFile docs\screenshots\03-records.png
```

`preview-run.ps1` 的关键做法（照抄即可）：**必须声明 DPI 感知**
（`SetProcessDpiAwarenessContext(-4)` → 回退 `SetProcessDpiAwareness(2)` → 回退 `SetProcessDPIAware()`），
否则在 125% 缩放下 `CopyFromScreen` 只能拿到逻辑分辨率的放大模糊图；裁页面不用固定坐标，而是按
**行/列亮像素剖面**求包围盒（顶栏、状态栏本身有大量亮像素，直接求全局包围盒一定退化）；
预览器把鼠标事件当触摸事件（日志可见 `MousePress → TouchPress`），所以 `mouse_event` 点击有效。

**硬限制（务必知道，别浪费时间）**：**预览器里的 `RdbStore` 是 mock 实现**。日志原文：

```
W A0c0d0/JSAPP: The RdbStore.executeSql interface in the Previewer is a mocked implementation and may behave dif...
W A0c0d0/JSAPP: The RdbStore.querySql interface in the Previewer is a mocked implementation and may behave diffe...
```

后果：`EntryAbility.bootstrapDataFoundation()` 里 `schema ok / seeds: goals=… badges=… science=…` 这行日志
**永远不出现**，`goal_def` / `badge_def` / `shop_item` / `science_article` 全是空表。于是**所有依赖数据库的
页面都只能看到空态**：

- 目标页「这个分组还没有目标」、科普页「没有匹配的文章」、看板「本周期还没有记录」、首页「累计减排 0.0000 kg」；
- **`15-record-detail` 与 `17-science-detail` 两张截图因此无法产出**：前者要先有记录，后者要先有文章列表可点，
  而 `ScienceDetailPage.reload()` 第一步就是 `hub.science.metaOf(id)`（查库），拿不到 meta 就不会渲染正文。

**要拿到带数据的截图，只有三条路**：① 真机（`signingConfigs` 为空，需先在 DevEco 里生成调试签名）；
② 模拟器（需 `bcdedit /set hypervisorlaunchtype auto` + **重启**，本机当前 `HypervisorPresent=False`、无镜像）；
③ 写临时代码把页面根内容换成假数据（**会污染源码，不推荐**，且截出来的不是真实运行结果）。
