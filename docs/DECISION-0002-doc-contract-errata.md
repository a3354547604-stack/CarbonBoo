# DECISION-0002 · v4.2 文档契约勘误（决策记录）

> 本文件是 `AGENTS.md §10` ① 要求的「修改本文件必须留下决策记录」的落点，记录 **v4.2（2026-11-06）**
> 这一轮文档勘误的**依据、取舍与影响面**。变更逐条清单在 [`CHANGELOG.md`](./CHANGELOG.md) 的 v4.2 章节；
> 机器可读登记在 `tests/cases/carbon-calc.json → docConflicts` 的 B40–B45。
> 本文件**不重复**规格正文（唯一来源：`PLAN.md` / `APPENDIX-*`）。

- **状态**：已生效（2026-11-06）
- **触发**：三部分实现落地后（`app/` t2+t4、`server/` t3+t5、`/admin` t6），发现文档契约与
  「已实现并已验证的正确口径」分叉；`server/README.md §9.1` 给出带行号的清单，队长实测补两处 + 一处遗漏。
- **原则**：**以已实现并已验证的口径为准收敛文档**（文档是基线，不是实现要迁就的对象）；
  **不改任何实现代码**；不改检查器、不放宽断言；数值改动同次提交同步基准。

## 决策

| # | 决策 | 理由（为什么不是另一种） | 影响面 |
|---|---|---|---|
| D1 | `uq_pr_source` 改为 **`(user_id, source_type, source_id, flow_kind)`** | `source_id` 的取值口径（`<goalId>:<periodKey>` / `<shop_item.id>`）**不含账号维度**；本机 `local-guest`/`demo-user`/账号并存、服务端多账号共库时，缺 `user_id` 会让两个账号同日同名目标互相顶掉、**后入账者丢积分**。服务端 `sql/schema.sql` + `migrations/001_*` 与客户端 `ClientSchema.ets` 早已按含 `user_id` 实现并验证 | `APPENDIX-B §2` 建表 SQL 与幂等注释、`PLAN §9.5` 第 2/3 条、两处变更索引；B40 |
| D2 | 同步契约**以服务端已实现并已有守门用例的口径**为准补齐 | `t5` 的 `test_sync.py`/`test_backup.py` 已钉住行为：备份是**独立三端点**（`POST/GET /sync/backup`、`POST /sync/backup/restore`，恢复即覆盖 + `preRestore`）、`clientNow` 可选、`ignored != conflicts`、忽略远端购买行不产生流水、`user_profile` 按 `user_id` 收敛一行 | `APPENDIX-B §5.2/§5.3/§6.3/§6.4/§6.5`、`APPENDIX-D D5-12`；B41 |
| D3 | 演示数据规格**以 §9.1 汇总口径为唯一求和来源**，取 **累计 61.7400 kg / 余额 4,820–4,919** | 原 §9 的"典型值"列（骑行 5 km = 0.9600）与「260 条 / 90 天 / 60–90 kg / 4000–6000 分」数学上互斥；`DemoService` 已把每条量按「日均 ≈0.7 kg」缩放并保住功能约束（< 100 kg 不触发 `B_TOTAL_100`、余额靠收尾兑换收敛）。**选 61.74 而不是原 §10.3 的 76.38**：76.38 那组取自旧典型值，且其"光盘 0.4 kg"只相当于 1 餐，与 §9 表不同源 | `APPENDIX-D §9/§9.1/§10.3`、`APPENDIX-C §3.4`；B44 |
| D4 | 设计令牌落盘路径以仓库实际为准：**`app/entry/src/main/ets/util/AppTheme.ets`** | 实测 `find … -name 'AppTheme.ets'` 只有 `util/` 一处，`app/entry/src/main/ets/` 下**没有** `common/` 目录；`LiteralConstants` 是同一文件里的类，不存在独立文件 | `APPENDIX-C §3/§25`；B43 |
| D5 | `AGENTS.md §6` 未登录例外集补齐为**四类**，头部状态行改为**写实进度** | 铁律 1 / §5 L2 / 附录 D §1.6 都是四项（含「云端备份」），§6 只列三项属 B21 漏网；状态行仍写"暂不编码 / `app/`、`server/` 尚未创建"会让后续 agent 误判仓库现状 | `AGENTS.md §6`、头部状态行、`docs/README.md` 当前阶段；B42/B45 |

## 未决 / 不在本决策范围

- **app 侧云端备份路径**：`SyncService.fullUpload()/fullRestore()` 仍走 `push` / `pull?since=0`（LWW 合并），
  与 D2 的"独立三端点、恢复即覆盖"不同——**属实现改动**（已另建 t13），本文档侧只把契约写实，不动 `app/**`。
- **服务端单例表合并**：`_merge_lww` 对 `user_profile` / `user_appearance` 在"`id` 不同、`user_id` 相同"时
  直接保留云端行并回写 `merged`（不比较 `updated_at`）；文档已按"按 `user_id` 收敛到一行、`id` 取胜者的"写。
  若要严格"按 `updated_at` 取新再收敛"，需 server 侧确认——**文档不替实现做决定**。
- **演示数据实测总量**：`DemoService` 的播种报告（真机）可能落在 ≈56–63 kg 区间；§9.1 的 61.7400 是**规格目标值**
  （可复算），实测偏差记在播种报告里，不回写文档。

## 变更记录

| 日期 | 决策 | 依据 |
|---|---|---|
| 2026-11-06 | D1–D5 全部生效；`AGENTS.md §10` 本表新增 v4.2 一行 | 队长复核 + t5/t9 实现反馈 + `server/README.md §9.1` |
