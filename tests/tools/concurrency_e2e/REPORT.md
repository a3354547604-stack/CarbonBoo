# `tests/tools/concurrency_e2e/REPORT.md` —— 并发 / 竞态实跑报告（t61）

> **绑定基准**：`git rev-parse HEAD` = `1866838bd6dee9567cd35fe10bc6bcdbbf4d37f8`
> （`git ls-remote origin main` = `92dd282d56a7cf0c9585e651ebb8a7975b68d8ac`；`92dd282..HEAD` 的两个提交
> 只改 `app/entry/src/main/ets/viewmodel/net/SyncService.ets` 与 `app/entry/src/ohosTest/ets/test/LwwMerge.test.ets`，
> `git diff --name-only 92dd282..HEAD -- server/` = **0 行** ⇒ 本报告的服务端证据在当前 HEAD 上有效）
> **实测主机**：WSL2（Docker Desktop 27.5.1）+ 容器 `carbonboo-mysql`（`127.0.0.1:13307`，MySQL 8.0.46）
> **本工具自身的提交**：`git log -1 --format=%H -- tests/tools/concurrency_e2e/`（只新增本目录，不改任何被测字节）
> **日志**：`/tmp/t61/run7.log`（本体）、`run4.log` / `run6.log` / `run5.log`（重跑对照）；现场保留 `/tmp/cbconc.gGyeEg`

---

## §0 一句话结论与判定口径

**结论**：四处「并发敏感」的服务端设计里，**唯一键并发入账、同步 push 幂等、余额恒等式、限流**在真实
MySQL + 真实 `uvicorn --workers 2` 的并发下**成立**（35 条断言全过）；**LWW 合并**在并发下**不守恒**，
且这条缺陷被**四次独立实跑复现**（32 轮里 11 轮最终落库的不是最大 `updated_at`）。此外发现 3 条
「与交付质量相关度不同」的问题（归因错误计数、契约冲突），逐条见 §4。

**判定口径（写死，避免把「发现」当「断言」混算）**：

| 类别 | 是否影响 `run.sh` 退出码 | 出现在哪 |
|---|---|---|
| 断言（`[PASS]/[FAIL]`） | 是（`FAIL` ⇒ 退出码 1） | §3 |
| **产品侧 STOP 发现**（`[!] 发现 …`） | **否**（默认）；`CONC_STRICT_CONTRACT=1` 时是 | §4 |

任务书写明「发现真缺陷写三行 STOP 只报告不改」，故产品契约被并发违反时按 STOP **发现**呈现并给原始数据，
不与「工具自身的断言」混在一个计数里；不想放过它时跑
`CONC_STRICT_CONTRACT=1 bash tests/tools/concurrency_e2e/run.sh` → 退出码 1。

---

## §1 复现命令与退出码

```bash
$ cd /mnt/c/Users/Administrator/Desktop/CarbonBoo
$ CONC_KEEP=1 bash tests/tools/concurrency_e2e/run.sh; echo "RUN_EXIT=$?"
…
RESULT: PASS
[INFO] 保留现场：/tmp/cbconc.gGyeEg（CONC_KEEP=1）
RUN_EXIT=0
```

| 退出码 | 含义 | 本次取值 |
|---|---|---|
| `0` | 全部断言通过（§4 的产品侧发现不影响退出码） | **run7 = 0**（36 PASS / 0 FAIL） |
| `1` | 有断言失败；或 `CONC_STRICT_CONTRACT=1` 且存在非 info 级发现 | run1–run5 期间出现过（工具自身 bug 与产品缺陷），修好后为 0 |
| `2` | 环境不可达（无 docker / 容器没起 / `server/.env` 缺键 / `server/.venv` 缺失 / 建库失败 / uvicorn 起不来） | 见 §5.3 自证 |

---

## §2 环境（`S0` 原始读数，实测）

```
VERSION()          = 8.0.46
max_connections    = 30
transaction_isolation = REPEATABLE-READ
Max_used_connections(本次启动后累计峰值) = 21
Threads_connected  = 3
目标库 = carbonboo_conc_go965j（任务专属，跑完 drop）
```

**这确实是两个 worker 进程**（不是单进程假象），uvicorn 日志原文：

```
INFO:     Started parent process [1333078]
INFO:     Started server process [1333133]
INFO:     Started server process [1333132]
```

`pool` 参数出处：`server/app/core/database.py:34-37`（`pool_size` / `max_overflow` / `pool_recycle` / `pool_timeout`），
默认值 `server/app/core/config.py:72-75` = `5/5/1800/30`，`database.py:50` 打印上限 `2 * (pool_size + max_overflow)` = 20。

---

## §3 逐场景：并发数 / 期望 / 实测 + 原始证据

### S1 唯一键并发入账（18 并发）

| 项 | 值 |
|---|---|
| 并发数 | 18 条 push（9 条同 `(user_id, source_type, source_id, flow_kind)` + 9 条异键） |
| 期望 | 最终**恰好 1 行**；`SUM(points)` 只计一次 200；每条响应 `skipped = ignored + rejected`；合计 `accepted = 1` |
| 实测 | `COUNT(*)=1 DISTINCT(id)=1`、`SUM(points)=200`、`skipped=ignored+rejected` 自洽 **18/18**、`sum(accepted)=1` |

原始响应（节选，逐条）：

```
#00 http=200 accepted=1 ignored=0 rejected=0 skipped=0 conflicts=0
#01 http=200 accepted=0 ignored=1 rejected=0 skipped=1 conflicts=0
#02 http=200 accepted=0 ignored=1 rejected=0 skipped=1 conflicts=0
…
```

**结论：唯一键并发入账成立**（挡重复靠 `uq_pr_source(user_id, source_type, source_id, flow_kind)`，
`server/sql/schema.sql:86`），并发下没有重复计分。

> `S1.5` 是**如实标注而非通过**：服务端 `point_record` 无 `sync_state` 列
> （`SHOW COLUMNS FROM point_record LIKE 'sync_state'` → 0 行），故「`sync_state` 分布」在服务端结构上不可观测。

### S2 同步 push 幂等（16 并发 × 5 轮）

| 项 | 值 |
|---|---|
| 并发数 | 16 并发推同一 `carbon_record`，重复 5 轮 |
| 期望 | 每轮只落 1 行；落库内容与推送值逐字段一致；`offsetMs` 只在带 `clientNow` 时非 0 |
| 实测 | 5 轮**全部** `COUNT(*)=1`；5 轮 `skipped=ignored+rejected` 均 `16/16`；5 轮最终行逐字段一致（`amount=5.0 reduction_kg=4.5 factor=0.9/CF-2026.2 points=450`） |

```
S2.4 带 clientNow ⇒ offsetMs ≠ 0 | offsetMs=[7, 10, 11, 17, 19, 21, 24, 25, 28, 35, 37, 38, 40, 42]
S2.5 accepted 计数可以 > 1（LWW 写回同值），但行数仍恒为 1 | sum(accepted)=14 rows=1
```

**结论：push 幂等成立**（行数维度）；但「重复行为什么算重复」有归因缺陷 → 见 §4.2（S2，low）。

### S2b LWW 并发丢更新（8 轮 × 16 并发，同一 `id`、`updated_at` 递增）

| 项 | 值 |
|---|---|
| 并发数 | 每轮 16 个版本并发 push 同一 `id`，`updated_at` 依次递增（`race-v01`…`race-v16`，`deviceId` 各不相同） |
| 期望 | 最终行 = **最大 `updated_at`** 的那一版（附录 B §6.4-6「`updatedAt` 大者胜」） |
| 实测 | **违反 6/8 轮**（run4 = 3/8、run5 = 0/8、run6 = 2/8、run7 = 6/8） |

run7 逐轮原始输出：

```
round0: max(updated_at)=1792389554072 实际落库=1792389554072 note=race-v16 => OK
round1: max(updated_at)=1792389555072 实际落库=1792389555066 note=race-v10 => LWW 违反（旧版胜出）
round2: max(updated_at)=1792389556072 实际落库=1792389556072 note=race-v16 => OK
round3: max(updated_at)=1792389557072 实际落库=1792389557070 note=race-v14 => LWW 违反（旧版胜出）
round4: max(updated_at)=1792389558072 实际落库=1792389558071 note=race-v15 => LWW 违反（旧版胜出）
round5: max(updated_at)=1792389559072 实际落库=1792389559064 note=race-v8  => LWW 违反（旧版胜出）
round6: max(updated_at)=1792389560072 实际落库=1792389560064 note=race-v8  => LWW 违反（旧版胜出）
round7: max(updated_at)=1792389561072 实际落库=1792389561071 note=race-v15 => LWW 违反（旧版胜出）

统计：LWW 违反轮次 = 6/8；自称 accepted 却未存活的响应数 = 30
```

**结论：LWW 在并发下不守恒（丢更新），是真缺陷** → §4.3 给三行 STOP、文件行号与建议。

> 同一 `id` 并发 push **不产生重复行**：`S2b.2` = `COUNT(cr-race-%)=8`，期望 8 ⇒ 通过（幂等与 LWW 是两件事）。

### S3 积分封顶（8 并发同日入账）

| 项 | 值 |
|---|---|
| 并发数 | 8 条 push，同日、每条各带 `point_awarded = 200` |
| 期望 | 不丢行、不重复行；并查服务端是否存在「封顶读-改-写」路径 |
| 实测 | `落库 8/8 sum(accepted)=8`；`point_daily_stat` **0 行**；`server/app` 内「`200 − D`」封顶算术命中 **0** |

```
S3.1 8 条并发同日入账全部落库（无丢失、无重复） | 落库 8/8 sum(accepted)=8
S3.2 服务端不产生任何封顶读数（point_daily_stat 0 行）⇒ 封顶读-改-写在服务端不存在 | point_daily_stat=0 行
S3.3 服务端无封顶读-改-写路径（无 `200 − D` 算术、不写 point_daily_stat） | point_daily_stat=0 行；server/app 内封顶算术命中 = 0
```

**结论**：服务端**没有**封顶读-改-写路径（封顶是客户端 `PointService` 的事），所以「并发超发」在服务端不构成
竞态缺陷；但「8 条并发同日入账合计 1600 > 200」与任务书场景 3 的期望判据冲突 → 作为契约问题记 §4.4（medium）。

### S4 连接池上限（6 轮 × 64 并发）

| 项 | 值 |
|---|---|
| 并发数 | 384 个并发 `GET /api/v1/sync/status`（每请求查库），并发数 ≫ `2×(pool_size+max_overflow)=20` |
| 期望 | 无 5xx、无 `QueuePool` 超时/`Too many connections`；给出本库真实并发连接峰值 |
| 实测 | 直方图 `{"200": 384}`；本任务库并发连接**峰值 = 20**（= 上限）；`uvicorn.log` 无任何池耗尽错误 |

```
状态码直方图 = {"200": 384}
本任务库并发连接峰值（information_schema.PROCESSLIST WHERE DB=carbonboo_conc_go965j）= 20
max_connections = 30（全局，含同容器其它任务）
(uvicorn.log 中无 QueuePool/TimeoutError/Too many connections/Traceback)
```

**结论：连接池上限在并发下没有被击穿**（峰值恰好贴住 20，未溢到 30，也未出现排队超时）。

### S5 登录限流（60 并发）

| 项 | 值 |
|---|---|
| 并发数 | 60 并发 `POST /api/v1/auth/login`（同 IP + 同用户名），`LOGIN_RATE_LIMIT_PER_MINUTE=10`，`--workers 2` |
| 期望 | 出现 429；放行数 ≤ 阈值 × worker 数 = 20；窗口内后续仍被限 |
| 实测 | 直方图 `{"200": 20, "429": 40}`；放行 20 = 上限 20；窗口内再登录 → 429 |

```
状态码直方图 = {"200": 20, "429": 40}
429 响应体样本：{"ok":false,"code":"RATE_LIMITED","message":"登录尝试过于频繁，请 60 秒后再试（上限 10 次/分钟）"}
S5.3 窗口内后续登录仍被限住（不是一次性误判） | http=429
```

**结论：限流在并发下真的限住**；口径按 `server/app/core/ratelimit.py:1-6` 自述的「进程内滑动窗口」，
故 2 worker 的有效上限 = 10 × 2 = 20（**不是**全局限流，本工具不把它当全局）。

### S6 并发后一致性

```
S6.1 余额 = 收入合计 − 支出合计（客户端口径 SUM(points) 恒等） | 1000 vs 1000 - 0
S6.2 point_record 只增不删（快照取证：S1 后的行全部仍在且三列逐值不变） | 消失 0 / 改动 0
S6.3 无重复 id（COUNT(*) = COUNT(DISTINCT id)） | 5 vs 5
S6.4 S1 并发批次最终仍恰好 1 行 / 200 分（无丢更新） | rows=1 points=200
```

（`UPDATE`/`DELETE` 触发器建不了：`1419 You do not have the SUPER privilege and binary logging is enabled` ——
工具**不吞**这个错，打印原文后改用「S1 后快照 → S6 三列逐值比对」的数据级取证，见 README §5.1。）

---

## §4 STOP 发现（只报告不改；按任务书三行格式 + 原始数据）

### 4.1 `S1-note`（info）—— 服务端没有 `sync_state` 列

```
STOP: 服务端 point_record 无 sync_state 列，「待同步数」在服务端结构上不可观测。
冲突: 附录 B §2 的 server 侧建表（`server/sql/schema.sql`）与客户端 19 表口径不同 —— 客户端
      `carbon_record`/`point_record` 等 9 张表带 `sync_state`，服务端不存该列；而 pull/push 的
      `sync_state` 只存在于**客户端**。这不一定是缺陷（服务端不需要），但「服务端待同步数」这类
      指标在服务端无法直接查询。
建议: 文档口径已按客户端为准（AGENTS §2 铁律 1「本机 relationalStore 是唯一真相源」），
      本工具如实标注为「结构上不可观测」，不计入通过。
```

### 4.2 `S2`（low）—— 并发重复行被归因为 `unknown`，计入 `rejected`

**原始数据**（同一场景四次跑，命中 4/4）：

```
run4: 同一行 16 并发重推时，有 33 条响应把「重复行」归因为 unknown 并计入 rejected
run6: … 26 条 …
run7: … 36 条 …
（run5 该场景被 CONC_ONLY 裁剪，未测）
```

```
STOP: 同一行 16 并发重推时，最多 36 条响应把「重复行」归因为 unknown 并计入 rejected。
冲突: server/app/services/sync_service.py 在 INSERT IGNORE rowcount=0 后调 _diagnose_ignored（:247）
      重新 SELECT 归因，但 MySQL 默认 REPEATABLE READ 下该事务快照仍看不到并发事务刚提交的行
      ⇒ 返回 unknown ⇒ _merge_lww 落到「未识别冲突来源」分支计 rejected。
      ↔ 附录 B §6.4-3「跨设备重复被去重计入 ignored」与 §5.3 的 `skipped = ignored + rejected` 语义。
建议: 归因前 `SELECT ... FOR UPDATE`，或把隔离级别降到 READ COMMITTED，或先 `INSERT ... ON DUPLICATE KEY
      UPDATE id=id` 再 SELECT，使「同 id / 同业务键」在并发下稳定归因为 ignored。
数据面影响: **无**（每轮仍只 1 行、内容一致；只影响客户端对回写结果的判断）。
```

### 4.3 `S2b.1`（**high**）—— LWW「`updatedAt` 大者胜」在并发下不守恒（丢更新）

**原始数据**（四次独立实跑，32 轮里 11 轮违反）：

| 跑次 | 违反轮次 | 「自称 accepted 却未存活」的响应数 |
|---|---|---|
| run4 | 3/8 | 15 |
| run5 | 0/8 | 0 |
| run6 | 2/8 | 11 |
| run7 | **6/8** | **30** |

```
STOP: 同一行被 16 个并发 push 写、updated_at 递增时，8 轮里有 6 轮最终落库的不是最大 updated_at
      （LWW「updatedAt 大者胜」在并发下不守恒 ⇒ 丢更新）。
冲突: server/app/services/sync_service.py:405 _merge_lww 走「SELECT 现有行 → 比较 updated_at → UPDATE」
      （:466 `if remote_updated > local_updated`），而 :490 _apply_update 的 UPDATE 只带
      `WHERE id=? AND user_id=?`（:495），既没有 `AND updated_at < :remote`，也没有 `SELECT ... FOR UPDATE`：
      两个事务可同时读到旧行、都通过比较，后提交的更旧版本覆盖先提交的新版本
      ↔ 附录 B §6.4-6「updatedAt 大者胜」两端收敛口径。
建议: 把比较条件下推进 UPDATE 的 WHERE（`... AND updated_at < :remote_updated`），或 `SELECT ... FOR UPDATE`
      锁住该行再比较，或改用 `INSERT ... ON DUPLICATE KEY UPDATE col = IF(VALUES(updated_at) > updated_at,
      VALUES(col), col)`，使「大者胜」成为数据库层的不变式。
自愈性: 下一次同步会把更新的版本重新推上来（收敛），但本次编辑在服务端确实被旧值覆盖过，
        且这 30 条响应都告诉客户端「accepted=1」（客户端会据此标记已同步）。
```

**性质**：服务端并发缺陷（不是工具问题）；触发条件是「同一行在毫秒级窗口内被两端并发 push」。
**未修**（超出 t61 只读边界：`server/` 不在 inScope），留给 fixer 任务。

### 4.4 `S3`（medium）—— 并发同日入账合计 1600 > 200，服务端无封顶路径

```
STOP: 并发同日入账合计 = 1600 > 200（任务书场景 3 的期望判据），但服务端并无封顶路径。
冲突: 附录 B §2 / PLAN §9 的封顶口径（`实入 A = max(0, min(C, 200 − D))`、`point_daily_stat` 记当日已得）
      由**客户端** `PointService` 实现；服务端 `server/sql/schema.sql` 无 `point_daily_stat`、
      `server/app` 内无「200 − D」算术（实测命中 0）。后端把每条 push 原样入账 ⇒ 同日 8 条各 200 共 1600。
建议: 这不是「服务端该补封顶」的简单结论 —— 铁律 1 规定本机是唯一真相源、云端只搬运。要么在文档里
      写明「服务端不做封顶（封顶是端侧职责，服务端只存原值）」，要么给服务端加一道与端侧同口径的
      防线；属**契约决策**，需队长/用户拍板，不自行选一个实现。
```

---

## §5 三分类：实跑 / 静态验证 / 未运行

### 5.1 实跑（本次用真实 MySQL + 真实 2-worker HTTP 打出来的）

| 场景 | 并发 | 结论 |
|---|---|---|
| S0 环境 | — | MySQL 8.0.46 / `max_connections=30` / REPEATABLE-READ / 峰值 21 |
| S1 唯一键并发入账 | 18 | ✅ 恰好 1 行、不重复计分、三数自洽 18/18 |
| S2 push 幂等 | 16 × 5 轮 | ✅ 每轮 1 行、内容逐字段一致、`skipped/ignored/rejected` 自洽 16/16 |
| S2b LWW | 16 × 8 轮 | ❌ **违反 6/8**（四次跑合计 11/32）→ §4.3 |
| S3 封顶 | 8 | ✅ 不丢行不重复；服务端无封顶路径 → 契约问题 §4.4 |
| S4 连接池 | 384 请求 | ✅ 全 200、峰值贴住上限 20、无池错误 |
| S5 限流 | 60 | ✅ 429=40 / 200=20（= 10×2 worker）、窗口内持续限住 |
| S6 一致性 | — | ✅ 余额恒等式、只增不删（快照取证）、无重复 id |
| 清理自证 | — | ✅ 端口 `CLOSED`、`carbonboo_conc_*` 遗留 0、生产库逐表 `COUNT(*)` 跑前==跑后、残留进程 0 |

### 5.2 静态验证（读源码/配置得出，**不是**跑出来的）

* 连接池上限出处：`server/app/core/database.py:34-37`、默认值 `server/app/core/config.py:72-75`、打印 `:50`。
* 限流实现口径：`server/app/core/ratelimit.py:1-6`（进程内计数，非全局）。
* 服务端无封顶算术：`grep -rn '200 -\|200 −' server/app` 命中 0；`point_daily_stat` 在 `server/sql/schema.sql` 不存在。
* LWW 代码路径：`server/app/services/sync_service.py:405/:459-500`、`_diagnose_ignored` `:247`。
* 触发器的不可用：MySQL `log_bin` + 应用账号无 `SUPER`（1419，报错原文见 §3 S6）。

### 5.3 未运行（**一条都不算通过**）

| 编号 | 未运行项 | 具体原因与原始错误 |
|---|---|---|
| N1 | **真机 / 模拟器并发** | 无真机、无模拟器：`hdc` 不在 PATH（`command -v hdc` → 127）、`/dev/kvm` 不可写、Previewer 崩于 GLIBC 断言（`docs/VERIFICATION.md` §R4 已留档）。ArkTS 端 `relationalStore` 并发、端侧封顶读-改-写**完全没跑** |
| N2 | **L2 端侧集成（两设备近场）** | 需要两条真机；本机无设备 |
| N3 | **分布式 / 多机并发** | 只跑了「同机 2 个 uvicorn worker + 1 个 MySQL 容器」；多机、主从、跨进程行锁退化未测 |
| N4 | **真双设备同步** | 本工具用「换 `deviceId` 字段」模拟多设备，与「两台真机各自离线改同一行再同步」不是一回事 |
| N5 | **性能 / 压测** | 无 QPS、P95、内存、慢查询证据；并发数只为触发竞态 |
| N6 | **整轮 `CONC_STRICT_CONTRACT=1`** | 未跑整轮；只在单场景 `CONC_ONLY=s3` 上做过**成对自证**：`STRICT=1` → `RESULT: FAIL（探针退出码 1）`、退出码 **1**；同一场景不带 STRICT → `RESULT: PASS`、退出码 **0**（同一条 S3 发现两次都打印）。日志 `/tmp/t61/strict_s3.txt`、`/tmp/t61/plain_s3.txt` |
| N7 | **工具自身退出码 2（环境不可达）分支** | 部分验证：分支①「没有 docker」→ `[ENV] 没有 docker` + `RESULT: ENV-UNREACHABLE` + 退出码 **2**；分支②「容器不存在」→ `[ENV] 容器 cb-mysql-definitely-absent 不存在` + 退出码 **2**。分支③端口连不上、④缺 `.env` 键、⑤缺 `.venv`、⑥建库失败 **未逐个制造** |

---

## §6 跨跑对照（可重复性）

| 跑次 | 断言 PASS/FAIL | 退出码 | S2b 违反 | 备注 |
|---|---|---|---|---|
| run4 | 33 / 4 | 1 | 3/8 | 工具自身 3 个 bug（S3 计数口径、S4 峰值采样、S4.3 判定串）+ S2b 真缺陷 |
| run5 | 36 / 0（在 S3 崩溃前） | 1 | 0/8 | `pymysql` 对 `LIKE 'cr-cap-%'` 的 `%` 误判为格式符 → 崩溃 |
| run6 | 36 / 0 | 0 | 2/8 | 工具 bug 修净；S2b 去重后只报 1 条 finding |
| run7 | **36 / 0** | **0** | 6/8 | 本报告主体 |

除 S2b（竞态，概率性）与各条动态值（`offsetMs` 数组、`updated_at` 毫秒、端口/库名）外，
四次跑的 `[PASS]` 行集合一致。

---

## §7 这次**没能证明什么**（边界，硬写死）

1. 本工具证明的是**服务端在并发下的行为**，**不**等于「端侧并发安全」；ArkTS 端一行都没跑（N1）。
2. 「多设备」是同一进程里换 `deviceId` 字段，**不**等于真双机（N4）。
3. 单机 2 worker **不**代表分布式部署（N3）。
4. 没有性能数据（N5）；`384 个并发请求全部 200` 只说明没崩，不说明快。
5. `S2b` 是**概率性**竞态：单次跑到 0/8 不能证明它不存在（run5），四次跑合计 11/32 违反才是判据。
6. 本报告不替代 `server/tests/`（237 条顺序 pytest），后者是顺序功能口径，两者互不替代。

---

## §8 t66：严格模式（F2）与「确定性红」的归属

> t65 复核的两条 must-fix 之一：本工具**没有**开启严格模式，导致 S2b 的 LWW 违反计数不影响退出码 ——
> 修复一旦回归，`run.sh` 仍会打印一行 STOP 发现后照样 `RESULT: PASS`（假绿）。本节是修复后的口径与判据。

### 8.1 `run.sh` 显式导出 `CONC_STRICT_CONTRACT=1`

`tests/tools/concurrency_e2e/run.sh` 第 17 行（`set -uo pipefail` 之后）新增：

```bash
export CONC_STRICT_CONTRACT=1
```

于是探针（`lib/conc_probe.py:46`）的 `STRICT_CONTRACT` 恒为真，**门禁级发现**会让退出码变 1。

### 8.2 「门禁级发现」= 代码缺陷，不含待裁决的契约口径

`lib/conc_probe.py` 的 `finding(..., gating=...)`：缺省按 severity 判定，`blocker|high` 拦门禁；
`S3`（并发同日入账合计 > 200、服务端无封顶路径）显式 `gating=False`，`S1-note`（服务端无 `sync_state`
列）同为 `info` 不拦。理由写死在 `GATING_SEVERITIES` 的注释里：**契约口径是产品/队长待拍板的问题，
不是被测代码的回归** —— 让它拦门禁，「绿」就不再表示「无回归」，退出码随之失去信号意义。
（`S2b.1` 仍是 `high` ⇒ 默认拦门禁，这正是 F2 要的。）

### 8.3 关键事实：S2b 是**概率性**探测，别只看 `RESULT: PASS`

- 修复前（t63 之前、`_merge_lww` 先 SELECT 再无条件 UPDATE）本工具**单跑曾出现 `LWW 违反轮次 = 0/8`**
  （t61 run5）—— 单次 0/8 **不能**证明竞态不存在；
- 四次跑合计 **11/32** 轮违反才是修复前的判据；
- **确定性**的红来自 `server/tests/test_sync.py::test_lww_concurrent_push_converges_to_max_updated_at`
  （`8` 轮 × `16` 并发、`threading.Barrier` 同步起跑，修复前 `2 failed`，`-k concurrent_push` 即可复现）。

### 8.4 可逆演示（判据：违反非零 ⇒ `run.sh` 非零退出）

```bash
# ① 触发回归：把「比较 + 写入」的原子条件临时置空（等价退回旧行为）
#    server/app/services/sync_service.py 的 _merge_lww 内
#    `if_newer_than=(remote_updated, remote_device)` → `if_newer_than=None`
bash tests/tools/concurrency_e2e/run.sh; echo "CONC_MUT_EXIT=$?"     # 期望：非零（S2b 违反 ⇒ 门禁级发现 ⇒ 1）
# ② 还原（禁 cp，必须走 git 对象）
git show <sha>:server/app/services/sync_service.py > server/app/services/sync_service.py
cmp <(git show <sha>:server/app/services/sync_service.py) server/app/services/sync_service.py   # 期望：无输出
bash tests/tools/concurrency_e2e/run.sh; echo "CONC_EXIT=$?"          # 期望：0
```

复现日志与逐行原始输出见 t66 提交信息 / 任务报告；本节只固定**判据与命令**。

### 8.5 t66 附带的同批修复（与 F2 无关，但同一次提交）

`server/app/services/sync_service.py` 的平局比较加了显式 `collate("utf8mb4_bin")`（t65 F1）：
列的默认排序规则 `utf8mb4_0900_ai_ci` 会把 `'A-dev'` 与 `'a-dev'` 判成相等，使字节序更大的远端
永远赢不了平局，与客户端（`SyncService.ets` 的 `remoteDevice > localDevice`）永久不收敛。
回归用例：`server/tests/test_sync.py::test_lww_tie_break_uses_byte_order_not_column_collation`。
**已知边界（F4，不属本任务）**：比较处用服务端基准（`updated_at + offset_ms`），落库处写客户端裸时间戳
（`sync_service.py:545` / `:600-601`）—— 归 t68，本报告只记一句，未改。

