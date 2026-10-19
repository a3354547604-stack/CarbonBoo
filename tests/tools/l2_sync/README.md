# tests/tools/l2_sync —— 「L2 双设备协同」协议级端到端验证

`docs/VERIFICATION.md` 的未运行项里长期列着「L2 双设备协同」。真机 L2（两条真机跑协同脚本）在本机
**物理不可达**（无 hdc、无模拟器、`/dev/kvm` 不可写）。但附录 B §6.4-6 那条**协议级**判定
（「两端用同一规则、结论一致」）可以在本机真跑——本目录就是把它跑成可复现证据的夹具。

```bash
bash tests/tools/l2_sync/run.sh        # 退出码 0=全过 / 1=有失败 / 2=环境不可达
```

## 1. 它验什么、不验什么

**验**（八项，逐条都有断言 + 原始输出，详见 [REPORT.md](REPORT.md)）：

| # | 断言 | 关键点 |
|---|---|---|
| 1 | 基线往返 | A 真录入 → push → **另一个**库/另一个 deviceId 的 B pull → 逐列相同（含四字段因子快照） |
| 2 | LWW 收敛 | 两端离线各改成一版 → 依次 push/pull → **两库最终行逐列完全相同**，胜者 = `updatedAt` 大者 |
| 3 | 平局按 `deviceId` | `updated_at` 完全相等、deviceId 字典序不同 ⇒ **大者胜且两端一致** |
| 4 | 时钟偏移取反 | `clientOffsetMs = -respOffsetMs` 两向对照；超 ±300000ms 告警但继续合并 |
| 5 | 幂等 | 同一批连推两次 ⇒ 不产生重复行；`skipped = ignored + rejected` 三数自洽 |
| 6 | 软删除传播 | A 删 → B pull ⇒ `is_deleted=1` 且**行仍在表里**（不物理删） |
| 7 | 冲突计数口径 | `ignored` 不计入 `conflicts`（附录 B §6.4-3） |
| 8 | 反证不是假绿 | 不设 `L1_ALLOW_NETWORK` 时出网被拒（贴原始错误）+ 变异自证 |

> **t62 修订**：t57 首次跑这套夹具时报出客户端 pull 合并的三个缺陷（F1 首同步撞唯一索引 / F2 偏移取反不可达 / F3 两端编辑撞 `uq_pr_source`）。
> t62 把它们修在 `SyncService.ets` 里之后，本夹具**同一个 run.sh** 多出三条「修复现场」断言（`#8.3`/`#8.4`，以及 `#0.2` 改成「首同步就必须成功」），
> 并把第 3 项的平局输入改成**逐毫秒确定**的构造（见 §4.5）。断言只增不减；变异自证仍是同一处比较规则（`remoteDevice > localDevice`）。

**不验**（本任务**不能替代真机 L2**）：

- 界面（`pages/`、`components/` 全是 ArkUI `struct`，esbuild 不转译，也不该转译）
- Ability 生命周期、进程被杀/后台恢复、端侧权限（`WRITE_IMAGEVIDEO` 等）、系统时间/时区真实行为
- 鸿蒙近场/分布式通路（`discover()`/`nearFieldSync()` 的真机行为）
- 真机 `relationalStore` 实现细节（本夹具用的是 l1_offline 的 `arkdata.cjs`，以 `node:sqlite` 真引擎顶替）

## 2. 目录职责

| 文件 | 职责 |
|---|---|
| `run.sh` | 编排：环境检查 → 建任务专用库 → 起真服务端 → 构建 → 跑主用例 → **变异自证** → 收工清理；给退出码 |
| `lib/build.mjs` | 把 `app/entry/src/main/ets/{service,util,data,model,viewmodel}` 的 `.ets` **原样复制**（逐文件 sha256 校验）到构建目录，再用 esbuild 转译成 CJS；重写平台说明符指向垫片；支持 `--mutate=tie-flip`（只改**构建目录里的副本**）与 `--skip-copy`（原处重转译，用于「git show 还原后必须变绿」） |
| `lib/device.mjs` | **一台设备的一个动作**（一个 OS 进程 = 一台设备）：`boot/save_record/edit_record/remove_record/insert_raw/set_row/set_config/mark_pending/sync/status/dump/egress`；每次调都走真实客户端实现 |
| `lib/l2_run.mjs` | 用例驱动：编排两台设备的动作、直连 HTTP 探针、独立读两个 `node:sqlite` 库文件、直查服务端 MySQL，逐条断言并打印原始请求/响应 |
| `lib/proxy.mjs` | **协议补全代理**（独立进程）：把同一轮 push 的 `offsetMs` 补进紧随的 pull 响应，好让「客户端取反换算」这条契约可被端到端验证；`forceOffsetMs=0` 时也用于第 3 项（让「平局」这个输入逐毫秒成立）。数据面完全来自真服务端，只补这一个字段 |
| `REPORT.md` | 逐条实测命令 + 原始输出 + 结论 + 覆盖边界 + 发现的缺陷（含 STOP） |

## 3. 前置依赖（本机既有资产，本夹具**不安装任何东西**）

- **Node ≥ 22.5**（要 `node:sqlite`；本机 `/usr/bin/node` 是 22.22.1）
- **esbuild**：`~/harmony-toolchain/esbuild/bin/esbuild`（0.28.2）；**禁止 `npm install`**
- **docker** 与项目 MySQL 容器 `carbonboo-mysql`（`127.0.0.1:13307`）——**只建/用一个任务专属库**，不碰共享库与别人的库
- **`server/.venv/bin/uvicorn`** 与 `server/.env`（JWT 密钥、MySQL 口令都从 `server/.env` 读，不回显）

缺任一项 ⇒ 退出码 **2**（环境不可达），不会伪装成"通过"。

## 4. 工作机制（为什么这样可信）

1. **不重写实现**：`build.mjs` 复制的是仓库里**真实生产源文件**（逐个 sha256 比对），只做「`.ets` → CJS」转译与平台说明符重写；`SyncService.ets` 的仓库 sha256 与构建副本 sha256 都打印出来。
2. **两个真的客户端**：两台设备是**两个独立 OS 进程**，各有自己的 `L1_DATABASE_DIR`（`node:sqlite` 真 SQLite 引擎落成两个不同的库文件）、自己的 `deviceId`；同一账号在**真服务端**登录拿 JWT。
3. **真 HTTP、真服务端**：`HttpClient`（`viewmodel/net/HttpPort.ets`，唯一 HTTP 出口）走 `L1_ALLOW_NETWORK=1` 下的真 `fetch` 打到真 uvicorn；服务端数据面用真 MySQL。
4. **独立判据**：断言不只看客户端返回，而是**独立**读两个库文件（`node:sqlite`）+ 直查服务端 MySQL + 保留每个请求/响应的原始文本（`L2_WIRE_LOG`）。
5. **反证**：① 不设 `L1_ALLOW_NETWORK` 时垫片必须拒绝出网（贴原始错误）；② 把客户端平局判据 `remoteDevice > localDevice` 临时反转为 `<`，主用例必须**变红**，再用 `git show HEAD:<path>` 还原（`cmp` 逐字节校验后**原处重转译**）必须**变绿**。禁止用备份文件还原。

### 4.5 第 3 项（平局）的输入为什么要「构造」

平局要成立，客户端比较的两个值是 `remoteRaw + clientOffsetMs` 与 `localUpdated`，而 `clientOffsetMs` 来自**握手腿的实时测量**
（`offsetMs = 服务端 started_at − 客户端 clientNow`，含请求往返的几毫秒抖动）。用标称 Δ 摆出来的平局实际会差几毫秒
（t62 首跑实测差 57ms），断言因此**假红**。现在的构造是确定的：

1. 服务端那一版与本机那一版的 raw `updated_at` **完全相等**（这才是真的平局输入）；
2. 两端各自把本机时钟**调快** 5 分钟 ⇒ 服务端握手腿 `offsetMs ≈ −300000` ⇒ 本机上行被判「比服务端旧」而 `rejected`，
   服务端那一版**不被覆盖**（push 与 pull 共用同一个 `since` 锚点，故本机行必然会被 push —— 这是必要的抵消手段）；
3. `baseUrl` 指向 `lib/proxy.mjs`（`forceOffsetMs=0`）⇒ `clientOffsetMs = -0 = 0` ⇒ 客户端按裸 raw 比较 ⇒ 逐毫秒相等 ⇒ 命中平局分支。

`device_id` 比较与被测分支全部是真实代码；代理只补这一个字段，数据面仍全部来自真服务端。

## 5. 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `L2_PORT` | 自动挑空闲端口 | 真服务端端口 |
| `L2_DB` | `carbonboo_l2_e2e` | 任务专用库名（跑完删除） |
| `L2_MYSQL_CONTAINER` | `carbonboo-mysql` | 项目 MySQL 容器 |
| `L2_USERNAME` / `L2_PASSWORD` | `l2dev_<时间戳>` / `l2-pass-123` | 客户端 `AuthService.validate` 要求用户名 4–20 位 `[A-Za-z0-9_]`、口令 6–32 位 |
| `L2_TIME_BASE` | 自动 | 行时间戳基准（默认"未来 7 天"，保证恒大于 `lastSyncAt` 锚点） |
| `L2_ONLY` | `all` | 只跑某一组：`baseline,lww,tie,idem,delete,conflict-count,clock,negative` |
| `L2_WIRE_LOG` | 不写 | 落盘每个请求/响应的**原始文本**（排障与取证用） |
| `L2_CLOCK_OFFSET_MS` | `0` | 让该设备进程的 `Date.now()` 偏移 N 毫秒（用于第 4 项的"设备时钟不准"，**不是**打桩实现） |
| `L2_KEEP_OUT` | 不设 | 设了就先把原始输出留档到该目录再清理；**默认收工即删**（构建产物、两台设备的库、wire 日志都在 `mktemp -d` 的临时目录里） |

（`lib/l2_run.mjs` 还可通过 `L2_REPO`/`L2_BUILD`/`L2_ROOTS`/`L2_BASE_URL` 指向自己准备的构建与设备目录，便于单独调试某一项。）

`run.sh` 收工时会：停自己起的 uvicorn → 删任务专用库 → 删临时目录 → 打印退出码。
（`carbonboo-mysql` 容器是共享的，**不停**。）

## 6. 与第 8 项有关的两个反证

- 出网拦截：`L1_ALLOW_NETWORK` 未设置时，垫片对任何请求回
  `离线执行（L1）不出网：拦截了对 … 的请求。…`；注意客户端 `HttpClient` 会把平台异常收敛成
  `{status:0, error}`（`HttpPort.ets:99-107`），所以"被拦截"要**从响应看**而不是从异常看。
- 变异自证：见 `run.sh` 第 6 段输出（三趟：正常 → 变异必红 → `git show` 还原 + `--skip-copy` 原处重转译必绿）。

## 7. 发现与修复

- **t57（只报告）**：夹具首次跑出 F1（blocker：新设备首同步撞 `uq_ua`/`uq_uprofile`）、F2（high：pull 响应无 `offsetMs` ⇒ 取反换算不可达）、
  F3（medium：两端都真实编辑 ⇒ 下一次 pull 撞 `uq_pr_source`），按 AGENTS.md §1.3 给了 STOP 三行；原始栈与触发条件见 [REPORT.md](REPORT.md)。
- **t62（修复 + 现场断言）**：三个缺陷修在 `app/entry/src/main/ets/viewmodel/net/SyncService.ets`（`RowClaim` 三级认领 / `INSERT OR IGNORE` / 偏移取反取自 **push 响应**），
  夹具里的 `#8.3`/`#8.4`/`#0.2` 就是修复现场的断言（修复前必红、修复后必绿）。
- **仍待处理（不在 t62 inScope）**：`server/**` 侧「比较用换算值、落库用原始值」的基准分裂（`sync_service.py` 的 `_apply_update`），
  以及 `skipped` 一词两端不同义（客户端 = pull 侧保留本机行数；服务端 = `ignored + rejected`）。
- 本目录自身的写入范围只有 `tests/tools/l2_sync/`；`server/**` 全程只读，`app/**` 的改动只发生在 t62 的修复任务里（见提交信息）。

## 8. 四段门禁与成对自证（t62）

| 门禁 | 命令 | 实测 |
|---|---|---|
| L1 单测 | `bash tests/tools/l1_offline/run_tests.sh` | `RESULT: it_executed=41 passed=41 failed=0`（含 t62 新增的 LwwMerge ⑪–⑮）|
| L1 纯逻辑 | `bash tests/tools/l1_offline/run.sh` | `RESULT: PASS=55 FAIL=0` |
| L2 协议级 | `bash tests/tools/l2_sync/run.sh` | 主用例 `checks=35 passed=35 failed=0`；变异趟 `4/7`（`#3.1 #3.2 #3.3` 红）；`git show` 还原趟 `7/7`；退出码 0 |
| 文档基准 | `python3 tests/tools/check_l0.py --strict` | 退出码 0 |
| 编译成对自证 | `cd app && hvigorw --no-daemon assembleHap` | 基线 BUILD SUCCESSFUL → 注入未定义引用 ⇒ **BUILD FAILED**（`SyncService.ets:238`）→ `git show` 还原（sha256 一致）⇒ BUILD SUCCESSFUL |

> 真机 hypium 执行数在本机是 **0**（无 hdc / 无模拟器 / `/dev/kvm` 不可写）：L1 的 41 条是**离线转译后在 Node 里跑**的，
> 不等于真机通过；端侧真机 L2 同样未运行。这两项在 [REPORT.md](REPORT.md) §6 单列。

## 9. t68 追加：跨端时间戳基准与**严格基准断言**（无容差）

- **断言形态**：`basisOf(row, offsetMs) = updated_at + offsetMs` 表示「把该端存储值换算到**服务端基准**」。
  跨端一致性断的是 **`basisOf(A行, 该端当次 offsetMs) === basisOf(B行, 该端当次 offsetMs)`**，并要求逐字节等于
  服务端那一份 —— **不再用「两端差值 ≤3s」的容差**。理由：容差会把 1000ms 级的符号/倍率错误吃成绿，
  而这里根本不需要容差（同一次 `sync` 调用的 push 与 pull 用的是同一个 `offsetMs`，换算可精确逆回）。
- **只有换算不参与的比较**（本机自写行 vs 自己的目标值）才用 ±3s 抖动容差，并在断言标题里写明理由（见 `#4.9`）。
- **反证 C（必跑）**：`node lib/build.mjs <repo> <dir> --mutate=offset-1000` 把客户端落库换算多 1000ms ⇒
  `L2_ONLY=baseline,lww,delete,clock` 必须 **红**（实测 `16/24`，红的恰是 `#1.2 #1.3 #1.4 #2.2 #2.3 #2.4 #6.3 #4.9` 八条严格断言）；
  `git show HEAD:app/entry/src/main/ets/viewmodel/net/SyncService.ets > <dir>/src/main/ets/viewmodel/net/SyncService.ets`
  + `cmp` + `--skip-copy` 重转译 ⇒ 必须 **绿**（`24/24`）。`run.sh` 的第 6b 段会自动跑这一腿。
- **`#4.10`**：服务端库内 `updated_at` 必须**逐字节等于** `raw + offset_ms`（§5.3:1095；改前服务端存客户端裸值，t68 修复）。
- **t68 主用例规模**：38 条断言（t62 的 35 条 + `#4.8`/`#4.9`/`#4.10`）。

## 10. t73 追加：`#4.9` / `#5.1` 的判据语义（修过假红之后）

- **`#4.9`（时钟往返不漂移）** 现在是五条互不重叠的判据，全部**无容差**（除 ④ 这一个上界）：
  ① 逐轮严格等式 `本机值 + 该轮 offsetMs === 服务端值`（原 `noAccum9` 与 `inv9` 已合并为同一件事）；
  ② `wire9`：`本轮上行原文 updated_at + 该轮 offsetMs === 服务端值`（只在本轮确实改写了服务端时可核）；
  ③ `bound9`：跨轮不累加（相对第 1 轮的偏移 ≤ `DRIFT9 = 3 s = |offsetMs|/20`）；
  ④ `jitter9`：±3 s，仅作**收敛上界**，不承担严格性；
  ⑤ `exact9e`：**确定性**判据——对"只能由 pull 写入"的行，`A 库内值 + 该轮 respOffsetMs === 服务端值`。
  - **为什么不能拿 `T9` 当基准**：客户端每轮会按**该轮** `offsetMs` 重定基（`local = server − offset`），
    `offsetMs` 每轮抖动几毫秒 ⇒「初始 `T9` + 本轮 offset」不是合法候选值。旧判据正是这样产生假红的（t71 报 `#4.9`）。
  - **变异鉴别力**：`--mutate=tie-flip` 不命中 `#4.9`；`--mutate=offset-1000` 与 `--mutate=offset-twice` **都会**让 `#4.9` 变红
    （`run.sh` 第 6b/6c 段各自「变异必红 → `git show HEAD:` 还原必绿」）。
- **`#5.1`（复推不产生重复行）**："本轮是否改写了服务端"用 **push 响应的 `accepted`** 判定；
  `updated_at` 的漂移只允许两种合法形态：`Δ = 0`，或 `Δ = 两轮 offsetMs 之差`。
  （用服务端**行数**变化判断是错的：复推本来就不新增行，行数恒等。）
- 这两条都只改**夹具判据**，产品侧零改动；`app/**`、`server/**` 未碰（`git status --short -- app/ server/` 为空）。
