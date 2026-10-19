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
- **hypium 的 41 个 `it()` 仍然未运行。**（t74 更正：本工具于 t37 入库时 `ohosTest` 为 36 个 `it()`，t62 增补后为 41） 本工具跑完**不改变**这一事实：`tests/README.md` §5 里 L1 的
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
- **注入-还原用 `git show`，别用 `cp` 备份**（t42 实测陷阱）：做「改一个真实常数 → 应报错 → 还原」的自证时，`cp 原文件 /tmp/备份` 的备份会被后续 shell 重放污染（备份内容也跟着变成被改后的值），于是「还原」实际是把**污染版**写回去，症状是还原后**仍然 FAIL**。正确做法：`git show HEAD:<path> > <path>`，或用 `git archive HEAD | tar -x` 解出的干净副本里的原文件；还原后校验 `git diff --stat <path>` 为空（或与 `git show HEAD:<path>` 逐字节相同）。
- 新增/替换被消费的源文件：改 `run.sh` 顶部的 `MAIN_SRC` / `TEST_SRC` 列表，并同步 §3 的 `expected` 清单
  （纯类型文件会被 TS 擦除、不会出现在 metafile 的 inputs 里，需放进 `typeOnly` 集合）。
- 若某个 `app/` 下的纯逻辑文件开始 import ArkTS 运行时 API（如 `@ohos.*`），它会在这里直接转译失败——
  那是**信号**，说明它已不适合离线复算，别把 `@ohos` 塞进 tests/tools/ 的桩里假装能跑。

## 7. `run_tests.sh` —— 把 `ohosTest` 里的 41 个 `it()` 也在离线环境真跑一遍

`run.sh` 只跑「基准复算」（纯逻辑、无平台依赖）。`run_tests.sh` 更进一步：它把
`app/entry/src/ohosTest/ets/test/*.test.ets` 与它们依赖的 `main/ets/**` 一起转译，
用垫片顶掉 `@ohos/*` 平台 API，在 Node 里**真实执行每一条 `it()`**。

```bash
bash tests/tools/l1_offline/run_tests.sh                 # 退出码 0 = 36 条全过且基准一致；1 = 有失败；2 = 环境/转译问题
L1_VERBOSE=1 bash tests/tools/l1_offline/run_tests.sh     # 附带 hilog 与失败堆栈（已开 sourcemap，行号指回原始 .ets）
L1_ONLY=ShopPriceFallback bash tests/tools/l1_offline/run_tests.sh   # 只跑某个套件
L1_CASE=⑤ bash tests/tools/l1_offline/run_tests.sh        # 只跑套件内某条用例（与 L1_ONLY 可叠加）
L1_KEEP=1 bash tests/tools/l1_offline/run_tests.sh        # 保留转译产物目录，供排查
```

平台垫片在 `platform/`，**只垫 API、不含业务逻辑**：`relationalStore` 落到 `node:sqlite`
（真 SQL：唯一索引、`ON CONFLICT ... DO UPDATE`、`MAX()`、事务都按真语义执行），
`@ohos.app.ability.common` / `@kit.AbilityKit` 给出可用的 `Context`（`resourceManager.getRawFileContent`
读真 rawfile），`@ohos/hypium` 提供 `describe/it/expect` 与断言匹配器，
`@ohos.file.fs` 等未覆盖模块由 `unavailable.cjs` **显式抛错**（不静默返回假值）。

执行前会重放 App 的**启动地基**（`RdbHelper.open` 建 19 张表 → `SeedRepository.seedStatic` 写种子 →
`FactorRepository.load`），调的都是仓库真实函数：这些用例是按「App 已启动过」写的（例如
`ShopPriceFallback ⑤` 断言"回落到 rawfile 播种价"，而播种发生在启动路径里、不在任何用例里），
不重放会得到一片"测试自身缺前置"的红。**冷启动取价 / 配置下发两步不重放**（网络例外，L1 不出网）。

### 7.1 本次实测（2026-10-18，原样摘录尾部）

```
转译完成：78 个 .ets → CJS（.js）
启动地基：goals=11 badges=8 shop=9 science=12 factors=CF-2026.2
...
hypium 用例：36 条，PASS=18 FAIL=18（**历史留痕，不改写**：这是 t43 首次离线真执行时的原始输出，当时仓库确为 36 条；**t74 更正：现为 41 条**，见 `docs/VERIFICATION.md §R16.2`）
CalcBaselineValidator：checked=323 passed=true
基准复算结论：全部一致：共复算 323 个断言点

RESULT: FAIL
```

### 7.2 18 条失败的逐条归因（**这些是发现，不是被放行的红**）

36 条里 18 条过、18 条失败。失败**没有一条**是「垫片缺 API」造成的，逐条如下
（`app/` 与 `tests/cases/` 本轮**一个字节都没改**，缺陷只登记、不顺手修 —— 本任务的 inScope 是 `tests/tools/`）：

| 套件 | 用例 | 断言/抛出位置 | 观察 vs 期望 | 归因 |
|---|---|---|---|---|
| CalcSamples | 唯一计算入口 | `app/entry/src/ohosTest/ets/test/CalcSamples.test.ets:109-110` | `actualPoint=200` vs 期望 `570` | **用例期望过时**：`CarbonCalc.actualPointOf`（`app/entry/src/main/ets/service/CarbonCalc.ets:174-178`）缺省用 `effectiveDailyCap()` 封顶，`AppConstants.ets:34` = 200；570 是 `expectedPoint`（C），不是实入 A。用例仍按"不封顶"写 |
| LwwMerge | ①–⑩（10 条） | `app/entry/src/ohosTest/ets/test/LwwMerge.test.ets:299`（setup 抛错） | 登录 `INPUT_INVALID`：「用户名只能用字母、数字、下划线」 | **夹具自造非法入参**：`:295-297` 的用户名 `t-lww-${now}` 含 `-`，被 `AuthService` 的入参校验拒掉；与实现无关，10 条一起红 |
| BadgeIdempotent | 徽章解锁幂等 | `app/entry/src/ohosTest/ets/test/BadgeIdempotent.test.ets:53` | `again.length=1` vs 期望 `0` | **实现缺陷**：`app/entry/src/main/ets/viewmodel/RewardService.ets` 的 `unlockBadges` 用 `BadgeEngine.evaluate` 算出 `newly`，但写库用的是 `BadgeEngine.progressRows(..., unlockedIds, ...)`，后者只按**调用前**的 `unlockedIds` 判 `unlocked` → 新解锁徽章永远写不进 `unlocked=1`，每次调用都把同一枚当"新解锁"返回。实测落库行：`B_FIRST unlocked=0 progress=1`，而 `unlockBadges` 连调三次都返回 `['B_FIRST']` |
| BackupRoundTrip | 备份→恢复往返 | `BackupRoundTrip.test.ets:84` → `app/entry/src/main/ets/viewmodel/domain/BackupCodec.ets:67` `JSON.parse('')` | 备份文件读成空串 | **测试支撑代码缺陷**：`app/entry/src/main/ets/viewmodel/store/FilesPort.ets` 里 `MemoryFiles.list()` 返回的 `name` 是**含目录的相对路径**（`backup/xxx.json`），而真实端口 `FileIoFiles.list()` 返回**裸文件名**；用例按裸名拼 `backup/${list[0].name}` → 读到另一个不存在的键 → 空串 |
| ServerConfigFallback | ④ goalRewards 覆盖 | `ServerConfigFallback.test.ets` 的 `expect(rewardOfCard(cards,'S1')).assertEqual(7777)` | 实得 `20`（内置值） | **实现缺陷**：`app/entry/src/main/ets/viewmodel/net/ServerConfigFetcher.ets` 的 `effectiveFrom()`（读库侧）调 `parse(raw, false, [])`，把 `knownGoalIds` 传成**空数组** → `rewardsOf()` 把每条 `goalRewards` 都判成"未登记"整条丢弃 → 下行的目标奖励在**运行期永不生效**（写入侧校验通过、`goalRewardCount=1`，两端口径不一致） |
| ShopPriceFallback | ② / ⑤ / ⑥（3 条） | ② `expect(basePrice).assertEqual(1500)`；⑤ ⑥ `assertTrue(false)` | 实得 `1800` / 断言 false | **用例间共享状态耦合**：同一进程一份库（设备上同样如此），① 先把 `app_config[shop_items]` 整份覆盖成 1800，② 却断言"内置基线 1500"、⑤ 断言"从未拉到过"。**单跑这三条全部通过**（`L1_ONLY=ShopPriceFallback L1_CASE=②` 等，见 §7.3） |
| ServerConfigFallback | ⑥ 降级不抛错 | 同套件 | 断言 false | 同上：单跑通过，随套件顺序跑失败（① 已写入一份有效配置） |

合计 1 + 10 + 1 + 1 + 1 + 3 + 1 = 18。

### 7.3 「单跑通过、连跑失败」的复现命令

```bash
L1_ONLY=ShopPriceFallback L1_CASE=② bash tests/tools/l1_offline/run_tests.sh   # → RESULT: PASS
L1_ONLY=ShopPriceFallback L1_CASE=⑤ bash tests/tools/l1_offline/run_tests.sh   # → RESULT: PASS
L1_ONLY=ShopPriceFallback L1_CASE=⑥ bash tests/tools/l1_offline/run_tests.sh   # → RESULT: PASS
L1_ONLY=ServerConfigFallback L1_CASE=⑥ bash tests/tools/l1_offline/run_tests.sh # → RESULT: PASS
```

### 7.4 这一节**不改变** hypium 的状态

`run_tests.sh` 把 41 个 `it()` 在**离线环境**跑了一遍（t74 更正：它实现时是 36 个，现为 41），用的仓库真实实现；但它跑的是
`node` + 垫片，**不是** `ohosTest` 在设备上的执行。因此：

- 「`hvigorw test` / hypium 在真机或模拟器上的 L1 执行」**仍然是未运行**（无真机、无模拟器、
  Previewer 与 glibc 2.43 不兼容）—— 本工具不改变这一事实，两条证据**不可互相顶替**。
- 垫片层的差异本身就是结论的边界：`relationalStore` 是 `node:sqlite` 而非设备上的 RDB，
  `fileIo` 是 Node `fs`、HTTP 一律不出网。凡是依赖这些真实平台行为的断言，本工具**不能**替代设备执行。
