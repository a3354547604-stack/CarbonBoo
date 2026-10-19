# tests/tools/l2_sync REPORT —— 「L2 双设备协同」协议级端到端验证实测报告（t62 修订）

- **交付**：`tests/tools/l2_sync/`（`run.sh` + `lib/build.mjs` / `lib/device.mjs` / `lib/l2_run.mjs` / `lib/proxy.mjs` + 本报告 + `README.md`）
- **被测对象**：`app/entry/src/main/ets/viewmodel/net/SyncService.ets`（客户端 pull 合并实现；t62 的 F1/F2/F3 修复点）与 `server/app/**`（真服务端，本报告只读引用，未改一行）
- **实测命令**：`bash tests/tools/l2_sync/run.sh` → **退出码 0**（主用例 35 条断言全过；变异趟必红；`git show` 还原趟必绿）
- **日期**：2026-10-19 ｜ 跑测机：本机 WSL（无 hdc、无模拟器、`/dev/kvm` 不可写 ⇒ **真机 L2 物理不可达**）

> **一句话结论**：用**两个独立客户端的真 SQLite 库 + 真 FastAPI 服务端 + 真 HTTP**，把附录 B §6.4-6「两端用同一规则、结论一致」
> 跑成了可复现证据——**35 条断言全过**，并完成两条反证（出网必须被拒；把客户端平局判据反转必须变红、`git show` 还原必须变绿）。
> t57 用同一套夹具报出的三个客户端缺陷（F1/F2/F3）在 t62 修掉后，`#0.2`/`#8.3`/`#8.4` 就是**修复现场**断言（修复前必红、修复后必绿）。
> **它验的是协议级两端收敛，不能替代真机 L2**：不覆盖 UI、Ability 生命周期、端侧权限、系统时间/时区真实行为与近场通路（边界见 §4）。

## 0. 结论速览

| # | 验收项 | 判定 | 一句话证据 |
|---|---|---|---|
| 1 | 基线往返 | ✅ | A 真录入（`RecordService.save`→`CarbonService.calculate`）→ push → **另一个库/另一个 deviceId** 的 B pull → 逐列相同，四字段因子快照一致（`#1.2`/`#1.3`） |
| 2 | LWW 收敛 | ✅ | 两端各改一版 → 依次 push/pull → **两库最终行逐列完全相同**，胜者 = `updated_at` 大者（`#2.2`/`#2.3`），旧版上行被 rejected（`#2.4`） |
| 3 | 平局按 `deviceId` | ✅ | raw `updated_at` 完全相等时字典序大者胜、两端一致（`#3.1`/`#3.2`）；负向对照 `l2-dev-0` + 服务端同规则（`#3.3`/`#3.4`） |
| 4 | 时钟偏移取反 | ✅ | `offsetMs = 服务端 − 客户端` 两向对照（`#4.1`/`#4.2`）；超 ±300000ms 告警但继续合并（`#4.3`/`#4.4`）；`clientOffsetMs = −respOffsetMs` 的真链路取反 + 响应字段优先（`#4.5`/`#4.6`）；pull 响应确实没有该字段（`#4.7`） |
| 5 | 幂等 | ✅ | 同一批连推两次不产生重复行、行数三处不变（`#5.1`/`#5.5`）；`skipped = ignored + rejected` 三数自洽（`#5.2`）；口径前提见 `#5.3`/`#5.4` |
| 6 | 软删除传播 | ✅ | B 侧 `is_deleted=1` 且**行仍在表里**（两端各恰 1 行，`#6.2`），服务端同样持软删行（`#6.3`） |
| 7 | 冲突计数口径 | ✅ | 纯去重批次 `ignored>0` 而 `conflicts=0`（`#7.1`），同一计数器在真冲突批次确实 +1（`#7.2`）⇒ 不是「计数器坏了」的假绿 |
| 8 | 反证不是假绿 | ✅ | 不设 `L1_ALLOW_NETWORK` 时垫片拒绝出网并给出原始错误（`#8.1`）；变异自证三趟（§3.2）；`app/**` 零改动 + 指纹一致（§3.3） |
| 附 | t62 修复现场 | ✅ | F1 首同步不再撞唯一索引（`#0.2`/`#8.3`）；F3 两端真实编辑按业务键认领（`#8.4`）；F2 取反换算改走 push 握手腿（`#4.5`/`#4.7`）；L1 单测 41/41；编译成对自证（§3.4） |

## 1. 被验对象、机制与基准

### 1.1 机制（为什么这些证据可信）

1. **不重写实现**：`lib/build.mjs` 把 `app/entry/src/main/ets/{service,util,data,model,viewmodel}` 的真实 `.ets`
   **原样复制**到临时构建目录（逐文件 sha256 校验），再用 esbuild（`~/harmony-toolchain/esbuild/bin/esbuild` 0.28.2）
   转成 CJS；只重写平台说明符到 `tests/tools/l1_offline/platform/` 的 9 个垫片（垫片也逐字节复制、未改一行）。
   仓库里的 `SyncService.ets` 与构建副本 sha256 相同（见 §3.3）。
2. **两个真的客户端**：两台设备是**两个独立 OS 进程**（`lib/device.mjs` 一次调用 = 一台设备的一个动作），
   各有自己的 `L1_DATABASE_DIR`（`relationalStore` 垫片背后是 **`node:sqlite` 真 SQLite 引擎**，落成两个不同的库文件）
   和自己的 `deviceId`（预置 `app_config.device_id`），同一账号在**真服务端**登录拿 JWT。
3. **真 HTTP、真服务端**：客户端唯一 HTTP 出口 `HttpClient`（`viewmodel/net/HttpPort.ets`）在 `L1_ALLOW_NETWORK=1` 下走真 `fetch`
   打到真 uvicorn（FastAPI + MySQL 8，任务专属库 `carbonboo_l2_e2e`，跑完即删）。
4. **独立判据**：断言不采信客户端返回值，而是**独立**读两个库文件（`node:sqlite`）+ **直查服务端 MySQL** + 保留每个请求/响应的**原始文本**（`L2_WIRE_LOG`）。
5. **反证**：见 §3。

### 1.2 环境（run.sh 自检，缺任一项即退出码 2）

```text
== 1. 环境检查 ==
   Node: /usr/bin/node（v22.22.1）
   esbuild: /home/qinyixiang/harmony-toolchain/esbuild/bin/esbuild（0.28.2）
   容器: carbonboo-mysql 在线
   uvicorn: /mnt/c/Users/Administrator/Desktop/CarbonBoo/server/.venv/bin/uvicorn
   任务专用库: carbonboo_l2_e2e（不动共享库 carbonboo/carbonboo-mysql）
   服务端端口: 127.0.0.1:38675
== 2. 建任务专用库并灌 schema/seed ==
   库 carbonboo_l2_e2e 就绪：21 张表
```

### 1.3 运行规模

- 主用例 **35 条断言**（`#0.1`–`#8.4`），变异趟与还原趟各 7 条（第 3 项那一组）；
- 两台设备 + 一台"全新设备 C"（第 8.3 项），三个独立 `node:sqlite` 库文件；
- 每个请求/响应的原始文本都留档：主用例 wire 日志、变异趟、还原趟各一份（`run.sh` 的 `L2_KEEP_OUT`）。

## 2. 逐项实测（断言 / 原始输出 / 结论）

### 前置（0.x）：两台设备真的独立、真的登录、真的各同步一轮

```text
[PASS] #0.1 两台设备各自独立落库（不同库文件、不同 deviceId），用同一账号在真服务端登录拿到 token
    | A: via=register userId=u-489ad409da0648409bc2440038a6ea12 deviceId=l2-dev-A token长度=369 isLoggedIn=true
    | B: via=login userId=u-489ad409da0648409bc2440038a6ea12 deviceId=l2-dev-B token长度=369 isLoggedIn=true
    | A 库文件=/tmp/cbl2-1NGY5t/roots-main/A/databases/carbonboo.db.db
    | B 库文件=/tmp/cbl2-1NGY5t/roots-main/B/databases/carbonboo.db.db
    | A 账号态={"accountUserId":"u-489ad409da0648409bc2440038a6ea12","loginName":"u-489ad409da0648409bc2440038a6ea12\nl2dev_1792382848","loggedIn":true}
    | A 的认证请求（最后一条）→ POST http://127.0.0.1:38675/api/v1/auth/register → HTTP 201
      req:  {"username":"l2dev_1792382848","password":"l2-pass-123"}
      resp: {"ok":true,"data":{"userToken":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1LTQ4OWFkNDA5ZGEwNjQ4NDA5YmMyNDQwMDM4YTZlYTEyIiwidXNlcm5hbWUiOiJsMmRldl8xNzkyMzgyODQ4IiwiYXVkIjoiY2FyYm9uYm9vLWNsaWVudCIsImlzcyI6ImNhcmJvbmJvby1zZXJ2ZXIiLCJpYXQiOjE3OTIzODI4NTUsIm5iZiI6MTc5MjM4Mjg1NSwiZXhwIjoxNzkyOTg3NjU1LCJqdGkiOiJkMTRjNmJjZDMyOTQ0ZDFmYmNlOGNiNmMzNDE2ODE1NCJ9.Z84mSInLLyinJJnfIIBJFzYMBOzJtSgjN16CNaZaItU","userId":"u-489ad409da0648409bc2440038a6ea12","username":"l2dev_1792382848"}}
    | A 全部认证请求：["POST http://127.0.0.1:38675/api/v1/auth/login → 401","POST http://127.0.0.1:38675/api/v1/auth/register → 201"]
    | B 全部认证请求：["POST http://127.0.0.1:38675/api/v1/auth/login → 200"]
[PASS] #0.2 新设备首同步（since=0）不再撞唯一索引（F1 修复现场）：两端各自自建了同 user_id、不同 id 的单例行，B pull 到 A 那一版后按 user_id 认领并落库成功
    | A 本机: user_profile.id=28e0aa7a-ec5b-4d90-96c9-80d2a0612db8 / user_appearance.id=0547e455-85b9-4240-9696-9e6cc8ed97d5
    | B 本机: user_profile.id=06954b0e-1f19-463b-8fcc-eebde98ac1bc / user_appearance.id=ce2d58ea-966d-450a-a021-87c8d413ab2f（与 A 不同 —— 修复前正是这一步撞索引）
    | B 首同步（真实 push+pull）: ok=true，库内 user_profile 行数=1、user_appearance 行数=1
    | B 首同步 pull 线段（真实响应）: GET http://127.0.0.1:38675/api/v1/sync/pull?since=0 → HTTP 200
      req:
      resp: {"ok":true,"data":{"serverTime":1792382856819,"since":0,"tables":{"carbon_record":[],"point_record":[],"user_goal":[],"user_badge":[],"user_purchase":[],"user_appearance":[{"id":"0547e455-85b9-4240-9696-9e6cc8ed97d5","user_id":"u-489ad409da0648409bc2440038a6ea12","avatar_id":"avatar_leaf","frame_id":null,"theme_id":"theme_default","nickname":null,"created_at":1792382855482,"updated_at":1792382855482,"is_deleted":0,"device_id":"l2-dev-A"}],"science_progress":[],"carbon_include":[],"user_profile":[{"id":"28e0aa7a-ec5b-4d90-96c9-80d2a0612db8","user_id":"u-489ad409da0648409bc2440038a6ea12","display_name":"碳小布用户","register_day":"2026-10-19","onboarded":0,"last_active_at":1792382855482,"created_at":1792382855482,"updated_at":1792382855482,"is_deleted":0,"device_id":"l2-dev-A"}]}}}
    | B 首同步 errorString=undefined（修复前为 UNIQUE constraint failed: user_appearance.user_id）
    | A 首同步: ok=true，errorString=undefined
[PASS] #0.3 两端各完成一次真实 push+pull（服务端记录 lastSyncAt 锚点）
    | A push: {"accepted":2,"skipped":0,"ignored":0,"rejected":0,"conflicts":0,"serverTime":1792382856494,"offsetMs":58,"clockWarning":null,"acceptedByTable":{"user_appearance":1,"user_profile":1},"merged":{},"errors":[]}
    | B push: {"accepted":0,"skipped":2,"ignored":2,"rejected":0,"conflicts":0,"serverTime":1792382856792,"offsetMs":56,"clockWarning":null,"acceptedByTable":{},"merged":{"user_appearance":[{"id":"0547e455-85b9-4240-9696-9e6cc8ed97d5","user_id":"u-489ad409da0648409bc2440038a6ea12","avatar_id":"avatar_leaf","frame_id":null,"theme_id":"theme_default","nickname":null,"created_at":1792382855482,"updated_at":1792382855482,"is_deleted":0,"device_id":"l2-dev-A"}],"user_profile":[{"id":"28e0aa7a-ec5b-4d90-96c9-80d2a0612db8","user_id":"u-489ad409da0648409bc2440038a6ea12","display_name":"碳小布用户","register_day":"2026-10-19","onboarded":0,"last_active_at":1792382855482,"created_at":1792382855482,"updated_at":1792382855482,"is_deleted":0,"device_id":"l2-dev-A"}]},"errors":["user_appearance 业务唯一键 user_id=u-489ad409da0648409bc2440038a6ea12（单例行） 已存在，跨设备重复已去重（id=ce2d58ea-966d-450a-a021-87c8d413ab2f 未写入）","user_profile 业务唯一键 user_id=u-489ad409da0648409bc2440038a6ea12（单例行） 已存在，跨设备重复已去重（id=06954b0e-1f19-463b-8fcc-eebde98ac1bc 未写入）"]}
    | A lastSyncAt: null → 1792382856527
    | B lastSyncAt: null → 1792382856819
    | 客户端 sync_log（A 最近 5 条）: null
```

**结论**：✅。`#0.2` 是 t62 的修复现场之一：**新设备首同步**（`since=0`）就会 pull 到对端那一版
`user_profile`/`user_appearance`（同 `user_id`、不同 `id`），客户端现在按 `user_id` 认领并落库，**不再抛 `UNIQUE constraint failed`**。

### 第 1 项：基线往返（A 写 → push → B pull → 逐列相同）

**断言**：① A 走真实录入链路（`RecordService.save` → `CarbonService.calculate`）落库，四字段因子快照齐全；
② B（**另一个库文件、另一个 deviceId**）pull 后同一行与 A **逐列相同**（含四字段快照）；③ 服务端那份与两端一致；④ 另一张真实业务表（`point_record`）也随同一次同步往返。

```text
[PASS] #1.1 A 走真实录入链路（RecordService.save → CarbonService.calculate）落两条碳记录，含四字段因子快照
    | save#1 outcome: {"recordId":"1ee33bad-6380-495f-aae8-de3c42f3ad87","reductionKg":0.96,"pointExpected":96,"pointAwarded":96,"capped":false,"isAbnormal":false,"newGoals":[],"newBadges":["初次碳迹"],"goalPoints":0}
    | save#2 outcome: {"recordId":"68ff37ca-a3df-4e91-a76d-7c94fedaa607","reductionKg":5.703,"pointExpected":570,"pointAwarded":200,"capped":true,"isAbnormal":false,"newGoals":[],"newBadges":[],"goalPoints":0}
    | A 库中该行: amount=5 category=travel confidence=provisional created_at=1792987648000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=1ee33bad-6380-495f-aae8-de3c42f3ad87 is_abnormal=0 is_deleted=0 note=L2-基线-A1 occurred_at=1792379255247 point_awarded=96 point_capped=0 reduction_kg=0.96 revision=0 sub_type=walk sync_state=pending unit=km updated_at=1792987648000 user_id=u-489ad409da0648409bc2440038a6ea12
    | 四字段快照: factor_value=0.192 factor_version=CF-2026.2 factor_source=SRC-DERIVED confidence=provisional
[PASS] #1.2 push → pull 后，B 库中同一行与 A **逐列相同**（含四字段快照；排除端侧游标列 sync_state）
    | A push（原始响应）: POST http://127.0.0.1:38675/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-489ad409da0648409bc2440038a6ea12","deviceId":"l2-dev-A","lastSyncAt":1792382856527,"clientNow":1792382857621,"tables":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"},{"id":"68ff37ca-a3df-4e91-a76d-7c94fedaa607"…（截断，全长 7776 字符）
      resp: {"ok":true,"data":{"accepted":23,"skipped":0,"ignored":0,"rejected":0,"conflicts":0,"serverTime":1792382857783,"offsetMs":75,"clockWarning":null,"acceptedByTable":{"carbon_record":2,"point_record":2,"user_goal":11,"user_badge":8},"merged":{},"errors":[]}}
    | B pull（原始响应，仅列该行所在表）: [{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A"}]
    | A 库: amount=5 category=travel confidence=provisional created_at=1792987648000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=1ee33bad-6380-495f-aae8-de3c42f3ad87 is_abnormal=0 is_deleted=0 note=L2-基线-A1 occurred_at=1792379255247 point_awarded=96 point_capped=0 reduction_kg=0.96 revision=0 sub_type=walk sync_state=pending unit=km updated_at=1792987648000 user_id=u-489ad409da0648409bc2440038a6ea12
    | B 库: amount=5 category=travel confidence=provisional created_at=1792987648000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=1ee33bad-6380-495f-aae8-de3c42f3ad87 is_abnormal=0 is_deleted=0 note=L2-基线-A1 occurred_at=1792379255247 point_awarded=96 point_capped=0 reduction_kg=0.96 revision=0 sub_type=walk sync_state=local unit=km updated_at=1792987648000 user_id=u-489ad409da0648409bc2440038a6ea12
    | 差异列: 无
    | B 侧 sync_state=local（A 侧 pending）——端侧游标列，服务端不建该列，不参与同步
[PASS] #1.3 服务端（直查 MySQL）持有的该行与两端一致
    | 服务端: amount=5 category=travel confidence=provisional created_at=1792987648000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=1ee33bad-6380-495f-aae8-de3c42f3ad87 is_abnormal=0 is_deleted=0 note=L2-基线-A1 occurred_at=1792379255247 point_awarded=96 point_capped=0 reduction_kg=0.96 revision=0 sub_type=walk unit=km updated_at=1792987648000 user_id=u-489ad409da0648409bc2440038a6ea12
    | 直查命令: SELECT * FROM carbon_record WHERE id='1ee33bad-6380-495f-aae8-de3c42f3ad87'（docker exec carbonboo-mysql mysql -D carbonboo_l2_e2e）
[PASS] #1.4 另外的真实业务表（point_record 积分流水）也随同一次同步往返且两端逐列一致
    | A 侧 point_record 行数=2，B 侧=2
    | A 侧首行: created_at=1792382857095 device_id=l2-dev-A flow_kind=primary id=4b7d27ea-180c-460b-8f28-f4b0e3193570 is_deleted=0 occurred_at=1792379255247 points=96 remark=NULL source_id=1ee33bad-6380-495f-aae8-de3c42f3ad87#0 source_type=carbon_record sync_state=synced title=walk 5 km type=record updated_at=1792382857095 user_id=u-489ad409da0648409bc2440038a6ea12
    | B 侧首行: created_at=1792382857095 device_id=l2-dev-A flow_kind=primary id=4b7d27ea-180c-460b-8f28-f4b0e3193570 is_deleted=0 occurred_at=1792379255247 points=96 remark=NULL source_id=1ee33bad-6380-495f-aae8-de3c42f3ad87#0 source_type=carbon_record sync_state=local title=walk 5 km type=record updated_at=1792382857095 user_id=u-489ad409da0648409bc2440038a6ea12
    | 两端去游标列后全等: true
```

**结论**：✅ 通过。比对是**逐列**做的（唯一被排除的是端侧游标列 `sync_state`：服务端 schema 没有这一列，
`normalize_row` 会丢弃客户端的该列，故它本就不可能两端相同——这一点在夹具里是显式排除、不是放宽断言）。

### 第 2 项：LWW 收敛（两端各自离线改同一行 → 依次 push/pull）

**断言**：① 服务端按 `updatedAt` 大者胜；② **两库最终行逐列完全相同**（不是"服务端返回 accepted"就算）；
③ 与服务端那一份同一版本；④ 输的那一端上行被 `rejected`（不做降级覆盖），靠 pull 收敛。

```text
[PASS] #2.1 服务端按 updatedAt 大者胜：B 的版本（updated_at 更大）被采纳，且被计为真冲突
    | A 改（T1=1792987908000）: POST http://127.0.0.1:38675/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-489ad409da0648409bc2440038a6ea12","deviceId":"l2-dev-A","lastSyncAt":1792382858865,"clientNow":1792382859690,"tables":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"synced"},{"id":"68ff37ca-a3df-4e91-a76d-7c94fedaa607",…（截断，全长 8280 字符）
      resp: {"ok":true,"data":{"accepted":24,"skipped":0,"ignored":0,"rejected":0,"conflicts":22,"serverTime":1792382859847,"offsetMs":71,"clockWarning":null,"acceptedByTable":{"carbon_record":3,"point_record":2,"user_goal":11,"user_badge":8},"merged":{},"errors":[]}}
    | B 改（T2=1792987968000）: POST http://127.0.0.1:38675/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-489ad409da0648409bc2440038a6ea12","deviceId":"l2-dev-B","lastSyncAt":1792382859174,"clientNow":1792382860289,"tables":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"synced"},{"id":"68ff37ca-a3df-4e91-a76d-7c94fedaa607",…（截断，全长 8261 字符）
      resp: {"ok":true,"data":{"accepted":22,"skipped":2,"ignored":2,"rejected":0,"conflicts":22,"serverTime":1792382860396,"offsetMs":50,"clockWarning":null,"acceptedByTable":{"carbon_record":3,"user_goal":11,"user_badge":8},"merged":{},"errors":["point_record 业务唯一键 source_type='carbon_record', source_id='9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf#0', flow_kind='reverse'（user_id=u-489ad409da0648409bc2440038a6ea12） 已入账，跨设备重复已去重","point_record 业务唯一键 source_type='carbon_record', source_id='9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf#1', flow_kind='primary'（user_id=u-489ad409da0648409bc2440038a6ea12） 已入账，跨设备重复已去重"]}}
    | 服务端采纳后该行: updated_at=1792987968000 note=LWW-B版
    | B push 的 conflicts=22（两端自上次同步后都改过这一行 → 真冲突）
[PASS] #2.2 两端最终行**逐列完全相同**（不是只断言服务端返回 accepted）
    | A push#2（旧版本，被服务端拒绝）: POST http://127.0.0.1:38675/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-489ad409da0648409bc2440038a6ea12","deviceId":"l2-dev-A","lastSyncAt":1792382859878,"clientNow":1792382860624,"tables":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"synced"},{"id":"68ff37ca-a3df-4e91-a76d-7c94fedaa607",…（截断，全长 7431 字符）
      resp: {"ok":true,"data":{"accepted":2,"skipped":20,"ignored":0,"rejected":20,"conflicts":2,"serverTime":1792382860714,"offsetMs":52,"clockWarning":null,"acceptedByTable":{"carbon_record":2},"merged":{"carbon_record":[{"id":"9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":9.0,"unit":"kg","occurred_at":1792379255247,"reduction_kg":8.1,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":1,"is_abnormal":0,"note":"LWW-B版","created_at":1792987848000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"}],"user_goal":[{"id":"9b02748e-9e85-4aa5-b998-15bbd3270e3d","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"c46693cb-1266-46c1-a6bf-300db3f727ab","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M1","period_key":"M:2026-10","progress":5.0,"threshold":100.0,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"d4c163ac-6a24-44c8-9fff-c15a35a41a26","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M2","period_k…（截断，全长 7567 字符）
    | A 库: amount=9 category=recycle confidence=provisional created_at=1792987848000 device_id=l2-dev-A factor_source=SRC-CALC factor_value=0.9 factor_version=CF-2026.2 id=9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf is_abnormal=0 is_deleted=0 note=LWW-B版 occurred_at=1792379255247 point_awarded=200 point_capped=1 reduction_kg=8.1 revision=1 sub_type=paper sync_state=local unit=kg updated_at=1792987968000 user_id=u-489ad409da0648409bc2440038a6ea12
    | B 库: amount=9 category=recycle confidence=provisional created_at=1792987848000 device_id=l2-dev-A factor_source=SRC-CALC factor_value=0.9 factor_version=CF-2026.2 id=9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf is_abnormal=0 is_deleted=0 note=LWW-B版 occurred_at=1792379255247 point_awarded=200 point_capped=1 reduction_kg=8.1 revision=1 sub_type=paper sync_state=synced unit=kg updated_at=1792987968000 user_id=u-489ad409da0648409bc2440038a6ea12
    | 差异列: 无
[PASS] #2.3 胜者确为 updatedAt 更大的一版（B 版内容），且服务端与两端同一份
    | T2=1792987968000（B 版） > T1=1792987908000（A 版）
    | A 库: updated_at=1792987968000 note=LWW-B版 amount=9
    | B 库: updated_at=1792987968000 note=LWW-B版 amount=9
    | 服务端: updated_at=1792987968000 note=LWW-B版 amount=9
[PASS] #2.4 旧版本上行被服务端**拒绝**（不做降级覆盖），A 靠随后的 pull 收敛到胜者版本
    | A push#2 响应: {"accepted":2,"skipped":20,"ignored":0,"rejected":20,"conflicts":2,"serverTime":1792382860714,"offsetMs":52,"clockWarning":null,"acceptedByTable":{"carbon_record":2},"merged":{"carbon_record":[{"id":"9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":9,"unit":"kg","occurred_at":1792379255247,"reduction_kg":8.1,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":1,"is_abnormal":0,"note":"LWW-B版","created_at":1792987848000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"}],"user_goal":[{"id":"9b02748e-9e85-4aa5-b998-15bbd3270e3d","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"L1","period_key":"L:2026-10-19","progress":1,"threshold":80,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"c46693cb-1266-46c1-a6bf-300db3f727ab","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M1","period_key":"M:2026-10","progress":5,"threshold":100,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"d4c163ac-6a24-44c8-9fff-c15a35a41a26","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M2","period_key":"Q:2026-Q4","progress":14.763,"threshold":50,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"2a7b5eeb-e958-4823-a175-c8fb19c2b3b2","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M3","period_key":"Q:2026-Q4","progress":9,"threshold":20,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"396dd28f-42f0-4dc2-a5ed-5762efd3533b","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M4","period_key":"M:2026-10","progress":0,"threshold":20,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"dbef499c-ac2f-4346-b109-d88158fd7b04","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M5","period_key":"Y:2026","progress":14.763,"threshold":200,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"fdfcb91f-ea19-4a23-9919-1106245d3254","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S1","period_key":"D:2026-10-26","progress":0,"threshold":1,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"ae1fbcb0-dad5-4a5c-bafc-48d01c766e6b","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S2","period_key":"D:2026-10-26","progress":0,"threshold":5,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"a56a3612-f217-434a-af68-fa2cfbf9be37","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S3","period_key":"D:2026-10-26","progress":0,"threshold":1,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"45859f6b-4f15-47b9-97bd-069bee777fb9","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S4","period_key":"W:2026-W44","progress":0,"threshold":3,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"eab75295-c471-4127-8cce-bb37839c30c5","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S5","period_key":"W:2026-W44","progress":0,"threshold":5,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"}],"user_badge":[{"id":"8dfb7a8c-7e2e-4c22-8278-9c521f35d318","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_FIRST","unlocked":1,"unlocked_at":1792987648000,"progress":1,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"e515e5c9-bdaf-4860-b4f9-657977684e2f","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_GREEN_TRIP","unlocked":0,"unlocked_at":null,"progress":1,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"4e6f846c-6cde-46d9-a28b-ab9b47563a18","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_RECYCLER","unlocked":0,"unlocked_at":null,"progress":9,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"28aa2fb5-9d84-4e44-b1d5-66655dd0fcde","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_STREAK_30","unlocked":0,"unlocked_at":null,"progress":0,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"663f80f8-251d-4432-82d4-33b9022b7720","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_STREAK_7","unlocked":0,"unlocked_at":null,"progress":0,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"c4a06f33-9f44-4b07-b99e-2cc85a201169","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_TOTAL_10","unlocked":1,"unlocked_at":1792987968000,"progress":14.763,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"d010aa42-feec-4289-aea0-b49aac1276be","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_TOTAL_100","unlocked":0,"unlocked_at":null,"progress":14.763,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"74320cbf-6480-46c3-908c-bdde09c37c17","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_TREE","unlocked":0,"unlocked_at":null,"progress":0,"created_at":1792987648000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"}]},"errors":["carbon_record.id=9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=9b02748e-9e85-4aa5-b998-15bbd3270e3d 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=c46693cb-1266-46c1-a6bf-300db3f727ab 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=d4c163ac-6a24-44c8-9fff-c15a35a41a26 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=2a7b5eeb-e958-4823-a175-c8fb19c2b3b2 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=396dd28f-42f0-4dc2-a5ed-5762efd3533b 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=dbef499c-ac2f-4346-b109-d88158fd7b04 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=fdfcb91f-ea19-4a23-9919-1106245d3254 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=ae1fbcb0-dad5-4a5c-bafc-48d01c766e6b 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=a56a3612-f217-434a-af68-fa2cfbf9be37 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=45859f6b-4f15-47b9-97bd-069bee777fb9 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=eab75295-c471-4127-8cce-bb37839c30c5 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=8dfb7a8c-7e2e-4c22-8278-9c521f35d318 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=e515e5c9-bdaf-4860-b4f9-657977684e2f 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=4e6f846c-6cde-46d9-a28b-ab9b47563a18 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=28aa2fb5-9d84-4e44-b1d5-66655dd0fcde 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=663f80f8-251d-4432-82d4-33b9022b7720 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=c4a06f33-9f44-4b07-b99e-2cc85a201169 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=d010aa42-feec-4289-aea0-b49aac1276be 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=74320cbf-6480-46c3-908c-bdde09c37c17 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）"]}
    | A 库最终: amount=9 category=recycle confidence=provisional created_at=1792987848000 device_id=l2-dev-A factor_source=SRC-CALC factor_value=0.9 factor_version=CF-2026.2 id=9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf is_abnormal=0 is_deleted=0 note=LWW-B版 occurred_at=1792379255247 point_awarded=200 point_capped=1 reduction_kg=8.1 revision=1 sub_type=paper sync_state=local unit=kg updated_at=1792987968000 user_id=u-489ad409da0648409bc2440038a6ea12
    | 服务端在 push 响应里回了 merged（客户端 sync() 只检查 status、从不读 body）：{"carbon_record":[{"id":"9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":9,"unit":"kg","occurred_at":1792379255247,"reduction_kg":8.1,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":1,"is_abnormal":0,"note":"LWW-B版","created_at":1792987848000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"}],"u…（截断，全长 5715 字符）
```

**结论**：✅ 通过。这是本任务最核心的一条：**收敛判据落在两端库内容的逐列相等上**，服务端返回值只作旁证。

### 第 3 项：平局按 `deviceId` 字典序（`updated_at` 完全相等）

**断言**：① 对端 `deviceId` 更大（`l2-dev-Z`）且 raw `updated_at` 完全相等 ⇒ 两端都采纳对端、逐列相同；
② 负向对照：对端更小（`l2-dev-0`）⇒ 两端各自保留本机；③ 服务端侧同向规则（`offsetMs=0` 直连探针）。

**构造**（为什么不是让 B 去"编辑成平局"）：平局要求客户端比较的两个值**逐毫秒相等**，而 `clientOffsetMs` 来自握手腿的实时测量
（含往返抖动，实测差 57ms）。故夹具把输入做成确定的三件套：**三方 raw 相等** + **两端时钟调快 5 分钟**（让服务端拒绝本机上行，
保住服务端那一版）+ **代理 `forceOffsetMs=0`**（让客户端按裸 raw 比较）。`device_id` 比较与被测分支全是真实代码。

```text
[PASS] #3.1 对端 deviceId 字典序更大（l2-dev-Z > l2-dev-A / l2-dev-B）且两端 raw updated_at **完全相等** ⇒ 客户端平局分支采纳对端版本
    | 平局构造：本机 A=(updated_at=1792383460841, device_id=l2-dev-A, note=平局-A版) / 本机 B=(updated_at=1792383460841, device_id=l2-dev-B, note=平局-B版) / 服务端=(updated_at=1792383460841, device_id=l2-dev-Z, note=平局-Z版) —— 三方 raw 逐毫秒相等
    | 锚点（两端）: {"last_sync_at":"1792383460840"} / {"last_sync_at":"1792383460840"} —— 本机行 updated_at=1792383460841 > 1792383460840 ⇒ 会被 push（故需 ② 让服务端拒绝它）；服务端那一版同为 1792383460841 也被 pull 取回
    | A push 响应 offsetMs=-299919、rejected=28（本机时钟调快 300000ms ⇒ 握手腿回传 ≈ −300000 ⇒ 本机上行"比服务端旧"被拒，服务端那一版未被覆盖）
    | B push 响应 offsetMs=-299943、rejected=28
    | ③ 本轮 baseUrl 指向协议补全代理（forceOffsetMs=0）⇒ 客户端 clientOffsetMs = -0 = 0 ⇒ 按裸 raw 比较 ⇒ 与 raw 相等 ⇒ 命中平局分支
    | A 侧 set_row 回读: {"id":"255ecbbd-1b98-4e3e-a91f-79a9e6575839","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"aluminum","amount":5,"unit":"kg","occurred_at":1792379255247,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-A版","created_at":1792383460841,"updated_at":1792383460841,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"}
    | B 侧 set_row 回读: {"id":"255ecbbd-1b98-4e3e-a91f-79a9e6575839","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"aluminum","amount":7,"unit":"kg","occurred_at":1792379255247,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-B版","created_at":1792383460841,"updated_at":1792383460841,"is_deleted":0,"device_id":"l2-dev-B","sync_state":"pending"}
    | 服务端构造后: amount=42 category=recycle confidence=provisional created_at=1792383460841 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=255ecbbd-1b98-4e3e-a91f-79a9e6575839 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792383460841 user_id=u-489ad409da0648409bc2440038a6ea12
    | A push: POST http://127.0.0.1:35139/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-489ad409da0648409bc2440038a6ea12","deviceId":"l2-dev-A","lastSyncAt":1792383460840,"clientNow":1792383163321,"tables":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"synced"},{"id":"68ff37ca-a3df-4e91-a76d-7c94fedaa607",…（截断，全长 9466 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":28,"ignored":0,"rejected":28,"conflicts":0,"serverTime":1792382863438,"offsetMs":-299919,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5.0,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"68ff37ca-a3df-4e91-a76d-7c94fedaa607","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"utility","sub_type":"elec_grid","amount":10.0,"unit":"kWh","occurred_at":1792379255247,"reduction_kg":5.703,"factor_value":0.5703,"factor_version":"CF-2026.2","factor_source":"SRC-MEE-GRID-2022","confidence":"verified","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"L2-基线-A2","created_at":1792987649000,"updated_at":1792987649000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":9.0,"unit":"kg","occurred_at":1792379255247,"reduction_kg":8.1,"factor_val…（截断，全长 11128 字符）
    | B push: POST http://127.0.0.1:35139/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-489ad409da0648409bc2440038a6ea12","deviceId":"l2-dev-B","lastSyncAt":1792383460840,"clientNow":1792383163780,"tables":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"synced"},{"id":"68ff37ca-a3df-4e91-a76d-7c94fedaa607",…（截断，全长 9475 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":28,"ignored":0,"rejected":28,"conflicts":0,"serverTime":1792382863867,"offsetMs":-299943,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5.0,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"68ff37ca-a3df-4e91-a76d-7c94fedaa607","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"utility","sub_type":"elec_grid","amount":10.0,"unit":"kWh","occurred_at":1792379255247,"reduction_kg":5.703,"factor_value":0.5703,"factor_version":"CF-2026.2","factor_source":"SRC-MEE-GRID-2022","confidence":"verified","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"L2-基线-A2","created_at":1792987649000,"updated_at":1792987649000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":9.0,"unit":"kg","occurred_at":1792379255247,"reduction_kg":8.1,"factor_val…（截断，全长 11128 字符）
    | A 库: amount=42 category=recycle confidence=provisional created_at=1792383460841 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=255ecbbd-1b98-4e3e-a91f-79a9e6575839 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792383460841 user_id=u-489ad409da0648409bc2440038a6ea12
    | B 库: amount=42 category=recycle confidence=provisional created_at=1792383460841 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=255ecbbd-1b98-4e3e-a91f-79a9e6575839 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792383460841 user_id=u-489ad409da0648409bc2440038a6ea12
[PASS] #3.2 两端最终行**逐列完全相同**（不是"服务端返回 accepted"就算），且与服务端那一份同一版本
    | A 库: amount=42 category=recycle confidence=provisional created_at=1792383460841 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=255ecbbd-1b98-4e3e-a91f-79a9e6575839 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792383460841 user_id=u-489ad409da0648409bc2440038a6ea12
    | B 库: amount=42 category=recycle confidence=provisional created_at=1792383460841 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=255ecbbd-1b98-4e3e-a91f-79a9e6575839 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792383460841 user_id=u-489ad409da0648409bc2440038a6ea12
    | 服务端: amount=42 category=recycle confidence=provisional created_at=1792383460841 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=255ecbbd-1b98-4e3e-a91f-79a9e6575839 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792383460841 user_id=u-489ad409da0648409bc2440038a6ea12
    | 差异列: 无
[PASS] #3.3 负向对照：对端 deviceId 更小（l2-dev-0 < l2-dev-A / l2-dev-B）且两端 raw updated_at 完全相等 ⇒ 两端各自保留本机版本，不采纳对端
    | 服务端构造后: amount=99 category=recycle confidence=provisional created_at=1792383764047 device_id=l2-dev-0 factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=ddf6ffc8-141f-4ea5-8436-a06dd45331f0 is_abnormal=0 is_deleted=0 note=平局2-0版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass unit=kg updated_at=1792383764047 user_id=u-489ad409da0648409bc2440038a6ea12（与本机 raw 逐毫秒相等）
    | A push 响应 offsetMs=-299945、rejected=28
    | A 库（应保留本机）: amount=4 category=recycle confidence=provisional created_at=1792383764047 device_id=l2-dev-A factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=ddf6ffc8-141f-4ea5-8436-a06dd45331f0 is_abnormal=0 is_deleted=0 note=平局2-A版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=synced unit=kg updated_at=1792383764047 user_id=u-489ad409da0648409bc2440038a6ea12
    | B 库（应保留本机）: amount=6 category=recycle confidence=provisional created_at=1792383764047 device_id=l2-dev-B factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=ddf6ffc8-141f-4ea5-8436-a06dd45331f0 is_abnormal=0 is_deleted=0 note=平局2-B版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=synced unit=kg updated_at=1792383764047 user_id=u-489ad409da0648409bc2440038a6ea12
    | 注：这一支按规则"对端更小 ⇒ 保留本机"，两端各自留住自己那一版；它不是收敛用例，只用来证明比较方向（若把判据反转成"字典序小者胜"，A/B 都会变成平局2-0版 ⇒ 本条与 3.1 同时变红）。
[PASS] #3.4 服务端平局规则同向：`offsetMs=0`（省略 clientNow）时，同一 `updated_at` 下 deviceId 大者被采纳、小者被记 ignored
    | 直连探针①（device_id=l2-dev-Z，省略 clientNow）: {"ok":true,"data":{"accepted":1,"skipped":0,"ignored":0,"rejected":0,"conflicts":1,"serverTime":1792382867395,"offsetMs":0,"clockWarning":null,"acceptedByTable":{"carbon_record":1},"merged":{},"errors":[]}}
    | 服务端该行: amount=1 category=recycle confidence=provisional created_at=1792382986776 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=0.9 factor_version=CF-2026.2 id=85c1cf0d-ff05-4653-807c-013c50d215bf is_abnormal=0 is_deleted=0 note=平局3-l2-dev-Z occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=0.9 revision=0 sub_type=paper unit=kg updated_at=1792382986776 user_id=u-489ad409da0648409bc2440038a6ea12
    | 直连探针②（device_id=l2-dev-0）: {"ok":true,"data":{"accepted":0,"skipped":1,"ignored":1,"rejected":0,"conflicts":0,"serverTime":1792382867510,"offsetMs":0,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"85c1cf0d-ff05-4653-807c-013c50d215bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":1.0,"unit":"kg","occurred_at":1792379255247,"reduction_kg":0.9,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","po…（截断，全长 790 字符）
    | 服务端该行未变: amount=1 category=recycle confidence=provisional created_at=1792382986776 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=0.9 factor_version=CF-2026.2 id=85c1cf0d-ff05-4653-807c-013c50d215bf is_abnormal=0 is_deleted=0 note=平局3-l2-dev-Z occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=0.9 revision=0 sub_type=paper unit=kg updated_at=1792382986776 user_id=u-489ad409da0648409bc2440038a6ea12
    | 三数自洽：skipped=1 = ignored(1) + rejected(0)
    | 口径提醒：真实客户端总会带 `clientNow`（SyncService.ets:513），于是 `offsetMs≈+50ms≠0`，服务端比较的是 `raw + offsetMs` ⇒ **永远构不成相等**，平局分支在真实链路上轮不到；上面 3.1/3.2 的"两端一致"正是靠"服务端拒绝上行（更旧）+ 客户端平局分支"取得的。
```

**结论**：✅ 通过。这也是变异自证的靶子：把 `remoteDevice > localDevice` 反转为 `<`，`#3.1`/`#3.2`/`#3.3` 同时变红（§3.2）。

### 第 4 项：时钟偏移（`offsetMs = 服务端 − 客户端`；客户端须取反换算）

**断言**：① 客户端落后 ⇒ `offsetMs ≈ +300000`，服务端把"原始更旧、换算后更新"的行采纳；② 客户端超前 ⇒ 拒绝（证明判据是"服务端 − 客户端"而非原始值）；
③ 偏移超 ±300000ms ⇒ 响应 `clockWarning` 非空且**照常继续合并**；④ 告警落服务端 `sync_log`（status=partial + error_msg）；
⑤ 真链路（不接代理）：客户端用**同一轮 push 握手腿**的 `offsetMs` 取反 ⇒ 对端时间戳换算后显得更旧 ⇒ A 保留本机；
⑥ 响应字段优先：pull 响应里给了 `offsetMs` 就以它为准（同一构造结论翻面 ⇒ 证明是"按符号取反"而不是随手加减）；
⑦ 真实 pull 响应**不含** `offsetMs`（`SyncPullData` 就没有该字段）。

```text
[PASS] #4.1 A 时钟落后 5 分钟：offsetMs ≈ +300000（= 服务端 − 客户端），服务端把"原始时间戳更旧、换算后更新"的行采纳
    | A 那行的原始 updated_at=1792988488000，服务端原值 1792988548000（原始更旧）
    | 换算：remote_updated = 1792988488000 + offsetMs(300057) = 1792988788057 > local 1792988548000 → 采纳
    | push 响应 offsetMs=300057（≈ +300000 ⇒ 服务端时钟 − 客户端时钟，客户端落后）
    | 服务端前: amount=6 category=travel confidence=provisional created_at=1792988548000 device_id=l2-dev-B factor_source=SRC-DERIVED factor_value=0.162 factor_version=CF-2026.2 id=b13b627e-29b8-460b-a6fb-6790281d3550 is_abnormal=0 is_deleted=0 note=时钟-B基准 occurred_at=1792379255247 point_awarded=97 point_capped=0 reduction_kg=0.972 revision=0 sub_type=metro unit=km updated_at=1792988548000 user_id=u-489ad409da0648409bc2440038a6ea12
    | 服务端后: amount=8 category=travel confidence=provisional created_at=1792988548000 device_id=l2-dev-B factor_source=SRC-DERIVED factor_value=0.162 factor_version=CF-2026.2 id=b13b627e-29b8-460b-a6fb-6790281d3550 is_abnormal=0 is_deleted=0 note=时钟-A落后5分 occurred_at=1792379255247 point_awarded=130 point_capped=0 reduction_kg=1.296 revision=1 sub_type=metro unit=km updated_at=1792988488000 user_id=u-489ad409da0648409bc2440038a6ea12
    | 原始响应: {"ok":true,"data":{"accepted":33,"skipped":0,"ignored":0,"rejected":0,"conflicts":33,"serverTime":1792382873255,"offsetMs":300057,"clockWarning":"客户端时钟与服务端相差 300.1 秒，超出 ±5 分钟容差；已按 offsetMs=300057 换算到服务端基准后继续合并（附录 B §6.4-6）","acceptedByTable":{"carbon_record":9,"user_goal":16,"user_badge":8},"merged":{},"errors":["客户端时钟与服务端相差 300.1 秒，超出 ±5 分钟容差；已按 offsetMs=300057 换算到服务端基准后继续合并（附录 B §6.4-6）"]}}
[PASS] #4.2 反向：A 时钟超前 5 分钟，原始时间戳更新但换算后更旧 → 服务端拒绝（判据是"服务端 − 客户端"，不是原始值）
    | A 那行的原始 updated_at=1792988668000（原始比服务端 1792988608000 新）
    | 换算：remote_updated = 1792988668000 + offsetMs(-299949) = 1792988368051 < local 1792988608000 → 拒绝
    | push 响应: {"accepted":2,"skipped":34,"ignored":0,"rejected":34,"conflicts":0,"serverTime":1792382874777,"offsetMs":-299949,"clockWarning":null,"acceptedByTable":{"point_record":2},"merged":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"68ff37ca-a3df-4e91-a76d-7c94fedaa607","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"utility","sub_type":"elec_grid","amount":10,"unit":"kWh","occurred_at":1792379255247,"reduction_kg":5.703,"factor_value":0.5703,"factor_version":"CF-2026.2","factor_source":"SRC-MEE-GRID-2022","confidence":"verified","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"L2-基线-A2","created_at":1792987649000,"updated_at":1792987649000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":9,"unit":"kg","occurred_at":1792379255247,"reduction_kg":8.1,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":1,"is_abnormal":0,"note":"LWW-B版","created_at":1792987848000,"updated_at":1792987968000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"255ecbbd-1b98-4e3e-a91f-79a9e6575839","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"aluminum","amount":42,"unit":"kg","occurred_at":1792379255247,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":1792383460841,"updated_at":1792383460841,"is_deleted":0,"device_id":"l2-dev-Z"},{"id":"ddf6ffc8-141f-4ea5-8436-a06dd45331f0","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"glass","amount":4,"unit":"kg","occurred_at":1792379255247,"reduction_kg":3,"factor_value":1,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局2-A版","created_at":1792383764047,"updated_at":1792383764047,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"85c1cf0d-ff05-4653-807c-013c50d215bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":1,"unit":"kg","occurred_at":1792379255247,"reduction_kg":0.9,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局3-源","created_at":1792382986776,"updated_at":1792382986776,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"ee977ff7-a5ff-40fc-b12e-ed6a908d4743","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"plate","sub_type":"meal","amount":3,"unit":"次","occurred_at":1792379255247,"reduction_kg":1.05,"factor_value":0.35,"factor_version":"CF-2026.2","factor_source":"SRC-CCAP-FW","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"L2-幂等","created_at":1792382927627,"updated_at":1792382927627,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"afaeab28-4b25-479e-a475-3d13d0582697","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"bicycle","amount":4,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.768,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":77,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-待删","created_at":1792988448000,"updated_at":1792988508000,"is_deleted":1,"device_id":"l2-dev-A"},{"id":"b13b627e-29b8-460b-a6fb-6790281d3550","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"metro","amount":6,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.972,"factor_value":0.162,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":97,"point_capped":0,"revision":0,"is_abnormal":0,"note":"时钟-B基准","created_at":1792988548000,"updated_at":1792988548000,"is_deleted":0,"device_id":"l2-dev-B"},{"id":"06d68c8b-77a7-42f7-a823-39b395cac88d","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"utility","sub_type":"gas","amount":3,"unit":"m³","occurred_at":1792379255247,"reduction_kg":6.552,"factor_value":2.184,"factor_version":"CF-2026.2","factor_source":"SRC-MEE-GHG","confidence":"verified","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"时钟-B基准2","created_at":1792988608000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-B"}],"user_goal":[{"id":"9b02748e-9e85-4aa5-b998-15bbd3270e3d","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"L1","period_key":"L:2026-10-19","progress":1,"threshold":80,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"c46693cb-1266-46c1-a6bf-300db3f727ab","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M1","period_key":"M:2026-10","progress":11,"threshold":100,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"d4c163ac-6a24-44c8-9fff-c15a35a41a26","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M2","period_key":"Q:2026-Q4","progress":45.237,"threshold":50,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"2a7b5eeb-e958-4823-a175-c8fb19c2b3b2","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M3","period_key":"Q:2026-Q4","progress":58,"threshold":20,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"396dd28f-42f0-4dc2-a5ed-5762efd3533b","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M4","period_key":"M:2026-10","progress":1,"threshold":20,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"dbef499c-ac2f-4346-b109-d88158fd7b04","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"M5","period_key":"Y:2026","progress":45.237,"threshold":200,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"05af216c-c696-4245-a13c-6fa5cd4fde33","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S1","period_key":"D:2026-10-19","progress":1,"threshold":1,"settled":1,"settled_at":1792383460841,"created_at":1792383460841,"updated_at":1792383764047,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"fdfcb91f-ea19-4a23-9919-1106245d3254","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S1","period_key":"D:2026-10-26","progress":0,"threshold":1,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"7e84912f-29e2-4ad2-b899-29ef232dc55f","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S2","period_key":"D:2026-10-19","progress":10,"threshold":5,"settled":1,"settled_at":1792383460841,"created_at":1792383460841,"updated_at":1792383764047,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"ae1fbcb0-dad5-4a5c-bafc-48d01c766e6b","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S2","period_key":"D:2026-10-26","progress":0,"threshold":5,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"b1317691-0d9b-48f9-bf45-45e7c8276f9a","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S3","period_key":"D:2026-10-19","progress":0,"threshold":1,"settled":0,"settled_at":null,"created_at":1792383460841,"updated_at":1792383764047,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"a56a3612-f217-434a-af68-fa2cfbf9be37","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S3","period_key":"D:2026-10-26","progress":0,"threshold":1,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"320b4c7b-0130-4b39-90a9-da4b2e6e7350","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S4","period_key":"W:2026-W43","progress":3,"threshold":3,"settled":1,"settled_at":1792383764047,"created_at":1792383460841,"updated_at":1792383764047,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"45859f6b-4f15-47b9-97bd-069bee777fb9","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S4","period_key":"W:2026-W44","progress":0,"threshold":3,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"8fd85b05-f545-4736-bd4d-1820e75cec4e","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S5","period_key":"W:2026-W43","progress":1,"threshold":5,"settled":0,"settled_at":null,"created_at":1792383460841,"updated_at":1792383764047,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"eab75295-c471-4127-8cce-bb37839c30c5","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"S5","period_key":"W:2026-W44","progress":0,"threshold":5,"settled":0,"settled_at":null,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"}],"user_badge":[{"id":"8dfb7a8c-7e2e-4c22-8278-9c521f35d318","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_FIRST","unlocked":1,"unlocked_at":1792987648000,"progress":1,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"e515e5c9-bdaf-4860-b4f9-657977684e2f","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_GREEN_TRIP","unlocked":0,"unlocked_at":null,"progress":2,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"4e6f846c-6cde-46d9-a28b-ab9b47563a18","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_RECYCLER","unlocked":1,"unlocked_at":1792988448000,"progress":58,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"28aa2fb5-9d84-4e44-b1d5-66655dd0fcde","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_STREAK_30","unlocked":0,"unlocked_at":null,"progress":0,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"663f80f8-251d-4432-82d4-33b9022b7720","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_STREAK_7","unlocked":0,"unlocked_at":null,"progress":0,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"c4a06f33-9f44-4b07-b99e-2cc85a201169","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_TOTAL_10","unlocked":1,"unlocked_at":1792987968000,"progress":45.237,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"d010aa42-feec-4289-aea0-b49aac1276be","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_TOTAL_100","unlocked":0,"unlocked_at":null,"progress":45.237,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"74320cbf-6480-46c3-908c-bdde09c37c17","user_id":"u-489ad409da0648409bc2440038a6ea12","badge_id":"B_TREE","unlocked":0,"unlocked_at":null,"progress":0,"created_at":1792987648000,"updated_at":1792988608000,"is_deleted":0,"device_id":"l2-dev-A"}]},"errors":["carbon_record.id=1ee33bad-6380-495f-aae8-de3c42f3ad87 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=68ff37ca-a3df-4e91-a76d-7c94fedaa607 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=255ecbbd-1b98-4e3e-a91f-79a9e6575839 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=ddf6ffc8-141f-4ea5-8436-a06dd45331f0 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=85c1cf0d-ff05-4653-807c-013c50d215bf 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=ee977ff7-a5ff-40fc-b12e-ed6a908d4743 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=afaeab28-4b25-479e-a475-3d13d0582697 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=b13b627e-29b8-460b-a6fb-6790281d3550 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=06d68c8b-77a7-42f7-a823-39b395cac88d 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=9b02748e-9e85-4aa5-b998-15bbd3270e3d 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=c46693cb-1266-46c1-a6bf-300db3f727ab 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=d4c163ac-6a24-44c8-9fff-c15a35a41a26 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=2a7b5eeb-e958-4823-a175-c8fb19c2b3b2 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=396dd28f-42f0-4dc2-a5ed-5762efd3533b 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=dbef499c-ac2f-4346-b109-d88158fd7b04 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=05af216c-c696-4245-a13c-6fa5cd4fde33 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=fdfcb91f-ea19-4a23-9919-1106245d3254 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=7e84912f-29e2-4ad2-b899-29ef232dc55f 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=ae1fbcb0-dad5-4a5c-bafc-48d01c766e6b 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=b1317691-0d9b-48f9-bf45-45e7c8276f9a 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=a56a3612-f217-434a-af68-fa2cfbf9be37 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=320b4c7b-0130-4b39-90a9-da4b2e6e7350 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=45859f6b-4f15-47b9-97bd-069bee777fb9 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=8fd85b05-f545-4736-bd4d-1820e75cec4e 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=eab75295-c471-4127-8cce-bb37839c30c5 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=8dfb7a8c-7e2e-4c22-8278-9c521f35d318 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=e515e5c9-bdaf-4860-b4f9-657977684e2f 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=4e6f846c-6cde-46d9-a28b-ab9b47563a18 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=28aa2fb5-9d84-4e44-b1d5-66655dd0fcde 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=663f80f8-251d-4432-82d4-33b9022b7720 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=c4a06f33-9f44-4b07-b99e-2cc85a201169 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=d010aa42-feec-4289-aea0-b49aac1276be 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=74320cbf-6480-46c3-908c-bdde09c37c17 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）"]}
    | 服务端该行未变: amount=3 category=utility confidence=verified created_at=1792988608000 device_id=l2-dev-B factor_source=SRC-MEE-GHG factor_value=2.184 factor_version=CF-2026.2 id=06d68c8b-77a7-42f7-a823-39b395cac88d is_abnormal=0 is_deleted=0 note=时钟-B基准2 occurred_at=1792379255247 point_awarded=200 point_capped=1 reduction_kg=6.552 revision=0 sub_type=gas unit=m³ updated_at=1792988608000 user_id=u-489ad409da0648409bc2440038a6ea12
[PASS] #4.3 偏移超过 ±300000ms：响应带 clockWarning，且**照常继续合并**（该行仍被采纳）
    | offsetMs=600049（|offsetMs| > 300000）
    | clockWarning="客户端时钟与服务端相差 600.0 秒，超出 ±5 分钟容差；已按 offsetMs=600049 换算到服务端基准后继续合并（附录 B §6.4-6）"
    | 继续合并的证据（服务端该行已变成 A 的版本）: amount=120 category=utility confidence=provisional created_at=1792988668000 device_id=l2-dev-B factor_source=SRC-CALC factor_value=0.000168 factor_version=CF-2026.2 id=bad981ff-a0fb-4936-adb8-bdd55028de43 is_abnormal=0 is_deleted=0 note=时钟-A偏移超容差 occurred_at=1792379255247 point_awarded=2 point_capped=0 reduction_kg=0.0202 revision=1 sub_type=water unit=L updated_at=1792988788000 user_id=u-489ad409da0648409bc2440038a6ea12
[PASS] #4.4 服务端把该告警记进 sync_log（status=partial + error_msg），供 /sync/status 回显
    | 直查: SELECT direction,status,error_msg FROM sync_log ORDER BY started_at DESC LIMIT 3
    | sync_log: direction=pull status=success error_msg=null
    | sync_log: direction=push status=partial error_msg=客户端时钟与服务端相差 600.0 秒，超出 ±5 分钟容差；已按 offsetMs=600049 换算到服务端基准后继续合并（附录 B §6.4-6）
    | sync_log: direction=pull status=success error_msg=null
[PASS] #4.5 真链路取反换算（A 落后 5 分钟，不接代理）：push 握手腿 `offsetMs ≈ +300000` ⇒ `clientOffsetMs = -300000` ⇒ 对端时间戳换算后**显得更旧**（T4+120000-300000 = T4-180000 < T4）⇒ A 保留本机版本
    | 构造：本机=(updated_at=1792382936474, device_id=l2-dev-A, note=时钟-本机版)；服务端被夹具摆成=(updated_at=1792383056474, device_id=l2-dev-B, note=时钟-对端版)
    | 服务端构造后: amount=12 category=travel confidence=provisional created_at=1792382936474 device_id=l2-dev-B factor_source=SRC-DERIVED factor_value=0.152 factor_version=CF-2026.2 id=19bfdfb4-79a6-45b3-9a04-5061d8d9ad75 is_abnormal=0 is_deleted=0 note=时钟-对端版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=1.52 revision=0 sub_type=bus unit=km updated_at=1792383056474 user_id=u-489ad409da0648409bc2440038a6ea12
    | A 锚点（本机行不进上行）: {"last_sync_at":"1792382936475"}
    | A push 握手腿响应 offsetMs=300049（同上）
    | A pull 原始响应（**无** offsetMs 字段，hasOwnProperty=false）: {"ok":true,"data":{"serverTime":1792382877991,"since":1792382936475,"tables":{"carbon_record":[{"id":"85c1cf0d-ff05-4653-807c-013c50d215bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":1.0,"unit":"kg","occurred_at":1792379255247,"reduction_kg":0.9,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局3-源","created_at":1792382…（截断，全长 13106 字符）
    | A 库最终（应保留本机版本）: amount=10 category=travel confidence=provisional created_at=1792382936474 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.152 factor_version=CF-2026.2 id=19bfdfb4-79a6-45b3-9a04-5061d8d9ad75 is_abnormal=0 is_deleted=0 note=时钟-本机版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=1.52 revision=0 sub_type=bus sync_state=synced unit=km updated_at=1792382936474 user_id=u-489ad409da0648409bc2440038a6ea12
[PASS] #4.6 响应字段优先：代理把 pull 响应 offsetMs 强制为 0 ⇒ 客户端用响应值（不再用握手腿的 +300000）⇒ 对端 raw 更大 ⇒ A 采纳对端版本；同一构造在真链路（4.5）结论相反
    | A pull 原始响应（代理补了 offsetMs=0）: {"ok":true,"data":{"serverTime":1792382878669,"since":1792382936475,"tables":{"carbon_record":[{"id":"85c1cf0d-ff05-4653-807c-013c50d215bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":1,"unit":"kg","occurred_at":1792379255247,"reduction_kg":0.9,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局3-源","created_at":179238298…（截断，全长 13017 字符）
    | A 库最终: amount=12 category=travel confidence=provisional created_at=1792382936474 device_id=l2-dev-B factor_source=SRC-DERIVED factor_value=0.152 factor_version=CF-2026.2 id=19bfdfb4-79a6-45b3-9a04-5061d8d9ad75 is_abnormal=0 is_deleted=0 note=时钟-对端版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=1.52 revision=0 sub_type=bus sync_state=local unit=km updated_at=1792383056474 user_id=u-489ad409da0648409bc2440038a6ea12
    | 两向对照：同一时钟偏移下，4.5（真实响应无字段 ⇒ 用握手腿 +300000）保留本机、4.6（响应字段 0 ⇒ 不换算）采纳对端。若把取值写成 `optNum(data,"offsetMs") === undefined ? 0 : respOffset`（符号丢反）或直接丢掉握手腿回退，4.5/4.6 至少一条会翻面变红（见 run.sh 的 `--mutate=offset-drop` 变异趟）。
[PASS] #4.7 真实链路事实：直连服务端的 pull 响应**不含 `offsetMs`**（`SyncPullData` 就没有该字段）⇒ 客户端走**同一轮 push 握手腿**的 offsetMs（t62 修复，4.5 正是这条腿）；零偏移时该行按裸时间戳比较 ⇒ A 采纳对端那一版
    | A 锚点: {"last_sync_at":"1792382936475"}
    | 真实 pull 响应字段: ["serverTime","since","tables"]
    | 真实 pull 原始响应: {"ok":true,"data":{"serverTime":1792382879767,"since":1792382936475,"tables":{"carbon_record":[{"id":"85c1cf0d-ff05-4653-807c-013c50d215bf","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"recycle","sub_type":"paper","amount":1.0,"unit":"kg","occurred_at":1792379255247,"reduction_kg":0.9,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional"…（截断，全长 13106 字符）
    | 同一构造（服务端那一版 raw 更大）在真实链路上的实测后果: amount=12 category=travel confidence=provisional created_at=1792382936474 device_id=l2-dev-B factor_source=SRC-DERIVED factor_value=0.152 factor_version=CF-2026.2 id=19bfdfb4-79a6-45b3-9a04-5061d8d9ad75 is_abnormal=0 is_deleted=0 note=时钟-对端版 occurred_at=1792379255247 point_awarded=0 point_capped=1 reduction_kg=1.52 revision=0 sub_type=bus sync_state=local unit=km updated_at=1792383056474 user_id=u-489ad409da0648409bc2440038a6ea12（本次时钟零偏移 ⇒ `clientOffsetMs≈0` ⇒ 对端 raw 更大 ⇒ 覆盖本机；把时钟摆偏 5 分钟后结论翻面，见 4.5）
    | 影响面（t57 曾据此报 F2）：附录 B §5.3 的自证判据（`respOffsetMs = +60000 ⇒ 服务端 updatedAt = T 的行换算到客户端基准必须是 T − 60000`）要求客户端拿到 `offsetMs`；`SyncPullData` 里没有该字段，因此客户端必须从 push 握手腿取（t62 已实现：响应有字段优先、缺省回落握手腿）。
```

**结论**：✅ 通过。t57 时第 4 项只能证明"取反换算在真链路上不可达"（F2）；t62 的修法是**在客户端 `sync()` 里解析 push 响应的 `offsetMs`**（服务端与文档都没动），
于是 `#4.5` 变成了真链路的取反证据、`#4.7` 记录"pull 响应确实没有这个字段"这一事实；`#4.6` 用只补这一个字段的代理把"响应值优先"钉住。

> **口径张力（如实记录）**：任务书写「A 的 `clientNow` 故意偏移（如 +5 分钟）→ 断言服务端时间戳在 A 的基准上显得更旧」，
> 而附录 B §5.3 的自证判据是「`respOffsetMs = +60000` ⇒ 服务端 `updatedAt = T` 的行换算到客户端基准必须是 `T − 60000`（显得更旧）」。
> 两者方向互斥：要让服务端时间戳**显得更旧**，必须 `respOffsetMs > 0`，即**客户端时钟落后**服务端。按 AGENTS.md §1.2（附录 > 其余叙述性文字）以附录为准；
> 夹具把**两种符号都跑了**（`#4.1`/`#4.2` 落后与超前、`#4.5`/`#4.6` 两个方向），判定挂在附录口径上。

### 第 5 项：幂等（同一批 push 连推两次）

**断言**：① 复推不产生重复行（两端 + 服务端三处行数不变、库内无重复 id）；② `skipped = ignored + rejected` 三数自洽（附录 B §5.3）；
③ 服务端口径（省略 `clientNow` ⇒ `offsetMs=0`）重放 ⇒ `accepted=0`；④ 带 `clientNow` 重放（真实客户端就是这样）⇒ `accepted>0` 但**仍不新增行**。

```text
[PASS] #5.1 复推同一批**不产生重复行**：两端 + 服务端三处行数不变，库内无重复 id，且该行内容逐列不变
    | 第一次 push: {"ok":true,"data":{"accepted":14,"skipped":19,"ignored":0,"rejected":19,"conflicts":11,"serverTime":1792382868182,"offsetMs":63,"clockWarning":null,"acceptedByTable":{"carbon_record":7,"point_record":2,"user_goal":5},"merged":{"user_goal":[{"id":"9b02748e-9e85-4aa5-b998-15bbd3270e3d","user_id":"u-489ad409da0648409bc2440038a6ea12","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold…（截断，全长 7046 字符）
    | 重新标脏: ["carbon_record:ee977ff7-a5ff-40fc-b12e-ed6a908d4743"]
    | 第二次 push（同一批）: {"ok":true,"data":{"accepted":31,"skipped":0,"ignored":0,"rejected":0,"conflicts":31,"serverTime":1792382869287,"offsetMs":55,"clockWarning":null,"acceptedByTable":{"carbon_record":7,"user_goal":16,"user_badge":8},"merged":{},"errors":[]}}
    | 行数 A: 7 → 7；B: 7 → 7；服务端 carbon_record: 7 → 7
    | A 库重复 id: []；B 库重复 id: []
    | 该行内容差异（复推前后）: 无
[PASS] #5.2 三数自洽：`skipped = ignored + rejected`（附录 B §5.3）
    | 第二次 push 响应: {"ok":true,"data":{"accepted":31,"skipped":0,"ignored":0,"rejected":0,"conflicts":31,"serverTime":1792382869287,"offsetMs":55,"clockWarning":null,"acceptedByTable":{"carbon_record":7,"user_goal":16,"user_badge":8},"merged":{},"errors":[]}}
    | 解析: skipped=0 ignored=0 rejected=0
[PASS] #5.3 服务端口径：**省略 `clientNow`**（⇒ `offsetMs=0`）重放同一批 ⇒ `accepted=0`、`ignored>0`、`skipped=ignored+rejected` —— 附录 B §5.3 的"复推 accepted=0"成立
    | 重放 body 长度=10963（第 10963 字节…取本次 sync 的真实上行原文）
    | 直连探针（省略 clientNow）响应: {"ok":true,"data":{"accepted":0,"skipped":31,"ignored":31,"rejected":0,"conflicts":0,"serverTime":1792382869523,"offsetMs":0,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5.0,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792987648000,"updated_at":1792987648000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"68ff37ca-a3df-…（截断，全长 13343 字符）
[PASS] #5.4 同一份 body **带 `clientNow`** 重放（真实客户端就是这样）⇒ `offsetMs≠0`，服务端把同一批再判为 `accepted>0`（写回同值、不新增行）⇒ §5.3 的 `accepted=0` 以"两端同一时钟基准"为前提
    | 直连探针（原样，带 clientNow）响应: {"ok":true,"data":{"accepted":31,"skipped":0,"ignored":0,"rejected":0,"conflicts":31,"serverTime":1792382869486,"offsetMs":279,"clockWarning":null,"acceptedByTable":{"carbon_record":7,"user_goal":16,"user_badge":8},"merged":{},"errors":[]}}
    | 对比：带 clientNow → accepted=31 ignored=0 offsetMs=279；省略 clientNow → accepted=0 ignored=31 offsetMs=0
    | 机制：服务端比较的是 `remote_updated = values.updated_at + offset_ms`（sync_service.py:459），而落库的是客户端原始时间戳（:496-500）。只要 `offset_ms≠0`，重放同一行就会变成 `T+offset > T` ⇒ 判为"更新"。
[PASS] #5.5 两次重放之后行数依旧不变（既没有新增行、也没有被删）
    | 行数 A: 7 → 7；服务端 carbon_record: 7 → 7
```

**结论**：✅ 通过。`#5.3`/`#5.4` 一起把 §5.3 的 `accepted=0` 钉了个前提：它成立的条件是**两端同一时钟基准**；
真实客户端总是带 `clientNow`，此时服务端会把复推判成 `accepted>0`（**写回同值、不新增行**，幂等本身不破）。

### 第 6 项：软删除传播（A 删 → push → B pull → `is_deleted=1` 且行仍在）

**断言**：① B 侧收到软删除标记；② **行仍在表里**（不物理删）；③ 两端逐列一致且服务端也持软删行。

```text
[PASS] #6.1 B 侧收到软删除：is_deleted=1
    | 删除前 B 侧: is_deleted=0
    | remove 结果: {"step":"remove_record","deviceId":"l2-dev-A","clockOffsetMs":0,"ok":true,"code":"","message":"","device":"A","stepName":"remove_record"}
    | B pull 原始响应（该行）: [{"id":"afaeab28-4b25-479e-a475-3d13d0582697","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"bicycle","amount":4,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.768,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":77,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-待删","created_at":1792988448000,"updated_at":1792988508000,"is_deleted":1,"device_id":"l2-dev-A"}]
    | B 侧该行: amount=4 category=travel confidence=provisional created_at=1792988448000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=afaeab28-4b25-479e-a475-3d13d0582697 is_abnormal=0 is_deleted=1 note=L2-待删 occurred_at=1792379255247 point_awarded=77 point_capped=0 reduction_kg=0.768 revision=0 sub_type=bicycle sync_state=local unit=km updated_at=1792988508000 user_id=u-489ad409da0648409bc2440038a6ea12
[PASS] #6.2 行**仍在表里**（不物理删）：两端各恰有 1 行，且 uptate 走 DELETE+INSERT 也不减行数
    | A 侧该 id 行数=1
    | B 侧该 id 行数=1
    | B 侧该行: amount=4 category=travel confidence=provisional created_at=1792988448000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=afaeab28-4b25-479e-a475-3d13d0582697 is_abnormal=0 is_deleted=1 note=L2-待删 occurred_at=1792379255247 point_awarded=77 point_capped=0 reduction_kg=0.768 revision=0 sub_type=bicycle sync_state=local unit=km updated_at=1792988508000 user_id=u-489ad409da0648409bc2440038a6ea12
[PASS] #6.3 软删行两端逐列一致，且服务端也持软删行（不物理删）
    | A 库: amount=4 category=travel confidence=provisional created_at=1792988448000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=afaeab28-4b25-479e-a475-3d13d0582697 is_abnormal=0 is_deleted=1 note=L2-待删 occurred_at=1792379255247 point_awarded=77 point_capped=0 reduction_kg=0.768 revision=0 sub_type=bicycle sync_state=synced unit=km updated_at=1792988508000 user_id=u-489ad409da0648409bc2440038a6ea12
    | B 库: amount=4 category=travel confidence=provisional created_at=1792988448000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=afaeab28-4b25-479e-a475-3d13d0582697 is_abnormal=0 is_deleted=1 note=L2-待删 occurred_at=1792379255247 point_awarded=77 point_capped=0 reduction_kg=0.768 revision=0 sub_type=bicycle sync_state=local unit=km updated_at=1792988508000 user_id=u-489ad409da0648409bc2440038a6ea12
    | 差异列: 无
    | 服务端: amount=4 category=travel confidence=provisional created_at=1792988448000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=afaeab28-4b25-479e-a475-3d13d0582697 is_abnormal=0 is_deleted=1 note=L2-待删 occurred_at=1792379255247 point_awarded=77 point_capped=0 reduction_kg=0.768 revision=0 sub_type=bicycle unit=km updated_at=1792988508000 user_id=u-489ad409da0648409bc2440038a6ea12
```

**结论**：✅ 通过。客户端软删走 `RecordService.remove`（`is_deleted=1`、`updated_at=now`、**不 bump revision**），
服务端 LWW 对该行按普通更新处理；两端库内该 id 行数恒为 1（`#6.2` 同时校验了"客户端落库走 DELETE+INSERT 也不减行数"）。

### 第 7 项：冲突计数口径（`ignored` 不得计入 `conflicts`）

**断言**：① 纯去重批次（`accepted=0`、`ignored>0`）`conflicts=0` 且三数自洽；② 同一个 `conflicts` 计数器在"两端都改过同一行"的批次里确实 +1（第 2 项 B push）⇒ 7.1 不是"计数器坏了"造成的假绿。

```text
[PASS] #7.1 纯去重批次（`accepted=0`、`ignored>0`）`conflicts=0` 且 `skipped=ignored+rejected` ⇒ **ignored 没有被计入 conflicts**
    | 原始响应: {"ok":true,"data":{"accepted":0,"skipped":31,"ignored":31,"rejected":0,"conflicts":0,"serverTime":1792382869523,"offsetMs":0,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"1ee33bad-6380-495f-aae8-de3c42f3ad87","user_id":"u-489ad409da0648409bc2440038a6ea12","category":"travel","sub_type":"walk","amount":5.0,"unit":"km","occurred_at":1792379255247,"reduction_kg":0.96,"fac…（截断，全长 13343 字符）
    | accepted=0 ignored=31 rejected=0 conflicts=0 skipped=31 offsetMs=0
    | 反证：如果 `ignored` 被算进 `conflicts`，本批的 conflicts 至少等于 ignored（>0）——实测为 0。
[PASS] #7.2 同一个 `conflicts` 计数器在"两端都改过同一行"的批次里确实会 +1（第 2 项 B push）⇒ 7.1 不是"计数器坏了"造成的假绿
    | 第 2 项 B push（两端都改过同一行）conflicts=22
    | B push 原始响应: {"ok":true,"data":{"accepted":22,"skipped":2,"ignored":2,"rejected":0,"conflicts":22,"serverTime":1792382860396,"offsetMs":50,"clockWarning":null,"acceptedByTable":{"carbon_record":3,"user_goal":11,"user_badge":8},"merged":{},"errors":["point_record 业务唯一键 source_type='carbon_record', source_id='9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf#0', flow_kind='reverse'（user_id=u-489ad409da0648409bc2440038a6ea12） 已入账，跨设备重复已去重","point_record 业务唯一键 source_type='carbon_record', source_id='9b6d7e5f-7517-4a5b-b642-7ffc9cd0c0bf#1', flow_kind='primary'（user_id=u-489ad409da0648409bc2440038a6ea12） 已入账，跨设备重复已去重"]}}
    | 对照条件（服务端 sync_service.py:466-467）：`local_updated > last_sync_at and values.updated_at > last_sync_at`。
```

**结论**：✅ 通过。另记一条**观察（非判定项）**：服务端的冲突判定条件是
`local_updated > last_sync_at and int(values["updated_at"]) > last_sync_at`（`server/app/services/sync_service.py:466-467`），
其中后半句对任何"被上推的行"恒真 ⇒ 实际起作用的是前半句「服务端本机版本也在本轮同步窗口内被改过」，与附录 B §6.4-3 的「真冲突」定义一致。

## 3. 第 8 项：反证（不是假绿）

### 3.1 不设 `L1_ALLOW_NETWORK` 时，垫片必须拒绝出网

```text
[PASS] #8.1 不设 L1_ALLOW_NETWORK 时垫片拒绝出网（贴原始错误）；本任务全程在 L1_ALLOW_NETWORK=1 下跑真 HTTP
    | L1_ALLOW_NETWORK=(未设置)
    | 原始错误：离线执行（L1）不出网：拦截了对 http://127.0.0.1:38675/api/v1/config 的请求。L1 里网络必须由用例注入的假实现承担；若确需真网络，显式设 L1_ALLOW_NETWORK=1（这已不属于 L1 的范畴）。
    | 同一进程置 L1_ALLOW_NETWORK=1 时，上面的每一次 sync 都真的打到了 http://127.0.0.1:38675（见各步原始请求/响应）
```

### 3.2 变异自证：改一处**真实比较规则**必红，`git show` 还原必绿

变异点就是客户端平局判据（`app/entry/src/main/ets/viewmodel/net/SyncService.ets`，`applyRow` 的平局分支）：
`if (remoteDevice > localDevice) {` → `if (remoteDevice < localDevice) {`。**只改构建目录里的副本**，仓库文件一行不动；
还原用 `git show HEAD:<path>` 覆写副本 + `cmp` 逐字节校验 + `--skip-copy` **原处重转译**（**不用任何备份文件**）。

```text
-        if (remoteDevice > localDevice) {

+        if (remoteDevice < localDevice) {

```

```text
[FAIL] #3.1 对端 deviceId 字典序更大（l2-dev-Z > l2-dev-A / l2-dev-B）且两端 raw updated_at **完全相等** ⇒ 客户端平局分支采纳对端版本
    | 平局构造：本机 A=(updated_at=1792383486567, device_id=l2-dev-A, note=平局-A版) / 本机 B=(updated_at=1792383486567, device_id=l2-dev-B, note=平局-B版) / 服务端=(updated_at=1792383486567, device_id=l2-dev-Z, note=平局-Z版) —— 三方 raw 逐毫秒相等
    | 锚点（两端）: {"last_sync_at":"1792383486566"} / {"last_sync_at":"1792383486566"} —— 本机行 updated_at=1792383486567 > 1792383486566 ⇒ 会被 push（故需 ② 让服务端拒绝它）；服务端那一版同为 1792383486567 也被 pull 取回
    | A push 响应 offsetMs=-299935、rejected=20（本机时钟调快 300000ms ⇒ 握手腿回传 ≈ −300000 ⇒ 本机上行"比服务端旧"被拒，服务端那一版未被覆盖）
    | B push 响应 offsetMs=-299946、rejected=20
    | ③ 本轮 baseUrl 指向协议补全代理（forceOffsetMs=0）⇒ 客户端 clientOffsetMs = -0 = 0 ⇒ 按裸 raw 比较 ⇒ 与 raw 相等 ⇒ 命中平局分支
    | A 侧 set_row 回读: {"id":"02d73a79-f595-4614-9a68-9fa208cdd5cd","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","category":"recycle","sub_type":"aluminum","amount":5,"unit":"kg","occurred_at":1792379284922,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-A版","created_at":1792383486567,"updated_at":1792383486567,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"}
    | B 侧 set_row 回读: {"id":"02d73a79-f595-4614-9a68-9fa208cdd5cd","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","category":"recycle","sub_type":"aluminum","amount":7,"unit":"kg","occurred_at":1792379284922,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-B版","created_at":1792383486567,"updated_at":1792383486567,"is_deleted":0,"device_id":"l2-dev-B","sync_state":"pending"}
    | 服务端构造后: amount=42 category=recycle confidence=provisional created_at=1792383486567 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=02d73a79-f595-4614-9a68-9fa208cdd5cd is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379284922 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792383486567 user_id=u-08d756f1d6954b7aac6d868e84b6e4b8
    | A push: POST http://127.0.0.1:46653/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-08d756f1d6954b7aac6d868e84b6e4b8","deviceId":"l2-dev-A","lastSyncAt":1792383486566,"clientNow":1792383188940,"tables":{"carbon_record":[{"id":"02d73a79-f595-4614-9a68-9fa208cdd5cd","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","category":"recycle","sub_type":"aluminum","amount":5,"unit":"kg","occurred_at":1792379284922,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-A版","created_at":1792383486567,"updated_at":1792383486567,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"}],"point_record":[],"user_goal":[{"id":"6b00de09-f1…（截断，全长 6389 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":20,"ignored":0,"rejected":20,"conflicts":0,"serverTime":1792382889033,"offsetMs":-299935,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"02d73a79-f595-4614-9a68-9fa208cdd5cd","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","category":"recycle","sub_type":"aluminum","amount":42.0,"unit":"kg","occurred_at":1792379284922,"reduction_kg":18.0,"factor_value":9.0,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":1792383486567,"updated_at":1792383486567,"is_deleted":0,"device_id":"l2-dev-Z"}],"user_goal":[{"id":"6b00de09-f13e-450d-aea9-417112fb9c6b","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792383486567,"updated_at":1792383486567,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"74a44e84-6705-49fc-8d66-3c19a2967127","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","goal_id":"M1","period_key":"M:2026-10","progress":0.0,"threshold":100.0,"settled":0,"settled_at":null,"created_at":1792383486567,"updated_at":1792383486567,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"32f64b1e-032c-4e0c-82d3-6ca236393e3d","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","goal_id":"M2","period_key":"Q:2…（截断，全长 7551 字符）
    | B push: POST http://127.0.0.1:46653/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-08d756f1d6954b7aac6d868e84b6e4b8","deviceId":"l2-dev-B","lastSyncAt":1792383486566,"clientNow":1792383189375,"tables":{"carbon_record":[{"id":"02d73a79-f595-4614-9a68-9fa208cdd5cd","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","category":"recycle","sub_type":"aluminum","amount":7,"unit":"kg","occurred_at":1792379284922,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-B版","created_at":1792383486567,"updated_at":1792383486567,"is_deleted":0,"device_id":"l2-dev-B","sync_state":"pending"}],"point_record":[],"user_goal":[{"id":"6b00de09-f1…（截断，全长 6370 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":20,"ignored":0,"rejected":20,"conflicts":0,"serverTime":1792382889450,"offsetMs":-299946,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"02d73a79-f595-4614-9a68-9fa208cdd5cd","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","category":"recycle","sub_type":"aluminum","amount":42.0,"unit":"kg","occurred_at":1792379284922,"reduction_kg":18.0,"factor_value":9.0,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":1792383486567,"updated_at":1792383486567,"is_deleted":0,"device_id":"l2-dev-Z"}],"user_goal":[{"id":"6b00de09-f13e-450d-aea9-417112fb9c6b","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792383486567,"updated_at":1792383486567,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"74a44e84-6705-49fc-8d66-3c19a2967127","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","goal_id":"M1","period_key":"M:2026-10","progress":0.0,"threshold":100.0,"settled":0,"settled_at":null,"created_at":1792383486567,"updated_at":1792383486567,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"32f64b1e-032c-4e0c-82d3-6ca236393e3d","user_id":"u-08d756f1d6954b7aac6d868e84b6e4b8","goal_id":"M2","period_key":"Q:2…（截断，全长 7551 字符）
    | A 库: amount=5 category=recycle confidence=provisional created_at=1792383486567 device_id=l2-dev-A factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=02d73a79-f595-4614-9a68-9fa208cdd5cd is_abnormal=0 is_deleted=0 note=平局-A版 occurred_at=1792379284922 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=synced unit=kg updated_at=1792383486567 user_id=u-08d756f1d6954b7aac6d868e84b6e4b8
    | B 库: amount=7 category=recycle confidence=provisional created_at=1792383486567 device_id=l2-dev-B factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=02d73a79-f595-4614-9a68-9fa208cdd5cd is_abnormal=0 is_deleted=0 note=平局-B版 occurred_at=1792379284922 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=synced unit=kg updated_at=1792383486567 user_id=u-08d756f1d6954b7aac6d868e84b6e4b8
[FAIL] #3.2 两端最终行**逐列完全相同**（不是"服务端返回 accepted"就算），且与服务端那一份同一版本
    | A 库: amount=5 category=recycle confidence=provisional created_at=1792383486567 device_id=l2-dev-A factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=02d73a79-f595-4614-9a68-9fa208cdd5cd is_abnormal=0 is_deleted=0 note=平局-A版 occurred_at=1792379284922 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=synced unit=kg updated_at=1792383486567 user_id=u-08d756f1d6954b7aac6d868e84b6e4b8
    | B 库: amount=7 category=recycle confidence=provisional created_at=1792383486567 device_id=l2-dev-B factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=02d73a79-f595-4614-9a68-9fa208cdd5cd is_abnormal=0 is_deleted=0 note=平局-B版 occurred_at=1792379284922 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=synced unit=kg updated_at=1792383486567 user_id=u-08d756f1d6954b7aac6d868e84b6e4b8
    | 服务端: amount=42 category=recycle confidence=provisional created_at=1792383486567 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=02d73a79-f595-4614-9a68-9fa208cdd5cd is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379284922 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792383486567 user_id=u-08d756f1d6954b7aac6d868e84b6e4b8
    | 差异列: amount: A=5 B=7 ; device_id: A=l2-dev-A B=l2-dev-B ; note: A=平局-A版 B=平局-B版
[FAIL] #3.3 负向对照：对端 deviceId 更小（l2-dev-0 < l2-dev-A / l2-dev-B）且两端 raw updated_at 完全相等 ⇒ 两端各自保留本机版本，不采纳对端
    | 服务端构造后: amount=99 category=recycle confidence=provisional created_at=1792383789625 device_id=l2-dev-0 factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=89ffb384-4ee1-4071-a47a-4cabed2863ec is_abnormal=0 is_deleted=0 note=平局2-0版 occurred_at=1792379284922 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass unit=kg updated_at=1792383789625 user_id=u-08d756f1d6954b7aac6d868e84b6e4b8（与本机 raw 逐毫秒相等）
    | A push 响应 offsetMs=-299944、rejected=20
    | A 库（应保留本机）: amount=99 category=recycle confidence=provisional created_at=1792383789625 device_id=l2-dev-0 factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=89ffb384-4ee1-4071-a47a-4cabed2863ec is_abnormal=0 is_deleted=0 note=平局2-0版 occurred_at=1792379284922 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=local unit=kg updated_at=1792383789625 user_id=u-08d756f1d6954b7aac6d868e84b6e4b8
    | B 库（应保留本机）: amount=99 category=recycle confidence=provisional created_at=1792383789625 device_id=l2-dev-0 factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=89ffb384-4ee1-4071-a47a-4cabed2863ec is_abnormal=0 is_deleted=0 note=平局2-0版 occurred_at=1792379284922 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=local unit=kg updated_at=1792383789625 user_id=u-08d756f1d6954b7aac6d868e84b6e4b8
    | 注：这一支按规则"对端更小 ⇒ 保留本机"，两端各自留住自己那一版；它不是收敛用例，只用来证明比较方向（若把判据反转成"字典序小者胜"，A/B 都会变成平局2-0版 ⇒ 本条与 3.1 同时变红）。
```

```text
RESULT: checks=7 passed=4 failed=3   ← 变异后（必须非 0）
```

```text
① 原样复制真实源 : 65 个 .ets（逐文件 sha256 一致）
③ esbuild 转译   : 65 个 .ets → CJS
① 原样复制真实源 : 65 个 .ets（逐文件 sha256 一致）
③ esbuild 转译   : 65 个 .ets → CJS
   git show 还原后与仓库原件逐字节一致（cmp 通过）
   还原后 sha256 = 3aa6eea0c168befccf33b5e08c6a86336ea20b45a1434dbe4a9b30e8ff56e062
```

```text
RESULT: checks=7 passed=7 failed=0   ← git show 还原后（必须 0）
```

```text
[PASS] #3.1 对端 deviceId 字典序更大（l2-dev-Z > l2-dev-A / l2-dev-B）且两端 raw updated_at **完全相等** ⇒ 客户端平局分支采纳对端版本
    | 平局构造：本机 A=(updated_at=1792383496081, device_id=l2-dev-A, note=平局-A版) / 本机 B=(updated_at=1792383496081, device_id=l2-dev-B, note=平局-B版) / 服务端=(updated_at=1792383496081, device_id=l2-dev-Z, note=平局-Z版) —— 三方 raw 逐毫秒相等
    | 锚点（两端）: {"last_sync_at":"1792383496080"} / {"last_sync_at":"1792383496080"} —— 本机行 updated_at=1792383496081 > 1792383496080 ⇒ 会被 push（故需 ② 让服务端拒绝它）；服务端那一版同为 1792383496081 也被 pull 取回
    | A push 响应 offsetMs=-299919、rejected=20（本机时钟调快 300000ms ⇒ 握手腿回传 ≈ −300000 ⇒ 本机上行"比服务端旧"被拒，服务端那一版未被覆盖）
    | B push 响应 offsetMs=-299944、rejected=20
    | ③ 本轮 baseUrl 指向协议补全代理（forceOffsetMs=0）⇒ 客户端 clientOffsetMs = -0 = 0 ⇒ 按裸 raw 比较 ⇒ 与 raw 相等 ⇒ 命中平局分支
    | A 侧 set_row 回读: {"id":"e77358c1-597d-4f6e-9375-d764bc43218e","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","category":"recycle","sub_type":"aluminum","amount":5,"unit":"kg","occurred_at":1792379294436,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-A版","created_at":1792383496081,"updated_at":1792383496081,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"}
    | B 侧 set_row 回读: {"id":"e77358c1-597d-4f6e-9375-d764bc43218e","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","category":"recycle","sub_type":"aluminum","amount":7,"unit":"kg","occurred_at":1792379294436,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-B版","created_at":1792383496081,"updated_at":1792383496081,"is_deleted":0,"device_id":"l2-dev-B","sync_state":"pending"}
    | 服务端构造后: amount=42 category=recycle confidence=provisional created_at=1792383496081 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e77358c1-597d-4f6e-9375-d764bc43218e is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379294436 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792383496081 user_id=u-0c6a649df9a44f90a6ece9aeeee2f5af
    | A push: POST http://127.0.0.1:43273/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-0c6a649df9a44f90a6ece9aeeee2f5af","deviceId":"l2-dev-A","lastSyncAt":1792383496080,"clientNow":1792383198334,"tables":{"carbon_record":[{"id":"e77358c1-597d-4f6e-9375-d764bc43218e","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","category":"recycle","sub_type":"aluminum","amount":5,"unit":"kg","occurred_at":1792379294436,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-A版","created_at":1792383496081,"updated_at":1792383496081,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"}],"point_record":[],"user_goal":[{"id":"ef699bd3-b1…（截断，全长 6389 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":20,"ignored":0,"rejected":20,"conflicts":0,"serverTime":1792382898441,"offsetMs":-299919,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"e77358c1-597d-4f6e-9375-d764bc43218e","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","category":"recycle","sub_type":"aluminum","amount":42.0,"unit":"kg","occurred_at":1792379294436,"reduction_kg":18.0,"factor_value":9.0,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":1792383496081,"updated_at":1792383496081,"is_deleted":0,"device_id":"l2-dev-Z"}],"user_goal":[{"id":"ef699bd3-b1c9-4100-bcc0-ebbd24bbc443","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792383496081,"updated_at":1792383496081,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"e567f63a-bb6b-479e-9a02-89b77215203b","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","goal_id":"M1","period_key":"M:2026-10","progress":0.0,"threshold":100.0,"settled":0,"settled_at":null,"created_at":1792383496081,"updated_at":1792383496081,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"7d52ecfb-e97a-4c06-9420-7c0693673a2f","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","goal_id":"M2","period_key":"Q:2…（截断，全长 7551 字符）
    | B push: POST http://127.0.0.1:43273/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-0c6a649df9a44f90a6ece9aeeee2f5af","deviceId":"l2-dev-B","lastSyncAt":1792383496080,"clientNow":1792383198735,"tables":{"carbon_record":[{"id":"e77358c1-597d-4f6e-9375-d764bc43218e","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","category":"recycle","sub_type":"aluminum","amount":7,"unit":"kg","occurred_at":1792379294436,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-B版","created_at":1792383496081,"updated_at":1792383496081,"is_deleted":0,"device_id":"l2-dev-B","sync_state":"pending"}],"point_record":[],"user_goal":[{"id":"ef699bd3-b1…（截断，全长 6370 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":20,"ignored":0,"rejected":20,"conflicts":0,"serverTime":1792382898813,"offsetMs":-299944,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"e77358c1-597d-4f6e-9375-d764bc43218e","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","category":"recycle","sub_type":"aluminum","amount":42.0,"unit":"kg","occurred_at":1792379294436,"reduction_kg":18.0,"factor_value":9.0,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":1792383496081,"updated_at":1792383496081,"is_deleted":0,"device_id":"l2-dev-Z"}],"user_goal":[{"id":"ef699bd3-b1c9-4100-bcc0-ebbd24bbc443","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792383496081,"updated_at":1792383496081,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"e567f63a-bb6b-479e-9a02-89b77215203b","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","goal_id":"M1","period_key":"M:2026-10","progress":0.0,"threshold":100.0,"settled":0,"settled_at":null,"created_at":1792383496081,"updated_at":1792383496081,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"7d52ecfb-e97a-4c06-9420-7c0693673a2f","user_id":"u-0c6a649df9a44f90a6ece9aeeee2f5af","goal_id":"M2","period_key":"Q:2…（截断，全长 7551 字符）
    | A 库: amount=42 category=recycle confidence=provisional created_at=1792383496081 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e77358c1-597d-4f6e-9375-d764bc43218e is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379294436 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792383496081 user_id=u-0c6a649df9a44f90a6ece9aeeee2f5af
    | B 库: amount=42 category=recycle confidence=provisional created_at=1792383496081 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e77358c1-597d-4f6e-9375-d764bc43218e is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379294436 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792383496081 user_id=u-0c6a649df9a44f90a6ece9aeeee2f5af
[PASS] #3.2 两端最终行**逐列完全相同**（不是"服务端返回 accepted"就算），且与服务端那一份同一版本
    | A 库: amount=42 category=recycle confidence=provisional created_at=1792383496081 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e77358c1-597d-4f6e-9375-d764bc43218e is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379294436 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792383496081 user_id=u-0c6a649df9a44f90a6ece9aeeee2f5af
    | B 库: amount=42 category=recycle confidence=provisional created_at=1792383496081 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e77358c1-597d-4f6e-9375-d764bc43218e is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379294436 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792383496081 user_id=u-0c6a649df9a44f90a6ece9aeeee2f5af
    | 服务端: amount=42 category=recycle confidence=provisional created_at=1792383496081 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e77358c1-597d-4f6e-9375-d764bc43218e is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792379294436 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792383496081 user_id=u-0c6a649df9a44f90a6ece9aeeee2f5af
    | 差异列: 无
[PASS] #3.3 负向对照：对端 deviceId 更小（l2-dev-0 < l2-dev-A / l2-dev-B）且两端 raw updated_at 完全相等 ⇒ 两端各自保留本机版本，不采纳对端
    | 服务端构造后: amount=99 category=recycle confidence=provisional created_at=1792383798994 device_id=l2-dev-0 factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=1007c303-85d3-49d0-9adf-ad2756bf3265 is_abnormal=0 is_deleted=0 note=平局2-0版 occurred_at=1792379294436 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass unit=kg updated_at=1792383798994 user_id=u-0c6a649df9a44f90a6ece9aeeee2f5af（与本机 raw 逐毫秒相等）
    | A push 响应 offsetMs=-299950、rejected=20
    | A 库（应保留本机）: amount=4 category=recycle confidence=provisional created_at=1792383798994 device_id=l2-dev-A factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=1007c303-85d3-49d0-9adf-ad2756bf3265 is_abnormal=0 is_deleted=0 note=平局2-A版 occurred_at=1792379294436 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=synced unit=kg updated_at=1792383798994 user_id=u-0c6a649df9a44f90a6ece9aeeee2f5af
    | B 库（应保留本机）: amount=6 category=recycle confidence=provisional created_at=1792383798994 device_id=l2-dev-B factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=1007c303-85d3-49d0-9adf-ad2756bf3265 is_abnormal=0 is_deleted=0 note=平局2-B版 occurred_at=1792379294436 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=synced unit=kg updated_at=1792383798994 user_id=u-0c6a649df9a44f90a6ece9aeeee2f5af
    | 注：这一支按规则"对端更小 ⇒ 保留本机"，两端各自留住自己那一版；它不是收敛用例，只用来证明比较方向（若把判据反转成"字典序小者胜"，A/B 都会变成平局2-0版 ⇒ 本条与 3.1 同时变红）。
```

**结论**：✅ 反证成立。变异后第 3 项三条断言全部变红（同组另外 4 条与平局无关的仍绿 ⇒ 变异是"定点"的），
`git show` 还原后同一组全绿 ⇒ 断言确实咬在被测实现上，不是恒真式。

### 3.3 全程零改动（`app/` 一行都没碰）

```text
== 7. 零改动核对（app/ tests/cases/ tests/tools/l1_offline/；server/ docs/ 并行 agent 的改动单列） ==
   干净：app/、tests/cases/、tests/tools/l1_offline/ 零改动（这三处是本任务最该证明没碰的）
   本任务自身产物（未提交则显示为 ??）： M tests/tools/l2_sync/README.md  M tests/tools/l2_sync/lib/device.mjs  M tests/tools/l2_sync/lib/l2_run.mjs  M tests/tools/l2_sync/lib/proxy.mjs
   跑完后 app/**/*.ets 全量 sha256 指纹 = cab20a454a901eb641f7400a177a061b024640e6eeb062109d14a8c0fd57e857
   指纹一致 ⇒ 全程未碰 app/**
```

```text
① 原样复制真实源 : 跳过（--skip-copy，沿用构建目录里的副本）
① 原样复制真实源 : 跳过（--skip-copy，沿用构建目录里的副本）
① 原样复制真实源 : 跳过（--skip-copy，沿用构建目录里的副本）
① 原样复制真实源 : 跳过（--skip-copy，沿用构建目录里的副本）
① 原样复制真实源 : 跳过（--skip-copy，沿用构建目录里的副本）
① 原样复制真实源 : 65 个 .ets（逐文件 sha256 一致）
② 原样复制垫片   : 9 个（来自 tests/tools/l1_offline/platform/，未改一行）
③ esbuild 转译   : 65 个 .ets → CJS
```

### 3.4 t62 修复现场与其余三段门禁

**F1（t57 曾报 blocker）→ `#0.2`/`#8.3`**：修复点是 `SyncService.ets` 的 `RowClaim`——认领本机行不再只按 `id`，
而是**单例表按 `user_id` / 有业务键的表按 `(user_id, 业务键)` / 其余按 `id`**（与 `server/app/services/sync_service.py` 的
`_find_business_key_row` 同规则），覆盖时删的是**本机那一行的 id**，`insertRow` 用 `INSERT OR IGNORE` 兜底并把被丢弃的行计 `skipped`。
`#8.3` 用**全新设备 C**（第三个库文件、`since=0`）取证：首同步成功、该表仍恰一行。

```text
[PASS] #8.3 F1 修复现场（t57 曾报 blocker）：全新设备 C 的**首同步**（since=0）不再撞 uq_ua/uq_uprofile —— 客户端 pull 侧按 user_id 认领单例行（删本机旧行 + 写入远端行），本机仍只有一行
    | C 是全新库（deviceId=l2-dev-C，库=/tmp/cbl2-1NGY5t/roots-main/C/databases/carbonboo.db.db），账号与 A/B 相同
    | C 本机首同步前: user_profile={"id":"fa669db8-6ffd-4d88-bd95-97a6a3d1eb4c","updated_at":1792382880198,"device_id":"l2-dev-C"}，user_appearance={"id":"13aced1c-0b88-4cbb-9b4b-3526b55540aa","updated_at":1792382880198,"device_id":"l2-dev-C"}（id 由本机 IdUtil.uuid() 生成，与 A/B 都不同）
    | 服务端 user_appearance: [{"id":"0547e455-85b9-4240-9696-9e6cc8ed97d5","user_id":"u-489ad409da0648409bc2440038a6ea12","updated_at":"1792382855482"}]
    | C 首同步 ok=true，errorString=undefined
    | C 本机首同步后: user_appearance=[{"id":"13aced1c-0b88-4cbb-9b4b-3526b55540aa","user_id":"u-489ad409da0648409bc2440038a6ea12","device_id":"l2-dev-C","updated_at":1792382880198}]，user_profile=[{"id":"fa669db8-6ffd-4d88-bd95-97a6a3d1eb4c","user_id":"u-489ad409da0648409bc2440038a6ea12","device_id":"l2-dev-C","updated_at":1792382880198}]（各 1 行，id 收敛到服务端那一版）
    | 修复前本条为红：pull 侧只按 `WHERE id = ?` 认领本机行，找不到就 INSERT（无 OR IGNORE）⇒ `UNIQUE constraint failed: user_appearance.user_id`（t57 夹具第 8.3 节的原始栈；t62 起改为按 user_id 认领）。
    | 同族单例/业务键表：user_profile、user_appearance、user_goal、user_badge、user_purchase、science_progress。
```

**F3（t57 曾报 high）→ `#8.4`**：两端都走真实 `records.edit` ⇒ 各自落出**同业务键不同 id** 的 `point_record`（append_only）流水，
pull 侧现在按业务唯一键认领 ⇒ 行数与内容逐列不变、本机无重复业务键、不再撞 `uq_pr_source`。

```text
[PASS] #8.4 F3 修复现场（t57 曾报 high）：两端都走真实 `records.edit` ⇒ 各自落出**同业务键不同 id** 的 point_record 流水 ⇒ pull 侧按业务唯一键认领（不再撞 uq_pr_source）：行数与内容逐列不变、本机无重复业务键、业务键集合与服务端一致
    | A 真实编辑（RecordService.ets 的 records.edit）：{"recordId":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd","reductionKg":0.81,"pointExpected":81,"pointAwarded":81,"capped":false,"isAbnormal":false,"newGoals":[],"newBadges":[],"goalPoints":0}
    | B 真实编辑：{"recordId":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd","reductionKg":0.972,"pointExpected":97,"pointAwarded":97,"capped":false,"isAbnormal":false,"newGoals":[],"newBadges":[],"goalPoints":0}
    | 服务端 point_record（该记录）: [{"id":"0ad2c161-85c7-4fd6-a425-edb8e9a89f79","source_id":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd#0","flow_kind":"primary","points":"65"},{"id":"1b655131-2bf4-47b5-981e-5230d5123362","source_id":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd#0","flow_kind":"reverse","points":"-65"},{"id":"221ddc81-805b-48bf-add7-f39533972e34","source_id":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd#1","flow_kind":"primary","points":"81"}]
    | B 本机 point_record 同步前: [{"id":"0ad2c161-85c7-4fd6-a425-edb8e9a89f79","source_id":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd#0","flow_kind":"primary","points":65},{"id":"0319da08-c570-49bd-9b0a-bb3d52db2968","source_id":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd#0","flow_kind":"reverse","points":-65},{"id":"a56b50ba-fb16-418b-a52a-aee4d2d6945a","source_id":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd#1","flow_kind":"primary","points":97}]
    | B 本机 point_record 同步后（行数不变=true，业务键不重复=true）: [{"id":"0ad2c161-85c7-4fd6-a425-edb8e9a89f79","source_id":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd#0","flow_kind":"primary","points":65},{"id":"0319da08-c570-49bd-9b0a-bb3d52db2968","source_id":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd#0","flow_kind":"reverse","points":-65},{"id":"a56b50ba-fb16-418b-a52a-aee4d2d6945a","source_id":"18b3c7a4-66eb-46b9-89f0-5c5d573193bd#1","flow_kind":"primary","points":97}]
    | B 同步 ok=true，errorString=undefined
    | 业务键集合一致=true；本机无重复业务键=true；内容逐列不变=true
    | **口径**：两端同一业务键下的 points 可以不同（B=97 vs 服务端=81）—— append_only 表按业务键去重且"先到者留"，两端各自保留本机那一版；本条**不断言**积分合计相等，只断言契约要求的"不插第二行、不 UPDATE、行数内容不变"。
    | 修复前本条为红：pull 侧只按 `id` 判重（旧 SyncService.ets:641-643）⇒ 服务端那一版业务键已在 B 本机存在但 id 不同 ⇒ 直接 INSERT ⇒ `UNIQUE constraint failed: point_record`（t57 夹具第 8.4 节原始栈）。t62 起 pull 侧对带业务唯一键的表（point_record / user_goal / user_badge / user_purchase / science_progress）按业务键认领。
    | 口径说明：`point_record` 是 append_only 表，服务端语义也是"同业务键即去重"（server/app/services/sync_service.py 的 `_merge_append_only`），所以两端**行 id 可以不同**（各自保留本机那一版），本条断的是业务键集合 + 积分合计一致、且本机不出现重复业务键。
```

**F2（t57 曾报 high）→ `#4.5`/`#4.7`**：见第 4 项（客户端改从 **push 响应**取 `offsetMs` 并取反；服务端与文档未动）。

**L1 单测门禁**（`bash tests/tools/l1_offline/run_tests.sh`，离线转译后在 Node 里跑）：

```text
PASS  [LwwMerge] ⑪ 单例表按 user_id 认领：远端 user_appearance 同 user_id、不同 id → 删本机旧行后写入（不再撞 uq_ua）  (6 ms)
PASS  [LwwMerge] ⑫ 业务键按 (goal_id, period_key) 认领：远端 user_goal 同业务键、不同 id → 收敛为 1 行  (6 ms)
PASS  [LwwMerge] ⑮ 只增表去重：远端 point_record 同业务键、不同 id → 去重丢弃（不 UPDATE、不再撞 uq_pr_source）  (6 ms)
PASS  [LwwMerge] ⑬ 握手校正：push 响应带 offsetMs、pull 响应无该字段（真实服务端形状，§5.3:855）→ 校正生效  (13 ms)
PASS  [LwwMerge] ⑭ 取值优先级：pull 响应自带 offsetMs 时以响应为准（仍取反），不被握手值顶掉  (10 ms)
RESULT: it_executed=41 passed=41 failed=0 requires_device=0
RESULT: PASS
```

**L1 纯逻辑门禁**（`bash tests/tools/l1_offline/run.sh`）与**文档基准门禁**（`python3 tests/tools/check_l0.py --strict`）：

```text
RESULT: PASS=55 FAIL=0
summary = 全部一致：共复算 323 个断言点
RUN.SH: 全部 PASS（离线纯逻辑部分）
```

```text
扫描文件：89    命中：0
L0-3 人工待修清单（tests/cases/carbon-calc.json → docConflicts）：0 条
结论：PASS —— 基准自洽，文档无已知冲突
```

**编译门禁成对自证**（`cd app && hvigorw --no-daemon assembleHap`）：基线 `BUILD SUCCESSFUL` →
在 `SyncService.ets` 的有效代码区注入一个未定义引用 ⇒ **`BUILD FAILED`** →
`git show HEAD:<path>` 还原（sha256 与还原前**逐字节一致**）⇒ 重新构建 `BUILD SUCCESSFUL`。

```text
> hvigor BUILD SUCCESSFUL in 34 s 685 ms
——
> hvigor ERROR: ArkTS Compiler Error
1 ERROR: ArkTS:ERROR File: /mnt/c/Users/Administrator/Desktop/CarbonBoo/app/entry/src/main/ets/viewmodel/net/SyncService.ets:238:12
> hvigor ERROR: BUILD FAILED in 22 s 343 ms
——
sha256（注入前） = 3aa6eea0c168befccf33b5e08c6a86336ea20b45a1434dbe4a9b30e8ff56e062
sha256（git show 还原后） = 3aa6eea0c168befccf33b5e08c6a86336ea20b45a1434dbe4a9b30e8ff56e062
——
> hvigor BUILD SUCCESSFUL in 35 s 305 ms
```

**F1 / F2 的「移除传递必须变红」成对自证**（L1 单测层，`L1_ONLY=LwwMerge` 只跑这一个 suite）。
两处都只用 `sed` 临时改动 `app/entry/src/main/ets/viewmodel/net/SyncService.ets`，再用 **`git show HEAD:<path>`** 覆写还原、
`sha256sum` 比对逐字节一致（**没有用任何备份文件**；规则见任务书与 AGENTS §5.1）：

| 变异 | 改的是什么 | 变异后（必须红） | `git show` 还原后（必须绿） |
|---|---|---|---|
| M1（F1 现场） | `RowClaim.of` 退回「只按 `id` 认领本机行」——单例分支与业务键分支都关掉 | `RESULT: it_executed=15 passed=12 failed=3`，红的正是 **⑪⑫⑮** | `passed=15 failed=0` |
| M2（F2 现场） | `applyPull` 的 `offsetMsClient` 退回「不接握手腿」（`respOffset === undefined ? 0 : -respOffset`） | `RESULT: it_executed=15 passed=14 failed=1`，红的正是 **⑬** | `passed=15 failed=0` |

M1 变异点（`RowClaim.of` 里被关掉的两个分支）：

```text

207:    if (false) {
210:    const keys: string[] | undefined = undefined;
```

```text

FAIL  [LwwMerge] ⑪ 单例表按 user_id 认领：远端 user_appearance 同 user_id、不同 id → 删本机旧行后写入（不再撞 uq_ua）  (4 ms)
FAIL  [LwwMerge] ⑫ 业务键按 (goal_id, period_key) 认领：远端 user_goal 同业务键、不同 id → 收敛为 1 行  (4 ms)
FAIL  [LwwMerge] ⑮ 只增表去重：远端 point_record 同业务键、不同 id → 去重丢弃（不 UPDATE、不再撞 uq_pr_source）  (4 ms)
RESULT: it_executed=15 passed=12 failed=3 requires_device=26
```

`git show HEAD:` 还原后的复跑：

```text

RESULT: it_executed=15 passed=15 failed=0 requires_device=26
```

M2 变异点：

```text

710:    const offsetMsClient: number = respOffset === undefined ? 0 : -respOffset;
```

```text

FAIL  [LwwMerge] ⑬ 握手校正：push 响应带 offsetMs、pull 响应无该字段（真实服务端形状，§5.3:855）→ 校正生效  (8 ms)
RESULT: it_executed=15 passed=14 failed=1 requires_device=26
```

`git show HEAD:` 还原后的复跑：

```text

RESULT: it_executed=15 passed=15 failed=0 requires_device=26
```

> `L1_ONLY` 过滤下 `RESULT` 行里的 `requires_device=` 计的是「未参与本轮过滤的其它 suite 条数」（runner 自己的计数口径），与被判失败无关；
> 判定只看 `passed`/`failed`。四段门禁里的全套跑（不过滤）是 `it_executed=41 passed=41 failed=0 requires_device=0`。

## 4. 覆盖 / 不覆盖边界

**本任务验的是「协议级两端收敛」**：两个独立客户端库 + 真服务端 + 真 HTTP，把附录 B §6 的合并规则跑成两端结论一致的证据。

**不能替代真机 L2**，具体不覆盖：

| 不覆盖 | 原因 |
|---|---|
| UI 与交互（录入向导、协同页、待同步数展示） | `pages/`、`components/` 是 ArkUI `struct`，esbuild 不转译；L2 夹具也不改这些 |
| Ability 生命周期（冷启/前后台/进程被杀后恢复、`onCreate` 引导顺序） | 夹具直接调用 Service 层，不跑 `EntryAbility` |
| 端侧权限（网络权限、`WRITE_IMAGEVIDEO` 等）与真机 `relationalStore` 实现细节 | 夹具用 `node:sqlite` 顶替 `relationalStore` 垫片；权限/沙箱行为在真机上才有 |
| 真机系统时间/时区行为（用户改系统时间、跨时区） | 夹具用时钟偏移模拟"设备时钟不准"（等价于该场景，但不是系统级行为） |
| 鸿蒙近场/分布式通路（`discover()` / `nearFieldSync()` / 已配对设备） | 需要真机与分布式软总线；本任务只覆盖**云通路**（账号 + HTTP 同步） |
| 多设备并发（>2 台同时同步）与网络中断重试 | 夹具是两台设备**依次**同步；并发/断网重连属服务端压测范畴（另有 t61 的并发工具） |

## 5. 复现与收工清理

### 5.1 复现（一条命令）

```bash
cd /mnt/c/Users/Administrator/Desktop/CarbonBoo
bash tests/tools/l2_sync/run.sh          # 退出码 0=全过 / 1=有失败 / 2=环境不可达
```

```text
== 8. 汇总 ==
   主用例（八项全跑）        退出码 0（0=全过）
   变异（平局判据反转）     退出码 1（须非 0）
   git show 还原后复跑           退出码 0（须 0）
   app/ tests/cases/ l1_offline 零改动 是
   app/**/*.ets 指纹                未变
RESULT: 全部通过（八项断言 + 两条反证）
```

### 5.2 收工清理（run.sh 自动做）

```text
== 收工清理 ==
   已停 uvicorn（pid=1365670）
   已删除任务专用库 carbonboo_l2_e2e
   原始输出已留档到 /tmp/l2run2/evidence（排障/写报告用；默认不留）
   已删除临时目录 /tmp/cbl2-1NGY5t
   退出码=0
RUNSH_EXIT=0
```

清理项：① 停掉自己起的 uvicorn（只停本任务端口那个 pid，不 `pkill` 别人的）；② 删除任务专属库 `carbonboo_l2_e2e`（**不动共享库 `carbonboo`、不动别人的 `carbonboo_test_*`**）；
③ 删除 `mktemp -d` 出来的临时目录（构建产物、两台设备的 `databases/`、wire 日志）；④ `carbonboo-mysql` 容器是共享的，**不停**。

### 5.3 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 八项断言全过 + 两条反证成立 |
| 1 | 有断言失败（或变异未变红 / 还原未变绿） |
| 2 | 环境不可达（Node < 22.5 无 `node:sqlite` / 无 esbuild / docker 或 `carbonboo-mysql` 不可用 / 无 `server/.venv`） |

## 6. 未运行项（如实单列）

| 未运行 | 原因 | 现状 |
|---|---|---|
| 真机 hypium 单测执行（`hdc` 跑到设备/模拟器上） | 本机无 `hdc`、无模拟器、`/dev/kvm` 不可写 | 执行数 **0**；§3.4 的 41 条是**离线转译后在 Node 里跑**的，**不等于真机通过** |
| 端侧真机 L2（两条真机跑协同脚本：UI + 生命周期 + 权限 + 近场） | 同上（物理不可达） | 未运行；本报告用协议级夹具替代，边界见 §4 |
| 服务端 L3 pytest 全量 | 属服务端任务范围（本任务只读 `server/**`） | 未在本任务内运行 |
