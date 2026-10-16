# CarbonBoo Web 后台管理端（`server/admin_web/`）

> **定位**：`docs/PLAN.md` §13 的**可选件**（`GLOSSARY.md` 名词表：服务端提供账号/同步/取价/备份，后台管理端是服务端上的 `/admin` 网页，属可选件）。
> 没有它，客户端全部功能照常（含碳小铺内置默认价 —— 附录 D §1.10 D10-8 / 附录 E E11）。

## 1. 一行集成说明

`server/app/main.py:161-175` 预留的挂载点调用本包唯一对外接口：

```python
from admin_web.mount import mount_admin
mount_admin(app)          # 必须传入 app；内部 = include_router(APIRouter(prefix="/admin")) + 注册 LoginRequired → 303
```

`mount_admin(app)` 幂等（`app.state.carbonboo_admin_mounted` 标记），**只增不改**：不覆盖服务端切片注册的
`AppError` 处理器（`/api/v1/*` 的错误信封不受影响），不占用 `/api/v1/*` 任何路径。
因此本目录可以直接删除而不影响服务端与客户端 —— 这就是"可选件"的含义。

## 2. 启动与首次登录（**没有默认口令**）

```bash
cd server
# ① 依赖（pypi.org 不可达时用阿里云镜像）
.venv/bin/python -m pip install -r requirements.txt -i https://mirrors.aliyun.com/pypi/simple/
# ② 起服务
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 2
# ③ 浏览器打开
#    http://127.0.0.1:8000/admin
```

首次创建管理员有两条正规路径（**共用同一个服务函数 `services/accounts.create_admin`，同一套强口令策略**）：

| 路径 | 做法 | 适用 |
|---|---|---|
| 环境变量引导（惰性） | 在 `server/.env`(600) 写 `ADMIN_BOOTSTRAP_USERNAME` / `ADMIN_BOOTSTRAP_PASSWORD`，然后直接登录 —— `admin_user` 表为空时自动创建首个管理员，**表非空后该路径彻底失效** | 首次初始化 / 演示 |
| 命令行 | `.venv/bin/python -m admin_web.cli create-admin --username <名字>`（口令交互输入）；忘记口令时加 `--reset` | 日常运维与找回 |

**口令策略（强口令，AGENTS §6）**：≥12 位、至少 3 类字符（小写/大写/数字/符号）、不在常见弱口令表、
不得与用户名相同。**代码内没有任何默认口令**；密钥（`JWT_SECRET` / `ADMIN_JWT_SECRET`）一律只来自
`server/.env`(600)，由 `app/core/config.py` 校验（两把必须不同且 ≥32 字符）。

## 3. 本包自有的可变量（环境变量前缀 `ADMIN_`）

| 变量 | 默认 | 说明 |
|---|---|---|
| `ADMIN_BOOTSTRAP_USERNAME` / `ADMIN_BOOTSTRAP_PASSWORD` | 空 | 首次引导（见上）；建议初始化后清空 |
| `ADMIN_UPLOAD_DIR` | `server/admin_web/static/uploads/icons/` | 上传图标落盘目录（该目录下 `.gitignore` 保证上传物不进仓库） |
| `ADMIN_MAX_ICON_BYTES` | `524288` | 单张图标上限（512 KB） |
| `ADMIN_PAGE_SIZE_DEFAULT` / `ADMIN_PAGE_SIZE_MAX` | `20` / `200` | 列表分页 |
| `ADMIN_COOKIE_NAME` | `carbonboo_admin_token` | 浏览器会话 Cookie 名（HttpOnly + SameSite=Lax，生产自动加 Secure） |
| `ADMIN_ICON_URL_PREFIX` / `ADMIN_PREFIX` | `/admin/icons` / `/admin` | 图标访问前缀 / 后台前缀 |

JWT 密钥、audience、有效期、是否生产**仍只读 `app/core/config.py`**，本包不复述、不覆盖（钥匙只有一把）。

## 4. 路由总表

附录 B §5.4 的 15 条路径**一条不多、一条不少**（`GET` 类路由是"二态"：`Accept: text/html` → 服务端渲染页面；
否则 → JSON 信封 `{ok, data}`）：

| 方法 | 路径 | 鉴权 | 功能（PLAN §13.2） |
|---|---|---|---|
| GET | `/admin/login` | 无 | ① 登录页 |
| POST | `/admin/login` | 无 | ① 登录 → `adminToken`（表单提交则 303 + 会话 Cookie） |
| POST | `/admin/password` | adminToken | ① 改密码（**增补**路由：条款要求"改密码"，页面需要提交口） |
| GET/POST | `/admin/items` | adminToken | ② 商品列表 / 新增 |
| PATCH | `/admin/items/{id}` | adminToken | ② 改价 / 改描述 / 排序 / 上下架 |
| POST | `/admin/items/{id}/icon` | adminToken | ② 传图标（`image/*` 原始字节 **或** `{filename, dataBase64}` JSON） |
| GET | `/admin/users` | adminToken | ③ 用户 / 设备列表（分页） |
| GET | `/admin/overview` | adminToken | ④ 数据总览 |
| GET | `/admin/orders` | adminToken | ⑤ 订单记录（分页） |
| GET/PUT | `/admin/config` | adminToken | ⑥ 系统配置 |
| GET | `/admin/logs` | adminToken | ⑦ 操作日志（分页 + `action` 过滤） |
| POST | `/admin/logout` | adminToken | **增补**：清会话 Cookie（管理端要有退出路径） |
| GET | `/admin/icons/{filename}` | adminToken | **增补**：取回上传的图标 |
| GET | `/admin/static/{filename}` | 无 | **增补**：仅 `admin.css` / `admin.js` 两个白名单文件（登录页也要样式，不含任何数据） |
| GET | `/admin`、`/admin/`、`/admin/password` | 会话 | 后台主页（数据总览）/ 改密码页（HTML） |

**鉴权与隔离**（AGENTS §7.2，两道防线）：

1. `app/main.py` 的隔离中间件：**客户端令牌**进 `/admin/*` → `403 FORBIDDEN`（在进路由之前）；
2. 本包 `security.require_admin`：只认管理侧密钥 ② + audience ② 签的令牌；JSON → 401 `TOKEN_INVALID`，
   HTML → `LoginRequired` → 303 跳登录页。

客户端令牌与管理端令牌**互不通用**（密钥不同 + audience 不同，两个维度都校验）。

## 5. 数据与口径

| 视图 | 数据来源 | 口径 |
|---|---|---|
| 商品列表 | `shop_item`（**复用 `app.services.shop_service`**，与客户端取价同一实现） | 含已下架商品（`onShelf=0`） |
| 改价生效 | 写 `shop_item` + bump `app_config['shop_items_version']` | 客户端**下次启动**经 `GET /api/v1/shop/items` 整份覆盖（附录 B §5.4、D10-3） |
| 用户 / 设备 | 9 张同步表（表名取 `app.models.SYNC_TABLE_NAMES`） | 设备 = 按 `device_id` 去重 + 各自最后一次同步时间（附录 B §3 注） |
| 数据总览 | `carbon_record` / `point_record` / `user_purchase` / `shop_item` / `server_user` | 今日新增 = `created_at` 落服务端本地今天的未删除记录；总积分发放 = 正流水合计（铁律 4 的收入侧） |
| 订单 | `user_purchase` + `server_user` + `shop_item` | `price_paid` 是下单时成交价，不随后台改价变化 |
| 系统配置 | `app_config['points_daily_cap']` / `app_config['badges_enabled']` / `goal_def.reward` | 见下"新增键名" |
| 操作日志 | `admin_op_log` | 一条动作一行：`change_price` / `toggle_shelf` / `update_item` / `create_item` / `upload_icon` / `update_config` / `change_password` / `login` / `logout` / `bootstrap_admin`；`detail` 带改前 / 改后 |

聚合一律用 SQL `SUM/COUNT`（AGENTS §3：禁止浮点累加）。

**新增的两个 `app_config` 键名**（附录 B §1.2 的 `app_config` 本来就是 key-value 配置表；
但"徽章开关"在文档里只出现在 PLAN §13.2 ⑥ / D10-5 的功能描述里，**没有给键名**，故在此写死）：

- `points_daily_cap` —— 每日记录积分封顶值（种子已有，值 `200`，PLAN §9.2）；
- `badges_enabled` —— 徽章开关（`1` 启用 / `0` 关闭，缺省 `1`）。

## 6. 明确的边界（不做什么）

- **不承担**账号、多设备同步、云端备份 —— 那些是 `/api/v1/auth/*`、`/api/v1/sync/*`（附录 B §5.2/§5.3）。
- 管理员账号与 App 用户体系**零关联**（不存在任何外键或映射）。
- 客户端**只读**后台下发的配置，**无权改价**。
- 不做：同步日志查询、科普内容管理、因子库版本管理（PLAN §13.2 标注"可选（未纳入本期）"）。
- 不新增前端依赖：**无前端框架、无构建链**，只有一个 `static/admin.js`（原生 `fetch`）与 `static/admin.css`。
  仅有的 Python 依赖是 **Jinja2**（FastAPI 渲染所需，属模板引擎而非前端框架）。

## 7. 未决问题（登记，未自行拍板）

**STOP-1（文档口径缺口，不阻塞本任务验收）**

```
STOP: 附录 D10-5 的通过判据含「App 侧能读到」，但文档没有把这三项下发给客户端的接口
冲突: docs/APPENDIX-D-acceptance.md:209「改目标奖励分值 / 每日封顶值 / 徽章开关 → 保存成功；App 侧能读到」
      ↔ docs/APPENDIX-B-data-and-api.md §5.4 与 docs/PLAN.md §13.3 只定义了商品目录的下发
        （GET /api/v1/shop/items），没有任何 app_config / goal_def 的下发通道
建议: 在附录 B §5.4 增列一条客户端可读的配置接口（例如 GET /api/v1/config，
      返回 points_daily_cap / badges_enabled / goal_def.reward），由服务端切片实现；
      本任务只保证服务端侧写入正确、可回读、有审计（不擅自新增客户端接口 —— server/app/ 不在本任务写入范围）
```

**待 server-api 补的两处（均在本任务写入范围之外）**

1. `server/requirements.txt` 需补 **`jinja2`**（本目录用它做服务端渲染；FastAPI 的 `Jinja2Templates` 依赖它）。
   本机已按 `https://mirrors.aliyun.com/pypi/simple/` 装进 `server/.venv`（`jinja2==3.1.6`），但**没有**改
   `requirements.txt`（属服务端切片范围）。
2. `server/.env.example` 需补三行说明：`ADMIN_BOOTSTRAP_USERNAME` / `ADMIN_BOOTSTRAP_PASSWORD` / `ADMIN_UPLOAD_DIR`
   （键名与本目录 `config.py` 的 `ADMIN_` 前缀一一对应，已用脚本核对）。

**已知的取舍（不是缺陷）**

- 用户列表在**本机规模**（演示/单机部署）下"全量合并后分页"；若账号数上万需改成 SQL 分页（当前实现
  会把 9 张同步表的分组结果全部取回内存）。已在 `services/stats.users` 的文档字符串里写明。
- 上传的图标在 `shop_item.icon` 里存为 `/admin/icons/<文件名>`（而内置商品是 `res://frame_01`）。
  客户端遇到不认识的资源引用会回落默认图标 —— 这不违反契约（`icon` 列只是 `VARCHAR(255)`），
  但没有让 App 真正用上自定义图标（需要客户端侧支持，属 app/ 范围）。
