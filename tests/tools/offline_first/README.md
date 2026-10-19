# tests/tools/offline_first —— 「未登录 = 纯单机」的两段可执行证据

> 一句话：用**仓库里真实的 Service 实现**，把网络口换成陷阱，跑两段方向相反的实验 ——
> 第一段证明「断网时本机流程照常可用、且一行都不出网」，第二段证明「网只在五类例外处被碰」。
>
> 边界先说死：这是**离线执行器**（esbuild 转译 + Node 垫片），**不是真机 hypium**，也不是 L2 端侧集成；
> 它只转译 `service/ util/ data/ model/ viewmodel/` 五个目录，**`pages/` 与 `components/` 一个文件都不进**，
> 所以它证明的是 **Service 层的本机优先**，界面层（18 页）不在本工具范围内。

## 1. 它能回答什么 / 不能回答什么

| 问题 | 本工具 | 靠什么 |
|---|---|---|
| 未登录时，录入碳记录 / 科普详情 / 本地小铺购买 / 本地备份快照能不能跑通？ | ✅ 能答 | 断网陷阱下调用真实 `RecordService.save`/`ScienceService`/`ShopService.purchase`/`BackupService.create`，并回读库表 |
| 这些本机流程里有没有偷偷出网？ | ✅ 能答 | 端口层陷阱（`HttpPort`）与平台层陷阱（`@kit.NetworkKit`）双记录，任一命中即红 |
| 五个网络例外是不是「只在例外处」出网？ | ✅ 能答 | 第二段只给五个端点预置响应，打印每条请求的 method + URL + 是否带 Bearer |
| 例外不可用时会不会崩？ | ✅ 能答 | 断网段里五个例外全部返回 `ok:false` + 可读原因，之后本机录入仍可用 |
| 真机 hypium 的 36 个 `it()` 跑过没有？ | ❌ 不能答 | 本工具是 Node 里的转译执行，**不是设备**（见 §5 N1） |
| 界面层（18 页）在飞行模式下的表现？ | ❌ 不能答 | UI 目录不进转译集（见 §5 N2） |
| 两条设备之间的真实同步？ | ❌ 不能答 | 需要真机 + L2（见 §5 N3） |

## 2. 怎么跑

```bash
bash tests/tools/offline_first/run.sh                            # 两段都跑
OFFLINE_FIRST_ONLY=1 bash tests/tools/offline_first/run.sh       # 只跑第一段（断网）
OFFLINE_FIRST_ONLY=2 bash tests/tools/offline_first/run.sh       # 只跑第二段（有网）
```

退出码：`0` = 全部断言通过；`1` = 有断言失败；`2` = 环境不可达（node < 22.5 / 找不到 esbuild / 不在仓库根）。

环境要求：`node ≥ 22.5`（内置 `node:sqlite`）、`esbuild`（默认找 `~/harmony-toolchain/esbuild/bin/esbuild`，
可用 `ESBUILD=` 覆盖）、无需数据库服务、**不需要联网**（Python 也不参与）。

日志：`artifacts/run-<时间戳>.txt`（`2>&1 | tee`，与终端输出同源）。

## 3. 两段实验的设计

```
真实实现（不替换）: RecordService / ScienceService / ShopService / BackupService / PointService
                    / SyncService / AuthService / ShopPriceFetcher / ServerConfigFetcher
只替换这一个口    : HttpPort（端口只有 baseUrl() + request() 两个方法）
                    + @kit.NetworkKit（平台层陷阱，包住 l1_offline 的垫片）
```

- **端口层陷阱**（`probe.mjs` 里的 `PortTrap`）
  - `offline` 模式：任何请求 → `{status:0, body:'', error:'离线陷阱（未登录 = 纯单机）：…'}`。
    这与生产 `HttpClient` 把网络异常折成 `status:0` 的形态一致，所以调用方的降级代码路径**完全相同**。
  - `stub` 模式：只对五个例外端点返回预置响应；**其它路径依旧返回失败**（防止「其实还有别的出网」被掩盖）。
- **平台层陷阱**（`platform/networkkit_trap.cjs`）：包住 `l1_offline/platform/networkkit.cjs`，
  记录每次 `@kit.NetworkKit` 出网尝试；`throw` 模式下立刻 reject。它保留原垫片的错误文本与 `L1_ALLOW_NETWORK` 语义。
- **`L1_ALLOW_NETWORK`**：本工具**不设**这个变量（所以平台层默认拒绝出网）。
  设成 `1` 时会真的发起 TCP —— `S0.2` 就是用子进程设 `1` 去撞一个关闭端口，得到 `ERR fetch failed`，
  证明「被拦住」是陷阱干的，不是垫片坏了（**陷阱非空转**）。

## 4. 断言清单（32 条）

| 段 | 断言 | 说明 |
|---|---|---|
| S0 | S0.1 / S0.2 | 陷阱非空转：真实 `HttpClient` 被拦且保留原始错误文本；`L1_ALLOW_NETWORK=1` 时真发起 TCP |
| 一 | S1.1–S1.3 | 录入碳记录 → 因子快照四字段落库 → 余额可读 |
| 一 | S1.3a–S1.3b | 目标进度 `user_goal`（11 行、progress>0 6 条）与徽章解锁 `user_badge`（`B_FIRST` unlocked=1、unlocked_at>0）逐行落库 |
| 一 | S1.4–S1.6 | 科普列表 / 正文 / 已读进度（rawfile，无网） |
| 一 | S1.7–S1.9 | 真实补记把余额攒到可买 → 本地小铺购买 → `user_purchase` + 负向流水可回溯 |
| 一 | S1.10–S1.11 | 本地备份快照生成 + 文件落在本机 |
| 一 | S1.12–S1.13 | 端口层零违规、平台层零触碰 |
| 一 | S1.14 / S1.14b | 未登录 + 断网：只有免 token 的三处发起请求；同步/备份**连请求都不发** |
| 一 | S1.15 ×5 | 五个例外各自优雅降级（`ok:false` + 可读原因） |
| 一 | S1.16 | 例外全失败之后，本机录入仍然可用 |
| 二 | S2.1 | 有网环境下本机录入依然不需要网 |
| 二 | S2.2–S2.6 | 五个例外**各自真的发出请求**并消费响应（登录拿 token、同步带 Bearer、取价免 token 且目录被覆盖、备份 `stored=19`、配置下发让 `pointsDailyCap=180` 生效） |
| 二 | S2.7 | 第二段总共只在五个例外端点出网 |

## 5. 已知坑与边界（踩过的）

1. **`JSON.stringify(new Map())` 是 `{}`** —— 断言 `ScienceService.progressMap` 的返回值时必须按 `Map` 判（`prog.has(id)`），否则永远红。
2. **`findHit` 用 `url.indexOf(path) === 0` 会永远 false** —— 端口层记录的 URL 带 `http://127.0.0.1:8000` 前缀，必须用 `>= 0`。这条坑过一轮全红。
3. **`RecordService.save(userId, input, now)`** 是三个参数（`input` 是第二个），只传一个对象会得到 `TypeError: Cannot read properties of undefined (reading 'amount')`。
4. **`l1_offline` 的 `ResourceManager` 靠 `L1_RAW_MAIN` / `L1_RAW_TEST` 找 rawfile**：不设就会报 `rawfile 不存在：goals/goal-defs.json（已查找 0 个根）`。
5. **未登录时 `sync()`/`fullUpload()`/`fullRestore()` 有前置守卫**（`SyncService.ets:174/226/275` 第一件事判登录态）⇒ 断网段里这两类**根本不会发请求**，只会有 3 次陷阱命中。这不是缺陷，是更强的证据（`S1.14b`）。
6. **偏离的是「验证方式」，不是「被测实现」**：唯一被换掉的是 `HttpPort` 与 `@kit.NetworkKit`；任何业务逻辑都没有重写。
7. **`@kit.NetworkKit` 的说明符改写是全局的**：转译产物里所有 `@kit.NetworkKit` 都指向陷阱文件（包括反证用的变异代码），这是「第一段变红」的基础。

## 6. 反证（怎么证明这套证据不是假绿）

把本机小铺路径改成**偷偷出网一次**（往 `ShopService.purchase()` 里注入 3 行 `http.createHttp().request(...)`），
第一段必须红；用 `git show HEAD:<path>` 还原后必须绿。命令与原始输出见 `REPORT.md §4`，
两份日志留在 `artifacts/mutation-seg1-red.txt` 与 `artifacts/mutation-seg1-restored-green.txt`。
