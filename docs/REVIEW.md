# 交付评审报告（round 4 · t8 attempt 9 复评）· CarbonBoo（赛题二）

> 评审人：**fixer-oc**（AgentTeams 成员；本轮角色是**评审者**，不是实现者 —— 只写本文件，
> 未改任何被测源码 / 规格文档 / 测试基准）
> 本轮结论**绑定 `HEAD = 53f76ca21ffb96128f7c756aa06a8869c336b73e` 的字节**（开工与收工各复核一次）
> 被评审对象：`docs/VERIFICATION.md` 的 §R4 / §R6 / §R8（含 §R5、§R7 的补充证据）+ 仓库当前实现
> 历史轮次报告（§0–§10，t32 终审，绑定 `284c069`）**原文保留在下方**，本附录只做追加，不覆盖、不删改。

## §R9.0 开工四查（原始输出，照录）

```
$ git rev-parse HEAD
53f76ca21ffb96128f7c756aa06a8869c336b73e
$ git status --short
（空输出）
$ python3 tests/tools/check_l0.py --strict ; echo L0_EXIT=$?
（… L0-1 / L0-2 / L0-3 全过 …）
结论：PASS —— 基准自洽，文档无已知冲突
L0_EXIT=0
$ md5sum tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  tests/cases/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
```

## §R9.1 本轮**我自己实跑**的四条门禁（原始输出，可复现）

| # | 命令 | 结果 |
|---|---|---|
| 1 | `python3 tests/tools/check_l0.py --strict` | **`L0_EXIT=0`**，尾行「结论：PASS —— 基准自洽，文档无已知冲突」 |
| 2 | `cd server && CARBONBOO_TEST_DB=carbonboo_test_t8 .venv/bin/python -m pytest tests/ -q` | **`237 passed, 1 warning in 230.22s`，`PYTEST_EXIT=0`** |
| 3 | `cd app && source ~/harmony-toolchain/env.sh && export OHOS_BASE_SDK_HOME=$DEVECO_SDK_HOME && hvigorw --no-daemon assembleHap` | **`BUILD SUCCESSFUL in 6 s 409 ms`，`ASSEMBLE_EXIT=0`**（增量：`PackageHap` 显示 `UP-TO-DATE`；**全量干净构建**的原始输出见 §R8.2，由队长实跑，我**未重跑**，如实标注为「采信」） |
| 4 | `bash tests/tools/l1_offline/run.sh` | **`checked = 323` / `passed = true` / `mismatches=0`，`RUN_EXIT=0`** |

**第 2 条的环境事实（必须写清，否则等于伪证）**：开工时 `127.0.0.1:13307` **不可达**，`carbonboo-mysql` 容器处于 `Exited (255) 23 hours ago`；
我第一次跑 pytest 得到的是 `237 errors`（报错原文是项目自带的 `STOP: 本机未找到可用的 MySQL…` 保护，不是代码缺陷）。
**我用 `docker start carbonboo-mysql` 把项目容器拉起**（镜像与本机既有容器，未新建、未改配置、未改库名），确认 `127.0.0.1:13307 OPEN` 后重跑，才得到上表 237 passed。
⇒ 这条证据的**真实性**由我负责：237 passed 是在**隔离库 `carbonboo_test_t8`** 上跑出来的（未占用别人的默认库）。

## §R9.2 t32 的 F1–F8：逐条闭环复核（不采信「改 status」，只看仓库现状）

| id | t32 原判 | 本轮复核 | 现状证据 |
|---|---|---|---|
| F1（medium） | 例外集口径仍有 4 处写「四项」 | **关闭** | `grep -rn "四项网络例外\|例外仅四项\|四个可依赖\|仅有的四个"` 全仓（排除 build/、.agent-teams）**仅 1 命中**：`docs/REVIEW.md:192` —— 那是本报告 §3.1 对旧措辞的**引用**，不是口径残留 |
| F2/F3/F4（low） | §R4 三条「沿用/计数」的证据与实测不符 | **关闭** | t33 在 `docs/VERIFICATION.md` 文末新增「本轮更正」节（C-F2/C-F3/C-F4），逐条承认失真并给复现命令与原始输出，未删原文 |
| F5（low） | §R4.6 两处函数名误标 | **关闭** | `docs/VERIFICATION.md:780` 已改为 `:258 amountOfCarFreeDays` / `:267 amountOfRecyclePieces`（t33 原位订正，并在「本轮更正」C-F5 留痕） |
| F6（low） | 未运行项两套 N 编号无映射 | **关闭** | 新增 C-F6 映射表（§R4.7 N1–N5 ↔ §13 N1–N8）并写死「引用须带小节前缀」 |
| F7（low） | 复算/契约脚本未入库，证据链易失 | **关闭** | `tests/tools/l1_offline/`（t37）与 `tests/tools/vision_check/`（t41）均已入库；本轮 `RUN_EXIT=0` **现场复现**，不再依赖 `/tmp` |
| F8（low·信息） | `PointCap` 套件名无对应文件 | **关闭** | `tests/README.md:24` 已改为删除线行并注明由 `CalcSamples.test.ets` + `CalcBaselineValidator.ets` 承载；`:112` F10 写明「非缺陷，有意设计」 |

> 复核口径：**「关闭」只表示「证据已在仓库且我能复现」，不表示「这个缺陷本来不存在」**。F1 曾是真缺陷（t33/t34 修复），这一点在报告里保留痕迹。

## §R9.3 用户原始要求（m00004）↔ 三部分交付物：逐条对应

| 用户要求 | 交付物（仓库内） | 本轮证据 | 判定 |
|---|---|---|---|
| **① 鸿蒙 app**（ArkTS + API 12） | `app/`：19 个页面文件（`Index` + 18 页）、23 个组件、`viewmodel/` 服务层、`data/` 19 表 schema + Dao | `assembleHap` EXIT=0；§R6/R4 的**注入自证**（未定义引用 → `BUILD FAILED 255` 且自定位 `文件:行:列`）证明页面/组件**确在编译图**内，不是「假绿」 | **通过（限已跑项）** |
| **② 服务端**（FastAPI + MySQL） | `server/app/`：`auth 5 + sync 4 + shop 1 + config 1 + backup 3 = 14` 个端点；21 张表；`sql/schema.sql` + migrations | **`237 passed`**（我独立复现）；`/admin` 双 JWT 隔离在 L3 用例内 | **通过** |
| **③ Web 管理后台** `/admin` | `server/admin_web/`（16 个 py + templates/static），`mount_admin(app)` 在 `server/app/main.py:170-175` 挂载，**可选件**（ADR-0001） | 服务端渲染路由 19 条（`api.py`）；**浏览器内交互本轮未跑**（无浏览器驱动） | **通过（服务端侧）/ 未跑（浏览器侧）** |
| **④ 用 git 管理便于回滚** | 47+ 次提交，`docs:`/`feat:`/`fix:`/`test:`/`chore:` 前缀；§5.1 基准与推送证据条款 | `git log --oneline -40` 逐条可读；**无**「改期望值/删断言/跳用例」类提交（§R9.5） | **通过** |
| **⑤ 前端用视觉模型** | 视觉通道：`tests/tools/vision_check/`（t41 入库） | §R7.2 两次探针 `HTTP_STATUS=200` + 判读与图一致；§7.6 色板 `17/17` 命中 | **部分**：通道与色板层**已验证**；**页面级截图 0 张**（见 findings G2） |
| **⑥ 规约红线**（禁 `any` / `@ts-ignore` / 强制断言 / 第三方包） | `app/entry/src/main/ets/**` | `grep -rn ": any\b\|@ts-ignore\|as unknown as"` → **0 命中**；`oh-package` 无第三方运行时依赖 | **通过** |

## §R9.4 四条铁律：`文件:行` 逐个核对（本轮重跑，不转抄）

| 铁律 | 结论 | 证据 |
|---|---|---|
| **1 本地优先** | 成立 | 客户端真相源：`app/entry/src/main/ets/data/dao/CarbonRecordDao.ets:18`（`import { relationalStore }`）、`:52`（`private readonly store: relationalStore.RdbStore`）；服务端**不做碳计算**：`grep -rn "factor\|reduction" server/app` 只命中**模型列定义**（`server/app/models/ledger.py:33-36`），无乘法/无因子逻辑 |
| **2 单一计算入口** | 成立 | 唯一实现 `app/entry/src/main/ets/service/CarbonService.ets:107`；调用点仅 `viewmodel/RecordService.ets:151` / `:319` / `:375`；`pages/` 目录下 `factor` 只用于**展示**（`RecordDetailPage.ets:141-143` 读快照字段），无页面自行乘因子 |
| **3 因子快照** | 成立 | 列定义 `app/entry/src/main/ets/data/schema/ClientSchema.ets:85-87`（`factor_value/factor_version/factor_source`）＋ 写入 `CarbonRecordDao.ets:70-72`；回读 `:270-272` |
| **4 积分单向可追溯** | 成立 | 余额唯一算法 `viewmodel/PointService.ets:87`（`balance()`，`:97` 取 `bal` 聚合，`:109` 派生碳币）；`point_record` 写入只经 `points.append(...)`：`IncludeService.ets:129`、`RecordService.ets:425`、`RewardService.ets:211`、`ShopService.ets:163`；**无删除路径**（流水只增不删） |

## §R9.5 「为让测试变绿而改期望值 / 删断言 / 跳用例」专项核查

| 检查 | 命令 | 结果 |
|---|---|---|
| 基准期望值是否被改过 | 对 `tests/cases/carbon-calc.json` 的**每一次**历史提交，统计 diff 里 `±…"expected…"` 行数 | **仅初始提交 `5f751c4` 有 25 行**（创建文件）；其余 11 次提交**全部 0** |
| 是否有跳过的用例 | `grep -rn "\.skip(\|pytest.mark.skip\|xfail"` over `server/tests` + `app/entry/src/ohosTest` | **0 命中** |
| 是否有 `expect.fail` 兜底 | `grep -rn "expect.fail"` over ohosTest | **0 命中** |
| 是否有测试文件被删除 | `git log --diff-filter=D --name-only -- '*test*' '*Test*'` | **0 条** |
| 规约红线 | 见 §R9.3-⑥ | 0 命中 |

⇒ 未发现 AGENTS §5 明令禁止的三类操作；**无 reject 级证据**。

## §R9.6 未运行项（单列，**一条都不算通过**）

| # | 未运行项 | 成因（本轮复验一致） |
|---|---|---|
| N1 | **hypium L1 全部 36 个 `it()`**（10 套件） | 无真机（`hdc` 无设备）、无模拟器（`/dev/kvm` 不可写）、Previewer 崩于 glibc 2.43 → `hvigorw test` 执行段 `EXIT=124`。**数字本轮自核**：`grep -c "^\s*it("` 合计 **36**，与文档一致（`47` 是不排除注释的粗数，不能引用） |
| N2 | L2 端侧集成（两条设备 + 飞行模式全功能） | 需两类设备，本机没有 |
| N3 | `server/deploy/` 实跑（容器 / systemd + TLS + 备份） | 无部署目标 |
| N4 | `/admin` **浏览器内**交互 | 无浏览器驱动；只验证了服务端渲染路由与 L3 用例 |
| N5 | **页面级视觉走查（18 页截图）** | 见 findings **G2** |

> 纯逻辑部分**不在这张表里**：`tests/tools/l1_offline/` 跑仓库真实实现、`checked=323 passed=true`（本轮 `RUN_EXIT=0` 复现）。
> 但它**不是** hypium 的替代品（不覆盖 UI/DB/网络/生命周期），两者不可互相顶替 —— 这一点 t37/t38 已写死，我复核成立。

## §R9.7 结论与放行建议

**verdict = `pass`（限已跑项）**，绑定 `HEAD = 53f76ca21ffb96128f7c756aa06a8869c336b73e`。

三条理由：
1. 三部分交付物**都在仓库内且可运行**：app 编译门禁成对自证（§R6/R4 的注入 → 255 → 0）＋ 本轮 `assembleHap EXIT=0`；服务端本轮**我独立复现 `237 passed`**；`/admin` 挂载点与 19 条服务端渲染路由在仓库内可查。
2. `docs/VERIFICATION.md` 的「通过」断言**逐条能找到命令与原始输出**；**凡未运行的都显式单列为未运行**（§R9.6），没有一条被偷换成通过（t32 的 F1–F8 已全部闭环，§R9.2）。
3. 四条铁律在代码里**真实成立**（§R9.4 给出 `文件:行`），且 AGENTS §5 的三类禁止操作**零命中**（§R9.5）。

放行建议：**可以交付，交付说明必须原样带上 §R9.6 五项未运行**；不得把「编译通过 / 离线复算通过」表述成「L1 通过」。

**Findings（2 条 low；无 blocker / 无 high / 无 medium）**

| id | severity | problem | requiredFix | file:line |
|---|---|---|---|---|
| G1 | low | §R8.2（全量干净构建）与 §R8.4（门禁自证）的证据由**队长实跑**提供，我无法在本轮独立复现（复现要清空 `build/`、`.hvigor/` 并跑 50 s，且注入会临时改 `app/` 源码 —— 超出本评审「只写 REVIEW.md」的写入范围） | 报告里已标注来源，保持不变；若需评审独立复现，另派一个允许改 `app/` 的执行型任务在 `git archive` 副本里做（`/tmp/cbgate` 模式） | `docs/VERIFICATION.md:24-105`（§R8.2 / §R8.4） |
| G2 | low | m00004 的「前端用视觉模型」只到**能力层/色板层**（`HTTP=200`、`17/17`），**页面级 18 页零截图**，故页面观感、布局、令牌落地**没有视觉证据** | 有真机/模拟器时补 18 页截图并跑 `vision_check` 判读；否则在交付说明中显式声明该证据缺失（不得表述为「界面已视觉验收」） | `docs/VERIFICATION.md:2396`（§R7.4 准确三态）/ §13 N8 |

**与前几轮的关系**：§0–§10 是 t32 终审（绑定 `284c069`，verdict=pass 限已跑项）。本轮**不推翻**它，只做两件事：① 把绑定字节刷新到 `53f76ca`（此后 `docs/`、`tests/`、`app/` 的改动我已逐项核对，§R9.2/§R9.5）；② 用我自己跑的四条门禁替换「采信上轮」。

---
## 附录 · 历史轮次原文（round 3 · t32 终审，绑定 `284c069`）

> 为便于阅读，本轮只把原标题由一级降为二级；**§0–§10 正文一字未改**。

> 评审人：**reviewer-cn**（AgentTeams 成员，交付评审员；**非实现者**，本轮不改任何被测源码与规格文档）
> 评审对象：`docs/VERIFICATION.md` **§R4 round 4**（t31 终验，基准 `e211ae1`）及其声明覆盖的仓库状态
> 本轮基准 commit（**完整 40 位**，`git rev-parse HEAD` 实跑）：
> `284c069411993c93b45818c8b39b06d623f30b90`

## §0 开工四查（四条原始输出，照录）

```
$ git rev-parse HEAD
284c069411993c93b45818c8b39b06d623f30b90

$ git ls-remote origin main
284c069411993c93b45818c8b39b06d623f30b90	refs/heads/main

$ git status --short
（空 —— 工作树干净，开工前置条件成立）

$ md5sum tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  tests/cases/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
```

- `git rev-parse HEAD` 与 `git ls-remote origin main` **双向一致** ⇒ 符合 AGENTS.md §5.1-4「已推送」的唯一合格证据（读远端引用，不是本地 `origin/main` 缓存）。
- 基准两副本 **md5 同值** `e096b2db…` ⇒ t29 报出的 O1（副本漂移）确已由 `d228939` 修掉、未复发。
- 近期提交链：`284c069`（t31 终验）/ `e211ae1`（O3 修正）/ `67e79c8`（O2 四项→五类）/ `d228939`（O1 同步副本）/ `c58b702`（t29 复评）。

### 0.1 verdict 绑定的字节与「报告入库后 HEAD 会前进」的处理

本报告的 verdict **绑定 `284c069` 的字节**。`git diff --name-only e211ae1..284c069` 只有 `docs/VERIFICATION.md`（+355/−1，只在文件开头新增 §R4）；`git diff --stat c58b702..284c069 -- app/ server/ tests/` 只有 `app/entry/src/ohosTest/resources/rawfile/carbon-calc.json | 4 ++--`（即 `d228939` 的基准副本同步，**非源码**）。⇒ 被测源码自 `c58b702` 起零改动。

本报告自身是一次 `docs:` 提交，提交后 HEAD 会前进一次，且 `git diff --stat 284c069..HEAD -- app/ server/ tests/` 为空 —— **产出本报告不构成新的被测对象**，下游取用时请按 §0 的基准 SHA 复现。

### 0.2 结论

**verdict = `pass`（限已跑项；附 1 条 medium + 7 条 low findings，无 blocker / 无 high）**

一句话：**§R4 声明的六类门禁（L0 / L3 全量 / 编译门禁成对自证 / 数值真相源零改动 / 规约红线 0/0/0 / 四条铁律）我都独立重跑复现成立；五项未运行项仍如实单列、未被任何章节改写成通过；数值真相源经程序化逐键比对确认只有 `docConflicts` 的 B21/B42 两段文本变动、数值区 7 个键全 equal。** 因此不满足任务书列出的三条「不判 pass」条件（无证据的通过 / 未运行写成通过 / 数值被改动）。

本轮**新发现**的 8 条问题全部是**证据陈述与检测口径层面**的瑕疵（§R4.3 的两条「沿用」理由与实测不符、「一字未删」不成立、141 处不可由所述模式复现、两处函数名标错、例外集口径仍有 4 处写「四项」），**均不改变任何一条实质结论**，故不据此判 `needs_revision`；但 F1（medium）是本项目反复多轮的同一类契约口径缺陷的**最后 4 处残留**，建议下一轮用一次极小提交清掉（见 §9）。

---

## §1 本轮我自己实跑的清单（全部可复现；凡「采信」都会明确标注）

| # | 命令 | 结果 | 与 §R4 对照 |
|---|---|---|---|
| A | `python3 tests/tools/check_l0.py --strict`（`$?` 单独取值） | **EXIT=0**；L0-1 检查项 **28** 错误 **0**；L0-2 扫描文件 **89** 命中 **0**；L0-3 docConflicts **0** 条；`结论：PASS —— 基准自洽，文档无已知冲突` | §R4-a 三项原值**逐字吻合** |
| B | `cd server && CARBONBOO_TEST_DB=carbonboo_test_rv ./.venv/bin/python -m pytest tests/ -q` | **237 passed, 1 warning in 194.40s**，**EXIT=0**（唯一 warning = `StarletteDeprecationWarning`，非失败） | §R4-b 吻合（其 196.96s，差异属正常机时抖动） |
| C | `pytest tests/ --collect-only -q` 逐文件计数 | `test_admin 85` / `test_auth 40` / `test_authz 29` / `test_config 25` / `test_shop 10` / `test_sync 48` = **237** | 逐数字吻合，85+40+29+25+10+48=237 ✔ |
| D | 编译门禁基线（`source ~/harmony-toolchain/env.sh && export OHOS_BASE_SDK_HOME=$DEVECO_SDK_HOME && hvigorw --no-daemon assembleHap`） | `BUILD SUCCESSFUL`，**EXIT=0** | 一致（但为增量构建，见 §2.3 局限） |
| E | 编译门禁**注入**（第 39 行 `const RV_GATE_PROBE: number = RV_UNDEFINED_PROBE_SYMBOL + 1;`） | `ArkTS:ERROR File: …/app/entry/src/main/ets/viewmodel/net/SyncService.ets:39:31` / `Cannot find name 'RV_UNDEFINED_PROBE_SYMBOL'.` / `COMPILE RESULT:FAIL {ERROR:2}` / `BUILD FAILED in 24 s 779 ms`，**EXIT=255** | §R4-d 同型（其列号 32、我 31，因探针变量名长度不同，属正常） |
| F | 编译门禁**撤回**（`cp` 备份还原，**未用 `git checkout`**） | md5 复原 `d0fce64796fa5d901b243cc926616980`（与 `git show HEAD:<path> \| md5sum` 同值），`git status --short` 空；`Finished :entry:default@CompileArkTS... after 23 s 903 ms` / `BUILD SUCCESSFUL in 28 s 719 ms`，**EXIT=0**；hap `app/entry/build/default/outputs/default/entry-default-unsigned.hap` = **2,445,613 字节** | §R4-e 同型；**0 → 255 → 0** 三段成立 |
| G | 规约红线三项计数 | `: any` = **0**；`@ts-ignore` = **0**；非相对 import（排除 `@ohos`/`@kit`）= **0** | §R4.5 完全一致 |
| H | 宽口径 `grep -rn "四类"` / `grep -rn "四项"` + 逐行判语境 | 见 §3.1（**这是本轮最花时间的一项**） | 补充了 §R4 未做的「四项」口径 |
| I | md5 双副本 + 数值真相源程序化逐键比对 | 见 §3.2 / §3.3 | 独立复现「零改动」 |
| J | `python3 /tmp/cbv24/ev/recompute.py` 重跑 | **70 检查点 / 失败 0**，含 half-up 单验与家庭净额 170/0/100 | §4 沿用 round 3 的 70/70 **确实可复现** |
| K | 未运行项环境断点复验（`hdc` / `/dev/kvm` / `emulator` / 浏览器驱动 / `ARK_API_KEY` / `nginx` / `/opt/carbonboo` / `ldd`） | 见 §4.2 原始输出 | §R4.7 五条**全部复现** |

**采信（未自跑）**：`§R4-b` 的 196.96s 机时、`§R4-c` 的 4 s 879 ms 基线耗时 —— 只影响性能数字，不影响结论。

---

## §2 逐条核对 §R4 的每一条「通过」

判定口径（严格版）：**命令能产出所述结果 + 结果被原始输出固定 + 结论不超出证据范围**，三条全满足才算「有证据的通过」。

### 2.1 通过且有完整证据（6 条，我已独立复现）

| §R4 条目 | 断言 | 我的判定 |
|---|---|---|
| **R4-a** L0 | `EXIT=0`；28 项 0 错误 / 89 文件 0 命中 / docConflicts 0 | **通过** —— 我复跑同值（§1-A）。且它原文给出 `$?` 单独取值，未读管道尾值，方法正确 |
| **R4-b** L3 全量 | `237 passed`；85+40+29+25+10+48=237 | **通过** —— 我复跑 237 passed（§1-B/C），并核对了「无 skip/xfail/收集遗漏」这条推论：逐文件计数之和恰等于 passed 数，推论成立 |
| **R4-c/d/e** 编译门禁 | 基线 0 → 注入 255（自定位 `文件:行:列`）→ 撤回 0 | **通过** —— 我自己注入/撤回各跑一次得同型结果（§1-D/E/F），错误确实自定位到 `SyncService.ets:39:31`，撤回后 md5 与 HEAD 逐字节一致 |
| **R4.4** 数值真相源零改动 | `git diff --name-only` 无基准 JSON；两副本同 md5 | **通过** —— 我另做了**程序化逐键比对**（§3.3），比 diff 更强 |
| **R4.5** 规约红线 | 三项全 0 | **通过** —— 复跑同值（§1-G） |
| **R4.6** 四条铁律 | 各给 `文件:行` | **通过（2 条标注错名，见 F5）** —— 每条 `文件:行` 我都去读了原文并核对语义（§5）；`:258`/`:267` 的**函数名标注**是错的，但「四处 `Dec.mul` 全在 `CarbonCalc.ets`、业务乘法无第二个文件」这个结论我实测成立 |

### 2.2 「沿用上轮」的两条：结论成立，但**所给的理由与实测不符**（→ F2）

`§R4.3` 表格两行：

```
docs/VERIFICATION.md:265  | §4 独立复算 70 检查点 | 沿用 round 3（308d09f） | 理由：git diff 308d09f..e211ae1 -- tests/cases/ 为空且本轮 md5 与 round 3 记录同值 ⇒ 被复算的字节没变 |
docs/VERIFICATION.md:269  | §9 契约 A/B/C 抽查 | 沿用 round 3 | 本轮未重跑；app/ server/ 未被这些提交触碰（git diff --stat 308d09f..e211ae1 -- app/ server/ 为空） |
```

两条理由我都实测，**都不成立**：

```
$ git diff --stat 308d09f..e211ae1 -- app/ server/
 app/entry/src/ohosTest/resources/rawfile/carbon-calc.json | 4 ++--
 1 file changed, 2 insertions(+), 2 deletions(-)

$ git diff --stat 308d09f..e211ae1 -- tests/cases/
 tests/cases/carbon-calc.json | 4 ++--
 1 file changed, 2 insertions(+), 2 deletions(-)

$ # md5 对照（round 3 记录在 docs/VERIFICATION.md:362/:363/:569/:580/:1390）
round 3 现场记录 = c096da45ba7e1852d25cf91699fcb42b
e211ae1 / 当前 HEAD = e096b2db77bbcc9a43ee8728cbd883e9      ← 不同值
```

→ 「diff 为空」为假、「md5 同值」为假。**但结论本身成立**，因为有更强且正确的理由：`samples`/`capSamples`/`boundarySamples`/`factors`/`constants`/`conversions`/`meta` **7 个键逐键 `identical=True`**（§3.3），即「被复算的字节没变」这句话是真的，只是它举的两个证据都错。我另外把 `recompute.py` 重跑了一遍（70/70，§1-J），所以 §4 的「沿用」在我这里已升级为**已复现**。

### 2.3 必须写明的局限（不构成缺陷）

`§R4-c` 的基线 `BUILD SUCCESSFUL in 4 s 879 ms` + `CompileArkTS` 显示 `UP-TO-DATE`，是**增量构建**。§R4 自己在 `:134-135` 已诚实标注「不足以单独证明从零全量可编译」，正确。我这一轮的基线同理（也是增量）。真正有全量编译背书的是 **撤回那一次**：`CompileArkTS` 真实执行 23 s 903 ms（§R4 那次是 23 s 644 ms）。⇒ 「能被编译器校验的字节可以编译」有真实编译段支撑；「从零 clean 全量可编译」本轮**没有**证据，属环境与时间成本限制，不是缺陷。

### 2.4 `§R4` 首段「一字未删」不成立（→ F3）

`docs/VERIFICATION.md:6` 写「`§0` 起的正文仍是 round 3（t24，基准 `308d09f`）的原文，**一字未删**」。实测：

```
$ git diff --numstat 39be3b0..284c069 -- docs/VERIFICATION.md
511	5	docs/VERIFICATION.md        ← 增 511 行、删 5 行
```

被删的正是 `V9` 判据行、`F3` 闭环判定行与那两行「窄模式唯一命中」的假绿证据（t28 的 R3 勘误把它们改写成「部分闭环」）。**删是应该删的**（那是假绿证据），但「一字未删」这句话本身是错的，而它承载着「旧结论一律继续有效」的授权 —— 读者若照字面理解，会以为 V9 仍是「闭环」。

---

## §3 假闭环抽检（不看 diff，用宽口径 grep + md5 + 逐键比对自己跑）

### 3.1 R1「例外集统一五类」：`四类` 全清，但 **`四项` 仍有 4 处例外集残留**（→ F1）

**宽口径 `四类`**（排除 `docs/REVIEW.md`、`docs/VERIFICATION.md` —— 两份报告的自引用会污染自己的输入；排除 `build/`、`.agent-teams/`、`node_modules`、`.venv`）：

```
$ grep -rn "四类" --include='*.md' --include='*.json' --include='*.py' --include='*.ets' . | 排除上述路径
→ 22 行
```

逐行判语境后：**例外集语境 0 处**。22 行的构成（全部「不该改」）：
- **减排分类语境 11 行**：`docs/APPENDIX-D-acceptance.md:48`（D2-2 四类减排量）、`:538`（四类之和 61.7400）、`docs/APPENDIX-E-demo-script.md:67`（柱状图四类行为）、`:134`（四类共三十个因子）、`docs/PLAN.md:375`（F2-2 四类并列）、`tests/cases/carbon-calc.json:971`（B44 四类 21.6000/14.0400/13.5000/12.6000）、`app/entry/src/main/ets/pages/DashboardPage.ets:126`、`app/entry/src/main/ets/viewmodel/domain/ChartModel.ets:6`/`:11`/`:276`、`app/entry/src/main/ets/viewmodel/domain/CsvRenderer.ets:7`。
- **历史留痕 / 自述 11 行**：`AGENTS.md:61`/`:66`/`:247`、`docs/CHANGELOG.md:34`/`:39`/`:97`/`:100`、`docs/DECISION-0002-doc-contract-errata.md:22`、`tests/cases/carbon-calc.json:955`（B42.correct 句尾自述「本条原文的『四类』于 t28 一并改五类」）。

行数账自洽：`9d73de4` 基线宽口径 20 行 − 8 处真缺陷（`PLAN.md` 7 + `ADR-0001:17` 1）= 12，再加 t28/t31 新写的收尾登记行 = 22。**无漏改。**

**宽口径 `四项`（§R4 与 t29 都只查了「四类」，没查「四项」）**：

```
$ grep -rn "四项" --include='*.md' --include='*.json' --include='*.py' --include='*.ets' . | 同上排除
→ 18 行（含 ohosTest 基准副本内的同内容 3 行）
```

其中 **4 行是例外集语境，仍是「四项」**（即漏掉了第五类「配置下发」）：

| 文件:行 | 原文 |
|---|---|
| `app/entry/src/main/ets/model/SyncTypes.ets:8` | `铁律 1 例外：登录/注册、多设备同步、商品取价、云端备份四项可依赖网络，其余全部离线可用。` |
| `app/entry/src/main/ets/viewmodel/net/HttpPort.ets:12` | `③ 无网络时由调用方用 AppResult 降级（铁律 1 的例外集只有四项）。` |
| `README.md:16` | `…例外仅「登录 / 云端同步 / 取价 / 云端备份」四项…` |
| `docs/CHANGELOG.md:116` | `可依赖网络的例外**仅四项**：登录/注册、多设备同步、商品取价、云端备份。`（而同文件 `:100` 已写「例外集口径统一为五类」⇒ 同文件自相矛盾） |

其余 14 行是非例外集语境（周期统计四项、SegmentButton 四项、后台可改四项、赛题四项创新拓展、ADR 四项未决项、B21/B42 的 `bad` 原文等），**不该改**。

> **特别说明**：`HttpPort.ets` 正是旧正文 `§7.1`（`docs/VERIFICATION.md:964` 附近）判「铁律 1 成立」时引用的网络出口文件，而**它自己的文件头注释还写着「只有四项」**。这不影响运行时行为（注释不参与编译语义），但作为「口径全仓统一」的宣称，它是一处反例。

判定：**R1 = 部分闭环**（不是 §R4 结论里的「成立」，也不是 t29 的「真闭环」）。文档主体（`PLAN.md` 7 处 + `ADR-0001:17` + `AGENTS.md` 三处）确已统一为五类，剩下 4 处是同一缺陷的尾巴。

### 3.2 O1「基准副本同步」：**成立**

```
$ md5sum tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  tests/cases/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
```

两副本**同 md5、字节一致**。`d228939` 修掉后未复发。

### 3.3 数值真相源零改动：**程序化逐键比对，成立**

```
$ git show 308d09f:tests/cases/carbon-calc.json > /tmp/t32/bench_308d09f.json   # md5 c096da45…
$ git show e211ae1:tests/cases/carbon-calc.json > /tmp/t32/bench_e211ae1.json   # md5 e096b2db…
$ python3 - <<'PY'   # json.load 后逐键 ==
PY
samples          identical=True
capSamples       identical=True
boundarySamples  identical=True
factors          identical=True
constants        identical=True
conversions      identical=True
meta             identical=True
docConflicts     47 条 vs 47 条，id 集合相同，open = []
                 差异条目仅 ['B21', 'B42']，差异字段各仅 ['correct']
```

`git diff 308d09f..e211ae1 -- tests/cases/carbon-calc.json` 原文两处，均为登记文本：
- `B21.correct`：「网络例外仅四项…」→「仅**五类**…原登记为『四项』，t21 定五类后本条未跟进，t28 补齐」
- `B42.correct`：「**四类网络例外**」→「**五类网络例外**…本条原文的『四类』于 t28 一并改五类」

⇒ **数值（`samples` / `capSamples` / `boundarySamples` / `factors` / `constants` / `conversions` / `meta.*`）零改动**，与 §R4.4 的结论一致，且比它给的 `git diff --name-only`（空）证据更硬。当前 `git diff --name-only` 输出为空，符合。

### 3.4 复算可复现性（§4 沿用结论的升级证据）

```
$ python3 /tmp/cbv24/ev/recompute.py
检查点：70    失败：0
RESULT: PASS
```

含 `half_up(0.005×100)=1 vs half_even=0`、`Decimal 1000×0.1920=192.0000 vs float 192.00000000000017`、家庭净额三组 170/0/100（旧双重取负写法为 230/192/300）。⇒ round 3 的 70/70 **确实可复现**，不是转抄。

### 3.5 一处「数字对得上、名字对不上」的证据（→ F4）

旧正文 `§7.1`（`docs/VERIFICATION.md:964`，`§R4` 声明「仍然有效」）与 `§0` 的 `V9` 行（`:419`）都写：

> 全仓 `.ets` 中 `hub.http.request` / `this.http.request` / `HttpPort` 调用共 **141 处**，逐个归入五类 —— **五类之外 0 处**。

按它所述的三条模式实测：`hub.http.request` = **0** + `this.http.request` = **10** + `HttpPort` = **44** = **54**，**不是 141**。

141 的真实来源我找到了：`grep -roE 'http|HttpPort'`（44 个 `HttpPort` + 97 个 `http`）= **141**。但那 97 个 `http` 里包含注释文字、`import { http } from '@kit.NetworkKit'`、`HttpRequest`/`HttpResponse` 类型名、`http.count()` 之类，**不是「网络调用点」**。真实的调用点（`.request(` 发起处，`main` 目录）= **11 处**，全部落在五类内：

```
viewmodel/AuthService.ets:67 / :82 / :98         （登录 / 登出 / 注销账号）
viewmodel/net/HttpPort.ets:91                     （真实实现内部，转发调用）
viewmodel/net/ServerConfigFetcher.ets:106         （配置下发）
viewmodel/net/ShopPriceFetcher.ets:114            （商品取价）
viewmodel/net/SyncService.ets:183 / :192 / :234 / :281 / :304   （同步 push/pull、备份 upload/download/restore）
```

⇒ **「五类之外 0 处」这个实质结论我独立成立**（11 个真实调用点全在五类内），但「141 处网络调用点」这个数字**是原始 token 计数、不是调用点计数**，且所述模式产不出它。

---

## §4 未运行项：确认没有被偷换成通过

### 4.1 三处「未运行」清单都在，且明写不计通过

| 位置 | 内容 | 我的核对 |
|---|---|---|
| `docs/VERIFICATION.md:274` | `### R4.7 未运行项（**一条都不算通过**）`，表内 N1–N5 = L1 / L2 / `server/deploy/` / `/admin` 浏览器 / 视觉走查 | 五项齐，逐项都给了「未运行的具体原因（本轮实测原始输出）」 |
| `docs/VERIFICATION.md:1327` | `## §13 未能真实运行的验证项（**不得算作通过**）`，表内 N1–N8 | 八项齐（比 R4.7 更细，含 `hvigorw test` 执行段 EXIT=124、t18/t13 运行态） |
| `docs/VERIFICATION.md:332` | `> **未运行 = 不算通过。** …尤其不要把「assembleHap BUILD SUCCESSFUL」说成「L1 用例通过」——那 36 个 it() 本轮一个都没执行` | 口径正确，且专门点了最容易混的一句 |

`grep -nE "L1.*通过|通过.*L1"` 的全部命中（`:12`/`:278`/`:333`/`:350`/`:388`/`:446`/`:1354`）**都是否定语境**（「不算通过」「未运行」「不足以」）。⇒ **未发现任何一处把未运行项写成通过。**

`§R4.8` 未决问题 5 条也如实（L1 零执行 / 视觉走查零达成且「必须显式告知用户」/ `/admin` 只到 HTTP 层 / `PointCap` 名不存在 / 不 push）。

### 4.2 未运行项的成因我逐条复验（都是环境限制，不是实现缺陷）

```
$ command -v hdc;                    → 无输出，EXIT=1
$ test -w /dev/kvm; echo $?          → 1（uid 1000 不在 kvm 组）
$ command -v emulator; echo $?       → 1
$ for b in chromium chromium-browser google-chrome playwright chromedriver; do command -v $b; done
                                      → chromium not found / chromium-browser not found /
                                        google-chrome not found / playwright not found / chromedriver not found
$ echo "len=${#ARK_API_KEY}"         → len=0
$ command -v nginx; echo $?          → 1（未安装）
$ ls -d /opt/carbonboo               → No such file or directory
$ ldd --version | head -1            → ldd (Ubuntu GLIBC 2.43-2ubuntu2.4) 2.43
```

⇒ L1（无真机 / 无模拟器 / Previewer 崩于 GLIBC 2.43）、L2（需两台设备）、`server/deploy/`（无部署目标、无 nginx）、`/admin` 浏览器（无任何浏览器驱动）、视觉走查（截图腿断 + `ARK_API_KEY` 为空）**五条成因全部复现**。这些是环境限制，**按任务书要求写进报告、不当缺陷**。

---

## §5 四条铁律：`文件:行` 逐条核对（全部成立）

### 铁律 2 · 单一计算入口

```
$ grep -rnE "\* *(factorValue|factor_value)|(factorValue|factor_value) *\*|mul\(Dec\.from\(factor" --include='*.ets' app | grep -v /build/
app/entry/src/main/ets/service/CarbonCalc.ets:153:    const product: Dec = Dec.from(amount).mul(Dec.from(factorValue));
```

**唯一因子乘法**：`app/entry/src/main/ets/service/CarbonCalc.ets:153`。同文件另有 3 处 `mul`，**都不是因子乘法**：
- `:164` `Dec.from(reductionKg).mul(Dec.fromInt(rate)).toInt()` —— 求应得积分 C
- `:258` `static amountOfCarFreeDays(days: number, kmPerDay: number): number` —— 天数 × 单程里程（**§R4.6 标成「树当量」，实非**）
- `:267` `static amountOfRecyclePieces(pieces: number, kgPerPiece: number): number` —— 件数 × 单件重量（**§R4.6 标成「纸张当量」，实非**）

**唯一 calculate 入口**：`app/entry/src/main/ets/service/CarbonService.ets:76`
`static calculate(activity: ActivityInput, factor: FactorSnapshot, options?: CalcOptions): CarbonCalculation`

**页面层零计算、零 SQL**（`pages/` + `components/`）：
```
calculate → 0    Dec\.from → 0    DecimalUtil → 0    (SELECT |INSERT INTO|INSERT OR|UPDATE |DELETE FROM) → 0
```
页面读取因子的方式确为格式化：`pages/RecordDetailPage.ets:141` `` `${Formatter.number(this.record.factorValue, 'factor')} kg/${this.record.unit}` ``、`components/RecordItem.ets:55` 同型。

### 铁律 3 · 因子快照

`app/entry/src/main/ets/data/schema/ClientSchema.ets:85-88`（`carbon_record` 建表）：

```
:85  factor_value    REAL  NOT NULL,
:86  factor_version  TEXT  NOT NULL,
:87  factor_source   TEXT  NOT NULL,
:88  confidence      TEXT  NOT NULL,
```

四列齐备且**全部 `NOT NULL`**。唯一构造点 `app/entry/src/main/ets/service/CarbonService.ets:187` `static snapshotOf(`；调用点 `app/entry/src/main/ets/viewmodel/RecordService.ets:149`（`CarbonService.snapshotOf(item.value, version, item.source, item.confidence)`）/ `:306` / `:367`（新增 / 编辑 / 补记三条链路）。

### 铁律 4（上）· 流水只增不删

```
$ grep -rniE "(UPDATE|DELETE)[[:space:]]+(FROM[[:space:]]+)?point_record" --include='*.ets' --include='*.ts' --include='*.py' --include='*.sql' --include='*.js' .
→ 0 命中
```

（唯一命中在 `.agent-teams/carbonboo-delivery/team.json` 的历史消息正文里，该目录被 `.gitignore:26` 忽略、**不入库、不构成被测字节** —— 这一条我采纳 §R4.6 的说明并已核对 `.gitignore`。）

- 唯一写入点：`app/entry/src/main/ets/viewmodel/PointService.ets:153` `'INSERT OR IGNORE INTO point_record ' +`（幂等键 `uq_pr_source(user_id, source_type, source_id, flow_kind)`，见 `ClientSchema.ets:141`）。
- 冲正不删行、写负额新行：`PointService.ets:190` `async reverse(userId: string, type: PointType, points: number, sourceId: string, title: string, occurredAt: number): Promise<void>` → `:195 type: 'reverse',` / `:196 points: -points,`。
- 软删除只作用于 `carbon_record`，**不作用于 `point_record`**：`app/entry/src/main/ets/data/dao/CarbonRecordDao.ets:176`、`app/entry/src/main/ets/viewmodel/RecordService.ets:220` 两处 `UPDATE carbon_record SET is_deleted = 1, …`；全仓 `is_deleted` 的写点只有这两处。

### 铁律 4（下）· 余额同口径三处

| # | 位置 | 语义 |
|---|---|---|
| 1 | `app/entry/src/main/ets/viewmodel/PointService.ets:91` | 余额：`'COALESCE(SUM(points), 0) AS bal FROM point_record WHERE user_id = ? AND is_deleted = 0'`（同一条 SQL 里另有 `inc` / `spent`） |
| 2 | `app/entry/src/main/ets/viewmodel/net/SyncService.ets:362` | 家庭合并 · 单设备：`"SELECT COALESCE(SUM(points), 0) AS p FROM point_record WHERE user_id = ? AND is_deleted = 0 AND COALESCE(device_id, '') = ?"` |
| 3 | `app/entry/src/main/ets/viewmodel/net/SyncService.ets:377` | 家庭合并 · 合计：同式去掉 device 条件 |

三处均为**裸 `SUM(points)`**（`points` 本身已带符号），**不做 `flow_kind` 二次取负**（round 1 的 F1 双重取负已修，`SyncService.ets:342` 保留勘误注释）。另有同式非余额语义：`PointService.ets:121`/`:136`/`:235`（`sumBySource`，实读为 `SELECT COALESCE(SUM(points), 0) AS v … AND source_type = ?`）、`server/admin_web/services/stats.py:90` 的 `total_issued = … points > 0` 与 `total_spent = … COALESCE(-SUM(points), 0) … points < 0`。用例内的独立复算参照 `app/entry/src/ohosTest/ets/test/LwwMerge.test.ets:648`（`expect(net).assertEqual(0);   // +96 − 96`，**未运行**）。

### 铁律 1 · 本地优先 / 五类例外

文档侧：`grep -n "五类" AGENTS.md` → `:104`（§2 铁律 1）、`:143`（§5 L2）、`:164`（§6）**三处齐**。代码侧出口单一（11 个调用点，§3.5），未登录时不发请求的短路点在发请求之前。**但代码注释与 README 存在 4 处「四项」残留（F1）**，其中 `app/entry/src/main/ets/viewmodel/net/HttpPort.ets:12` 就在这个出口文件里。

---

## §6 `docs/VERIFICATION.md` 自身一致性

| 检查项 | 结果 |
|---|---|
| 轮次索引（`:381-388`）4 行 ↔ 各节基准 SHA | **一致**：round 1 `87a055d`/`3a23c82`、round 2 `971d042`、round 3 `308d09f`、round 4 `e211ae1`，与各节首部所写相符 |
| `§13` 的「L3 全量本轮未执行」↔ `§R4-b` 的「237 passed」 | **已显式消解**：`:1348` 有「上段『L3 全量本轮未执行』是 round 3 的口径，已被 §R4 覆盖」 |
| `§13` N1 的「`hdc` 未安装」↔ `§R4.7` N1 的「PATH 无 hdc 但 SDK 内有二进制」 | **已显式消解**（`:1352-1356` 补正「两者说的是同一件事（无真机），不应被读成『换一个 hdc 就能跑』」） |
| `§R4` 首段「一字未删」↔ 实际 5 行被删 | **矛盾**（F3） |
| `§R4.3` 两行「沿用」理由 ↔ `git diff` / md5 实测 | **矛盾**（F2） |
| 未运行项编号：`§R4.7` N1–N5 ↔ `§13` N1–N8 | **两套编号并存、无映射**（F6）：R4.7 的 N3=deploy 对应 §13 的 N4；R4.7 的 N4=`/admin` 对应 §13 的 N5；R4.7 的 N5=视觉走查对应 §13 的 N8；且 `§R4.3` 写「§13 未运行 N1–N8 本轮复核（R4.7）」，但 R4.7 只有 5 行 |
| `§R4.6` 对 `CarbonCalc.ets:258/:267` 的语义标注 | **错名**（F5） |
| `§7.1` 「141 处网络调用点」↔ 所述模式 | **不可复现**（F4） |

---

## §7 Findings（1 medium + 7 low；无 blocker / 无 high）

> 口径：本轮 findings **不改变任何一条实质结论**（门禁、铁律、数值、未运行项全部成立），因此不据此判非 pass；但每一条都应修，且 F1 建议在下一轮一并清掉。

### F1（medium）例外集口径仍有 4 处写「四项」，R1 应为「部分闭环」

- **problem**：`AGENTS.md:104/:143/:164`、`docs/PLAN.md` 7 处、`docs/adr/0001-account-and-sync.md:17`、`B21.correct`/`B42.correct` 都已是**五类**（含「配置下发」），但下列 4 处仍是**四项**：`app/entry/src/main/ets/model/SyncTypes.ets:8`、`app/entry/src/main/ets/viewmodel/net/HttpPort.ets:12`、`README.md:16`、`docs/CHANGELOG.md:116`。其中 `HttpPort.ets` 正是旧正文判「铁律 1 成立」时引用的网络出口文件、`README.md` 是仓库首页对交付形态的描述、`CHANGELOG.md:116` 与同文件 `:100`（写「统一为五类」）自相矛盾。这构成 `AGENTS.md §1.3` 第一条停手条件的形态（同一契约两套表述），且 t29 的 R1「真闭环」与 `§R4` 的「成立」在范围上被高估。
- **requiredFix**：四处按五类改写 —— `SyncTypes.ets:8` / `HttpPort.ets:12` 的注释补「配置下发（`GET /api/v1/config`）」；`README.md:16` 改「例外仅「登录 / 云端同步 / 取价 / 云端备份 / 配置下发」五类」；`docs/CHANGELOG.md:116` 属 v4.1 历史行，保留原文但补一句「※ t21 起为五类（含配置下发），见 §9」。另把 `docs/VERIFICATION.md §7.1` 的结论从「成立」改为「部分闭环（4 处注释/README 残留，见 REVIEW F1）」。
- **file**：`app/entry/src/main/ets/model/SyncTypes.ets` **line**：8

### F2（low）`§R4.3` 两条「沿用上轮」的理由与实测不符

- **problem**：`§R4` 用「`git diff 308d09f..e211ae1 -- app/ server/` 为空」与「本轮 md5 与 round 3 记录同值」支撑「沿用 round 3 的 §4 复算 / §9 契约抽查」。实测前者**非空**（`app/entry/src/ohosTest/resources/rawfile/carbon-calc.json | 4 ++--`，`-- tests/cases/` 亦非空），后者**不同值**（round 3 = `c096da45…`，本轮 = `e096b2db…`）。结论偶然正确、证据全错 —— 这正是「假闭环」的典型形态之一。
- **requiredFix**：把两行理由改为实测成立的那条：`samples`/`capSamples`/`boundarySamples`/`factors`/`constants`/`conversions`/`meta` **7 键逐键 identical=True**（数值区未变）；并注明「`app/`、`server/` 的**源码**零改动，唯一被触碰的是 ohosTest 基准副本（`d228939` 同步）与基准 `docConflicts` 文本」。
- **file**：`docs/VERIFICATION.md` **line**：265、269

### F3（low）`§R4` 首段「一字未删」不成立

- **problem**：`git diff --numstat 39be3b0..284c069 -- docs/VERIFICATION.md` = `511 5`，被删的 5 行含 `V9` 判据行、`F3` 闭环行与两行窄模式假绿证据（t28 的 R3 勘误所需）。删得对，但「一字未删」这句话不实，而它承载「旧结论一律继续有效」的授权。
- **requiredFix**：改为「`§0` 起正文基本保留，**仅 t28 的 R3 勘误处删改 5 行**（V9/F3 判据与窄模式证据，删改内容见 `fccf524`）」，并列出被删改的 5 行位置。
- **file**：`docs/VERIFICATION.md` **line**：6

### F4（low）「141 处网络调用点」不可由所述模式复现，且它不是「调用点」计数

- **problem**：`§7.1`/`V9` 写「`hub.http.request` / `this.http.request` / `HttpPort` 调用共 141 处」。按所述三条模式实测 = 0 + 10 + 44 = **54**。141 实为 `grep -roE 'http|HttpPort'` 的原始 token 计数（97 + 44），其中 97 个 `http` 含注释、`import { http } from '@kit.NetworkKit'`、`HttpRequest`/`HttpResponse` 类型名等，不是调用点。真实调用点 = **11** 处。
- **requiredFix**：把「141 处」改为「调用点 11 处（`grep -rn '\.request(' app/entry/src/main/ets` = 11），逐条归五类，五类之外 0 处」，并删掉 141 这个数（或注明它是「含注释与类型名的 token 计数」，不能当调用点用）。
- **file**：`docs/VERIFICATION.md` **line**：964（另 `:419` 的 V9 行同改）

### F5（low）`§R4.6` 两处函数名标注错误

- **problem**：`§R4.6` 的「全 app 的 `Dec.mul` 落点」表把 `CarbonCalc.ets:258` 标为「树当量」、`:267` 标为「纸张当量」。实测两处函数是 `static amountOfCarFreeDays(days: number, kmPerDay: number): number`（天数 × 单程里程）与 `static amountOfRecyclePieces(pieces: number, kgPerPiece: number): number`（件数 × 单件重量）。全仓 `grep -rn "树当量\|纸张当量"` = **0 命中**。结论（业务乘法无第二个文件）不受影响，但标注是错的。
- **requiredFix**：`:258` 改「少开一天车：天数 × 单程里程（换算成活动量）」、`:267` 改「按件回收：件数 × 单件重量（换算成活动量）」。
- **file**：`docs/VERIFICATION.md` **line**：211

### F6（low）未运行项存在两套编号且无映射

- **problem**：`§R4.7` 用 N1–N5，`§13` 用 N1–N8，二者不同义（R4.7-N3=deploy ↔ §13-N4；R4.7-N4=`/admin` ↔ §13-N5；R4.7-N5=视觉走查 ↔ §13-N8）。而 `§R4.3` 写「§13 未运行 N1–N8 本轮复核（R4.7）」，读者无法对齐。
- **requiredFix**：`§R4.7` 直接沿用 `§13` 的 N1–N8 编号（未运行的仍是原来那 8 条中的 5 条），或在 R4.7 表加一列「对应 §13 编号」。
- **file**：`docs/VERIFICATION.md` **line**：272、274-282

### F7（low）复算与契约脚本仍未入库，证据链易失

- **problem**：`recompute.py`（70 检查点）、`contract.py`、`verify.mjs`、`validator.mjs` 全在 `/tmp/cbv24/ev`、`/tmp/t32` 等易失目录；仓内 `tests/tools/` 只有 `check_l0.py`。round 3 的 `F15` 只解决了「报告入库」，没解决「脚本入库」—— 换台机器就无法复现「70/70」与「契约 A/B/C 全等」。
- **requiredFix**：把三个脚本（独立复算 / 契约逐列比对 / 基准副本一致性校验）提交到 `tests/tools/`，并在 `docs/VERIFICATION.md` 里把命令改为仓内路径。
- **file**：`docs/VERIFICATION.md` **line**：1274（F15 所在节）

### F8（low·信息）`PointCap` 套件名仍无对应文件

- **problem**：契约文本点名的 `PointCap.test.ets` 不存在，封顶 5 组实际由 `CalcSamples.test.ets:78`（`expect(bench.capSamples.length).assertEqual(5)`）与 `CalcBaselineValidator.ets:212-213` 承载。`docs/VERIFICATION.md:341` 已如实记录（F17 复述），`tests/README.md` 已用删除线标注，但契约文本本身未改。
- **requiredFix**：在契约/`tests/README.md` 处把「PointCap 套件」改为「封顶 5 组（由 `CalcSamples.test.ets` + `CalcBaselineValidator.ets` 承载）」。
- **file**：`tests/README.md` **line**：66

---

## §8 未运行项与不可核验项（如实单列，**一条都不算通过**）

### 8.1 五项未运行（环境限制，非实现缺陷）

| 项 | 原因（我本轮复验的原始输出见 §4.2） | 替代证据及其效力 |
|---|---|---|
| **L1 全部 hypium（10 套件 / 36 个 `it()`）** | 无真机（`hdc` 不在 PATH，SDK 内二进制也得 `Connect server failed`）、无模拟器（`/dev/kvm` 不可写）、Previewer 崩于 GLIBC 2.43 | 离线复算 70/70 —— **不等价**：不经过 ArkTS 运行时，只验证基准自洽与独立算术 |
| **L2 端侧集成** | 需两条设备 | 无 |
| **`server/deploy/` 实跑** | 无部署目标（`/opt/carbonboo` 不存在）、`nginx` 未安装 | round 2 的 `bash -n` / `systemd-analyze verify` / `migrate.sh --dry-run`（EXIT=0） |
| **`/admin` 浏览器交互** | `chromium` / `chromium-browser` / `google-chrome` / `playwright` / `chromedriver` **逐个 not found** | HTTP/JSON 层由 `test_admin.py` 85 例覆盖（我复跑 237 passed 内含这 85 例） |
| **视觉模型走查（18 页面截图 + 判图）** | 截图腿同上；判图腿 `ARK_API_KEY` 长度 0 | **无**。用户 m00004「前端子代理须有视觉模型」**仍未满足**，必须在最终交付说明中显式告知 |

> **不要把 `assembleHap BUILD SUCCESSFUL` 读成「L1 用例通过」** —— 36 个 `it()` 本轮**一个都没执行**。编译通过只证明字节可编译、且（经注入自证）业务模块确在编译图内。

### 8.2 无法从仓库核验的过程项（只作队长自述采信，不列为缺陷）

- 「子代理统一 `deepseek-v4.1-flash`」「队长只指派、不亲自开发」「供应商链 ark > commandcode > workbuddy」：提交作者统一为 `CarbonBoo Captain <captain@carbonboo.local>`（个别为 `a3354547604-stack <…@163.com>`），仓库内**无可核验痕迹**。
- 前端 skill：`/mnt/c/Users/Administrator/.dsh/skills/carbonboo-arkui-ui/SKILL.md` **确实存在**（WSL `~/.dsh` 下没有，是路径口径差异，非缺失），且 `app/` 的实现风格与其规范一致 —— 这一条**可核实为已具备**。
- 「视觉模型已用于走查」：全仓 `grep -rn "v4-1-flash\|视觉模型"`（排除 `build/`、`.agent-teams/`）**零命中**，`docs/VERIFICATION.md` 亦无一处提及实际使用 —— 与 N8「零视觉结论」一致，即**未使用过**。

---

## §9 放行建议

1. **可以放行**：三部分（① `app/` ArkTS API 12 鸿蒙客户端 19 页 / 23 组件 / 34 viewmodel / 19 表 / 30+1 因子 / 36 个 L1 用例已登记已编译；② `server/` FastAPI + MySQL 21 表，L3 **237 passed** 全绿；③ `/admin` 七项功能路由齐备、客户端 token 一律 403）实体齐备，六类门禁我全部独立复现，四条铁律静态成立，无测试篡改、无为变绿改期望值。
2. **必须在最终交付说明里显式告知用户的 3 条**（不许圆场）：
   - **L1 的 36 个 `it()` 一条都没跑过**（无真机 / 无模拟器 / Previewer 与 GLIBC 2.43 不兼容）——「编译通过」不等于「用例通过」；
   - **视觉模型走查零达成**（`ARK_API_KEY` 为空），用户 m00004 的这条要求**未满足**；
   - **`/admin` 只到 HTTP 层**，浏览器交互与 `server/deploy/` 实跑均无证据。
3. **建议下一轮用一个极小 `docs:`/`fix:` 提交清掉 F1 + F2 + F3 + F4 + F5 + F6**（全部是文本与标注，零代码行为改动、零数值改动），其中 F1 的 `README.md:16` 与两个 `.ets` 文件头注释是唯一会让读者对「例外集几类」产生错误认知的地方。

---

## §10 与前两轮评审的关系

| 轮次 | 任务 | 基准 commit | 结论 | 本报告的处理 |
|---|---|---|---|---|
| round 1 | t8（`reviewer-cn`） | `39be3b0` | `needs_revision`：R1–R8（2 medium / 6 low） | 8 条已被 t28 修复并被 t29 复核闭环；本报告不再重复，仅在 F1 里指出 R1 的**范围仍被高估**（`四项` 口径未查） |
| round 2 | t29（`reviewer-cn`） | `fccf524` | `pass` + O1–O4（全 low） | O1（副本漂移）已由 `d228939` 修、本轮 §3.2 复验通过；O2（`AGENTS.md:71` 四项）已由 `67e79c8` 修、但**同类残留另在 4 处**（F1）；O3 已由 `e211ae1` 修；O4（脚本未入库）**仍在**（F7） |
| round 3 | **t32（本轮，`reviewer-cn`）** | **`284c069`** | **`pass`（限已跑项）** + F1–F8 | 本文件 |

> 本报告只写 `docs/REVIEW.md` 一个文件；**未修改任何被测源码、规格文档、测试基准，未删改任何断言或期望值，未 skip 任何用例**；未执行 `git stash` / `clean` / `checkout --` / `reset --hard`；**未 push**（推送由队长执行，SHA 见回执）。
