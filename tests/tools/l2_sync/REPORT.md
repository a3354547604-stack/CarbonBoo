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
