"""CarbonBoo Web 后台管理端（可选件，ADR-0001）—— 落在 `server/admin_web/`。

是什么
------
浏览器访问 `/admin` 的管理界面，用于**商品定价**与**用户 / 订单 / 数据总览**（PLAN §13.2 七项功能）。
它是服务端上的一个**可选件**：即使整个后台不可用，客户端全部功能照常（含碳小铺内置默认价）。

边界（重要）
------------
* 后台**不承担**账号、同步与备份 —— 那些是 `/api/v1/*` 的职责（附录 B §5.2/§5.3）。
* 管理员账号**独立于任何用户体系**（`admin_user` 与 `server_user` 无任何关联）。
* 鉴权用**管理侧独立 JWT**（密钥 ② + audience ②）；客户端令牌访问任何 `/admin/*` 一律 403
  （`app/main.py` 的隔离中间件为第一道，本包的 `require_admin` 为第二道）。
* 客户端**只读**后台下发的配置，无权改价（改价能力只在服务端与后台）。

接口
----
唯一的对外函数：`admin_web.mount.mount_admin(app)`。
内部结构见 `services/__init__.py` 的分工表；页面为 Jinja2 服务端渲染（`templates/`）+ 一个原生 JS
（`static/admin.js`），无前端框架、无构建链。
"""

from __future__ import annotations

__all__ = ["__version__"]

#: 后台自有版本号（与资料版本号 `app.core.config.VERSION` 分开：后台是可选件，独立演进）
__version__ = "1.0.0"
