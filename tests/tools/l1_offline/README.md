# tests/tools/l1_offline · L1 纯逻辑的「离线执行真实实现」执行器

> 一句话：**把仓库里那一份真实的 ArkTS 实现（不是复制品、不是重写）用 esbuild 转译成 CJS，在 Node 里对着
> `tests/cases/carbon-calc.json` 基准跑一遍**，让「仓库实现 vs 数值唯一真相源」这件事在本机没有真机 /
> 没有模拟器 / Previewer 与 glibc 2.43 不兼容的条件下，仍然**有可复现的可执行证据**。

---

## 1. 一条命令

```bash
bash tests/tools/l1_offline/run.sh          # 退出码 0 = 两部分全 PASS；非 0 = 任一 FAIL
```

产物写在 `mktemp -d` 出来的临时目录里，**退出即删**，仓库里不留任何 `.cjs` / `.ts`。
要留证据核对：`L1_OFFLINE_KEEP=1 bash tests/tools/l1_offline/run.sh`（会打印保留的目录）。

依赖只有两样（都可覆盖）：`~/harmony-toolchain/esbuild/bin/esbuild`（或 PATH 上的 `esbuild`，用 `ESBUILD=` 指定）、
`~/harmony-toolchain/clt/command-line-tools/tool/node/bin/node`（或 PATH 上的 `node`，用 `NODE=` 指定）。
**没有任何 npm 依赖，不会生成 `node_modules`**（`AGENTS.md` §7.1 禁止第三方包）。

## 2. 本次实测输出（原样摘录，2026-11-07）

```
-- ③ esbuild 转译成 CJS（--bundle，入口就是仓库源文件转出来的副本） --
   out/carboncalc.cjs out/validator.cjs out/types.cjs

-- ④ bundle 输入文件断言（esbuild metafile：吃进去的就是上面那 9 个仓库源） --
   实际输入(8): main/ets/service/CarbonCalc.ts, main/ets/service/CarbonService.ts, main/ets/util/AppConstants.ts,
               main/ets/util/DecimalUtil.ts, main/ets/util/JsonUtil.ts, main/ets/util/StringUtil.ts,
               test/CalcBaselineValidator.ts, test/CalcTestTypes.ts
   ok: 8/8 运行期输入 + 1 个纯类型文件（合计 9/9）全部来自仓库真实源文件
   ok: tests/tools/ 里没有一行算法 —— 转译产物完全由 app/ 下那 9 份 .ets 决定

-- ⑤ 用真实实现复算基准 --
samples(18×2)        PASS=36 FAIL=0
capSamples(5×2+1)    PASS=11 FAIL=0
conversions(2)       PASS=2 FAIL=0
boundary 20/21/22(6) PASS=6 FAIL=0

RESULT: PASS=55 FAIL=0

checked = 323
passed  = true
summary = 全部一致：共复算 323 个断言点
RESULT: checked=323 passed=true mismatches=0

RUN.SH: 全部 PASS（离线纯逻辑部分）
```

两段结论分别来自两份**仓库里的真实实现**：

| 段 | 入口源文件 | 产出 |
|---|---|---|
| `PASS=55 FAIL=0` | `app/entry/src/main/ets/service/CarbonCalc.ets`（及其依赖 `util/DecimalUtil`、`util/AppConstants`、`model/CarbonTypes`） | `runners/calc_samples.mjs` 逐样例断言：18 组正向 ×(减排量, C) + 5 组封顶 ×(实入 A, capped) + 1 项「阈值以下不生成流水」+ 2 组换算 + 边界 20/21/22 共 6 项 |
| `checked=323 passed=true` | `app/entry/src/ohosTest/ets/test/CalcBaselineValidator.ets` + `CalcTestTypes.ets`（及其依赖 `service/CarbonService`、`JsonUtil`、`StringUtil` 等） | 由仓库自己那份校验器（连同它内置的独立参考实现交叉验证）逐条复算基准并给出 `checked / passed() / summary()` |

## 3. 为什么这不算「又一次离线复算」

差别只有一条，但它是全部价值：**转译，不是重写**。

```
① 原样复制：cp app/entry/src/main/ets/... → 临时目录（然后 cmp 逐字节校验，不一致直接 exit 3）
② 唯一改写：ohosTest 侧两个文件的相对 import 前缀 '../../../main/ets/' → '../main/ets/'
   （目录结构变了，import 前缀必须跟着变），改完再 diff 断言「每一行差异都只涉及这个前缀」，
   出现任何与 import 前缀无关的差异立即 exit 3
③ esbuild --bundle --platform=node --format=cjs --metafile 出 CJS 与输入清单
④ Node 断言 metafile 的 inputs 集合 == 期望的仓库源集合（且全部落在临时目录内）
```

于是：`CarbonCalc.ets` 里少了一行定点舍入、`DecimalUtil.ets` 里 half-up 改成 banker's rounding、
`AppConstants.ets` 里封顶从 200 改成 300 —— 都会**立刻**在这里变成 FAIL，而不是等真机。
反过来，谁也没有在 `tests/tools/` 里写过一行业务算法；这里的 `.mjs` 只做「读文件 / 喂输入 / 打印结论」。

被消费的 9 份源文件在输出里逐一打印 `sha256`，便于把某次结论钉到某个具体版本上（改了源文件，哈希就会变）。

## 4. 边界（**必须连这条一起读**）

**它不是 hypium 的替代品。**

- **不覆盖**：UI（ArkUI 组件树 / 布局 / 交互）、数据库（`relationalStore` 19 张表与事务）、网络（HTTP 客户端与
  超时降级）、生命周期（`UIAbility` / 页面栈 / 冷启动）、权限与端侧能力（相册保存、识图 stub、分布式近场）。
  这些只能靠 `ohosTest` + hypium 在真机/模拟器上跑。
- **只覆盖**：不 import 任何 ArkTS 运行时 API 的纯逻辑模块（计算、定点舍入、封顶、换算、基准与因子表的交叉校验），
  且证明的是「**这些模块的真实实现与基准一致**」，不是「App 行为正确」。
- **hypium 的 36 个 `it()` 仍然未运行。** 本工具跑完**不改变**这一事实：`tests/README.md` §5 里 L1 的
  执行状态仍然是「未真正跑过 hypium」，两条证据**不可互相顶替**、必须分开陈述。
  （`CalcBaselineValidator` 确实被 hypium 的 `CalcSamples.test.ets` 调用，本工具让**同一个校验器**在离线环境
  被真实执行——这是它唯一能替代的部分，也仅限这一部分。）

## 5. 为什么 `capSamples` 里 `countsTowardCap === false` 的样例要**跳过**封顶计算

因为那一类不是「记录类积分」，不受日封顶约束，也不计入今日已得 D。

`capSamples` 5 组里有 1 组是这个形状：

```json
{ "id": "cap-4", "desc": "D=200，完成目标 S1（+20）",
  "todayEarnedD": "200", "expectedC": 20, "expectedActualA": 20,
  "capped": 0, "countsTowardCap": false }
```

它表示「今日记录分已满 200，此刻完成目标 S1 应得 +20」：**目标奖励不封顶、也不计入 D**
（`AGENTS.md` §2 铁律 4 与附录 B §5.4 的封顶口径 —— 封顶只作用于记录类流水）。

若照搬记录类公式 `A = max(0, min(C, 200 − D))`，会得到 `max(0, min(20, 0)) = 0`，
与基准的 `expectedActualA = 20` 冲突，于是报出**一条假失败**（且看起来像实现错了，
实际上是用错了公式）。正确做法是按 `countsTowardCap` 分流：

```js
const A = c.countsTowardCap === false ? C : CarbonCalc.actualPointOf(C, D);
```

这条分流是**用例语义**的一部分，不是为了让测试变绿：`capped` 期望值同样是 0（未封顶）。
基准里若新增 `countsTowardCap === false` 的样例，本 runner 自动按同一口径处理。

## 6. 失败语义与维护

- 任一 FAIL → 脚本**非零退出**（`calc_samples.mjs` 与 `baseline_validator.mjs` 各自返回 1，`run.sh` 汇总）。
  实测过：把基准里一处 `expectedReductionKg` 与一处 `expectedActualA` 故意改错（只在 `/tmp` 的副本上），
  两个 runner 分别报 `RESULT: PASS=53 FAIL=2` 与 `mismatches=3`，退出码均为 1。
- **失败就是发现**：不许为了让这里变绿而改基准、删断言、跳过用例（`AGENTS.md` §5、`tests/README.md` §4）。
  若确认是基准写错了，那是一次需要理由的决策，要按 `AGENTS.md` §3 同步改文档并在提交信息里写明。
- 新增/替换被消费的源文件：改 `run.sh` 顶部的 `MAIN_SRC` / `TEST_SRC` 列表，并同步 §3 的 `expected` 清单
  （纯类型文件会被 TS 擦除、不会出现在 metafile 的 inputs 里，需放进 `typeOnly` 集合）。
- 若某个 `app/` 下的纯逻辑文件开始 import ArkTS 运行时 API（如 `@ohos.*`），它会在这里直接转译失败——
  那是**信号**，说明它已不适合离线复算，别把 `@ohos` 塞进 tests/tools/ 的桩里假装能跑。
