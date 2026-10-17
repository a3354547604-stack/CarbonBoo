# tests/ · 碳小布 CarbonBoo 测试

> 规则依据：`AGENTS.md` §5（测试即完成定义）、§1.4（待修清单）。
> 原则：**能跑的断言才算验收**；人工勾选的条目（附录 D）只是入口，最终必须落到这里的某一层。

---

## 1. 分层

| 层 | 范围 | 现在能否跑 | 位置 |
|:--:|---|:--:|---|
| **L0** | 数值与文档一致性：碳计算 18 组样例、封顶 5 组、边界样例、文档已知冲突扫描 | ✅ **现在就能跑**（只依赖 Python 3） | `tests/tools/check_l0.py` + `tests/cases/` |
| **L1** | 纯逻辑单测（ArkTS / hypium）：计算、封顶、目标与徽章幂等、备份往返、CSV 编码、LWW 合并、系统配置下发 | ✅ **套件已建**（**10 个** `.test.ets` 用例文件 + `List.test.ets` 汇总入口）；执行需 SDK Previewer / 真机 / 模拟器，本机无 → **尚未真正跑过**（见 §5 L1） | `app/entry/src/ohosTest/ets/test/` |
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

包含：21 个因子（20 个可录入 + `CAR_OWN_FACTOR`）、2 条换算规则、18 组正向样例、5 组封顶样例、6 条边界样例、`docConflicts` 待修清单。

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
| ~~`PointCap.test.ets`~~ | **已并入 `CalcSamples.test.ets`**（同上行，5 组封顶样例），不再单独建文件 |
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
> ⚠️ **执行状态**：本机无真机/模拟器（hypium 需 SDK Previewer 驱动，且该二进制与本机 glibc 不兼容），
> 故 L1 的现有证据只有「随 `ohosTest` 目标 `assembleHap` 编译通过 + 人工审查」，**尚未真正跑过**——
> 不得据此声称任何 L1 用例"通过"。

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

---

## 6. 目录

```
tests/
├─ README.md              # 本文件
├─ cases/
│  └─ carbon-calc.json    # 数值唯一真相源（L0 与 L1 共用）
└─ tools/
   └─ check_l0.py         # L0 检查器（现在即可运行）
```
