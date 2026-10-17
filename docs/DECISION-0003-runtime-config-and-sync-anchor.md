# DECISION-0003 · 运行期配置下发通道与同步锚点基准（决策记录）

> 本文件是 `AGENTS.md §10` ① 要求的「修改本文件必须留下决策记录」的落点，记录 **v4.2 勘误批次的第二批**
> （2026-11-07 追加）的**依据、取舍与影响面**。变更逐条清单在 [`CHANGELOG.md`](./CHANGELOG.md) 的 v4.2 §5/§6；
> 机器可读登记在 `tests/cases/carbon-calc.json → docConflicts` 的 **B46 / B47**。
> 本文件**不重复**规格正文（唯一来源：`PLAN.md` / `APPENDIX-*`）。

- **状态**：已生效（2026-11-07）；文档侧闭环，实现在 **t17 服务端 / t18 客户端** 跟进（两者均已完成，见「落点与实现跟进」）
- **触发**：两件事。① **t6（`/admin` 后台）交付时报出的 STOP** —— 验收 **D10-5** 的判据含「改目标奖励分值 / 每日封顶值 / 徽章开关 → **App 侧能读到**」，但附录 B §5.4 与 `PLAN §13.3` 只定义了商品目录下发（`GET /api/v1/shop/items`），**没有任何 `app_config` / `goal_def` 的读通道** → 后台的系统配置是「只写不读」的死功能，D10-5 没有可执行路径。② **t15 消歧 `offsetMs` 时发现的同类且更严重的问题**：`lastSyncAt` 同名不同基准。
- **原则**：**以已实现并已验证的口径为准收敛文档**；**只冻结文档契约、不改任何实现代码**；不改检查器、不放宽断言；不涉及任何数值（`tests/cases/carbon-calc.json` 的 `constants` / `factors` / `samples` 未动）。

## 决策

| # | 决策 | 理由（为什么不是另一种） | 影响面 |
|---|---|---|---|
| D1 | 新增**免鉴权** `GET /api/v1/config` 作为系统配置下发通道，与 `GET /api/v1/shop/items` 同组；响应体在附录 B 新 **§5.5** 冻结 | **不塞进已有鉴权接口**：附录 D10-8 要求「关闭后端时 App 全功能可用」，且**未登录态也要能读到公共配置**（铁律 1 的例外本就有「商品取价」这一类，配置与它同性质）；若挂在需 Bearer 的接口上，未登录态与后端故障路径会被迫分叉成两套降级逻辑。**不复用 `/api/v1/shop/items` 夹带**：该端点语义是商品目录、失败即整份丢弃，混入配置会让两条降级路径互相拖累 | `APPENDIX-B §5.4` 端点表 + 新 §5.5、`APPENDIX-D D10-5`；B47；提交 `d719c45`、实现 `0f320c2` |
| D2 | `pointsDailyCap` 只作**下行默认值**（搬运）；本机 `app_config` 仍是**唯一真相源**，`app_config` **不参与同步** | 铁律 1（本地优先）不允许服务端参与业务计算；离线必须照常可用。**不把服务端改成「权威配置」**——那会违反铁律 1，且断网即降级失败 | `APPENDIX-B §1.1/§1.2`（清单与「不参与同步」说明**未动**）；B47 |
| D3 | `lastSyncAt` 冻结为**单一服务端基准**（= 响应 `serverTime`，同一个值用于 `device_info.last_sync_at`、push 请求体、`pull?since=`） | **否决「客户端单锚点」**：`GET /sync/pull?since=` **没有 `clientNow`**，服务端在 pull 路径上拿不到 `offset_ms`；若把锚点定成客户端基准，服务端**无法换算回来**，增量边界会随时钟偏移漂移。**也不选「双字段各存一份」**——两处可能不一致，等于没收敛 | `APPENDIX-B §6.3 / §6.4-6`；B46；提交 `bfd5090` |
| D4 | 冲突判定**只把锚点换算到本机一侧**：派生 `lastSyncAtLocal ≝ lastSyncAt + clientOffsetMs = lastSyncAt − respOffsetMs`，§6.3 真冲突与平局分支统一写作 `l.updatedAt > lastSyncAtLocal && r.updatedAt > lastSyncAt`（等价写法 `l.updatedAt + respOffsetMs > lastSyncAt`）；服务端侧对端行先换算 `int(values["updated_at"]) + offset_ms > last_sync_at` | 本机行与换算后的锚点同基准、对端行保持原值，两侧各自自洽，**只需一次换算**且退化行为可自证。**不逐行换算 `updatedAt`**（两处都要改、越改越漏）；**不改条件本身**（会连带影响平局分支与 `conflicts` 计数口径 —— §6.4-3 要求二者同条件） | `APPENDIX-B §6.3 / §6.4-3 / §6.4-6`；B46 |
| D5 | `offsetMs` 保持**服务端视角**语义不变，在 §5.3 明文写出客户端**必须取反** `clientOffsetMs = −respOffsetMs`；§6.3 伪码参数由 `offsetMs` **更名 `clientOffsetMs`** | 服务端视角 = **服务端时钟 − 客户端时钟**（`sync_service.py:outcome.offset_ms = started_at - client_now`），客户端视角与其**互为相反数**。照伪码字面直接相加，在服务端快 60 秒时会把对端时间戳算**新** 60 秒 → 对端更旧的行反而覆盖本机，得到与 §6.4-6 **相反**的收敛结论（双机演示才暴露、极难定位）。**不改响应字段方向**（要动已冻结协议与两侧实现，收益为零）；**不只加注释不改名**（同名陷阱仍在） | `APPENDIX-B §5.3 / §6.3 / §6.4-6`；B46；提交 `67f363b` |
| D6 | 客户端落地口径：**整份校验、任一字段非法即整份丢弃**；`goalId` 必须能在 `rawfile/goals/goal-defs.json` 里找到，否则**整条忽略**；`goalRewards` 可缺省（缺省 = 用内置 rawfile 种子）；**冷启动**生效 | 半份生效的配置比不生效更难排查，且 D10-5 的判据无法判定；`goalId` 是跨端外键，未知值必须丢弃而非新建（否则凭空造出无 `goal_def` 承载的目标） | `APPENDIX-B §5.5`；B47；实现 `18db1db` |
| D7 | `badgesEnabled` **必须序列化为 JSON 布尔**（`1`/`0` → `true`/`false`）；`version` 用**独立键名** `app_config['config_version']`，不与 `shop_items_version` 互相顶替 | 客户端是强类型 ArkTS，收到数字 `1` 会在校验层被拒 → 整份丢弃 → 配置通道**静默失效**；两套配置共用一个版本键会导致改价顺带刷新配置（或反之） | `APPENDIX-B §5.5`；B47；t19 补 `config_version` bump |
| D8 | 配置通道在冷启动拉取一次，不参与同步协议、不写 `admin_op_log` / `sync_log` | 它是「下行默认值」不是用户数据变更，没有审计与冲突语义；写入日志会污染 §6.4 的冲突计数口径 | `APPENDIX-B §5.5`；B47 |

## 自证判据（可执行）

- **D5（`offsetMs`）**：`respOffsetMs = +60000` ⇒ 服务端 `updatedAt = T` 的行换算到客户端基准必须是 **`T − 60000`**（即显得更旧）；服务端侧与自己的基准同向，**不取反**。
- **D3/D4（`lastSyncAt`）**：`respOffsetMs = 0` ⇒ `lastSyncAtLocal === lastSyncAt`，客户端与服务器两式退化为同一个数。§6.4-6 另给「凡跨端时间戳必须能说清在哪个基准上」的字段归属表。
- **D1/D6/D7（配置通道）· 验收口径（附录 D10-5）**：App 冷启动后本机 `app_config['server_config']` 内 `pointsDailyCap` / `badgesEnabled` / `goalRewards` 三项**与后台一致**即为通过，数据来源为 `GET /api/v1/config`。

## 落点与实现跟进

| 事项 | 文档提交 | 实现提交 | 状态 |
|---|---|---|---|
| 配置下发通道（附录 B §5.4 行 + 新 §5.5 + D10-5 口径） | `d719c45` | `0f320c2`（server `app/api/v1/config.py`）、`18db1db`（app `ServerConfigFetcher.ets`） | 已实现并验证 |
| `lastSyncAt` 单一服务端基准（§6.3 / §6.4-6） | `bfd5090` | 客户端 t13 已按取反实现（`viewmodel/net/SyncService.ets`） | 已实现 |
| `offsetMs` 同名双视角消歧（§5.3 / §6.3 / §6.4-6） | `67f363b` | 同上 | 已实现 |
| `config_version` bump（后台改配置时刷新 `version`） | §5.5 已冻结键名与语义 | t19 进行中 | 跟进中 |

## 未决 / 不在本决策范围

- **`app_config['server_config']` 的存储形态**：§5.5 只冻结「整份落 `app_config['server_config']`」与「整份校验失败即整份丢弃」，
  未规定序列化细节（单行 JSON 文本 or 分列）——**属实现细节**，由 t18 决定，不回写文档。
- **`version` 与上一份相同时的行为**：§5.5 明确「由客户端自行决定」（可用于省一次本地写入），**本契约不强制**。
- **`/admin` 侧改配置后的下发时效**：本决策只保证「冷启动拉取一次」；不引入推送/长连接，后台改完需等下次冷启动（演示口径已写在附录 D10-5）。
- **附录 B/C/D 正文**：本轮**不再改动**（`d719c45` + `bfd5090` 已逐条验收）。

## 变更记录

| 日期 | 决策 | 依据 |
|---|---|---|
| 2026-11-07 | D1–D8 全部生效；`AGENTS.md §1.4` 新增 B46/B47、`§9` 区间更新为 B1–B47、`§10` 补一行；`CHANGELOG.md` v4.2 追加 §6；`docConflicts` 共 **47** 条、`open` 0 条 | t6（`/admin`）报出的 STOP + t15 消歧 + 附录 D10-5/D10-8 |
