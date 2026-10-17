# CarbonBoo 服务端（FastAPI + SQLAlchemy 2.x + MySQL 8）

> 切片：**t3 服务端地基**（账号体系与鉴权隔离）+ **t5 服务端续建**（多设备同步 / 商品取价 / 云端备份 / 部署脚本）。
> 口径来源（唯一真相，冲突时按 `AGENTS.md` §1.2 优先级裁决）：
> `docs/APPENDIX-B-data-and-api.md`（表与接口）、`docs/adr/0001-account-and-sync.md`（账号与同步决策）、
> `docs/PLAN.md` §4.2/§4.3/§5.2/§7.8/§12、`AGENTS.md` §6/§7.2。
> 服务端是**必做件**（账号 + 多设备同步 + 商品取价 + 云端备份）；唯一可选项是 Web 后台管理端。

**已做**：21 张表 DDL、ORM 模型、配置/连接池/安全/错误/限流、5 个账号接口、`AuthProvider` 抽象、
双 JWT 密钥隔离、注销 30 天保留与恢复、**3 个同步接口 + 3 个云端备份接口 + 1 个取价接口**、
增量迁移执行器、部署脚本（systemd / nginx+TLS / 防火墙 / `mysqldump` 定时备份）、L3 测试 **127 例**。
**未做**（后续切片，写入范围互斥）：Web 管理后台（t6，落在 `server/admin_web/`，经 `main.py` 的挂载点接入）。

---

## 1. 快速开始

```bash
cd server

# ① 依赖（Python 3.11+；本机 pypi.org 不可达，统一走阿里云镜像）
python3.11 -m venv .venv
.venv/bin/pip install -r requirements.txt -i https://mirrors.aliyun.com/pypi/simple/

# ② 配置：复制样例并填两把互不相同的密钥（≥32 字符）
cp .env.example .env
python3 -c "import secrets;print(secrets.token_urlsafe(48))"   # 执行两次，分别填 JWT_SECRET / ADMIN_JWT_SECRET
chmod 600 .env                                                 # ★ 硬性要求（AGENTS §6）

# ③ 建库建表（21 张表，可重复执行）
mysql -h127.0.0.1 -P3306 -uroot -p < sql/schema.sql                 # 建库 + 21 张表 + 索引
mysql -h127.0.0.1 -P3306 -uroot -p carbonboo < sql/seed.sql          # 静态字典种子（可选但推荐）
bash deploy/migrate.sh carbonboo                                     # 增量迁移（幂等；见 §7.5）
# 本机 WSL 没装 mysql 客户端时，可让容器代跑（下面用容器名 carbonboo-mysql）：
#   docker exec -i carbonboo-mysql mysql -uroot -p*** < sql/schema.sql
#   docker exec -i carbonboo-mysql mysql -uroot -p*** carbonboo < sql/seed.sql
#   （迁移同样可让容器代跑：docker exec -i carbonboo-mysql mysql -uroot -p*** carbonboo < sql/migrations/001_*.sql）

# ④ 启动（与 AGENTS §7.2 一致：2 个 worker）
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 2
# 接口文档（dev/test 默认开）：http://127.0.0.1:8000/docs
# 探活：curl -s http://127.0.0.1:8000/api/v1/health
# 取价（无需令牌）：curl -s http://127.0.0.1:8000/api/v1/shop/items
```

没有本机 MySQL 时（开发用容器，与生产无关）：

```bash
docker run -d --name carbonboo-mysql -p 127.0.0.1:13307:3306 \
  -e MYSQL_ROOT_PASSWORD=rootpw_dev_only -e MYSQL_DATABASE=carbonboo \
  -e MYSQL_USER=carbonboo -e MYSQL_PASSWORD=carbonboo_dev_pw mysql:8.0 \
  --max-connections=30 --innodb-buffer-pool-size=256M --performance-schema=OFF \
  --character-set-server=utf8mb4 --collation-server=utf8mb4_0900_ai_ci
# 端口选 13307 只是避开本机已占用的 13306；MySQL 仍只监听 127.0.0.1（AGENTS §6）
```

L3 测试（**真实 MySQL**，不 mock 数据库）：

```bash
cd server
source .venv/bin/activate        # 激活后 `python` 即本工程解释器（本机 WSL 无 python 命令、系统 python3 无 pytest）
python -m pytest tests/ -q       # 127 passed；不激活时等价写法：.venv/bin/python -m pytest tests/ -q
# 连接信息默认读 server/.env，但**强制把库名换成 <MYSQL_DB>_test**（carbonboo_test）后才清表。
# 覆盖方式（环境变量优先于 .env，便于没有 .env 的干净检出：开发机 / CI）：
#   MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD     连接库
#   MYSQL_ADMIN_USER / MYSQL_ADMIN_PASSWORD                   仅用于 CREATE DATABASE 测试库
#   CARBONBOO_TEST_DB                                         改成别的测试库名（默认 carbonboo_test）
# 例（本机容器在 13307，无 .env 也能跑）：
#   MYSQL_PORT=13307 MYSQL_USER=carbonboo MYSQL_PASSWORD=... MYSQL_ADMIN_USER=root MYSQL_ADMIN_PASSWORD=... \
#     python -m pytest tests/ -q
# 测试库名不含 test → 直接拒绝执行（避免清掉真库）；数据库不可达 → 直接 fail（不静默 skip）。
```

---

## 2. 目录结构（与 `docs/PLAN.md` §5.2 的偏离，已声明）

```
server/
├── app/
│   ├── main.py                 # create_app：路由 + 异常处理器 + /admin 隔离中间件 + 可选后台挂载点
│   ├── core/                   # PLAN §5.2 的 config.py / database.py / security.py 收进 core/，另加 errors.py、ratelimit.py
│   ├── models/                 # 21 张表 ORM（account / ledger / goal / badge / shop / content / profile）
│   ├── schemas/                # Pydantic v2 请求/响应模型（auth / sync / shop / common）
│   ├── api/v1/                 # auth.py（账号）、sync.py（同步）、backup.py（云端备份/恢复）、shop.py（取价）、__init__.py 挂 health
│   └── services/               # auth_provider.py（账号抽象）、sync_service.py（LWW 合并）、
│                               #   shop_service.py（取价）、backup_service.py（快照/恢复）
├── sql/schema.sql              # 21 张表 DDL（自附录 B §1.2/§1.3/§3 程序化生成，可重复执行）
├── sql/seed.sql                # 静态字典种子（目标 11 / 徽章 8 / 商品 9 / 头像 8 / 碳普惠 5 / 因子镜像 31）
├── sql/migrations/             # ★ t5 新增：增量迁移（001 修 uq_pr_source 的 user_id；幂等，见 README）
├── deploy/                     # ★ t5 新增：migrate.sh / backup-mysql.sh / systemd/* / nginx/*（见 deploy/README.md）
├── tests/                      # conftest.py（真实 DB 夹具 + 迁移执行）+ test_auth.py + test_authz.py + test_sync.py + test_shop.py
└── admin_web/                  # ★ 本切片不存在，由 t6 新建：admin_web/mount.py 提供 mount_admin(app)
```

偏离理由：附录 B/PLAN 的目录草案是"一次列全"，而本切片只建账号地基；把基础设施收进 `core/`、
把 router 收进 `api/v1/` 可以让 t5/t6 各自新增文件而**不改动本切片的任何文件**（写入范围互斥）。

**给 t6 的接缝（本切片已固定）**：`app/main.py` 末尾是

```python
try:
    from admin_web.mount import mount_admin
    mount_admin(app)
except Exception:   # 目录不存在/导入失败 → 静默跳过，服务端不受影响
    pass
```

另提供 `app.core.security.require_admin` 依赖（管理端令牌校验，客户端令牌一律 401）与
`ADMIN_JWT_SECRET` / `JWT_ADMIN_AUDIENCE=carbonboo-admin` 配置项；`admin_op_log` 表可直接复用做后台审计。

---

## 3. 21 张表与附录 B 的对应

`sql/schema.sql` = **19 张客户端同名表去掉 `science_article`（服务端不建）→ 18 张 + 3 张管理表**。

| 组 | 表 |
|---|---|
| 账本/积分（§1.2） | `carbon_record`、`carbon_factor_meta`、`point_record`、`point_daily_stat` |
| 目标/徽章 | `goal_def`、`user_goal`、`badge_def`、`user_badge` |
| 商店/外观 | `shop_item`、`user_purchase`、`user_appearance` |
| 内容/协同 | `science_progress`、`carbon_include`、`share_record`、`sync_log` |
| 用户/设备/配置 | `user_profile`、`device_info`、`app_config` |
| 管理表（§3） | `server_user`、`admin_user`、`admin_op_log` |

类型映射（附录 B §1.3）：`id TEXT PK` → `VARCHAR(36) PRIMARY KEY`；`user_id` → `VARCHAR(36)`；
`device_id` → `VARCHAR(64)`；`INTEGER` 布尔标记 → `TINYINT`；`*_at` 毫秒戳 → `BIGINT`；其余 `INTEGER` → `INT`；
`REAL` → `DOUBLE`；其余 `TEXT` 按列语义取 `VARCHAR(n)`/`TEXT`。通篇 `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`。

两条容易踩的契约：

- **服务端不建 `sync_state` 列**（§1.3：该列只存在于客户端；"待同步数"由端侧统计）。
- **`server_user` 不存 `device_id`**（B35 修复写入的尾注）：`deviceId` 只出现在 §5.3 同步请求体与业务行
  `device_id` 列；§5.2 的注册/登录请求体**不接收** `deviceId`（客户端多传的字段被忽略，见 §5）。
- MySQL 8 没有 `CREATE INDEX IF NOT EXISTS`，所以客户端侧的 `CREATE INDEX` 已折算进建表语句的
  `KEY` / `UNIQUE KEY` 子句 —— 保证 `schema.sql` **可重复执行**（已在真库连续跑两次验证）。
- 索引/唯一键名与附录 B §2 同名，例如 `uq_pr_source`、`uq_ug(user_id, goal_id, period_key)`、
  `uq_uprofile(user_id)`。**一处有意偏离**：`uq_pr_source` 加了 `user_id`
  （原文 §2:142 是 `(source_type, source_id, flow_kind)`）—— 服务端多账号共库，而 `source_id`
  取值口径（§2:135-138）不含账号维度，两个账号同一天达成同名目标会互相顶掉（后入账者丢积分）。
  基线已改，老库用 `sql/migrations/001_uq_pr_source_user_id.sql` 补；文档侧待修正项见 §9。

`sql/seed.sql` 全部 `INSERT ... ON DUPLICATE KEY UPDATE`，可重复执行；不改业务数值口径：
目标 11 条（S1 20 / S2 20 / S3 15 / S4 40 / S5 60 / M1 200 / M2 300 / M3 200 / M4 150 / M5 500 / L1 1000）、
徽章 8 条、商品 9 条（含 `theme_default` 价 0 且 `isDefaultFree=1`，`frame_*` 合计 51000）、头像 8 条、碳普惠 5 条、
因子库元数据 1 条（`carbon_factor_meta.id = CF-2026.2`，注明"30 条因子 + `CAR_OWN_FACTOR` = 31 项"，
服务端只登记版本、不参与碳计算）、`app_config` 3 条（`points_daily_cap=200`、`shop_items_version`、
`account_purge_retention_days=30`）。
**不插入任何 `admin_user`**（AGENTS §6 要求后台强口令，请自行生成 bcrypt 哈希后插入）：

```bash
.venv/bin/python -c "from passlib.hash import bcrypt;import getpass;print(bcrypt.using(rounds=12).hash(getpass.getpass()))"
```

---

## 4. 接口契约（`/docs` 可见）

| 方法 | 路径 | 鉴权 | 说明 | 状态码 |
|---|---|---|---|---|
| GET | `/api/v1/health` | 无 | 探活，**扁平结构**（附录 B §5.1） | 200 |
| POST | `/api/v1/auth/register` | 无 | 注册，返回 JWT | **201**（§5.2 `// res 201`） |
| POST | `/api/v1/auth/login` | 无 | 登录，返回 JWT | 200 |
| GET | `/api/v1/auth/me` | 客户端令牌 | 当前用户 | 200 |
| POST | `/api/v1/auth/logout` | 客户端令牌 | 登出（服务端无状态，记 `last_login_at`） | 200 |
| DELETE | `/api/v1/auth/account` | 客户端令牌 | 注销（软删除保留 30 天，期内可恢复） | 200 |
| POST | `/api/v1/sync/push` | 客户端令牌 | 推送增量（§6.3 LWW 合并，返回需回写的行） | 200 |
| GET | `/api/v1/sync/pull?since={ms}` | 客户端令牌 | 拉取增量（`updated_at > since`，含软删除行） | 200 |
| GET | `/api/v1/sync/status` | 客户端令牌 | 云端统计（各表条数、最后时间、最近同步日志） | 200 |
| POST | `/api/v1/sync/backup` | 客户端令牌 | 上传全量快照（只存快照，**不做自动合并**） | 200 |
| GET | `/api/v1/sync/backup` | 客户端令牌 | 下载云端快照（恢复即覆盖的数据源） | 200 |
| POST | `/api/v1/sync/backup/restore` | 客户端令牌 | 用快照覆盖云端副本（覆盖前生成快照） | 200 |
| GET | `/api/v1/shop/items` | **无** | 商品目录与价格（无需令牌；同组的配置下发见下一行，§5.4 / §5.5） | 200 |
| GET | `/api/v1/config` | **无** | 全局可读配置（§5.5；免令牌，与取价同组） | 200 |

响应体（逐字对齐 §5.1/§5.2/§5.3/§5.4/§5.5）：

```jsonc
// GET /api/v1/health —— 注意：health 没有 data 包装
{ "ok": true, "version": "1.0.0", "time": 1762300000000 }
// POST /api/v1/auth/register  res 201
{ "ok": true, "data": { "userToken": "eyJ...", "userId": "u-...", "username": "harry_01" } }
// GET  /api/v1/auth/me
{ "ok": true, "data": { "userId": "u-...", "username": "harry_01" } }
// DELETE /api/v1/auth/account   req { "password": "abc12345" }
{ "ok": true, "data": { "purgeAfter": 1764892000000 } }
// POST /api/v1/sync/push  req { "userId", "deviceId", "lastSyncAt", "clientNow"?, "tables": { 表名: [行] } }
{ "ok": true, "data": { "accepted": 42, "skipped": 3, "ignored": 3, "rejected": 0, "conflicts": 1,
                        "serverTime": 1762300000000, "offsetMs": -1200, "clockWarning": null,
                        "acceptedByTable": { "carbon_record": 41 }, "merged": { "carbon_record": [ ... ] },
                        "errors": [] } }
// GET  /api/v1/sync/pull      res.data = { serverTime, since, tables: { 表名: [行] } }（客户端读这两个键）
// GET  /api/v1/sync/status    res.data = { userId, serverTime, totalRows, tables: [ {name,count,deletedCount,lastUpdatedAt} ],
//                                          devices: [...], lastSync: {direction,status,pushedCount,pulledCount,conflictCount,errorMsg,...} }
// GET  /api/v1/shop/items
{ "ok": true, "data": { "version": "2026.02.01-1", "items": [ { "id": "frame_01", "section": "frame", "name": "嫩芽",
    "description": "初生的绿色", "price": 1500, "icon": "res://frame_01", "order": 1, "onShelf": 1, "isDefaultFree": 0 } ] } }
// GET  /api/v1/config        res.data = ConfigData（§5.5；**免令牌**，与 §5.4 取价同组）
{ "ok": true, "data": { "version": "2026-11-06-1", "pointsDailyCap": 200, "badgesEnabled": true,
                        "goalRewards": [ { "goalId": "S1", "reward": 20 }, { "goalId": "S2", "reward": 20 },
                                         { "goalId": "S3", "reward": 15 } ],
                        "serverTime": 1762300000000 } }
// badgesEnabled 是 **JSON 布尔**（true/false，**不是** 1/0）；goalRewards 取服务端 `goal_def` 逐行、按 `goalId` 升序
// （示例只列 `server/sql/seed.sql` 第 1–3 条，其余省略；`goal_def` 为空时省略该字段 = 客户端用内置种子）
// 失败一律 { "ok": false, "code": "...", "message": "..." }
```

错误码（§5.2 表 + 两个补充码）：

| code | HTTP | 触发 |
|---|:--:|---|
| `USERNAME_TAKEN` | 409 | 用户名已存在 |
| `USERNAME_INVALID` / `PASSWORD_INVALID` | 400 | 用户名非 4–20 位字母数字下划线 / 口令非 6–32 位 |
| `CREDENTIAL_INVALID` | 401 | 用户名或口令错误 |
| `TOKEN_EXPIRED` / `TOKEN_INVALID` | 401 | 令牌过期 / 非法、账号已注销 |
| `FORBIDDEN` | 403 | 客户端令牌访问 `/admin/*`；**同步/备份**请求体 `userId` 或行内 `user_id` 与令牌账号不一致 |
| `NOT_FOUND` | 404 | 路由或资源不存在 |
| `RATE_LIMITED` | 429 | 登录限流（`LOGIN_RATE_LIMIT_PER_MINUTE`，键 = IP + 用户名） |
| `SERVER_ERROR` | 500 | 服务端异常（**未预期异常也走统一信封**，不回显异常文本） |
| `INVALID_REQUEST` | 400 | **补充码**：请求体结构/类型不合法；同步/备份里**出现 9 张参与同步表之外的表名**也走它（不静默丢数据） |

用户名/口令口径逐字取 §5.2 错误码表（"4–20 位字母数字下划线"、"6–32 位"），因此文档示例
`harry_01` / `abc12345` **必须能注册成功** —— `tests/test_auth.py::test_documented_example_credentials_are_accepted`
就是这条口径的守门测试（不得加"必须含符号/大小写"之类的额外强度规则）。

### 双 JWT 密钥隔离（AGENTS §7.2）

- 密钥 ① `JWT_SECRET` + `audience=carbonboo-client` → 客户端令牌；密钥 ② `ADMIN_JWT_SECRET` + `audience=carbonboo-admin` → 管理端令牌。
- **客户端令牌访问任何 `/admin/*` 一律 403**：由 `app/main.py` 的 HTTP 中间件在**进入路由之前**判定（即使某一层漏加鉴权依赖也进不去）。
- 校验同时看**密钥 + audience**（双重），所以只换密钥维度或只换 audience 维度都不通用：
  `test_authz.py` 断言了双向不通用（用户令牌→`decode_admin_token` 失败、管理令牌→`decode_user_token` 失败、管理令牌调 `/api/v1/auth/me` → 401）。
- 反向：管理端令牌调客户端接口 → 401 `TOKEN_INVALID`。`/admin/*` 在未挂载时是 **404**（不是 403）。

---

## 5. `AuthProvider` 抽象（ADR-0001 / 附录 B §7.1）

`app/services/auth_provider.py`：

```python
AuthProviderId = Literal["local", "server", "huaweiId"]        # server / huaweiId 为预留
class AuthProvider(ABC):                                       # id + 六方法
    def is_available(self) -> bool
    def register(self, username, password) -> AuthSession
    def login(self, username, password) -> AuthSession
    def logout(self, session) -> None
    def current_session(self, token) -> AuthSession
    def delete_account(self, token, password) -> int           # 返回物理清除时间戳（毫秒）
```

- **接口层（`app/api/v1/auth.py`）只依赖抽象**：通过 `Depends(get_auth_provider)` 拿 provider，
  源码里不出现任何具体 provider 名字 —— `test_authz.py::test_auth_routes_do_not_import_concrete_providers`
  用源码扫描守住这条；`test_upper_layer_only_depends_on_abstraction` 用 `app.dependency_overrides`
  整体替换成假 provider，证明五个接口全部经抽象转发。
- 服务端是**无状态**的，所以身份由参数显式传入（`logout(session)` / `current_session(token)` /
  `delete_account(token, password)`），与 §7.1 的六能力集同构。
- `AUTH_PROVIDER=server|huaweiId`：**启动即失败**（配置校验），绝不静默降级成 `local`；
  运行时若被选中，方法抛 `ProviderNotImplementedError`。
- 本切片的 `local` 实现 = 用户名口令 + bcrypt + JWT + `server_user` 落库（不是端侧 `LocalAuthProvider` 的
  "恒返回 local-guest 空令牌"，那是 App 侧 §7.1 的默认实现）。

### 注销 / 30 天保留 / 恢复 / 物理清除（ADR-0001 决策 ③）

`DELETE /api/v1/auth/account`（校验口令后）：

1. 把该账号名下 **9 张参与同步的归属表**（`carbon_record`、`point_record`、`user_goal`、`user_badge`、
   `user_purchase`、`user_appearance`、`science_progress`、`carbon_include`、`user_profile`）的
   `is_deleted = 0` 行置 `is_deleted = 1`，并**统一盖同一个毫秒时间戳** `deletionTs`；
2. `server_user.is_active = 0`，返回 `purgeAfter = deletionTs + 30 天`；
3. 审计：`admin_op_log(action='account_delete', target_type='server_user', target_id=<user_id>, detail={deletedRows, deletionTs, graceDays})`。
4. 旧令牌立刻失效（`is_active = 0` → `current_session` 抛 `TOKEN_INVALID`）。
5. **保留期内**同一用户名 + 同一口令登录 = **恢复**：把 `updated_at == deletionTs` 的那批行还原为
   `is_deleted = 0`、`is_active = 1`，并记 `action='account_restore'`（只还原注销时打标的那批行，
   不会复活用户此前自行删除的记录）。
6. **超期**：登录时惰性清除，或运维批量清除 ——

```bash
cd server && .venv/bin/python -m app.services.auth_provider      # purge_expired_accounts()
```

> **STOP 报告（文档缺口 + 忠实实现，`AGENTS.md` §1.3）**
> `STOP: server_user 没有"注销时间"列，无法只凭 §3 冻结 DDL 判定 30 天保留期是否到期`
> `冲突: docs/APPENDIX-B-data-and-api.md §3（server_user 只有 id/user_id/username/password_hash/created_at/last_login_at/is_active） ↔ docs/adr/0001-account-and-sync.md Decisions ③（"30 天后由定时任务物理清除"）`
> `建议: 不改 §3 的冻结 DDL（改了会与"建表 SQL 与附录 B 一致"的验收冲突），改用现成的审计表 admin_op_log 记录 account_delete/account_restore（注销时间 = 最新一条 account_delete 的 created_at）。若后续允许改 DDL，建议给 server_user 加 deleted_at BIGINT NULL 并把判定改回单表可判定。`

---

## 6. 配置（全部经环境变量注入）

配置类：`app/core/config.py`（pydantic-settings）。`env_file` 用**绝对路径** `server/.env`，与启动时的 CWD 无关。
完整清单与注释见 `.env.example`（每一项都对应一个真实字段，`test` 与 README 都以此为准）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `APP_ENV` | `dev` | `dev`/`test`/`prod`；`prod` 默认关 `/docs` |
| `APP_VERSION` | `1.0.0` | `/api/v1/health` 的 `version`（≠ 资料版本号 `CF-2026.2`） |
| `APP_HOST` / `APP_PORT` / `API_PREFIX` | `127.0.0.1` / `8000` / `/api/v1` | 只监听本机，对外由 Nginx/TLS 终结 |
| `DOCS_URL` / `DOCS_ENABLED` | `/docs` / 空 | `DOCS_ENABLED` 留空 = 非生产开、生产关；`true/false` 显式覆盖（路演前临时开） |
| `MYSQL_HOST` / `MYSQL_PORT` / `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_DB` | `127.0.0.1` / `3306` / … | MySQL 只监听 `127.0.0.1` |
| `DB_POOL_SIZE` / `DB_MAX_OVERFLOW` / `DB_POOL_RECYCLE` / `DB_POOL_TIMEOUT` | `5` / `5` / `1800` / `30` | 见下 |
| `JWT_SECRET` / `JWT_ALGORITHM` / `JWT_ISSUER` / `JWT_USER_AUDIENCE` / `JWT_ACCESS_TOKEN_EXPIRES_MINUTES` | 无默认 / `HS256` / `carbonboo-server` / `carbonboo-client` / 10080 | 客户端令牌（密钥 ①） |
| `ADMIN_JWT_SECRET` / `JWT_ADMIN_AUDIENCE` / `ADMIN_JWT_EXPIRES_MINUTES` | 无默认 / `carbonboo-admin` / 120 | 管理端令牌（密钥 ②） |
| `AUTH_PROVIDER` | `local` | `local`/`server`/`huaweiId`（后两者预留，选用即启动失败） |
| `ACCOUNT_PURGE_GRACE_DAYS` | `30` | 注销保留期（ADR-0001 决策 ③） |
| `LOGIN_RATE_LIMIT_PER_MINUTE` | `10` | 登录限流（0 = 关闭）；开发/测试可用 0 |
| `USERNAME_MIN_LENGTH` / `USERNAME_MAX_LENGTH` / `PASSWORD_MIN_LENGTH` / `PASSWORD_MAX_LENGTH` | `4` / `20` / `6` / `32` | 逐字取 §5.2 错误码表 |

**Web 后台管理端（可选件）的自有配置**：`server/admin_web/config.py` 的 `AdminWebSettings`，
环境变量前缀 `ADMIN_`、读**同一个** `server/.env`（600）。其中
`ADMIN_BOOTSTRAP_USERNAME` / `ADMIN_BOOTSTRAP_PASSWORD`（仅当 `admin_user` 表为空时用于创建首个管理员，
表非空后该路径彻底失效）、`ADMIN_UPLOAD_DIR`（图标上传目录，留空 = `admin_web/static/uploads/icons/`）
已列进 `.env.example`；其余 `ADMIN_MAX_ICON_BYTES` / `ADMIN_ICON_URL_PREFIX` / `ADMIN_PAGE_SIZE_*` /
`ADMIN_COOKIE_*` / `ADMIN_PREFIX` 有代码内默认值，不必写。**管理端 JWT 密钥与 audience 仍只来自
`Settings`**（`ADMIN_JWT_SECRET` / `JWT_ADMIN_AUDIENCE`，见上表），两处不复述、避免「两处都能配密钥」。

依赖清单：`requirements.txt`（本机实测锁定版本）。其中 **`jinja2==3.1.6`** 是可选件 `/admin` 的
服务端渲染（`fastapi.templating.Jinja2Templates`，PLAN §13.3）所需；**刻意不含 `python-multipart`**
（管理端用标准库解析 urlencoded 表单体 + 原始字节上传图标）。
核对脚本：`.env.example` 的每个键都能在 `Settings` 或 `AdminWebSettings` 里找到同名环境变量字段，
且 `requirements.txt` 的每个 pin 与本机 `.venv` 实际版本逐条相等（两者都脚本核对过，见提交信息）。

安全规则：

- **代码内没有任何默认密钥**；`JWT_SECRET` / `ADMIN_JWT_SECRET` 缺失、短于 32 字符、或**两者相同** → 启动即 `ValueError`。
- `.env` **不进仓库**（`server/.gitignore`），权限 600。
- 连接池显式收口：`pool_size=5, max_overflow=5, pool_recycle=1800, pool_timeout=30`（`create_engine(..., pool_pre_ping=True)`）。
  理由（AGENTS §7.2）：`--workers 2` 时 2×(5+5)=20 < `max_connections=30`；若用默认的 5+10 则 2×15=30 正好打满。
- 端口/密钥/库名一律环境变量注入，**服务端地址禁止硬编码**由 App 侧配置（AGENTS §6）。

> 本机（WSL + Windows 盘）`chmod 600 .env` 无法生效（drvfs 不支持 POSIX 权限位）。等价做法：
> `icacls "C:\Users\Administrator\Desktop\CarbonBoo\server\.env" /inheritance:r /grant:r "%USERNAME%:(R)"`
> 实测 ACL 只剩 `Administrator:(R)`（仅属主可读）。**部署到 Linux 上仍必须 `chmod 600 .env`。**

---

## 7. 同步 / 取价 / 备份 口径（t5）

### 7.1 参与同步的 9 张表与合并策略（附录 B §6.5）

`app/models.SYNC_TABLE_NAMES` 是唯一来源，与客户端 `ClientSchema.SYNCED_TABLES` 逐字一致；
`app/services/sync_service.SYNC_MODES` 逐表登记策略（**没登记的表名 → push 整批 400**，不静默丢数据）：

| 组 | 表 | 策略 |
|---|---|---|
| 只增账本 | `point_record`、`carbon_include` | `append_only`：同 `id` 已存在即跳过，**永不 UPDATE**（铁律 4） |
| 可改可删 | `carbon_record`、`user_goal`、`user_badge`、`user_purchase`、`user_appearance`、`science_progress` | `lww`：完整 LWW，平局比 `deviceId` 字典序 |
| 单例行 | `user_profile` | `lww` + `uq_uprofile(user_id)` 兜底 |
| **不参与** | `point_daily_stat`（派生缓存）、`sync_log`/`device_info`/`share_record`/`app_config`（本机专属） | — |

`sync_state` 是**仅客户端**的列（附录 B §1.3）：服务端不建它，客户端推上来的 `sync_state`
按"未知列"忽略；「待同步数」由客户端自己按 9 张表统计（验收 D6-6），`/sync/status` 不报它。

### 7.2 双重幂等与冲突计数（§6.4-3 / §6.3）

* 写入统一 `INSERT IGNORE`（`mysql_insert(table).prefix_with("IGNORE")`），写之前先按
  **(user_id + 业务唯一键)** 判重：`point_record`→`(source_type, source_id, flow_kind)`、
  `user_goal`→`(goal_id, period_key)`、`user_badge`→`badge_id`、`user_purchase`→`item_id`、
  `science_progress`→`article_id`、`user_appearance`/`user_profile`→单例（每 user 一行）。
* 被丢弃的行 → `ignored`（§5.3 里叫 `skipped`）并在 `errors[]` 写明原因，面板显示「跨设备重复已去重」。
  **业务键在服务端必须按 (user_id, 键) 判定**：服务端是多账号共库（理由见 §3 与 §9）。
* 真冲突 = `l.updated_at > lastSyncAt AND r.updated_at > lastSyncAt`（两端自上次同步后都改过这一行）；
  平局分支用**同一条件**计数。
* `merged` 回带"服务端版本更胜"的行（`lww` 表 + 有唯一键的重复购买），客户端回写后两端收敛。
  `user_purchase` 的重复购买**不会**产生任何 `reverse`/`adjust` 流水 —— 记账等价于"没有多扣一次分"。

### 7.3 软删除与时钟（§1.3-4 / §6.4-2 / §6.4-6）

* 软删除 = `is_deleted = 1` + 更新 `updated_at`；服务端把它当普通行参与 LWW 与增量下发，
  **不物理删除**任何账本行（否则删除无法传播）。
* `offsetMs = 服务端时钟 − 客户端时钟`（请求体可选 `clientNow`）；比较前 `r.updated_at + offsetMs` 换算到
  服务端基准；**容差 ±5 分钟**，超容差写 `sync_log.error_msg` 与响应的 `clockWarning`，但**继续合并**。
  客户端未提供 `clientNow` 时按"无偏移"处理（不猜），并在响应里报 `offsetMs = 0`。

### 7.4 云端备份 / 恢复（§5.3 标题行 + PLAN §7.8）

`backup_service`：**只存快照**（同 id 覆盖、不做 LWW、不算冲突、不用 `lastSyncAt`）、
**不做自动合并**（业务键撞车计 `ignored` 并写明原因）、**恢复即覆盖**（payload 里出现的表整体对齐快照；
LWW 表移除快照外的行，**只增账本只补不删**）、**恢复前生成快照**（覆盖前把云端原状读出来，
随响应 `preRestore` 返回，由调用方落盘 —— 21 张表是冻结契约，服务端不偷偷新建历史快照表）。

> 客户端的"云端备份/恢复"走的是 `POST /sync/push`（`since=0` 全量）+ `GET /sync/pull?since=0`
> （附录 B §5.3 没有独立备份端点行，t4 的 `SyncService.fullUpload/fullRestore` 就是这么实现的）；
> 本组的 3 个端点写同一批表、语义更明确（不合并），两者不会分叉。

### 7.5 增量迁移（`sql/migrations/`）

`sql/schema.sql` 是**基线**（可重复执行），`sql/migrations/NNN_*.sql` 是**在已有库上的增量**；
`tests/conftest.py` 在基线 + 种子之后**按序执行全部迁移**，所以"基线 + 迁移"这条真实部署路径每次跑 L3 都被验证
（包括**重复执行的幂等性**：`test_sync.py::test_migrations_are_executable_and_idempotent`）。
执行器：`bash deploy/migrate.sh <库名>`（幂等；`--dry-run` 只列不跑；**库名含 `test` 直接拒绝**）。

### 7.6 取价（§5.4）

`shop_service.catalog()`：返回**全部商品（含已下架，`onShelf=0`）**与目录版本
（`app_config['shop_items_version']` 的 `value`，缺失时给缺省版本而不是编造日期），
顺序 `section, order, id`（与客户端内置 `rawfile/shop/shop-items.json` 同序）。
下架商品不写在这里过滤：客户端 `ShopRules.check` 正是靠 `onShelf` 显示「该商品已下架」。
库异常 → 500 + 统一错误信封（不是"半个目录"），客户端据此**整份丢弃**并回落内置默认价（超时 3s）。

---

## 8. 测试（L3，真实 MySQL）

```
tests/conftest.py    # 真实数据库夹具：建 carbonboo_test、执行 sql/schema.sql + seed.sql + sql/migrations/*、逐表清理；TestClient
tests/test_auth.py   # 40 例：接口契约 + 表结构契约 + 口令哈希 + 注销/恢复/物理清除 + 令牌过期
tests/test_authz.py  # 29 例：/admin 403、两套密钥不通用、AuthProvider 抽象、/docs 开关、限流
tests/test_sync.py   # 48 例：pull/push/status 形状、LWW（新者胜/旧者回写/平局）、双重幂等、真冲突定义、
                     #   软删除传播、时钟容差与换算、越权 403、备份/恢复（含 preRestore 与账本只补不删）、
                     #   首次登录全量并入账号、注销保留期内旧令牌失效+恢复、迁移幂等、后台挂载点
tests/test_shop.py   # 10 例：取价形状/顺序/下架标志/按库报价/版本回落/失败信封（客户端整份丢弃）
```

覆盖到的"硬要求"：

- 表结构契约：`information_schema` 查得 **21 张表**；18 张同名表的列集合 = 附录 B §2 客户端列集 **减去 `sync_state`**；
  `server_user` **无 `device_id`**；类型映射抽查（`TEXT/BIGINT/DOUBLE/TINYINT`）；`uq_pr_source` 等唯一键存在；
  `sql/schema.sql` 可**重复执行**；`sql/migrations/*.sql` 幂等（重复执行两遍不报错）。
- 同步（t5）：表名白名单（9 张，其它表名整批 400）、`uq_pr_source` 含 `user_id`（多账号同键各自入账）、
  `INSERT IGNORE` + 业务键去重计入 `ignored`、账本行不被改写、真冲突需两端自上次同步后都改过、
  平局按 deviceId 字典序、软删除随增量传播、时钟换算与 ±5 分钟容差留痕、跨账号行整批 403 且一行不写、
  备份不做 LWW / 恢复即覆盖 / `preRestore` 是覆盖前原状 / 账本只补不删。
- 取价（t5）：无需令牌、含下架商品、按库报价、版本缺失回落、失败返回错误信封（客户端整份丢弃）。
- `server_user.password_hash` 是 bcrypt（`$2b$…`）且 `verify_password` 能验；DB 里查不到明文口令。
- 注册请求体里客户端多传的 `deviceId` / `usingCount` / `mode` / `mergePolicy` 被忽略（服务端无处可存）。
- 注销：9 张表行**仍在**（软删除）且 `is_deleted=1`、`is_active=0`、`purgeAfter` = 注销时刻 + 30 天；
  期内同一口令登录 = 恢复（行还原、可继续用新令牌访问 `/me`）；超期 → 物理清除 + 401。
- 鉴权：客户端令牌访问 13 条 `/admin/*` 路径（GET/POST/PATCH/PUT/DELETE）**全部 403**；无令牌/乱签名 → 404（落到路由）；
  管理端令牌 → 通过中间件；两套密钥+audience 双向不通用；篡改/过期令牌 → 401。
- 抽象：`app/api/**` 源码不得出现具体 provider 名；替换 provider 后五接口仍工作；`AUTH_PROVIDER=wechat` 配置即拒。
- 其他：`/docs` 与 `/openapi.json` 可关闭；登录限流 429；错误响应不回显密钥/哈希。

**未运行 / 无法运行**：无（本切片所有用例都在真实 MySQL 8 上跑过）。容器/真机同层验证（L2）属 App 侧切片。

---

## 9. 其他偏离与待办（写给队长/下游切片的报告）

| 项 | 说明 |
|---|---|
| `server/.gitignore` | **超出本切片 inScope 列表**：仓库根 `.gitignore` 没有 `.env` 规则，而 AGENTS §7.3 禁止提交 `.env`。为不污染根文件（根 `.gitignore` 也不在 inScope），在 `server/.gitignore` 里忽略 `.env` / `.venv/` / `__pycache__/` / `*.pyc` / `.pytest_cache/`。 |
| `server/.env` | 本机开发用，已按上面 ACL 收紧，**未跟踪**（`git status` 不显示）。 |
| health 的 `version` | 附录 B §5.1 示例是 `"1.0.0"`（API 版本号），与资料版本号 `CF-2026.2` 是两件事；`VERSION=CF-2026.2` 只用于工程元数据（`pyproject.toml`）。 |
| `INVALID_REQUEST` | 文档未列的补充码，用于请求体结构/类型错误（§5.2 表格只有业务语义错误）。 |
| `/admin/*` 非 403 的状态码 | 未挂载管理端路由时是 404；403 只由"客户端令牌"触发。t6 挂载后其余状态码由 t6 定。 |
| `server/deploy/`（t5 已建） | systemd（`--workers 2` + 每天超期账号清除 timer）、nginx（TLS + 反代 + `/admin` 登录限流）、`mysqldump` 定时备份、`migrate.sh`。用法见 `deploy/README.md`。 |
| t6 `admin_web/` 挂载点 | `app/main.py` 已固定 `try: from admin_web.mount import mount_admin … except Exception: 静默跳过`；`test_sync.py` 用假模块证明"有则挂载、无则静默跳过"，并断言本切片**没有**创建 `server/app/admin/`、`server/templates/`、`server/static/`。 |
| 未预期异常的信封 | t5 给 `main.py` 补了 `@app.exception_handler(Exception)` → 500 `{ok:false, code:"SERVER_ERROR"}`：客户端取价规则是"非 200 或数据非法 → 整份丢弃"，纯文本 500 会让它分不清错误类型；不回显异常文本。 |
| `sync_state` 未知列 | 客户端 `SELECT *` 会把 `sync_state` 一起推上来；服务端按"未知列"忽略（服务端根本没有该列，附录 B §1.3）。响应里回带给客户端的行也不含它 → 客户端本地 `DEFAULT 'local'` 生效。 |
| 浮点列 `DOUBLE(asdecimal=False)` | 服务端 ORM 必须显式关掉 `asdecimal`（`mysql.DOUBLE` 默认开）：否则拉回来的 `amount` 会被 JSON 序列化成字符串 `"2.0000000000"`，客户端 `numOf()` 直接读不到数。守门用例 `test_sync.py::test_pull_returns_json_numbers_not_decimal_strings`。 |

### 9.1 附录 B 需要同步修正的行号清单（t5 实现按正确口径，文档待改）

| # | 位置（当前行号） | 现文问题 | 应改成 |
|---|---|---|---|
| 1 | `APPENDIX-B:142`（`uq_pr_source`）+ `:134-141` 的幂等约束说明 | 唯一键 `(source_type, source_id, flow_kind)` **不含 `user_id`**；而 `source_id` 取值口径（`:135-138`：`goal → '<goalId>:<periodKey>'`、`shop_item → '<shop_item.id>'`）不含账号维度 → **两个账号同一天达成同名目标会互相顶掉**（后入账者丢积分）。同一处缺陷在客户端 `ClientSchema` 的 `uq_pr_source` 也在（本机库同时有 `local-guest`/`demo-user`/账号 `userId`），t2/t4 需同步修 | `uq_pr_source(user_id, source_type, source_id, flow_kind)`（服务端 `sql/schema.sql` 已改，老库走 `sql/migrations/001_*`） |
| 2 | `:894-925`（§6.3 appendOnly 伪码主体）+ `:906` | 伪码里 `appendOnly` 只按 `id` 去重，业务唯一键兜底只写在 `:927-935` 的散文注释里 —— 伪码自身不自洽（容易被照抄成"只按 id 去重"的实现） | 在 `appendOnly` 分支补一句"业务唯一键已存在 → `ignored++`"，或把 `:927-935` 的写回块提为伪码的一部分 |
| 3 | `:794-798`（§5.3 端点表） | 表里只有 `pull`/`push`/`status` 三行，**云端备份/恢复的端点缺行**；`:792` 只说"全量快照上传/下载覆盖" | 补三行：`POST /api/v1/sync/backup`（上传快照）、`GET /api/v1/sync/backup`（下载快照）、`POST /api/v1/sync/backup/restore`（覆盖式恢复，返回 `preRestore`）；或明确写"备份复用 `push`/`pull` 的 `since=0`"（t4 客户端就是这么实现） |
| 4 | `:801-805`（push 请求体示例） | 没有客户端时钟字段，而 `:945`（§6.4-6）要求"握手时测得 `offsetMs = 本机时钟 − 对端时钟`" —— 服务端无从测得 | 请求体补可选 `clientNow`（毫秒）；服务端据此算 `offsetMs`，缺失时按"无偏移"处理 |
| 5 | `:939-942`（§6.4-3） | "被忽略的行计入 `ignored` 与冲突数"——`ignored` 与 `conflicts` 混在一条里，容易被实现成"去重也计冲突"（与 `:912` 的"真冲突"定义冲突） | 明确：`ignored`（跨设备重复已去重）**不**计入 `conflicts`；`conflicts` 只按 `:912` 的条件计数 |
| 6 | `:953`（§6.5 `user_purchase` 行） | 已由 t1 修好（"不是退回多扣的分"），但**没有说明服务端不产生任何 `reverse`/`adjust` 流水** | 补一句"忽略远端购买行不会产生任何流水"（t5 已按此实现并有守门用例） |
| 7 | `:954`+`:371`（`user_profile` 单例行） | 已由 t1 修好（`uq_uprofile(user_id)` + 新 UUID）；服务端实现口径是"同 `user_id` 只保留一行，跨设备按 LWW 取新"，`id` 不变 | 可在 §6.5 注明"合并时按 `user_id` 收敛到一行，`id` 取胜者的" |
| 8 | `:748`（§5.2 端点表）附近 | 未写明**所有同步/备份端点都要客户端令牌**（`:729` 只说"用于账号与同步"） | 在 §5.3 表头写明"本组三个端点均需 `Authorization: Bearer <userToken>`，账号已注销者 401" |

> 另外 **1 处跨切片缺陷（不在 t5 写入范围，需 app 侧修）**：客户端从未发送 `Authorization` 头 ——
> `app/entry/src/main/ets/viewmodel/net/HttpPort.ets` 的 `HttpClient.request()` 只设 `Content-Type`，
> `HttpPort.request()` 接口本身也没有传令牌的位置；`AuthService.ets:69/82` 把 token 塞在请求体里，
> `net/SyncService.ets:135/142/166/186` 完全没有令牌。因此真机上 `/auth/me`、`/auth/logout`、
> `DELETE /auth/account`、`/sync/*` 全部会 401。建议：`HttpClient` 接受一个 token 源（如
> `AppState`/`AuthDao` 的读取函数）并在 `request()` 里补 `Authorization: Bearer <token>`，
> 同时把 `logout`/`deleteAccount` 请求体里的 `token` 去掉（§5.2 的体只带 `password`）。
> t5 已按文档口径**严格要求令牌**（不为迁就客户端而放宽鉴权），并在 `test_sync.py` 里把 401 钉住。
