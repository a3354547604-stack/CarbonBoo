# CarbonBoo 独立验证报告（轮次累积 · round 4 = t31 终验见 §R4；round 5 = t38 L1 表述修正见 §R5；**最新 round 6 = t40 最终独立验证见 §R6，结论绑定 HEAD `a8b78ef`**）

> **最新一轮是 §R6（round 6 / t40 最终独立验证，绑定 HEAD `a8b78ef`）。** 下面这段说的是上一轮：
> **round 5 / t38 只做 L1 表述修正，不新增门禁结论。** 起因：t37 把「用 esbuild 转译仓库
> **真实 ArkTS 实现**并在 Node 里离线执行」的链路固化进了仓库（`tests/tools/l1_offline/`），于是本文件里
> 「**替代证据为零**」一类断言从「当时的真话」变成了「**漏报已完成的工作**」。§R5 把这类断言逐处改为准确陈述，
> 并把离线执行证据与 hypium 的边界写死（**只证明纯逻辑真实实现与基准一致；36 个 `it()` 仍未运行；两证不可互相顶替**）。
> §R4 的门禁结论、§0–§15 的历史记录**一条都不动**（只在失真的断言旁加「t38 补记/更正」指针）。

## §R6 round 6（t40 最终独立验证 · 结论绑定 HEAD `a8b78ef` 的字节）

> **本节是本文件最前面新增的一节，也是当前唯一绑定最新字节的结论。** §R4（`e211ae1`）、§R5（`300a89d`）
> 以及 §0 起的 round 3 正文**一字未删**：它们的门禁原始输出仍然有效，只是各自绑定在**更早的 HEAD** 上。
> 本轮把 L0 / L3 全量 / 编译门禁成对自证 / 离线 L1 执行器 / 数值真相源 / 四条铁律 / 规约红线
> **全部在 `a8b78ef` 上重跑**；未运行项（hypium、L2、`server/deploy/` 实跑、`/admin` 浏览器交互、视觉走查）
> 如实单列，**一条都不算通过**。
>
> 之所以要重绑：本团队有旧 verdict（t7 / t24 / t27 / t29 / t32）因其后仍有提交改动被测文件，被判
> 「verdict 覆盖的 revision 已不存在」，Delivery 因此为 blocked。判据是**字节绑定** —— 那几份结论确实
> 没有审过 `a8b78ef` 的字节。本轮即为此补上一次绑定当前字节的独立验证；**本轮不改任何被测字节**，
> 只新增本节（连同文件首行标题与轮次索引一行）。

### R6.1 基准字节（开工第一步，四条原始输出）

```
$ git rev-parse HEAD
a8b78efa505d7643bf20e13674305a332e6925e6

$ git ls-remote origin main
a8b78efa505d7643bf20e13674305a332e6925e6	refs/heads/main

$ md5sum tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  tests/cases/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  app/entry/src/ohosTest/resources/rawfile/carbon-calc.json

$ git status --short
（空 —— 工作树干净；不干净就不开工的前置条件成立）
$ git log --oneline -1
a8b78ef docs: t38 历史段（§10/§13/§14/C-收尾）加 t38 补记 + §R5.7 逐处改动清单
```

- **基准 commit = `a8b78efa505d7643bf20e13674305a332e6925e6`**（完整 40 位，AGENTS.md §5.1-1），
  与任务书给出的 `a8b78ef` 一致。
- 与 `git ls-remote origin main` **双向一致** —— 这是 §5.1-4 规定的「已推送」唯一合格证据
  （向远端要引用、只读、不碰本地缓存）。
- 数值唯一真相源现场实测 md5 = `e096b2db77bbcc9a43ee8728cbd883e9`，根基准与 ohosTest 副本**同值**。
  按 §5.1-2，该值**只作现场留痕、不作门禁期望值**；「本轮有没有动数值」一律以 `git diff` 为准（见 R6.4）。
- **关于「报告入库后 HEAD 会前进」**：本轮的提交只新增本文件 `docs/VERIFICATION.md`；提交后 HEAD 会比
  `a8b78ef` 前进一次，`git diff --name-only a8b78ef..HEAD` 只会出现这一行。所有门禁都是在 `a8b78ef`
  的工作树上实跑的，被测路径自那以后零改动；复现者照 R6.2 的命令在 `a8b78ef` 上重跑即得同样结果。

### R6.2 本轮实跑（六条门禁，逐条原始结果）

| # | 门禁 | 命令 | 结果 |
|---|---|---|---|
| **R6-a** | L0 文档与数值一致性 | `python3 tests/tools/check_l0.py --strict`（`$?` 单独取） | **EXIT=0** |
| **R6-b** | L3 服务端全量 | `cd server && CARBONBOO_TEST_DB=carbonboo_test_final .venv/bin/python -m pytest tests/ -q` | **237 passed / EXIT=0**，218.64s |
| **R6-c** | 编译门禁基线 | `cd app && source ~/harmony-toolchain/env.sh && export OHOS_BASE_SDK_HOME=$DEVECO_SDK_HOME && hvigorw --no-daemon assembleHap` | **BUILD SUCCESSFUL / EXIT=0** |
| **R6-d** | 编译门禁注入（未定义**引用**） | 同上（注入一行未定义引用后） | **BUILD FAILED / EXIT=255**，自定位 `SyncService.ets:39:32` |
| **R6-e** | 编译门禁撤回 | 同上（`cp` 备份还原后） | **BUILD SUCCESSFUL / EXIT=0**，`CompileArkTS` 真实重编 25s947ms |
| **R6-f** | 离线 L1 执行器（t37 入库） | `bash tests/tools/l1_offline/run.sh` | **RUN_EXIT=0**，`RESULT: PASS=55 FAIL=0`；`checked = 323 / passed = true` |

#### R6-a · L0（`$?` 单独取值，不读管道尾值）

```
$ python3 tests/tools/check_l0.py --strict > /tmp/t40_l0.txt 2>&1; echo "L0_EXIT=$?"
L0_EXIT=0

$ cat /tmp/t40_l0.txt
========================================================================
L0-1 数值基准自检（tests/cases/carbon-calc.json）
========================================================================
检查项：28    错误：0
  OK：18 组正向样例 / 5 组封顶 / 边界样例全部自洽

========================================================================
L0-2 文档已知冲突扫描（docs/）
========================================================================
扫描文件：89    命中：0

L0-3 人工待修清单（tests/cases/carbon-calc.json → docConflicts）：0 条

========================================================================
结论：PASS —— 基准自洽，文档无已知冲突
```

三项原值：**L0-1 检查项 28 / 错误 0**、**L0-2 扫描文件 89 / 命中 0**、**L0-3 待修 0 条**；退出码由 `$?`
**单独取得**（未经过任何管道，避免「读管道尾值」的假绿）。

#### R6-b · L3 全量（R6-b）

```
$ cd server && CARBONBOO_TEST_DB=carbonboo_test_final ./.venv/bin/python -m pytest tests/ -q
........................................................................ [ 30%]
........................................................................ [ 60%]
........................................................................ [ 91%]
.....................                                                    [100%]
=============================== warnings summary ===============================
.venv/lib/python3.11/site-packages/fastapi/testclient.py:1
  .../fastapi/testclient.py:1: StarletteDeprecationWarning: Using `httpx` with `starlette.testclient` is deprecated; install `httpx2` instead.
    from starlette.testclient import TestClient as TestClient  # noqa

-- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html
237 passed, 1 warning in 218.64s (0:03:38)
L3_EXIT=0
```

逐文件用例数（`pytest <file> --collect-only -q` 尾行原值）：

```
85 tests collected in 1.52s   tests/test_admin.py
40 tests collected in 0.56s   tests/test_auth.py
29 tests collected in 1.17s   tests/test_authz.py
25 tests collected in 1.72s   tests/test_config.py
10 tests collected in 1.98s   tests/test_shop.py
48 tests collected in 0.40s   tests/test_sync.py
```

**85 + 40 + 29 + 25 + 10 + 48 = 237**，与 `237 passed` 完全吻合（无 skip / xfail / 收集遗漏）。

环境口径（本轮实测，非转抄）：

- `server/.venv/bin/python` = **Python 3.11.17**；`pytest 9.1.1`；
  `CARBONBOO_TEST_DB=carbonboo_test_final`（**本轮验证者专属库名**，避免与他人共用库撞出
  `1412 Table definition has changed` 或 InnoDB `1213` 死锁造成的假失败）。
- MySQL 走 TCP `127.0.0.1:13307` → 容器 `carbonboo-mysql`。`docker ps` 原文：
  `carbonboo-mysql	33060/tcp, 127.0.0.1:13307->3306/tcp	Up 22 hours`；
  **不是** `13306`（那是别人的容器 `cb-mysql	0.0.0.0:13306->3306/tcp	Up 28 hours`）。
- 凭据取自 `server/.env`（`MYSQL_HOST=127.0.0.1` / `MYSQL_PORT=13307` / `MYSQL_USER=carbonboo`，密码打码），
  **不是**任务书历史版本里写过的 `root/cbpass123`（该组合前几轮实测 1045 被拒，见 F18）。
- 唯一 warning 是第三方 `fastapi.testclient` 的弃用提示，**与被测代码无关**。

#### R6-c / R6-d / R6-e · 编译门禁成对自证（本轮自己跑、自己注入、自己还原）

注入点选在 `app/entry/src/main/ets/viewmodel/net/SyncService.ets` —— **import 区之后的有效代码区（第 39 行）**，
不是插进 `/** */` 注释块（插进注释会 BUILD SUCCESSFUL，那是假绿，前几轮已有人踩过）。
注入前先落证据，证明该行确实在有效代码区：

```
$ sed -n '37,41p' app/entry/src/main/ets/viewmodel/net/SyncService.ets
import { JsonArray, JsonObject, asArray, asObject, num, optNum, optStr } from '../../util/JsonUtil';
import { AppResult, fail, ok } from '../../model/Result';

/** 协同页顶部卡片的数据（附录 C §18.1）。 */
export interface SyncStatus {
```

注入的一行（`sed -i '39i ...'`）：

```
const VFY_GATE_PROBE: number = VFY_UNDEFINED_PROBE_SYMBOL + 1;
```

**① 基线（未注入）：**

```
$ hvigorw --no-daemon assembleHap
> hvigor UP-TO-DATE :entry:default@CompileArkTS...
> hvigor BUILD SUCCESSFUL in 5 s 240 ms
BASE_EXIT=0
```

> 诚实标注：这条基线是**增量构建**（`CompileArkTS` 显示 `UP-TO-DATE`、总耗时 5.2s），
> 它只能证明「当前字节的产物是最新的」，**不足以单独证明从零全量可编译**。真正的编译段证据在 ③。

**② 注入后（必须 FAILED）：**

```
> hvigor ERROR: Failed :entry:default@CompileArkTS...
> hvigor ERROR: ArkTS Compiler Error
1 ERROR: ArkTS:ERROR File: /mnt/c/Users/Administrator/Desktop/CarbonBoo/app/entry/src/main/ets/viewmodel/net/SyncService.ets:39:32
 Cannot find name 'VFY_UNDEFINED_PROBE_SYMBOL'.
COMPILE RESULT:FAIL {ERROR:2}
> hvigor ERROR: BUILD FAILED in 21 s 228 ms
PROBE_EXIT=255
```

判据三条全部满足：`Cannot find name 'VFY_UNDEFINED_PROBE_SYMBOL'` 出现 ✓；`BUILD FAILED` 出现 ✓；
报错**自定位到 `文件:行:列` = `SyncService.ets:39:32`** ✓（列 32 正是那个未定义符号的起始列）。**EXIT=255** ✓。
注意探针是**未定义引用**（`VFY_UNDEFINED_PROBE_SYMBOL + 1`）而不是纯声明 —— 纯声明是合法代码，永远不会失败。

**③ `cp` 备份还原后（必须 SUCCESSFUL，且字节与 HEAD 一致）：**

```
$ cp /tmp/SyncService.ets.t40bak app/entry/src/main/ets/viewmodel/net/SyncService.ets
$ md5sum app/entry/src/main/ets/viewmodel/net/SyncService.ets
d0fce64796fa5d901b243cc926616980  app/entry/src/main/ets/viewmodel/net/SyncService.ets
$ git show HEAD:app/entry/src/main/ets/viewmodel/net/SyncService.ets | md5sum
d0fce64796fa5d901b243cc926616980  -
$ cmp -s app/entry/src/main/ets/viewmodel/net/SyncService.ets /tmp/SyncService.ets.t40bak
CMP_BAK=identical
$ git status --short
（空）
$ hvigorw --no-daemon assembleHap
> hvigor Finished :entry:default@CompileArkTS... after 25 s 947 ms
> hvigor BUILD SUCCESSFUL in 30 s 556 ms
RESTORE_EXIT=0
```

两侧 EXIT 码：**注入侧 255 / 撤回侧 0**。还原后文件 md5 与 `git show HEAD:<path>` **逐字节一致**
（同 md5 `d0fce647…`，且 `cmp -s` 与备份副本比对通过），`git status --short` 仍为空 → **零污染**。
③ 里 `CompileArkTS` 是**真实执行**（25s947ms，不是 UP-TO-DATE），所以「还原后的字节确实能编译」有真实编译段背书。
探针残留核查：`grep -rn "VFY_GATE_PROBE\|VFY_UNDEFINED_PROBE_SYMBOL" app/entry/src/` → **0 命中**。

#### R6-f · 离线 L1 执行器（`tests/tools/l1_offline/`，t37 入库）

```
$ bash tests/tools/l1_offline/run.sh
== l1_offline：离线执行仓库真实 ArkTS 实现 ==
仓库 HEAD   : a8b78efa505d7643bf20e13674305a332e6925e6
esbuild     : /home/qinyixiang/harmony-toolchain/esbuild/bin/esbuild
node        : .../tool/node/bin/node (v18.20.1)
-- ① 消费仓库真实源文件（原样复制，逐字节 cmp） --
   ok(未改写)  app/entry/src/main/ets/util/DecimalUtil.ets  ->  main/ets/util/DecimalUtil.ts
   ok(未改写)  app/entry/src/main/ets/util/AppConstants.ets  ->  main/ets/util/AppConstants.ts
   ok(未改写)  app/entry/src/main/ets/util/JsonUtil.ets  ->  main/ets/util/JsonUtil.ts
   ok(未改写)  app/entry/src/main/ets/util/StringUtil.ets  ->  main/ets/util/StringUtil.ts
   ok(未改写)  app/entry/src/main/ets/model/CarbonTypes.ets  ->  main/ets/model/CarbonTypes.ts
   ok(未改写)  app/entry/src/main/ets/service/CarbonCalc.ets  ->  main/ets/service/CarbonCalc.ts
   ok(未改写)  app/entry/src/main/ets/service/CarbonService.ets  ->  main/ets/service/CarbonService.ts
   ok(仅改 import 前缀 …/test/CalcTestTypes.ets -> test/CalcTestTypes.ts)
   ok(仅改 import 前缀 …/test/CalcBaselineValidator.ets -> test/CalcBaselineValidator.ts)
-- ④ bundle 输入文件断言 --
   实际输入(8): main/ets/service/CarbonCalc.ts, main/ets/service/CarbonService.ts, main/ets/util/AppConstants.ts,
                main/ets/util/DecimalUtil.ts, main/ets/util/JsonUtil.ts, main/ets/util/StringUtil.ts,
                test/CalcBaselineValidator.ts, test/CalcTestTypes.ts
   ok: 8/8 运行期输入 + 1 个纯类型文件（合计 9/9）全部来自仓库真实源文件
   ok: tests/tools/ 里没有一行算法 —— 转译产物完全由 app/ 下那 9 份 .ets 决定
   samples(18×2)        PASS=36 FAIL=0
   capSamples(5×2+1)    PASS=11 FAIL=0
   conversions(2)       PASS=2 FAIL=0
   boundary 20/21/22(6) PASS=6 FAIL=0
RESULT: PASS=55 FAIL=0
   消费真实实现 : .../out/validator.cjs
   checked = 323
   passed  = true
   summary = 全部一致：共复算 323 个断言点
RESULT: checked=323 passed=true mismatches=0
RUN.SH: 全部 PASS（离线纯逻辑部分）
RUN_EXIT=0
```

- 执行器第一行就打印**仓库 HEAD = `a8b78ef…`**，即本轮这份 L1 离线证据与该基准**同一次采样**。
- **边界（与 §R5 同口径，不可退回旧写法）**：这条证据只覆盖**纯逻辑**（计算 / 舍入 / 封顶 / 转译执行真实实现），
  **不覆盖** UI、DB、网络、生命周期；它**不能折算成任何 hypium `it()` 通过**。
  因此本节 N1 的准确表述是「**hypium 未运行；纯逻辑部分另有独立离线证据 55 项 + 323 个断言点，两条证据不可互相顶替**」，
  而**不是**已经删掉的那句失真断言「替代证据为零」。

### R6.3 数值真相源零改动

```
$ git diff 300a89d..HEAD -- tests/cases/carbon-calc.json
（空 —— 自 t37 起该文件一字未动）

$ md5sum tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  tests/cases/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  app/entry/src/ohosTest/resources/rawfile/carbon-calc.json

$ cmp tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
CMP_EXIT=0 字节相同

$ git diff --name-only
（空）

$ git status --short
（空）
```

- 基准 commit `300a89d` = `docs: t37 tests/README.md 登记离线执行器 —— 一行说明 + 「不能替代 hypium」边界`。
- `git diff 300a89d..HEAD -- tests/cases/carbon-calc.json` **为空** ⇒ 自 t37 起数值真相源零改动
  （AGENTS.md §5.1-3 的判据是 `git diff`，不是 md5 相等）。
- 根基准与 ohosTest 副本**同 md5**（`e096b2db…`）且 `cmp` 逐字节相同 ⇒ 上一轮 `d228939` 修掉的副本漂移没有复发。
- **本文件（`docs/VERIFICATION.md`）的 diff 单列**：本轮只**追加** §R6 一节 + 改首行标题 + 轮次索引加一行，
  §R4 / §R5 与 §0–§15 的原文一字未删；**未触碰** `tests/cases/carbon-calc.json` / 任何 APPENDIX /
  `AGENTS.md` / `docs/PLAN.md` / `docs/REVIEW.md` / `app/` / `server/` / `tests/`。

### R6.4 规约红线（AGENTS.md §7.1：`app/` 内三项计数，均须为 0）

```
$ grep -rn ': any' --include='*.ets' app | grep -v '/build/' | grep -v '/\.test/' | wc -l
0
$ grep -rn '@ts-ignore' --include='*.ets' app | grep -v '/build/' | grep -v '/\.test/' | wc -l
0
# 非相对 import，排除 @ohos / @kit（AGENTS.md §7.1 禁止第三方包）
$ grep -rnE "^import .* from ['\"]" --include='*.ets' app | grep -v '/build/' | grep -v '/\.test/' \
    | grep -vE "from ['\"]\.\.?/" | grep -vE "from ['\"]@(ohos|kit)" | wc -l
0
```

三项全 0：`: any` = **0**、`@ts-ignore` = **0**、非相对 import（排除 `@ohos`/`@kit`）= **0**。
（第三条的逐条打印为「零命中」，即没有任何一条需要人工豁免。）

### R6.5 四条铁律静态核对（各给 `文件:行`）

**① 单一计算入口（铁律 2）**

| 断言 | 证据 |
|---|---|
| 唯一 `calculate` 入口 | `app/entry/src/main/ets/service/CarbonService.ets:76` `static calculate(activity: ActivityInput, factor: FactorSnapshot, options?: CalcOptions): CarbonCalculation` |
| 唯一因子乘法 | `app/entry/src/main/ets/service/CarbonCalc.ets:153` `const product: Dec = Dec.from(amount).mul(Dec.from(factorValue));` |
| 全 app 的 `Dec.mul` 落点 | `CarbonCalc.ets:153`（活动量 × 因子）、`:164`（kg × 100 求 C）、`:258`（免车天数的量）、`:267`（回收件数的量）—— **四处全在同一文件**，业务乘法没有第二个文件 |
| `pages/` + `components/` 零命中 | `grep -rnE "calculate\|Dec\.from\|DecimalUtil"` 于 `pages/` + `components/` = **0 命中** |
| 页面只展示、不计算 | `pages/`/`components/` 里出现 `factor` 字样的全部是**格式化读取/字段声明**：`pages/RecordDetailPage.ets:141` `Formatter.number(this.record.factorValue, 'factor')`、`pages/RecordEditPage.ets:536` 同式、`components/RecordItem.ets:15` 字段声明，无乘法、无因子取值 |

**② 因子快照四字段 NOT NULL（铁律 3）**

`app/entry/src/main/ets/data/schema/ClientSchema.ets`（`CREATE TABLE IF NOT EXISTS carbon_record`，:76 起）：

```
:85  factor_value    REAL    NOT NULL,          -- 因子快照（铁律 3）
:86  factor_version  TEXT    NOT NULL,
:87  factor_source   TEXT    NOT NULL,
:88  confidence      TEXT    NOT NULL,          -- verified | provisional
```

四列齐备且全部 `NOT NULL`。写入侧唯一构造点 `service/CarbonService.ets:187` `static snapshotOf(...)`，
调用点 `viewmodel/RecordService.ets:149` / `:306` / `:367`（新增、编辑、补记三条链路）。

**③ 流水只增不删（铁律 4 上）**

```
$ grep -rEn "(UPDATE|DELETE)[[:space:]]+(FROM[[:space:]]+)?point_record" \
    --include='*.ets' --include='*.ts' --include='*.py' --include='*.sql' \
    --exclude-dir=build --exclude-dir=.test --exclude-dir=node_modules --exclude-dir=oh_modules --exclude-dir=.git .
（无输出 —— 0 命中）
```

源码树 **0 命中**（逐条计数 `UPDATE point_record` / `UPDATE FROM point_record` / `DELETE FROM point_record`
三种口径均为 0）。唯一命中出现在 `app/entry/build/**` 与 `app/entry/.test/**` 的**编译产物/测试缓存的既有字符串**里
（那是构建输出，不是被测源码；被测源字节由 `git status --short` 为空背书）。

- 唯一写入点：`viewmodel/PointService.ets:153` `'INSERT OR IGNORE INTO point_record '`（幂等键
  `uq_pr_source(user_id, source_type, source_id, flow_kind)`，见 `ClientSchema.ets:141`）。
- 冲正不删行、写负额新行：`PointService.ets:190` `async reverse(...)` → `:196` `points: -points`。

**④ 余额同口径 `COALESCE(SUM(points),0)`（铁律 4 下）**

| # | 位置 | 作用 |
|---|---|---|
| 1 | `app/entry/src/main/ets/viewmodel/PointService.ets:91` | 余额（`inc` / `spent` / `bal` 同一条 SQL，`bal` = `COALESCE(SUM(points), 0)`） |
| 2 | `app/entry/src/main/ets/viewmodel/net/SyncService.ets:362` | 家庭合并 · 单设备积分（`... AND COALESCE(device_id, '') = ?`） |
| 3 | `app/entry/src/main/ets/viewmodel/net/SyncService.ets:377` | 家庭合并 · 合计积分 |

三处**同口径**：都对 `point_record.points`（本身已带符号）直接 `SUM`，**不做** `flow_kind` 二次取负
（round 1 的 F1 正是这个双重取负，已修）。另有同式但非「余额」语义的四处：
`PointService.ets:121` / `:136` / `:235`、`server/admin_web/services/stats.py:90`；以及用例内的独立复算
`app/entry/src/ohosTest/ets/test/LwwMerge.test.ets:648`（**未运行**，见 R6.6-N1）。

### R6.6 未运行项（**一条都不算通过**）

| 编号 | 项 | 未运行的具体原因（本轮实测原始输出） |
|---|---|---|
| **N1** | **L1 全部 hypium（10 套件 / 36 个 `it()`）** | 三座桥全断 + `hvigorw test` 实测超时被 `timeout` 杀掉（`TEST_EXIT=124`），见下方原文。**hypium 侧零执行**：编译通过 ≠ 用例通过，本轮不给 L1 任何通过判定。**纯逻辑部分另有一条独立离线证据**（R6-f：`RESULT: PASS=55 FAIL=0`、`checked=323 passed=true`），但**它不改变本行结论**：36 个 `it()` 仍然一条都没执行 |
| **N2** | L2 端侧集成（云通路 + 近场通路两条链路） | 需**两条设备**（或真机 + 模拟器）。N1 的三条环境断点直接否决；本机 `command -v emulator` → **EXIT=1（无输出）**。本轮未跑 |
| **N3** | `server/deploy/` 实跑（systemd / nginx / TLS / 定时备份） | 无部署目标：`ls -d /opt/carbonboo` → `No such file or directory`（EXIT=2）；`command -v nginx` → **EXIT=1（未安装）**。`systemctl is-system-running` → `running`、`docker ps` 可用，但部署目标与 nginx 不存在，**不能算跑过**。本轮未跑 |
| **N4** | `/admin` 浏览器交互（SSR 渲染、`admin.js` 前端行为） | 无浏览器驱动：`chromium` / `chromium-browser` / `google-chrome` / `playwright` / `chromedriver` / `firefox` **逐个 not found**。HTTP/JSON 层由 L3 `test_admin.py`（85 例全过）覆盖，但**渲染与 JS 交互未跑** |
| **N5** | 视觉模型走查（18 页面截图 + 判图） | 截图腿：同 N1（无设备 / 无模拟器 / Previewer 与 GLIBC 2.43 不兼容）。判图腿：`ARK_API_KEY` 在本会话**未设置**（`len=0`，`.dsh/.env` 与 `~/.dsh/.env` 均不存在），空 key 打端点得 **HTTP=400**（原文见下）。⇒ **本轮零视觉结论** |

**N1 的环境断点与本轮实跑原文（逐条）：**

```
# ① PATH 里没有 hdc
$ command -v hdc; echo "which_EXIT=$?"
which_EXIT=1

# ② SDK 里确有 hdc 二进制，但连不上设备服务端
$ $HARMONY_TOOLCHAIN/sdk/default/openharmony/toolchains/hdc list targets
Connect server failed
（stdout 无任何设备行）

# ③ 无模拟器：/dev/kvm 存在但当前用户不可写
$ ls -l /dev/kvm
crw-rw---- 1 root kvm 10, 232 Oct 14 22:10 /dev/kvm
$ [ -w /dev/kvm ] && echo WRITABLE || echo NOT_WRITABLE
NOT_WRITABLE
$ id
uid=1000(qinyixiang) gid=1000(qinyixiang) groups=1000(qinyixiang),4(adm),24(cdrom),27(sudo),30(dip),46(plugdev),100(users),1001(docker)
$ command -v emulator; echo "EMU_EXIT=$?"
EMU_EXIT=1

# ④ Previewer 与 GLIBC 2.43 冲突
$ ldd --version | head -1
ldd (Ubuntu GLIBC 2.43-2ubuntu2.4) 2.43
$ .../previewer/common/bin/Previewer
[INFO][RichPreviewer.cpp][main][99]:RichPreviewer enter the main function.
[ERROR][CommandParser.cpp][IsAppPathValid][319]:Launch -j parameters abnormal!
[ERROR][CommandParser.cpp][IsCommandValid][135]:No app path specified.
[FATAL][CommandParser.cpp][ParseArgs][1008]:Start args is invalid.
PREVIEWER_PIPE_EXIT=11
（按 round 1/2 留档，带 `-j <app>` 真正拉起页面时崩在 glibc 2.43 的 pthread_mutex_lock robust 断言；
本轮无参直跑只走到参数校验段，故**无法在本条命令里复现该断言 —— 如实标注，不冒充已复现**）

# ⑤ 本轮直接把 hypium 跑了一次（唯一一次，420s 上限）
$ cd app && source ~/harmony-toolchain/env.sh && hvigorw --no-daemon test
> hvigor Finished :entry:default@UnitTestArkTS... after 23 s 196 ms
> hvigor Linux
TEST_EXIT=124
（= 被 `timeout 420` 杀死：用例档案编译成功，但设备/Previewer 拉起阶段无进展、无任何用例被执行）
```

**N1 的逐套件 `it()` 计数（`grep -oE "\bit\("`，合计 36；`describe(` 合计 10）：**

```
 1  BackupRoundTrip.test.ets        1  BadgeIdempotent.test.ets      6  CalcSamples.test.ets
 1  CsvExport.test.ets             1  GoalIdempotent.test.ets      10  LwwMerge.test.ets
 1  NotLoggedIn.test.ets           8  ServerConfigFallback.test.ets 6  ShopPriceFallback.test.ets
 1  ShopPurchase.test.ets          0  List.test.ets（登记入口，不含用例）
合计 36 个 it() / 10 个 describe —— 本轮**执行数 0**
```

**N5 判图腿的原始输出：**

```
$ echo "ARK_API_KEY=[${ARK_API_KEY:-<unset>}]"; echo "len=${#ARK_API_KEY}"
ARK_API_KEY=[<unset>]
len=0
$ ls -l .dsh/.env ~/.dsh/.env
ls: cannot access '.dsh/.env': No such file or directory
ls: cannot access '/home/qinyixiang/.dsh/.env': No such file or directory
$ curl -sS -m 25 -w 'HTTP=%{http_code}\n' https://ark.cn-beijing.volces.com/api/v3/chat/completions \
    -H 'Content-Type: application/json' -H "Authorization: Bearer ${ARK_API_KEY}" \
    -d '{"model":"doubao-vision-pro-32k","messages":[{"role":"user","content":"ping"}]}'
HTTP=400
{"error":{"code":"InvalidParameter","message":"The parameter `` specified in the request are not valid: invalid parameter: AuthHeader. …","param":"","type":"BadRequest"}}
```

> **未运行 = 不算通过。** 上表五项在本轮**没有任何一条**被计入「通过」。尤其不要把「`assembleHap`
> BUILD SUCCESSFUL」说成「L1 用例通过」——那 36 个 `it()` 本轮**一个都没执行**；也不要把
> `l1_offline` 的 55 项说成 hypium 通过（两者覆盖面不同，见 R6-f 的边界段）。

### R6.7 本轮未决问题

1. **hypium 仍是零执行**：无真机、无模拟器（`/dev/kvm` 不可写）、Previewer 与 GLIBC 2.43 不兼容；
   本轮实跑 `hvigorw test` 得 `TEST_EXIT=124`（超时杀）。在拿到设备或修好兼容性前，
   36 个 `it()` 只能算「已编写、已登记、已编译」。纯逻辑部分由 `tests/tools/l1_offline/` 独立佐证，**两证不可互相顶替**。
2. **视觉走查仍是零达成**（N5）：`ARK_API_KEY` 缺失。这是用户明示要求，交付说明里必须写明未满足，不能沉默处理。
3. **`/admin` 只到 HTTP 层**：85 条 `test_admin.py` 全过证明后端行为，但「浏览器里点得动」没有证据（N4）。
4. **`server/deploy/` 未实跑**（N3）：脚本存在但无部署目标与 nginx，属「已编写未执行」。
5. **旧 verdict 漂移**：本节的用途就是把结论重新绑到 `a8b78ef`。**本节入库后，请不要再用任何提交改动
   `app/`、`server/`、`tests/`、`AGENTS.md`、规格文档或基准** —— 一旦改动，本节与本文件 §R4/§R5 都会再次漂移
   （判据见 Delivery 的 sha256 比对）。
6. **审批与推送**：本轮**只写本文件**，不 push；推送由队长执行。`ls-remote` 与本地 HEAD 现为同一 SHA。

### R6.8 AGENTS.md §8 格式对照（任务 → 改了什么 → 跑了什么命令 → 结果 → 未决问题）

- **任务**：对 `HEAD=a8b78ef` 的字节做一次绑定当前版本的最终独立验证（L0、L3 全量、编译门禁成对自证、
  离线 L1 执行器、数值真相源零改动、四条铁律静态核查），并如实单列未运行项；结论写入 `docs/VERIFICATION.md`。
- **改了什么**：**只有 `docs/VERIFICATION.md` 一个文件**（新增本节 §R6 于文件开头；首行标题补「round 6 = t40」；
  轮次索引新增 round 6 一行）。**未改**任何被测源码 / 规格文档 / 测试基准 / `tests/cases/` / `tests/tools/`。
- **跑了什么命令**：`git rev-parse HEAD`、`git ls-remote origin main`、`md5sum`（基准两份副本）+ `cmp`、
  `git status --short`、`git diff 300a89d..HEAD -- tests/cases/carbon-calc.json`、
  `python3 tests/tools/check_l0.py --strict`（`$?` 单独取）、
  `cd server && CARBONBOO_TEST_DB=carbonboo_test_final ./.venv/bin/python -m pytest tests/ -q`、
  `pytest <file> --collect-only -q`（6 个文件逐个数）、
  `cd app && source ~/harmony-toolchain/env.sh && export OHOS_BASE_SDK_HOME=$DEVECO_SDK_HOME && hvigorw --no-daemon assembleHap`
  （基线 / 注入 / 还原 三次；注入用 `sed -i '39i …'`）、`bash tests/tools/l1_offline/run.sh`、
  各项 `grep` 计数、`hdc list targets`、`[ -w /dev/kvm ]`、`ldd --version`、`Previewer`、`hvigorw --no-daemon test`、
  `command -v emulator/nginx/chromium/…`、`ls -d /opt/carbonboo`、`curl` ark 端点。
- **结果**：L0 **EXIT=0**（28 项 0 错误 / 89 文件 0 命中 / docConflicts 0）；L3 **237 passed / EXIT=0**，218.64s
  （85+40+29+25+10+48）；编译门禁 **0 → 255 → 0**（注入侧自定位 `SyncService.ets:39:32`；还原后 md5 与
  `git show HEAD` 同值 `d0fce647…`）；离线 L1 **`RESULT: PASS=55 FAIL=0`、`checked=323 passed=true`**；
  数值真相源 **零改动**（`git diff 300a89d..HEAD` 为空）、两副本 md5 同值且 `cmp` 相同；
  规约红线 **0/0/0**；四条铁律**静态全部成立**（各给 `文件:行`）。
  **未运行**：L1 全部 `it()`、L2、`server/deploy/` 实跑、`/admin` 浏览器交互、视觉模型走查 —— 五项一条都不算通过。
- **未决问题**：见 R6.7。

---

## §R4 round 4（t31 终验 · 结论绑定 HEAD `e211ae1` 的字节）

> **本节是文件最前面新增的一节，也是**唯一**绑定当前字节的结论。** §0 起的正文仍是 round 3（t24，基准 `308d09f`）的原文，
> **一字未删**：其中的「独立复算 70/70」「编译门禁四组注入自证」「契约 A/B/C 全等」「F15–F18」等仍然是有效的原始记录，
> 本轮不推翻它们，只在**一条不再变动的 HEAD** 上重跑关键门禁并把结论重新绑到该 HEAD 上。
>
> 之所以要重绑：t24 / t27 / t29 三份结论都形成于工作区仍在变动的时刻，其后又落了 5 个提交
> （`c58b702` → `fccf524` → `d228939` → `67e79c8` → `e211ae1`），调度器因此判「verdict 覆盖的 revision 已不存在」。
> 本轮把 L0 / L3 全量 / 编译门禁成对自证 / 数值真相源 / 四条铁律 / 规约红线**全部在 `e211ae1` 上重跑**，
> 未运行项（L1 / L2 / deploy / `/admin` 浏览器 / 视觉走查）如实单列、**一条都不算通过**。

### R4.1 基准字节（开工第一步，四条原始输出）

```
$ git rev-parse HEAD
e211ae143a04922952693adf2262cc9feae2e9b4

$ git ls-remote origin main
e211ae143a04922952693adf2262cc9feae2e9b4	refs/heads/main

$ md5sum tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  tests/cases/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  app/entry/src/ohosTest/resources/rawfile/carbon-calc.json

$ git status --short
（空 —— 工作树干净；不干净就不开工的前置条件成立）
```

- **基准 commit = `e211ae143a04922952693adf2262cc9feae2e9b4`**（完整 40 位，AGENTS.md §5.1-1）。
- 与 `git ls-remote origin main` **双向一致** —— 这是 §5.1-4 规定的「已推送」唯一合格证据（读远端引用，不是本地缓存）。
- 数值唯一真相源现场实测 md5 = `e096b2db77bbcc9a43ee8728cbd883e9`，根基准与 ohosTest 副本**同值**。
  按 §5.1-2，该值**只作现场留痕、不作门禁期望值**；「本轮有没有动数值」一律以 `git diff` 为准（见 R4.4）。
- `git log --oneline` 顶行：`e211ae1 docs: O3 修正 VERIFICATION §7.1 两处行文瑕疵（错标 id + 计数口径）`。
- **关于「报告入库后 HEAD 会前进」**：本轮的报告提交只新增本文件 `docs/VERIFICATION.md`；提交后 HEAD 会比 `e211ae1`
  前进一次，而 `git diff --stat e211ae1..HEAD` 只有 `docs/VERIFICATION.md`（本文件）这一行。这是「结论入库」的必然结果，
  **不改变被测字节的绑定**：所有门禁（L0 / L3 全量 / 编译门禁 / md5 / 四条铁律 / 规约红线）都是在 `e211ae1` 的工作树上实跑的，
  被测路径自那以后零改动；复现者照 R4.2 的命令在 `e211ae1` 上重跑即得同样结果。

### R4.2 本轮实跑（五条门禁，逐条原始结果）

| # | 门禁 | 命令 | 结果 |
|---|---|---|---|
| **R4-a** | L0 文档与数值一致性 | `python3 tests/tools/check_l0.py --strict` | **EXIT=0** |
| **R4-b** | L3 服务端全量 | `cd server && CARBONBOO_TEST_DB=carbonboo_test_vfy .venv/bin/python -m pytest tests/ -q` | **237 passed / EXIT=0**，196.96s |
| **R4-c** | 编译门禁基线 | `cd app && source ~/harmony-toolchain/env.sh && export OHOS_BASE_SDK_HOME=$DEVECO_SDK_HOME && hvigorw --no-daemon assembleHap` | **BUILD SUCCESSFUL / EXIT=0** |
| **R4-d** | 编译门禁注入（未定义引用） | 同上（注入 `VFY_UNDEFINED_PROBE_SYMBOL` 后） | **BUILD FAILED / EXIT=255**，报错自定位 `SyncService.ets:39:32` |
| **R4-e** | 编译门禁撤回 | 同上（`cp` 备份还原后） | **BUILD SUCCESSFUL / EXIT=0**，`CompileArkTS` 真实重编 23s644ms |

#### R4-a · L0（`$?` 单独取值，不读管道尾值）

```
$ python3 tests/tools/check_l0.py --strict > /tmp/l0_out.txt 2>&1
$ echo "L0_EXIT=$?"
L0_EXIT=0

（输出原文）
========================================================================
L0-1 数值基准自检（tests/cases/carbon-calc.json）
========================================================================
检查项：28    错误：0
  OK：18 组正向样例 / 5 组封顶 / 边界样例全部自洽

========================================================================
L0-2 文档已知冲突扫描（docs/）
========================================================================
扫描文件：89    命中：0

L0-3 人工待修清单（tests/cases/carbon-calc.json → docConflicts）：0 条

========================================================================
结论：PASS —— 基准自洽，文档无已知冲突
```

三项原值：**L0-1 检查项 28 / 错误 0**；**L0-2 扫描文件 89 / 命中 0**；**L0-3 待修 0 条**。
（round 3 报告中此三值为 `28 / 0`、`82 / 0`、`0`，扫描文件数由 82 增至 89 —— 是 round 3 之后新增/改动的文档被扫进来了，属正常增长。）

#### R4-b · L3 全量（专属隔离库，不与他人共用）

```
$ cd server && CARBONBOO_TEST_DB=carbonboo_test_vfy .venv/bin/python -m pytest tests/ -q
........................................................................ [ 30%]
........................................................................ [ 60%]
........................................................................ [ 91%]
.....................                                                    [100%]
=============================== warnings summary ===============================
.venv/lib/python3.11/site-packages/fastapi/testclient.py:1
  /mnt/c/Users/Administrator/Desktop/CarbonBoo/server/.venv/lib/python3.11/site-packages/fastapi/testclient.py:1: StarletteDeprecationWarning: Using `httpx` with `starlette.testclient` is deprecated; install `httpx2` instead.
    from starlette.testclient import TestClient as TestClient  # noqa
-- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html
237 passed, 1 warning in 196.96s (0:03:16)
PIPE_EXIT=0
```

逐文件用例数（`pytest tests/ --collect-only -q | grep '::' | sed 's/::.*//' | sort | uniq -c`，收集 237 条，EXIT=0）：

```
     85 tests/test_admin.py
     40 tests/test_auth.py
     29 tests/test_authz.py
     25 tests/test_config.py
     10 tests/test_shop.py
     48 tests/test_sync.py
```

**85 + 40 + 29 + 25 + 10 + 48 = 237**，与 `237 passed` 完全吻合（无 skip / xfail / 收集遗漏）。

环境口径（本轮实测，非转抄）：
- `server/.venv/bin/python` = **Python 3.11.17**；`pytest 9.1.1`；`CARBONBOO_TEST_DB=carbonboo_test_vfy`（**验证者专属库名**，避免与他人共用库撞出 `1412 Table definition has changed` 假失败）。
- MySQL 走 TCP `127.0.0.1:13307` → 容器 `carbonboo-mysql`（`docker ps` 原文：`Up 20 hours  33060/tcp, 127.0.0.1:13307->3306/tcp  carbonboo-mysql`）；**不是** `13306`（那是别人的容器 `cb-mysql`，`0.0.0.0:13306->3306/tcp`）。
- 凭据取自 `server/.env`，**不是**任务书写过的 `root/cbpass123`（该组合前几轮实测 1045 被拒，见 F18）。

#### R4-c / R4-d / R4-e · 编译门禁成对自证（本轮自己跑、自己注入、自己还原）

注入点选在 `app/entry/src/main/ets/viewmodel/net/SyncService.ets` —— **import 区之后的有效代码区**（第 39 行），
不是插进 `/** */` 注释块（插进注释会 BUILD SUCCESSFUL，那是假绿，前几轮已有人踩过）。注入的一行：

```
const VFY_GATE_PROBE: number = VFY_UNDEFINED_PROBE_SYMBOL + 1;
```

**① 基线（未注入）：**

```
$ hvigorw --no-daemon assembleHap
...
> hvigor UP-TO-DATE :entry:default@CompileArkTS...
> hvigor Finished :entry:assembleHap... after 1 ms
> hvigor BUILD SUCCESSFUL in 4 s 879 ms
BASE_EXIT=0
```

> 诚实标注：这条基线是**增量构建**（`CompileArkTS` 显示 `UP-TO-DATE`、总耗时 4.9s），
> 它只能证明「当前字节的产物是最新的」，**不足以单独证明从零全量可编译**。真正的编译段证据在 ③（撤回后 `CompileArkTS` 真实执行）。

**② 注入后（必须 FAILED）：**

```
$ hvigorw --no-daemon assembleHap
> hvigor ERROR: Failed :entry:default@CompileArkTS...
> hvigor ERROR: ArkTS Compiler Error
1 ERROR: ArkTS:ERROR File: /mnt/c/Users/Administrator/Desktop/CarbonBoo/app/entry/src/main/ets/viewmodel/net/SyncService.ets:39:32
 Cannot find name 'VFY_UNDEFINED_PROBE_SYMBOL'.
COMPILE RESULT:FAIL {ERROR:2}
> hvigor ERROR: BUILD FAILED in 23 s 77 ms
PROBE_EXIT=255
```

判据三条全部满足：**`Cannot find name 'VFY_UNDEFINED_PROBE_SYMBOL'`** 出现 ✓；**`BUILD FAILED`** 出现 ✓；
报错**自定位到 `文件:行:列` = `SyncService.ets:39:32`** ✓（列 32 正是那个未定义符号的起始列）。**EXIT=255** ✓。

**③ `cp` 备份还原后（必须 SUCCESSFUL，且字节与 HEAD 一致）：**

```
$ cp /tmp/SyncService.ets.bak app/entry/src/main/ets/viewmodel/net/SyncService.ets
$ md5sum app/entry/src/main/ets/viewmodel/net/SyncService.ets
d0fce64796fa5d901b243cc926616980  app/entry/src/main/ets/viewmodel/net/SyncService.ets
$ git show HEAD:app/entry/src/main/ets/viewmodel/net/SyncService.ets | md5sum
d0fce64796fa5d901b243cc926616980  -
$ hvigorw --no-daemon assembleHap
> hvigor Finished :entry:default@CompileArkTS... after 23 s 644 ms
> hvigor BUILD SUCCESSFUL in 28 s 428 ms
RESTORE_EXIT=0
```

两侧 EXIT 码：**注入侧 255 / 撤回侧 0**。还原后文件 md5 与 `git show HEAD:<path>` **逐字节一致**（同 md5 `d0fce647…`；
另用 `cmp -s` 与备份副本比对通过），`git status --short` 仍为空 → **零污染**。
③ 里 `CompileArkTS` 是真实执行（23s644ms，不是 UP-TO-DATE），所以「还原后的字节确实能编译」有真实编译段背书。

#### R4.4 数值真相源零改动

```
$ git diff --name-only
（空 —— 被测路径与基准 JSON 均无改动）
$ md5sum tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  tests/cases/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
$ git status --short
（空）
```

- `git diff --name-only` 中**没有** `tests/cases/carbon-calc.json` ⇒ 本轮未动数值（AGENTS.md §5.1-3 的判据是 diff，不是 md5 相等）。
- 根基准与 ohosTest 副本**同 md5**（`e096b2db…`）⇒ 上一轮 `d228939` 修掉的副本漂移没有复发。
- **数值真相源 diff 单列**（§5.1-3 要求）：**无 diff**，本轮未触碰 `samples` / `capSamples` / `factors` / `meta.*` / `docConflicts` 任何字段。

#### R4.5 规约红线（`app/` 内三项计数，均须为 0）

```
$ grep -rn ': any' --include='*.ets' app | grep -v '/build/' | wc -l
0
$ grep -rn '@ts-ignore' --include='*.ets' app | grep -v '/build/' | wc -l
0
# 非相对 import，排除 @ohos / @kit（AGENTS.md §7.1 禁止第三方包）
$ grep -rnE "^import .* from ['\"]" --include='*.ets' app | grep -v '/build/' \
    | grep -vE "from ['\"]\.\.?/" | grep -vE "from ['\"]@(ohos|kit)" | wc -l
0
```

三项全 0：`: any` = **0**、`@ts-ignore` = **0**、非相对 import（排除 `@ohos`/`@kit`）= **0**。
（第三条的逐条打印为「零命中」，即没有任何一条需要人工豁免。）

#### R4.6 四条铁律静态核对（各给 `文件:行`）

**① 单一计算入口（铁律 2）**

| 断言 | 证据 |
|---|---|
| 唯一 `calculate` 入口 | `app/entry/src/main/ets/service/CarbonService.ets:76` `static calculate(activity: ActivityInput, factor: FactorSnapshot, options?: CalcOptions): CarbonCalculation` |
| 唯一因子乘法 | `app/entry/src/main/ets/service/CarbonCalc.ets:153` `const product: Dec = Dec.from(amount).mul(Dec.from(factorValue));` |
| 全 app 的 `Dec.mul` 落点 | `CarbonCalc.ets:153`（活动量 × 因子）、`:164`（kg × 100 求 C）、`:258`（`amountOfCarFreeDays`：天数 × 单车里程）、`:267`（`amountOfRecyclePieces`：件数 × 单件重量）—— **四处全在同一文件**，业务乘法无第二个文件（**t33 更正**：此处原写「树当量 / 纸张当量」为误标，真实函数名见 §「本轮更正」C-F5） |
| `pages/` + `components/` 零命中 | `grep -rn "calculate"` = **0**；`grep -rn "DecimalUtil\|Dec\.from"` = **0**；`grep -rnE "(factorValue|factor_value) *\*|\* *(factorValue|factor_value)|reductionKg *=[^=]"` = **0** |
| 页面只展示、不计算 | `pages/`/`components/` 里出现 `factor` 字样的全部是 `Formatter.number(this.record.factorValue, 'factor')` 这类**格式化读取**（`RecordDetailPage.ets:141`、`RecordEditPage.ets:535-536`、`components/RecordItem.ets:55`、`components/BadgeItem.ets:37`、`components/GoalItem.ets:38`、`HomePage.ets:155`、`AboutPage.ets:105`），无乘法、无因子取值 |

**② 因子快照四字段 NOT NULL（铁律 3）**

`app/entry/src/main/ets/data/schema/ClientSchema.ets`（`CREATE TABLE IF NOT EXISTS carbon_record`，:76 起）：

```
:85  factor_value    REAL    NOT NULL,          -- 因子快照（铁律 3）
:86  factor_version  TEXT    NOT NULL,
:87  factor_source   TEXT    NOT NULL,
:88  confidence      TEXT    NOT NULL,          -- verified | provisional
```

四列齐备且全部 `NOT NULL`。写入侧唯一构造点 `service/CarbonService.ets:187` `static snapshotOf(...)`，
调用点 `viewmodel/RecordService.ets:149` / `:306` / `:367`（新增、编辑、补记三条链路）。

**③ 流水只增不删（铁律 4 上）**

```
$ grep -rniE "(UPDATE|DELETE)[[:space:]]+(FROM[[:space:]]+)?point_record" \
    --include='*.ets' --include='*.ts' --include='*.py' --include='*.sql' --include='*.js' .
UPDATE point_record      => 0
UPDATE FROM point_record => 0
DELETE FROM point_record => 0
delete from point_record => 0
```

全仓 **0 命中**（唯一命中在 `.agent-teams/carbonboo-delivery/team.json` 的历史消息正文里，
该目录被 `.gitignore:26 .agent-teams/` 忽略、**不入库**，不构成被测字节）。

- 唯一写入点：`viewmodel/PointService.ets:153` `'INSERT OR IGNORE INTO point_record '`（幂等键 `uq_pr_source(user_id, source_type, source_id, flow_kind)`，见 `ClientSchema.ets:141`）。
- 冲正不删行、写负额新行：`PointService.ets:190` `async reverse(...)` → `:195` `points: -points`（`type: 'reverse'`）。
- 软删除只作用于 `carbon_record`（`data/dao/CarbonRecordDao.ets:176`、`viewmodel/RecordService.ets:220`），**不作用于 `point_record`**。

**④ 余额同口径 `COALESCE(SUM(points),0)`（铁律 4 下）**

| # | 位置 | 作用 |
|---|---|---|
| 1 | `app/entry/src/main/ets/viewmodel/PointService.ets:91` | 余额（`inc` / `spent` / `bal` 同一条 SQL，`bal` = `COALESCE(SUM(points), 0)`） |
| 2 | `app/entry/src/main/ets/viewmodel/net/SyncService.ets:362` | 家庭合并 · 单设备积分（`... AND COALESCE(device_id, '') = ?`） |
| 3 | `app/entry/src/main/ets/viewmodel/net/SyncService.ets:377` | 家庭合并 · 合计积分 |

三处**同口径**：都对 `point_record.points`（本身已带符号）直接 `SUM`，**不做** `flow_kind` 二次取负
（round 1 的 F1 正是这个双重取负，已修）。另有同式但非「余额」语义的四处：
`PointService.ets:121` / `:136` / `:235`、`server/admin_web/services/stats.py:90`；以及用例内的独立复算
`app/entry/src/ohosTest/ets/test/LwwMerge.test.ets:648`（**未运行**，见 R4.7）。

### R4.3 沿用上轮 vs 本轮重跑（读者请按此表取用）

| 章节 | 状态 | 说明 |
|---|---|---|
| §R4（本节） | **本轮新写** | 绑定 `e211ae1`，取代 t24/t27/t29 的旧基准结论 |
| §4 独立复算 70 检查点 | **沿用 round 3**（`308d09f`） | 本轮未重跑。理由：`git diff 308d09f..e211ae1 -- tests/cases/` 为空且本轮 md5 与 round 3 记录同值 ⇒ 被复算的字节没变 |
| §5 编译门禁四组注入自证 | **本轮以 3 步重跑覆盖**（R4-c/d/e） | 新增「自定位到 `文件:行:列`」判据；结论一致 |
| §3 L0 | **本轮重跑覆盖**（R4-a） | 扫描文件数 82 → 89 |
| §6 L3 | **本轮重跑覆盖**（R4-b） | 从「只跑子集」升级为**全量 237 passed** |
| §9 契约 A/B/C 抽查 | **沿用 round 3** | 本轮未重跑；`app/` `server/` 未被这些提交触碰（`git diff --stat 308d09f..e211ae1 -- app/ server/` 为空） |
| §11 工程规范抽查 | **本轮重跑覆盖**（R4.5） | 三项计数全 0 |
| §12 F15–F18 | **沿用 round 3** | F15 已由「报告入库」解决（本文件已进 git 历史） |
| §13 未运行 N1–N8 | **本轮复核**（R4.7） | 环境未变；N1 的 `hdc` 表述本轮精确化了一条（PATH 无 hdc，但 SDK 内有二进制，直接调用得 `Connect server failed`） |

### R4.7 未运行项（**一条都不算通过**）

| 编号 | 项 | 未运行的具体原因（本轮实测原始输出） |
|---|---|---|
| **N1** | **L1 全部 hypium（10 套件 / 36 个 `it()`）** | 三座桥全断，见下方三行原文。**hypium 侧零执行**：编译通过 ≠ 用例通过，本轮不给 L1 任何通过判定。**（t38 更正）** 此处原写「**替代证据为零**」，该断言随 `tests/tools/l1_offline/` 于 t37 入库而**失真** —— 纯逻辑部分现有一条可复现的独立离线证据（`RESULT: PASS=55 FAIL=0`、`checked=323 passed=true`，命令 `bash tests/tools/l1_offline/run.sh`），详见 **§R5**；但**它不改变本节结论**：36 个 `it()` 仍然一条都没执行 |
| **N2** | L2 端侧集成（云通路 + 近场通路两条链路） | 需**两条设备**（或真机 + 模拟器）。N1 的三条环境断点直接否决；本机 `command -v emulator` → **EXIT=1（无输出）**。本轮未跑 |
| **N3** | `server/deploy/` 实跑（systemd / nginx / TLS / 定时备份） | 无部署目标：`ls -d /opt/carbonboo` → `No such file or directory`；`command -v nginx` → **EXIT=1（未安装）**。`systemctl is-system-running` → `running`、`docker ps` 可用，但部署目标与 nginx 不存在，**不能算跑过**。本轮未跑 |
| **N4** | `/admin` 浏览器交互（SSR 渲染、`admin.js` 前端行为） | 无浏览器驱动：`chromium` / `chromium-browser` / `google-chrome` / `playwright` / `chromedriver` **逐个 not found**。HTTP/JSON 层由 L3 `test_admin.py`（85 例全过）覆盖，但**渲染与 JS 交互未跑** |
| **N5** | 视觉模型走查（18 页面截图 + 判图） | 截图腿：同 N1（无设备 / 无模拟器 / Previewer 不兼容）。判图腿：`ARK_API_KEY` 在本会话**未设置**（`len=0`，`.dsh/.env` 与 `~/.dsh/.env` 均不存在），空 key 打端点得 **HTTP=400**（原文见下）。⇒ **本轮零视觉结论**，用户 m00004「前端子代理须有视觉模型」一条仍未满足，须在最终交付说明里显式告知 |

**N1 的三条环境断点（本轮实跑原文）：**

```
# ① PATH 里没有 hdc（任务书口径）
$ command -v hdc; hdc list targets
Command 'hdc' not found, did you mean: …（apt 建议列表，略）
HDC_EXIT=127

# ② 精确化：SDK 里确有 hdc 二进制，但连不上设备服务端
$ $HARMONY_TOOLCHAIN/sdk/default/openharmony/toolchains/hdc list targets
Connect server failed
（stdout 无任何设备行）

# ③ 无模拟器：/dev/kvm 存在但当前用户不可写
$ ls -l /dev/kvm
crw-rw---- 1 root kvm 10, 232 Oct 14 22:10 /dev/kvm
$ test -w /dev/kvm; echo "KVM_WRITABLE_EXIT=$?"
KVM_WRITABLE_EXIT=1
$ command -v emulator; echo "EMU_EXIT=$?"
EMU_EXIT=1

# ④ Previewer 与 GLIBC 2.43 冲突
$ ldd --version | head -1
ldd (Ubuntu GLIBC 2.43-2ubuntu2.4) 2.43
$ $DEVECO_SDK_HOME/default/openharmony/previewer/common/bin/Previewer --help
[ERROR][CommandParser.cpp][IsAppPathValid][319]…:Launch -j parameters abnormal!
[ERROR][CommandParser.cpp][IsCommandValid][135]…:No app path specified.
[FATAL][CommandParser.cpp][ParseArgs][1008]…:Start args is invalid.
（按 round 1/2 留档，带 `-j <app>` 真正拉起页面时崩在 glibc 2.43 的 pthread_mutex_lock robust 断言；
本轮 `--help` 只走到参数校验段，故无法在本条命令里复现该断言——如实标注，不冒充已复现）
```

**N5 判图腿的原始输出：**

```
$ echo "ARK_API_KEY=[${ARK_API_KEY:-<unset>}]"; echo "len=${#ARK_API_KEY}"
ARK_API_KEY=[<unset>]
len=0
$ ls -l .dsh/.env ~/.dsh/.env
ls: cannot access '.dsh/.env': No such file or directory
ls: cannot access '/home/qinyixiang/.dsh/.env': No such file or directory
$ curl -sS -m 20 -w 'HTTP=%{http_code}\n' https://ark.cn-beijing.volces.com/api/v3/chat/completions \
    -H 'Content-Type: application/json' -H "Authorization: Bearer ${ARK_API_KEY}" \
    -d '{"model":"doubao-vision-pro-32k","messages":[{"role":"user","content":"ping"}]}'
HTTP=400
{"error":{"code":"InvalidParameter","message":"The parameter `` specified in the request are not valid: invalid parameter: AuthHeader. Request id: 0217922287742100ab9d8edb12c66686fe4c60e6bc8d007401eee","param":"","type":"BadRequest"}}
```

> **未运行 = 不算通过。** 上表五项在本轮**没有任何一条**被计入「通过」。尤其不要把「`assembleHap` BUILD SUCCESSFUL」
> 说成「L1 用例通过」——那 36 个 `it()` 本轮**一个都没执行**。

### R4.8 本轮未决问题

1. **L1 仍是零执行**：无真机、无模拟器、Previewer 与 GLIBC 2.43 不兼容。这不是「再试一次」能解决的；在拿到设备或修好 Previewer 兼容性前，
   `CalcSamples / LwwMerge / NotLoggedIn` 等 36 个 `it()` 只能算「已编写、已登记、已编译」。
   **（t38 补记）** 这里的「零执行」限于 **hypium**。纯逻辑部分此后另有一条独立离线证据
   （`tests/tools/l1_offline/`：`RESULT: PASS=55 FAIL=0`、`checked=323 passed=true`），见 **§R5** ——
   它覆盖 UI/DB/网络/生命周期之外的纯计算与断言库，**不能**折算成任何 `it()` 通过。
2. **视觉走查仍是零达成**（N5）：`ARK_API_KEY` 缺失。这是用户明示要求，交付说明里必须写明未满足，不能沉默处理。
3. **`/admin` 只到 HTTP 层**：85 条 `test_admin.py` 全过证明后端行为，但「浏览器里点得动」没有证据（N4）。
4. **`PointCap` 套件名仍不存在**（round 3 的 F17 复述）：封顶 5 组由 `CalcSamples.test.ets:78` + `CalcBaselineValidator.ets:210-224` 承载。
   这不是代码缺陷，但契约文本仍点名一个不存在的文件名。
5. **审批与推送**：本轮**只写本文件**，不 push；推送由队长执行。`ls-remote` 与本地 HEAD 现为同一 SHA。

### R4.9 AGENTS.md §8 格式对照（任务 → 改了什么 → 跑了什么命令 → 结果 → 未决问题）

- **任务**：对 `HEAD=e211ae1` 的字节做一次绑定当前版本的独立验证（L0、L3 全量、编译门禁成对自证、数值真相源零改动、四条铁律、规约红线），并如实单列未运行项。
- **改了什么**：**只有 `docs/VERIFICATION.md` 一个文件**（新增本节 §R4 于文件开头 + 轮次索引新增 round 4 一行 + §13 补一条 N1 表述精确化）。未改任何被测源码 / 规格文档 / 测试基准 / `tests/cases/`（`git diff --name-only` 对被测路径为空）。
- **跑了什么命令**：`git rev-parse HEAD`、`git ls-remote origin main`、`md5sum`（基准两份副本）、`git status --short`、`python3 tests/tools/check_l0.py --strict`、`cd server && CARBONBOO_TEST_DB=carbonboo_test_vfy .venv/bin/python -m pytest tests/ -q`、`pytest --collect-only -q`、`cd app && source ~/harmony-toolchain/env.sh && export OHOS_BASE_SDK_HOME=$DEVECO_SDK_HOME && hvigorw --no-daemon assembleHap`（基线 / 注入 / 还原 三次）、各项 `grep` 计数、`hdc list targets`、`test -w /dev/kvm`、`ldd --version`、`curl` ark 端点。
- **结果**：L0 **EXIT=0**；L3 **237 passed / EXIT=0**；编译门禁 **0 → 255 → 0**（注入侧自定位 `SyncService.ets:39:32`）；数值真相源 **零改动**、两份副本 md5 同值；规约红线 **0/0/0**；四条铁律**静态全部成立**（各给 `文件:行`）。**未运行**：L1 全部 `it()`、L2、`server/deploy/` 实跑、`/admin` 浏览器交互、视觉模型走查 —— 五项一条都不算通过。**（t38 补记）** 其中「L1 全部 `it()`」指 **hypium 侧**；纯逻辑部分另有一条独立离线证据（55 项 + 323 断言点，见 §R5），两证不可互相顶替。
- **未决问题**：见 R4.8。


```
验证基准 commit：308d09f8c1e6b0178f1480ad8c6938c6b0c1dc3a   ← 完整 40 位，符合 AGENTS.md §5.1-1
git rev-parse HEAD 复核（开工第一步）= 308d09f8c1e6b0178f1480ad8c6938c6b0c1dc3a
「已推送」证据（AGENTS.md §5.1-4，唯一合格证据）：
  git ls-remote origin main → fa91daa2b68b8dee39d2cc4222eef212b02844b1	refs/heads/main
  （收尾时远端已前进到 fa91daa，见「未覆盖（在途）」）
  git rev-list --left-right --count origin/main...HEAD → 0	0   ← **只作辅助、不作证据**（读本地引用缓存，push 失败时同样 0 0）
数值唯一真相源：tests/cases/carbon-calc.json
md5sum = c096da45ba7e1852d25cf91699fcb42b   ← 现场实测，非转抄（AGENTS.md §5.1-2：不设期望常量）
ohosTest 副本 app/entry/src/ohosTest/resources/rawfile/carbon-calc.json md5 同为 c096da45ba7e1852d25cf91699fcb42b
工作区：验证全程 `git status --short` 只有 1 行 `?? docs/VERIFICATION.md`（= 本报告）；
        三次采样（开工 / 四次注入全部回滚后 / 收尾）输出相同。被测路径 git diff 为空。
未覆盖（在途）：验证期间 t25 落地为 fa91daa2b68b8dee39d2cc4222eef212b02844b1
  （只改 AGENTS.md / docs/CHANGELOG.md / tests/README.md，+43/−1），
  与 308d09f 相比**被测代码零差异**：git diff --stat 308d09f..fa91daa -- app/ server/ tests/cases/ 为空。
  本报告的被测结论对 fa91daa 同样成立；其中 L0 与独立复算我已在 fa91daa 上补跑（§3.2 / §4.2），其余章节以 308d09f 为准。
本文件 diff（AGENTS.md §5.1-3 要求单列）：docs/VERIFICATION.md 本轮为**纯覆盖写**（round 3 全文覆盖 round 1/2）；
  未触碰 tests/cases/carbon-calc.json（diff 见 §4.9）/ 任何 APPENDIX / AGENTS.md / PLAN.md / GLOSSARY.md /
  README.md / app/ / server/。唯一写入物就是本文件。
```

> **独立验证者**：`qa-verifier-wb`（**非实现者**）。只用实际运行的命令与原始输出说话，不做「应该可以」的推断。
> 命令均在 WSL、仓库根 `/mnt/c/Users/Administrator/Desktop/CarbonBoo` 下执行（编译在 `/tmp/cbv24` 副本内，理由见 §5.1）。
> **本轮我改了哪些文件**：只有本文件 `docs/VERIFICATION.md`。没有改任何被测源码、文档、基准 JSON、测试期望值，也没有删断言/跳过用例。

---

## 轮次索引

| 轮次 | 任务 | 基准 commit | 日期 | 结论一句话 | 锚点 |
|---|---|---|---|---|---|
| round 1 | t7（`qa-verifier-ark`） | `87a055d`（主体验证于 `3a23c82`） | 2026-11-07 | **失败**：L0 / L3 / 独立复算 / 契约 A–C / 编译门禁全通过，但 L1 全部未运行（N1–N7），并报出 F1（家庭积分双重取负，实测 230 应为 170）与 F2（两个 `data/dao/` 模块不在编译图）两条中危缺陷 | 全文备份 `/tmp/cbv22/ev/VERIFICATION-round1-backup.md`（md5 `b6bf1ccbaa0f5080d3516dc101b9ffe0`，853 行）。**该文件从未被提交**，`git show 971d042:docs/VERIFICATION.md` 为空 |
| round 2 | t22（`qa-verifier-wb`） | `971d042e8166fcd125879d67bcb569b848614c09` | 2026-11-07 | **部分通过 / 判 failed**：L0 EXIT=0、L3 **237 passed**、独立复算 **70 检查点 0 失败**、契约 A/B/C 全等、编译门禁注入自证成立、铁律 2/3/4 成立；F1/F2/F3/F4/F5 已修并复验闭环；但 **L1 仍全部未运行**，并新增 F9–F14（F9 **死组件**、F10 `PointCap` 套件名不存在、F12 `AGENTS.md §5.1` 的 md5 刷新要求**不可执行**） | 全文备份 `/tmp/cbv24/ev/VERIFICATION-round2-backup.md`（md5 `d12abec7ec1fff474c54affbaa6a3b2a`，783 行）；**同样从未被提交**（见 F15） |
| round 3 | t24（本轮，`qa-verifier-wb`） | `308d09f8c1e6b0178f1480ad8c6938c6b0c1dc3a` | 2026-11-07 | **部分通过**：L0 EXIT=0、独立复算 70/70、契约 A/B/C 全等、**编译门禁四组注入自证成立且副本零污染**、铁律 1/2/3/4 全部成立、未登录态证据链成立；**F9/F12 闭环、F14 撤销、F3/F4/F5/F10/F11 复验属实**；新增 F15–F18（四条低危）；**L1 仍全部未运行**（N1–N7 环境未变，本轮补跑证据） | 本文 §0 起 |
| round 4 | t31（`verifier-oc`，终验） | `e211ae143a04922952693adf2262cc9feae2e9b4` | 2026-11-07 | **通过（限已跑项）**：L0 EXIT=0（28 项 0 错误 / 89 文件 0 命中 / docConflicts 0）、**L3 全量 237 passed**（85+40+29+25+10+48，专属库 `carbonboo_test_vfy`）、**编译门禁成对自证 EXIT 0→255→0**（注入侧自定位 `SyncService.ets:39:32`，还原后 md5 与 `git show HEAD` 一致）、数值真相源零 diff 且两副本同 md5、规约红线 0/0/0、四条铁律静态全部成立；**L1/L2/deploy/`/admin` 浏览器/视觉走查 五项仍未运行，一条不算通过** | 本文 §R4 |
| round 5 | t38（`fixer-oc`，**表述修正轮，不新增门禁结论**） | `300a89d900c3b38722d67747a17a08518e843665` | 2026-11-07（与 R1–R4 同口径） | **仅修正 L1 表述**：t37 已把离线执行器入库（`tests/tools/l1_offline/`，用 **9 份真实 `.ets`** 转译执行），故把「**替代证据为零**」等失真断言改为准确三态陈述；本机实跑 `RESULT: PASS=55 FAIL=0`、`checked=323 passed=true`（反证：坏基准 → `PASS=53 FAIL=2` / `passed=false`，两者 `EXIT=1`）；**hypium 36 个 `it()` 仍未运行**，N1 结论不变，两证不可互相顶替；L0 `EXIT=0` | 本文 §R5（文件末尾） |

| round 6 | t40（`verifier-oc`，**最终独立验证**） | `a8b78efa505d7643bf20e13674305a332e6925e6` | 2026-11-07 | **通过（限已跑项）**：L0 EXIT=0（28 项 0 错误 / 89 文件 0 命中 / docConflicts 0）、**L3 全量 237 passed**（85+40+29+25+10+48，专属库 `carbonboo_test_final`，218.64s）、**编译门禁成对自证 EXIT 0→255→0**（注入侧自定位 `SyncService.ets:39:32`，还原后 md5 与 `git show HEAD` 同值 `d0fce647…`）、**离线 L1 执行器 `RESULT: PASS=55 FAIL=0` / `checked=323 passed=true`**、数值真相源零 diff（`300a89d..HEAD`）且两副本同 md5+`cmp` 相同、规约红线 0/0/0、四条铁律静态全部成立；**hypium 36 个 `it()` / L2 / `server/deploy/` 实跑 / `/admin` 浏览器交互 / 视觉走查 五项仍未运行，一条不算通过** | 本文 §R6（文件最前） |

**F 编号规则**：跨轮累加不重用。round 1 用到 **F8**，round 2 用到 **F14**，round 3 从 **F15** 起。
round 1 / round 2 的原始描述**一字未删** —— 本文件 §R1 转引 round 1 要点，两份备份文件完整留档（见 §15）。

---

## §R1 round 1（t7）历史结论转引（不删，仅供对照）

**通过项 P1–P17（round 1）**：L0 EXIT=0（75 文件 0 命中）；L3 237 passed 252.00s（隔离库 `carbonboo_test_t7head`）；`3a23c82` 上 233 passed；独立复算 35/35；half-up vs banker's 3 点中 2 点可观测差异；float 累加 1000 条 = 192.00000000000017 ≠ 192.000；契约 A 43/43 逐字全等；契约 B 类型差异 0 / 客户端独有 `sync_state` × 9；契约 C 因子 31 = 30 + `CAR_OWN_FACTOR`；编译门禁基线 SUCCESS + 注入 FAILED(255)；28 模块逐模块探针 26 入图 / 2 未入图；探针 A 34/34；铁律 2/3 通过。

**缺陷 F1–F8（round 1）**：F1（中）`SyncService` 冲正行双重取负（实测 230，正确 170）；F2（中）`CarbonRecordDao.ets` / `ResultSetMapper.ets` 不在编译图；F3（低）`AGENTS.md` 例外集仍写四类；F4（低）`server/app/models/ledger.py` 陈旧注释；F5（低）`LwwMerge` 编号缺 ⑦；F6（低·信息）契约点名的 `test_backup` 无此文件；F7（低·信息）任务书凭据 `root/cbpass123` 被拒（1045）；F8（低·信息）基准 commit 与实际 HEAD 不符。

**未运行 N1–N4（round 1）**：N1 L1 全部 hypium；N2 L2 端侧集成；N3 部署脚本实跑；N4 `hvigorw test` 执行段。

---

## §0 结论速览（三态严格分开：**通过 / 失败 / 未运行**）

### 通过（每行都有原始输出，见对应 §）

| # | 验证项 | 命令 / 方法 | 结果 |
|---|---|---|---|
| **V1** | L0 文档与数值一致性 | `python3 tests/tools/check_l0.py --strict` | **EXIT=0**；28 检查项 0 错误 / 扫描 82 文件 0 命中 / docConflicts **0** 条（§3.1）；在 `fa91daa` 收尾复跑同样 EXIT=0（§3.2） |
| **V2** | 基准自检（契约 verify 第 4 条） | `python3 -c "import json;…print(len(samples),len(capSamples),len(boundarySamples),len(factors))"` | `18 5 6 31`，**EXIT=0**（§4.1） |
| **V3** | 独立复算（**不调被测代码**） | `/tmp/cbv24/ev/recompute.py`（`Decimal` + `ROUND_HALF_UP`，只读基准 JSON） | **检查点 70 个，失败 0 个，EXIT=0**（§4.2–4.8）；`fa91daa` 上复跑仍 70/70 |
| **V4** | half-up 舍入单独验证 | 同脚本 D 段 | `half_up(2.5)=3` vs `half_even=2`；`half_up(0.005×100)=1` vs `half_even=0`；**float 实算 `0.005*100 = 0.5 → round = 0`**（若用 float，边界样例 22 会得 0 分而基准期望 1 分）（§4.6） |
| **V5** | 「禁止浮点累加求总量」单独验证 | 同脚本 E 段 | 1000×0.1920：float 累加 = **192.00000000000017**，Decimal = 192.0000；10×0.1：float = 0.9999999999999999（§4.7） |
| **V6** | 编译门禁真实性（注入未定义**引用**） | `/tmp/cbv24` 副本（`git archive 308d09f`）注入 4 个不同模块 | **4 组注入全部 BUILD FAILED / EXIT=255 且错误自定位到注入行**；撤回后 4 次 BUILD SUCCESSFUL / EXIT=0（§5.1–5.2） |
| **V7** | 业务代码真实进入编译图 | 自写 import 闭包脚本 + 3 处注入探针 | `pages/Index.ets` import 闭包 **105 个 .ets**；另 3 个未入闭包文件全部另有入图路径（含 `module.json5` 入口，已注入自证）⇒ **108 个 .ets 全在编译图内**（§5.3） |
| **V8** | 副本零污染（注入不回写工作树） | 逐个 md5 与 `git show 308d09f:<path>` 对比 | 4 个被注入文件回滚后 md5 **全部与基准提交逐字节相同**；仓库 `git status --short` 全程只有 `?? docs/VERIFICATION.md`（§5.4） |
| **V9** | 铁律 1 · 未登录 = 纯单机（五类例外） | **宽口径语义覆盖** `grep -rn "四类"`（+ `grep -n "五类" AGENTS.md`）+ 141 个网络调用点全表审查 | `AGENTS.md:104/:143/:164` 三处均「五类」；全仓 `.ets` 网络调用 **141 处，五类之外 0 处**。例外集语境判据由窄模式改为宽口径后重新判定为 **部分闭环**（R3 勘误，见 §7.1） |
| **V10** | 铁律 2 · 单一计算入口 | 全 `.ets` 乘法/除法穷举 236 处 + 页面组件 SQL/乘法双 grep | **页面层与网络层零乘法**；`DecimalUtil.mul` 全部 8 处均非碳因子；页面/组件层 SQL **零命中**（§7.2） |
| **V11** | 铁律 3 · 因子快照四字段 | 建表 + 写入路径 + 回填点三查 | `ClientSchema` 四列 `NOT NULL`；`snapshotOf` 唯一构造点；写入路径三处；回填仅 1 处且只对**无因子的历史行**（§7.3） |
| **V12** | 铁律 4（上）· 流水只增不删 | `grep -rn "UPDATE point_record\|DELETE FROM point_record\|delete from point_record"` 全 app+server | **命中 0**；软删除只打 `is_deleted`；冲正走 `PointService.reverse()` 写负额新行（§7.4） |
| **V13** | 铁律 4（下）· 余额 = 收入 − 支出 | 三处口径源码比对 + 独立算术 G1/G2/G3 | 客户端 `balance()`、家庭合并两处、后台 `stats.py` **同口径**；G1=170 / G2=0 / G3=100 全部相等（§7.5） |
| **V14** | 未登录态不发起任何上传（**静态**核查） | `NotLoggedIn.test.ets` 70 行全文 + `FakeHttpClient` + `SyncService` 短路点 | `:48`/`:62` 两处 `expect(http.count()).assertEqual(0)`；三处短路在**发请求之前**；`backup.create` 无 HttpPort 字段 → 结构上不可能触网（§8） |
| **V15** | 契约 A/B/C 一致性 | `contract_cols.py` + `factor3way.py`（自写，不调被测代码） | A：19 表逐名全等 + 服务端 21 表逐列 **列名全等**、**类型映射违反 0 处**；B：`sync_state` 客户端独有 ×9 与附录 B:62 一致；C：**三向逐字段全等**（含附录 A 表格解析）+ §2.5 五项统计 + 编号 + 顺序 + points 段（§9） |
| **V16** | L1 用例**完整编写 + 登记**（静态） | 手工逐文件复核 + `List.test.ets` 全文 | `List.test.ets` **10 import / 10 调用一一对应**、无悬空；契约点名 9 套件里 **8 个在、1 个（`PointCap`）不存在**（F17）；`it()` 合计 **36**（§10） |
| **V17** | L3 服务端（子集，本轮口径） | `cd server && CARBONBOO_TEST_DB=carbonboo_test_t24 .venv/bin/python -m pytest tests/test_sync.py -q` | **48 passed, 1 warning in 41.82s, EXIT=0**（§6.1） |
| **V18** | 「客户端 token 访问 `/admin/*` 必须 403」 | `… pytest tests/test_admin.py -q -k "forbidden or not_accepted or different_keys"` | **19 passed, 66 deselected, EXIT=0**；覆盖 **16 条 `/admin/*` 路径**（含 1 条未注册路径）+ 6 种写方法 + 反向隔离（§6.2） |
| **V19** | 工程规范抽查（AGENTS.md §7.1） | grep | 页面/组件层 `: any` / `@ts-ignore` / `<any>` **零命中**；页面层 SQL **零命中**（§11） |
| **V20** | 工作区零污染（全程） | `git status --short` ×3 次 | 验证开始时 / 四次注入全部回滚后 / 收尾时**三次输出相同**，只有 `?? docs/VERIFICATION.md`（§1.3） |

### 失败（如实报告；**我未做任何修复**。本轮新增 F15–F18）

| 编号 | 级别 | 一句话 |
|---|---|---|
| **F15** | 低 | 未提交文件**无法从仓库恢复**：`docs/VERIFICATION.md` 自 round 1 起从未入库（`git log --all -- docs/VERIFICATION.md` 零条），round 1/2 全文只存在于本机 `/tmp`，重启即失。本轮已补两份备份到 `/tmp/cbv24/ev/`，**但 `/tmp` 同样不是仓库**（§12.1） |
| **F16** | 低 | `git archive <SHA>` 副本跑 `hvigorw test` 会**假失败**：`oh_modules/` 被 `.gitignore:29` 忽略 → 副本报 `Failed to resolve OhmUrl for "@ohos/hypium"` + `BUILD FAILED / EXIT=255`。这是**副本的方法学缺陷**，不是被测代码缺陷（仓库工作树上同一命令 `UnitTestArkTS` 编译段通过）（§12.2） |
| **F17** | 低·信息 | 本轮契约点名的 9 个 L1 套件中 `PointCap` **不存在**（`grep -rn PointCap app/` 源码零命中）；5 组封顶由 `CalcSamples.test.ets:78` + `CalcBaselineValidator.ets:210-224` 承载。F10 的**复述而非新代码缺陷**，但契约文本仍在点名一个不存在的文件名（§12.3） |
| **F18** | 低·信息 | 任务书给的 MySQL 凭据 `root/cbpass123` **第三轮仍不可用**（1045）；真实凭据在 `server/.env`（`MYSQL_USER=carbonboo`）。F7/F13 的第三次复现（§12.4） |

### 未运行（**不得算作通过**）

| 编号 | 项 | 本机原因（实证，本轮全部重跑） | 替代证据（**效力有限**） |
|---|---|---|---|
| **N1** | **L1 全部 hypium 用例（10 套件 / 36 个 `it()`）** | 无真机：`hdc list targets` → stderr **`Connect server failed`**（无任何设备行）；无模拟器：`/dev/kvm` 存在但 **`test -w /dev/kvm` 失败**（uid 1000 不在 kvm 组）；Previewer 崩于 GLIBC 2.43 | §4 离线复算 70/70；§7 铁律静态核查；§8 未登录态静态核查。**（t38 补记，不改本轮结论）** 另有更强的一条：`tests/tools/l1_offline/` 用**仓库真实 `.ets` 转译执行**得 `PASS=55 FAIL=0` 与 `checked=323 passed=true`（§R5）—— 它仍**不是** hypium，**不覆盖** UI/DB/网络/生命周期，36 个 `it()` 仍未运行 |
| **N2** | `hvigorw test` 的**执行段** | 仓库工作树（含 `oh_modules`）实跑：`Finished :entry:default@UnitTestArkTS... after 19 s 880 ms` 之后**再无任何输出**，`timeout 420` 触发 **EXIT=124**（执行器等不到设备，静默挂住） | 仅「编译段通过」，**不构成 L1 通过** |
| **N3** | L2 端侧集成（双设备协同、飞行模式全功能） | 需两条真实设备（或真机 + 模拟器），同上无设备 | 无 |
| **N4** | 部署脚本实跑（systemd / nginx / TLS / `mysqldump` 定时） | 本机无 `systemd` 承载目标路径、nginx 未安装；unit 的 `ExecStart` 指向 `/opt/carbonboo/…`（本机不存在） | 沿用 round 2 的 `bash -n` / `systemd-analyze verify` / `migrate.sh --dry-run`（EXIT=0）+ 安全阀（EXIT=2）；**本轮环境未变，未重跑** |
| **N5** | `/admin` 浏览器端交互（Jinja2 SSR 渲染、`admin.js` 行为） | 无浏览器驱动，只到 HTTP 层 | §6.2 的 HTTP/JSON 路径已实测 |
| **N6** | t18 运行态（徽章开关 / 下发封顶在真机生效） | 同 N1 | 8 个 `it()` 存在且登记，**未运行** |
| **N7** | t13 运行态（真机备份往返） | 同 N1 | 服务端侧备份用例随 `test_sync.py` **48 passed 真实通过** |
| **N8** | **前端视觉走查（18 个页面截图 + 视觉模型判图）** | **本机根本没有截图与判图这两条腿**：`hdc` 未安装（`Command 'hdc' not found`，EXIT=127）、无真机无模拟器（`/dev/kvm` 不可写）、Previewer 崩于 **glibc 2.43**；视觉模型侧 `ARK_API_KEY` 在本会话不存在（`env` 空、`.dsh/.env` 不存在，`cordis.yml:79` 声明 `apiKeyEnv: ARK_API_KEY`），空 key 打端点得 HTTP 400 `InvalidParameter … AuthHeader` | **无。18 个页面一张截图都产生不出来**，故本轮**没有任何视觉走查结论**。**用户 m00004 的「前端子代理须有视觉模型」一条未满足，须在最终交付说明中显式告知**（原始输出见 §7.6） |

> **N1–N7 沿用 round 2 的清单**（环境未变：同一台 WSL、无设备、`/dev/kvm` 仍不可写）。
> 本轮**额外补跑了 N1/N2 的证据**（`hdc`、`/dev/kvm`、`hvigorw test`），未重跑 N4–N7（环境未变、无新信息）。
> **N8 是本轮（t28）新增项**：评审 R2 要求前端做视觉走查，本轮把「为什么做不了」的原始输出落在 §7.6 —— **本机连一张页面截图都产生不出来**，这是比「视觉模型不可用」更前置的阻塞。

---

## §1 环境与基准（实测）

### 1.1 版本与工具链

```
$ python3 -V                        → Python 3.14.4
$ server/.venv/bin/python -V        → Python 3.11.17     （PATH 无 python 命令，必须走 venv）
$ node -v                           → v18.20.1
$ ldd --version | head -1           → ldd (Ubuntu GLIBC 2.43-…)   ← Previewer 不兼容的根因
$ echo $DEVECO_SDK_HOME             → /home/qinyixiang/harmony-toolchain/clt/command-line-tools/sdk
esbuild：/tmp/t2verify/node_modules/esbuild/bin/esbuild（11,427,952 B）—— 仓库内无 npm 依赖，用既有离线副本
```

### 1.2 数据库

```
容器 carbonboo-mysql → 127.0.0.1:13307->3306/tcp (mysql:8.0)
另有他人容器 cb-mysql → 0.0.0.0:13306 —— 本轮全程未使用
实际可用凭据（server/.env）：
  MYSQL_HOST=127.0.0.1 / MYSQL_PORT=13307 / MYSQL_USER=carbonboo / MYSQL_DB=carbonboo
  （任务书的 root/cbpass123 连续三轮被拒，见 F18；连接全程走 TCP）
测试库：CARBONBOO_TEST_DB=carbonboo_test_t24（本任务专属，避免并发成员共用触发 1412 假失败）
```

### 1.3 仓库状态（零污染证据，三次采样输出相同）

```
$ git rev-parse HEAD
308d09f8c1e6b0178f1480ad8c6938c6b0c1dc3a
$ git status --short
?? docs/VERIFICATION.md            ← 开工时 / 四次注入全部回滚后 / 收尾时，三次相同
```

> **窗口期记录（只记录、不碰）**：任务进行中工作树曾出现他人两处未提交改动
> （` M AGENTS.md`、` M tests/README.md`，属 t25），**我一个字节都没动**；
> 提交前它们已由 t25 自行提交为 `fa91daa`，故收尾时工作树恢复为只有本报告。

---

## §2 round 1–2 缺陷的处置复验（闭环判定）

| 编号 | round 2 状态 | 本轮实测 | 判定 |
|---|---|---|---|
| **F1** 家庭积分双重取负 | 已修（`971d042`） | `grep "CASE WHEN flow_kind" SyncService.ets` → 执行代码 0 命中；两处 `COALESCE(SUM(points), 0)` 在 `:359`（成员）/ `:374`（合计）；独立算术 G1/G2/G3 = 170/0/100 | **闭环**（静态 + 纯算术；**承载它的 L1 用例仍未运行**，见 N1） |
| **F2** 两个 Dao 不在编译图 | 报告为缺陷 | 本轮**我自己**在 `/tmp/cbv24` 副本注入 `CarbonRecordDao.ets:52` → `ArkTS:ERROR File: …/CarbonRecordDao.ets:52:40` / `Cannot find name 'T24_UNDEFINED_DAO_SYMBOL'.` / **BUILD FAILED / EXIT=255**；撤回 → SUCCESSFUL / EXIT=0（§5.2 第 2 组） | **闭环** |
| **F3** 例外集四类 → 五类 | 已修 | `AGENTS.md:104`（§2 铁律 1）/ `:143`（§5 L2）/ `:164`（§6）三处均「五类」且含「配置下发」。**原判据 `grep "四类网络例外\|四类例外"` 是窄模式假绿（t28 / R3 撤回）**：`docs/PLAN.md` 当时有 7 处写作「例外仅四类 / 除上述四类外 / 四类外全部功能必须可用」、`ADR-0001:17` 1 处「固定为四类」，全都不含那两个连写短语（§7.1）。t28 已逐处改五类，现宽口径 `grep -rn "四类"` 剩余 13 处**全部为减排分类语境或历史留痕** | **部分闭环**（正文已一致；判据改为语义覆盖宽口径，见 §7.1） |
| **F4** `server/app/models/ledger.py` 陈旧注释 | 已修 | `:69-70` 现文「已于 B40 勘误闭环（附录 B §2:149 已含 user_id）；老库升级迁移见 sql/migrations/001_uq_pr_source_user_id.sql。」 | **闭环** |
| **F5** `LwwMerge` 编号缺 ⑦ | 已修 | 带圈编号 `it()` = 10 条、去重 10、**缺号 []**；文件 `it()` 总数 10，**编号与用例一一对应**；硬锚 `LwwMerge.test.ets:652` `expect(net).assertEqual(0);   // +96 − 96` 在 | **闭环** |
| **F9** `CategoryTag` 死组件 | 报告为缺陷 | t23 选了「接线」：`pages/RecordSearchPage.ets:17` `import { CategoryTag } from '../components/CategoryTag';`，`:116` 真实渲染；我在副本 `CategoryTag.ets:21` 注入 → **BUILD FAILED / EXIT=255 自定位 `:21:36`**（§5.2 第 1 组） | **闭环** |
| **F10** `PointCap` 套件不存在 | 低·信息 | 仍不存在（`grep -rn PointCap app/` 源码零命中）；封顶 5 组确由 `CalcSamples.test.ets:78` + `CalcBaselineValidator.ets:210-224` 承载 | **维持（非缺陷，见 F17）** |
| **F11** `test_backup` 不存在 | 低·信息 | `server/tests/` 实有 7 个文件，无 `test_backup.py`；备份用例在 `test_sync.py` 内，随 **48 passed** 真实通过 | **维持（非缺陷）** |
| **F12** `AGENTS.md §5.1-2` md5 刷新要求不可执行 | 中 | `308d09f` 已改：现文「引用时现场 `md5sum` 并贴原始输出 / 不设期望 md5 常量 / 数值有没有动一律以 `git diff` 为准」 | **闭环** |
| **F13** 任务书 MySQL 凭据不可用 | 低·信息 | 第三轮复现 → 记为 **F18** | **维持（非缺陷，任务书侧）** |
| **F14** 基准 JSON 字符串写法不一致 | 低 | **改判：不是缺陷，是「复算必须用 Decimal 比较」的约束**（见 §12.5） | **撤销为缺陷** |

---

## §3 L0 文档与数值一致性（V1）

### 3.1 基准提交 `308d09f` 上

```
$ python3 tests/tools/check_l0.py --strict
========================================================================
L0-1 数值基准自检（tests/cases/carbon-calc.json）
========================================================================
检查项：28    错误：0
  OK：18 组正向样例 / 5 组封顶 / 边界样例全部自洽

========================================================================
L0-2 文档已知冲突扫描（docs/）
========================================================================
扫描文件：82    命中：0

L0-3 人工待修清单（tests/cases/carbon-calc.json → docConflicts）：0 条

========================================================================
结论：PASS —— 基准自洽，文档无已知冲突
$ echo $?
0
```

### 3.2 收尾时在新 HEAD `fa91daa` 上复跑（覆盖 t25 对 `AGENTS.md` / `tests/README.md` / `CHANGELOG` 的改动）

```
$ git rev-parse HEAD
fa91daa2b68b8dee39d2cc4222eef212b02844b1
$ python3 tests/tools/check_l0.py --strict | tail -3
L0-3 人工待修清单（tests/cases/carbon-calc.json → docConflicts）：0 条
========================================================================
结论：PASS —— 基准自洽，文档无已知冲突
$ echo $?
0
$ git diff --stat 308d09f..fa91daa -- app/ server/ tests/cases/
（空）      ← 被测代码与基准 JSON 在两个提交间零差异，§4 起的结论对 fa91daa 同样成立
```

---

## §4 独立复算（V2–V5；**不调用任何被测代码**）

**方法**：`/tmp/cbv24/ev/recompute.py`（8,873 B，自 round 2 脚本拷贝而来）只 `json.load` 基准文件，
用 `decimal.Decimal` + `ROUND_HALF_UP` 重算。**不 import** `CarbonCalc` / `CarbonService` / 任何 `app/` 代码，
**不连数据库**。全部数值按**字符串 → Decimal** 比对（不经过 float）；`amount` 与 `expectedReductionKg` 都是字符串。

### 4.1 基准自检（契约 verify 第 4 条）+ 数值真相源

```
$ md5sum tests/cases/carbon-calc.json
c096da45ba7e1852d25cf91699fcb42b  tests/cases/carbon-calc.json

$ python3 -c "import json;d=json.load(open('tests/cases/carbon-calc.json'));print(len(d['samples']),len(d['capSamples']),len(d['boundarySamples']),len(d['factors']))"
18 5 6 31
$ echo $?
0
```

脚本头部自检输出：

```
基准文件 md5 = c096da45ba7e1852d25cf91699fcb42b
基准计数: samples=18 capSamples=5 boundarySamples=6 factors=31
```

### 4.2 A. 18 组正向样例（`reduction = round_half_up(amount × factor, 4)`；`C = round_half_up(kg × 100, 0)`）

```
=== A. 18 组正向样例（reduction = round_half_up(amount × factor, 4)；C = round_half_up(kg × 100, 0)）===
  ✓ [ 1] 步行               5 × 0.1920 = 0.9600 kg → C=96
  ✓ [ 2] 自行车              5 × 0.1920 = 0.9600 kg → C=96
  ✓ [ 3] 电动自行车            10 × 0.1800 = 1.8000 kg → C=180
  ✓ [ 4] 公交车              12 × 0.1520 = 1.8240 kg → C=182
  ✓ [ 5] 地铁               8 × 0.1620 = 1.2960 kg → C=130
  ✓ [ 6] 新能源车             20 × 0.0870 = 1.7400 kg → C=174
  ✓ [ 7] 拼车（人均）           15 × 0.0720 = 1.0800 kg → C=108
  ✓ [ 8] 少开一天车            16.0 × 0.1920 = 3.0720 kg → C=307
  ✓ [ 9] 节约用电             10 × 0.5703 = 5.7030 kg → C=570
  ✓ [10] 节约用水             100 × 0.000168 = 0.0168 kg → C=2
  ✓ [11] 天然气              3 × 2.1840 = 6.5520 kg → C=655
  ✓ [12] 液化石油气            1 × 3.1010 = 3.1010 kg → C=310
  ✓ [13] 废纸回收             2 × 0.9000 = 1.8000 kg → C=180
  ✓ [14] 废铝回收             1.5 × 9.0000 = 13.5000 kg → C=1350
  ✓ [15] 废塑料回收            3 × 1.5000 = 4.5000 kg → C=450
  ✓ [16] 废电子产品（按件）        0.5 × 12.0000 = 6.0000 kg → C=600
  ✓ [17] 光盘行动             1 × 0.3500 = 0.3500 kg → C=35
  ✓ [18] 减少食物浪费           0.5 × 2.5000 = 1.2500 kg → C=125
```

### 4.3 B. 5 组封顶（`A = max(0, min(C, 200 − D))`，仅 `countsTowardCap` 时封顶）

```
=== B. 5 组封顶（A = max(0, min(C, 200 - D))，仅 countsTowardCap 时封顶）===
  ✓ [cap-1] D=150 C=96 → A=50 capped=1
  ✓ [cap-2] D=150 C=30 → A=30 capped=0
  ✓ [cap-3] D=200 C=96 → A=0 capped=1
  ✓ [cap-4] D=200 C=20 → A=20 capped=0（不计入封顶）
  ✓ [cap-5] D=0 C=0 → A=0 capped=0
```

### 4.4 C. 6 组边界样例（3 条算术 + 3 条非算术，后者如实标注「不复算」）

```
=== C. 6 组边界样例 ===
  -- [19] 活动量 0 / 负数 / 空   kind=ui   → 非算术断言，本脚本不复算（expect: 保存按钮禁用，无法提交…）
  -- [20] 骑行 300 km（>200 上限）kind=ui   → 非算术断言，本脚本不复算（expect: 提示「距离较大，请确认是否填错」；可保存，is_abnormal=1…）
  ✓ [21] 减排量 0.0049 kg              kg=0.0049  C=0     noPointRow=True
  ✓ [22] 减排量 0.005 kg               kg=0.005   C=1     noPointRow=False
  ✓ [23] 供暖 30 m²·月                 kg=93.0000 C=9300  A=200
  -- [24] 编辑历史记录数量        kind=rule → 非算术断言，本脚本不复算（expect: 按新数量整体重算减排量与积分差额头（reverse），不增量累加…）
```

> 19 / 20 / 24 是**界面行为与库存规则**断言，不是算术。本复算**不覆盖它们**，也不假装覆盖。

### 4.5 契约 verify 第 3/4 条（离线校验，**非设备运行**）

```
$ /tmp/t2verify/node_modules/esbuild/bin/esbuild entry/src/main/ets/util/DecimalUtil.ets \
    --loader:.ets=ts --outfile=/tmp/cbverify/DecimalUtil.mjs --format=esm --platform=node
  ../../../../../../../tmp/cbverify/DecimalUtil.mjs  5.0kb
⚡ Done in 33ms
$ echo $?
0

$ node /tmp/cbverify/verify.mjs
…
OK   定点乘法不丢精度: 12 × 0.152 = 1.8240

RESULT: PASS —— 全部断言点命中期望值（离线复算，非设备运行）
$ echo $?
0
```

> 注：`verify.mjs` 的标题里就写着「离线复算，非设备运行」—— 它验证的是 `DecimalUtil` 的定点算法与基准自洽，
> **不能替代 hypium 用例**（不经过 ArkTS 运行时与 OHOS 环境）。
>
> **（t38 补记）** 这种「/tmp 里的临时脚本」后来在 t37 有了仓库内的正式版本：`tests/tools/l1_offline/`（见 **§R5**）。
> 它与本节 `verify.mjs` 的差别是**是否可复现、是否直接执行仓库实现**：`l1_offline` 用 esbuild 转译 `app/` 下 9 份
> 真实 `.ets` 并在 Node 里执行 `CarbonCalc` / `CalcBaselineValidator`，`RESULT: PASS=55 FAIL=0`、
> `checked=323 passed=true`。**两者都不能替代 hypium** —— 这条判断不变。

### 4.6 D. half-up 舍入（**单独验证**）

```
=== D. half-up vs banker's（ROUND_HALF_UP 必须用，语言默认 ROUND_HALF_EVEN 会错）===
  half_up(2.5 → 0 位) = 3   half_even = 2   ⚠ 两者不同（证明必须显式指定 HALF_UP）
  half_up(3.5 → 0 位) = 4   half_even = 4   两者相同
  half_up(0.005 × 100（基准边界样例 22，Decimal 路径）) = 1   half_even = 0   ⚠ 两者不同（证明必须显式指定 HALF_UP）
  half_up(0.0125 → 4 位) = 0.0125   half_even = 0.0125   两者相同
  ⚠ float 实算 0.005 * 100 = 0.5  → round(…, 0) = 0（若用 float，边界样例 22 会得 0 分，与基准期望 1 分不符）
```

**结论**：契约点名要验的「浮点下 `0.005*100`」这一具体点，实测 **float → 0、Decimal+half-up → 1**，
而基准 `boundarySamples[22]` 期望 **1 分** —— 所以要拿到期望值，**`Decimal` 与 `ROUND_HALF_UP` 两条都不能省**。

### 4.7 E. 「禁止浮点累加求总量」（**单独验证**）

```
=== E. 禁止浮点累加（float 累加 vs Decimal 累加）===
  1000 × 0.1920：float 累加 = 192.00000000000017   Decimal 累加 = 192.0000
  ⚠ float 累加与精确值不相等（差 1.7E-13）→ 证明禁止浮点累加是必要的
  10 × 0.1：      float 累加 = 0.9999999999999999   Decimal 累加 = 1.0
```

### 4.8 F. 家庭积分净额三组（纯算术，不读库、不调被测代码）

```
=== F. 家庭积分净额（纯算术；primary 正 / reverse 负）===
  ✓ G1 流水 [('primary', 200), ('reverse', 30)] → SUM(points)=170；旧写法=230（虚高 60 = 2×Σ|reverse|）
  ✓ G2 流水 [('primary', 96), ('reverse', 96)] → SUM(points)=0；旧写法=192（虚高 192 = 2×Σ|reverse|）
  ✓ G3 流水 [('primary', 200), ('reverse', 30), ('reverse', 70)] → SUM(points)=100；旧写法=300（虚高 200 = 2×Σ|reverse|）

===== 汇总：检查点 70 个，失败 0 个 =====
$ echo $?
0
```

> G1/G2/G3 是队长要求的「不经任何被测代码的家庭积分独立复算」：
> `primary=+200 / reverse=−30` → **170**（round 1 旧口径 230，偏移正是 `2×30`）；
> `+96 / −96` → **0**（旧口径 192）；`+200 / −30 / −70` → **100**（旧口径 300）。
> 期望值写死在本报告与脚本里，**不读库、不调被测代码**。

### 4.9 基准 diff 单列（AGENTS.md §5.1-3）

```
$ git diff 971d042..HEAD --stat -- tests/cases/carbon-calc.json
（空）
$ git status --porcelain tests/cases/carbon-calc.json
（空）
$ git diff 87a055d..HEAD --stat -- tests/cases/carbon-calc.json
 tests/cases/carbon-calc.json | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)
```

那 1 行是 **`docConflicts` 里 B47 条目的 `correct` 文本追加（「⑤ 收尾回写（2026-11-07，t20）…」）**，
属条目元数据补写，**不含任何数值**（`samples` / `capSamples` / `factors` / `meta.*` 全未动）。
**本轮数值零改动。**

---

## §5 编译门禁真实性（V6–V8）

### 5.1 方法：为什么在 `/tmp/cbv24` 副本里注入，而不是就地注入

```
$ mkdir -p /tmp/cbv24 && cd /mnt/c/Users/Administrator/Desktop/CarbonBoo
$ git archive 308d09f8c1e6b0178f1480ad8c6938c6b0c1dc3a | tar -x -C /tmp/cbv24
（292 个文件；副本根无 .git / build/ / node_modules / .env）
```

两条理由（写进方法，避免后人重复踩）：

1. **语义对齐**：`git archive` 只导出**已提交**内容，天然排除工作树里的未提交/脏改动 —— 我要验的就是「这个 commit 编译得过、业务代码在编译图里」。验证期间工作树里有**他人**的未提交改动，就地注入一旦回滚就会覆盖别人的字节（历史上有成员把别人 7 个改动 stash 掉的事故）。
2. **不拷垃圾**：`cp -r` 会连带拷 `app/build/`、`node_modules/`、`.env`、`.git`（构建产物与密钥都不该进副本）。

环境（副本里没有 `~` 默认值，**忘 source 会报一堆「SDK 找不到」的假失败**）：

```
$ source ~/harmony-toolchain/env.sh && export OHOS_BASE_SDK_HOME=$DEVECO_SDK_HOME
$ cd /tmp/cbv24/app && hvigorw --no-daemon assembleHap
```

### 5.2 成对注入自证（**四组，全部我自己跑**，不引用任何他人结论）

| # | 注入文件与位置 | 注入内容（未定义**引用**） | 注入后编译 | 撤回后编译 |
|---|---|---|---|---|
| 0 | ——（基线，冷建） | —— | —— | `BUILD SUCCESSFUL in 12 s 315 ms`，**EXIT=0**，hap **2,445,613 B** |
| 1 | `components/CategoryTag.ets`，紧跟 `@Prop selected: boolean = false;`（:20）之后的 **:21** | `private T24_GATE_PROBE: number = T24_UNDEFINED_CATEGORYTAG_SYMBOL + 1;` | **EXIT=255**（原文见下） | `BUILD SUCCESSFUL in 5 s 834 ms`，**EXIT=0** |
| 2 | `data/dao/CarbonRecordDao.ets`，`export class CarbonRecordDao` 之后 **:52** | `private T24_DAO_GATE_PROBE: number = T24_UNDEFINED_DAO_SYMBOL + 1;` | **EXIT=255**（原文见下） | `BUILD SUCCESSFUL in 5 s 641 ms`，**EXIT=0** |
| 3 | `service/FactorLibrary.ets`，`export class FactorLibrary` 之后 **:40** | `private T24_SEED_GATE_PROBE: number = T24_UNDEFINED_SEEDTYPES_SYMBOL + 1;` | **EXIT=255**（原文见下） | `BUILD SUCCESSFUL in 6 s 778 ms`，**EXIT=0** |
| 4 | `entryability/EntryAbility.ets`，`export default class EntryAbility` 之后 **:30** | `private T24_SEEDREPO_GATE_PROBE: number = T24_UNDEFINED_SEEDREPO_SYMBOL + 1;` | **EXIT=255**（原文见下） | `BUILD SUCCESSFUL in 5 s 511 ms`，**EXIT=0** |

原始输出（第 1 组）：

```
> hvigor ERROR: Failed :entry:default@CompileArkTS...
> hvigor ERROR: ArkTS Compiler Error
1 ERROR: ArkTS:ERROR File: /tmp/cbv24/app/entry/src/main/ets/components/CategoryTag.ets:21:36
 Cannot find name 'T24_UNDEFINED_CATEGORYTAG_SYMBOL'.

COMPILE RESULT:FAIL {ERROR:2}
> hvigor ERROR: BUILD FAILED in 5 s 456 ms
EXIT=255
```

第 2 / 3 / 4 组（同一形态，只有文件与行号不同 —— 这正是「编译器确实在读这些文件」的证据）：

```
1 ERROR: ArkTS:ERROR File: /tmp/cbv24/app/entry/src/main/ets/data/dao/CarbonRecordDao.ets:52:40
 Cannot find name 'T24_UNDEFINED_DAO_SYMBOL'.
COMPILE RESULT:FAIL {ERROR:2}
> hvigor ERROR: BUILD FAILED in 5 s 277 ms          EXIT=255

1 ERROR: ArkTS:ERROR File: /tmp/cbv24/app/entry/src/main/ets/service/FactorLibrary.ets:40:41
 Cannot find name 'T24_UNDEFINED_SEEDTYPES_SYMBOL'.
COMPILE RESULT:FAIL {ERROR:2}
> hvigor ERROR: BUILD FAILED in 6 s 481 ms          EXIT=255

1 ERROR: ArkTS:ERROR File: /tmp/cbv24/app/entry/src/main/ets/entryability/EntryAbility.ets:30:45
 Cannot find name 'T24_UNDEFINED_SEEDREPO_SYMBOL'.
COMPILE RESULT:FAIL {ERROR:2}
> hvigor ERROR: BUILD FAILED in 4 s 857 ms          EXIT=255
```

**注入的是「未定义引用」（`UNDEFINED_X + 1`），不是纯声明** —— `const X: number = 1;` 是合法代码，
必然 SUCCESSFUL，不能用来证明门禁。这一点 round 2 已由队长点明，本轮严格执行。

### 5.3 业务代码是否真的进了编译图（V7）

**静态 import 闭包**（自写脚本 `/tmp/cbv24/modprobe.py`，从 `pages/Index.ets` 沿 `import … from './x'` 递归）：

```
入口 pages/Index.ets import 闭包文件数: 105
ets 总数: 108  未进入 Index import 闭包: 3
  NOT-IN-GRAPH entry/src/main/ets/entryability/EntryAbility.ets
  NOT-IN-GRAPH entry/src/main/ets/model/SeedTypes.ets
  NOT-IN-GRAPH entry/src/main/ets/service/SeedRepository.ets
```

3 个「不在 Index 闭包」的文件，逐个查清**不是掉出编译图**：

| 文件 | 入图路径 | 自证 |
|---|---|---|
| `entryability/EntryAbility.ets` | `app/entry/src/main/module.json5:16` `"srcEntry": "./ets/entryability/EntryAbility.ets"` —— **模块入口**，由构建系统直接拉入 | 注入 → **BUILD FAILED(255)**（§5.2 第 4 组） |
| `model/SeedTypes.ets` | `service/FactorLibrary.ets:34` `} from '../model/SeedTypes';`（类型 import） | 经第 3 组（`FactorLibrary` 注入）间接证明 `FactorLibrary` 在图中 |
| `service/SeedRepository.ets` | `entryability/EntryAbility.ets:18` `import { SeedRepository, SeedReport } from '../service/SeedRepository';` | 经第 4 组（`EntryAbility` 注入）间接证明 `EntryAbility` 在图中 |

**结论**：**108 个 `.ets` 全部在编译图内**（105 在 Index 闭包内 + `EntryAbility` 经 `module.json5` + 它两个依赖经 `EntryAbility`/`FactorLibrary`），
4 组注入全部 FAILED 且自定位。**没有「未入图却 BUILD SUCCESSFUL」的假绿。**

> **旁证（不能替代主证）**：把 108 个 `.ets` 逐个交给 esbuild 单文件转译 —— **成功 66 / 失败 42**。
> 失败 42 个全是 `Unexpected "struct"`（页面与组件的 ArkUI 语法，esbuild 不认识 `struct` / `@Component`），
> 不是业务代码错误。**所以 esbuild 无法充当编译门禁**；真正的门禁证据只有 §5.2 的 4 组注入。

### 5.4 副本零污染（V8）

```
$ git -C /mnt/c/Users/Administrator/Desktop/CarbonBoo show 308d09f:<path> | md5sum   vs   md5sum <path>
06ccf8e3e6215ea19582f220d0be2472  06ccf8e3e6215ea19582f220d0be2472  components/CategoryTag.ets
05575c8f49cbe876b643f79664d41b7e  05575c8f49cbe876b643f79664d41b7e  data/dao/CarbonRecordDao.ets
17a41bc75a556228de07c231c1ed479f  17a41bc75a556228de07c231c1ed479f  service/FactorLibrary.ets
4ae34bec25024974533559930ffdfd76  4ae34bec25024974533559930ffdfd76  entryability/EntryAbility.ets
```

四个被注入文件回滚后**逐字节等于基准提交**。仓库工作树 `git status --short` 全程只有 `?? docs/VERIFICATION.md`。

### 5.5 探针残留核查

```
$ grep -rn --include=*.ets --include=*.ts "T23_UNDEFINED\|T23_GATE_PROBE" app/
$ echo $?
1                       ← 零命中
```

不带 include 的 `grep -rn` 只命中 `app/.hvigor/outputs/build-logs/build.log:16361`（构建产物、不入库，**不是残留**）。

---

## §6 L3 服务端（V17–V18）

### 6.1 `test_sync.py`（含备份 9 例 + 同步幂等/冲突共 48 例）

```
$ cd server && CARBONBOO_TEST_DB=carbonboo_test_t24 .venv/bin/python -m pytest tests/test_sync.py -q
................................................                         [100%]
48 passed, 1 warning in 41.82s
---EXIT=0
```

> **为什么只跑子集**：`git diff --stat 971d042..HEAD -- server/` 为空、`git status --porcelain --untracked-files=no -- server/` 为空
> —— `server/` 相对 round 2 基准**零 diff**。round 2 已在 `971d042` 上跑过全量 **237 passed**（备份留档）。
> 本轮选 `test_sync.py` 是因为 t23 唯一碰到的服务端相邻物是客户端 `SyncService.ets`，
> 若有人手滑改了服务端同步语义会在这里炸 —— 这是成本最低、耦合最高的一条。

### 6.2 「客户端 token 访问 `/admin/*` 必须 403」（V18）

```
$ cd server && CARBONBOO_TEST_DB=carbonboo_test_t24 .venv/bin/python -m pytest tests/test_admin.py -q \
    -k "forbidden or not_accepted or different_keys"
...................                                                      [100%]
19 passed, 66 deselected, 1 warning in 34.60s
---EXIT=0
```

覆盖范围（读 `server/tests/test_admin.py` 的 `ADMIN_PATHS` 与写方法表）：

```
16 条 /admin/* 路径（GET）：
  /admin  /admin/  /admin/login  /admin/logout  /admin/password  /admin/items
  /admin/items/frame_01  /admin/items/frame_01/icon  /admin/users  /admin/overview
  /admin/orders  /admin/config  /admin/logs  /admin/icons/frame_01.png
  /admin/static/admin.css  /admin/__probe_not_registered__   ← 未注册路径也 403（拦在中间件，不是路由）
6 种写方法：POST /admin/login、POST /admin/items、PATCH /admin/items、PUT /admin/config、
            POST /admin/items/{id}/icon、DELETE /admin/items/{id}
反向隔离：管理端 token 打 /api/v1/auth/me → 401 TOKEN_INVALID；两套密钥/audience 互不通过
断言原文：server/tests/test_admin.py:934  assert response.status_code == 403, f"{path} 应 403，实际 {response.status_code}"
         server/tests/test_admin.py:935-936  body["ok"] is False and body["code"] == "FORBIDDEN"
```

> 其余 66 例（`test_admin.py` 全 85 例）与 `test_auth / test_authz / test_shop / test_config` **本轮未重跑**：
> `server/` 零 diff，重跑不产生新信息（round 2 全量 237 passed 见备份）。
> **F11 复述**：契约点名的 `test_backup.py` 不存在，备份用例在 `test_sync.py` 内，已随上面 48 passed 真实通过。

---

## §7 四条铁律（V9–V13）

### 7.1 铁律 1 · 未登录 = 纯单机（五类例外）

```
$ grep -n "五类" AGENTS.md
:104  §2 铁律 1「例外（可依赖网络，**五类**）：登录/注册、多设备同步、商品取价、云端备份、配置下发（GET /api/v1/config…）」
:143  §5 L2「…除五类网络例外（登录/注册、多设备同步、商品取价、云端备份、配置下发）与近场协同外全功能可用」
:164  §6「除「…、配置下发」五类网络例外…外全功能可用」
```

> **判据勘误（t28 / R3）**：本节原来的判据是**窄模式** `grep -rn "四类网络例外\|四类例外" --include=*.md .`，只要码面上没有「四类网络例外」「四类例外」这两个连写短语就判「五类闭环」——**这是假绿**：`docs/PLAN.md` 当时有 6 处写作「例外仅四类：…」「除上述四类外…」「四类外全部功能必须可用」、`ADR-0001:17` 写「固定为四类」、基准 `B42.correct` 写「四类网络例外」但同一处 `B21.correct` 写「仅四项」，这些**一个都不含那两个连写短语的字面组合**，窄模式要么全部漏掉、要么只捞到一处。现改为**语义覆盖的宽口径** `grep -rn "四类"`，再**逐条判语境**（例外集语境 vs 减排分类语境 vs 历史留痕）。宽口径的原始输出见下（`docs/REVIEW.md` 是评审报告本身，引用了这些行号，任何口径下都排除它；`docs/VERIFICATION.md` 是本文件自引用，单独排除以免自己的输出污染自己的输入）。

```
$ git grep -n "四类" 9d73de4 -- docs AGENTS.md tests ':!docs/REVIEW.md' ':!docs/VERIFICATION.md'
（t28 修复前，原始输出，按行首 90 字符截断显示）
AGENTS.md:61:- B42 §6「未登录 = 纯单机」的例外集补齐为**四类**（登录/注册、多设备同步、商品取价、云端备份），与 §2 铁律 1 / §5 L2 / 附
AGENTS.md:66:- B47 附录 D10-5「改目标奖励分值 / 每日封顶值 / 徽章开关 → **App 侧能读到**」缺下发通道（后台系统配置「只写不读」的死功能）→
AGENTS.md:247:| 2026-11-06 | **v4.2 文档契约勘误**：头部状态行改为「S1–S6 已实现并落库，S7 与 `/admin` 收尾中」；§6 未登
docs/APPENDIX-D-acceptance.md:48:| D2-2 | 柱状图正确 | 看板-月粒度 | 4 根柱 = 该月四类减排量，与手算汇总一致 |
docs/APPENDIX-D-acceptance.md:538:> 四类之和必须等于总减排：`21.6000 + 14.0400 + 13.5000 + 12.6000 = 6
docs/APPENDIX-E-demo-script.md:67:| 旁白 | 「所有记录都会汇总到数据看板。折线图看减排趋势，柱状图对比四类行为的贡献，饼图看构成占比。日、周、
docs/APPENDIX-E-demo-script.md:134:赛题二给了五项主要功能。第一，**行为核算**：内置碳排放因子库，覆盖出行、水电燃气、旧物回收、光盘行动四类共
docs/CHANGELOG.md:34:- **AGENTS.md §6**：「未登录 = 纯单机」的例外集由三项补齐为**四类**（登录/注册、多设备同步、商品取价、云端备份）
docs/CHANGELOG.md:39:- **§9 表格**：「典型值（v4.0 因子）」→「**单条量级**（按「日均新增减排 ≈0.7 kg」缩放后的每条约值）」，四类改为
docs/DECISION-0002-doc-contract-errata.md:22:| D5 | `AGENTS.md §6` 未登录例外集补齐为**四类**，头部状态行改为
docs/PLAN.md:95:| 单机版定位 | 赛题二明确为**单机版**碳足迹记录应用 | 任何必做功能**不得依赖网络或登录态**；例外仅四类：登录/注册、多设备同步、商品
docs/PLAN.md:118:**本机 `relationalStore` 是唯一真相源。** 分布式协同与云端只做"搬运"，不参与业务计算。未登录、无网络状态下，**除「登录
docs/PLAN.md:143:| 网络 | **`@ohos.net.http`** | 仅用于**登录/注册、多设备同步、商品取价、云端备份**四类（未登录不发起任何请求），
docs/PLAN.md:375:| F2-2 | 柱状图：分类减排对比 | F | 四类并列 |
docs/PLAN.md:620:> **服务端是必做件**（账号 + 同步 + 取价 + 备份，见 ADR-0001）；**未登录时客户端全部功能可用**，只有「登录/注册、多设
docs/PLAN.md:935:- **没有后台时全部功能仍可用**；**未登录时客户端也不依赖服务端**——只有「登录/注册、多设备同步、商品取价、云端备份」四类需要服务端（铁
docs/PLAN.md:1071:| R2 | 服务端成本 / 可用性 | 登录、同步、取价与云端备份不可用 | 学生机约 100 元/年；**除上述四类外客户端不依赖服务端**
docs/adr/0001-account-and-sync.md:17:- 铁律 1 的例外集固定为四类：**登录/注册、多设备同步、商品取价、云端备份**。
tests/cases/carbon-calc.json:955:      "correct": "【已闭环·2026-11-06】§6 第 2 条改为「除\u300c登录/注册
tests/cases/carbon-calc.json:971:      "correct": "【已闭环·择一为准·2026-11-06】以 §9 为唯一求和来源并新增「§9
← 20 行。窄模式（`四类网络例外\|四类例外`）在这 20 行里只可能命中 :955 一处，其余 19 处全部漏检。
```

```
$ grep -rn "四类" docs/ AGENTS.md tests/ | grep -v "^docs/REVIEW.md" | grep -v "^docs/VERIFICATION.md"
（t28 修复后，原始输出，按行首 96 字符截断显示）
docs/APPENDIX-D-acceptance.md:48:| D2-2 | 柱状图正确 | 看板-月粒度 | 4 根柱 = 该月四类减排量，与手算汇总一致 |
docs/APPENDIX-D-acceptance.md:538:> 四类之和必须等于总减排：`21.6000 + 14.0400 + 13.5000 + 12.6000
docs/APPENDIX-E-demo-script.md:67:| 旁白 | 「所有记录都会汇总到数据看板。折线图看减排趋势，柱状图对比四类行
docs/APPENDIX-E-demo-script.md:134:赛题二给了五项主要功能。第一，**行为核算**：内置碳排放因子库，覆盖出行、
docs/CHANGELOG.md:34:- **AGENTS.md §6**：「未登录 = 纯单机」的例外集由三项补齐为**四类**（登录/注
docs/CHANGELOG.md:39:- **§9 表格**：「典型值（v4.0 因子）」→「**单条量级**（按「日均新增减排
docs/CHANGELOG.md:97:> 本节处理两类**漏记**：一条已合入 main 但从未在本文件留痕的tests改动
docs/CHANGELOG.md:100:- **例外集口径统一为五类（收尾 R1）**：`AGENTS.md` 于 t21 已把 §2 铁律
docs/CHANGELOG.md:103:- **`docs/VERIFICATION.md` 判据勘误（R2/R3）**：V9 的判据由窄模式 `grep
docs/DECISION-0002-doc-contract-errata.md:22:| D5 | `AGENTS.md §6` 未登录例外集补齐为**四类**，头部状态行改为
docs/PLAN.md:375:| F2-2 | 柱状图：分类减排对比 | F | 四类并列 |
AGENTS.md:61:- B42 §6「未登录 = 纯单机」的例外集补齐为**四类**（登录/注册、多设备同步、
AGENTS.md:66:- B47 附录 D10-5「改目标奖励分值 / 每日封顶值 / 徽章开关 → **App 侧能
AGENTS.md:247:| 2026-11-06 | **v4.2 文档契约勘误**：头部状态行改为「S1–S6 已实现并落
tests/cases/carbon-calc.json:955:      "correct": "【已闭环·2026-11-06】§6 第 2 条改为「除\u300c登录
tests/cases/carbon-calc.json:971:      "correct": "【已闭环·择一为准·2026-11-06】以 §9 为唯一求和
← 16 行。行数账（自洽）：宽口径 20 行基线 − 7 行（真缺陷，已改五类，已从结果消失）= 13 行仍在；13 行仍在 = 10 行历史留痕 / 历史缺陷记录 / 减排分类 + 3 行计划表 / 基准登记项（`docs/PLAN.md:375` 的 F2-2 分类、`tests/cases/carbon-calc.json:955` 的 `B42.correct` 句尾自述、`:971` 的 `B44.correct` 分类）；13 + 3 行本节新写的 `docs/CHANGELOG.md:97/:100/:103` 收尾登记 = 16 行，与实测一致。
   PLAN.md:95/:118/:143/:620/:935/:1071 与 adr/0001:17 已从结果里消失 —— 这就是修复生效的直接证据。
```

**逐条判语境（20 行修复前的每一行都有处置，一行不漏）**：

| 出处 | 语境 | 处置 |
|---|---|---|
| `docs/PLAN.md:375` | 减排**分类**（F2-2 柱状图四类并列） | **不动** |
| `docs/APPENDIX-D-acceptance.md:48` | 减排**分类**（D2-2 四类减排量） | **不动** |
| `docs/APPENDIX-D-acceptance.md:538` | 减排**分类**（四类之和 = 61.7400） | **不动** |
| `docs/APPENDIX-E-demo-script.md:67` / `:134` | 减排**分类**（四类行为 / 四类共三十个因子） | **不动** |
| `docs/CHANGELOG.md:34` / `:39` | **历史留痕**（记录 v4.2 当时的决定与改动） | **不动** |
| `docs/DECISION-0002-doc-contract-errata.md:22` | **历史决策留档**（D5 记录） | **不动** |
| `AGENTS.md:61` / `:247` | **历史留痕**（B42 条目内已显式写「t21 起再补「配置下发」→ 五类」） | **不动** |
| `docs/VERIFICATION.md:47` / `:153` | **本文件的历史缺陷记录**（F3 原文与本次裁定） | **不动** |
| `docs/VERIFICATION.md:534` | 本节自引用（round 2 那条窄模式 grep 命令的文本） | **不动**（保留作反例） |
| `docs/CHANGELOG.md:97` / `:100` / `:103` | 本节（t28）新写的**收尾登记**，描述的就是「曾经是四类」 | 新增文本，保留 |
| `tests/cases/carbon-calc.json:971`（B44） | 减排**分类**（四类 21.6000/14.0400/13.5000/12.6000） | **不动** |
| `tests/cases/carbon-calc.json:955`（B42） | **当前口径**（登记项描述「现在正确的状态」） | **已改五类**；命中残留是句尾「本条原文的『四类』于 t28 一并改五类」这句自述 |
| `docs/PLAN.md:95/:118/:143/:620/:935/:1071`、`docs/adr/0001-account-and-sync.md:17` | **当前口径**（例外集正文） | **已改五类**（t28，7 行已从 grep 结果中消失） |

**结论：部分闭环 —「五类口径」这一条从「闭环」改为「部分闭环」**（原判撤回）。理由分两层：

1. **判据本身错了**（这是 R3 的实质）：原判据用窄模式找两个连写短语，`PLAN.md` 6 处 + `ADR-0001:17` 一处 + `tests/cases/carbon-calc.json:955` 的 **`B42.correct`** 一项共 8 处例外集语境**根本不匹配**，判「闭环」是无证据的。改宽口径后这 8 处全部显形，其中 7 处（`PLAN` 6 + `ADR` 1）是**真缺陷**、本轮已修；第 8 处是 `B42.correct`（旧原文「除「…」四类网络例外」，改写后仍因句尾自述「本条原文的『四类』于 t28 一并改五类」而留在宽口径结果里）。另：`B21.correct` 旧原文写的是「网络例外仅**四项**」、从未含「四类」，**不在宽口径 20 行基线内**，t28 也已与其余正文一并统一为五类。
2. **修完之后仍不能写「闭环」**：宽口径当前共 16 行含「四类」= 13 行仍在（20 行基线 − 7 行已改五类的真缺陷）+ 3 行本节新写的收尾登记（`docs/CHANGELOG.md:97/:100/:103`，自述「曾经是四类」）。这 13 行仍在中，10 行是**历史留痕 / 历史缺陷记录 / 减排分类**（改了就是篡改历史记录或混淆两个无关概念），另 3 行是计划表 / 基准登记项（`docs/PLAN.md:375`、`tests/cases/carbon-calc.json:955` 的 `B42.correct` 句尾自述、`:971` 的 `B44.correct`）。这 16 行**永远会命中**宽口径 grep —— 所以「宽口径 grep 零命中」不是一个能达到的目标，能要求的是**逐条判语境后 0 处属当前例外集口径**。这正是判据从「字符串命中」改为「语境判定」的原因。**故结论为「部分闭环」，而不是「闭环」。**

**网络调用点全表审查**（自写扫描，不抽样）：全仓 `.ets` 中 `hub.http.request` / `this.http.request` / `HttpPort` 调用共 **141 处**，
逐个归入五类：登录注册 / 同步 / 取价 / 备份 / 配置下发 —— **五类之外 0 处**。
未登录时这五类都返回 `NOT_LOGGED_IN` 或走「失败即整份丢弃」，本机数据不受影响。**成立。**

### 7.6 前端视觉走查（N8，本轮新增 · **未运行**）

评审 **R2** 要求对 18 个页面做视觉走查。走查需要两条腿：**能截到图** + **能判图**。本轮实测两条腿**都不存在**，且第一条比第二条更根本 —— 截图都产生不出来。

**（一）截图腿：`hdc` 未安装、无真机、无模拟器、Previewer 崩**

```
$ command -v hdc
（空）
$ hdc list targets
Command 'hdc' not found, did you mean:
  command 'htc' from deb httptunnel (3.3+dfsg-6build1)
  …（其余 15 条同形建议，略）
Try: sudo apt install <deb name>
EXIT=127
```

即：**hdc 本机未安装**（不是「装了但连不上设备」，而是连命令都没有），因此既无真机也无模拟器可取图。

```
$ ldd --version | head -1
ldd (Ubuntu GLIBC 2.43-2ubuntu2.4) 2.43
$ ls -l /dev/kvm
crw-rw---- 1 root kvm 10, 232 Oct 14 22:10 /dev/kvm
$ test -w /dev/kvm; echo $?
1
```

无 KVM 写权限 ⇒ 模拟器起不来；Previewer 崩于 **GLIBC 2.43**（本机 glibc 版本即 2.43，round 2/3 已两次实证）。**结论：18 个页面一张截图都产生不出来。**

**（二）判图腿：视觉模型不可用（`ARK_API_KEY` 在本会话不存在）**

```
$ env | grep -i ARK_API_KEY
（无输出）
$ echo $?
1
$ ls -l /mnt/c/Users/Administrator/.dsh/.env
ls: cannot access '/mnt/c/Users/Administrator/.dsh/.env': No such file or directory
```

而配置侧确实**声明**要用这个变量：

```
$ grep -n "apiKeyEnv" /mnt/c/Users/Administrator/.dsh/profiles/desktop/cordis.yml | head -1
79:        apiKeyEnv: ARK_API_KEY
$ sed -n '75,82p' /mnt/c/Users/Administrator/.dsh/profiles/desktop/cordis.yml
  config:
    providers:
      ark:
        displayName: ark
        apiKeyEnv: ARK_API_KEY
        api: openai-completions
        baseURL: https://ark.cn-beijing.volces.com/api/coding/v3
```

即 `cordis.yml:79` 声明 `apiKeyEnv: ARK_API_KEY`，而该变量在本会话**不存在**。用空 key 直接打该端点：

```
$ curl -sS -m 30 -w "HTTP=%{http_code}\n" -X POST \
    "https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions" \
    -H "Content-Type: application/json" -H "Authorization: Bearer " \
    -d '{"model":"deepseek-v3","messages":[{"role":"user","content":"hi"}]}'
HTTP=400
{"error":{"code":"InvalidParameter","message":"The parameter `` specified in the request are not valid: invalid parameter: AuthHeader. Request id: 02179222527642746c14d470d092c1c2bed457a462426b2a6b13c","param":"","type":"BadRequest"}}
```

**（三）结论与必须告知用户的事项**

- **N8 未运行，不得算作通过。** 本轮**没有任何**视觉走查结论 —— 既没有截图，也没有任何模型对页面外观的判断。
- **用户 m00004「前端子代理须有视觉模型」这条要求未满足**（配置里声明了 `ARK_API_KEY`，但本会话没有这个变量，`.dsh/.env` 也不存在，空 key 打端点直接 HTTP 400 `InvalidParameter … AuthHeader`）。**须在最终交付说明中显式告知用户。**
- 待环境可用后的补跑方式：装 `hdc` 或起模拟器 → `hdc shell snapshot_display` 逐页取图 → 用有效 `ARK_API_KEY` 调 `POST https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions` 判图。**本轮不做任何「看起来还行」的口头替代**。

### 7.2 铁律 2 · 单一计算入口

```
全仓 .ets 乘法/除法表达式穷举 236 处，排查结果：
  · pages/ 与 components/：碳因子相关乘法 0 处
  · viewmodel/net/（网络层）：乘法 0 处
  · util/CardRenderer.ets:66,70：reductionKg 赋值转发 / × CAR_KM_PER_KG（=5.21，等价展示）  非减排计算
  · pages/IncludePage.ets:62、viewmodel/IncludeService.ets:120：× CARBON_COIN_RATE（=100，碳币兑换）  非碳因子
  · DecimalUtil.mul( 全部 8 处：service/CarbonCalc.ets:153(amount×factor) / :164(×rate) /
    :258(days×kmPerDay) / :267(pieces×kgPerPiece) —— 唯一碳因子乘法在这里
$ grep -rn "SELECT \|INSERT INTO\|UPDATE \|DELETE FROM" --include=*.ets \
    app/entry/src/main/ets/pages app/entry/src/main/ets/components
（零命中）  ← 页面层不做数据库读写
```

减排量的赋值/转发点只有 4 处：`service/CarbonCalc.ets:88`、`service/CarbonService.ets:52`、`util/CardRenderer.ets:66`（转发）、`viewmodel/ShareService.ets:113`（`numOf(r,'reduction_kg')` 读库）。
**成立**：减排量只由 `CarbonService.calculate()` → `CarbonCalc` 产出，页面层既不乘因子也不写 SQL。

### 7.3 铁律 3 · 因子快照四字段

```
app/entry/src/main/ets/data/schema/ClientSchema.ets:85   factor_value REAL NOT NULL -- 因子快照（铁律 3）
                                                         （factor_version / factor_source / confidence 同段四列 NOT NULL）
app/entry/src/main/ets/service/CarbonService.ets:189-196  static snapshotOf(factorValue, factorVersion, factorSource, confidence): FactorSnapshot
                                                         ← 四字段的唯一构造点
app/entry/src/main/ets/data/dao/CarbonRecordDao.ets:48   插入列含 factor_value, factor_version, factor_source, confidence
app/entry/src/main/ets/viewmodel/RecordService.ets:380/:452  更新与查询同四字段
回填（唯一一处）：仅针对「本来没有因子值的历史行」按当前因子库补齐 —— 不是「升级因子库后回写历史」
```

**成立**。

### 7.4 铁律 4（上）· 流水只增不删

```
$ grep -rn "UPDATE point_record\|DELETE FROM point_record\|delete from point_record" \
    --include=*.ets app/entry/src/main/ets
（零命中）
$ 同上 --include=*.py --include=*.sql server/
（零命中）
冲正：app/entry/src/main/ets/viewmodel/PointService.ets:190  async reverse(userId, type, points, sourceId, title, occurredAt)
      :195  type: 'reverse'，写一条**负额新行**，原 primary 行一条不改
软删除：只打 is_deleted = 1（不做物理删除），按普通行传播（附录 B §6.4）
```

**成立**。

### 7.5 铁律 4（下）· `余额 = 收入合计 − 支出合计`

```
客户端  app/entry/src/main/ets/viewmodel/PointService.ets:87-101  balance(userId, now)
        'COALESCE(SUM(points), 0) AS bal FROM point_record WHERE user_id = ? AND is_deleted = 0'
        （不读缓存 point_daily_stat，理由写在 :14-15）
家庭合并 app/entry/src/main/ets/viewmodel/net/SyncService.ets:362（成员）/ :377（合计）
        两处均为裸 COALESCE(SUM(points),0)，:342-344 注释说明与 balance() 逐字一致
后台    server/admin_web/services/stats.py  totalPointsBalance = total_issued - total_spent
独立算术 §4.8 G1/G2/G3 = 170 / 0 / 100，三组全部相等
```

**成立**。> 缺口如实说明：本轮**没有**做运行态余额对账（需真机 + 真实库），只有源码口径 + 独立算术。

---

## §8 未登录态不发起上传（V14，**静态核查**）

`app/entry/src/ohosTest/ets/test/NotLoggedIn.test.ets`（70 行）全文核查：

```ts
const http: FakeHttpClient = new FakeHttpClient();                    // 注入假 HttpClient
const hub: ServiceHub = await ServiceHub.init(context, now, { http: http, files: new MemoryFiles() });
await hub.setBreakSave(false, now);
await hub.auth.logout(now);                                           // 确保未登录
await hub.state.ensureUser(userId, now);
expect(hub.state.isLoggedIn()).assertFalse();
const syncResult = await hub.sync.sync(userId, now);         expect(syncResult.code).assertEqual('NOT_LOGGED_IN');
const upload     = await hub.sync.fullUpload(userId, now);    expect(upload.code).assertEqual('NOT_LOGGED_IN');
const restore    = await hub.sync.fullRestore(userId, now);   expect(restore.code).assertEqual('NOT_LOGGED_IN');
expect(http.count()).assertEqual(0);                                  // ← :48  第一次计数 = 0
const saved  = await hub.records.save(userId, {…}, now);     expect(saved.ok).assertTrue();   // 单机记录照常
const backup = await hub.backup.create(now);                 expect(backup.ok).assertTrue();  // 单机备份照常
expect(http.count()).assertEqual(0);                                  // ← :62  第二次计数 = 0
const status = await hub.sync.status(userId);                expect(status.loggedIn).assertFalse();
```

**假客户端是否真的会计数**（`app/entry/src/main/ets/viewmodel/net/HttpPort.ets`）：

```
:131  export class FakeHttpClient implements HttpPort {
:146    async request(req: HttpRequest): Promise<HttpResponse> { this.log.push(req); … }
:191-193  count(): number { return this.log.length; }
```

**被验证实现是否真的在发请求之前拦截**（`app/entry/src/main/ets/viewmodel/net/SyncService.ets`）：

```
:171-176  async sync(userId, now)        首行 if (!this.state.isLoggedIn()) return fail('NOT_LOGGED_IN', …)
:223-228  async fullUpload(userId, now)  同上
:272-277  async fullRestore(userId, now) 同上
:149-166  async status(userId)           纯本机查询（pendingCount / cfg.stamp / logs / device_info COUNT），无 HttpPort 调用
app/entry/src/main/ets/viewmodel/BackupService.ets —— 构造参数只有 (store, state, files)，**没有 HttpPort 字段**，
                                                       结构上不可能发请求（grep "http" 该文件零命中）
```

**结论**：用例确实用「注入假 HttpClient + `count()` 断言为 0」证明游客态零上传；
两条计数断言分别卡在「三件套之后」与「写记录 + 建备份之后」，中间夹着两处「单机功能照常」的正向断言 —— 逻辑成立。
**但本机未运行（N1），不算通过。** 本报告只判「用例写得对、被验证实现确实短路」，不判「用例已执行通过」。

---

## §9 契约一致性抽查（V15）

### 9.1 A. `app/` 建表 SQL ↔ `docs/APPENDIX-B-data-and-api.md` §2

```
客户端 19 张表（app/entry/src/main/ets/data/schema/ClientSchema.ets）与附录 B §1.2 的 19 张：**逐名全等**
服务端 21 张 = 附录 B §1.2 的 19 张 − science_article + §3 的 server_user / admin_user / admin_op_log
    → Python 集合比对：21 表逐名全等 True；服务端独有 = 上述三张管理表；缺 = 无
18 张同名表逐列（列名）比对：**全部全等**
    · 唯一预期差异：附录 B 有 sync_state、服务端无 —— docs/APPENDIX-B-data-and-api.md:62 原文
      「sync_state | TEXT DEFAULT 'local' | — | local/synced/pending（仅客户端）」
      → 服务端无此列是**正确**（server/sql/schema.sql:10 注释亦写明），不是缺陷
§3 三张管理表：20 列逐名全等
```

**方法坑（写下来避免后人重复）**：附录 B 的 DDL 表名**无引号、缩进 0**，服务端用 `` `table` `` 反引号 —— 正则要两版；
服务端 §3 三张表名**无反引号**，统一按反引号匹配会解析失败返回 None。

### 9.2 B. 类型映射（附录 B §1.3：`TEXT → VARCHAR(n)/TEXT`、`INTEGER → BIGINT/INT/TINYINT`、`REAL → DOUBLE`）

```
§2 的 18 张表：192 个「列 → 类型」对，**违反映射 0 处**
§3 的三张管理表：20 个类型对，**违反 0 处**
```

> 未归一化方言时「18/18 表类型全不同」是 **SQLite ↔ MySQL 方言差异**，属预期；按 §1.3 映射后为 0 差异。

### 9.3 C. 因子库三向比对：附录 A §2.5 ↔ 基准 `factors`(31) ↔ `app/…/carbon-factors.json`(30 + `CAR_OWN_FACTOR`)

```
$ python3 /tmp/cbv24/factor3way.py
附录 A 解析行数: 30
  A: walk       {'num': 1,  'own': '0.0000', 'value': '0.1920',  'source': 'SRC-DERIVED',        'confidence': 'provisional', 'rec': '✅'}
  A: car        {'num': 8,  'own': '0.1920', 'value': '0.0000',  'source': 'SRC-CALC',           …               'rec': '❌'}
  A: elec_grid  {'num': 12, 'unit': 'kg/kWh', 'value': '0.5703', 'source': 'SRC-MEE-GRID-2022', 'confidence': 'verified',    'rec': '✅'}
  A: water      {'num': 13, 'value': '0.000168', 'source': 'SRC-CALC', 'confidence': 'provisional', 'rec': '✅'}
  A: paper      {'num': 20, 'value': '0.9000',   … 'rec': '✅'}
  A: meal       {'num': 28, 'value': '0.3500',   … 'rec': '✅'}
  A: kitchen_waste {'num': 30, 'value': '0.9000', … 'rec': '❌'}
CAR_OWN_FACTOR: 基准= 0.1920  app.conversions= 0.192  附录A §2.6=0.1920
app 统计: {'total': 30, 'rec_true': 20, 'rec_false': 10, 'verified': 3, 'provisional': 27}
分类计数: {'travel': {'n': 11, 't': 7, 'f': 4}, 'utility': {'n': 8, 't': 5, 'f': 3},
          'recycle': {'n': 8, 't': 6, 'f': 2}, 'plate': {'n': 3, 't': 2, 'f': 1}}
factors 版本: 基准 meta.factorVersion= CF-2026.2  app meta.version= CF-2026.2
points 段: 基准 {'pointsPerKgCo2e': 100, 'dailyRecordCap': 200, 'minReductionForPoint': '0.005', 'carbonCoinRate': 100}
           app  {'perKgCo2e': 100, 'dailyRecordCap': 200, 'minReductionForPoint': 0.005, 'carbonCoinRate': 100}
---
OK 因子库三向比对全部通过（30 条逐字段 + CAR_OWN_FACTOR + §2.5 统计 + 编号 + 顺序 + points）
$ echo $?
0
```

逐条比对字段：`value`（Decimal 相等）/ `source` / `confidence` / `recording` / `unit`，**三向全部一致，不一致 0 处**。
附录 A §2.5 声称的五项统计（总数 30 / `recording:true` 20 / `recording:false` 10 / `verified` 3 / `provisional` 27）
与四个分类的 (n, true, false) 三元组**全部实测命中**；编号 #1–#30 连续且与基准顺序一致。

**30 + `CAR_OWN_FACTOR` = 31 是设计如此，不是缺陷**（附录 A §2.5 原文：「收录本表全部 30 条 + 换算常量
`CAR_OWN_FACTOR` 1 条 = 31 项」，`app` 侧由 `FactorLibrary` 从 `conversions` 合成第 31 项）。

---

## §10 L1 静态审计（V16；**未运行，不判其通过**）

### 10.1 登记表 ↔ 实际调用（`app/entry/src/ohosTest/ets/test/List.test.ets`）

```
import = 10   调用 = 10   一一对应 = True   悬空调用 = 0
  calcSamples / notLoggedIn / goalIdempotent / badgeIdempotent / shopPurchase
  backupRoundTrip / csvExport / lwwMerge / shopPriceFallback / serverConfigFallback
```

### 10.2 契约点名的 9 个套件逐个

| 契约点名 | 文件存在 | 完整编写 | 登记进 `List.test.ets` | `it()` | 行数 | 运行 |
|---|---|---|---|---|---|---|
| `CalcSamples` | ✅ `CalcSamples.test.ets` | ✅ 6 个 `it()`：基准 18+5+边界逐条复算 / 唯一计算入口 / half-up / 定点乘法 / 超限 / 目标奖励不封顶 | ✅ | 6 | 159 | **未运行** |
| `PointCap` | ❌ **不存在**（F17；`grep -rn PointCap app/` 源码零命中） | 5 组封顶由 `CalcSamples.test.ets:78` `expect(bench.capSamples.length).assertEqual(5);` + `CalcBaselineValidator.ets:210-224` 承载 | —（无文件可登记） | 0 | — | **未运行** |
| `GoalIdempotent` | ✅ | ✅ | ✅ | 1 | 85 | **未运行** |
| `BadgeIdempotent` | ✅ | ✅ | ✅ | 1 | 76 | **未运行** |
| `ShopPurchase` | ✅ | ✅ | ✅ | 1 | 100 | **未运行** |
| `BackupRoundTrip` | ✅ | ✅（19 表逐表行数往返） | ✅ | 1 | 125 | **未运行** |
| `CsvExport` | ✅ | ✅（BOM + CRLF + 列序 + RFC4180） | ✅ | 1 | 112 | **未运行** |
| `LwwMerge` | ✅ | ✅ ①–⑩ 编号 10/10 无缺号 | ✅ | 10 | 799 | **未运行** |
| `NotLoggedIn` | ✅ | ✅（假 HttpClient 计数 0 ×2 处，§8） | ✅ | 1 | 70 | **未运行** |
| （额外）`ShopPriceFallback` | ✅ | ✅ | ✅ | 6 | — | **未运行** |
| （额外）`ServerConfigFallback` | ✅ | ✅ | ✅ | 8 | — | **未运行** |
| **合计** | — | — | **10/10 登记一致** | **36** | — | **全部未运行** |

> `CalcBaselineValidator.ets`（585 行）与 `CalcTestTypes.ets`（313 行）不含 `it()`，是被 import 的断言库/类型定义。

### 10.3 本机未运行及原因（证据链，本轮重跑）

| 证据 | 原始输出 |
|---|---|
| **无真机** | `hdc list targets` → stderr **`Connect server failed`**，stdout 无任何设备行（`hdc` = `~/harmony-toolchain/clt/command-line-tools/sdk/default/openharmony/toolchains/hdc`，5,064,720 B） |
| **无模拟器** | `ls -l /dev/kvm` → `crw-rw---- 1 root kvm 10, 232 …`；`test -w /dev/kvm` → **kvm NOT writable**（当前 uid 1000 不在 kvm 组） |
| **预览器不兼容** | `ldd --version` → **GLIBC 2.43**；SDK Previewer 二进制在此 glibc 上触发 `pthread_mutex_lock` robust 断言崩溃（round 1/2 实测原文留档于备份） |
| **`hvigorw test`** | 仓库工作树（含 `oh_modules`）实跑：`Finished :entry:default@UnitTestArkTS... after 19 s 880 ms` 之后**再无任何输出**，`timeout 420` → **EXIT=124** |

**因此：36 个 `it()` 全部是「已编译、未执行」。本报告不把任何一条算作通过。**

> **（t38 补记，不改本条判定）** 上表审计的是「hypium 用例是否执行」，结论照旧：**一条都没执行**。
> 需要与它分开陈述的是另一条证据：`tests/tools/l1_offline/` 用 esbuild 转译 `app/` 下 9 份真实 `.ets` 并在 Node 里
> 执行 `CarbonCalc` 与仓库自己的 `CalcBaselineValidator`，得 `RESULT: PASS=55 FAIL=0`、`checked=323 passed=true`（§R5）。
> 它是「纯逻辑层的可复现旁证」，**不是** §10 任何一行 `it()` 的运行记录，也不改变本节的「全部未运行」。

---

## §11 工程规范抽查（V19，AGENTS.md §7.1）

```
$ grep -rn ": any\b\|@ts-ignore\|<any>" --include=*.ets app/entry/src/main/ets | grep -v "^\S*:\s*\*"
（零命中）        ← 禁用 any / @ts-ignore 落实
$ grep -rn "SELECT \|INSERT INTO\|UPDATE \|DELETE FROM" --include=*.ets \
    app/entry/src/main/ets/pages app/entry/src/main/ets/components
（零命中）        ← 页面层不直连 Dao
$ grep -rn "from '../data/dao" --include=*.ets app/entry/src/main/ets/pages app/entry/src/main/ets/components
app/entry/src/main/ets/pages/Index.ets:47  import { CarbonRecordDao } from '../data/dao/CarbonRecordDao';
app/entry/src/main/ets/pages/Index.ets:48  import { ResultSetMapper } from '../data/dao/ResultSetMapper';
```

后两条是 `Index.ets` 文件头 **⚠️ 段明写的「刻意的编译图锚点」**（`:13-20` 原文：「t4 重写本页时它们一度不在编译图里…
t21 按验收要求把它们显式接入本页…业务路径上它们仍**不作为**数据通道使用（t4 起数据层是 `viewmodel/store/*`）」），
页面层无任何 **SQL**、也不调用 Dao 方法，**不构成跨层直连**。

---

## §12 新发现的问题（F15–F18，**我未做任何修改**）

### 12.1 F15（低）未提交的验证报告无法从仓库恢复

- **现象**：
  ```
  $ git log --all --oneline -- docs/VERIFICATION.md
  （零条）
  $ git show 971d042:docs/VERIFICATION.md
  fatal: path 'docs/VERIFICATION.md' exists on disk, but not in '971d042'
  ```
- **后果**：round 1（853 行）与 round 2（783 行）的全文只存在于本机 `/tmp`。`/tmp` 不是仓库，重启/清理即失。
- **本轮处置**：新建两份备份到 `/tmp/cbv24/ev/`：
  `VERIFICATION-round1-backup.md`（md5 `b6bf1ccbaa0f5080d3516dc101b9ffe0`）、
  `VERIFICATION-round2-backup.md`（md5 `d12abec7ec1fff474c54affbaa6a3b2a`）。**仍是 `/tmp`，不解决根本问题。**
- **建议**：报告一经产出即入库（前缀 `docs:`）；轮次历史用「同一文件多次提交」保住，而不是靠 `/tmp` 备份。

### 12.2 F16（低）`git archive` 副本跑 `hvigorw test` 会假失败（方法学陷阱）

- **现象**（副本 `/tmp/cbv24/app`，`308d09f` 导出）：
  ```
  "@ohos/hypium" is imported by "entry/.test/testability/pages/Index.ets", but could not be resolved …
  > hvigor ERROR: Failed :entry:default@UnitTestArkTS...
  1 ERROR: ArkTS:ERROR Failed to resolve OhmUrl.
  COMPILE RESULT:FAIL {ERROR:2}
  > hvigor ERROR: BUILD FAILED in 8 s 280 ms          EXIT=255
  ```
- **根因**：`.gitignore:29 oh_modules/` → 副本里 `app/oh_modules`（332 K）与 `app/entry/oh_modules` 不存在。
  仓库工作树上同一命令 `Finished :entry:default@UnitTestArkTS... after 19 s 880 ms`，**编译段通过**。
- **判据**：这是**副本的方法学缺陷**，不是被测代码缺陷。`assembleHap` 不受影响（主 HAP 不依赖 hypium）。
- **建议**：任何用 `git archive` 副本验 L1 的人，先把 `app/oh_modules` 与 `app/entry/oh_modules` 拷进副本，否则会把环境问题误判成编译错误。

### 12.3 F17（低·信息）契约点名的 `PointCap` 套件仍不存在（F10 的复述）

- `grep -rn "PointCap" app/` → 源码**零命中**（唯一命中是 `.agent-teams/` 的 team.json 与本轮任务书文本）。
- `tests/README.md:67` 已把它记为 `~~PointCap.test.ets~~`（并入 `CalcSamples`）。
- **封顶 5 组确有承载**：`CalcSamples.test.ets:78` + `CalcBaselineValidator.ets:210-224`（`// ---- 2) 5 组封顶样例 ----` 段）。
- **不是代码缺陷**，但**契约文本仍在点名一个不存在的文件名**，每轮都要重新解释一次。

### 12.4 F18（低·信息）任务书给的 MySQL 凭据第三轮仍不可用（F7/F13 复现）

- 任务书写 `root/cbpass123`；实测 `127.0.0.1:13307` 用该凭据返回 **1045 Access denied**。
- 真实凭据在 `server/.env`：`MYSQL_USER=carbonboo` / `MYSQL_PASSWORD=…`。
- **不是代码缺陷**；建议任务书直接写「凭据见 `server/.env`，不要抄任务书里的字符串」。

### 12.5 撤销的旧缺陷：F14

**F14 改判为「不是缺陷，是复算必须用 Decimal 的约束」**（队长裁定，我复核后同意）：

- `tests/cases/carbon-calc.json:422` `samples[8].amount = "16"` 与 `:336` `conversions.car-free-days.expect.amount = "16.0"` 是**不同用例的不同输入**，数值语义都是 16，只是书写形式不同；`amount` 字段本身就是**字符串类型**。
- **想为此把基准改成统一形式是错的**：那等于为了让测试好写而改真相源 —— `AGENTS.md §5` 明令禁止。
- 正确约束（本轮已执行）：任何复算**必须用 `Decimal` 比较，不得用字符串相等或裸 float**。round 2 首跑的那次假失败正是踩了这个，当时改的是**比对方式**而不是基准，处理正确；只是把它报成 finding 定性偏保守。

---

## §13 未能真实运行的验证项（**不得算作通过**）

| 编号 | 项 | 原因（实证见 §10.3 / §6 说明） | 替代证据及其效力 |
|---|---|---|---|
| **N1** | L1 全部 hypium（10 套件 / 36 `it()`） | 无真机（`hdc` = `Connect server failed`）、无模拟器（`/dev/kvm` 不可写）、SDK Previewer 崩于 GLIBC 2.43 | 离线复算 70/70（**不等价**：不经过 ArkTS 运行时，不验证 `CarbonCalc` 的实际实现，只验证基准自洽与我的独立算术）。**（t38 补记）** 后半句已过时：`tests/tools/l1_offline/` **确实**执行 `CarbonCalc.ets` 与 `CalcBaselineValidator.ets` 的真实实现（esbuild 转译 + Node，非重写），故它强于「只验证基准自洽」；但它仍不经过 ArkTS 运行时与 OHOS 环境、不覆盖 UI/DB/网络/生命周期，**36 个 `it()` 仍未运行** ——「不等价」这个总判断成立（§R5） |
| **N2** | `hvigorw test` 执行段 | 编译段通过后 `timeout 420` **EXIT=124**，零用例输出 | 「编译通过」≠「用例通过」 |
| **N3** | L2 端侧集成 | 需两条设备 | 无 |
| **N4** | 部署脚本实跑（systemd/nginx/TLS/定时备份） | 本机无部署目标（`/opt/carbonboo/…` 不存在、nginx 未装） | round 2 的 `bash -n` / `systemd-analyze verify` / `migrate.sh --dry-run`（EXIT=0）与安全阀（EXIT=2）；**本轮未重跑（环境未变）** |
| **N5** | `/admin` 浏览器交互（SSR 渲染、`admin.js`） | 无浏览器驱动 | HTTP/JSON 层已实测（§6.2） |
| **N6** | t18 运行态（配置下发在真机生效） | 同 N1 | 用例存在且登记（未运行） |
| **N7** | t13 运行态（真机备份往返） | 同 N1 | 服务端侧备份用例真实通过（`test_sync.py` 48 passed） |
| **N8** | 前端视觉走查（18 页面截图 + 视觉模型判图） | 截图腿：`hdc` 未安装（`Command 'hdc' not found`，EXIT=127）、无真机无模拟器（`/dev/kvm` 不可写）、Previewer 崩于 glibc 2.43 ⇒ **18 个页面一张截图都产生不出来**；判图腿：`ARK_API_KEY` 在本会话不存在（`cordis.yml:79` 声明该变量，但 `env` 为空、`.dsh/.env` 不存在，空 key 打端点得 HTTP 400 `InvalidParameter … AuthHeader`） | **无** —— 本轮零视觉结论。**用户 m00004「前端子代理须有视觉模型」一条未满足，须在最终交付说明中显式告知**（原始输出见 §7.6） |

> 另：**L3 全量本轮未执行** —— 本轮口径是「`server/` 零 diff，只跑子集」。我跑了 `test_sync.py`（48）+
> `test_admin.py` 403 子集（19），是**真实结果**；其余 66+ 例未跑。全量 **237 passed** 是 **round 2 在 `971d042` 上的实测**，
> 本报告引用它时已注明来源与基准不同。

> **t31 复核补正（round 4）**：上表 N1–N8 本轮逐条核对，结论未变（环境未变，五项仍未运行，一条不算通过）。
> 其中 **N1 / N8 关于 `hdc` 的表述需精确化**：`hdc` 确实不在 `PATH`（`Command 'hdc' not found`，EXIT=127），
> 但 SDK 内存在该二进制 `$HARMONY_TOOLCHAIN/sdk/default/openharmony/toolchains/hdc`（5,064,720 B），
> 直接调用得 `Connect server failed`（无设备服务端）—— 两者说的是同一件事（无真机），
> 不应被读成「换一个 hdc 就能跑」。本轮 L3 已改为**全量 237 passed**（上段「L3 全量本轮未执行」是 round 3 的口径，已被 §R4 覆盖）。

---

## §14 未决问题

1. **L1 何时能真跑**：本机无设备、无模拟器、Previewer 与 GLIBC 2.43 不兼容 —— 这三条都不是「再试一次」能解决的。在拿到真机或修复 Previewer 兼容性之前，`CalcSamples / LwwMerge / NotLoggedIn` 等 36 个用例**只能算「已编写、已登记、已编译」，不能算「已通过」**。
   **（t38 补记）** 这句话说的是 hypium；纯逻辑部分此后有了一条可复现的独立离线证据（`bash tests/tools/l1_offline/run.sh`：`PASS=55 FAIL=0`、`checked=323 passed=true`，见 §R5）。**它不改变本条的「不能算已通过」**，只是让「L1 完全无证据」的说法不再成立。
2. **报告入库**：见 F15。本文件一旦提交，后续轮次才有 git 历史可依赖。
3. **`PointCap` 口径**：见 F17。建议把契约里的 `PointCap` 改为「5 组封顶（承载于 `CalcSamples` + `CalcBaselineValidator`）」。
4. **L3 全量的时效**：237 passed 是 `971d042` 上的实测；`server/` 自那以后零 diff，结论可沿用，但**任何一次 `server/` 改动都必须重跑全量**。
5. **`fa91daa` 上的完整复验**：本轮被验证对象是 `308d09f`；`fa91daa` 只改了 `AGENTS.md` / `tests/README.md` / `docs/CHANGELOG.md`（被测代码零差异），我已补跑 L0（EXIT=0）与复算（70/70）复核，其余章节未在 `fa91daa` 上重跑。

---

## §15 证据文件（均在 `/tmp/cbv24/` 下，易失、**未写入仓库**）

| 文件 | 内容 |
|---|---|
| `/tmp/cbv24/` | `git archive 308d09f` 导出的 292 个文件（编译副本，注入 4 次后已全部字节级回滚） |
| `/tmp/cbv24/ev/recompute.py` / `.log` | 独立复算脚本（8,873 B，只读基准 JSON，`Decimal` + `ROUND_HALF_UP`）与 70 检查点全文输出 |
| `/tmp/cbv24/ev/l0.log` | `check_l0.py --strict` 原始输出 |
| `/tmp/cbv24/ev/factor3way.py` / `.log` | 因子库三向比对脚本与输出 |
| `/tmp/cbv24/contract_cols.py` | 服务端 21 表逐列 / 类型映射比对脚本 |
| `/tmp/cbv24/modprobe.py` | `pages/Index.ets` import 闭包脚本 |
| `/tmp/cbv24/hvigorw-test-main.log` | 仓库工作树 `hvigorw test`（`UnitTestArkTS` + `EXIT=124`） |
| `/tmp/cbv24/hvigorw-test.log` | 副本 `hvigorw test`（`Failed to resolve OhmUrl` + `EXIT=255`，F16 证据） |
| `/tmp/cbv24/ev/VERIFICATION-round2-backup.md` | round 2 全文（783 行，md5 `d12abec7ec1fff474c54affbaa6a3b2a`） |
| `/tmp/cbv22/ev/VERIFICATION-round1-backup.md` | round 1 全文（853 行，md5 `b6bf1ccbaa0f5080d3516dc101b9ffe0`） |

---

## 附：AGENTS.md §8 格式对照（任务 → 改了什么 → 跑了什么命令 → 结果 → 未决问题）

**任务**：t24 —— 独立验证 round 3（L0 / L1 静态 / L3 子集 / 独立复算 / 契约抽查 / 四条铁律 / 编译门禁注入自证 / 未运行项如实单列）。

**改了什么**：只有 `docs/VERIFICATION.md`（本文件，覆盖写）。`git status --short` 全程只有 `?? docs/VERIFICATION.md`。
被测源码 / 文档 / 基准 JSON / 测试期望值**一个字节都没动**。

**跑了什么命令**（完整原文见各 §）：

```
python3 tests/tools/check_l0.py --strict                                      → EXIT=0
md5sum tests/cases/carbon-calc.json                                           → c096da45ba7e1852d25cf91699fcb42b
python3 -c "…print(len(d['samples']),…)"                                      → 18 5 6 31
python3 /tmp/cbv24/ev/recompute.py                                            → 检查点 70 / 失败 0 / EXIT=0
python3 /tmp/cbv24/factor3way.py                                              → OK / EXIT=0
esbuild …/DecimalUtil.ets --outfile=/tmp/cbverify/DecimalUtil.mjs              → EXIT=0
node /tmp/cbverify/verify.mjs                                                 → RESULT: PASS / EXIT=0
git archive 308d09f | tar -x -C /tmp/cbv24 && cd /tmp/cbv24/app &&
  hvigorw --no-daemon assembleHap    → 基线 SUCCESSFUL(0) / 注入 ×4 FAILED(255) / 回滚 ×4 SUCCESSFUL(0)
cd server && CARBONBOO_TEST_DB=carbonboo_test_t24 .venv/bin/python -m pytest tests/test_sync.py -q   → 48 passed / EXIT=0
cd server && CARBONBOO_TEST_DB=carbonboo_test_t24 .venv/bin/python -m pytest tests/test_admin.py -q \
  -k "forbidden or not_accepted or different_keys"                                                    → 19 passed, 66 deselected / EXIT=0
hdc list targets                                                              → Connect server failed
test -w /dev/kvm                                                              → NOT writable
cd app && hvigorw --no-daemon test                                            → EXIT=124（UnitTestArkTS 后静默）
```

**结果**：L0 通过；独立复算 70/70；契约 A/B/C 全等；编译门禁 4 组注入自证成立且副本零污染；
铁律 1/2/3/4 全部成立；未登录态证据链成立（静态）；L3 子集 67 例真实通过（48 + 19）。
**L1 全部未运行**（N1–N7，环境未变，本轮补跑证据）。F9/F12 闭环，F14 撤销，新增 F15–F18（四条低危）。

**未决问题**：见 §14（五条）。

---

## 本轮更正（t33 · 对 F2/F3/F4/F5/F6 的追加更正，**不改动上文任何原始记录**）

> 来源：t32 终审（`c9a3f1d`）报出的 F2/F3/F4/F5/F6。本节**只追加**：上文 round 1–4 的原始章节一字不删、不改写其结论
> （唯一原位改动是 §7.1 表内一处**函数名事实错误**的更正，见 C-F5——那是错标订正，不是改写判定）。
> 本节所有依据均为现场重跑的原始输出；基准为更正写入前的 HEAD `c9a3f1d`。

### C-F2 · §R4.3 两条「沿用」理由与实测不符（结论偶然对，证据全错）

§R4.3 表内两行原文的依据是「`git diff … -- tests/cases/` 为空且 md5 与 round 3 同值」「`git diff --stat 308d09f..e211ae1 -- app/ server/` 为空」。现场重跑：

```
$ git diff --stat 308d09f..e211ae1 -- app/ server/
 app/entry/src/ohosTest/resources/rawfile/carbon-calc.json | 4 ++--
 1 file changed, 2 insertions(+), 2 deletions(-)

$ git diff --stat 308d09f..e211ae1 -- tests/cases/
 tests/cases/carbon-calc.json | 4 ++--
 1 file changed, 2 insertions(+), 2 deletions(-)

$ git show 308d09f:tests/cases/carbon-calc.json | md5sum
c096da45ba7e1852d25cf91699fcb42b  -
$ md5sum tests/cases/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  tests/cases/carbon-calc.json
```

⇒ ① 「`app/` / `server/` 未被这些提交触碰」**不成立**（t30-O1 同步了 `ohosTest` 基准副本，2 增 2 删）；
② 「本轮 md5 与 round 3 记录同值」**不成立**（`c096da45…` → `e096b2db…`，t28 改了 `docConflicts` 文本）；
③ 连「`tests/cases/` 为空」也不成立（同一批 2 增 2 删）。
被改的只是 `docConflicts` **元数据文本**，`samples` / `capSamples` / `factors` 期望值零变化（L0 `--strict` EXIT=0 可证），
故「§4 复算 70 检查点、§9 契约 A/B/C 可沿用 round 3」的**结论仍然成立** —— 但它当时给出的两条证据是错的，属「结论偶然对，证据全错」。

### C-F3 · §R4 首段「round 1–3 原文一字未删」不实

```
$ git diff --numstat 39be3b0..284c069 -- docs/VERIFICATION.md
511	5	docs/VERIFICATION.md
```

⇒ 该区间 **511 增 5 删**。被删的 5 行（原文）：

```
-# CarbonBoo 独立验证报告（round 3 · t24）
-| **V9** | 铁律 1 · 未登录 = 纯单机（五类例外） | 三处例外集 grep + 141 个网络调用点全表审查 | … |
-| **F3** 例外集四类 → 五类 | 已修 | `AGENTS.md:104`（§2 铁律 1）/ `:143`（§5 L2）/ `:164`（§6）… | **闭环** |
-$ grep -rn "四类网络例外\|四类例外" --include=*.md .   （排除 build/ 与 .agent-teams/）
-唯一命中 docs/VERIFICATION.md:171 —— 是 round 2 报告里那条 grep 命令的文本本身，非口径残留
```

⇒ 正是 V9/F3 的旧判据与「窄模式假绿」证据（窄模式 `grep "四类网络例外"` 抓不到措辞变体「四项」），
round 4（t31）为改用宽口径判据而**替换**了它们。所以「一字未删」的自我描述与该 diff 直接矛盾：
round 4 实际做的是「新增 §R4 + 把部分旧判据**替换**为宽口径判据」。本轮（t33）起不再使用「一字未删」表述。

### C-F4 · 「141 处网络调用点」的口径是 token 计数，不是调用点数

`§0`/`§7.1` 引用的「全仓 `.ets` 网络调用 **141 处，五类之外 0 处**」在现场重跑中复现不出 141 个**调用点**：

```
$ grep -rn 'hub\.http\.request' --include=*.ets app/ | wc -l      → 0
$ grep -rn 'this\.http\.request' --include=*.ets app/ | wc -l     → 10
$ grep -rn 'HttpPort' --include=*.ets app/ | wc -l                → 38   （按出现次数 44）
（三模式相加：按出现次数 0 + 10 + 44 = 54；按行数 0 + 10 + 38 = 48 —— 都不是 141）
$ grep -roE 'http|HttpPort' --include=*.ets app/ | wc -l          → 141  ← 141 的真实来源
```

⇒ 141 是 **token 计数**（`grep -roE 'http|HttpPort'`，把注释、类型名、字符串、`FakeHttpClient` 一并计入），
**不是调用点数**。真实**网络调用点 11 处**（现场实测）：

```
app/entry/src/main/ets/viewmodel/AuthService.ets:67 / :82 / :98            注册 / 登录 / 注销
app/entry/src/main/ets/viewmodel/net/ServerConfigFetcher.ets:106           配置下发 GET /api/v1/config
app/entry/src/main/ets/viewmodel/net/ShopPriceFetcher.ets:114              商品取价
app/entry/src/main/ets/viewmodel/net/SyncService.ets:183 / :192 / :234 / :281 / :304   同步 push / pull + 云端备份
app/entry/src/main/ets/viewmodel/net/HttpPort.ets:91                       传输层自身（http.request 唯一出口）
```

11 处逐条落在**五类例外**（登录/注册、多设备同步、取价、云端备份、配置下发）之内，
**「五类之外 0 处」的实质结论仍成立**；但「141 处」这个数字及其「全表审查」表述属**错误口径**，
应读作「141 个 token / **11 个调用点**」。

### C-F5 · §7.1 表内 `CarbonCalc.ets:258/:267` 函数名标错（**已在原位更正**）

§7.1 表原文写「`:258`（树当量）、`:267`（纸张当量）」。现场实测该两行的真实归属：

```
$ grep -n "static amountOf" app/entry/src/main/ets/service/CarbonCalc.ets
257:  static amountOfCarFreeDays(days: number, kmPerDay: number): number {
266:  static amountOfRecyclePieces(pieces: number, kgPerPiece: number): number {
$ sed -n '258p;267p' app/entry/src/main/ets/service/CarbonCalc.ets
    return toNumber(Dec.fromInt(days).mul(Dec.from(kmPerDay)), AppConstants.REDUCTION_DECIMALS);
    return toNumber(Dec.fromInt(pieces).mul(Dec.from(kgPerPiece)), AppConstants.REDUCTION_DECIMALS);
```

⇒ `:258` 属 `amountOfCarFreeDays`（少开一天车：天数 × 单车里程）、`:267` 属 `amountOfRecyclePieces`（回收按件：件数 × 单件重量），
**与「树当量 / 纸张当量」无关**（`Dec.mul` 只有四处落点、同在一个文件，四面都是「活动量 × 因子」的形态）。
已就地把改处两个标签改为真实函数名，行号与「四处全在同一文件」的结论不变；
本文件 :1050 原已按正确口径写作 `:258(days×kmPerDay) / :267(pieces×kgPerPiece)`，两处现已一致。

### C-F6 · 两套未运行项编号同号不同义（补映射表，**不重写任一处编号**）

本文件存在两套 `N1–Nn` 编号，语义不同，此前无任何提示：

| 位置 | 编号域 | 含义 |
|---|---|---|
| §R4.7（round 4 / t31） | **N1–N5** | 绑定 `e211ae1` 的本轮未运行项：N1 L1 全部 hypium、N2 L2 端侧集成、N3 `server/deploy/` 实跑、N4 `/admin` 浏览器交互、N5 视觉模型走查 |
| §13（round 3 / t24） | **N1–N8** | 历史轮次未运行项：N1 L1、N2 `hvigorw test` 执行段（EXIT=124）、N3 L2、N4 部署脚本、N5 `/admin` 交互、N6 t18 运行态、N7 t13 运行态、N8 视觉走查 |

同义对应（映射）：

| §R4.7 编号 | §13 编号 | 项 |
|---|---|---|
| N1 | N1 | L1 全部 hypium（10 套件 / 36 `it()`） |
| N2 | N3 | L2 端侧集成（需两条设备） |
| N3 | N4 | `server/deploy/` 实跑（systemd / nginx / TLS / 定时备份） |
| N4 | N5 | `/admin` 浏览器交互（SSR 渲染 + `admin.js`） |
| N5 | N8 | 视觉走查（18 页面截图 + 判图） |
| （无） | N2 | `hvigorw test` 执行段（EXIT=124）—— round 4 未再单列 |
| （无） | N6 | t18 运行态（配置下发真机生效）—— round 4 并入 N1 同因 |
| （无） | N7 | t13 运行态（真机备份往返）—— round 4 并入 N1 同因 |

> **引用约定**：两套编号一律带小节前缀（`§R4.7-N4` vs `§13-N5`），单写 `N4` 属歧义。
> 本表**不统一重写**任何编号（那会改到前几轮的原始记录）。两套的实质结论一致：**未运行 = 一条都不算通过**。

### C-收尾 · 本轮（t33）做了什么 / 没做什么

- **改了**：`README.md:16`、`app/entry/src/main/ets/model/SyncTypes.ets:8`、`app/entry/src/main/ets/viewmodel/net/HttpPort.ets:1/:12`
  （例外集「四项」→ **五类**，补「配置下发 `GET /api/v1/config`，免鉴权、与取价同组」与失败降级语义）+ 本文件（:211 函数名更正 + 本「本轮更正」小节）。
- **没改**：`docs/REVIEW.md`（评审人结论，改它等于篡改评审记录）、`docs/CHANGELOG.md:116`（v4.1 历史留痕，正确）、
  任何数值与测试基准（`tests/cases/carbon-calc.json` 零 diff，md5 与 `app/…/ohosTest/…` 副本同值）。
- **没跑**：L1 / L2 / deploy / `/admin` 浏览器 / 视觉走查（环境未变）—— §R4.7 与 §13 的「未运行 = 不算通过」对本轮同样有效。
  （**t38 补记**：上面的「没跑」指 hypium 的 36 个 `it()`；纯逻辑部分现在另有一条独立离线证据，见 §R5 —— 但那条证据**不改变**这里的结论。）

---

## §R5 round 5（t38 · L1 表述修正如实化：离线执行证据已入库，「替代证据为零」不再成立）

> 本节**不新增任何门禁结论**，只把与 L1 有关的**表述**改准。它针对的是「第二种失真」：
> **漏报已完成的工作** —— 与夸大成果等价。前四轮（round 1–4）的全部记录保持原样，只在失真的断言旁加「t38 补记/更正」指针。

### R5.1 为什么会失真

round 4（t31）写「**替代证据为零**」时是**真话**：那时能跑通这条链路的脚本只在本机 `/tmp/cbv*`、`/tmp/cbl1`、
`/tmp/cbl2` 里，仓库内 `tests/tools/` 只有 `check_l0.py`，评审把它登记为 **O4「复算证据链不可从仓库复现」**。

t37（提交 `63695f998d209ecc251a365b1f7e1094eeeba5dc` / `47eaf882e3d94105babad9ae0991e3f13324a518` /
`300a89d900c3b38722d67747a17a08518e843665`）把这条链路**固化进仓库**：`tests/tools/l1_offline/`。
于是同一句话从「当时的真话」变成「漏报」—— 必须先说清这一点，后面的边界才有意义。

### R5.2 不变的事实：hypium 侧仍是零执行，N1 结论不动

**36 个 `it()` 一条都没有执行过**：无真机（`hdc list targets` → `Connect server failed`）、无模拟器
（`test -w /dev/kvm` → `EXIT=1`）、SDK Previewer 崩于 GLIBC 2.43（`ldd --version` → `2.43`）、
`hvigorw test` 执行段 `timeout 420` → **`EXIT=124`**（`Finished :entry:default@UnitTestArkTS...` 之后零输出）。

⇒ **§R4.7-N1 与 §13-N1 的结论都不变：L1 不判通过。** 本节新增的是一条**覆盖更窄**的独立证据，
它既不把 N1 变成「通过」，也不减少 N1 的剩余风险。

### R5.3 本轮实跑的命令与原始输出（绑定 `HEAD = 300a89d`）

```
$ bash tests/tools/l1_offline/run.sh
== l1_offline：离线执行仓库真实 ArkTS 实现 ==
仓库 HEAD   : 300a89d900c3b38722d67747a17a08518e843665
仓库根      : /mnt/c/Users/Administrator/Desktop/CarbonBoo
esbuild     : /home/qinyixiang/harmony-toolchain/esbuild/bin/esbuild
node        : /home/qinyixiang/harmony-toolchain/clt/command-line-tools/tool/node/bin/node (v18.20.1)
中间产物目录: /tmp/cbl1-offline-S0Na1x

-- ① 消费仓库真实源文件（原样复制，逐字节 cmp） --
   ok(未改写)  app/entry/src/main/ets/util/DecimalUtil.ets  ->  main/ets/util/DecimalUtil.ts
   ok(未改写)  app/entry/src/main/ets/util/AppConstants.ets  ->  main/ets/util/AppConstants.ts
   ok(未改写)  app/entry/src/main/ets/util/JsonUtil.ets  ->  main/ets/util/JsonUtil.ts
   ok(未改写)  app/entry/src/main/ets/util/StringUtil.ets  ->  main/ets/util/StringUtil.ts
   ok(未改写)  app/entry/src/main/ets/model/CarbonTypes.ets  ->  main/ets/model/CarbonTypes.ts
   ok(未改写)  app/entry/src/main/ets/service/CarbonCalc.ets  ->  main/ets/service/CarbonCalc.ts
   ok(未改写)  app/entry/src/main/ets/service/CarbonService.ets  ->  main/ets/service/CarbonService.ts
   ok(仅改 import 前缀 app/entry/src/ohosTest/ets/test/CalcTestTypes.ets -> test/CalcTestTypes.ts)
   ok(仅改 import 前缀 app/entry/src/ohosTest/ets/test/CalcBaselineValidator.ets -> test/CalcBaselineValidator.ts)

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
$ echo $?
0            ← RUN_EXIT=0
```

两段结论各由谁产出（这一点决定了它是不是「跑真实实现」）：

- `RESULT: PASS=55 FAIL=0`：`runners/calc_samples.mjs` 把基准里的输入喂给**转译出来的 `CarbonCalc`**，
  逐条比对 `expectedReductionKg` / `expectedPointC` / `expectedActualA`（55 项 = 18×2 + 5×2+1 + 2 + 4 + 2）。
- `checked = 323 / passed = true`：`runners/baseline_validator.mjs` 调用的是**仓库里那份真实的
  `CalcBaselineValidator.run()`**（连同它依赖的 `CalcTestTypes` 的 `parseBenchmark` / `parseFactors`），
  即 hypium 用例原本会走的同一段断言库；`323` 是它自己算出来的断言点数量，不是本节抄来的常量。

### R5.4 消费的 9 份真实源文件（转译，不是复制粘贴改写）

| # | 文件 | 在链路里的角色 |
|---|---|---|
| 1 | `app/entry/src/main/ets/service/CarbonCalc.ets` | **被测实现**：减排量 / 应得 C / 实入 A 的唯一计算入口 |
| 2 | `app/entry/src/main/ets/util/DecimalUtil.ets` | 定点十进制（half-up 舍入的实现） |
| 3 | `app/entry/src/main/ets/util/AppConstants.ets` | `REDUCTION_DECIMALS` 等常量 |
| 4 | `app/entry/src/main/ets/model/CarbonTypes.ets` | 类型定义（纯类型，转译后被 TS 擦除，故 metafile 里只数到 8 个运行期输入） |
| 5 | `app/entry/src/main/ets/service/CarbonService.ets` | 被 `CarbonCalc` 依赖的调用链 |
| 6 | `app/entry/src/main/ets/util/JsonUtil.ets` | `CarbonService` 依赖的 JSON 工具 |
| 7 | `app/entry/src/main/ets/util/StringUtil.ets` | 同上 |
| 8 | `app/entry/src/ohosTest/ets/test/CalcBaselineValidator.ets` | **仓库真实的断言库**（hypium 用例也调它） |
| 9 | `app/entry/src/ohosTest/ets/test/CalcTestTypes.ets` | `parseBenchmark` / `parseFactors`：读真实基准与真实因子库 |

三条防「悄悄重写」的机制：① 8 个不依赖相对 import 的文件是**原样复制**后 `cmp` 逐字节比对（不一致即 `EXIT=3`）；
② 只有 `CalcTestTypes.ets` / `CalcBaselineValidator.ets` 两个文件改写 `../../../main/ets/` → `../main/ets/` 前缀，
改完用 `diff` 断言**每一行差异都只涉及该前缀**（出现无关差异即 `EXIT=3`）；③ esbuild `--metafile` 断言
bundle 的 inputs 集合 ⊆ 这 9 份源（实测 8/8 运行期输入全中）。`run.sh` 还会把 9 份文件的 `sha256` 逐条打印，
数值或逻辑一改，留档值就会变。

### R5.5 反证：它不是「永远绿」的摆设

只在 `/tmp` 的副本上把基准改错 2 处（不动仓库里的基准），再分别跑两个 runner：

```
$ # ① 先保留一个中间产物目录（否则脚本退出即删）：L1_OFFLINE_KEEP=1 bash tests/tools/l1_offline/run.sh
$ # ② 只改 /tmp 里的副本，仓库里的基准一个字节都不动：
$ python3 - "$KEEP" <<'PY'
import json, sys
b = json.load(open('tests/cases/carbon-calc.json'))        # 只读；不写回
b['samples'][0]['expectedReductionKg'] = "0.9700"          # 真值 0.9600
b['samples'][1]['expectedPointC'] += 1                     # 真值 96 → 97
json.dump(b, open(sys.argv[1] + '/mutated-bench.json', 'w'), ensure_ascii=False, indent=1)
PY
$ node tests/tools/l1_offline/runners/calc_samples.mjs "$KEEP/out/carboncalc.cjs" "$KEEP/mutated-bench.json"
samples(18×2)        PASS=34 FAIL=2
…
RESULT: PASS=53 FAIL=2
   FAIL [samples] #1.reductionKg: got 0.9600, want 0.9700
   FAIL [samples] #2.expectedPointC: got 96, want 97
$ echo $?
1            ← MUT_CALC_EXIT=1

$ node tests/tools/l1_offline/runners/baseline_validator.mjs "$KEEP/out/validator.cjs" "$KEEP/out/types.cjs" \
       "$KEEP/mutated-bench.json" app/entry/src/main/resources/rawfile/factors/carbon-factors.json
checked = 323
passed  = false
summary = 发现 3 处不一致（共复算 323 个断言点）
   MISMATCH {"scope":"sample#1","field":"reductionKg","expected":"0.9700","actual":"0.9600"}
   MISMATCH {"scope":"sample#1","field":"reductionKg(参考实现)","expected":"0.9700","actual":"0.9600"}
   MISMATCH {"scope":"sample#2","field":"expectedPointC","expected":"97","actual":"96"}
RESULT: checked=323 passed=false mismatches=3
$ echo $?
1            ← MUT_VALIDATOR_EXIT=1
```

⇒ 两个 runner 都会**真的失败、真的非零退出**，不是「打印 PASS 就算过」。这也是为什么本文件的「通过」判定
不能只看它的 `EXIT=0`：它的价值在**可复现地证伪**，而它覆盖的范围比 hypium 窄得多。

### R5.6 边界（写死；这一段是这个工具存在的全部理由）

1. **不覆盖**：UI（ArkUI 组件树 / 交互 / 页面栈）、数据库（`relationalStore` 19 张表 / 事务 / 迁移）、
   网络（HTTP 超时与降级 / `HttpPort` / 同步）、生命周期（`UIAbility` / 冷启动）、权限与端侧能力
   （相册保存、识图 stub、近场协同）。以上**只能靠 hypium 在真机/模拟器上跑**。
2. **只证明**：纯逻辑模块的**真实实现**（`CarbonCalc` + `DecimalUtil` + `AppConstants` 链）与
   `tests/cases/carbon-calc.json` 的数值唯一真相源**一致**，且仓库里那份真实的 `CalcBaselineValidator` 断言库得出
   `323 / passed = true`。**不证明** App 行为正确、不证明任何页面可渲染、不证明服务端契约。
3. **hypium 的 36 个 `it()` 仍然未运行**；本节不改变 N1，也不把「编译通过」或「离线执行」折算成任何用例通过。
4. **两条证据不可互相顶替**：报告里必须分开陈述 ——「离线纯逻辑 = 55 项 + 323 个断言点」与「hypium = 未运行」。
   任何把前者写成「L1 已通过」的表述都是造假；反过来，把后者写成「替代证据为零」则是本节要修掉的漏报。
5. **它不属于「通过」三态中的任何一态**：`§0 结论速览` 的「通过（V1–V20）」一项都不因本节而改变，
   离线证据是**第四种表述**（「未运行 + 一条覆盖更窄的可复现旁证」），证据强度排序为
   `hypium 通过 > 离线纯逻辑 55 项/323 断言点 > 编译通过 > 无`。

### R5.7 本节（round 5 / t38）逐处改动清单

| # | 位置 | 改前 | 改后 |
|---|---|---|---|
| 1 | 文件标题（`:1`） | 「最新 round 4 = t31 终验，结论见 §R4」 | 加「最新 round 5 = t38 L1 表述修正见 §R5」 |
| 2 | §R4 之前（`:3–8`） | （无） | 新增 6 行说明：本轮只修表述、不新增门禁结论、历史记录一条不动 |
| 3 | 轮次索引（`:398`） | （无 round 5 行） | 新增 round 5 一行（基准 `300a89d`、结论一句话、锚点 §R5） |
| 4 | §R4.7 未运行项 N1 单元格（`:284`） | 「**替代证据为零**：编译通过 ≠ 用例通过」 | 「**hypium 侧零执行**」+「t38 更正」标记 + 实测数字 + 命令 + 指向 §R5 + 「不改变本节结论」 |
| 5 | §R4.8 未决问题 1（`:345`） | 「L1 仍是零执行」（无限定） | 补「t38 补记：限于 hypium」+ 离线证据指针 + 「不能折算成任何 `it()` 通过」 |
| 6 | §R4.9 结果行（`:359`） | 「未运行：L1 全部 `it()`…」 | 补「t38 补记：指 hypium 侧；纯逻辑另有独立离线证据，两证不可互相顶替」 |
| 7 | §0 未运行表 N1「替代证据」列（`:455`） | 「§4 离线复算 70/70；§7 铁律静态核查；§8 未登录态静态核查」 | 追加「t38 补记」：更强的离线证据（55 项 / 323 断言点）+ 明确它不覆盖 UI/DB/网络/生命周期、`it()` 仍未运行 |
| 8 | §4.5 `verify.mjs` 注（`:665`） | 「不能替代 hypium 用例」 | 追加「t38 补记」：t37 起仓库内有正式版 `l1_offline`，并重申两者都不能替代 hypium |
| 9 | §10.3 结论句（`:1266`） | 「36 个 `it()` 全部是「已编译、未执行」…」 | 追加「t38 补记，不改本条判定」：审计对象是 `it()`，离线旁证另算、不改变「全部未运行」 |
| 10 | §13-N1「替代证据」列（`:1351`） | 「不等价…**不验证 `CarbonCalc` 的实际实现**」 | 追加「t38 补记」：该后半句已过时（`l1_offline` 确实执行真实实现），但「不等价」总判断成立 |
| 11 | §14 未决问题 1（`:1375`） | 「36 个用例只能算已编写/已登记/已编译」 | 追加「t38 补记」：限 hypium；离线证据不改变「不能算已通过」 |
| 12 | C-收尾「没跑」（`:1564`） | 「没跑：L1 / L2 / deploy / `/admin` / 视觉走查」 | 追加「t38 补记」：此处 L1 指 hypium，纯逻辑另有独立证据（见 §R5） |
| 13 | 文件末尾（`:1568` 起） | （无） | 新增本节 §R5（R5.1–R5.7） |

- **只改本文件**：`git diff --name-only` 只有 `docs/VERIFICATION.md`；`tests/cases/carbon-calc.json` 零 diff（两份副本 md5 仍同值）。
- **只改表述**：没有为让措辞好看而删掉任何「未运行/不算通过」的判定 —— 本轮改的方向是**补上漏报**，不是放宽结论。
- **不 push**：提交后由队长推送；本轮的「已推送」证据以队长的 `git ls-remote` 为准（AGENTS.md §5.1-4）。
