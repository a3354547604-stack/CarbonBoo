"""后台管理端服务层。

分层口径（沿用 AGENTS §7.1「页面层禁止业务计算与数据库读写」「事务边界在 Service 层」）
--------------------------------------------------------------------------------------
* `admin_web/api.py` / `admin_web/pages.py` 只做 HTTP 面：解析请求、调服务、选响应形态（JSON / HTML）。
* 本包内每个模块各自拥有**一张或一组表**的读写，并负责自己的事务边界
  （`admin_web.services.base.transaction`）；跨模块调用只走函数，不共享 Session 内部状态。
* 所有写操作都必须留下 `admin_op_log`（审计唯一写入点是 `admin_web.services.audit.write_op_log`）。

| 模块 | 负责的表 | 对应功能（PLAN §13.2） |
|---|---|---|
| `accounts` | `admin_user` | ① 管理员登录 + 改密码 |
| `catalog` | `shop_item` + `app_config['shop_items_version']` | ② 商品管理 |
| `stats` | 9 张同步表 + `server_user` + `user_purchase` + `carbon_record` | ③ 用户列表 ④ 数据总览 ⑤ 订单记录 |
| `system_config` | `app_config` + `goal_def` | ⑥ 系统配置 |
| `audit` | `admin_op_log` | ⑦ 操作日志 |
| `icons` | 文件系统（`static/uploads/icons/`，不落库） | ② 传图标 |

**为什么这里不做 `from admin_web.services import xxx` 的预导入**：子模块彼此引用
（`catalog` → `audit`，`stats` → `base`），包级预导入会把循环依赖引到导入期。
`from admin_web.services import audit` 由导入系统按需加载子模块，语义完全一样。
"""
