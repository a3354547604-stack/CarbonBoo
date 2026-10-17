# 变更记录 · 碳小布 CarbonBoo

> **全仓库唯一的变更记录来源。** 附录 A / B / C / D / F 末尾的「变更摘要」小节全部指向本文件；
> `AGENTS.md §10` 只记「规约本身」的变更。任何影响契约（数值 / 字段 / 接口 / 页面元素 / 验收）的改动，
> 都必须在同一次提交里在这里留一行，并同步 `tests/cases/carbon-calc.json → docConflicts`。

| 版本 | 日期 | 主题 |
|---|---|---|
| **v4.2** | 2026-11-06 | **文档契约勘误（对齐已实现并验证的口径）**：`uq_pr_source` 补 `user_id`、同步契约七处收紧（备份三端点 / `clientNow` / `ignored` 与 `conflicts` 分离 / 鉴权）、附录 C 落盘路径与附录 D §9 演示数据口径；**后续（2026-11-07 追加）**：`offsetMs` 同名双视角消歧 + `lastSyncAt` 基准单一化、冻结免鉴权 `GET /api/v1/config` 配置下发通道（B46 / B47，见 §6）；**收尾回写（2026-11-07，见 §7）**：测试清单计数对齐仓库实测（L1 **10** 个用例文件 + `List.test.ets`、L3 **6** 个）、`LwwMerge` 行的失效 STOP 反转、`admin_web/README` 的 STOP-1 改记「已闭环」、附录 B §5.5 版本 bump 条件消歧；**再追加（2026-11-07，见 §8）**：`AGENTS.md §5.1-4` 增「已推送」证据条款（唯一合格证据 = `git ls-remote` 原始输出），该条以本节代 `docs/DECISION-*.md` 留痕 |
| **v4.1** | 2026-11-06 | **文档契约冻结**：统一账号与同步口径、补齐可执行契约、验收与界面双向承载、因子基准收敛 |
| v4.0 | 2026-10-15 | 规划定稿：9 项官方要求全做、出行类净减排口径、因子 30 个、19 张表、11 个目标、8 枚徽章 |

---

## v4.2（2026-11-06）· 文档契约勘误

**触发**：三部分实现（`app/` t2+t4、`server/` t3+t5、`/admin` t6）落地后，发现文档契约与「已实现并已验证的正确口径」分叉（`server/README.md §9.1` 的行号清单 + 队长实测）。**本版不改任何实现代码**，只把分叉收敛到文档侧。
**门禁**：`python3 tests/tools/check_l0.py --strict` → `L0-1 错误 0 / L0-2 命中 0 / L0-3 open 0 / 结论 PASS`，退出码 0。

### 1. 附录 B 八处契约修正（B40 / B41）

- **`uq_pr_source` 补 `user_id`**（§2）：`uq_pr_source(source_type, source_id, flow_kind)` → **`uq_pr_source(user_id, source_type, source_id, flow_kind)`**；幂等约束注释写清"`source_id` 取值口径不含账号维度 → 缺 `user_id` 时两个账号同日达成同名目标互相顶掉、后入账者丢积分"，并写明同步判重一律按 `(user_id, 业务键)` 组合。同口径同步到 PLAN §9.5 第 2/3 条与两处变更索引。服务端 `sql/schema.sql`（+ `migrations/001_uq_pr_source_user_id.sql`）与客户端 `ClientSchema.ets` 早已按含 `user_id` 实现。
- **§6.3 伪码自洽**：`appendOnly` 分支新增 `businessKeyOf` / `keys` 集合，**同 `id` 或同业务唯一键已存在都算重复**（`ignored++`，不计 `conflicts`），不再把"业务唯一键兜底"只写在散文注释里；写回 `INSERT OR IGNORE` 明确为**第二道**兜底。
- **§5.3 云端备份三端点补行**：`POST /api/v1/sync/backup`（上传快照）、`GET /api/v1/sync/backup`（下载快照）、`POST /api/v1/sync/backup/restore`（覆盖式恢复，返回覆盖前原状 `preRestore`）；写明"只存快照、不做 LWW、不算冲突、不用 `lastSyncAt`"，并**明确否决**"备份复用 `push`/`pull` 的 `since=0`"（那条路径走 LWW 合并，做不到"覆盖"）。D5-12 的判据同步指向这三端点。
- **§5.3 push 请求体补 `clientNow`**（毫秒，可选）：§6.4-6 要求测得 `offsetMs = 本机时钟 − 对端时钟`，服务端侧即 `服务端时钟 − 客户端时钟`；缺失时 `offsetMs = 0`（未校正，不猜值）。响应示例补 `ignored` / `rejected` / `offsetMs` / `clockWarning`，并写明 `skipped = ignored + rejected`。
- **§6.4-3 分离两个计数器**：`ignored`（跨设备重复已去重）**不计入** `conflicts`；`conflicts` 只按 §6.3 的「真冲突」条件计数。
- **§6.5 `user_purchase`**：补"服务端忽略远端购买行时**不产生任何流水**"（无 `reverse`，也没有 `adjust` 这个 `source_type`）。
- **§6.5 `user_profile`**：补"合并时按 `user_id` 收敛到一行，`id` 取胜者的"（同 `id` 两行仍按 `updated_at` 取新）。
- **§5.2 / §5.3 鉴权**：§5.2 增「鉴权」列；§5.3 表头写明**本组全部端点**（`pull`/`push`/`status` + 备份三端点）均需 `Authorization: Bearer <userToken>`，身份取自令牌、请求体 `userId` 只用于对账（不一致整批 403），账号已注销者 401。

### 2. 附录 C 落盘路径与 AGENTS 口径勘误（B42 / B43）

- **附录 C §3 设计令牌落盘路径**：`app/entry/src/main/ets/common/AppTheme.ets` → **`app/entry/src/main/ets/util/AppTheme.ets`**（仓库里**没有** `common/` 目录；`find app/entry/src/main/ets -name 'AppTheme.ets'` 实测只有 `util/` 这一处）；§25 界面自检第 2 条的例外由「`LiteralConstants.ets` 文件」改为「`util/AppTheme.ets` 里的 `LiteralConstants` 类」——同文件里 `export class AppTheme` + `export class LiteralConstants`。
- **AGENTS.md §6**：「未登录 = 纯单机」的例外集由三项补齐为**四类**（登录/注册、多设备同步、商品取价、云端备份），与 §2 铁律 1、§5 L2 飞行模式验收、附录 D §1.6 同一口径。
- **AGENTS.md 头部状态行**：删掉「只做计划与开发文档，暂不编码」「`app/`、`server/` 尚未创建」——改为实际进度「S1–S6 已实现并落库（`app/` 19 张表 + 18 个页面；`server/` 21 张表 + 账号/同步/取价/备份 + L3 pytest），S7 与 `/admin` 收尾中」，规划版本号 v4.1 → **v4.2**。

### 3. 附录 D §9 演示数据口径收敛（B44）

- **§9 表格**：「典型值（v4.0 因子）」→「**单条量级**（按「日均新增减排 ≈0.7 kg」缩放后的每条约值）」，四类改为 出行 ≈0.30 / 节水节电 ≈0.13 / 旧物回收 ≈0.30 / 光盘 0.35 kg（数值取自 `DemoService` 的 `dayPlan/travelItem/elecItem/…`，逐条一致）。
- **新增 §9.1 汇总口径（唯一求和来源）**：条数 72+108+45+36 = **261**（统一表述「约 260 条」）；日均 **0.701 kg/天**；累计减排 **61.7400 kgCO₂e**（= 21.6000 + 14.0400 + 13.5000 + 12.6000，落 60–90 区间且 **< 100 kg**）；记录类毛收益 **≈6,174 分**（日均 68.6 < 200 ⇒ 封顶不生效）；余额由收尾兑换收敛到 **4,820–4,919**（`TARGET_BALANCE = 4820`，仍在 4,000–6,000 内）；自动解锁 **6 枚**。
- **四条约束为何相容**：写进 §9.1 的说明行——"余额 ≠ 减排量 × 100"，余额由收尾那笔碳普惠兑换收敛，故「60–90 kg」与「4,000–6,000 分」不矛盾。
- **§10.3 `summary.csv` 示例**改为与 §9.1 逐字同源：总减排 `61.7400`、出行 `21.6000`、水电燃气 `14.0400`、旧物回收 `13.5000`、光盘 `12.6000`、记录数 `260`、累计积分 `4,820`、徽章 `6`（原来那组 `76.3800 / 32.4000 / 28.6000 / 14.9800 / 0.4000` 与 §9 表不同源，光盘按 0.4 kg 只相当于 1 餐）。
- **附录 C §3.4** 补一行：「`12.4800` / `4,820` / `48` 是**格式示例**，示意图数字不代表演示数据规格；规格唯一来源是附录 D §9/§9.1」。
- 数值仍是**文档级规格值**：`tests/cases/carbon-calc.json` 的 `constants/factors/samples` 没有演示数据字段，本次只登记 B44 条目、不改基准数值。

### 4. 登记与决策留档（B45）

- `AGENTS.md §1.4` 新增 B40–B45 六条（`status` 全 `closed`）、`§9` 的区间由 B1–B39 更新为 **B1–B45**、`§10` 本表新增 v4.2 一行（`AGENTS.md §10` 要求「修改本文件必须更新本表」）。
- `AGENTS.md` 头部状态行 + `docs/README.md`「当前阶段」改为写实进度（B45）。
- 新建 [`DECISION-0002-doc-contract-errata.md`](./DECISION-0002-doc-contract-errata.md)，记录 D1–D5 五条取舍（`AGENTS.md §10` ① 要求的决策留档），并在 `docs/README.md` 文档清单补第 10 行导航。
- 门禁：`python3 tests/tools/check_l0.py --strict` → `L0-1 错误 0 / L0-2 命中 0 / L0-3 open 0 / 结论 PASS`，退出码 0；`docConflicts` 共 45 条、`open` 0 条。

### 5. `offsetMs` 同名双视角消歧（文档明文，防符号写反）

- **问题**：`offsetMs` 这一个名字在文档里被两端各自复用（「本机 − 对端」），却没有写出客户端那一次**取反**。客户端从 §5.3 响应拿到的是**服务端视角**（服务端 − 客户端），而 §6.3 的合并伪码要的是**客户端视角**（客户端 − 服务端）。照伪码字面把响应值直接相加，在服务端快 60 秒时会把对端时间戳算**新** 60 秒 → 对端更旧的行反而覆盖本机，得到与 §6.4-6 **相反**的收敛结论（双机演示才暴露，极难定位）。
- **§5.3「响应字段口径」**：补明文——响应里的 `offsetMs` 是服务端视角，客户端必须 `const clientOffsetMs = -respOffsetMs;`（等价写法 `const rUpdated = r.updatedAt - respOffsetMs;`），并给出**自证判据**（`respOffsetMs = +60000` ⇒ 服务端 `updatedAt = T` 的行换算到客户端必须是 **`T − 60000`**，即显得更旧）；同时写明服务端侧不需要取反（它与自己的基准同向，直接相加）。
- **§6.3 伪码**：参数由 `offsetMs` **更名 `clientOffsetMs`**，并在头部注释写明「它**不是** §5.3 响应里的 `offsetMs`（互为相反数），客户端必须取反」，用于换算的那一行同时给出等价写法。
- **§6.4-6**：保留「两端互为相反数」语义不变，把客户端那一次取反写成明文（`clientOffsetMs = −respOffsetMs`），并注明「漏掉取反会得到与本条相反的结论」。
- 口径与实现一致：`server/app/services/sync_service.py` 的 `outcome.offset_ms = started_at - client_now` 是**服务端视角**（与响应字段同向）；客户端 t13 已按 `-respOffset` 取反实现（`app/entry/src/main/ets/viewmodel/net/SyncService.ets`）。本次**只改文档**、未动任何实现与测试。

### 6. `lastSyncAt` 基准单一化与配置下发通道（B46 / B47，2026-11-07 追加）

> 本节与 §5 同属 v4.2 勘误批次，**分开记**是因为改动依据不同：§5 来自 t15 的符号消歧（`offsetMs` 一个名字两端复用的取反），本节来自 t6（`/admin`）交付时报出的 STOP 与 t16 的基准收敛。**本节只冻结文档契约，不改任何实现代码**；实现跟进任务：**t17 服务端 / t18 客户端**。

- **`lastSyncAt` 由「同名不同基准」收敛为单一服务端基准（B46 ②）**：原文档里它既被定义为「上次成功同步的时刻（**服务端时钟基准**，落 `device_info.last_sync_at`）」，又在 §6.3 的冲突条件 `l.updatedAt > lastSyncAt && r.updatedAt > lastSyncAt` 里与**本机**行的 `updatedAt` 直接比较 —— 同名不同基准，双机演示才暴露。现冻结：`lastSyncAt` **一律是服务端基准**（= 响应里的 `serverTime`，同一个值同时用于 push 请求体与 `pull?since=`）；冲突判定只把**锚点**换算到本机一侧，派生 `lastSyncAtLocal ≝ lastSyncAt + clientOffsetMs = lastSyncAt − respOffsetMs`（等价写法 `l.updatedAt + respOffsetMs > lastSyncAt`），§6.3 真冲突与平局分支统一写作 `l.updatedAt > lastSyncAtLocal && r.updatedAt > lastSyncAt`；服务端侧对端行取值时先换算 `int(values["updated_at"]) + offset_ms > last_sync_at`。**否决「客户端单锚点」的理由**写进 §6.4-6：`GET /sync/pull?since=` 没有 `clientNow`，服务端在 pull 路径上拿不到 `offset_ms`，增量边界会随时钟偏移漂移。自证判据：`respOffsetMs = 0` 时两式退化为同一个数；§6.4-6 另给「凡跨端时间戳必须能说清在哪个基准上」的字段归属表。
- **新增 `GET /api/v1/config` 配置下发通道（B47）**：t6 报出 STOP —— 验收 **D10-5** 的判据含「改目标奖励分值 / 每日封顶值 / 徽章开关 → **App 侧能读到**」，但附录 B §5.4 与 `PLAN §13.3` 只定义了商品目录下发（`GET /api/v1/shop/items`），**没有任何 `app_config` / `goal_def` 的读通道** → 后台的系统配置是「只写不读」的死功能，D10-5 没有可执行路径。现冻结：附录 B §5.4 端点表新增 `GET /api/v1/config`，**鉴权「无」**（与 `GET /api/v1/shop/items` 同组 —— 未登录也要能读到公共配置，后端不可用时照常用本地值，D10-8 / 铁律 1）；并新开 **§5.5** 写死响应体 `{ ok, data: { version, pointsDailyCap, badgesEnabled, goalRewards[], serverTime } }`、服务端生成规则表（`version` ← `app_config['config_version']`，**独立键名**不与 `shop_items_version` 互相顶替、缺省 `"0.0.0"`；`pointsDailyCap` ← `points_daily_cap` 缺省 `200`；`badgesEnabled` ← `badges_enabled` 的 `1`/`0` **必须序列化为 JSON 布尔**、缺省 `true`；`goalRewards` ← `goal_def` 按 `id` 升序、表空可省略）与客户端落地口径（整份校验、**任一字段非法即整份丢弃**、`goalId` 必须能在 `rawfile/goals/goal-defs.json` 找到否则**整条忽略**、整份落 `app_config['server_config']`、**冷启动**生效、`version` 与上一份相同由客户端自行决定、只读不写 `admin_op_log`/`sync_log`）。
- **铁律 1 边界写明**：服务端只提供**下行默认值**（搬运），本机 `app_config` 仍是唯一真相源；§1.1/§1.2 的表清单与「`app_config` 不参与同步」**未动**。
- **D10-5 补可执行口径**：App 冷启动后本机 `app_config['server_config']` 内 `pointsDailyCap` / `badgesEnabled` / `goalRewards` 三项**与后台一致**即为通过，并指向 §5.5 新端点。
- **登记与留档**：`AGENTS.md §1.4` 新增 **B46 / B47**（`status` 全 `closed`）、`§9` 区间更新为 **B1–B47**、`§10` 补一行（`AGENTS.md §10` 要求「修改本文件必须更新本表」）；`tests/cases/carbon-calc.json → docConflicts` 追加两条（**共 47 条、`open` 0 条**）；决策留档见 [`DECISION-0003-runtime-config-and-sync-anchor.md`](./DECISION-0003-runtime-config-and-sync-anchor.md)（`AGENTS.md §10` ① 要求），并在 `docs/README.md` 文档清单补第 11 行导航。
- **门禁**：`python3 tests/tools/check_l0.py --strict` → `L0-1 错误 0 / L0-2 命中 0 / L0-3 open 0 / 结论 PASS`，退出码 0。

### 7. 收尾回写：清单计数与闭环状态（t20，2026-11-07）

> 本节与 §5/§6 同属 v4.2 勘误批次，处理的是那两批改动**改完之后没回头同步**的残留 —— L0 检查器只查数值与已知条目，查不出「清单条数写成旧值」「闭环了却仍登记为 STOP」这类空白。**只改文档，不动任何实现与测试。**

- **`tests/README.md` L1 清单与仓库实测对齐**：计数由「9 个」改为 **10 个** `.test.ets` 用例文件（复核命令 `ls app/entry/src/ohosTest/ets/test/*.test.ets | wc -l` 实测 **11 条** = 10 个用例文件 + `List.test.ets` 汇总入口）；补 `ServerConfigFallback.test.ets` 一行 —— t18 落地的配置下发用例（8 个 `it`：整份生效 / 任一字段非法整份丢弃 / 未知 `goalId` 整条忽略 / 同 `version` 跳过写入 / 5xx 与网络异常静默降级 / `badgesEnabled` 开关）。
- **`LwwMerge.test.ets` 行的失效 STOP 反转**：该行原写「平局按 `deviceId` 裁决与时钟偏移校正在实现里都未做」，而 **t13 已按附录 B §6.3/§6.4-6 补齐实现**、用例 ③/⑥ 也已（如该文件头所述）反转为**按文档口径的回归断言** —— 原表述与仓库现状相反，现改为「两处均已在 t13 落地（`viewmodel/net/SyncService.ets` 的 `applyRow()`），原 STOP 保留在文件头『历史记录』段」。
- **`tests/README.md` L3 清单同步补行**：t17 新增的 `test_config.py`（免鉴权 `GET /api/v1/config` 的接口契约）未登记 —— 计数由「5 个」改为 **6 个**用例文件（`ls server/tests/test_*.py` = `test_auth` / `test_authz` / `test_shop` / `test_sync` / `test_admin` / `test_config`）。
- **`server/admin_web/README.md §7` 的 STOP-1 改记「已闭环」**：B47 的缺口已由 t17（服务端免鉴权端点，`0f320c2`）+ t18（客户端消费，`18db1db`）+ t19（后台**有改动才** bump `config_version`，`87a055d`）在实现侧闭合，文档侧指向附录 B §5.5 与验收 D10-5（`APPENDIX-D:209`）。**当初报 STOP 的原文逐字保留在下方**（历史不抹）；同节「待 server-api 补的两处」（`requirements.txt` 补 `jinja2`、`.env.example` 补三个 `ADMIN_` 键）实现侧也已补齐，一并回写为 ✅。
- **附录 B §5.5 版本条款消歧**：原句「`PUT /admin/config` 成功保存后**必须**同步更新 `app_config['config_version']`」在「无改动（幂等保存）」情形下与实现（t19 的 `if changed:`）相反。现写死三种情形：**有实际改动 → 必须 bump + 照常写一条 `update_config` 审计；无改动 → 幂等成功、不 bump、不写第二条审计；保存失败 → 整体回滚**。裁决依据是该条款自身的立法意图（防「内容变了却感知不到」）—— 无改动时内容没变，照字面 bump 反而留下「版本 +1 但配置没动」的虚假变更记录，污染 `app_config` 与 `update_config` 审计。
- **登记**：以上均**不新开 B 编号**（不是新缺陷，是 B46/B47 那批改动的收尾残留）—— `tests/cases/carbon-calc.json → docConflicts` 的 **B47 `correct` 字段**追加一段回写说明；本条 CHANGELOG 行即 `AGENTS.md §9` 要求的留痕。
- **门禁**：`python3 tests/tools/check_l0.py --strict` → EXIT=0。

### 8. AGENTS §5.1-4「已推送」证据条款 —— 以本文件代 DECISION 留痕（t25，2026-11-07）

> **为什么记在这里而不是 `docs/DECISION-*.md`**：`AGENTS.md §10` 末句规定「修改本文件必须 ① 在 `docs/DECISION-*.md` 里留下决策记录 ② 更新本表」。本次新增的 §5.1-4 是**可执行约定的补充**（怎么写「已推送」的证据），**不涉及数值 / 契约 / 架构取舍**，不构成需要长期追溯的决策分支。**队长裁决：不新建 DECISION 文件，以本行代决策留痕**，避免决策目录被流程性约定稀释。

- **触发**：t23 第一轮报告用 `git fetch -q && git rev-list --left-right --count origin/main...HEAD` → `0	0` 证明「已推送」。这条命令读的是**本地 `origin/main` 引用缓存**——若 `push` 从未发生或失败，缓存本就停在该 commit，**同样显示 `0 0`**。**即：它在推送失败时也报「已推送」，是会直接造成假绿交付的证据。** t23 补跑 `git ls-remote origin main` 得到 `308d09f8c1e6b0178f1480ad8c6938c6b0c1dc3a	refs/heads/main` 后才真正闭环。
- **条款内容**（`AGENTS.md §5.1` 第 4 条）：唯一合格证据 = `git ls-remote origin <branch>` 的**原始输出**（走网络问远端、只读、不碰本地缓存），且与本地 `git rev-parse HEAD` 一致；`git rev-list --left-right --count` 的 `0 0` 与 `git log origin/main` 读本地缓存，**明确列为不可单独作为证据**；`git push` 的 `a1b2c3..d4e5f6  main -> main` 只作**辅助**（证明发起过、远端接受了更新），报告仍须附 `ls-remote` 原文。
- **特别写明**：`fetch` 之后再跑 `rev-list` **也不行**——`fetch` 只是刷新缓存，刷新完 `0 0` 依旧是 `0 0`。这是本条的实操要点，漏了它会以为「先 fetch 一下就严谨了」。
- **只在跨环境时尤其危险**：推送凭据在本机 **Windows Git 凭据管理器**里、WSL 内没有（`AGENTS §7.3`），推送常态是经由 Windows git，更容易「看起来成功、其实没推」。
- **范围**：只改 `AGENTS.md §5.1`（新增第 4 条）与 §10（补一行）；§1.4 的 B 编号区间、§2 的五类例外**一字未动**（那是 t21 刚定的口径）。**不新开 B 编号**——不是新缺陷，是证据判据的补充。
- **门禁**：`python3 tests/tools/check_l0.py --strict` → EXIT=0。

### 9. 补记 `7e3e969` 与例外集五类收尾（t28，2026-11-07）

> 本节处理两类**漏记**：一条已合入 main 但从未在本文件留痕的测试改动，以及 t21 把例外集从四类补为五类后、`PLAN` / `ADR-0001` / 基准正文未跟进的残留。**只改文档，不改任何实现与测试代码，不改基准数值。**

- **补记 `7e3e969`（`test(server)`，2026-10-16）**：该提交移除会给 t5/t6 埋雷的跨切片断言与恒真断言 —— ① 删掉 `server/tests/test_authz.py` 里断言 `app/api/v1/{sync,shop,backup}.py` 与 `admin_web/mount.py`「不存在」的用例（t5/t6 正要创建这些文件，该断言会让下游切片的 verify 必红），改为只自检本切片唯一身份实现 `auth_provider.py` 存在；② 删掉 `assert ... or True` 恒真断言，改为断言调用次数 `len(calls) == 6`（六个接口全部经抽象转发）。**理由**：跨切片断言会让 t5/t6 的 verify 必红。提交时自检 `cd server && .venv/bin/python -m pytest tests/ -q` → 69 passed，并做了反脆弱自检（临时创建 t5/t6 目标文件后重跑仍 69 passed，随后删除模拟文件）。此前该提交只在 `git log` 里可查、本文件无痕，属漏记（评审 R6）。
- **例外集口径统一为五类（收尾 R1）**：`AGENTS.md` 于 t21 已把 §2 铁律 1 / §5 L2 / §6 三处统一为**五类**（第五类 = 配置下发 `GET /api/v1/config`，免鉴权、与取价同组），但 `docs/PLAN.md` 七处与 `docs/adr/0001-account-and-sync.md` 一处仍是「四类」。本轮逐处改为五类并补「失败降级」半句（取价失败 → 内置默认价，配置下发失败 → 内置种子）：`PLAN.md:95` / `:118` / `:143` / `:620` / `:935` / `:1046`（**A2 验收标准原文**）/ `:1071`、`ADR-0001:17`。`PLAN.md:375`（F2-2 柱状图「四类并列」）与附录 D/E 的相关表述属**减排分类**语境、非例外集语境，未动。**口径唯一来源仍是 `AGENTS.md §2` 铁律 1**，本行只做收尾登记，不新开 B 编号。
- **落盘路径勘误（收尾 R4 + B43 同型漏网）**：`APPENDIX-C:158` 的 `app/entry/src/main/ets/view/components/` → `app/entry/src/main/ets/components/`（仓库无 `view/` 目录）；`PLAN.md:143` 的 `common/HttpClient.ets` → `app/entry/src/main/ets/viewmodel/net/HttpPort.ets`（`HttpClient` 是该文件内的类名，`HttpPort.ets:62`；仓库无 `common/` 目录）。
- **`tests/README.md` 因子口径与套件表勘误（R5/R8）**：「21 个因子」→ **31 项**（30 条因子 = 20 条 `recording:true` + 10 条 `recording:false` 对照镜像，+ `CAR_OWN_FACTOR` 1 条），与附录 A §2.5 的镜像关系一致；`PointCap` 行改为「封顶 5 组（无独立套件，由 `CalcSamples.test.ets` + `CalcBaselineValidator.ets` 承载）」。**未改任何基准数值**。
- **`docs/VERIFICATION.md` 判据勘误（R2/R3）**：V9 的判据由窄模式 `grep "四类网络例外\|四类例外"` 改为**语义覆盖**宽口径 `grep -rn "四类"` 并逐条判语境；新增未运行项 **N8 视觉走查**（本机无 hdc / 无真机 / 无模拟器、Previewer 崩于 glibc 2.43 ⇒ 18 个页面一张截图都产生不出来；`ARK_API_KEY` 在本会话不存在 ⇒ 视觉模型亦不可用）。用户 m00004 的「前端子代理须有视觉模型」一条**未满足，须在最终交付说明中显式告知**。
- **门禁**：`python3 tests/tools/check_l0.py --strict` → EXIT=0。

---

## v4.1（2026-11-06）· 文档契约冻结

**触发**：两轮独立交叉审计（31 条 + 8 条不一致）+ 负责人对 ADR-0001 四项未决项的拍板。
**门禁**：`python3 tests/tools/check_l0.py --strict` → `L0-1 错误 0 / L0-2 命中 0 / L0-3 open 0 / 结论 PASS`，退出码 0。

### 1. 账号与同步口径统一（ADR-0001）

- 服务端由「可选演示件」改为**必做件**（账号 + 云端同步 + 取价 + 云端备份）；**唯一可选项是 Web 后台管理端**。
- **未登录 = 纯单机**；可依赖网络的例外**仅四项**：登录/注册、多设备同步、商品取价、云端备份。
- 鸿蒙分布式协同**降级为近场演示层**（同 Wi-Fi 双机演示，不承担跨设备一致性，可整体关闭，见附录 B §6.6）。
- 名词统一到 `GLOSSARY.md`：**本机档案 / 游客态 / 账号态**、**分布式协同 / 云端同步 / 云端备份 / 家庭合并统计**。
- 家庭碳积分合并统计 = **同一账号下多台设备按 `device_id` 的只读合并**；不建家庭账号体系，不合并账本。
- 隐私文案：任何页面不得声称「绝不上传数据」，一律表述为「默认本地；仅在你登录后上传行为数据，可随时退出登录或注销」。
- ADR-0001 的「未决」①②③ 已写进 ADR 的 Decisions 表：① 首次登录本机历史数据**全部改挂账号并上传**；② 近场协同保留为演示层；③ 注销 = 云端**软删除保留 30 天**（期间可恢复）、**本机数据一条不删**。剩余唯一未决项 ④ 云服务器规格/地区/域名（地址经配置注入，禁止硬编码，不阻塞编码）。

### 2. 补齐可执行契约（附录 B）

- `point_record` 新增 `flow_kind TEXT NOT NULL -- primary | reverse`；唯一索引由 `uq_pr_source(source_type, source_id, type)` 改为 **`uq_pr_source(source_type, source_id, flow_kind)`** —— 同 revision 的 `record` / `record_capped` 都是 `primary`，不可能并存；`reverse` 可与 `primary` 并存（冲正必进当日已得 D）。
- `source_id` 取值口径写死：`carbon_record → '<id>#<revision>'`、`goal → '<goalId>:<periodKey>'`、`shop_item → '<shop_item.id>'`、`carbon_include → '<carbon_include.id>'`、`reverse → '<原 source_id>#r<n>'`。
- 删除无产生方的 `adjust` 枚举值（`source_type` / `PointSourceType` / 文档三处）。
- `appendOnly` 分支只按 `id` 提前跳过，**业务唯一键的重复由写回的 `INSERT OR IGNORE` 兜底**；两者合起来才是 §6.4 的「`id` 与业务键双重幂等」。
- LWW 平局分支改为：`rUpdated === l.updatedAt` 时按 **`deviceId` 字典序大者胜**，且冲突计数与「真冲突」**同一条件**（两端 `updatedAt` 均 > `lastSyncAt`）。
- `server_user` **不存 `device_id`**（设备粒度只出现在各业务行的 `device_id` 列与同步请求体）；注册/登录请求体删除 `deviceId`；后台 `/admin/users` 的「设备列表」= 该用户已同步行按 `device_id` 去重 + 各自最后同步时间。
- 首次安装写 `user_profile`：`id` = 新生成 UUID v4，`user_id = 'local-guest'`，**每个 `user_id` 恒一行**（由 `uq_uprofile` 保证），不再与 UUID 主键/单例行冲突。
- `DELETE /api/v1/auth/account` 语义冻结：校验密码 → 云端数据软删除保留 30 天（可恢复）→ 返回 `purgeAfter`；本机数据不删。
- 新增 **`AuthProvider` 抽象**落点：`PLAN.md §5.1` 增列 `AuthService`（14 → 15 个服务），附录 B **§7.1** 冻结接口契约（`login / register / logout / currentSession / migrateLocalData`）、`AuthDao` 持久化（token 只落 `preferences`）、`AccountMigrator`（首次登录并入本机数据）。

### 3. 界面与验收双向承载（附录 C / D）

- 新增 UI 元素：**`BackupListSheet`**（备份记录：时间 + 文件大小 + 单条删除 + 「清理旧备份」保留最近 3 份）、**`DevOptionsSheet`**（保存强制抛错 / 数据库体积 / 重建 `point_daily_stat` / 演示数据播种与清除）、**`DemoModeBanner`**、首页 **📤** ShareSheet 入口、识图半模态「模拟识别」提示条、「我的」页科普收藏分组、「待同步数」与「家庭碳积分合并」只读视图。
- 半模态数 5 → **7**；页面数 18（5 Tab + 13 二级页）。
- 新增验收：**D5-12**（云端备份/恢复）、**D6-11**（首次登录并入账号）、**D6-12**（注销语义）；D5-1/D5-10 改由 `BackupListSheet` 承载；D4-5/D4-8/D4-9、C4、P10、D3-5 全部有落点。
- D7-1 / I-5 / 附录 E：一律「给出候选类型，**不展示置信度数字或准确率**」。
- 数字格式唯一入口：减排**固定 4 位小数**（`12.4800`）、积分千分位（`4,820`）、碳币整数；实现只在 `Formatter.number(value, kind)`，页面禁止 `toFixed()`。

### 4. 因子与基准（附录 A + `tests/cases/carbon-calc.json`）

- 版本号统一为 **`CF-2026.2`**（唯一现存数值版本）；确立「**只有数值变化才升版本号**，来源/分级/角标变化只记本文件」。
- 决策 2a / 2b：回收 8 个（#20–#27）+ 光盘 2 个（#28/#29）因子**保留现有数值**，统一 `provisional`，界面必须标「参考值」角标，路演不得称权威；`SRC-GB51366` 停用（依据不可采信）、`SRC-CCAP-FW` 身份真相留档（《世界农业》期刊论文而非方法学原文）。
- `SRC-SH-INC`（上海市碳普惠方法学）可核实但**未被任何因子引用**——不换源 ≠ 否认上海口径。
- 基准 `factors` 由 21 条补到 **31 条**：新增 10 条 `recording:false` 对照镜像（`car` / `motorcycle` / `hsr` / `flight` / `water_treat` / `elec_thermal` / `elec_gas` / `textile` / `wood` / `kitchen_waste`）= 30 条 + `CAR_OWN_FACTOR` 1 条，与 `APPENDIX-A §2.5` 写死的镜像关系一致。
- §8 复核清单 10 项补齐**负责人 / 期限 / 取证方式**；§2.3 决策 2a 的错误论据（「换源会掉到 ≤5 录入项直接违规」）删除，改为"会连带改写已冻结文档与基准"。
- `_src/` 三份伪 PDF（md5 `2b567fd9a85fdeb7406a8c41aa929660`，各 60157 字节，实为中华环保联合会官网 HTML 存档）身份真相留档于 `APPENDIX-A §1.1`；**物理删除属 `_src/**` 变更，超出文档任务写入范围**（见 `AGENTS.md §9`）。

### 5. 数字与文案批次

目标数统一 **11**（README M3、附录 E 旁白）、首页建议**每日至多 1 条主建议**（PLAN §7.13.2 / F §2.2）、记录页**左滑**、累计减排统一 **12.4800**、D4-8/D4-9 行序对调、「陪伴引导」→「**配对引导**」、`summary.csv` 示例与附录 D §9 演示数据同源（徽章 **6**）、附录 E「一百二十余条」改为引用附录 D §9。
**未改动**：附录 E 分镜 5 的「**+15**」经核对为正确值（S3 光盘卫士 `reward: 15`，`PLAN.md §10.1` 与 `APPENDIX-B §8.1` 一致，S1+S2+S3 = 20+20+15 = 55 自洽）。

### 6. 文档冗余收敛（单一来源）

| 规格 | 唯一来源 | 其余位置 |
|---|---|---|
| 积分封顶取数 SQL | `PLAN.md §9.2` | 附录 A §3.3 只留口径要点 |
| 19 张客户端表建表 SQL | `APPENDIX-B §2` | `PLAN.md §5.2` 只留表清单 |
| 11 个目标的数值 | `PLAN.md §10.1` | 附录 B §8.1、附录 A §3.5 只引用 |
| 同步协议与 LWW 算法 | `APPENDIX-B §5.3 / §6` | `PLAN.md §12` 只留约束 |
| A1–A18 总门槛定义 | `PLAN.md §16` | 附录 D §11 只做映射 |
| 演示数据条数与分布 | `APPENDIX-D §9` | GLOSSARY、附录 E 只引用 |
| 文档导航与阅读顺序 | `docs/README.md` | 仓库根 `README.md` 只留入口顺序 |
| 设计令牌（颜色/尺寸/字体） | `APPENDIX-C §3` | `PLAN.md §14.1/§14.2` 改为引用 |
| 变更记录 | 本文件 | 附录 A/B/C/D/F 末尾小节改为指针 |

---

## v4.0（2026-10-15）· 规划定稿

> 以下为原附录 A / B / C / D / F 末尾「v4.0 相对 v3 的变更摘要」的合并存档。

### 附录 A · 因子与公式

| 变更 | 说明 |
|---|---|
| **删除修正系数** | 主公式简化为 `活动量 × 因子值`；`correctionOptions`、`correction_factor` 列、录入页档位控件全部移除 |
| **出行类统一为「净减排」口径** | 出行因子 = `max(0, CAR_OWN_FACTOR − 自身排放)`；`walk`/`bicycle` 由 0.0000 改为 **0.1920**（骑行 5 km 得 0.9600 kg / 96 分），`bus` 0.1520、`metro` 0.1620、`ev` 0.0870、`carpool` 0.0720、`ebike` 0.1800；JSON 每个出行因子新增 `ownValue` 字段保留自身排放值供科普对照 |
| **新增常量 `CAR_OWN_FACTOR = 0.1920`** | 出行净减排因子的对照基准；「少开一天车」改用它（不再误取 `car` 行的 0.0000） |
| **因子按 `recording` 分层** | **30** 个因子中 **20 个**进录入表单（满足 PLAN §7.1 的「≥20」约束），**10 个**只做展示与换算 |
| **统计数字订正** | v3 误写的「总数 31 / `recording:false` 11 / `verified` 14」三处相加皆不成立，已改为 **30 / 10 / verified 10、provisional 20** |
| **积分口径换源** | 封顶判定改为 `point_record` 实时聚合，`point_daily_stat` 降级为可重建的展示缓存 |
| **新增碳币兑换率** | `points.carbonCoinRate = 100`（`100 积分 = 1 碳币`，单向） |
| **JSON 版本** | `CF-2026.1` → `CF-2026.2` → **`CF-2026.3`**（来源溯源修正，见 §1.1）※注释：v4.1 已改回 `CF-2026.2`，见上文 |
| **回收类来源降级（2026-10-15）** | `SRC-GB51366` 依据不可核实 → 停用为 `deprecated`；回收 8 因子改挂 `SRC-CALC` 并降为 `provisional`；新增 `SRC-SH-INC`（上海市碳普惠方法学，回收类唯一可核实原始资料）；§1.1 留档三份伪 PDF 证据 |
| **`elec_grid` 来源更正（决策 1a）** | 来源编号 `SRC-MEE-2024`（指向 0.5777 产品碳足迹口径）→ **`SRC-MEE-GRID-2022`**（环办气候函〔2023〕43号「2022 年度全国电网平均排放因子 0.5703」）；**数值 0.5703 与 `KWH_PER_KG = 1.75` 均不变** |
| **`CAR_OWN_FACTOR` 来源更正（决策 3a）** | 来源 `SRC-EEA`（欧洲环境署，不发布中国数据）→ **`SRC-CALC`**；**数值 0.1920 不变**，出行 11 因子全部不动；`SRC-EEA` 停用为 `deprecated` |
| **回收 8 值维持不变（决策 2a）** | 不整体改用上海口径，理由见 §2.3 |

### 附录 B · 表与接口

| 变更 | 说明 |
|---|---|
| 表数 21 → **19** | 删除 `demo_marker`；新增 `carbon_include`、`share_record` |
| 新增 `carbon_include` | 碳普惠模拟兑换（创新项 Ⅲ） |
| 新增 `share_record` | 分享卡片记录（创新项 Ⅳ） |
| 同步机制替换 | 云账号 pull / push → **鸿蒙分布式数据服务**（§6 全新）※v4.1 已改回服务端同步为主通路、分布式为近场演示层 |
| 参与同步 7 → **9 张** | 新增 `carbon_include`、`user_profile` |
| 封顶判定换源 | 改为 `point_record` 实时聚合；`point_daily_stat` 降级为可重建的展示缓存 |
| 流水类型扩充 | 新增 `carbon_include` |
| `point_record` 幂等键 | `UNIQUE(source_type, source_id, type)` ※v4.1 改为 `(source_type, source_id, flow_kind)` |
| 服务端定位 | 由"必需"降为**可选演示件**（18 张同名表 + 3 张管理表 = 21 张）※v4.1 已改回必做件 |
| 后台规格并入 | 原附录 G 内容并入本附录 §5.4 与 PLAN 第 13 章，附录索引收敛为 A–F |

### 附录 C · 界面

| 变更 | 说明 |
|---|---|
| 页面新增 | 15 碳普惠（模拟） |
| 页面移除 | 「登录」不再是独立页 → `LoginDialog` 半模态 |
| 半模态新增 | `AiRecognizeSheet`、`ShareSheet`、`LoginDialog`、`RedeemConfirmDialog`、`UnlockCelebrationDialog` |
| 主色调整 | `#2E7D32` → `#2E7D5B`（对齐 PLAN §14.1） |
| 分类色调整 | 出行 `#4A90D9`、水电 `#E6A23C`、回收 `#7FB069`、光盘 `#D98C6A` |
| 同步页重写 | 云账号三段进度 → 鸿蒙分布式设备列表 + ①②③ 状态机；新增「超额不追回」说明 |
| 科普恢复 | 科普 Tab + 科普文章页（12 篇内置 Markdown） |
| 分享恢复 | 分享卡片作为 `ShareSheet`，两种尺寸，默认匿名 |
| 目标体系 | 11 个目标（5 短期 + 5 中长期 + 1 长期），按周期分组展示 |
| 外观页重写 | 头像 8 个全免费可切换；头像框需购买；头像上传、多主题明确不做 |

### 附录 D · 验收

| 变更 | 说明 |
|---|---|
| **覆盖 9 项官方要求** | 新增 1.6 协同 / 1.7 端侧 AI / 1.8 碳普惠 / 1.9 智能服务与分享四大组，共 30 条新验收项；原「创新项 D6-x」由"云同步 12 条"改写为"鸿蒙分布式协同 10 条" |
| **删除修正系数** | §3 公式改为 `活动量 × 因子值`；新增 D1-14「无修正系数」；§10.1 CSV 删除「修正系数」列 |
| **删除植树证书** | 删除 v3 的 D3-10/D3-11（兑换证书、证书编号 `CB-`）；新增 D3-28「无植树证书」防回归；§9 演示数据同步调整 |
| **出行类样例重算** | 采用「相对燃油车净减排」因子（步行/骑行 0.1920），样例由 12 组扩到 **18 组**，并新增 §3.2 封顶样例 5 行 |
| **封顶验收细化** | 新增 D3-3/D3-4/D3-5 三条，明确"判定不读缓存、缓存可重建且一致" |
| **新增 C 组一致性** | 原 §4 的 D4-1..D4-6 改为 **C1–C10**（避免与科普组 D4-x 编号冲突） |
| **协同环境改变** | 原"同后端同账号"改为同组网配对、不依赖服务端；新增 D6-9 家庭碳积分合并、D6-10 时钟偏移、E12 |
| **新增 §7.4–§7.6** | 碳普惠模拟、分享卡片、家庭合并三组专项验收 |
| **代码质量分级** | Q2「无硬编码文案」、Q3「无第三方依赖」降为**建议级**（AI 推理接口需三方能力） |
| **A1–A18 对照索引** | 新增 §11，把 PLAN §16 的 18 条总门槛逐条映射到本附录条目 |

### 附录 F · 合规

1. 赛题二要求由"5 项主要 + 2 项创新"扩展为 **9 项全做**（新增科普专栏、社交分享、碳普惠模拟为正式实现，不再"预留/不做"）。
2. 因子库由 35 个订正为 **30 个**（20 个可录入）；出行类统一为**相对燃油车净减排**口径，删除修正系数。
3. 多设备协同由"自建后端 + 云账号同步"改为鸿蒙分布式数据服务；服务端降级为可选演示件。（※v4.1 已改回：服务端必做，分布式为近场演示层）
4. 表数由 9 张（v2）/21 张（v3）收敛为**客户端 19 张**，其中 **9 张参与同步**。
5. 任务体系由"7 项任务"改为 **11 个周期目标**；积分新增**记录类当日封顶 200 分**与实时聚合判定（决策「甲」）、协同超额**不追回**（决策「甲2」）。
6. 奖励体系由"头像框 + 植树证书"改为**碳小铺**（8 个头像框 + 1 套默认主题），**取消植树证书**。
7. §2 的 I★1/I★3/I★4 行由"自建后端 / 预留 / 不做社交分享"改写为对应 v4.0 实现位置。
8. §5 不做清单由 10 条扩充为 **12 条**，明确"真实碳普惠对接 / 真实支付 / 第三方社交 SDK / 家庭账号体系"等边界。
