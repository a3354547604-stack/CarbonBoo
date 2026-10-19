# `tests/tools/concurrency_e2e/` —— 并发 / 竞态端到端证据（t61）

> 一句话：**用真实 MySQL（`carbonboo-mysql`）+ `uvicorn --workers 2` 打真实 HTTP 并发**，把仓库里
> 「并发敏感但从来没被验证过」的四处设计（唯一键入账、同步幂等、LWW 合并、连接池上限）与两处
> HTTP 面（登录限流、并发后一致性）变成可复现的原始证据。
>
> **它不是性能压测**：不测 QPS / 延迟分位数 / 内存，只测**正确性在并发下是否仍然成立**。

---

## 1. 一条命令

```bash
bash tests/tools/concurrency_e2e/run.sh          # 全跑（约 3–5 分钟，含一次 uvicorn --workers 2 冷启动）
CONC_ONLY=s1,s5 bash tests/tools/concurrency_e2e/run.sh   # 只跑某几个场景
CONC_KEEP=1 bash tests/tools/concurrency_e2e/run.sh       # 保留 /tmp/cbconc.* 现场（取证/排错）
CONC_STRICT_CONTRACT=0 bash tests/tools/concurrency_e2e/run.sh  # 显式关掉严格模式（默认已由 run.sh 打开，见下）
```

| 退出码 | 含义 |
|---|---|
| `0` | 全部断言通过，且**门禁级发现 = 0**。契约口径类发现（`gating=False`，如 S3 封顶归属 / S1-note）只报告、不影响退出码，单列在 `REPORT.md §4` |
| `1` | 有断言失败；或存在**门禁级发现**（`blocker` / `high`） |
| `2` | 环境不可达：没有 docker / `carbonboo-mysql` 未运行 / MySQL 端口连不上 / 缺 `server/.env` 键 / 缺 `server/.venv` / 建库或灌 schema 失败 / uvicorn 起不来 |

判定口径（为什么不把「发现」算进断言）：本工具的任务是**取证**——产品契约在并发下被违反时，
按任务书「发现真缺陷写三行 STOP 只报告不改」以 `[!] 发现 …` + 三行 STOP + 原始数据呈现（`REPORT.md §4`），
不与「工具自身断言」混在一个计数里。**t66 起严格执行：`run.sh:21` 默认 `export CONC_STRICT_CONTRACT=1`**，
门禁级（`blocker` / `high`）发现会转成退出码 1；「契约口径待裁决」类显式 `gating=False`，只报告不拦
（不改口径就调 `CONC_STRICT_CONTRACT=0` 显式关闭）。

> **S2b（LWW 丢更新）是概率性探测**：修前四次跑合计 11/32 轮违反、单跑曾出现 0/8，
> 因此它**不能**单独当成回归判据；**确定性红**来自 `server/tests/test_sync.py::test_lww_concurrent_push_converges_to_max_updated_at`
> （`-k concurrent_push` 可稳定复现，口径与 `REPORT.md §8` 一致）。

`run.sh` 自己负责：建任务库 → 灌 `schema.sql` + `seed.sql` → 起 `uvicorn --workers 2` → 跑探针 →
杀进程、drop 库、删临时目录 → 打印清理自证。**中途 Ctrl-C 也会走同一个 `trap` 清理。**

---

## 2. 覆盖了什么（6 组场景 + 1 组前置）

| 场景 | 并发数 | 断言的是什么 |
|---|---|---|
| **S0** 前置 | — | MySQL 版本 / `max_connections` / 隔离级别 / 峰值连接 |
| **S1** 唯一键并发入账 | 18 | 同一 `(user_id, source_type, source_id, flow_kind)` 被 18 个并发 push 打，最终**恰好 1 行**、`SUM(points)` 不重复计分、每条响应 `skipped = ignored + rejected`、只有 1 条 `accepted=1` |
| **S2** 同步幂等 push | 16 × 2 变体 | 同一 `carbon_record` 并发推 → 只落 1 行；`offsetMs` 只在带 `clientNow` 时非 0 |
| **S2b** LWW 丢更新 | 8 轮 × 16 | 同一 `id`、`updated_at` 递增的 16 个版本并发推 → 最终行必须是**最大 `updated_at`**（`updatedAt 大者胜`在并发下守恒） |
| **S3** 积分封顶 | 8 | 同日并发入账：不丢行、不重复行；服务端**没有**封顶读-改-写路径（`point_daily_stat` 从未被写） |
| **S4** 连接池上限 | 6 轮 × 64 | 并发数 ≫ `2×(pool_size+max_overflow)` 时是否出现 5xx / `QueuePool` 超时；并给出本库并发连接峰值 |
| **S5** 限流 | 60 | 并发打 `/api/v1/auth/login` 是否真的出现 429，放行数是否 ≤ 阈值 × worker 数 |
| **S6** 并发后一致性 | — | 余额 = 收入 − 支出；`point_record` 只增不删（触发器或快照取证）；无重复 `id` |

每个断言都打印**原始证据**：逐条 HTTP 状态码 + 响应计数、`SELECT` 结果原文、`uvicorn.log` 里的错误检索。
`REPORT.md` 逐场景给「并发数 / 期望 / 实测」三元组。

---

## 3. 怎么保证它测的是「真库 + 多 worker」

* 库：`carbonboo_conc_<6 位随机>`，从 `server/sql/schema.sql` + `seed.sql` 灌（**库名只在管道里替换**，
  仓库文件一字不改）；跑完 `DROP DATABASE`，并打印 `SHOW DATABASES` 自证无遗留。
* 服务端：`server/.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port <随机> --workers 2`，
  **真的是两个 worker 进程**（日志里有两条 `Started server process`）。
* 生产库 `carbonboo` 只做**只读**快照（逐表精确 `COUNT(*)`），跑前跑后对比 → 证明工具没碰生产库。

---

## 4. 边界（硬写死，别把这里当「并发已全验证」）

1. **服务端单机多 worker ≠ 分布式**：只验证了同一台机器上 2 个 uvicorn worker + 1 个 MySQL 容器。
   **没有**验证多机部署、主从、连接池跨进程争抢、MySQL 行锁在高并发下的退化。
2. **≠ 真机端侧并发**：ArkTS 端（`relationalStore` + 多进程/多线程、`PointService` 的封顶读-改-写）
   **完全没跑**。`docs/VERIFICATION.md` 里「真机 hypium 36 个 `it()`」仍是未运行项。
3. **≠ 近场协同并发**：鸿蒙分布式协同（近场）不在本工具范围。
4. **≠ 真双设备**：本工具的「多设备」是同一批 HTTP 请求里换 `deviceId` 字段，
   与「两条真机各自离线改同一行再同步」不是一回事。
5. **≠ 性能压测**：没有 QPS / P95 / 内存 / 慢查询证据；并发数是为了触发竞态，不是为了压满。
6. **不是 L3 的替代**：`server/tests/`（237 条 pytest）是顺序执行的功能测试，本工具是它的**并发补充证据**，
   两者互不替代。

---

## 5. 已知坑（都是本工具实测踩出来的）

1. **触发器建不了**：MySQL 开了 binlog 且应用账号无 `SUPER` 时，`CREATE TRIGGER` 报
   `1419 You do not have the SUPER privilege and binary logging is enabled`。
   → 工具**不吞这个错**：打印原文，并退回「S1 后快照 → S6 复核三列逐值不变」的数据级取证。
2. **`uvicorn --workers 2` 的进程回收**：supervisor 收到 SIGTERM 会转发给 worker，但实测出现过
   supervisor 已退出、worker 仍占端口。`run.sh` 用「SIGTERM → 等 → SIGKILL → `pkill -f '--port <port>'`」四段兜底，
   收尾再自证端口 `CLOSED`、残留进程数 0。
3. **生产库快照不能用 `information_schema.TABLE_ROWS`**：那是估算值，会随统计刷新变化，导致假差异。
   必须逐表 `COUNT(*)`。
4. **`f-string` 表达式里不能出现反斜杠**（Python < 3.12）：SQL 里的 `\'` 要先取成变量再拼。
5. **端口**：`8031 / 8041 / 18099` 在本机已被其它任务占用；脚本随机挑 `18300–18700` 的空闲端口。
6. **限流是进程内计数**（`server/app/core/ratelimit.py:1-6` 自述）：2 worker 下上限 = 阈值 × 2。
   本工具按这个口径断言，不把它当全局限流。
7. **`pymysql` 会把 SQL 里的单个 `%` 当格式符**：带参数的查询里 `LIKE 'cr-cap-%'` 会抛
   `ProgrammingError: not enough arguments for format string`（实测崩过一次）。带参数时必须写 `%%`；
   无参数时**不要**传 `args`（本工具 `sql()` 已按这个规则实现）。

---

## 6. 产物与绑定

| 文件 | 内容 |
|---|---|
| `REPORT.md` | 某一次实跑的完整结果：逐场景「并发数 / 期望 / 实测」三元组 + 原始输出 + 4 条 STOP 发现 + **这次没能证明什么** |
| `/tmp/cbconc.*` | `CONC_KEEP=1` 时的现场（`uvicorn.log` / 探针日志 / pid） |

`REPORT.md` 首段写死绑定基准（现场 `git rev-parse HEAD` 的完整 40 位 SHA），并声明服务端字节在该基准上未变。

---

## 7. 文件

| 文件 | 作用 |
|---|---|
| `run.sh` | 环境检查 → 建库灌数据 → 起 `--workers 2` → 跑探针 → 清理自证（退出码 0/1/2） |
| `lib/conc_probe.py` | 六组场景的并发探针（httpx 并发 + pymysql 直查 + 断言 + 原始证据输出） |
| `REPORT.md` | 某一次实跑的完整结果：三元组、原始输出、发现（STOP）、**这次没能证明什么** |
| `README.md` | 本文件：能力 / 边界 / 复现 / 已知坑 |
