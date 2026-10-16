# CarbonBoo 鸿蒙命令行构建环境 —— 实测笔记

> 由队长在 2026-10-16 亲手安装并**逐项实测验证**。所有结论都有命令与结果支撑。
> 这份笔记在仓库之外（`~/harmony-toolchain/`），避免与任务 inScope 冲突；内容本身可直接抄进仓库。

## 0. 一句话用法

每个跑鸿蒙构建的 shell，**第一件事**：

```bash
source ~/harmony-toolchain/env.sh
```

它导出 `JAVA_HOME` / `DEVECO_SDK_HOME` / `OHOS_BASE_SDK_HOME` / `PATH`（含工具链自带 node）。

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
- 或环境变量 `OHOS_BASE_SDK_HOME=<...>/sdk`（已由 `env.sh` 导出，**推荐**，团队不用往仓库塞机器相关路径）

## 5. 编译门禁是真的有效（不是摆设）

故意把 `fontSize(20)` 改成 `fontSize(NOT_DEFINED_CONST)`：
```
ArkTS:ERROR File: .../Index.ets:6:40  Cannot find name 'NOT_DEFINED_CONST'.
BUILD FAILED
```
恢复后 `BUILD SUCCESSFUL`。**所以 `assembleHap` 是一条真实的静态类型门禁**，能抓出 ArkTS 类型错误、
`any`/`as` 之类的违规要靠后续审查（编译器不一定拦）。

## 6. 目前**不能**做的事（务必如实报告，不要声称通过）

- **不能跑 hypium 测试**：`hvigorw` 只有 `assembleHap` 这类构建任务；真跑测试要
  把测试 HAP 装到**真机/模拟器**上，靠 `hdc` + `aa test` 触发。
  - 本机 `hdc list targets` => `Connect server failed`，**没有任何设备**。
  - CLT 里**没有模拟器**；Windows 侧也没装 DevEco/模拟器。
  - `/dev/kvm` 存在但当前用户**不可写**（`ls -l` 是 `crw-rw---- root kvm`），docker 挂载后可见；
    真跑模拟器这条路未打通。
- 因此 **L1「真实运行」= 未运行**。可用的替代证据（必须明确标注为「静态/离线」）：
  - `assembleHap` 编译通过（真实静态类型门禁）
  - 把纯逻辑（`CarbonService` 计算部分，不 import ArkTS 运行时 API）用 esbuild 转成 ESM 后用
    Node 跑，与 `tests/cases/carbon-calc.json` 的 18+5+6 组样例比对。
    实测可行：`npm i --no-save esbuild` → `esbuild x.ts --outfile=x.mjs --format=esm --platform=node` → `node x.mjs`。
  - 注意：系统 `/usr/bin/node` 是 v22.22.1，**编译时没带 TypeScript 支持**
    （`ERR_NO_TYPESCRIPT: Node.js is not compiled with TypeScript support`），
    `--experimental-strip-types` 用不了，所以必须走 esbuild。

## 7. 其他环境事实

- WSL Ubuntu 26.04，用户 `qinyixiang`（非 root，但**在 docker 组且 sudo 免密可用**）。
- 有 docker 27.5.1；`/tmp` 是 tmpfs 仅 3.7G —— **别把大文件放 /tmp**（CLT 3.2G 放在 `$HOME`）。
- WSL 内 Python 3.14.4 **无 pip**；`pypi.org`/清华源不可达，阿里云源可用：
  `https://mirrors.aliyun.com/pypi/simple/`。
- 推送只能走 Windows git：
  `/mnt/c/Program Files/Git/cmd/git.exe -C "C:/Users/Administrator/Desktop/CarbonBoo" push origin main`
