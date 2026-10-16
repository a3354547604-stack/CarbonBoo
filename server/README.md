# CarbonBoo 服务端（FastAPI + SQLAlchemy 2.x + MySQL 8）

> 切片：**t3 服务端地基**——账号体系与鉴权隔离（S6 的最低可用切片）。
> 口径来源（唯一真相，冲突时按 `AGENTS.md` §1.2 优先级裁决）：
> `docs/APPENDIX-B-data-and-api.md`（表与接口）、`docs/adr/0001-account-and-sync.md`（账号与同步决策）、
> `docs/PLAN.md` §4.2/§4.3/§5.2、`AGENTS.md` §6/§7.2。
> 服务端是**必做件**（账号 + 多设备同步 + 商品取价 + 云端备份）；唯一可选项是 Web 后台管理端。

本切片**已做**：21 张表 DDL、ORM 模型、配置/连接池/安全/错误/限流、5 个账号接口、`AuthProvider` 抽象、
双 JWT 密钥隔离、注销 30 天保留与恢复、L3 测试（69 例）。
本切片**未做**（后续切片，写入范围互斥）：`sync` / `shop` / `backup` 接口（t5）、Web 管理后台（t6）。

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
# 本机 WSL 没装 mysql 客户端时，可让容器代跑（下面用容器名 carbonboo-mysql）：
#   docker exec -i carbonboo-mysql mysql -uroot -p*** < sql/schema.sql
#   docker exec -i carbonboo-mysql mysql -uroot -p*** carbonboo < sql/seed.sql

# ④ 启动（与 AGENTS §7.2 一致：2 个 worker）
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 2
# 接口文档（dev/test 默认开）：http://127.0.0.1:8000/docs
# 探活：curl -s http://127.0.0.1:8000/api/v1/health
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
python -m pytest tests/ -q       # 69 passed；不激活时等价写法：.venv/bin/python -m pytest tests/ -q
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
│   ├── schemas/                # Pydantic v2 请求/响应模型（common.ErrEnvelope / OkEnvelope）
│   ├── api/v1/                 # PLAN §5.2 的 routers/* → api/v1/*（auth.py、__init__.py 里挂 health）
│   └── services/auth_provider.py  # AuthProvider 抽象 + local 实现 + server/huaweiId 预留（本切片唯一 service）
├── sql/schema.sql              # 21 张表 DDL（自附录 B §1.2/§1.3/§3 程序化生成，可重复执行）
├── sql/seed.sql                # 静态字典种子（目标 11 / 徽章 8 / 商品 9 / 头像 8 / 碳普惠 5 / 因子镜像 31）
├── tests/                      # conftest.py（真实 DB 夹具）+ test_auth.py + test_authz.py
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
- 索引/唯一键名与附录 B §2 同名，例如 `uq_pr_source(source_type, source_id, flow_kind)`、
  `uq_ug(user_id, goal_id, period_key)`、`uq_uprofile(user_id)`。

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

| 方法 | 路径 | 说明 | 状态码 |
|---|---|---|---|
| GET | `/api/v1/health` | 探活，**扁平结构**（附录 B §5.1） | 200 |
| POST | `/api/v1/auth/register` | 注册，返回 JWT | **201**（§5.2 `// res 201`） |
| POST | `/api/v1/auth/login` | 登录，返回 JWT | 200 |
| GET | `/api/v1/auth/me` | 当前用户 | 200 |
| POST | `/api/v1/auth/logout` | 登出（服务端无状态，记 `last_login_at`） | 200 |
| DELETE | `/api/v1/auth/account` | 注销（软删除保留 30 天，期内可恢复） | 200 |

响应体（逐字对齐 §5.1/§5.2）：

```jsonc
// GET /api/v1/health —— 注意：health 没有 data 包装
{ "ok": true, "version": "1.0.0", "time": 1762300000000 }
// POST /api/v1/auth/register  res 201
{ "ok": true, "data": { "userToken": "eyJ...", "userId": "u-...", "username": "harry_01" } }
// GET  /api/v1/auth/me
{ "ok": true, "data": { "userId": "u-...", "username": "harry_01" } }
// DELETE /api/v1/auth/account   req { "password": "abc12345" }
{ "ok": true, "data": { "purgeAfter": 1764892000000 } }
// 失败一律 { "ok": false, "code": "...", "message": "..." }
```

错误码（§5.2 表 + 两个补充码）：

| code | HTTP | 触发 |
|---|:--:|---|
| `USERNAME_TAKEN` | 409 | 用户名已存在 |
| `USERNAME_INVALID` / `PASSWORD_INVALID` | 400 | 用户名非 4–20 位字母数字下划线 / 口令非 6–32 位 |
| `CREDENTIAL_INVALID` | 401 | 用户名或口令错误 |
| `TOKEN_EXPIRED` / `TOKEN_INVALID` | 401 | 令牌过期 / 非法、账号已注销 |
| `FORBIDDEN` | 403 | 客户端令牌访问 `/admin/*` |
| `NOT_FOUND` | 404 | 路由或资源不存在 |
| `RATE_LIMITED` | 429 | 登录限流（`LOGIN_RATE_LIMIT_PER_MINUTE`，键 = IP + 用户名） |
| `SERVER_ERROR` | 500 | 服务端异常 |
| `INVALID_REQUEST` | 400 | **补充码**：请求体结构/类型不合法（§5.2 只规定业务语义错误） |

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

## 7. 测试（L3，真实 MySQL）

```
tests/conftest.py    # 真实数据库夹具：建 carbonboo_test、执行 sql/schema.sql、逐表清理；TestClient
tests/test_auth.py   # 40 例：接口契约 + 表结构契约 + 口令哈希 + 注销/恢复/物理清除 + 令牌过期
tests/test_authz.py  # 29 例：/admin 403、两套密钥不通用、AuthProvider 抽象、/docs 开关、限流
```

覆盖到的"硬要求"：

- 表结构契约：`information_schema` 查得 **21 张表**；18 张同名表的列集合 = 附录 B §2 客户端列集 **减去 `sync_state`**；
  `server_user` **无 `device_id`**；类型映射抽查（`TEXT/BIGINT/DOUBLE/TINYINT`）；`uq_pr_source` 等唯一键存在；
  `sql/schema.sql` 可**重复执行**。
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

## 8. 其他偏离与待办（写给队长/下游切片的报告）

| 项 | 说明 |
|---|---|
| `server/.gitignore` | **超出本切片 inScope 列表**：仓库根 `.gitignore` 没有 `.env` 规则，而 AGENTS §7.3 禁止提交 `.env`。为不污染根文件（根 `.gitignore` 也不在 inScope），在 `server/.gitignore` 里忽略 `.env` / `.venv/` / `__pycache__/` / `*.pyc` / `.pytest_cache/`。 |
| `server/.env` | 本机开发用，已按上面 ACL 收紧，**未跟踪**（`git status` 不显示）。 |
| health 的 `version` | 附录 B §5.1 示例是 `"1.0.0"`（API 版本号），与资料版本号 `CF-2026.2` 是两件事；`VERSION=CF-2026.2` 只用于工程元数据（`pyproject.toml`）。 |
| `INVALID_REQUEST` | 文档未列的补充码，用于请求体结构/类型错误（§5.2 表格只有业务语义错误）。 |
| `/admin/*` 非 403 的状态码 | 本切片不注册管理端路由，未挂载时是 404；403 只由"客户端令牌"触发。t6 挂载后其余状态码由 t6 定。 |
| `server/deploy/` | AGENTS §7.2 要求部署脚本（systemd/容器 + TLS + 防火墙 + `mysqldump` 定时备份），**不在本切片 inScope**，留给部署切片；本切片不创建该目录。 |
| t5 接缝 | `app/api/v1/__init__.py` 里 `router.include_router(...)` 追加点已留好；`app/models` 已含 21 张表 ORM 与 `compare_with_database()`，sync/shop/backup 直接复用，无需改本切片文件。 |
