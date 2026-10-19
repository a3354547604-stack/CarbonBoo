# t58 报告 · 「未登录 = 纯单机」两段可执行证据

分类约定（每组结论都标了来源）：
**【实跑】** = 本机亲自执行命令得到的原始输出；**【读源码】** = 读代码得出、没有运行；**【未运行】** = 没跑，且**不算通过**。

---

## §0 基准与复现

```
$ git rev-parse HEAD
f56edf6992bd33017193d53a20778ff070e070c9
$ git ls-remote origin main
f56edf6992bd33017193d53a20778ff070e070c9	refs/heads/main
$ git status --short
?? tests/tools/l2_sync/
?? tests/tools/offline_first/
```
⇒ 结论（【实跑】）：本报告的全部断言都绑定 HEAD `f56edf6992bd33017193d53a20778ff070e070c9`，且与远端同值；
工作树里只有两个**未跟踪**目录（本工具与另一个并行任务的工具），**被测源码零改动**。

复现：
```bash
bash tests/tools/offline_first/run.sh      # 32 条断言，期望 RESULT: PASS=32 FAIL=0，退出码 0
```

## §1 交付物

| 文件 | 作用 |
|---|---|
| `tests/tools/offline_first/run.sh` | 入口：环境检查（node ≥22.5 / esbuild / 仓库结构）→ 跑探针 → 传退出码（0/1/2） |
| `tests/tools/offline_first/probe.mjs` | 两段实验本体：转译 → 启动地基 → 陷阱 → S0/S1/S2 断言 |
| `tests/tools/offline_first/platform/networkkit_trap.cjs` | `@kit.NetworkKit` 平台层陷阱（包住 `l1_offline` 垫片，保留原始错误文本） |
| `tests/tools/offline_first/README.md` | 能力/边界/复现/已知坑 |
| `tests/tools/offline_first/artifacts/*.txt` | 本轮实跑与反证的原始日志 |

**零新增依赖**：只用 `node:` 内置模块 + 仓库已有的 esbuild（与 `l1_offline` 同一个二进制）。Python 不参与，也不需要数据库服务。

## §2 实跑记录

### §2.1 环境与转译【实跑】

```
$ bash tests/tools/offline_first/run.sh
── 未登录 = 纯单机（offline_first） ──
仓库根 : /mnt/c/Users/Administrator/Desktop/CarbonBoo
模式   : OFFLINE_FIRST_ONLY=all
node   : v22.22.1（/usr/bin/node）
[ENV] node=v22.22.1 平台=linux L1_ALLOW_NETWORK=（未设）
[ENV] 转译完成：65 个 .ets → CJS（只含 service/util/data/model/viewmodel）
[ENV] 启动地基：goals=11 badges=8 shop=9 science=12 factors=CF-2026.2
```

### §2.2 S0 陷阱非空转自证【实跑】

```
[TRAP-PLATFORM] @kit.NetworkKit 出网尝试：GET http://127.0.0.1:59998/self-proof
PASS S0.1 真实 HttpClient 被平台层陷阱拦住，且保留 l1_offline 的原始错误文本 —— status=0 error=离线执行（L1）不出网：拦截了对 http://127.0.0.1:59998/self-proof 的请求。L1 里网络必须由用例注入的假实现承担；若确需真网络，显式设 L1_ALLOW_NETWORK=1（这已不属于 L1 的范畴）。
PASS S0.2 逃生舱存在：L1_ALLOW_NETWORK=1 时真的发起 TCP（ECONNREFUSED），说明「被拦」是陷阱而非垫片损坏 —— ERR fetch failed
```
⇒ 结论：平台层陷阱**真的在拦**（`HttpClient` 走的就是它），且 `L1_ALLOW_NETWORK=1` 时确实会发起 TCP —— 所以后面的「零出网」不是垫片坏掉的假绿。

### §2.3 第一段：断网陷阱下跑通本机流程【实跑】

`ServiceHub.init(context, now, { http: new PortTrap('offline'), files: new MemoryFiles() })`，
请求一律 `status:0`（等价断网）。全部 16 条断言的原样输出（`artifacts/run-*.txt`）：

```
PASS S1.1 录入碳记录（RecordService.save：真实计算 → 落库 → 积分 → 目标/徽章） —— ok=true
PASS S1.2 因子快照四字段随记录落库（铁律 3：永不回写） —— factor_value=0.192 version=CF-2026.2 source=SRC-DERIVED confidence=provisional
PASS S1.3 记录入账后可读到余额（PointService.balance） —— 余额=116
PASS S1.3a 目标进度随录入落库（user_goal 有行，且至少一条 progress > 0） —— user_goal=11 行；progress>0 6 条：L1=1,M1=5,M2=0.96,M5=0.96,S1=1,S5=1
PASS S1.3b 徽章解锁落库（user_badge.unlocked=1 且 unlocked_at>0，铁律 4 可追溯） —— user_badge=8 行；B_FIRST=unlocked=1 unlocked_at=1792380000000
PASS S1.4 科普列表（ScienceService.list，读 rawfile 索引） —— 12 篇
PASS S1.5 科普正文（ScienceService.body → rawfile） —— id=sci-01 正文 331 字符
PASS S1.6 已读进度落库（markProgress → progressMap） —— progressMap=Map(1) {sci-01=…}
PASS S1.7 用真实补记路径把余额攒到可买（30 天补记窗口内） —— 余额=116 最便宜商品=theme_default/0 补记 0 天
PASS S1.8 本地小铺购买（ShopService.purchase：user_purchase + 负向流水，全程无网） —— ok=true
PASS S1.9 购买留痕可回溯（user_purchase 一行 + point_record 一条负向流水） —— user_purchase=1 条，purchase 流水=1 条（points=-0）
PASS S1.10 本地备份快照（BackupService.create：只写本机文件，不联网） —— ok=true name=carbonboo-backup-*.json
PASS S1.11 备份文件确实落在本机（FilesPort.list("backup")） —— 1 份：carbonboo-backup-*.json
PASS S1.12 第一段本机流程零出网（端口层陷阱零违规） —— 违规 0 次
PASS S1.13 第一段平台层（@kit.NetworkKit）零触碰 —— 平台层命中 0 次
PASS S1.14 断网 + 未登录：只有免 token 的三处真的发起请求（登录/注册、商品取价、配置下发） ——
      命中 3 次：POST http://127.0.0.1:8000/api/v1/auth/register | GET http://127.0.0.1:8000/api/v1/shop/items | GET http://127.0.0.1:8000/api/v1/config
PASS S1.14b 未登录时「多设备同步」「云端备份」连请求都不发（NOT_LOGGED_IN 前置守卫，铁律 1 的更严形态） ——
      sync.code=NOT_LOGGED_IN fullUpload.code=NOT_LOGGED_IN sync 相关请求=0 次
PASS S1.15 登录/注册：断网时优雅降级 —— POST /api/v1/auth/register → ok=false code=AUTH_FAILED
      reason={"ok":false,"code":"AUTH_FAILED","message":"离线陷阱（未登录 = 纯单机）：拦截 POST http://127.0.0.1:8000/api/v1/auth/register，本机流程不得出网"}
PASS S1.15 多设备同步：断网时优雅降级 —— ok=false code=NOT_LOGGED_IN message=未登录，未发起任何上传（本机数据不受影响）
PASS S1.15 商品取价：断网时优雅降级 —— ok=false code=SHOP_FETCH_HTTP message=取价失败（HTTP 0），整份丢弃，保留上一份目录
PASS S1.15 云端备份：断网时优雅降级 —— ok=false code=NOT_LOGGED_IN message=未登录，未发起任何上传
PASS S1.15 配置下发：断网时优雅降级 —— ok=false code=CONFIG_FETCH_HTTP message=配置拉取失败（HTTP 0），整份丢弃，保留上一份配置
PASS S1.16 例外全部失败之后，本机录入仍然可用（可用性不依赖网络） —— ok=true 余额=174
```

⇒ 结论（【实跑】）：
1. 断网 + 未登录下，**录入 / 科普 / 本地小铺 / 本地备份四类功能全部跑通**，且**零出网**（端口层 0 违规、平台层 0 触碰）；
2. 未登录时**连允许联网的例外都不发起**（同步/备份在 `SyncService.ets:174/226/275` 的前置守卫处直接返回 `NOT_LOGGED_IN`，请求数 0）；
3. 例外真的失败时全是 `ok:false` + 人话原因，**没有未捕获异常**；失败之后本机录入照常可用。

### §2.4 第二段：只在这五处出网【实跑】

`PortTrap('stub')` 只对五个端点预置响应；其它路径依旧失败。

```
PASS S2.1 有网环境下本机录入依然不需要网 —— ok=true 此前出网 0 次
[TRAP-PORT] POST http://127.0.0.1:8000/api/v1/auth/register（body=46B，无 token）
PASS S2.2 登录/注册发出 POST /api/v1/auth/register 并消费响应（拿到 token） —— ok=true
      outcome={"userId":"acc-of-e2e-1","username":"of_e2e_1","token":"tok-of-e2e-1","migrated":2}
[TRAP-PORT] POST http://127.0.0.1:8000/api/v1/sync/push（body=7316B，Bearer 12 字符）
[TRAP-PORT] GET  http://127.0.0.1:8000/api/v1/sync/pull?since=0（body=0B，Bearer 12 字符）
PASS S2.3 多设备同步发出 POST /api/v1/sync/push 并消费响应（带 Bearer） —— ok=true
[TRAP-PORT] GET http://127.0.0.1:8000/api/v1/shop/items（body=0B，无 token）
PASS S2.4 商品取价发出 GET /api/v1/shop/items（免 token）并整份覆盖目录 —— ok=true catalog(frame_01)=1200
[TRAP-PORT] POST http://127.0.0.1:8000/api/v1/sync/backup（body=16694B，Bearer 12 字符）
PASS S2.5 云端备份发出 POST /api/v1/sync/backup 并消费响应（stored>0，带 Bearer） —— ok=true stored=19
[TRAP-PORT] GET http://127.0.0.1:8000/api/v1/config（body=0B，无 token）
PASS S2.6 配置下发发出 GET /api/v1/config（免 token）并让封顶真的生效 ——
      ok=true effective.pointsDailyCap=180 badgesEnabled=true
PASS S2.7 第二段总共只在五个例外端点出网（其余路径即便有请求也会被拒） ——
      出网 6 次：POST …/auth/register | POST …/sync/push | GET …/sync/pull?since=0 | GET …/shop/items | POST …/sync/backup | GET …/config
```

⇒ 结论（【实跑】）：
- 五个例外**各自真的发出请求**，URL 与方法见上（同步是 push + pull 两跳，故第二段共 6 条请求 = 5 类端点）；
- 响应被**真正消费**，不是「发了就算」：登录拿到 `token`、取价把 `catalog(frame_01)` 覆盖成 1200、
  配置下发让 `effectiveFrom(store).pointsDailyCap = 180`、备份算出 `stored=19`；
- 带不带 Bearer 的边界与文档一致：登录/注册、同步、备份带 token；取价与配置下发**免 token**。

### §2.5 汇总【实跑】

```
[ENV] 转译 65 个文件；断言 32 条
RESULT: PASS=32 FAIL=0
退出码 : 0（0=全过 / 1=有失败 / 2=环境）
```
本轮共跑 6 次：前 4 次红（原因全是**工具自身的缺陷**：`findHit` 子串判定写成 `=== 0`、`Map` 的 `JSON.stringify` 是 `{}`、`RecordService.save` 少传 `userId`、缺 `L1_RAW_MAIN`/`L1_RAW_TEST`、`AuthOutcome` 字段名取错、`sync/pull` 未预置响应），第 5 次起 30/30 稳定全绿；第 6 次是变异反证（见 §4）。

## §3 静态验证（读源码得出，未运行）

以下事实用于解释上面的观测，**不作为「已运行」证据**：

1. 未登录守卫在 `app/entry/src/main/ets/viewmodel/net/SyncService.ets:174`（`sync`）、`:226`（`fullUpload`）、`:275`（`fullRestore`），
   三处第一件事就是判登录态并 `return fail('NOT_LOGGED_IN', …)`（`:176` / `:228` / `:277`），**早于任何 `http.request`**。
2. 五个例外的实现入口：`AuthService.ets:232`（`register`）/ `:219`（`login`）、`SyncService.ets:174`（`sync`）、
   `net/ShopPriceFetcher.ets:111`（`fetchAndStore`）、`SyncService.ets:226`（`fullUpload`）、`net/ServerConfigFetcher.ets:103`（`fetchAndStore`）。
3. `HttpPort` 只有两个方法（`baseUrl()` + `request()`），所以陷阱类实现两个方法即完整替换，**不需要改任何调用方**。
4. `MemoryFiles`（`viewmodel/store/FilesPort.ets`）是本机文件口的既有内存实现，用它是为了不落盘、可重复；**不是**对 `FilesPort` 语义的改写。

## §4 反证：让本机路径偷偷出网 → 第一段必须红【实跑】

变异（唯一一次改动被测源码，且**同一条命令内还原**）：在 `app/entry/src/main/ets/viewmodel/ShopService.ets`
的 `purchase()` 里插入 3 行平台层出网（`http.createHttp().request('http://127.0.0.1:59999/mutation-proof')`）。

```
$ OFFLINE_FIRST_ONLY=1 bash tests/tools/offline_first/run.sh   # 变异态
[TRAP-PLATFORM] @kit.NetworkKit 出网尝试：GET http://127.0.0.1:59999/mutation-proof
FAIL S1.8 本地小铺购买（ShopService.purchase：user_purchase + 负向流水，全程无网） ——
     ok=false message=抛异常：离线陷阱（本机流程不得出网）：拦截了对 http://127.0.0.1:59999/mutation-proof 的平台层请求。…
FAIL S1.9 购买留痕可回溯（user_purchase 一行 + point_record 一条负向流水）
FAIL S1.13 第一段平台层（@kit.NetworkKit）零触碰 —— 平台层命中 1 次
RESULT: PASS=20 FAIL=3
退出码 : 1
$ git show HEAD:app/entry/src/main/ets/viewmodel/ShopService.ets > app/entry/src/main/ets/viewmodel/ShopService.ets
RESTORE_CMP_IDENTICAL
$ OFFLINE_FIRST_ONLY=1 bash tests/tools/offline_first/run.sh   # 还原态
RESULT: PASS=23 FAIL=0
退出码 : 0
$ sha256sum app/entry/src/main/ets/viewmodel/ShopService.ets
05329be9b1bb710128ac86c902a5ce40575a67edcf4eed203c15d67c2aba9302   （与变异前逐字节相同）
```
日志：`artifacts/mutation-seg1-red.txt`（红）与 `artifacts/mutation-seg1-restored-green.txt`（绿）。

⇒ 结论（【实跑】）：**第一段的绿不是假绿** —— 一旦本机路径碰了网，断言立刻红且失败信息里带着那条 URL；
还原后逐字节相同（`cmp` 一致）且重新全绿。变异未使用 `stash` / `clean` / `checkout --` / `reset`。

## §5 未运行 / 不在本工具范围（**一条都不算通过**）

| 编号 | 项 | 状态 | 原因 / 原始依据 |
|---|---|---|---|
| N1 | 真机 hypium 的 10 个套件 / 36 个 `it()` | **未运行** | 本机无真机、无模拟器：`hdc` 不在 PATH（`command -v hdc` 空）、SDK 内 hdc 直调 `Connect server failed`、`/dev/kvm` 不可写、`command -v emulator` 无。本工具是 Node 里的转译执行，**不能替代设备执行** |
| N2 | 界面层（18 页 / 23 组件）在飞行模式下的表现 | **不在本工具范围** | `pages/` 与 `components/` 含 ArkUI `struct`/装饰器，esbuild 不转译、也**故意**不进转译集（`MAIN_LOGIC_DIRS` 只有五个逻辑目录）。本工具证明的是 Service 层 |
| N3 | L2 端侧集成（两条设备跑协同脚本） | **未运行** | 同上，需要两台设备（真机 + 模拟器）；另有并行任务 `tests/tools/l2_sync/` 在做，本报告不代它背书 |
| N4 | 与真实服务端联调（真 HTTP 200/401/403、真实 MySQL） | **未运行** | 本工具全程不出网、不用数据库（`node:sqlite` 内存/临时文件）。服务端行为由 `server/tests` 的 L3 与 `/admin` E2E 分别覆盖 |
| N5 | 并发/多账号/多设备同时操作的竞态 | **未运行** | 单进程单库串行执行，不构造并发 |

另外两条**必须说清**的口径：
- 「第一段跑通」= **Service 层在断网陷阱下跑通**，不等于「App 在飞行模式下点得动」（N2）；
- 「第二段 6 条请求」= 五个例外端点的**方法/URL/是否带 Bearer** 与文档一致，**不等于**这些端点真的返回了这些数据（响应是预置的，真实端点在 N4 里）。

## §6 结论

| 结论 | 依据 |
|---|---|
| 未登录 + 断网：录入 / 科普 / 本地小铺 / 本地备份**全部可用** | §2.3 S1.1–S1.11【实跑】 |
| 这些本机流程**零出网**（端口层 + 平台层双零） | §2.3 S1.12–S1.13【实跑】 |
| 未登录时**连例外都不发起**（同步/备份请求数 0） | §2.3 S1.14b【实跑】+ §3.1【读源码】 |
| 五个例外**只在例外处**出网，且响应被真正消费 | §2.4 S2.2–S2.7【实跑】 |
| 例外失败只降级、不崩，且之后本机功能照常 | §2.3 S1.15–S1.16【实跑】 |
| 第一段的绿不是假绿（本机路径一碰网就红） | §4 变异反证【实跑】 |
| 真机 / 界面层 / L2 / 真实服务端 / 并发 | **未运行，不算通过**（§5） |
