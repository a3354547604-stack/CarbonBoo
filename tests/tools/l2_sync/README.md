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
| `lib/device.mjs` | **一台设备的一个动作**（一个 OS 进程 = 一台设备）：`boot/save_record/edit_record/remove_record/insert_raw/set_row/set_config/mark_pending/align_singleton/sync/status/dump/egress`；每次调都走真实客户端实现 |
| `lib/l2_run.mjs` | 用例驱动：编排两台设备的动作、直连 HTTP 探针、独立读两个 `node:sqlite` 库文件、直查服务端 MySQL，逐条断言并打印原始请求/响应 |
| `lib/proxy.mjs` | **协议补全代理**（独立进程）：把同一轮 push 的 `offsetMs` 补进紧随的 pull 响应，好让「客户端取反换算」这条契约可被端到端验证；数据面完全来自真服务端，只补这一个字段 |
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

## 7. 发现（只报告，不在本任务修复）

本任务 inScope 只有 `tests/tools/l2_sync/`：**一行 `app/**` 都不改，`server/**` 只读**。
实测过程中发现的客户端/服务端缺陷、以及任务书与附录 B 的口径张力，全部逐条写在
[REPORT.md](REPORT.md) 的「发现」一节（含原始栈、触发条件、影响面与建议），
按 AGENTS.md §1.3 的格式给出 STOP。
