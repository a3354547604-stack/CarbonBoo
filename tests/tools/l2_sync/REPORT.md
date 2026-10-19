# tests/tools/l2_sync REPORT —— 「L2 双设备协同」协议级端到端验证实测报告

- **交付**：`tests/tools/l2_sync/`（`run.sh` + `lib/build.mjs` / `lib/device.mjs` / `lib/l2_run.mjs` / `lib/proxy.mjs` + 本报告 + `README.md`）
- **被测对象**：`app/entry/src/main/ets/viewmodel/net/SyncService.ets`（客户端同步实现）与 `server/app/**`（真服务端）——**一行都没改**
- **实测命令**：`bash tests/tools/l2_sync/run.sh` → **退出码 0**
- **日期**：2026-10-19 ｜ 跑测机：本机 WSL（无 hdc、无模拟器、`/dev/kvm` 不可写 ⇒ 真机 L2 物理不可达）

> **一句话结论**：用**两个独立客户端的真 SQLite 库 + 真 FastAPI 服务端 + 真 HTTP**，把附录 B §6 的「两端用同一规则、结论一致」
> 跑成了可复现证据——**35 条断言全过**，并完成两条反证（出网必须被拒；把客户端平局判据反转必须变红、`git show` 还原必须变绿）。
> **它验的是协议级两端收敛，不能替代真机 L2**（边界见 §5）。

## 0. 结论速览

| # | 验收项 | 判定 | 一句话证据 |
|---|---|---|---|
| 1 | 基线往返 | ✅ | A 真录入（`RecordService.save`→`CarbonService.calculate`）→ push → **另一个库/另一个 deviceId** 的 B pull → 逐列相同，四字段因子快照一致（`#1.2`/`#1.3`） |
| 2 | LWW 收敛 | ✅ | 两端各改一版 → 依次 push/pull → **两库最终行逐列完全相同**，胜者 = `updated_at` 大者（`#2.2`/`#2.3`），旧版上行被 rejected（`#2.4`） |
| 3 | 平局按 `deviceId` | ✅ | `updated_at` 完全相等时字典序大者胜、两端一致（`#3.1`/`#3.2`）；负向对照 + 服务端同规则（`#3.3`/`#3.4`） |
| 4 | 时钟偏移取反 | ✅（含事实发现） | `offsetMs = 服务端 − 客户端` 两向对照（`#4.1`/`#4.2`）；`clientOffsetMs = −respOffsetMs` 两向对照（`#4.5`/`#4.6`）；超 ±300000ms 告警但继续合并（`#4.3`/`#4.4`）；**真实 pull 响应不含 `offsetMs` ⇒ 取反换算在真链路上不可达**（`#4.7`，见发现 F2） |
| 5 | 幂等 | ✅ | 同一批连推两次不产生重复行、行数三处不变（`#5.1`/`#5.5`）；`skipped = ignored + rejected` 三数自洽（`#5.2`）；口径前提见 `#5.3`/`#5.4` |
| 6 | 软删除传播 | ✅ | B 侧 `is_deleted=1` 且**行仍在表里**（两端各恰 1 行，`#6.2`），服务端同样持软删行（`#6.3`） |
| 7 | 冲突计数口径 | ✅ | 纯去重批次 `ignored>0` 而 `conflicts=0`（`#7.1`），同一计数器在真冲突批次确实 +1（`#7.2`）⇒ 不是"计数器坏了"的假绿 |
| 8 | 反证不是假绿 | ✅ | 不设 `L1_ALLOW_NETWORK` 时垫片拒绝出网并给出原始错误（`#8.1`）；变异自证三趟（§3.2） |

## 1. 被验对象、机制与基准

### 1.1 机制（为什么这些证据可信）

1. **不重写实现**：`lib/build.mjs` 把 `app/entry/src/main/ets/{service,util,data,model,viewmodel}` 的真实 `.ets`
   **原样复制**到临时构建目录（逐文件 sha256 校验），再用 esbuild（`~/harmony-toolchain/esbuild/bin/esbuild` 0.28.2）
   转成 CJS；只重写平台说明符到 `tests/tools/l1_offline/platform/` 的 9 个垫片（垫片也逐字节复制、未改一行）。
   **仓库里的 `SyncService.ets` 与构建副本 sha256 相同**（见 §3.3）。
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
   服务端端口: 127.0.0.1:32785
== 2. 建任务专用库并灌 schema/seed ==
   库 carbonboo_l2_e2e 就绪：21 张表
```

### 1.3 运行规模

- 八项 = **35 条断言**（`RESULT: checks=35 passed=35 failed=0`）；两台设备进程、两个独立库文件、真 HTTP 请求全程落 `wire-main.log`（约 1 MB）。
- 分组可单跑：`L2_ONLY=baseline|lww|tie|idem|delete|conflict-count|clock|negative bash tests/tools/l2_sync/run.sh`
  （下面每一项的"实测命令"都是这条；本报告引用的是**八项全跑**那一趟的原始输出）。

## 2. 逐项实测（断言 / 实测命令 / 原始输出 / 结论）

### 第 1 项：基线往返（A 写 → push → B pull → 逐列相同）

**实测命令**：`bash tests/tools/l2_sync/run.sh`（`L2_ONLY=baseline` 单跑同源）

**断言**：① 两台设备各自独立落库并登录同一账号；② A 走**真实录入链路**落两条 `carbon_record`（带 `factor_value/factor_version/factor_source/confidence` 四字段快照）；
③ B 的库里出现**逐列相同**的同名行（排除仅端侧的 `sync_state`）；④ 服务端直查一致；⑤ `point_record` 也随同一次同步往返。

```text
[PASS] #0.1 两台设备各自独立落库（不同库文件、不同 deviceId），用同一账号在真服务端登录拿到 token
    | A: via=register userId=u-df7db19f6ec14d348457b6bdc1a3618e deviceId=l2-dev-A token长度=369 isLoggedIn=true
    | B: via=login userId=u-df7db19f6ec14d348457b6bdc1a3618e deviceId=l2-dev-B token长度=369 isLoggedIn=true
    | A 库文件=/tmp/cbl2-R5KLR3/roots-main/A/databases/carbonboo.db.db
    | B 库文件=/tmp/cbl2-R5KLR3/roots-main/B/databases/carbonboo.db.db
    | A 账号态={"accountUserId":"u-df7db19f6ec14d348457b6bdc1a3618e","loginName":"u-df7db19f6ec14d348457b6bdc1a3618e\nl2dev_1792381003","loggedIn":true}
    | A 的认证请求（最后一条）→ POST http://127.0.0.1:32785/api/v1/auth/register → HTTP 201
      req:  {"username":"l2dev_1792381003","password":"l2-pass-123"}
      resp: {"ok":true,"data":{"userToken":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1LWRmN2RiMTlmNmVjMTRkMzQ4NDU3YjZiZGMxYTM2MThlIiwidXNlcm5hbWUiOiJsMmRldl8xNzkyMzgxMDAzIiwiYXVkIjoiY2FyYm9uYm9vLWNsaWVudCIsImlzcyI6ImNhcmJvbmJvby1zZXJ2ZXIiLCJpYXQiOjE3OTIzODEwMTAsIm5iZiI6MTc5MjM4MTAxMCwiZXhwIjoxNzkyOTg1ODEwLCJqdGkiOiJlZDQyMDU0MTlkZWE0MTE0OGE2ZTg0NmU3YWQ4ODI4ZCJ9.j9ASj67_8J0uQiBkbNGWI_s-FPb0CceNH73WM3WVqv0","userId":"u-df7db19f6ec14d348457b6bdc1a3618e","username":"l2dev_1792381003"}}
    | A 全部认证请求：["POST http://127.0.0.1:32785/api/v1/auth/login → 401","POST http://127.0.0.1:32785/api/v1/auth/register → 201"]
    | B 全部认证请求：["POST http://127.0.0.1:32785/api/v1/auth/login → 200"]
[PASS] #0.2 夹具前置：B 的既有唯一键行（user_profile / user_appearance）id 对齐到 A（稳态构造，非放宽断言）
    | A 的 user_profile.id=688d9fc9-fddd-4b5a-9aca-f9be73cd713f，user_appearance.id=3f3bdd44-0802-48b3-98e1-bfe32d124abc
    | user_profile: fdba2383-f521-4500-8cfe-f1d1f462feeb → 688d9fc9-fddd-4b5a-9aca-f9be73cd713f（同一行，user_id 未变，内容未动）
    | user_appearance: 5456da8e-b1af-4e70-98bf-5311ff3a7e4b → 3f3bdd44-0802-48b3-98e1-bfe32d124abc（同一行，user_id 未变，内容未动）
    | 若不对齐：B 首同步 pull 到 A 那一版时，本机按 id 查不到 → 直接 INSERT → UNIQUE constraint failed: user_appearance.user_id（见第 8.3 节原始栈）
[PASS] #0.3 两端各完成一次真实 push+pull（服务端记录 lastSyncAt 锚点）
    | A push: {"accepted":2,"skipped":0,"ignored":0,"rejected":0,"conflicts":0,"serverTime":1792381011462,"offsetMs":58,"clockWarning":null,"acceptedByTable":{"user_appearance":1,"user_profile":1},"merged":{},"errors":[]}
    | B push: {"accepted":2,"skipped":0,"ignored":0,"rejected":0,"conflicts":2,"serverTime":1792381011748,"offsetMs":52,"clockWarning":null,"acceptedByTable":{"user_appearance":1,"user_profile":1},"merged":{},"errors":[]}
    | A lastSyncAt: null → 1792381011495
    | B lastSyncAt: null → 1792381011771
    | 客户端 sync_log（A 最近 5 条）: null
[PASS] #1.1 A 走真实录入链路（RecordService.save → CarbonService.calculate）落两条碳记录，含四字段因子快照
    | save#1 outcome: {"recordId":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","reductionKg":0.96,"pointExpected":96,"pointAwarded":96,"capped":false,"isAbnormal":false,"newGoals":[],"newBadges":["初次碳迹"],"goalPoints":0}
    | save#2 outcome: {"recordId":"b5172724-a184-499b-9d74-2965b7b27cf9","reductionKg":5.703,"pointExpected":570,"pointAwarded":200,"capped":true,"isAbnormal":false,"newGoals":[],"newBadges":[],"goalPoints":0}
    | A 库中该行: amount=5 category=travel confidence=provisional created_at=1792985803000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=f7d2e5d5-351f-41e4-8aa6-5364899c208f is_abnormal=0 is_deleted=0 note=L2-基线-A1 occurred_at=1792377410054 point_awarded=96 point_capped=0 reduction_kg=0.96 revision=0 sub_type=walk sync_state=pending unit=km updated_at=1792985803000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 四字段快照: factor_value=0.192 factor_version=CF-2026.2 factor_source=SRC-DERIVED confidence=provisional
[PASS] #1.2 push → pull 后，B 库中同一行与 A **逐列相同**（含四字段快照；排除端侧游标列 sync_state）
    | A push（原始响应）: POST http://127.0.0.1:32785/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-df7db19f6ec14d348457b6bdc1a3618e","deviceId":"l2-dev-A","lastSyncAt":1792381011495,"clientNow":1792381012398,"tables":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"},{"id":"b5172724-a184-499b-9d74-2965b7b27cf9"…（截断，全长 7776 字符）
      resp: {"ok":true,"data":{"accepted":23,"skipped":0,"ignored":0,"rejected":0,"conflicts":0,"serverTime":1792381012508,"offsetMs":50,"clockWarning":null,"acceptedByTable":{"carbon_record":2,"point_record":2,"user_goal":11,"user_badge":8},"merged":{},"errors":[]}}
    | B pull（原始响应，仅列该行所在表）: [{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A"}]
    | A 库: amount=5 category=travel confidence=provisional created_at=1792985803000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=f7d2e5d5-351f-41e4-8aa6-5364899c208f is_abnormal=0 is_deleted=0 note=L2-基线-A1 occurred_at=1792377410054 point_awarded=96 point_capped=0 reduction_kg=0.96 revision=0 sub_type=walk sync_state=pending unit=km updated_at=1792985803000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | B 库: amount=5 category=travel confidence=provisional created_at=1792985803000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=f7d2e5d5-351f-41e4-8aa6-5364899c208f is_abnormal=0 is_deleted=0 note=L2-基线-A1 occurred_at=1792377410054 point_awarded=96 point_capped=0 reduction_kg=0.96 revision=0 sub_type=walk sync_state=local unit=km updated_at=1792985803000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 差异列: 无
    | B 侧 sync_state=local（A 侧 pending）——端侧游标列，服务端不建该列，不参与同步
[PASS] #1.3 服务端（直查 MySQL）持有的该行与两端一致
    | 服务端: amount=5 category=travel confidence=provisional created_at=1792985803000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=f7d2e5d5-351f-41e4-8aa6-5364899c208f is_abnormal=0 is_deleted=0 note=L2-基线-A1 occurred_at=1792377410054 point_awarded=96 point_capped=0 reduction_kg=0.96 revision=0 sub_type=walk unit=km updated_at=1792985803000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 直查命令: SELECT * FROM carbon_record WHERE id='f7d2e5d5-351f-41e4-8aa6-5364899c208f'（docker exec carbonboo-mysql mysql -D carbonboo_l2_e2e）
[PASS] #1.4 另外的真实业务表（point_record 积分流水）也随同一次同步往返且两端逐列一致
    | A 侧 point_record 行数=2，B 侧=2
    | A 侧首行: created_at=1792381012196 device_id=l2-dev-A flow_kind=primary id=83cf9936-951e-437f-83dc-c23d82bae2ac is_deleted=0 occurred_at=1792377410054 points=200 remark=本笔受每日记录上限影响，实入 200 分 source_id=b5172724-a184-499b-9d74-2965b7b27cf9#0 source_type=carbon_record sync_state=synced title=elec_grid 10 kWh type=record_capped updated_at=1792381012196 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | B 侧首行: created_at=1792381012196 device_id=l2-dev-A flow_kind=primary id=83cf9936-951e-437f-83dc-c23d82bae2ac is_deleted=0 occurred_at=1792377410054 points=200 remark=本笔受每日记录上限影响，实入 200 分 source_id=b5172724-a184-499b-9d74-2965b7b27cf9#0 source_type=carbon_record sync_state=local title=elec_grid 10 kWh type=record_capped updated_at=1792381012196 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 两端去游标列后全等: true
```

**结论**：✅ 通过。B 是**另一个库文件、另一个 deviceId**（`#0.1` 打印两者路径与 deviceId），
B 库里的行与 A 逐列相同、与服务端直查结果也相同 ⇒ 「push → pull 往返」在协议层成立。

### 第 2 项：LWW 收敛（两端各自离线改同一行 → 依次 push/pull）

**断言**：① 服务端按 `updated_at` 大者胜且计为**真冲突**；② **两库最终行逐列完全相同**（不是只看服务端返回码）；
③ 胜者确为 `updated_at` 更大的一版；④ 旧版上行被服务端 `rejected`（不做降级覆盖），A 靠随后的 pull 收敛。

```text
[PASS] #2.1 服务端按 updatedAt 大者胜：B 的版本（updated_at 更大）被采纳，且被计为真冲突
    | A 改（T1=1792986063000）: POST http://127.0.0.1:32785/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-df7db19f6ec14d348457b6bdc1a3618e","deviceId":"l2-dev-A","lastSyncAt":1792381013441,"clientNow":1792381014141,"tables":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"synced"},{"id":"b5172724-a184-499b-9d74-2965b7b27cf9",…（截断，全长 8280 字符）
      resp: {"ok":true,"data":{"accepted":24,"skipped":0,"ignored":0,"rejected":0,"conflicts":22,"serverTime":1792381014234,"offsetMs":50,"clockWarning":null,"acceptedByTable":{"carbon_record":3,"point_record":2,"user_goal":11,"user_badge":8},"merged":{},"errors":[]}}
    | B 改（T2=1792986123000）: POST http://127.0.0.1:32785/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-df7db19f6ec14d348457b6bdc1a3618e","deviceId":"l2-dev-B","lastSyncAt":1792381013733,"clientNow":1792381014669,"tables":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"synced"},{"id":"b5172724-a184-499b-9d74-2965b7b27cf9",…（截断，全长 7400 字符）
      resp: {"ok":true,"data":{"accepted":3,"skipped":19,"ignored":0,"rejected":19,"conflicts":3,"serverTime":1792381014750,"offsetMs":53,"clockWarning":null,"acceptedByTable":{"carbon_record":3},"merged":{"user_goal":[{"id":"bfc46464-0752-4067-9e77-dce3bc8ec6f8","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986063000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"1af8de5d-b96f-481b-aa9e-53141ce0651e","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"M1","period_key":"M:2026-10","progress":5.0,"threshold":100.0,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986063000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"e346d86c-46e7-4f74-a244-8dc196bd05a8","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"M2","period_key":"Q:2026-Q4","progress":12.963,"threshold":50.0,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986063000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"750c0315-294e-4063-847f-3a0211146dcc","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"M3","period_key":"Q:2026-Q4","progress":7.0,"threshold":20.0,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986063000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"4022fca3-d41e-4349-802f-d5dabee…（截断，全长 6985 字符）
    | 服务端采纳后该行: updated_at=1792986123000 note=LWW-B版
    | B push 的 conflicts=3（两端自上次同步后都改过这一行 → 真冲突）
[PASS] #2.2 两端最终行**逐列完全相同**（不是只断言服务端返回 accepted）
    | A push#2（旧版本，被服务端拒绝）: POST http://127.0.0.1:32785/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-df7db19f6ec14d348457b6bdc1a3618e","deviceId":"l2-dev-A","lastSyncAt":1792381014256,"clientNow":1792381015000,"tables":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"synced"},{"id":"b5172724-a184-499b-9d74-2965b7b27cf9",…（截断，全长 7431 字符）
      resp: {"ok":true,"data":{"accepted":21,"skipped":1,"ignored":0,"rejected":1,"conflicts":21,"serverTime":1792381015090,"offsetMs":51,"clockWarning":null,"acceptedByTable":{"carbon_record":2,"user_goal":11,"user_badge":8},"merged":{"carbon_record":[{"id":"e2461fdc-5ea1-4839-aa10-1346005d04d6","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"paper","amount":9.0,"unit":"kg","occurred_at":1792377410054,"reduction_kg":1.8,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":180,"point_capped":0,"revision":0,"is_abnormal":0,"note":"LWW-B版","created_at":1792986003000,"updated_at":1792986123000,"is_deleted":0,"device_id":"l2-dev-B"}]},"errors":["carbon_record.id=e2461fdc-5ea1-4839-aa10-1346005d04d6 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）"]}}
    | A 库: amount=9 category=recycle confidence=provisional created_at=1792986003000 device_id=l2-dev-B factor_source=SRC-CALC factor_value=0.9 factor_version=CF-2026.2 id=e2461fdc-5ea1-4839-aa10-1346005d04d6 is_abnormal=0 is_deleted=0 note=LWW-B版 occurred_at=1792377410054 point_awarded=180 point_capped=0 reduction_kg=1.8 revision=0 sub_type=paper sync_state=local unit=kg updated_at=1792986123000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | B 库: amount=9 category=recycle confidence=provisional created_at=1792986003000 device_id=l2-dev-B factor_source=SRC-CALC factor_value=0.9 factor_version=CF-2026.2 id=e2461fdc-5ea1-4839-aa10-1346005d04d6 is_abnormal=0 is_deleted=0 note=LWW-B版 occurred_at=1792377410054 point_awarded=180 point_capped=0 reduction_kg=1.8 revision=0 sub_type=paper sync_state=synced unit=kg updated_at=1792986123000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 差异列: 无
[PASS] #2.3 胜者确为 updatedAt 更大的一版（B 版内容），且服务端与两端同一份
    | T2=1792986123000（B 版） > T1=1792986063000（A 版）
    | A 库: updated_at=1792986123000 note=LWW-B版 amount=9
    | B 库: updated_at=1792986123000 note=LWW-B版 amount=9
    | 服务端: updated_at=1792986123000 note=LWW-B版 amount=9
[PASS] #2.4 旧版本上行被服务端**拒绝**（不做降级覆盖），A 靠随后的 pull 收敛到胜者版本
    | A push#2 响应: {"accepted":21,"skipped":1,"ignored":0,"rejected":1,"conflicts":21,"serverTime":1792381015090,"offsetMs":51,"clockWarning":null,"acceptedByTable":{"carbon_record":2,"user_goal":11,"user_badge":8},"merged":{"carbon_record":[{"id":"e2461fdc-5ea1-4839-aa10-1346005d04d6","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"paper","amount":9,"unit":"kg","occurred_at":1792377410054,"reduction_kg":1.8,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":180,"point_capped":0,"revision":0,"is_abnormal":0,"note":"LWW-B版","created_at":1792986003000,"updated_at":1792986123000,"is_deleted":0,"device_id":"l2-dev-B"}]},"errors":["carbon_record.id=e2461fdc-5ea1-4839-aa10-1346005d04d6 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）"]}
    | A 库最终: amount=9 category=recycle confidence=provisional created_at=1792986003000 device_id=l2-dev-B factor_source=SRC-CALC factor_value=0.9 factor_version=CF-2026.2 id=e2461fdc-5ea1-4839-aa10-1346005d04d6 is_abnormal=0 is_deleted=0 note=LWW-B版 occurred_at=1792377410054 point_awarded=180 point_capped=0 reduction_kg=1.8 revision=0 sub_type=paper sync_state=local unit=kg updated_at=1792986123000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 服务端在 push 响应里回了 merged（客户端 sync() 只检查 status、从不读 body）：{"carbon_record":[{"id":"e2461fdc-5ea1-4839-aa10-1346005d04d6","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"paper","amount":9,"unit":"kg","occurred_at":1792377410054,"reduction_kg":1.8,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":180,"point_capped":0,"revision":0,"is_abnormal":0,"note":"LWW-B版","created_at":1792986003000,"updated_at":1792986123000,"is_deleted":0,"device_id":"l2-dev-B"}]}
```

**结论**：✅ 通过。这是本任务最核心的一条：判定挂在**两端库的逐列比对**上（`#2.2` 打印了两库 + 服务端三方比对与
"差异列：无"），而不是"服务端返回 accepted"。

### 第 3 项：平局按 `deviceId` 字典序（`updated_at` 完全相等）

**断言**：① 对端 `deviceId` 字典序更大 ⇒ 客户端平局分支（`SyncService.ets:655-665`）采纳对端版本，**两端一致**；
② 负向对照：对端 `deviceId` 更小 ⇒ 两端各自保留本机版本；③ 服务端平局规则同向。

> 构造说明：客户端 `pushBody` 的上行过滤是 `WHERE user_id = ? AND updated_at > ?`（`SyncService.ets:504`，**与 `sync_state` 无关**），
> 而 pull 的 `since` 是同一个锚点 ⇒ 若两端时钟一致，A 推送时服务端就会先把该行改成 A 自己的版本，平局分支在真链路上摸不到。
> 因此本项让两端在**各自时钟快 5 分钟**的条件下同步（`offsetMs≈-300000` ⇒ 服务端把两端的上行都判为"更旧"而拒绝，从而**保留夹具预置的服务端版本**），
> 再让客户端 pull 到那条 `updated_at` 完全相等的行——这正是平局分支的真实触发条件（`respOffsetMs` 在 pull 响应里缺失 ⇒ `offsetMsClient=0`，见 `#4.7`）。

```text
[PASS] #3.1 对端 deviceId 字典序更大（l2-dev-Z > l2-dev-A / l2-dev-B）且 updated_at 完全相等 ⇒ 客户端平局分支采纳对端版本（SyncService.ets:659）
    | 平局构造：本机 A=(updated_at=1792381075221, device_id=l2-dev-A, note=平局-A版) / 本机 B=(updated_at=1792381075221, device_id=l2-dev-B, note=平局-B版) / 服务端=(updated_at=1792381075221, device_id=l2-dev-Z, note=平局-Z版)
    | A 侧 set_row 回读: {"id":"9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"aluminum","amount":5,"unit":"kg","occurred_at":1792377410054,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-A版","created_at":1792381075221,"updated_at":1792381075221,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"}
    | B 侧 set_row 回读: {"id":"9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"aluminum","amount":7,"unit":"kg","occurred_at":1792377410054,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-B版","created_at":1792381075221,"updated_at":1792381075221,"is_deleted":0,"device_id":"l2-dev-B","sync_state":"pending"}
    | 服务端构造后: amount=42 category=recycle confidence=provisional created_at=1792381075221 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792381075221 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | A push（时钟超前 5 分钟 ⇒ 上行被判更旧）: POST http://127.0.0.1:32785/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-df7db19f6ec14d348457b6bdc1a3618e","deviceId":"l2-dev-A","lastSyncAt":1792381015744,"clientNow":1792381316800,"tables":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"synced"},{"id":"b5172724-a184-499b-9d74-2965b7b27cf9",…（截断，全长 9466 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":28,"ignored":0,"rejected":28,"conflicts":0,"serverTime":1792381016882,"offsetMs":-299950,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5.0,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"b5172724-a184-499b-9d74-2965b7b27cf9","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"utility","sub_type":"elec_grid","amount":10.0,"unit":"kWh","occurred_at":1792377410054,"reduction_kg":5.703,"factor_value":0.5703,"factor_version":"CF-2026.2","factor_source":"SRC-MEE-GRID-2022","confidence":"verified","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"L2-基线-A2","created_at":1792985804000,"updated_at":1792985804000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"e2461fdc-5ea1-4839-aa10-1346005d04d6","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"paper","amount":9.0,"unit":"kg","occurred_at":1792377410054,"reduction_kg":1.8,"factor_val…（截断，全长 11128 字符）
    | B push: POST http://127.0.0.1:32785/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-df7db19f6ec14d348457b6bdc1a3618e","deviceId":"l2-dev-B","lastSyncAt":1792381016053,"clientNow":1792381317109,"tables":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"synced"},{"id":"b5172724-a184-499b-9d74-2965b7b27cf9",…（截断，全长 9475 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":28,"ignored":0,"rejected":28,"conflicts":0,"serverTime":1792381017188,"offsetMs":-299949,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5.0,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"b5172724-a184-499b-9d74-2965b7b27cf9","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"utility","sub_type":"elec_grid","amount":10.0,"unit":"kWh","occurred_at":1792377410054,"reduction_kg":5.703,"factor_value":0.5703,"factor_version":"CF-2026.2","factor_source":"SRC-MEE-GRID-2022","confidence":"verified","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"L2-基线-A2","created_at":1792985804000,"updated_at":1792985804000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"e2461fdc-5ea1-4839-aa10-1346005d04d6","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"paper","amount":9.0,"unit":"kg","occurred_at":1792377410054,"reduction_kg":1.8,"factor_val…（截断，全长 11128 字符）
    | A 库: amount=42 category=recycle confidence=provisional created_at=1792381075221 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792381075221 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | B 库: amount=42 category=recycle confidence=provisional created_at=1792381075221 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792381075221 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
[PASS] #3.2 两端最终行**逐列完全相同**（不是"服务端返回 accepted"就算），且与服务端那一份同一版本
    | A 库: amount=42 category=recycle confidence=provisional created_at=1792381075221 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792381075221 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | B 库: amount=42 category=recycle confidence=provisional created_at=1792381075221 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792381075221 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 服务端: amount=42 category=recycle confidence=provisional created_at=1792381075221 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792381075221 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 差异列: 无
[PASS] #3.3 负向对照：对端 deviceId 更小（l2-dev-0 < l2-dev-A / l2-dev-B）且 updated_at 相等 ⇒ 两端各自保留本机版本，不采纳对端
    | 服务端构造后: amount=99 category=recycle confidence=provisional created_at=1792381107310 device_id=l2-dev-0 factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=7786208a-6b43-440d-ba52-45a20ed7c555 is_abnormal=0 is_deleted=0 note=平局2-0版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass unit=kg updated_at=1792381107310 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | A 库（应保留本机）: amount=4 category=recycle confidence=provisional created_at=1792381107310 device_id=l2-dev-A factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=7786208a-6b43-440d-ba52-45a20ed7c555 is_abnormal=0 is_deleted=0 note=平局2-A版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=synced unit=kg updated_at=1792381107310 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | B 库（应保留本机）: amount=6 category=recycle confidence=provisional created_at=1792381107310 device_id=l2-dev-B factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=7786208a-6b43-440d-ba52-45a20ed7c555 is_abnormal=0 is_deleted=0 note=平局2-B版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=synced unit=kg updated_at=1792381107310 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 注：这一支按规则"对端更小 ⇒ 保留本机"，两端各自留住自己那一版；它不是收敛用例，只用来证明比较方向（若把判据反转成"字典序小者胜"，A/B 都会变成平局2-0版 ⇒ 本条与 3.1 同时变红）。
[PASS] #3.4 服务端平局规则同向：`offsetMs=0`（省略 clientNow）时，同一 `updated_at` 下 deviceId 大者被采纳、小者被记 ignored
    | 直连探针①（device_id=l2-dev-Z，省略 clientNow）: {"ok":true,"data":{"accepted":1,"skipped":0,"ignored":0,"rejected":0,"conflicts":1,"serverTime":1792381019901,"offsetMs":0,"clockWarning":null,"acceptedByTable":{"carbon_record":1},"merged":{},"errors":[]}}
    | 服务端该行: amount=1 category=recycle confidence=provisional created_at=1792381139367 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=0.9 factor_version=CF-2026.2 id=1edc6b50-e7fd-477d-a880-d66b46f0e2e6 is_abnormal=0 is_deleted=0 note=平局3-l2-dev-Z occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=0.9 revision=0 sub_type=paper unit=kg updated_at=1792381139367 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 直连探针②（device_id=l2-dev-0）: {"ok":true,"data":{"accepted":0,"skipped":1,"ignored":1,"rejected":0,"conflicts":0,"serverTime":1792381019998,"offsetMs":0,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"1edc6b50-e7fd-477d-a880-d66b46f0e2e6","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"paper","amount":1.0,"unit":"kg","occurred_at":1792377410054,"reduction_kg":0.9,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","po…（截断，全长 790 字符）
    | 服务端该行未变: amount=1 category=recycle confidence=provisional created_at=1792381139367 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=0.9 factor_version=CF-2026.2 id=1edc6b50-e7fd-477d-a880-d66b46f0e2e6 is_abnormal=0 is_deleted=0 note=平局3-l2-dev-Z occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=0.9 revision=0 sub_type=paper unit=kg updated_at=1792381139367 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 三数自洽：skipped=1 = ignored(1) + rejected(0)
    | 口径提醒：真实客户端总会带 `clientNow`（SyncService.ets:513），于是 `offsetMs≈+50ms≠0`，服务端比较的是 `raw + offsetMs` ⇒ **永远构不成相等**，平局分支在真实链路上轮不到；上面 3.1/3.2 的"两端一致"正是靠"服务端拒绝上行（更旧）+ 客户端平局分支"取得的。
```

**结论**：✅ 通过。两端最终行逐列完全相同且等于服务端那一份（`#3.2`）；把判据反转后本组**必红**（§3.2）。

### 第 4 项：时钟偏移（`offsetMs = 服务端 − 客户端`；客户端须取反换算）

**断言**：① A 时钟落后 5 分钟 ⇒ `offsetMs≈+300000`，服务端按换算后基准判"更新"而采纳原始更旧的行；
② 反号 ⇒ 换算后更旧 ⇒ 拒绝（证明判据是"服务端 − 客户端"而不是原始值）；③ 偏移超 ±300000ms ⇒ 响应带 `clockWarning` 且**照常继续合并**；
④ 告警落到服务端 `sync_log`；⑤ 客户端取反换算：`respOffsetMs≈+300000` ⇒ `clientOffsetMs=-300000` ⇒ 对端时间戳**显得更旧** ⇒ A 保留本机版本；
⑥ 同一构造偏移反号 ⇒ 结论翻面（证明是"按符号取反"而不是随手加减）；⑦ 真实链路事实：pull 响应**不含 `offsetMs`**。

> **口径张力（如实记录）**：任务书写「A 的 `clientNow` 故意偏移（如 +5 分钟）→ 断言服务端时间戳在 A 的基准上显得更旧」，
> 而附录 B §5.3 的自证判据是「`respOffsetMs = +60000` ⇒ 服务端 `updatedAt = T` 的行换算到客户端基准必须是 `T − 60000`（显得更旧）」。
> 两者方向互斥：要让服务端时间戳**显得更旧**必须 `respOffsetMs > 0`，即**客户端时钟落后**服务端（`clientNow` 取小而不是取大）。
> 按 AGENTS.md §1.2（附录 > 其余叙述性文字）以附录为准；夹具把**两种符号都跑了**（落后 / 超前），判定挂在附录口径上。

```text
[PASS] #4.1 A 时钟落后 5 分钟：offsetMs ≈ +300000（= 服务端 − 客户端），服务端把"原始时间戳更旧、换算后更新"的行采纳
    | A 那行的原始 updated_at=1792986643000，服务端原值 1792986703000（原始更旧）
    | 换算：remote_updated = 1792986643000 + offsetMs(300052) = 1792986943052 > local 1792986703000 → 采纳
    | push 响应 offsetMs=300052（≈ +300000 ⇒ 服务端时钟 − 客户端时钟，客户端落后）
    | 服务端前: amount=6 category=travel confidence=provisional created_at=1792986703000 device_id=l2-dev-B factor_source=SRC-DERIVED factor_value=0.162 factor_version=CF-2026.2 id=9c0931bd-7293-4299-8da2-6145ced491df is_abnormal=0 is_deleted=0 note=时钟-B基准 occurred_at=1792377410054 point_awarded=97 point_capped=0 reduction_kg=0.972 revision=0 sub_type=metro unit=km updated_at=1792986703000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 服务端后: amount=8 category=travel confidence=provisional created_at=1792986703000 device_id=l2-dev-B factor_source=SRC-DERIVED factor_value=0.162 factor_version=CF-2026.2 id=9c0931bd-7293-4299-8da2-6145ced491df is_abnormal=0 is_deleted=0 note=时钟-A落后5分 occurred_at=1792377410054 point_awarded=130 point_capped=0 reduction_kg=1.296 revision=1 sub_type=metro unit=km updated_at=1792986643000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 原始响应: {"ok":true,"data":{"accepted":33,"skipped":0,"ignored":0,"rejected":0,"conflicts":33,"serverTime":1792381025116,"offsetMs":300052,"clockWarning":"客户端时钟与服务端相差 300.1 秒，超出 ±5 分钟容差；已按 offsetMs=300052 换算到服务端基准后继续合并（附录 B §6.4-6）","acceptedByTable":{"carbon_record":9,"user_goal":16,"user_badge":8},"merged":{},"errors":["客户端时钟与服务端相差 300.1 秒，超出 ±5 分钟容差；已按 offsetMs=300052 换算到服务端基准后继续合并（附录 B §6.4-6）"]}}
[PASS] #4.2 反向：A 时钟超前 5 分钟，原始时间戳更新但换算后更旧 → 服务端拒绝（判据是"服务端 − 客户端"，不是原始值）
    | A 那行的原始 updated_at=1792986823000（原始比服务端 1792986763000 新）
    | 换算：remote_updated = 1792986823000 + offsetMs(-299944) = 1792986523056 < local 1792986763000 → 拒绝
    | push 响应: {"accepted":2,"skipped":34,"ignored":0,"rejected":34,"conflicts":0,"serverTime":1792381026695,"offsetMs":-299944,"clockWarning":null,"acceptedByTable":{"point_record":2},"merged":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"b5172724-a184-499b-9d74-2965b7b27cf9","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"utility","sub_type":"elec_grid","amount":10,"unit":"kWh","occurred_at":1792377410054,"reduction_kg":5.703,"factor_value":0.5703,"factor_version":"CF-2026.2","factor_source":"SRC-MEE-GRID-2022","confidence":"verified","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"L2-基线-A2","created_at":1792985804000,"updated_at":1792985804000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"e2461fdc-5ea1-4839-aa10-1346005d04d6","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"paper","amount":9,"unit":"kg","occurred_at":1792377410054,"reduction_kg":1.8,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":180,"point_capped":0,"revision":0,"is_abnormal":0,"note":"LWW-B版","created_at":1792986003000,"updated_at":1792986123000,"is_deleted":0,"device_id":"l2-dev-B"},{"id":"9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"aluminum","amount":42,"unit":"kg","occurred_at":1792377410054,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":1792381075221,"updated_at":1792381075221,"is_deleted":0,"device_id":"l2-dev-Z"},{"id":"7786208a-6b43-440d-ba52-45a20ed7c555","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"glass","amount":4,"unit":"kg","occurred_at":1792377410054,"reduction_kg":3,"factor_value":1,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局2-A版","created_at":1792381107310,"updated_at":1792381107310,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"1edc6b50-e7fd-477d-a880-d66b46f0e2e6","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"paper","amount":1,"unit":"kg","occurred_at":1792377410054,"reduction_kg":0.9,"factor_value":0.9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局3-源","created_at":1792381139367,"updated_at":1792381139367,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"1c645d04-44c4-4c1b-a1df-741149215969","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"plate","sub_type":"meal","amount":3,"unit":"次","occurred_at":1792377410054,"reduction_kg":1.05,"factor_value":0.35,"factor_version":"CF-2026.2","factor_source":"SRC-CCAP-FW","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"L2-幂等","created_at":1792381080107,"updated_at":1792381080107,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"9cb1f1ba-c56a-4827-95a0-f891f96e4819","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"bicycle","amount":4,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.768,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":77,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-待删","created_at":1792986603000,"updated_at":1792986663000,"is_deleted":1,"device_id":"l2-dev-A"},{"id":"9c0931bd-7293-4299-8da2-6145ced491df","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"metro","amount":6,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.972,"factor_value":0.162,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":97,"point_capped":0,"revision":0,"is_abnormal":0,"note":"时钟-B基准","created_at":1792986703000,"updated_at":1792986703000,"is_deleted":0,"device_id":"l2-dev-B"},{"id":"258137a2-52c8-4cc4-91cd-4d2f65a2fadb","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"utility","sub_type":"gas","amount":3,"unit":"m³","occurred_at":1792377410054,"reduction_kg":6.552,"factor_value":2.184,"factor_version":"CF-2026.2","factor_source":"SRC-MEE-GHG","confidence":"verified","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"时钟-B基准2","created_at":1792986763000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-B"}],"user_goal":[{"id":"bfc46464-0752-4067-9e77-dce3bc8ec6f8","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"L1","period_key":"L:2026-10-19","progress":1,"threshold":80,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"1af8de5d-b96f-481b-aa9e-53141ce0651e","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"M1","period_key":"M:2026-10","progress":11,"threshold":100,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"e346d86c-46e7-4f74-a244-8dc196bd05a8","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"M2","period_key":"Q:2026-Q4","progress":38.937,"threshold":50,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"750c0315-294e-4063-847f-3a0211146dcc","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"M3","period_key":"Q:2026-Q4","progress":58,"threshold":20,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"4022fca3-d41e-4349-802f-d5dabee187bd","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"M4","period_key":"M:2026-10","progress":1,"threshold":20,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"c8208150-7f84-427b-983d-dc1a31b829b4","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"M5","period_key":"Y:2026","progress":38.937,"threshold":200,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"44e75cf5-027f-492d-8b01-7c0b77f9752e","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"S1","period_key":"D:2026-10-19","progress":1,"threshold":1,"settled":1,"settled_at":1792381075221,"created_at":1792381075221,"updated_at":1792381139367,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"6b959732-6048-4384-90d9-7c1d902ba993","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"S1","period_key":"D:2026-10-26","progress":0,"threshold":1,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"c8aa2349-fd83-44d8-b670-9a07923db4e9","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"S2","period_key":"D:2026-10-19","progress":10,"threshold":5,"settled":1,"settled_at":1792381075221,"created_at":1792381075221,"updated_at":1792381139367,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"f399ff4a-5002-4365-85d6-cee47aec856e","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"S2","period_key":"D:2026-10-26","progress":0,"threshold":5,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"0a79a50b-b5f5-4c28-80fd-a15dac38cd6c","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"S3","period_key":"D:2026-10-19","progress":0,"threshold":1,"settled":0,"settled_at":null,"created_at":1792381075221,"updated_at":1792381139367,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"08d76560-0df8-4078-b003-4af493a15711","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"S3","period_key":"D:2026-10-26","progress":0,"threshold":1,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"80426ed9-8230-4f09-93c0-0b7c4b16bb34","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"S4","period_key":"W:2026-W43","progress":4,"threshold":3,"settled":1,"settled_at":1792381107310,"created_at":1792381075221,"updated_at":1792381139367,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"78e16c78-d6e8-451c-9aac-fcadd060b2bf","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"S4","period_key":"W:2026-W44","progress":0,"threshold":3,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"2458cb96-3a4c-447f-947e-c7c176667bb8","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"S5","period_key":"W:2026-W43","progress":1,"threshold":5,"settled":0,"settled_at":null,"created_at":1792381075221,"updated_at":1792381139367,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"69a46b86-cbb3-4c55-bbcd-9d479418942b","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"S5","period_key":"W:2026-W44","progress":0,"threshold":5,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"}],"user_badge":[{"id":"f1b9b133-f65f-41ac-a69d-b33fd1b1c6eb","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","badge_id":"B_FIRST","unlocked":1,"unlocked_at":1792985803000,"progress":1,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"a0f2fa1b-6f09-4cc9-b0d5-c257cb24cee0","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","badge_id":"B_GREEN_TRIP","unlocked":0,"unlocked_at":null,"progress":2,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"079b90d8-5dc2-4b54-9564-cae520984f67","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","badge_id":"B_RECYCLER","unlocked":1,"unlocked_at":1792986603000,"progress":58,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"c585f980-aa32-4bee-8170-f216138fae62","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","badge_id":"B_STREAK_30","unlocked":0,"unlocked_at":null,"progress":0,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"5062f160-0a3d-4b16-86a5-f8980c625820","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","badge_id":"B_STREAK_7","unlocked":0,"unlocked_at":null,"progress":0,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"1ec115fd-c76b-4a7e-b009-a0449c8ece38","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","badge_id":"B_TOTAL_10","unlocked":1,"unlocked_at":1792986063000,"progress":38.937,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"94e6af0a-30a0-42ec-8639-1d0b366c49ac","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","badge_id":"B_TOTAL_100","unlocked":0,"unlocked_at":null,"progress":38.937,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"ef8aaa1f-85e3-4b5f-9adc-aa743be1df55","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","badge_id":"B_TREE","unlocked":0,"unlocked_at":null,"progress":0,"created_at":1792985803000,"updated_at":1792986763000,"is_deleted":0,"device_id":"l2-dev-A"}]},"errors":["carbon_record.id=f7d2e5d5-351f-41e4-8aa6-5364899c208f 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=b5172724-a184-499b-9d74-2965b7b27cf9 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=e2461fdc-5ea1-4839-aa10-1346005d04d6 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=7786208a-6b43-440d-ba52-45a20ed7c555 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=1edc6b50-e7fd-477d-a880-d66b46f0e2e6 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=1c645d04-44c4-4c1b-a1df-741149215969 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=9cb1f1ba-c56a-4827-95a0-f891f96e4819 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=9c0931bd-7293-4299-8da2-6145ced491df 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","carbon_record.id=258137a2-52c8-4cc4-91cd-4d2f65a2fadb 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=bfc46464-0752-4067-9e77-dce3bc8ec6f8 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=1af8de5d-b96f-481b-aa9e-53141ce0651e 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=e346d86c-46e7-4f74-a244-8dc196bd05a8 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=750c0315-294e-4063-847f-3a0211146dcc 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=4022fca3-d41e-4349-802f-d5dabee187bd 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=c8208150-7f84-427b-983d-dc1a31b829b4 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=44e75cf5-027f-492d-8b01-7c0b77f9752e 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=6b959732-6048-4384-90d9-7c1d902ba993 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=c8aa2349-fd83-44d8-b670-9a07923db4e9 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=f399ff4a-5002-4365-85d6-cee47aec856e 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=0a79a50b-b5f5-4c28-80fd-a15dac38cd6c 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=08d76560-0df8-4078-b003-4af493a15711 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=80426ed9-8230-4f09-93c0-0b7c4b16bb34 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=78e16c78-d6e8-451c-9aac-fcadd060b2bf 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=2458cb96-3a4c-447f-947e-c7c176667bb8 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_goal.id=69a46b86-cbb3-4c55-bbcd-9d479418942b 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=f1b9b133-f65f-41ac-a69d-b33fd1b1c6eb 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=a0f2fa1b-6f09-4cc9-b0d5-c257cb24cee0 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=079b90d8-5dc2-4b54-9564-cae520984f67 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=c585f980-aa32-4bee-8170-f216138fae62 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=5062f160-0a3d-4b16-86a5-f8980c625820 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=1ec115fd-c76b-4a7e-b009-a0449c8ece38 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=94e6af0a-30a0-42ec-8639-1d0b366c49ac 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）","user_badge.id=ef8aaa1f-85e3-4b5f-9adc-aa743be1df55 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）"]}
    | 服务端该行未变: amount=3 category=utility confidence=verified created_at=1792986763000 device_id=l2-dev-B factor_source=SRC-MEE-GHG factor_value=2.184 factor_version=CF-2026.2 id=258137a2-52c8-4cc4-91cd-4d2f65a2fadb is_abnormal=0 is_deleted=0 note=时钟-B基准2 occurred_at=1792377410054 point_awarded=200 point_capped=1 reduction_kg=6.552 revision=0 sub_type=gas unit=m³ updated_at=1792986763000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
[PASS] #4.3 偏移超过 ±300000ms：响应带 clockWarning，且**照常继续合并**（该行仍被采纳）
    | offsetMs=600057（|offsetMs| > 300000）
    | clockWarning="客户端时钟与服务端相差 600.1 秒，超出 ±5 分钟容差；已按 offsetMs=600057 换算到服务端基准后继续合并（附录 B §6.4-6）"
    | 继续合并的证据（服务端该行已变成 A 的版本）: amount=120 category=utility confidence=provisional created_at=1792986823000 device_id=l2-dev-B factor_source=SRC-CALC factor_value=0.000168 factor_version=CF-2026.2 id=82bf526c-b937-40f2-9372-6f6c044ff0f5 is_abnormal=0 is_deleted=0 note=时钟-A偏移超容差 occurred_at=1792377410054 point_awarded=2 point_capped=0 reduction_kg=0.0202 revision=1 sub_type=water unit=L updated_at=1792986943000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
[PASS] #4.4 服务端把该告警记进 sync_log（status=partial + error_msg），供 /sync/status 回显
    | 直查: SELECT direction,status,error_msg FROM sync_log ORDER BY started_at DESC LIMIT 3
    | sync_log: direction=pull status=success error_msg=null
    | sync_log: direction=push status=partial error_msg=客户端时钟与服务端相差 600.1 秒，超出 ±5 分钟容差；已按 offsetMs=600057 换算到服务端基准后继续合并（附录 B §6.4-6）
    | sync_log: direction=pull status=success error_msg=null
[PASS] #4.5 取反换算（A 落后 5 分钟）：`respOffsetMs ≈ +300000` ⇒ `clientOffsetMs = -300000` ⇒ 对端时间戳换算后**显得更旧**（T4+120000-300000 < T4）⇒ A 保留本机版本
    | 构造：本机=(updated_at=1792381088717, device_id=l2-dev-A, note=时钟-本机版)；服务端被夹具摆成=(updated_at=1792381208717, device_id=l2-dev-B, note=时钟-对端版)
    | 服务端构造后: amount=12 category=travel confidence=provisional created_at=1792381088717 device_id=l2-dev-B factor_source=SRC-DERIVED factor_value=0.152 factor_version=CF-2026.2 id=ee1593f5-c8a4-4bcb-b110-c68bf9001018 is_abnormal=0 is_deleted=0 note=时钟-对端版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=1.52 revision=0 sub_type=bus unit=km updated_at=1792381208717 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | A 锚点（本机行不进上行）: {"last_sync_at":"1792381088718"}
    | A pull 原始响应（经协议补全代理，含 offsetMs）: {"ok":true,"data":{"serverTime":1792381030330,"since":1792381088718,"tables":{"carbon_record":[{"id":"7786208a-6b43-440d-ba52-45a20ed7c555","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"glass","amount":4,"unit":"kg","occurred_at":1792377410054,"reduction_kg":3,"factor_value":1,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局2-A版","created_at":179238110731…（截断，全长 12546 字符）
    | A 库最终: amount=10 category=travel confidence=provisional created_at=1792381088717 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.152 factor_version=CF-2026.2 id=ee1593f5-c8a4-4bcb-b110-c68bf9001018 is_abnormal=0 is_deleted=0 note=时钟-本机版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=1.52 revision=0 sub_type=bus sync_state=synced unit=km updated_at=1792381088717 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
[PASS] #4.6 同一构造、偏移**反号** ⇒ 结论必须翻面：`clientOffsetMs = +300000` ⇒ 对端时间戳换算后更新 ⇒ A 采纳对端版本（证明是"按符号取反换算"，不是随手加减）
    | A pull 原始响应: {"ok":true,"data":{"serverTime":1792381030686,"since":1792381030330,"tables":{"carbon_record":[{"id":"9ff7a5e1-e5a6-4e49-9fa1-9bb0cdb99ef5","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"aluminum","amount":42,"unit":"kg","occurred_at":1792377410054,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":0,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":17923810…（截断，全长 13501 字符）
    | A 库最终: amount=12 category=travel confidence=provisional created_at=1792381088717 device_id=l2-dev-B factor_source=SRC-DERIVED factor_value=0.152 factor_version=CF-2026.2 id=ee1593f5-c8a4-4bcb-b110-c68bf9001018 is_abnormal=0 is_deleted=0 note=时钟-对端版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=1.52 revision=0 sub_type=bus sync_state=local unit=km updated_at=1792381208717 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 两向对照 ⇒ 若把 `-respOffset` 写成 `respOffset`（符号丢反），4.5 与 4.6 会同时翻面变红。
[PASS] #4.7 真实链路事实：直连服务端的 pull 响应**不含 `offsetMs`**（`SyncPullData` 就没有该字段）⇒ 客户端 `offsetMsClient` 恒为 0（SyncService.ets:578-579），附录 B §6.4-6 的取反换算是**不可达代码**
    | A 锚点: {"last_sync_at":"1792381088718"}
    | 真实 pull 响应字段: ["serverTime","since","tables"]
    | 真实 pull 原始响应: {"ok":true,"data":{"serverTime":1792381031792,"since":1792381088718,"tables":{"carbon_record":[{"id":"7786208a-6b43-440d-ba52-45a20ed7c555","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"recycle","sub_type":"glass","amount":4.0,"unit":"kg","occurred_at":1792377410054,"reduction_kg":3.0,"factor_value":1.0,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional"…（截断，全长 12624 字符）
    | 同一构造（服务端那一版 raw 更大）在真实链路上的实测后果: amount=12 category=travel confidence=provisional created_at=1792381088717 device_id=l2-dev-B factor_source=SRC-DERIVED factor_value=0.152 factor_version=CF-2026.2 id=ee1593f5-c8a4-4bcb-b110-c68bf9001018 is_abnormal=0 is_deleted=0 note=时钟-对端版 occurred_at=1792377410054 point_awarded=0 point_capped=1 reduction_kg=1.52 revision=0 sub_type=bus sync_state=local unit=km updated_at=1792381208717 user_id=u-df7db19f6ec14d348457b6bdc1a3618e（裸时间戳比较 ⇒ 对端更大 ⇒ 覆盖本机；只有 pull 带上 offsetMs 时才会出现 4.5 的"保留本机"）
    | 影响面：附录 B §5.3 的自证判据（`respOffsetMs = +60000 ⇒ 服务端 updatedAt = T 的行换算到客户端基准必须是 T − 60000`）在真实 HTTP 链路上无法达成；服务端 push 响应里**有** offsetMs，但客户端从不解析 push 响应体（SyncService.ets:181-196）。
```

**结论**：✅ 通过（含一条事实发现）。`offsetMs` 的方向、容差告警、继续合并、以及客户端取反换算的**符号敏感性**都被两向对照钉住；
同时实测出 **`clientOffsetMs` 在真实链路上恒为 0**（`SyncService.ets:578-579` 读的是 pull 响应里的 `offsetMs`，
而 `SyncPullData` 没有这个字段）——见发现 F2。

### 第 5 项：幂等（同一批 push 连推两次）

**断言**：① 复推不产生重复行（两端 + 服务端三处行数不变、库内无重复 id）；② `skipped = ignored + rejected` 三数自洽（附录 B §5.3）；
③ 服务端口径（省略 `clientNow` ⇒ `offsetMs=0`）重放 ⇒ `accepted=0`；④ 带 `clientNow` 重放（真实客户端就是这样）⇒ `accepted>0` 但**仍不新增行**；⑤ 两次重放后行数依旧不变。

```text
[PASS] #5.1 复推同一批**不产生重复行**：两端 + 服务端三处行数不变，库内无重复 id，且该行内容逐列不变
    | 第一次 push: {"ok":true,"data":{"accepted":14,"skipped":19,"ignored":0,"rejected":19,"conflicts":11,"serverTime":1792381020581,"offsetMs":50,"clockWarning":null,"acceptedByTable":{"carbon_record":7,"point_record":2,"user_goal":5},"merged":{"user_goal":[{"id":"bfc46464-0752-4067-9e77-dce3bc8ec6f8","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold…（截断，全长 7046 字符）
    | 重新标脏: ["carbon_record:1c645d04-44c4-4c1b-a1df-741149215969"]
    | 第二次 push（同一批）: {"ok":true,"data":{"accepted":31,"skipped":0,"ignored":0,"rejected":0,"conflicts":31,"serverTime":1792381021545,"offsetMs":50,"clockWarning":null,"acceptedByTable":{"carbon_record":7,"user_goal":16,"user_badge":8},"merged":{},"errors":[]}}
    | 行数 A: 7 → 7；B: 7 → 7；服务端 carbon_record: 7 → 7
    | A 库重复 id: []；B 库重复 id: []
    | 该行内容差异（复推前后）: 无
[PASS] #5.2 三数自洽：`skipped = ignored + rejected`（附录 B §5.3）
    | 第二次 push 响应: {"ok":true,"data":{"accepted":31,"skipped":0,"ignored":0,"rejected":0,"conflicts":31,"serverTime":1792381021545,"offsetMs":50,"clockWarning":null,"acceptedByTable":{"carbon_record":7,"user_goal":16,"user_badge":8},"merged":{},"errors":[]}}
    | 解析: skipped=0 ignored=0 rejected=0
[PASS] #5.3 服务端口径：**省略 `clientNow`**（⇒ `offsetMs=0`）重放同一批 ⇒ `accepted=0`、`ignored>0`、`skipped=ignored+rejected` —— 附录 B §5.3 的"复推 accepted=0"成立
    | 重放 body 长度=10963（第 10963 字节…取本次 sync 的真实上行原文）
    | 直连探针（省略 clientNow）响应: {"ok":true,"data":{"accepted":0,"skipped":31,"ignored":31,"rejected":0,"conflicts":0,"serverTime":1792381021776,"offsetMs":0,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5.0,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":96,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-基线-A1","created_at":1792985803000,"updated_at":1792985803000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"b5172724-a184-…（截断，全长 13343 字符）
[PASS] #5.4 同一份 body **带 `clientNow`** 重放（真实客户端就是这样）⇒ `offsetMs≠0`，服务端把同一批再判为 `accepted>0`（写回同值、不新增行）⇒ §5.3 的 `accepted=0` 以"两端同一时钟基准"为前提
    | 直连探针（原样，带 clientNow）响应: {"ok":true,"data":{"accepted":31,"skipped":0,"ignored":0,"rejected":0,"conflicts":31,"serverTime":1792381021742,"offsetMs":248,"clockWarning":null,"acceptedByTable":{"carbon_record":7,"user_goal":16,"user_badge":8},"merged":{},"errors":[]}}
    | 对比：带 clientNow → accepted=31 ignored=0 offsetMs=248；省略 clientNow → accepted=0 ignored=31 offsetMs=0
    | 机制：服务端比较的是 `remote_updated = values.updated_at + offset_ms`（sync_service.py:459），而落库的是客户端原始时间戳（:496-500）。只要 `offset_ms≠0`，重放同一行就会变成 `T+offset > T` ⇒ 判为"更新"。
[PASS] #5.5 两次重放之后行数依旧不变（既没有新增行、也没有被删）
    | 行数 A: 7 → 7；服务端 carbon_record: 7 → 7
```

**结论**：✅ 通过。第 5.3/5.4 两条一起把 §5.3 的 `accepted=0` 钉了个前提：它成立的条件是**两端同一时钟基准**；
真实客户端总是带 `clientNow`，此时服务端会把复推判成 `accepted>0`（**写回同值、不新增行**，幂等本身不破）。

### 第 6 项：软删除传播（A 删 → push → B pull → `is_deleted=1` 且行仍在）

**断言**：① B 侧收到软删除标记；② **行仍在表里**（不物理删）；③ 两端逐列一致且服务端也持软删行。

```text
[PASS] #6.1 B 侧收到软删除：is_deleted=1
    | 删除前 B 侧: is_deleted=0
    | remove 结果: {"step":"remove_record","deviceId":"l2-dev-A","clockOffsetMs":0,"ok":true,"code":"","message":"","device":"A","stepName":"remove_record"}
    | B pull 原始响应（该行）: [{"id":"9cb1f1ba-c56a-4827-95a0-f891f96e4819","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"bicycle","amount":4,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.768,"factor_value":0.192,"factor_version":"CF-2026.2","factor_source":"SRC-DERIVED","confidence":"provisional","point_awarded":77,"point_capped":0,"revision":0,"is_abnormal":0,"note":"L2-待删","created_at":1792986603000,"updated_at":1792986663000,"is_deleted":1,"device_id":"l2-dev-A"}]
    | B 侧该行: amount=4 category=travel confidence=provisional created_at=1792986603000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=9cb1f1ba-c56a-4827-95a0-f891f96e4819 is_abnormal=0 is_deleted=1 note=L2-待删 occurred_at=1792377410054 point_awarded=77 point_capped=0 reduction_kg=0.768 revision=0 sub_type=bicycle sync_state=local unit=km updated_at=1792986663000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
[PASS] #6.2 行**仍在表里**（不物理删）：两端各恰有 1 行，且 uptate 走 DELETE+INSERT 也不减行数
    | A 侧该 id 行数=1
    | B 侧该 id 行数=1
    | B 侧该行: amount=4 category=travel confidence=provisional created_at=1792986603000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=9cb1f1ba-c56a-4827-95a0-f891f96e4819 is_abnormal=0 is_deleted=1 note=L2-待删 occurred_at=1792377410054 point_awarded=77 point_capped=0 reduction_kg=0.768 revision=0 sub_type=bicycle sync_state=local unit=km updated_at=1792986663000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
[PASS] #6.3 软删行两端逐列一致，且服务端也持软删行（不物理删）
    | A 库: amount=4 category=travel confidence=provisional created_at=1792986603000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=9cb1f1ba-c56a-4827-95a0-f891f96e4819 is_abnormal=0 is_deleted=1 note=L2-待删 occurred_at=1792377410054 point_awarded=77 point_capped=0 reduction_kg=0.768 revision=0 sub_type=bicycle sync_state=synced unit=km updated_at=1792986663000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | B 库: amount=4 category=travel confidence=provisional created_at=1792986603000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=9cb1f1ba-c56a-4827-95a0-f891f96e4819 is_abnormal=0 is_deleted=1 note=L2-待删 occurred_at=1792377410054 point_awarded=77 point_capped=0 reduction_kg=0.768 revision=0 sub_type=bicycle sync_state=local unit=km updated_at=1792986663000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
    | 差异列: 无
    | 服务端: amount=4 category=travel confidence=provisional created_at=1792986603000 device_id=l2-dev-A factor_source=SRC-DERIVED factor_value=0.192 factor_version=CF-2026.2 id=9cb1f1ba-c56a-4827-95a0-f891f96e4819 is_abnormal=0 is_deleted=1 note=L2-待删 occurred_at=1792377410054 point_awarded=77 point_capped=0 reduction_kg=0.768 revision=0 sub_type=bicycle unit=km updated_at=1792986663000 user_id=u-df7db19f6ec14d348457b6bdc1a3618e
```

**结论**：✅ 通过。客户端软删走 `RecordService.remove`（`is_deleted=1`、`updated_at=now`、**不 bump revision**），
服务端 LWW 对该行按普通更新处理；两端库内该 id 行数恒为 1（`#6.2` 同时校验了"客户端落库走 DELETE+INSERT 也不减行数"）。

### 第 7 项：冲突计数口径（`ignored` 不得计入 `conflicts`）

**断言**：① 纯去重批次（`accepted=0`、`ignored>0`）`conflicts=0` 且三数自洽；② 同一个 `conflicts` 计数器在"两端都改过同一行"的批次里确实 +1（第 2 项 B push）⇒ 7.1 不是"计数器坏了"造成的假绿。

```text
[PASS] #7.1 纯去重批次（`accepted=0`、`ignored>0`）`conflicts=0` 且 `skipped=ignored+rejected` ⇒ **ignored 没有被计入 conflicts**
    | 原始响应: {"ok":true,"data":{"accepted":0,"skipped":31,"ignored":31,"rejected":0,"conflicts":0,"serverTime":1792381021776,"offsetMs":0,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"f7d2e5d5-351f-41e4-8aa6-5364899c208f","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","category":"travel","sub_type":"walk","amount":5.0,"unit":"km","occurred_at":1792377410054,"reduction_kg":0.96,"fac…（截断，全长 13343 字符）
    | accepted=0 ignored=31 rejected=0 conflicts=0 skipped=31 offsetMs=0
    | 反证：如果 `ignored` 被算进 `conflicts`，本批的 conflicts 至少等于 ignored（>0）——实测为 0。
[PASS] #7.2 同一个 `conflicts` 计数器在"两端都改过同一行"的批次里确实会 +1（第 2 项 B push）⇒ 7.1 不是"计数器坏了"造成的假绿
    | 第 2 项 B push（两端都改过同一行）conflicts=3
    | B push 原始响应: {"ok":true,"data":{"accepted":3,"skipped":19,"ignored":0,"rejected":19,"conflicts":3,"serverTime":1792381014750,"offsetMs":53,"clockWarning":null,"acceptedByTable":{"carbon_record":3},"merged":{"user_goal":[{"id":"bfc46464-0752-4067-9e77-dce3bc8ec6f8","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792985803000,"updated_at":1792986063000,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"1af8de5d-b96f-481b-aa9e-53141ce0651e","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","goal_id":"…（截断，全长 6985 字符）
    | 对照条件（服务端 sync_service.py:466-467）：`local_updated > last_sync_at and values.updated_at > last_sync_at`。
```

**结论**：✅ 通过。另记一条**观察（非判定项）**：服务端的冲突判定条件是
`local_updated > last_sync_at and int(values["updated_at"]) > last_sync_at`（`server/app/services/sync_service.py:466-467`），
其中后半句对任何"被上推的行"恒真 ⇒ 实际起作用的是前半句"服务端本机版本也在本轮同步窗口内被改过"，与附录 B §6.4-3 的「真冲突」定义一致。

## 3. 第 8 项：反证（不是假绿）

### 3.1 不设 `L1_ALLOW_NETWORK` 时，垫片必须拒绝出网

```text
[PASS] #8.1 不设 L1_ALLOW_NETWORK 时垫片拒绝出网（贴原始错误）；本任务全程在 L1_ALLOW_NETWORK=1 下跑真 HTTP
    | L1_ALLOW_NETWORK=(未设置)
    | 原始错误：离线执行（L1）不出网：拦截了对 http://127.0.0.1:32785/api/v1/config 的请求。L1 里网络必须由用例注入的假实现承担；若确需真网络，显式设 L1_ALLOW_NETWORK=1（这已不属于 L1 的范畴）。
    | 同一进程置 L1_ALLOW_NETWORK=1 时，上面的每一次 sync 都真的打到了 http://127.0.0.1:32785（见各步原始请求/响应）
```

### 3.2 变异自证：改一处**真实比较规则**必红，`git show` 还原必绿

变异点就是客户端平局判据（`app/entry/src/main/ets/viewmodel/net/SyncService.ets:659`）：
`if (remoteDevice > localDevice) {` → `if (remoteDevice < localDevice) {`。**只改构建目录里的副本**，仓库文件不动；
还原用 `git show HEAD:<path>` 覆写副本 + `cmp` 逐字节校验 + `--skip-copy` 原处重转译（**不用任何备份文件**）。

```text
@@ -656,7 +656,7 @@

-        if (remoteDevice > localDevice) {

+        if (remoteDevice < localDevice) {

```

```text
[FAIL] #3.1 对端 deviceId 字典序更大（l2-dev-Z > l2-dev-A / l2-dev-B）且 updated_at 完全相等 ⇒ 客户端平局分支采纳对端版本（SyncService.ets:659）
    | 平局构造：本机 A=(updated_at=1792381099929, device_id=l2-dev-A, note=平局-A版) / 本机 B=(updated_at=1792381099929, device_id=l2-dev-B, note=平局-B版) / 服务端=(updated_at=1792381099929, device_id=l2-dev-Z, note=平局-Z版)
    | A 侧 set_row 回读: {"id":"1c6f7050-1902-40ef-aac4-f5f99fa70fb8","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","category":"recycle","sub_type":"aluminum","amount":5,"unit":"kg","occurred_at":1792377437925,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-A版","created_at":1792381099929,"updated_at":1792381099929,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"}
    | B 侧 set_row 回读: {"id":"1c6f7050-1902-40ef-aac4-f5f99fa70fb8","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","category":"recycle","sub_type":"aluminum","amount":7,"unit":"kg","occurred_at":1792377437925,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-B版","created_at":1792381099929,"updated_at":1792381099929,"is_deleted":0,"device_id":"l2-dev-B","sync_state":"pending"}
    | 服务端构造后: amount=42 category=recycle confidence=provisional created_at=1792381099929 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=1c6f7050-1902-40ef-aac4-f5f99fa70fb8 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377437925 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792381099929 user_id=u-579e28cdae974a3d9ad80ca79d3c90d8
    | A push（时钟超前 5 分钟 ⇒ 上行被判更旧）: POST http://127.0.0.1:32785/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-579e28cdae974a3d9ad80ca79d3c90d8","deviceId":"l2-dev-A","lastSyncAt":1792381040510,"clientNow":1792381341732,"tables":{"carbon_record":[{"id":"1c6f7050-1902-40ef-aac4-f5f99fa70fb8","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","category":"recycle","sub_type":"aluminum","amount":5,"unit":"kg","occurred_at":1792377437925,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-A版","created_at":1792381099929,"updated_at":1792381099929,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"}],"point_record":[],"user_goal":[{"id":"799ce082-c5…（截断，全长 6389 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":20,"ignored":0,"rejected":20,"conflicts":0,"serverTime":1792381041816,"offsetMs":-299942,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"1c6f7050-1902-40ef-aac4-f5f99fa70fb8","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","category":"recycle","sub_type":"aluminum","amount":42.0,"unit":"kg","occurred_at":1792377437925,"reduction_kg":18.0,"factor_value":9.0,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":1792381099929,"updated_at":1792381099929,"is_deleted":0,"device_id":"l2-dev-Z"}],"user_goal":[{"id":"799ce082-c5eb-4e83-991d-7f2f5a19ab9c","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792381099929,"updated_at":1792381099929,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"f57115c1-2edb-4e80-a7bd-7d43826c102c","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","goal_id":"M1","period_key":"M:2026-10","progress":0.0,"threshold":100.0,"settled":0,"settled_at":null,"created_at":1792381099929,"updated_at":1792381099929,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"264e4ee7-a963-4b91-95b1-287297f09fa4","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","goal_id":"M2","period_key":"Q:2…（截断，全长 7551 字符）
    | B push: POST http://127.0.0.1:32785/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-579e28cdae974a3d9ad80ca79d3c90d8","deviceId":"l2-dev-B","lastSyncAt":1792381040838,"clientNow":1792381342097,"tables":{"carbon_record":[{"id":"1c6f7050-1902-40ef-aac4-f5f99fa70fb8","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","category":"recycle","sub_type":"aluminum","amount":7,"unit":"kg","occurred_at":1792377437925,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-B版","created_at":1792381099929,"updated_at":1792381099929,"is_deleted":0,"device_id":"l2-dev-B","sync_state":"pending"}],"point_record":[],"user_goal":[{"id":"799ce082-c5…（截断，全长 6370 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":20,"ignored":0,"rejected":20,"conflicts":0,"serverTime":1792381042175,"offsetMs":-299946,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"1c6f7050-1902-40ef-aac4-f5f99fa70fb8","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","category":"recycle","sub_type":"aluminum","amount":42.0,"unit":"kg","occurred_at":1792377437925,"reduction_kg":18.0,"factor_value":9.0,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":1792381099929,"updated_at":1792381099929,"is_deleted":0,"device_id":"l2-dev-Z"}],"user_goal":[{"id":"799ce082-c5eb-4e83-991d-7f2f5a19ab9c","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792381099929,"updated_at":1792381099929,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"f57115c1-2edb-4e80-a7bd-7d43826c102c","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","goal_id":"M1","period_key":"M:2026-10","progress":0.0,"threshold":100.0,"settled":0,"settled_at":null,"created_at":1792381099929,"updated_at":1792381099929,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"264e4ee7-a963-4b91-95b1-287297f09fa4","user_id":"u-579e28cdae974a3d9ad80ca79d3c90d8","goal_id":"M2","period_key":"Q:2…（截断，全长 7551 字符）
    | A 库: amount=5 category=recycle confidence=provisional created_at=1792381099929 device_id=l2-dev-A factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=1c6f7050-1902-40ef-aac4-f5f99fa70fb8 is_abnormal=0 is_deleted=0 note=平局-A版 occurred_at=1792377437925 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=synced unit=kg updated_at=1792381099929 user_id=u-579e28cdae974a3d9ad80ca79d3c90d8
    | B 库: amount=7 category=recycle confidence=provisional created_at=1792381099929 device_id=l2-dev-B factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=1c6f7050-1902-40ef-aac4-f5f99fa70fb8 is_abnormal=0 is_deleted=0 note=平局-B版 occurred_at=1792377437925 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=synced unit=kg updated_at=1792381099929 user_id=u-579e28cdae974a3d9ad80ca79d3c90d8
[FAIL] #3.2 两端最终行**逐列完全相同**（不是"服务端返回 accepted"就算），且与服务端那一份同一版本
    | A 库: amount=5 category=recycle confidence=provisional created_at=1792381099929 device_id=l2-dev-A factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=1c6f7050-1902-40ef-aac4-f5f99fa70fb8 is_abnormal=0 is_deleted=0 note=平局-A版 occurred_at=1792377437925 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=synced unit=kg updated_at=1792381099929 user_id=u-579e28cdae974a3d9ad80ca79d3c90d8
    | B 库: amount=7 category=recycle confidence=provisional created_at=1792381099929 device_id=l2-dev-B factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=1c6f7050-1902-40ef-aac4-f5f99fa70fb8 is_abnormal=0 is_deleted=0 note=平局-B版 occurred_at=1792377437925 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=synced unit=kg updated_at=1792381099929 user_id=u-579e28cdae974a3d9ad80ca79d3c90d8
    | 服务端: amount=42 category=recycle confidence=provisional created_at=1792381099929 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=1c6f7050-1902-40ef-aac4-f5f99fa70fb8 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377437925 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792381099929 user_id=u-579e28cdae974a3d9ad80ca79d3c90d8
    | 差异列: amount: A=5 B=7 ; device_id: A=l2-dev-A B=l2-dev-B ; note: A=平局-A版 B=平局-B版
[FAIL] #3.3 负向对照：对端 deviceId 更小（l2-dev-0 < l2-dev-A / l2-dev-B）且 updated_at 相等 ⇒ 两端各自保留本机版本，不采纳对端
    | 服务端构造后: amount=99 category=recycle confidence=provisional created_at=1792381132320 device_id=l2-dev-0 factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=63eca656-956d-44a1-ab32-550eb25e2785 is_abnormal=0 is_deleted=0 note=平局2-0版 occurred_at=1792377437925 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass unit=kg updated_at=1792381132320 user_id=u-579e28cdae974a3d9ad80ca79d3c90d8
    | A 库（应保留本机）: amount=99 category=recycle confidence=provisional created_at=1792381132320 device_id=l2-dev-0 factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=63eca656-956d-44a1-ab32-550eb25e2785 is_abnormal=0 is_deleted=0 note=平局2-0版 occurred_at=1792377437925 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=local unit=kg updated_at=1792381132320 user_id=u-579e28cdae974a3d9ad80ca79d3c90d8
    | B 库（应保留本机）: amount=99 category=recycle confidence=provisional created_at=1792381132320 device_id=l2-dev-0 factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=63eca656-956d-44a1-ab32-550eb25e2785 is_abnormal=0 is_deleted=0 note=平局2-0版 occurred_at=1792377437925 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=local unit=kg updated_at=1792381132320 user_id=u-579e28cdae974a3d9ad80ca79d3c90d8
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
   还原后 sha256 = c572574dec3a9d355c2d005d9266e4f21eb5b6b53f832161118cde4076089d86
```

```text
RESULT: checks=7 passed=7 failed=0   ← git show 还原后（必须 0）
```

```text
[PASS] #3.1 对端 deviceId 字典序更大（l2-dev-Z > l2-dev-A / l2-dev-B）且 updated_at 完全相等 ⇒ 客户端平局分支采纳对端版本（SyncService.ets:659）
    | 平局构造：本机 A=(updated_at=1792381108771, device_id=l2-dev-A, note=平局-A版) / 本机 B=(updated_at=1792381108771, device_id=l2-dev-B, note=平局-B版) / 服务端=(updated_at=1792381108771, device_id=l2-dev-Z, note=平局-Z版)
    | A 侧 set_row 回读: {"id":"e6395f1f-1493-4144-8be8-83f4728e4653","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","category":"recycle","sub_type":"aluminum","amount":5,"unit":"kg","occurred_at":1792377446847,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-A版","created_at":1792381108771,"updated_at":1792381108771,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"}
    | B 侧 set_row 回读: {"id":"e6395f1f-1493-4144-8be8-83f4728e4653","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","category":"recycle","sub_type":"aluminum","amount":7,"unit":"kg","occurred_at":1792377446847,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-B版","created_at":1792381108771,"updated_at":1792381108771,"is_deleted":0,"device_id":"l2-dev-B","sync_state":"pending"}
    | 服务端构造后: amount=42 category=recycle confidence=provisional created_at=1792381108771 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e6395f1f-1493-4144-8be8-83f4728e4653 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377446847 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792381108771 user_id=u-738d91729cb44ef68ec07c1c03bab7d0
    | A push（时钟超前 5 分钟 ⇒ 上行被判更旧）: POST http://127.0.0.1:32785/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-738d91729cb44ef68ec07c1c03bab7d0","deviceId":"l2-dev-A","lastSyncAt":1792381049382,"clientNow":1792381350515,"tables":{"carbon_record":[{"id":"e6395f1f-1493-4144-8be8-83f4728e4653","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","category":"recycle","sub_type":"aluminum","amount":5,"unit":"kg","occurred_at":1792377446847,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-A版","created_at":1792381108771,"updated_at":1792381108771,"is_deleted":0,"device_id":"l2-dev-A","sync_state":"pending"}],"point_record":[],"user_goal":[{"id":"3fe3d140-ad…（截断，全长 6389 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":20,"ignored":0,"rejected":20,"conflicts":0,"serverTime":1792381050591,"offsetMs":-299947,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"e6395f1f-1493-4144-8be8-83f4728e4653","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","category":"recycle","sub_type":"aluminum","amount":42.0,"unit":"kg","occurred_at":1792377446847,"reduction_kg":18.0,"factor_value":9.0,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":1792381108771,"updated_at":1792381108771,"is_deleted":0,"device_id":"l2-dev-Z"}],"user_goal":[{"id":"3fe3d140-ad21-4938-8e52-ed54bd81f89d","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792381108771,"updated_at":1792381108771,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"89e407b1-4749-4350-84e6-9a21366e7ada","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","goal_id":"M1","period_key":"M:2026-10","progress":0.0,"threshold":100.0,"settled":0,"settled_at":null,"created_at":1792381108771,"updated_at":1792381108771,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"d9d0f820-18db-4983-a005-34f670b6e93c","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","goal_id":"M2","period_key":"Q:2…（截断，全长 7551 字符）
    | B push: POST http://127.0.0.1:32785/api/v1/sync/push → HTTP 200
      req:  {"userId":"u-738d91729cb44ef68ec07c1c03bab7d0","deviceId":"l2-dev-B","lastSyncAt":1792381049685,"clientNow":1792381350842,"tables":{"carbon_record":[{"id":"e6395f1f-1493-4144-8be8-83f4728e4653","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","category":"recycle","sub_type":"aluminum","amount":7,"unit":"kg","occurred_at":1792377446847,"reduction_kg":18,"factor_value":9,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-B版","created_at":1792381108771,"updated_at":1792381108771,"is_deleted":0,"device_id":"l2-dev-B","sync_state":"pending"}],"point_record":[],"user_goal":[{"id":"3fe3d140-ad…（截断，全长 6370 字符）
      resp: {"ok":true,"data":{"accepted":0,"skipped":20,"ignored":0,"rejected":20,"conflicts":0,"serverTime":1792381050928,"offsetMs":-299947,"clockWarning":null,"acceptedByTable":{},"merged":{"carbon_record":[{"id":"e6395f1f-1493-4144-8be8-83f4728e4653","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","category":"recycle","sub_type":"aluminum","amount":42.0,"unit":"kg","occurred_at":1792377446847,"reduction_kg":18.0,"factor_value":9.0,"factor_version":"CF-2026.2","factor_source":"SRC-CALC","confidence":"provisional","point_awarded":200,"point_capped":1,"revision":0,"is_abnormal":0,"note":"平局-Z版","created_at":1792381108771,"updated_at":1792381108771,"is_deleted":0,"device_id":"l2-dev-Z"}],"user_goal":[{"id":"3fe3d140-ad21-4938-8e52-ed54bd81f89d","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","goal_id":"L1","period_key":"L:2026-10-19","progress":1.0,"threshold":80.0,"settled":0,"settled_at":null,"created_at":1792381108771,"updated_at":1792381108771,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"89e407b1-4749-4350-84e6-9a21366e7ada","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","goal_id":"M1","period_key":"M:2026-10","progress":0.0,"threshold":100.0,"settled":0,"settled_at":null,"created_at":1792381108771,"updated_at":1792381108771,"is_deleted":0,"device_id":"l2-dev-A"},{"id":"d9d0f820-18db-4983-a005-34f670b6e93c","user_id":"u-738d91729cb44ef68ec07c1c03bab7d0","goal_id":"M2","period_key":"Q:2…（截断，全长 7551 字符）
    | A 库: amount=42 category=recycle confidence=provisional created_at=1792381108771 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e6395f1f-1493-4144-8be8-83f4728e4653 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377446847 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792381108771 user_id=u-738d91729cb44ef68ec07c1c03bab7d0
    | B 库: amount=42 category=recycle confidence=provisional created_at=1792381108771 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e6395f1f-1493-4144-8be8-83f4728e4653 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377446847 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792381108771 user_id=u-738d91729cb44ef68ec07c1c03bab7d0
[PASS] #3.2 两端最终行**逐列完全相同**（不是"服务端返回 accepted"就算），且与服务端那一份同一版本
    | A 库: amount=42 category=recycle confidence=provisional created_at=1792381108771 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e6395f1f-1493-4144-8be8-83f4728e4653 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377446847 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792381108771 user_id=u-738d91729cb44ef68ec07c1c03bab7d0
    | B 库: amount=42 category=recycle confidence=provisional created_at=1792381108771 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e6395f1f-1493-4144-8be8-83f4728e4653 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377446847 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum sync_state=local unit=kg updated_at=1792381108771 user_id=u-738d91729cb44ef68ec07c1c03bab7d0
    | 服务端: amount=42 category=recycle confidence=provisional created_at=1792381108771 device_id=l2-dev-Z factor_source=SRC-CALC factor_value=9 factor_version=CF-2026.2 id=e6395f1f-1493-4144-8be8-83f4728e4653 is_abnormal=0 is_deleted=0 note=平局-Z版 occurred_at=1792377446847 point_awarded=200 point_capped=1 reduction_kg=18 revision=0 sub_type=aluminum unit=kg updated_at=1792381108771 user_id=u-738d91729cb44ef68ec07c1c03bab7d0
    | 差异列: 无
[PASS] #3.3 负向对照：对端 deviceId 更小（l2-dev-0 < l2-dev-A / l2-dev-B）且 updated_at 相等 ⇒ 两端各自保留本机版本，不采纳对端
    | 服务端构造后: amount=99 category=recycle confidence=provisional created_at=1792381141090 device_id=l2-dev-0 factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=0caee823-ccd8-43be-b43c-1de15346dd01 is_abnormal=0 is_deleted=0 note=平局2-0版 occurred_at=1792377446847 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass unit=kg updated_at=1792381141090 user_id=u-738d91729cb44ef68ec07c1c03bab7d0
    | A 库（应保留本机）: amount=4 category=recycle confidence=provisional created_at=1792381141090 device_id=l2-dev-A factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=0caee823-ccd8-43be-b43c-1de15346dd01 is_abnormal=0 is_deleted=0 note=平局2-A版 occurred_at=1792377446847 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=synced unit=kg updated_at=1792381141090 user_id=u-738d91729cb44ef68ec07c1c03bab7d0
    | B 库（应保留本机）: amount=6 category=recycle confidence=provisional created_at=1792381141090 device_id=l2-dev-B factor_source=SRC-CALC factor_value=1 factor_version=CF-2026.2 id=0caee823-ccd8-43be-b43c-1de15346dd01 is_abnormal=0 is_deleted=0 note=平局2-B版 occurred_at=1792377446847 point_awarded=0 point_capped=1 reduction_kg=3 revision=0 sub_type=glass sync_state=synced unit=kg updated_at=1792381141090 user_id=u-738d91729cb44ef68ec07c1c03bab7d0
    | 注：这一支按规则"对端更小 ⇒ 保留本机"，两端各自留住自己那一版；它不是收敛用例，只用来证明比较方向（若把判据反转成"字典序小者胜"，A/B 都会变成平局2-0版 ⇒ 本条与 3.1 同时变红）。
```

**结论**：✅ 反证成立。变异后第 3 项三条断言全部变红（其余 4 条与平局无关的仍绿 ⇒ 变异是"定点"的），
`git show` 还原后同一组全绿 ⇒ 断言确实咬在被测实现上，不是恒真式。

### 3.3 全程零改动（`app/` 一行都没碰）

```text
== 7. 零改动核对（app/ tests/cases/ tests/tools/l1_offline/；server/ docs/ 并行 agent 的改动单列） ==
   干净：app/、tests/cases/、tests/tools/l1_offline/ 零改动（这三处是本任务最该证明没碰的）
   本任务自身产物（未提交则显示为 ??）：?? tests/tools/l2_sync/
   跑完后 app/**/*.ets 全量 sha256 指纹 = b97edf01cc297909caf7c7f886fc6256e50ba43c36586d2a02b8677a847ac626
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

## 4. 发现（本任务 **只报告不修复**；`app/**`、`server/**` 都不在本任务写入范围）

### F1（blocker，客户端 `app/**`）全新设备的**首同步**会撞唯一索引

```
STOP: 客户端 pull 侧只按 id 认领本机行，撞上 user_appearance/user_profile 等唯一索引即抛错，"两台设备首次协同"必然失败
冲突: app/entry/src/main/ets/viewmodel/net/SyncService.ets:641-643（本机行只按 `WHERE id = ?` 查）
      ↔ app/entry/src/main/ets/schema 的 uq_ua / uq_uprofile（user_appearance/user_profile 各按 user_id 唯一）
      ↔ 同一实现 SyncService.ets:678-700（insertRow 的 INSERT 没有 OR IGNORE）
建议: 按 ClientSchema 的业务唯一键（SINGLETON_TABLES 按 user_id；其余按 uq_* 各键）先查再写，或把 insertRow 改成 `INSERT OR IGNORE` + 命中唯一键时转 UPDATE
```

**取证**（第 8.3 节）：全新设备 C 以 `since=0` 做首同步，pull 到 A 那一版 `user_appearance` 时本机按 id 查不到 ⇒ 直接 INSERT ⇒
`UNIQUE constraint failed: user_appearance.user_id`。**触发条件**：任一新设备/新账号的首次协同（每台设备开机都会自建 `user_profile`/`user_appearance`）。
夹具因此把用例摆到"已同步过一次"的稳态（`#0.2` 把 B 的既有唯一键行 id 对齐到 A——这是**前置构造**，不是放宽断言），并单列本项取证。

```text
[PASS] #8.3 缺陷取证（非本任务修复范围）：全新设备 C 的**首同步**（since=0）因 uq_ua 唯一索引抛错 —— 客户端 pull 侧只按 `id` 找本机行，找不到就 INSERT
    | C 是全新库（deviceId=l2-dev-C，库=/tmp/cbl2-R5KLR3/roots-main/C/databases/carbonboo.db.db），账号与 A/B 相同
    | C 本机 user_appearance: [{"id":"d04e3a13-c8ef-4857-9911-f93e94aa2d59","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e"}]
    | 服务端 user_appearance: [{"id":"3f3bdd44-0802-48b3-98e1-bfe32d124abc","user_id":"u-df7db19f6ec14d348457b6bdc1a3618e","updated_at":"1792381010782"}]
    | C 本机 user_profile: {"id":"b7212ff7-97cc-4e8d-8890-da426e524bde","updated_at":1792381032169,"device_id":"l2-dev-C"}，user_appearance: {"id":"d04e3a13-c8ef-4857-9911-f93e94aa2d59","updated_at":1792381032169,"device_id":"l2-dev-C"}
    | 首同步原始错误：Error: UNIQUE constraint failed: user_appearance.user_id
    | 原始栈（节选）：Error: UNIQUE constraint failed: user_appearance.user_id
    at runTolerant (/tmp/cbl2-R5KLR3/build-main/platform/arkdata.cjs:77:25)
    at RdbStoreImpl.executeSql (/tmp/cbl2-R5KLR3/build-main/platform/arkdata.cjs:259:5)
    at RdbStore.exec (/tmp/cbl2-R5KLR3/build-main/out/main/ets/viewmodel/store/RdbStore.js:64:17)
    at SyncService.insertRow (/tmp/cbl2-R5KLR3/build-main/out/main/ets/viewmodel/net/SyncService.js:595:22)
    at SyncService.applyRow (/tmp/cbl2-R5KLR3/build-main/out/main/ets/viewmodel/net/SyncService.js:572:17)
    at process.processTicksAndRejections (node:internal/process/task_queues:103:5)
    at async SyncService.applyPull (/tmp/cbl2-R5KLR3/build-main/out/main/ets/viewmodel/net/SyncService.js:510:28)
    at async SyncService.sync (/tmp/cbl2-R5KLR3/build-main/out/main/ets/viewmodel/net/SyncService.js:130:21)
    at async sync (file:///mnt/c/Users/Administrator/Desktop/CarbonBoo/tests/tools/l2_sync/lib/device.mjs:257:15)
    at async main (file:///mnt/c/Users/Administrator/Desktop/CarbonBoo/tests/tools/l2_sync/lib/device.mjs:330:3)
    | 根因（app/，本任务不改）：app/entry/src/main/ets/viewmodel/net/SyncService.ets:641-643 按 `WHERE id = ?` 找本机行；:676-677 本机没有该行就直接 insertRow；:684-700 的 INSERT 不含 OR IGNORE。
    | 同族表：user_profile(uq_uprofile)、user_goal(uq_ug)、user_badge(uq_ub)、user_purchase(uq_up)、science_progress(uq_sp) 都会在第一台设备已推送、第二台设备本机自建过同名业务键行时撞索引。
    | 影响面：真机 L2「两台设备首次协同」在当前客户端实现下不可完成；本任务据此把夹具摆到"已同步过一次"的稳态（第 0.2 项），并**如实单列本条**。
```

### F2（high，服务端/契约）pull 响应没有 `offsetMs` ⇒ 附录 B §6.4-6 的取反换算是**不可达代码**

```
STOP: 客户端按 `-respOffsetMs` 取反换算，但它读的是 pull 响应；服务端 SyncPullData 没有 offsetMs 字段 ⇒ 恒等于 0
冲突: app/entry/src/main/ets/viewmodel/net/SyncService.ets:578-579（读 pull 体的 offsetMs）
      ↔ server/app/schemas/sync.py:63-68（SyncPullData = {serverTime, since, tables}）
      ↔ server/app/services/sync_service.py:506-517（pull() 也不返回 offset_ms；pull 端点无 clientNow 入参）
      ↔ 客户端 SyncService.ets:181-196（push 响应体被整个丢弃，里面的 offsetMs/merged 从不被消费）
建议: 二选一——① pull 端点接受 clientNow 并在 SyncPullData 回 offsetMs（与 push 同口径）；② 客户端消费 push 响应里的 offsetMs/merged（后者还能省掉一次"被拒行只能靠 pull 收敛"的往返）
```

**影响**：两端时钟不一致时，**服务端**按 `values.updated_at + offset_ms` 比较、却把**原始**时间戳落库（`_apply_update`，`sync_service.py:496-500`），
而**客户端**按裸时间戳比较 ⇒ 两端可能得出相反结论；极端情况下拥有"原始更大时间戳"的那一端会一直拒绝回退（"两端规则不同 ⇒ 结论不一致"）。
**本夹具把换算逻辑本身验通了**（`#4.5`/`#4.6` 用 `lib/proxy.mjs` 把同一轮 push 的 `offsetMs` 补进 pull 响应——**只补这一个字段**，数据面全部来自真服务端），
但**真实服务端不会发这个字段**（`#4.7`），所以真机上这条保护是失效的。

### F3（medium，服务端/客户端同族）两端都真实编辑同一记录 ⇒ 下一次 pull 撞 `uq_pr_source`

**取证**（第 8.4 节）：每次真实 `records.edit` 都会写一条冲正 `point_record`（业务唯一键 `<记录ID>#<revision>#<flow_kind>`），
两端各自生成不同 `id` 的冲正流水；服务端 append_only 侧按业务键去重为 `ignored`，
但客户端 pull 侧同样只按 `id` 找本机行 ⇒ 落到 INSERT ⇒ `UNIQUE constraint failed: point_record.source_id`。
与 F1 同根因（客户端认领本机行的键与 schema 的唯一键不一致），**修复面建议一并处理**。

```text
[PASS] #8.4 缺陷取证二（非本任务修复范围）：两端都走真实 `records.edit` → 各自落出**同业务键不同 id** 的 point_record 反向/正向流水 → 下一次 pull 撞 uq_pr_source
    | A 真实编辑（RecordService.ets:195 无 options 参数）：{"recordId":"e6ccc4d0-d7e9-4f8e-90ae-423921c88354","reductionKg":0.81,"pointExpected":81,"pointAwarded":81,"capped":false,"isAbnormal":false,"newGoals":[],"newBadges":[],"goalPoints":0}
    | B 真实编辑：{"recordId":"e6ccc4d0-d7e9-4f8e-90ae-423921c88354","reductionKg":0.972,"pointExpected":97,"pointAwarded":97,"capped":false,"isAbnormal":false,"newGoals":[],"newBadges":[],"goalPoints":0}
    | 服务端 point_record（该记录）：[{"id":"daf5dae8-af85-4c61-819a-b096ff6456e3","source_id":"e6ccc4d0-d7e9-4f8e-90ae-423921c88354#0","flow_kind":"primary"},{"id":"e5542dbf-fcaa-40bf-922c-139da12ab75f","source_id":"e6ccc4d0-d7e9-4f8e-90ae-423921c88354#0","flow_kind":"reverse"},{"id":"f053d4e7-b879-452b-bce0-af443342a21e","source_id":"e6ccc4d0-d7e9-4f8e-90ae-423921c88354#1","flow_kind":"primary"}]
    | B 本机 point_record（该记录）：[{"id":"daf5dae8-af85-4c61-819a-b096ff6456e3","source_id":"e6ccc4d0-d7e9-4f8e-90ae-423921c88354#0","flow_kind":"primary"},{"id":"0b2d7e4d-6ec3-4c33-9aa0-833f4255d10a","source_id":"e6ccc4d0-d7e9-4f8e-90ae-423921c88354#0","flow_kind":"reverse"},{"id":"0875bda4-085e-40d3-808f-d8f88a07e6fd","source_id":"e6ccc4d0-d7e9-4f8e-90ae-423921c88354#1","flow_kind":"primary"}]
    | B 同步原始错误：Error: UNIQUE constraint failed: point_record.user_id, point_record.source_type, point_record.source_id, point_record.flow_kind
    | 原始栈（节选）：Error: UNIQUE constraint failed: point_record.user_id, point_record.source_type, point_record.source_id, point_record.flow_kind
    at runTolerant (/tmp/cbl2-R5KLR3/build-main/platform/arkdata.cjs:77:25)
    at RdbStoreImpl.executeSql (/tmp/cbl2-R5KLR3/build-main/platform/arkdata.cjs:259:5)
    at RdbStore.exec (/tmp/cbl2-R5KLR3/build-main/out/main/ets/viewmodel/store/RdbStore.js:64:17)
    at SyncService.insertRow (/tmp/cbl2-R5KLR3/build-main/out/main/ets/viewmodel/net/SyncService.js:595:22)
    at SyncService.applyRow (/tmp/cbl2-R5KLR3/build-main/out/main/ets/viewmodel/net/SyncService.js:572:17)
    at process.processTicksAndRejections (node:internal/process/task_queues:103:5)
    at async SyncService.applyPull (/tmp/cbl2-R5KLR3/build-main/out/main/ets/viewmodel/net/SyncService.js:510:28)
    at async SyncService.sync (/tmp/cbl2-R5KLR3/build-main/out/main/ets/viewmodel/net/SyncService.js:130:21)
    at async sync (file:///mnt/c/Users/Administrator/Desktop/CarbonBoo/tests/tools/l2_sync/lib/device.mjs:257:15)
    at async main (file:///mnt/c/Users/Administrator/Desktop/CarbonBoo/tests/tools/l2_sync/lib/device.mjs:330:3)
    | 同族根因：客户端 pull 侧只按 `id` 判重（SyncService.ets:641-643 / 676-677），没有服务端 `_merge_append_only` / `_merge_lww` 那样的业务唯一键判重（server/app/services/sync_service.py:374-403 / 405-470）。
    | 所以本任务第 2、3 项的"B 端离线改"用直接行改写构造，避免把这条客户端缺陷混进协议判据；两条缺陷均如实单列。
```

### F4（观察，非缺陷）`sync_state` 不参与上行过滤

`pushBody` 的上行条件是 `WHERE user_id = ? AND updated_at > ?`（`SyncService.ets:504`），`markSynced` 也按同一条件置 `synced`（`:541`），
`sync_state` 只被 `pendingCount()`（UI 的"待同步数"）使用 ⇒ 客户端**每次同步都是"时间戳窗口内全量重推"**，
而不是"只推 pending 行"。这不影响正确性（幂等靠服务端去重），但"待同步数"与真实上行量不是一回事。

### F5（观察，非缺陷）`skipped` 一词两端不同义

服务端 `skipped = ignored + rejected`（`PushOutcome.skipped`，"跨设备重复已去重 / 越权或非法行"），
客户端 `SyncOutcome.skipped` 是 pull 侧"保留本机版本"的行数（`SyncService.ets:617`）——同名不同义，写用例/看日志时容易误读。

## 5. 覆盖 / 不覆盖边界

**本任务验的是「协议级两端收敛」**：两个独立客户端库 + 真服务端 + 真 HTTP，把附录 B §6 的合并规则跑成两端结论一致的证据。

**不能替代真机 L2**，具体不覆盖：

| 不覆盖 | 原因 |
|---|---|
| UI 与交互（录入向导、协同页、待同步数展示） | `pages/`、`components/` 是 ArkUI `struct`，esbuild 不转译；本任务也不改一行 `app/**` |
| Ability 生命周期（冷启/前后台/进程被杀后恢复、`onCreate` 引导顺序） | 夹具直接调用 Service 层，不跑 `EntryAbility` |
| 端侧权限（网络权限、`WRITE_IMAGEVIDEO` 等）与真机 `relationalStore` 实现细节 | 夹具用 `node:sqlite` 顶替 `relationalStore` 垫片；权限/沙箱行为在真机上才有 |
| 真机系统时间/时区行为（用户改系统时间、跨时区） | 夹具用 `L2_CLOCK_OFFSET_MS` 模拟时钟偏移（等价于"设备时钟不准"，但不是系统级行为） |
| 鸿蒙近场/分布式通路（`discover()` / `nearFieldSync()` / 已配对设备） | 需要真机与分布式软总线；本任务只覆盖**云通路**（账号 + HTTP 同步） |
| 多设备并发（>2 台同时同步）与网络中断重试 | 夹具是两台设备**依次**同步；并发与断网重连属真机/服务端压测范畴 |

## 6. 复现与收工清理

### 6.1 复现（一条命令）

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

### 6.2 收工清理（run.sh 自动做，退出码说明见下）

```text
== 收工清理 ==
   已停 uvicorn（pid=1273246）
   已删除任务专用库 carbonboo_l2_e2e
   原始输出已留档到 /tmp/l2run/evidence（排障/写报告用；默认不留）
   已删除临时目录 /tmp/cbl2-R5KLR3
   退出码=0
RUNSH_EXIT=0
```

清理项：① 停掉自己起的 uvicorn（只停本任务端口那个 pid，不 `pkill` 别人的）；② 删除任务专属库 `carbonboo_l2_e2e`（**不动共享库 `carbonboo`、不动别人的 `carbonboo_test_*`**）；
③ 删除 `mktemp -d` 出来的临时目录（构建产物、两台设备的 `databases/`、wire 日志）；④ `carbonboo-mysql` 容器是共享的，**不停**。

### 6.3 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 八项断言全过 + 两条反证成立 |
| 1 | 有断言失败（或变异未变红 / 还原未变绿） |
| 2 | 环境不可达（Node < 22.5 无 `node:sqlite` / 无 esbuild / docker 或 `carbonboo-mysql` 不可用 / 无 `server/.venv`） |

---

## §7 t62 修订（追加节：修复 F1/F2/F3 之后的夹具证据与门禁）

> **本节是追加的，§0–§6 的原文一字未改。** §0–§6 记录的是 **t57 当轮（修复前）**的真实运行：那一轮把
> F1（blocker：新设备首同步撞 `uq_ua`/`uq_uprofile`）、F2（high：pull 响应无 `offsetMs` ⇒ §6.4-6 取反换算不可达）、
> F3（medium：两端都真实编辑 ⇒ 下一次 pull 撞 `uq_pr_source`）当成**发现**报了出来，
> 并按 AGENTS.md §1.3 给了 STOP 三行。t62 把这三个缺陷**修在**
> `app/entry/src/main/ets/viewmodel/net/SyncService.ets` 里（inScope；未动 `server/**`、`docs/**`），
> 本节给出修复后的逐项实测原始输出、三条「修复现场」断言，以及 F1/F2 的**成对自证**
> （变异必红 / `git show HEAD:<path>` 还原必绿）与编译门禁成对自证。

**本节条目与 §0–§6 的取代关系**

| 本节 | 与 §0–§6 的关系 |
|---|---|
| §7.2 前置 `#0.2` | §2 的 `#0.2` 曾是「把 B 的既有唯一键行 id 对齐到 A」的**绕过**（`lib/device.mjs` 的 `align_singleton` 步骤，已删除）；本节改成硬断言「新设备首同步**就必须成功**」 |
| §7.2 第 3 项（平局） | §2 第 3 项的 Δ=300000 摆法实测与「握手腿实测偏移」相差 57ms ⇒ 平局输入不成立、断言假红；本节改成**逐毫秒确定**的三件套构造（两端 raw `updated_at` 完全相等 + 两端时钟调快使本机上行被服务端拒绝 + `forceOffsetMs=0` 代理） |
| §7.2 第 4 项（4.5/4.6/4.7） | 依 F2 的修法重述：校正值取自 **push 握手腿**（pull 体无该字段时的兜底）；4.6 证明「响应字段优先」，4.7 是「真实 pull 响应不含 `offsetMs`」的事实观测 |
| §7.2 第 8 项（`#8.3`/`#8.4`） | §2 的 `#8.3`/`#8.4` 是「记录崩溃取证」（F1/F3 的原始栈）；本节改成**修复现场断言**（首同步成功 / 按业务键去重不再撞 `uq_pr_source`） |
| §7.3 | 新增：F1/F2 的 L1 成对自证（`passed=12/15`、`passed=14/15` → `git show` 还原后 `15/15`）、四段门禁原始输出、编译门禁成对自证（基线 SUCCESSFUL → 注入未定义引用 FAILED → `git show` 还原后 SUCCESSFUL） |
| §7.4 / §7.5 / §7.6 | 边界、复现清理与未运行项（与 §4/§5/§6 同口径；真机 hypium 执行数仍为 **0**，端侧真机 L2 仍未运行） |

---

- **交付**：`tests/tools/l2_sync/`（`run.sh` + `lib/build.mjs` / `lib/device.mjs` / `lib/l2_run.mjs` / `lib/proxy.mjs` + 本报告 + `README.md`）
- **被测对象**：`app/entry/src/main/ets/viewmodel/net/SyncService.ets`（客户端 pull 合并实现；t62 的 F1/F2/F3 修复点）与 `server/app/**`（真服务端，本报告只读引用，未改一行）
- **实测命令**：`bash tests/tools/l2_sync/run.sh` → **退出码 0**（主用例 35 条断言全过；变异趟必红；`git show` 还原趟必绿）
- **日期**：2026-10-19 ｜ 跑测机：本机 WSL（无 hdc、无模拟器、`/dev/kvm` 不可写 ⇒ **真机 L2 物理不可达**）

> **一句话结论**：用**两个独立客户端的真 SQLite 库 + 真 FastAPI 服务端 + 真 HTTP**，把附录 B §6.4-6「两端用同一规则、结论一致」
> 跑成了可复现证据——**35 条断言全过**，并完成两条反证（出网必须被拒；把客户端平局判据反转必须变红、`git show` 还原必须变绿）。
> t57 用同一套夹具报出的三个客户端缺陷（F1/F2/F3）在 t62 修掉后，`#0.2`/`#8.3`/`#8.4` 就是**修复现场**断言（修复前必红、修复后必绿）。
> **它验的是协议级两端收敛，不能替代真机 L2**：不覆盖 UI、Ability 生命周期、端侧权限、系统时间/时区真实行为与近场通路（边界见 §4）。

### §7.0 结论速览（修复后的实测判定）

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

### §7.1 被验对象、机制与基准

#### 1.1 机制（为什么这些证据可信）

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

#### 1.2 环境（run.sh 自检，缺任一项即退出码 2）

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

#### 1.3 运行规模

- 主用例 **35 条断言**（`#0.1`–`#8.4`），变异趟与还原趟各 7 条（第 3 项那一组）；
- 两台设备 + 一台"全新设备 C"（第 8.3 项），三个独立 `node:sqlite` 库文件；
- 每个请求/响应的原始文本都留档：主用例 wire 日志、变异趟、还原趟各一份（`run.sh` 的 `L2_KEEP_OUT`）。

### §7.2 逐项实测（断言 / 原始输出 / 结论）

#### 前置（0.x）：两台设备真的独立、真的登录、真的各同步一轮

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

#### 第 1 项：基线往返（A 写 → push → B pull → 逐列相同）

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

#### 第 2 项：LWW 收敛（两端各自离线改同一行 → 依次 push/pull）

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

#### 第 3 项：平局按 `deviceId` 字典序（`updated_at` 完全相等）

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

#### 第 4 项：时钟偏移（`offsetMs = 服务端 − 客户端`；客户端须取反换算）

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

#### 第 5 项：幂等（同一批 push 连推两次）

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

#### 第 6 项：软删除传播（A 删 → push → B pull → `is_deleted=1` 且行仍在）

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

#### 第 7 项：冲突计数口径（`ignored` 不得计入 `conflicts`）

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

### §7.3 第 8 项：反证（不是假绿）

#### 3.1 不设 `L1_ALLOW_NETWORK` 时，垫片必须拒绝出网

```text
[PASS] #8.1 不设 L1_ALLOW_NETWORK 时垫片拒绝出网（贴原始错误）；本任务全程在 L1_ALLOW_NETWORK=1 下跑真 HTTP
    | L1_ALLOW_NETWORK=(未设置)
    | 原始错误：离线执行（L1）不出网：拦截了对 http://127.0.0.1:38675/api/v1/config 的请求。L1 里网络必须由用例注入的假实现承担；若确需真网络，显式设 L1_ALLOW_NETWORK=1（这已不属于 L1 的范畴）。
    | 同一进程置 L1_ALLOW_NETWORK=1 时，上面的每一次 sync 都真的打到了 http://127.0.0.1:38675（见各步原始请求/响应）
```

#### 3.2 变异自证：改一处**真实比较规则**必红，`git show` 还原必绿

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

#### 3.3 全程零改动（`app/` 一行都没碰）

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

#### 3.4 t62 修复现场与其余三段门禁

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

### §7.4 覆盖 / 不覆盖边界

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

### §7.5 复现与收工清理

#### 5.1 复现（一条命令）

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

#### 5.2 收工清理（run.sh 自动做）

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

#### 5.3 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 八项断言全过 + 两条反证成立 |
| 1 | 有断言失败（或变异未变红 / 还原未变绿） |
| 2 | 环境不可达（Node < 22.5 无 `node:sqlite` / 无 esbuild / docker 或 `carbonboo-mysql` 不可用 / 无 `server/.venv`） |

### §7.6 未运行项（如实单列）

| 未运行 | 原因 | 现状 |
|---|---|---|
| 真机 hypium 单测执行（`hdc` 跑到设备/模拟器上） | 本机无 `hdc`、无模拟器、`/dev/kvm` 不可写 | 执行数 **0**；§3.4 的 41 条是**离线转译后在 Node 里跑**的，**不等于真机通过** |
| 端侧真机 L2（两条真机跑协同脚本：UI + 生命周期 + 权限 + 近场） | 同上（物理不可达） | 未运行；本报告用协议级夹具替代，边界见 §4 |
| 服务端 L3 pytest 全量 | 属服务端任务范围（本任务只读 `server/**`） | 未在本任务内运行 |


---

## §8 t68 追加节：跨端时间戳基准（服务端落库 / 客户端落库）与严格基准断言

> **绑定提交**：`cee94ff6ff97684043e403a23950bf61f73b68f3`（父 `1b85147 fix(sync): pull 落库换算到客户端基准（§5.3:1097）`）。
> 本节按 t62 的形态**只追加**：§0–§7 原文逐字未改；两者不一致时以本节为准。

### §8.0 结论速览

| # | 契约条款（`docs/APPENDIX-B-data-and-api.md`） | 改前实测 | 改后实测 | 证据 |
|---|---|---|---|---|
| 1 | `:1095`「本机（库内）行已是服务端基准」 | 服务端库内 = **客户端裸时间戳 `T`** | 服务端库内 = **`T + offset_ms`** | §8.2 `fact_probe` 改前/改后原文 |
| 2 | `:1089`「`since` 取服务端基准」的增量边界 | 场景 A **漏行**；场景 B **重复拉** | ✓ 未漏行；✓ 未重复拉 | §8.3 `boundary_probe` 改前/改后原文 |
| 3 | `:1097`「本机业务行的 `updated_at` = 客户端基准」 | pull 落库写**服务端裸值**（本机库两套基准并存） | 落库前换算到**客户端基准** | 提交 `1b85147` + LwwMerge ⑪⑫⑮⑬⑭ |
| 4 | `:1096` 判据（`respOffsetMs=+60000` ⇒ 对端 `T` 在本机显得更旧 `T−60000`） | pull 响应**无** `offsetMs` ⇒ 取反换算在真链路不可达 | 校正取自 **push 握手腿**（`clientOffsetMs = −offsetMs`） | 提交 `1b85147`；本节 §8.5 |
| 5 | 跨端一致性断言形态 | 「两端 `updated_at` 差 **≤3s**」容差 | **严格等价式** `端上值 + offsetMs === 服务端值`（无容差） | §8.5 + §8.6 反证 C |
| 6 | `:1081`（封顶不追回、`ignored` 不计 `conflicts`） | 未涉及 | **未改动**（本任务一行未碰） | `git diff cee94ff -- server/app/services/sync_service.py` 中无封顶计数改动 |

### §8.1 任务与契约依据（逐字引用）

- `docs/APPENDIX-B-data-and-api.md:1095`：判据表里**服务端**一行 —— 「`local_updated > last_sync_at` 且 `int(values["updated_at"]) + offset_ms > last_sync_at` —— **对端（客户端）行加偏移换算到服务端基准；本机（库内）行已是服务端基准**」。
- `:1097`（规范性总则）：**凡跨端使用的时间戳都必须能说清在哪个基准上** —— `clientNow` / 本机业务行的 `updated_at` = **客户端基准**；`serverTime` / `lastSyncAt`（线上）/ 服务端与云端行的 `updated_at` = **服务端基准**。
- `:1089`：`lastSyncAt` 之所以选服务端基准，是因为 `GET /sync/pull?since=` **没有 `clientNow`**，服务端无从换算客户端基准的锚点。
- `:1096` 自证判据：`respOffsetMs = +60000` ⇒ `clientOffsetMs = −60000` ⇒ 服务端时间戳 `T` 在本机基准下是 `T − 60000`（**显得更旧**）。
- 结论：改前服务端把**客户端裸时间戳**落库，是**实现对既有契约的偏离**（不是契约缺口）⇒ 按 `:1095` 修写入路径，**不改文档正文**（`docs/VERIFICATION.md` 只追加，见 §R9）。

### §8.2 定事实（只读实测，真 uvicorn + 真 MySQL）

命令：`cd server && .venv/bin/python /tmp/t68/fact_probe.py`（脚本自挑空闲端口起 uvicorn，`MYSQL_DB=carbonboo_test_t68`，httpx 打真 API、pymysql 直查库，用完杀进程）。

**改前（提交 `cee94ff` 之前）原始输出节选：**

```
push 请求体 clientNow = 1792386683895；行 updated_at(T) = 1792390223895
push 响应：accepted=1 ignored=0 rejected=0 conflicts=0 offsetMs=-59974 serverTime=1792386623929
直查 MySQL：SELECT updated_at, device_id FROM carbon_record WHERE id='rec-t68-a' ⇒ {'updated_at': 1792390223895, 'device_id': 't68-dev'}
判定：库内 updated_at = 1792390223895
      T + offsetMs   = 1792390163921  （服务端基准）
      ⇒ 库内是 T（客户端基准！）
```

**改后（`cee94ff`）原始输出节选：**

```
判定：库内 updated_at = 1792393606916
      T + offsetMs   = 1792393606916  （服务端基准）
      ⇒ 库内是 T+offsetMs（服务端基准）
----- 场景 3：客户端钟慢 60000ms 的一行 -----
直查 MySQL：库内 updated_at = 1792397327047；T=1792397267019；T+offsetMs=1792397327047 ⇒ T+offsetMs（服务端基准）
----- 场景 4：同一行再推一次（无 clientNow ⇒ offsetMs=0）-----
直查 MySQL：库内 updated_at = 1792393666877（推的是 T=1792393666877）
```

（场景 4 说明：`clientNow` 缺失时 `offset_ms = 0`，换算退化为恒等、**不得报错也不得漂移**，与改前一致。）

### §8.3 pull 边界自洽（`since` = 上一次的 `serverTime`）

命令：`cd server && .venv/bin/python /tmp/t68/boundary_probe.py`。场景 A = 客户端钟**慢** 60 秒（服务端基准下该行**晚于** `since`），场景 B = 客户端钟**快** 60 秒（服务端基准下该行**早于** `since`）。

**改前：**

```
MySQL: SELECT updated_at FROM carbon_record WHERE id='rec-t68-b1' ⇒ 1792386784841
⇒ 库内是 T（客户端基准，偏离 :1095）
判定：✗ 漏行：该行服务端基准下晚于 since，却没被拉到
判定：✗ 重复拉：该行服务端基准下早于 since，仍被拉回
```

**改后：**

```
⇒ 库内是 T + offsetMs（服务端基准 ✓）   判定：✓ 未漏行（拉到了）
⇒ 库内是 T + offsetMs（服务端基准 ✓）   判定：✓ 未重复拉（正确排除）
```

### §8.4 改了什么（文件:行）

| 文件 | 改动 |
|---|---|
| `server/app/services/sync_service.py` | push 的行循环里、模式分派**之前**插一次换算：`values["updated_at"] = int(values["updated_at"]) + offset_ms`（注释标 §5.3:1095）；`_merge_lww` 去掉 `offset_ms` 形参、比较直接用已换算值（**只换算一次**，避免 ±2×offset 的错误） |
| `server/tests/test_sync.py` | +2 条回归用例：带 `clientNow`（`offsetMs≠0` ⇒ 库内 = `raw + offset_ms`）/ 不带 `clientNow`（`offsetMs=0` ⇒ 库内 = `raw`，不报错） |
| `tests/tools/l2_sync/lib/l2_run.mjs` | 新增 `basisOf(row, offsetMs)` / `offsetOf(run)`；把 1.2/1.3/1.4/2.2/2.3/2.4/6.3 的「差值 ≤3s」换成严格等价式；4.9 改成不变式 + 「服务端值只能是单次换算值」；4.10 改成逐字节相等；1.3/3.4/4.1/4.2/4.3 的期望值从「服务端存裸值」改为「服务端存服务端基准值」 |
| `tests/tools/l2_sync/lib/build.mjs` | 新增 `--mutate=offset-1000`（把 `out['updated_at'] = updatedAt;` 改成 `+ 1000`），只改构建副本 |
| `tests/tools/l2_sync/run.sh` | 新增反证 C 一腿（变异 ⇒ 必红；`git show` 还原 + `cmp` ⇒ 必绿），汇总与退出码纳入 |

### §8.5 为什么可以（也必须）**严格**相等，而不是容差

`offsetMs` 的定义是 **服务端 − 客户端**（`:1087-1090`），客户端落库用 `clientOffsetMs = −offsetMs`（`:1096`）。于是：

- 该轮 push 被服务端接受 ⇒ 服务端存的就是 `本机上行值 + offset_ms` ⇒ `本机值 + offsetMs === 服务端值` **恒等**；
- 该轮 push 被服务端拒绝 ⇒ 本机采纳的是 `服务端存量 − offsetMs`（pull 落库换算）⇒ 同一条等式**仍然恒等**。

两条分支都不含"要容差才成立"的项，因为**同一次 sync 调用里 push 与 pull 用的是同一个 `offsetMs`**（push 响应测得、客户端取反后传给 `applyPull`）。`updated_at` 的基准差就是两端时钟偏移本身（几十 ms～几分钟），只有**换算不参与**的那部分（例如"本机自写行与自己的 T9"这种同侧比较）才允许容差，本节里只剩 4.9 的"本机值 ± 抖动"一条，并在断言里明写理由。

### §8.6 反证 C：1000ms 的换算偏差必须让严格断言变红

`bash tests/tools/l2_sync/run.sh` 的第 6b 段：构建副本注入 `--mutate=offset-1000` ⇒ 跑严格组（`L2_ONLY=baseline,lww,delete,clock`）。

```
变异副本 sha256 = <见运行日志>（仓库原件 3a6f8de87b9b51279ba33c35c66e9c3cdfdbba1c3e45c22729b181e2eb588739）
RESULT: checks=24 passed=16 failed=8
失败项：#1.2 #1.3 #1.4 #2.2 #2.3 #2.4 #6.3 #4.9
[stderr 无] 退出码 = 1（必须非 0）
```

红的 8 条**恰好全是严格基准断言**（1.2/1.3/1.4/2.2/2.3/2.4/6.3/4.9）；`git show cee94ff:app/entry/src/main/ets/viewmodel/net/SyncService.ets > <构建副本>` + `cmp` ⇒ 逐字节一致 ⇒ `--skip-copy` 原处重转译 ⇒

```
RESULT: checks=24 passed=24 failed=0     退出码 = 0
```

⇒ 「±3s 容差会把 1000ms 级符号/倍率错误吃成绿」这条风险被实证排除。

### §8.7 四段门禁（原始输出节选）

| 门禁 | 命令 | 结果 |
|---|---|---|
| 服务端 pytest | `cd server && CARBONBOO_TEST_DB=carbonboo_test_t68 .venv/bin/python -m pytest tests/ -q` | `243 passed, 1 warning in 252.99s`（`PYTEST_EXIT=0`） |
| L1 hypium（离线转译执行） | `bash tests/tools/l1_offline/run_tests.sh; echo "TESTS_EXIT=$?"` | `RESULT: it_executed=41 passed=41 failed=0 requires_device=0`（`TESTS_EXIT=0`） |
| L1 纯逻辑 | `bash tests/tools/l1_offline/run.sh; echo "RUN_EXIT=$?"` | `RESULT: PASS=55 FAIL=0`、`RESULT: checked=323 passed=true mismatches=0`（`RUN_EXIT=0`） |
| L0 | `python3 tests/tools/check_l0.py --strict; echo "L0_EXIT=$?"` | `结论：PASS —— 基准自洽，文档无已知冲突`（`L0_EXIT=0`） |
| L2 夹具 | `bash tests/tools/l2_sync/run.sh; echo "L2_EXIT=$?"` | 主用例 `RESULT: checks=38 passed=38 failed=0`；三条反证腿（平局反转 / 换算多 1000ms）均红、还原均绿；`L2_EXIT=0` |

### §8.8 覆盖 / 不覆盖边界（本节新增部分）

- **覆盖**：跨端时间戳**基准**（服务端落库、客户端落库、`since` 增量边界）在**真 HTTP + 真 FastAPI + 两个独立 node:sqlite 客户端库**上的端到端行为；严格基准等价式与它的负向对照。
- **不覆盖（与 §7.4 一致，本节未改变）**：真机 L2（UI、Ability 生命周期、端侧权限、系统时间/时区、近场通路）；真机 hypium 执行（执行数 0，只有离线转译执行）；`/admin` 浏览器交互；`server/deploy/` 部署实测。
- **未决问题**：① 客户端 pull 侧的校正完全依赖**同一次 sync 的 push 握手腿**；若将来服务端在 pull 响应里回 `offsetMs`，客户端会**优先用响应字段**（`1b85147` 已实现优先级），无需再改。② push 腿非 200 时整轮失败、不落库（`1b85147` 未改该行为）。③ 本节的严格等价式对**多轮重推**场景只保证「服务端值 ∈ 单次换算候选集」（4.9 的 `noAccum9`），因为服务端会拒绝换算后更旧的重复上行、保留上一轮的值。
