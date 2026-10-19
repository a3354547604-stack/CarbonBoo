# tests/ · 碳小布 CarbonBoo 测试

> 规则依据：`AGENTS.md` §5（测试即完成定义）、§1.4（待修清单）。
> 原则：**能跑的断言才算验收**；人工勾选的条目（附录 D）只是入口，最终必须落到这里的某一层。

---

## 1. 分层

| 层 | 范围 | 现在能否跑 | 位置 |
|:--:|---|:--:|---|
| **L0** | 数值与文档一致性：碳计算 18 组样例、封顶 5 组、边界样例、文档已知冲突扫描 | ✅ **现在就能跑**（只依赖 Python 3） | `tests/tools/check_l0.py` + `tests/cases/` |
| **L1** | 纯逻辑单测（ArkTS / hypium）：计算、封顶、目标与徽章幂等、备份往返、CSV 编码、LWW 合并、系统配置下发 | ✅ **套件已建**（**10 个** `.test.ets` 用例文件 + `List.test.ets` 汇总入口）；执行需 SDK Previewer / 真机 / 模拟器，本机无 → **设备上尚未真正跑过**（见 §5）。离线执行器 `tests/tools/l1_offline/` 已把 **41 个 `it()` 全部离线真跑一遍**（t45 时为 36 条；t66 后 `PASS=41 / FAIL=0`，见 §5.1；跑的是仓库真实实现 + 真 SQL 垫片，**但不是 hypium 的替代品**，也**不**改变「设备上未跑过」这一事实） | `app/entry/src/ohosTest/ets/test/` + `tests/tools/l1_offline/` |
| **L2** | 端侧集成：两条真机协同脚本、飞行模式全功能、性能打点 | ⏳ **需两条真机（或真机 + 模拟器）**；当前无执行记录（不阻塞 L1/L3） | 手工脚本 + 录屏，结果记入 `docs/APPENDIX-D` |
| **L3** | 服务端（pytest）：账号、鉴权隔离、取价、同步幂等与冲突、后台管理端、配置下发 | ✅ **已建并可跑**（**6 个**用例文件 + `conftest.py` 夹具，跑在真实 MySQL 8 上：`pytest server/tests`） | `server/tests/` |

---

## 2. L0：现在就能跑

```bash
# 报告模式：列出问题，不失败
python3 tests/tools/check_l0.py

# 门禁模式：有任何待修项就退出码 1（建议接进提交前检查）
python3 tests/tools/check_l0.py --strict
```

**退出码**：`0` 通过 ｜ `1` 文档仍有待修项（仅 `--strict`）｜ `2` 数值基准自身算错（任何模式下都是错误）。

它做三件事：
1. 用 `tests/cases/carbon-calc.json` 的样例独立重算 `减排量`、`应得积分 C`、`实入积分 A`，确认**测试基准本身没算错**；
2. 扫描 `docs/` 里已知的错误数值与错误名字（电网因子 0.5777、10 个目标、`REMINDER_AGENT`、`science/index.json` 等）；
3. 打印 `docConflicts` 的人工待修清单。

> **当前预期结果是"基准 OK + 文档有命中"**——这不是测试写错了，而是 AGENTS.md §1.4 的待修项还没清零。

---

## 3. 数据基准：`tests/cases/carbon-calc.json`

**这是所有碳计算与积分数值的唯一真相源**（`AGENTS.md` §1.2）。`docs/` 与它不一致时：改文档，不改基准；确有必要改基准时，必须同时改文档并在同一次提交里完成。

包含：**31 项**因子相关条目 = 30 条因子（20 条 `recording: true` 可录入 + 10 条 `recording: false` 对照镜像）+ 换算常量 `CAR_OWN_FACTOR` 1 条；另含 2 条换算规则、18 组正向样例、5 组封顶样例、6 条边界样例、`docConflicts` 待修清单。条目口径与 `docs/APPENDIX-A-carbon-factors.md §2.5` 的「30 条 + `CAR_OWN_FACTOR` 1 条 = 31 项」镜像关系一致（B36）。

它同时是 L1 的输入：ArkTS 单测**不要重复抄数字**，应当把这份 JSON 拷进 `app/entry/src/ohosTest/resources/` 后逐条断言。

---

## 4. 完成定义（DoD）

一个切片算完成，必须同时满足：

1. `python3 tests/tools/check_l0.py --strict` 通过（该切片涉及的文档冲突已清零）；
2. 该切片对应的 L1/L3 用例全部通过，且**新增的边界用例一起入库**；
3. 提交信息里写清：跑过的命令 + 结果；
4. 不允许为了让测试变绿而改期望值、删断言、跳过用例；**改基准 = 一次需要理由的决策**，必须写进 `docs/DECISION-*.md` 或提交信息正文。

---

## 5. L1 / L3 清单（按切片；**已按仓库实测对齐**）

### L1 · ArkTS（hypium）— `app/entry/src/ohosTest/ets/test/`
| 文件 | 用例 |
|---|---|
| `CalcSamples.test.ets` | 18 组正向样例：断言 `reductionKg`（4 位小数）与应得 C；**并含 5 组封顶样例**：断言实入 A、`capped` 标记、`<0.005 kg` 不生成流水 |
| ~~`PointCap.test.ets`~~ | 封顶 5 组（无独立套件，由 `CalcSamples.test.ets` + `CalcBaselineValidator.ets` 承载），不再单独建文件 |
| `GoalIdempotent.test.ets` | 同一 `(goalId, periodKey)` 重复触发只发一次；跨周期重置；11 个目标判定 |
| `BadgeIdempotent.test.ets` | 8 枚徽章幂等、不发积分、删除记录后不撤销 |
| `ShopPurchase.test.ets` | 购买事务原子性、重复购买被拒、余额不足不可买 |
| `ShopPriceFallback.test.ets` | 取价「整份生效 / 整份丢弃」：成功 → 整份覆盖 `app_config['shop_items']`（含 version，且**不带 token**）；HTTP 失败 / 非法数据（缺 `price`、`section` 非法、缺 `version`、空目录）→ 原样保留上一份；从未取到 → 回落 `rawfile` 内置默认价；后台改价下次启动生效（`items()`/`purchase()` 取到新价并按新价扣分） |
| `BackupRoundTrip.test.ets` | 备份 → 清空 → 恢复：记录/积分/徽章/已购/科普进度五项一致；`schemaVersion` 不符则拒绝 |
| `CsvExport.test.ets` | UTF-8 BOM、`\r\n`、中文列头、无"修正系数"列 |
| `LwwMerge.test.ets` | 新者胜、平局、软删除传播、幂等（同 id 不重复）；**平局按 `deviceId` 字典序大者胜、对端时间戳先按 `offsetMs` 换算到本机基准**（附录 B §6.3/§6.4-6）—— 两处**均已在 t13 落地**（`viewmodel/net/SyncService.ets` 的 `applyRow()`），用例 ③/⑥ 已由 t11 的「告警断言」**反转为按文档口径的回归断言**（实现若回退即失败）；原 STOP 保留在该文件头「历史记录」段，本行不再声明「实现未做」 |
| `NotLoggedIn.test.ets` | 未登录态：不发起任何上传请求（可注入假 HttpClient 计数） |
| `ServerConfigFallback.test.ets` | **系统配置下发（附录 B §5.5 / D10-5，t18）**：① 成功 → 整份覆盖 `app_config['server_config']`（五项字段齐全、**免 token**、下行封顶 120 真实生效）② 未下发 → 内置 200；显式传参优先于下行镜像 ③ **任一字段非法 → 整份丢弃**（11 种坏样：空 `version`、封顶为负 / 非整数 / 字符串、`badgesEnabled` 回 `0/1` 整数、`goalRewards` 非数组 / 缺 `reward` / 负 `reward` / 空 `goalId`、缺 `serverTime`、信封 `ok=false`），上一份一字不变 ④ `goalRewards` **未知 `goalId` 整条忽略**、已知覆盖内置 `reward` 且真实生效（`goal_def` 一行不改）⑤ **同 `version` → 跳过写入** ⑥ HTTP 500 / 破损 JSON / 空 `data` / 网络抛错 → 静默降级为内置值、从不抛错 ⑦ `badgesEnabled=false` → 不发新徽章、已解锁行一字不动（打开后照常写入）⑧ `goalRewards` 缺省 / 空数组 → 回落内置种子 |

> **清单与仓库一致（2026-11-07 复核）**：上表去重后为 **10 个** `.test.ets` 用例文件；复核命令
> `ls app/entry/src/ohosTest/ets/test/*.test.ets | wc -l` 实测 **11 条** = 上表 10 个 + `List.test.ets`（套件汇总入口，
> 不是用例文件）；同目录的 `CalcBaselineValidator.ets` / `CalcTestTypes.ets` 是辅助文件，不匹配 `*.test.ets`。
> 新增用例文件必须同时在 `List.test.ets` 里 `import` 并调用，否则不会被收集。
> ⚠️ **执行状态（设备侧）**：本机无真机/模拟器（hypium 需 SDK Previewer 驱动，且该二进制与本机 glibc 不兼容），
> 故 L1 的**设备侧**证据仍为 **0**：41 个 `it()` 一条都没在设备上跑过，不得据此声称任何 L1 用例在设备上"通过"。
> **离线侧**另有可复现证据 —— `tests/tools/l1_offline/run_tests.sh` 已把这 41 条逐条真跑（见 §5.1）；
> 两条证据**不可混同**，报告里必须分开陈述「离线 = 已执行」与「设备上 hypium = 未运行」。

### 5.1 L1 · 离线执行器 — `tests/tools/l1_offline/`（**不是 hypium 的替代品**）

两条命令、验两件事（都只依赖 esbuild + node，**无 npm 依赖、不生成 `node_modules`**，转译中间产物写 `mktemp -d`
临时目录、退出即删）：

| 命令 | 它验什么 | 实测（绑定 `HEAD e83d3c1`） |
|---|---|---|
| `bash tests/tools/l1_offline/run.sh` | 把 `app/` 下 **9 份真实 `.ets`**（`CarbonCalc` / `DecimalUtil` / `AppConstants` / `CarbonTypes` / `CarbonService` / `JsonUtil` / `StringUtil` / `CalcTestTypes` / `CalcBaselineValidator`）**原样复制 + 仅改写 import 前缀** → esbuild 转 CJS → 在 Node 里跑**真实实现**，复算 `tests/cases/carbon-calc.json` 的基准（函数级 + 基准级两层） | `RESULT: PASS=55 FAIL=0`；`checked = 323` / `passed = true` / `mismatches=0`；`RUN_EXIT=0` |
| `bash tests/tools/l1_offline/run_tests.sh`（t43 新增） | 把 `app/entry/src/ohosTest/ets/test/` 下的 **10 个套件、41 个 `it()`** 在离线环境**逐条真执行**：`platform/` 垫片用 Node 内置 `node:sqlite` 提供**真 SQL** 的 `relationalStore` 语义（唯一索引 / `ON CONFLICT ... DO UPDATE` / `MAX()` / 事务），`runners/offline_run.mjs` 转译 **78 个 `.ets`** 并重放 App 启动地基（`RdbHelper.open` → `SeedRepository.seedStatic` → `FactorRepository.load`，调的都是仓库真实函数）；内联 sourcemap 让失败堆栈指回 `.ets:行` | `RESULT: it_executed=41 passed=41 failed=0 requires_device=0`；`CalcBaselineValidator：checked=323 passed=true`；`RESULT: PASS`；`TESTS_EXIT=0`（t43 首次执行时是 `passed=18 failed=18`，逐条差距与归因见 `docs/VERIFICATION.md` §R9/§R10） |

退出码：`run.sh` 0 = 全 PASS / 非 0 = 任一 FAIL；`run_tests.sh` 0 = 全过 / 1 = 有失败或基准不一致 / 2 = 环境问题。
用途、可复现性论证与完整实测输出见 `tests/tools/l1_offline/README.md`。

**边界（必须连这条一起读）**

- 它**不覆盖** UI（ArkUI 组件树 / 交互）、网络（HTTP 与超时降级）、生命周期（`UIAbility` / 页面栈 / 冷启动）、
  权限与端侧能力（相册保存、识图 stub、近场协同）—— 这些只能靠 hypium 在真机/模拟器上跑；
  （数据库一项自 `run_tests.sh` 起由 `node:sqlite` **部分**覆盖：真 SQL 语义成立，但**不是设备 RDB**）
- 它**只证明**「纯逻辑模块的**真实实现**与 `tests/cases/carbon-calc.json` 基准一致」以及「41 条用例在**真 SQL**
  垫片上跑出的行为」，**不证明 App 在设备上的行为正确**；
- **`run_tests.sh` 是离线执行（esbuild 转译 + `node:sqlite` 垫片），不等于真机 hypium**：真机侧 **10 个套件、
  41 个 `it()` 仍未在设备上执行过**（`hdc` 未安装、`/dev/kvm` 不可写、SDK Previewer 与 glibc 2.43 冲突）。
  输出里的 `requires_device=0` 是「因必须真机而被**跳过**的用例数」，**不是**「设备侧跑过的用例数」；
- 上表 L1 的执行状态**不因本工具而改变**；两条证据**不可互相顶替**，报告里必须分开陈述：
  「离线 = 41 条 `it()` + 55 项 + 323 个断言点」与「设备上 hypium = 未运行」。

### 5.2 判图腿 · 视觉模型一致性检查 — `tests/tools/vision_check/`（**不是截图腿，也不是 hypium 的替代品**）

一条命令 `bash tests/tools/vision_check/run.sh`：从 `app/entry/src/main/ets/util/AppTheme.ets`
**解析真实颜色令牌**（不手抄常数表）→ 渲染色板 PNG（每色一块 + 色名/十六进制/用途，背景用令牌
`COLOR_BG`）→ 采样像素自检（必须与令牌色值一致，否则退出 2）→ 把图交给视觉模型
（`deepseek-v4-1-flash-260910`，key 从凭据库 `.dsh/.credentials.yaml → refs.ARK_API_KEY` 读，**不落盘**）
判读 → 打印**原始响应** → 按「背景色被描述为浅色 + 至少 8/17 色块被正确说出」给 PASS/FAIL。
本轮实测 `RESULT: PASS` / `RUN_EXIT=0`（17/17 色块命中）；无网络退出 3、取不到 key 退出 4，
失败一律打印原因，**不会静默通过**。用途与完整实测见 `tests/tools/vision_check/README.md`。

**边界（必须连这条一起读）**

- 它验的是**设计令牌色板**，**不是页面截图外观**；它不碰设备、不启动模拟器、不渲染任何页面，
  所以**一页 UI 也没验**；
- **截图腿仍然不可用**：`hdc` 未安装、无真机无模拟器、`/dev/kvm` 不可写、SDK Previewer 崩于
  glibc 2.43 ⇒ **18 个页面一张截图都产生不出来**，页面级视觉走查仍不可做；
- 报告里必须把 **「视觉模型通道 = 已跑通」** 与 **「页面级视觉走查 = 仍不可做」** 分开写，
  不能合并成「视觉走查完成」；它同样不改变 hypium / L3 / 验收的任何判定。

### 5.3 验收证据工具一览（L0–L3 的**补充证据**，不替代任何一层）

L0–L3 之外还有一批**可复现的验收证据工具**：它们补的是「某一层在本机测不了」的证据缺口，**不是新的测试层**。
每行给一条**可复现命令**、**退出码含义**、**覆盖了什么**、**明确边界**。

| 工具 | 一条命令 | 退出码 | 覆盖了什么（实测） | 明确边界 |
|---|---|---|---|---|
| `tests/tools/l1_offline/`（§5.1） | `bash tests/tools/l1_offline/run.sh`<br>`bash tests/tools/l1_offline/run_tests.sh` | 前者 `0`=全 PASS / 非 0=任一 FAIL；后者 `0`=全过 / `1`=有失败或基准不一致 / `2`=环境不可达 | 9 份真实 `.ets` 复算基准：`PASS=55 FAIL=0`、`checked=323 passed=true`；**41 个 `it()` 离线逐条执行**：`RESULT: it_executed=41 passed=41 failed=0 requires_device=0` | **离线执行 ≠ 真机 hypium**：esbuild 转译 + `node:sqlite` 垫片，不是 ArkTS 运行时、不是设备 RDB；UI / 网络 / 生命周期 / 权限 / 端侧能力全不覆盖；`requires_device=0` 是「因必须真机被**跳过**」的数，**不是**「设备上跑过」的数 |
| `tests/tools/vision_check/`（§5.2） | `bash tests/tools/vision_check/run.sh` | `0`=判读通过 / `1`=判读失败 / `2`=像素自检失败 / `3`=无网络 / `4`=取不到 key | 从 `util/AppTheme.ets` 解析 17 个真实设计令牌 → 渲染色板 → 视觉模型判读（实测 17/17 命中，`RUN_EXIT=0`） | **设计令牌色板判读 ≠ 18 页视觉走查**：不渲染任何页面、不产生页面截图；**截图腿仍不可用**（`hdc` 未安装 / 无模拟器 / Previewer 崩于 glibc 2.43） |
| `tests/tools/admin_e2e/`（t55） | `bash tests/tools/admin_e2e/run.sh` | `0`=全过 / `1`=有断言失败 / `2`=环境不可达（MySQL 容器 / Edge / CDP / 服务端 任一不可用） | 真实 Edge headless + CDP 驱动 `/admin` 七项功能 + 四条鉴权边界；**97 项断言**（t59 后 **98 项**：`PASS=98 FAIL=0`）、13 张 1440×900 截图 + `artifacts/report.json` | 只覆盖 **Edge**（`Edg/155.0`）、明文 `http://127.0.0.1:8041`、单一 1440×900 视口；**≠ 跨浏览器 / 移动端 / HTTPS**；它与 App 侧证据**互不替代** |
| `tests/tools/deploy_e2e/`（t56） | `bash tests/tools/deploy_e2e/run.sh`（`L1_KEEP=1` 保留现场） | `0`=探针全过 / `1`=有探针失败 / `2`=环境不可达（无 docker / 缺镜像 / 端口被占 / deploy 文件缺失） | 容器化实跑 `server/deploy/` 四件实物：仓库 nginx 配置**字节不改**过 `nginx -t` 并真终止 TLS、限流真限住（40 连击→32×429、30 连击→20×503）、`backup-mysql.sh` 的 dump 导入**独立容器** 21/21 表一致、`migrate.sh` 两个安全阀真以 `EXIT=2/3` 拒跑；**49 探针**、三次连跑 `EXIT=0` | **容器化实跑 ≠ 云 VM 真实部署**：`systemd` 单元**从未真启动**（无 PID1 systemd）、`certbot` **未接 ACME**（用自签证书）、公网域名 / DNS / 防火墙**未验**、大库 dump 耗时未测；`/opt/carbonboo` 在本机不存在，被验的是**脚本与配置内容** |
| `tests/tools/offline_first/`（t58） | `bash tests/tools/offline_first/run.sh`（`OFFLINE_FIRST_ONLY=1/2` 只跑一段） | `0`=全过 / `1`=有断言失败 / `2`=环境不可达（node < 22.5 / 找不到 esbuild / 不在仓库根） | 「未登录 = 纯单机」**两段方向相反**的证据：断网陷阱下跑完本地主流程（录入含四字段快照 / 积分封顶与余额恒等式 / 本地购买幂等 / 科普离线读 / 本地备份往返）**零出网**；五类例外**确实出网**并打印 URL；**32 断言**；变异反证 `PASS=20 FAIL=3` | **逻辑层零出网 ≠ 真机飞行模式**：只转译 `service/ util/ data/ model/ viewmodel/` 五个目录，`pages/` 与 `components/` **一个文件都不进** ⇒ 不覆盖系统权限 / Ability 生命周期 / 端侧能力 / 界面层；断网是**陷阱**（端口层 + 平台层双记录），不是设备飞行模式开关 |
| `tests/tools/l2_sync/`（t57） | `bash tests/tools/l2_sync/run.sh` | `0`=全过 / `1`=有失败 / `2`=环境不可达 | 两个独立 `node:sqlite` 真库（各自 `deviceId`）+ 真 FastAPI + 真 HTTP：LWW 两端收敛、平局按 `deviceId`、时钟偏移取反、幂等、软删除、冲突计数，外加 **F1/F3 的修复现场**（`#0.2` / `#8.3` / `#8.4`）—— 主用例 **38 条断言**；**t71 实测 `RESULT: checks=38 passed=37 failed=1`、退出码 `1`**（红项 `#4.9`，见右栏） | **两个进程实例 ≠ 真双设备**：不是两条真机，不含 Ability 生命周期 / 后台恢复 / 端侧权限 / 近场协同；且**协议级不等于产品可用** —— 该工具 **t57 当年**报出 **F1（blocker：全新设备首同步撞 `uq_ua`）** 与 **F2（high：pull 响应无 `offsetMs`）**，**此后 F1 已由 t62 修复、F2 已由 t68 修复**（`#0.2`/`#8.3`/`#4.7`/`#4.10` 现均 PASS，即修复现场）；**当前唯一红项 `#4.9`（时钟往返不漂移）**：t71 连跑 2 次均红，三轮原始读数里严格不变量 `本机值 + offsetMs === 服务端值`（无容差）**三轮全部成立**（打印 `⇒ true`），失败的是 `noAccum9`（服务端值须 ∈ `{初始 T9 + 该轮 offsetMs}`）——第 3 轮本机值往返漂了 **+1 ms**，而同一 check 的 `jitter9` 明确用 3 s 容差允许这种漂移，故**从读数看是工具期望模型过严、不是产品换算错误**（无法排除 `r.ok`，工具未打印该字段）；**未修**，如实登记 |
| `tests/tools/repro/`（t69） | `bash tests/tools/repro/run.sh`（`REPRO_ONLY=l0,l1,l1test,pytest,hap` 只跑其中几条） | `0`=五条门禁全 PASS / `1`=有 FAIL / `2`=**全部** ENV-SKIP（环境不可达：找不到 esbuild/node、缺 MySQL 凭据、缺 `~/harmony-toolchain/env.sh`、MySQL 连不上） | 从 `git archive HEAD` 导出的**干净副本**（352 文件 = `git ls-files`）里重跑五条门禁：L0 `EXIT=0`、离线 L1 `PASS=55 FAIL=0` + `checked=323`、离线 hypium `it_executed=41 passed=41 failed=0`、服务端 `241 passed`（副本@`1b85147`；**首次需联网**建 venv + MySQL 8）、`assembleHap BUILD SUCCESSFUL in 11 s 500 ms`；脚本**不含任何内联期望值**，故用变异反证自身：改一个 `expectedReductionKg` ⇒ `PASS=3 FAIL=2` / `EXIT=1` ⇒ 副本内 `git checkout --` 还原 ⇒ `PASS=5 FAIL=0` / `EXIT=0` | (a) 干净副本**必须先 `git init`** —— `server/tests/` 有用例依赖 `.git` 元数据，否则 `test_no_secret_files_in_repo` 会**假失败**（见 `docs/VERIFICATION.md §R15.9`）；(b) 它证明的是「**仓库自包含且可复现**」，**不能**替代真机 hypium / 真机 L2 / 云 VM / 设备截图；(c) **本机副本 ≠ 第二台机器**：机器锁定路径见 [`docs/toolchain/harmony-cli-build.md`](../docs/toolchain/harmony-cli-build.md) §坑 4（`app/hvigor/hvigor-config.json5:14-15`，换机器必改） |

> **它们与 L0/L1/L2/L3 的层级关系（写死，别混读）**
>
> - 它们是**各层的补充证据**，**不替代任何一层**：L0（`check_l0.py`）、L1（真机 hypium）、L2（端侧集成）、L3（`server/tests/` pytest）的判定口径**一条都没有变**；
> - **真机 hypium（10 套件 / 41 个 `it()`）与真机 L2 仍是空缺**：`l1_offline/run_tests.sh` 的 41/41 是**离线执行**、`l2_sync` 的 35 条是**协议级**，两者都**不能**写成「L1 / L2 通过」；
> - 报告里必须分三态写：**「离线 / 协议级 = 已执行」**、**「设备上 = 未运行」**、**「未运行不算通过」**（口径与 `docs/VERIFICATION.md` §R14、§13 一致）；
> - 任一工具退出码 `2` = **环境不可达**，只能记「未运行」，**不许**折算成通过。

### L3 · pytest — `server/tests/`
| 文件 | 用例 |
|---|---|
| `test_auth.py` | 注册/登录/me/登出；用户名与密码规则；重复用户名 409 |
| `test_authz.py` | 客户端 token 访问 `/admin/*` 必须 403；两套密钥互不通用 |
| `test_shop.py` | 取价接口契约；非法数据整份丢弃 |
| `test_sync.py` | push/pull 幂等；LWW 结果与服务端一致；冲突计数正确；**另含云端备份三端点的 7 个用例**（`test_backup.py` 不存在，归属见下方 ⚠️ 说明） |
| `test_admin.py` | **Web 后台管理端（`/admin`，t6）**：模块头写明覆盖 PLAN §13.2 的 **7 项功能 + 管理侧独立 JWT 隔离**，把附录 D §1.10（D10-1…D10-8）逐条可执行化（真实 MySQL 8 + `TestClient`，**无 mock、不 skip**；用例数随 t6 续写增长，2026-11-06 复核时 50+）。按 D10 分组：① 登录/引导/改密码（D10-1：`adminToken` 与 bcrypt 落库、`admin_op_log` 审计、错口令 401 不泄漏密钥/哈希/明文、不区分"用户不存在"与"口令错"、强口令在引导路径也生效、表单登录 303 + HttpOnly/SameSite Cookie、`next` 开放重定向防护、未登录时 JSON→401 / HTML→303 分流）② 商品管理（D10-2/D10-3：价目表与客户端取价同源、改价写通到 `/api/v1/shop/items` 并记前后值、PATCH 只改传入字段、上下架、新增与重复编码 400、空改动幂等不写日志、图标上传三路径 + 大小上限 + 路径穿越与伪装图片防线、静态资源白名单）③④⑤ 用户列表/数据总览/订单（D10-4）⑥ 系统配置（D10-5）⑦ 操作日志（D10-6）；另有鉴权隔离组（客户端 token 在 `/admin/*` 全部路径与写方法上 403、管理 token 不被客户端 API 接受、两套密钥与受众不同、登录限流 429、日志详情不落密钥）、工程约束组（SSR 页面不是占位、无前端框架/无构建链、挂载幂等只加 `/admin` 路由）与 `admin_web.cli create-admin` |
| `test_config.py` | **配置下发通道（免鉴权 `GET /api/v1/config`，附录 B §5.5 / 验收 D10-5，t17）**：**无需令牌**（与 §5.4 取价同组，未登录也要能读到）；响应形状逐字对齐 §5.5（camelCase、**不泄漏 snake_case 列名**）；**`badgesEnabled` 是 JSON 布尔** —— 断言**原始响应文本**里为 `true`/`false`（`is True` 会被整数 `1` 骗过）；三项配置**真的来自库**（改库后端点读回新值 = D10-5 闭环证据）；`goalRewards` 来自既有 `goal_def`（按 `id` 升序、11 条，**未新增任何表**）；缺键回落（`config_version` → `"0.0.0"`、`points_daily_cap` → `200`、`badges_enabled` → `true`）且**回落时都不改写库**；非法封顶值（`abc` / 空串 / `12.5` / 纯空白 / `null` / 负数）一律回落而不是污染客户端；后台 `PUT /admin/config` 的写入**对客户端端点可见**；库异常 → 500 + `{ok:false,code:"SERVER_ERROR"}`（客户端据此整份丢弃）；只读端点**不写 `admin_op_log` / `sync_log`** |

> **⚠️ 云端备份用例的归属（t21 澄清，原验证 F6）**：历史上若有任务书把 L3 写成
> 「`test_auth / test_authz / test_shop / test_sync / test_backup / test_admin`」六个文件，
> 请注意 **`test_backup.py` 并不存在，也不是漏建**——云端备份三端点
> （`POST/GET /api/v1/sync/backup`、`POST /api/v1/sync/backup/restore`，附录 B §5.3）的 **7 个用例写在 `test_sync.py` 内**：
> 备份与同步共用同一组夹具与同一张库表快照，拆成两个文件会各自重建库、把 7 个用例的固件成本翻倍，
> 而它们断言的是「备份走独立三端点、**绕开** LWW 合并」（与同步用例的对照关系需要同文件并列才读得懂）。
> 故**按文件点检时请把备份用例算进 `test_sync.py`**；t21 已核查：`ls server/tests/test_*.py` = `test_admin` / `test_auth` /
> `test_authz` / `test_config` / `test_shop` / `test_sync` 计 **6 个**，无 `test_backup.py`。
>
> **清单与仓库一致（2026-11-07 复核）**：上表为 **6 个用例文件**，与 `ls server/tests/test_*.py` 实测一致
> （同一目录下的 `conftest.py` 是 **pytest 夹具**——`mysql_conn`/`clean_database`/`settings`/`db_session`/`app`/`client`
> 与 `register_user`/`auth_header`/`unique_username` 等辅助函数，**不是用例文件**，不计入上表）。
> 复核命令：`ls server/tests/*.py`（应输出 `conftest.py` + 上表 6 个 `test_*.py`）。
> 上表的锚点用**分组名 / D10 编号 / 用例名**（t6 还在续写 `test_admin.py`，行号会移动，故不写行号）。
> 新增用例文件时同步本表；`pytest server/tests` 需要真实 MySQL 8（连接参数见 `server/tests/conftest.py` 的 `.env` 发现逻辑）。

### 关于验证 round 2 的 F10 / F11 / F14（定性：均非缺陷）

> t25 收口。三条都是「清单里有个文件名 / 写法不统一」这类**表面不一致**，逐条核实后确认**都不是缺陷、都不改**。
> 记在这里是为了避免下一轮验证再次按编号点检时报出同一个误判。

- **F10（`PointCap.test.ets` 不存在）→ 非缺陷，是有意设计。**
  5 组封顶样例由 `CalcSamples.test.ets:78` / `:119` / `:151-154` 与 `CalcBaselineValidator.ets:210-218` **完整承载并已登记**（见上表删除线行）。
  为「清单里有个文件名」而拆出独立文件，会让同一份 `CarbonCalc` 封顶逻辑出现**两套夹具**；且本机 L1 跑不起来（见上表 ⚠️ 执行状态），拆了也验证不出任何差别。**不拆。**

- **F11（`test_backup.py` 不存在）→ 非缺陷，是有意设计。**
  7 个备份用例写在 `test_sync.py` 内，与同步用例**共用同一组夹具与同一张库表快照**；拆成两个文件会各自重建库、把固件成本翻倍（详见上方 ⚠️ 云端备份归属段）。**不拆。**

- **F14（基准里 `"16"` 与 `"16.0"` 写法不一致）→ 非缺陷。**
  已核实：`tests/cases/carbon-calc.json:422` 的 `"amount": "16"`（`samples` 第 8 组「少开一天车」，乘 `CAR_OWN_FACTOR`）与 `:336` 的 `"amount": "16.0"`（换算样例）是**不同用例的不同输入**，不是同一个量的两种写法。`amount` 字段在设计上就是**字符串**（服务端/客户端都按十进制字符串解析，不是 JSON number），两种写法并存合法。
  真正的约束在**复算侧**：**任何复算必须做 Decimal 比较，不得用字符串相等或裸 float 比较**——`round(0.005 × 100) == 0` 与 half-up 的 `1` 有可观测差异，用 float 会得出与基准相反的结论。
  为此去把基准改成统一形式，等于**为了让测试好写而改真相源**，正是 AGENTS §5 明令禁止的事。**不改基准。**

---

## 6. 目录

```
tests/
├─ README.md              # 本文件
├─ cases/
│  └─ carbon-calc.json    # 数值唯一真相源（L0 与 L1 共用）
└─ tools/
   ├─ check_l0.py         # L0 检查器（现在即可运行）
   ├─ admin_e2e/          # /admin 浏览器级 E2E（Edge headless + CDP；见 §5.3）
   ├─ deploy_e2e/         # server/deploy/ 容器化实跑（nginx/TLS/限流/备份还原/migrate；见 §5.3）
   ├─ l2_sync/            # L2 协议级双端收敛（两个真库 + 真服务端；见 §5.3）
   ├─ offline_first/      # 「未登录=纯单机」两段证据（断网陷阱 + 五类例外；见 §5.3）
   ├─ l1_offline/         # L1 离线执行器（见 §5.1；跑仓库真实实现，不是 hypium 的替代品）
      ├─ run.sh           # 一条命令：复制 → 校验 → 只改 import 前缀 → esbuild → Node 执行（55 项 + 323 个断言点）
      ├─ run_tests.sh     # 一条命令：转译 78 个 .ets → node:sqlite 垫片重放启动地基 → 逐条跑 41 个 it()（+ sourcemap 指回 .ets:行）
      ├─ platform/        # @ohos/* 垫片：arkdata.cjs（relationalStore → node:sqlite）、hypium.cjs、unavailable.cjs（未覆盖模块显式抛错）等
      ├─ runners/         # calc_samples.mjs（55 项）、baseline_validator.mjs（323 个断言点）、offline_run.mjs（41 个 it() 的收集与执行）
      └─ README.md        # 用途、边界、capSamples 口径、逐条失败归因与单跑复现命令
   └─ vision_check/       # 判图腿：设计令牌色板 → 视觉模型判读（见 §5.2；不产生页面截图）
      ├─ run.sh           # 一条命令：挑带 Pillow 的解释器 → 解析 AppTheme → 画色板 → 判读 → PASS/FAIL
      ├─ vision_check.py  # 解析令牌 / 渲染色板 / 像素自检 / 调视觉模型 / 判定
      └─ README.md        # 用途、退出码、边界（不是截图腿，不能替代 18 页视觉走查）
```
