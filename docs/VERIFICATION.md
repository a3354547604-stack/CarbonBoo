# CarbonBoo 独立验证报告（round 3 · t24）

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
| **V9** | 铁律 1 · 未登录 = 纯单机（五类例外） | 三处例外集 grep + 141 个网络调用点全表审查 | `AGENTS.md:104/:143/:164` 三处均「五类」；全仓 `.ets` 网络调用 **141 处，五类之外 0 处**（§7.1） |
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
| **N1** | **L1 全部 hypium 用例（10 套件 / 36 个 `it()`）** | 无真机：`hdc list targets` → stderr **`Connect server failed`**（无任何设备行）；无模拟器：`/dev/kvm` 存在但 **`test -w /dev/kvm` 失败**（uid 1000 不在 kvm 组）；Previewer 崩于 GLIBC 2.43 | §4 离线复算 70/70；§7 铁律静态核查；§8 未登录态静态核查 |
| **N2** | `hvigorw test` 的**执行段** | 仓库工作树（含 `oh_modules`）实跑：`Finished :entry:default@UnitTestArkTS... after 19 s 880 ms` 之后**再无任何输出**，`timeout 420` 触发 **EXIT=124**（执行器等不到设备，静默挂住） | 仅「编译段通过」，**不构成 L1 通过** |
| **N3** | L2 端侧集成（双设备协同、飞行模式全功能） | 需两条真实设备（或真机 + 模拟器），同上无设备 | 无 |
| **N4** | 部署脚本实跑（systemd / nginx / TLS / `mysqldump` 定时） | 本机无 `systemd` 承载目标路径、nginx 未安装；unit 的 `ExecStart` 指向 `/opt/carbonboo/…`（本机不存在） | 沿用 round 2 的 `bash -n` / `systemd-analyze verify` / `migrate.sh --dry-run`（EXIT=0）+ 安全阀（EXIT=2）；**本轮环境未变，未重跑** |
| **N5** | `/admin` 浏览器端交互（Jinja2 SSR 渲染、`admin.js` 行为） | 无浏览器驱动，只到 HTTP 层 | §6.2 的 HTTP/JSON 路径已实测 |
| **N6** | t18 运行态（徽章开关 / 下发封顶在真机生效） | 同 N1 | 8 个 `it()` 存在且登记，**未运行** |
| **N7** | t13 运行态（真机备份往返） | 同 N1 | 服务端侧备份用例随 `test_sync.py` **48 passed 真实通过** |

> **N1–N7 沿用 round 2 的清单**（环境未变：同一台 WSL、无设备、`/dev/kvm` 仍不可写）。
> 本轮**额外补跑了 N1/N2 的证据**（`hdc`、`/dev/kvm`、`hvigorw test`），未重跑 N4–N7（环境未变、无新信息）。

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
| **F3** 例外集四类 → 五类 | 已修 | `AGENTS.md:104`（§2 铁律 1）/ `:143`（§5 L2）/ `:164`（§6）三处均「五类」且含「配置下发」；`grep "四类网络例外\|四类例外" --include=*.md`（排除 build/.agent-teams）唯一命中是 round 2 报告里的 grep 命令文本本身 | **闭环** |
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
$ grep -rn "四类网络例外\|四类例外" --include=*.md .   （排除 build/ 与 .agent-teams/）
唯一命中 docs/VERIFICATION.md:171 —— 是 round 2 报告里那条 grep 命令的文本本身，非口径残留
```

**网络调用点全表审查**（自写扫描，不抽样）：全仓 `.ets` 中 `hub.http.request` / `this.http.request` / `HttpPort` 调用共 **141 处**，
逐个归入五类：登录注册 / 同步 / 取价 / 备份 / 配置下发 —— **五类之外 0 处**。
未登录时这五类都返回 `NOT_LOGGED_IN` 或走「失败即整份丢弃」，本机数据不受影响。**成立。**

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
| **N1** | L1 全部 hypium（10 套件 / 36 `it()`） | 无真机（`hdc` = `Connect server failed`）、无模拟器（`/dev/kvm` 不可写）、SDK Previewer 崩于 GLIBC 2.43 | 离线复算 70/70（**不等价**：不经过 ArkTS 运行时，不验证 `CarbonCalc` 的实际实现，只验证基准自洽与我的独立算术） |
| **N2** | `hvigorw test` 执行段 | 编译段通过后 `timeout 420` **EXIT=124**，零用例输出 | 「编译通过」≠「用例通过」 |
| **N3** | L2 端侧集成 | 需两条设备 | 无 |
| **N4** | 部署脚本实跑（systemd/nginx/TLS/定时备份） | 本机无部署目标（`/opt/carbonboo/…` 不存在、nginx 未装） | round 2 的 `bash -n` / `systemd-analyze verify` / `migrate.sh --dry-run`（EXIT=0）与安全阀（EXIT=2）；**本轮未重跑（环境未变）** |
| **N5** | `/admin` 浏览器交互（SSR 渲染、`admin.js`） | 无浏览器驱动 | HTTP/JSON 层已实测（§6.2） |
| **N6** | t18 运行态（配置下发在真机生效） | 同 N1 | 用例存在且登记（未运行） |
| **N7** | t13 运行态（真机备份往返） | 同 N1 | 服务端侧备份用例真实通过（`test_sync.py` 48 passed） |

> 另：**L3 全量本轮未执行** —— 本轮口径是「`server/` 零 diff，只跑子集」。我跑了 `test_sync.py`（48）+
> `test_admin.py` 403 子集（19），是**真实结果**；其余 66+ 例未跑。全量 **237 passed** 是 **round 2 在 `971d042` 上的实测**，
> 本报告引用它时已注明来源与基准不同。

---

## §14 未决问题

1. **L1 何时能真跑**：本机无设备、无模拟器、Previewer 与 GLIBC 2.43 不兼容 —— 这三条都不是「再试一次」能解决的。在拿到真机或修复 Previewer 兼容性之前，`CalcSamples / LwwMerge / NotLoggedIn` 等 36 个用例**只能算「已编写、已登记、已编译」，不能算「已通过」**。
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
