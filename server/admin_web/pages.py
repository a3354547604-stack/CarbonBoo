"""服务端渲染页面（Jinja2）+ 页面上下文（PLAN §13.3：**无前端框架、无构建链**）。

设计口径
--------
* 每个 `render_*` 函数 = 「一个页面的数据装配 + 一次模板渲染」，不做业务计算、不写库
  （数据来自 `services/*`，与 JSON 接口**同一批函数**：页面与接口永远同源）。
* 页面只做展示所需的**格式化**（时间戳 → 本地时间、数字千分位、kg 四位小数），
  这些格式化只在本模块定义一次（模板里不再写 Python 逻辑）。
* 导航是高亮当前页的唯一来源：`NAV` 里的键同时用于侧栏高亮与页面标题。
* 页面自身的交互（改价、上传、筛选）由 `static/admin.js` 用 `fetch()` 调**同一条路径**的 JSON 接口
  （`Accept: application/json`），页面上没有第二套写入口。
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any

from fastapi import Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.core.config import VERSION, Settings, get_settings
from app.core.security import TokenPrincipal

from admin_web.config import TEMPLATES_DIR, AdminWebSettings, get_admin_settings
from admin_web.security import LoginRequired, login_url, resolve_admin
from admin_web.services import audit, catalog, stats

logger = logging.getLogger("carbonboo.admin.pages")

templates = Jinja2Templates(directory=str(TEMPLATES_DIR))

#: 侧栏导航（键 = 页面标识兼高亮标记；值 = 中文名）
NAV: tuple[tuple[str, str, str], ...] = (
    ("overview", "数据总览", "/admin"),
    ("items", "商品管理", "/admin/items"),
    ("users", "用户列表", "/admin/users"),
    ("orders", "订单记录", "/admin/orders"),
    ("config", "系统配置", "/admin/config"),
    ("logs", "操作日志", "/admin/logs"),
    ("password", "修改密码", "/admin/password"),
)


# --------------------------------------------------------------------------- #
# 展示格式化（只在本模块定义一次；模板里不写逻辑）
# --------------------------------------------------------------------------- #
def fmt_time(ms: int | None, *, default: str = "—") -> str:
    """毫秒时间戳 → 本地时间 `YYYY-MM-DD HH:mm:ss`。"""
    if not ms:
        return default
    try:
        return datetime.fromtimestamp(int(ms) / 1000).strftime("%Y-%m-%d %H:%M:%S")
    except (OverflowError, OSError, ValueError):  # pragma: no cover - 脏数据兜底
        return str(ms)


def fmt_int(value: Any) -> str:
    """整数千分位（大数字好读）。"""
    try:
        return f"{int(value):,}"
    except (TypeError, ValueError):
        return str(value)


def fmt_kg(value: Any) -> str:
    """减排量：4 位小数（与契约的 `round_half_up(…, 4)` 同精度，不额外截断）。"""
    try:
        return f"{float(value):.4f}"
    except (TypeError, ValueError):
        return str(value)


def fmt_points(value: Any) -> str:
    """积分数（整数）。"""
    try:
        return f"{int(value):,}"
    except (TypeError, ValueError):
        return str(value)


templates.env.filters["time"] = fmt_time
templates.env.filters["int"] = fmt_int
templates.env.filters["kg"] = fmt_kg
templates.env.filters["points"] = fmt_points
templates.env.globals["action_label"] = audit.action_label
templates.env.globals["CATEGORY_LABELS"] = stats.CATEGORY_LABELS


def _current_admin(request: Request, web: AdminWebSettings) -> TokenPrincipal:
    """页面用的当前管理员；未登录 → 303 跳登录页（与 JSON 接口的 401 是两条路，判定只在这里）。"""
    principal = resolve_admin(request, settings=get_settings(), admin_settings=web)
    if principal is None:
        raise LoginRequired(login_url(request, web))
    return principal


def _base_context(
    request: Request, web: AdminWebSettings, *, active: str, title: str, **extra: Any
) -> dict[str, Any]:
    """所有页面共享的上下文（导航 / 当前管理员 / 版本号）。"""
    principal = _current_admin(request, web)
    context: dict[str, Any] = {
        "request": request,
        "prefix": web.prefix,
        "nav": NAV,
        "active": active,
        "title": title,
        "admin": principal,
        "product": f"碳小布 CarbonBoo · Web 后台管理端（{VERSION}）",
    }
    context.update(extra)
    return context


def render_login(
    request: Request,
    *,
    settings: Settings,
    web: AdminWebSettings,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    """登录页（无侧栏）。已登录（有效会话 Cookie）→ 直接跳 `next`。"""
    from fastapi.responses import RedirectResponse

    from admin_web.security import safe_next

    next_target = safe_next(request.query_params.get("next"), web)
    principal = resolve_admin(request, settings=settings, admin_settings=web)
    if principal is not None:
        return RedirectResponse(next_target, status_code=303)

    return templates.TemplateResponse(
        request=request,
        name="login.html",
        context={
            "prefix": web.prefix,
            "error": error,
            "next": next_target,
            "product": f"碳小布 CarbonBoo · Web 后台管理端（{VERSION}）",
        },
        status_code=status_code,
    )


def render_overview(
    request: Request, *, web: AdminWebSettings, db: Session, data: dict[str, Any]
) -> HTMLResponse:
    """④ 数据总览（`/admin`）。"""
    context = _base_context(
        request,
        web,
        active="overview",
        title="数据总览",
        data=data,
        recent=audit.recent_actions(db, limit=6),
        sections=stats.item_counts_by_section(db),
    )
    return templates.TemplateResponse(request=request, name="overview.html", context=context)


def render_items(request: Request, *, web: AdminWebSettings, db: Session) -> HTMLResponse:
    """② 商品管理。"""
    context = _base_context(
        request,
        web,
        active="items",
        title="商品管理",
        catalog=catalog.catalog(db),
        sections=stats.item_counts_by_section(db),
        suggested_id=catalog.new_item_id(),
    )
    return templates.TemplateResponse(request=request, name="items.html", context=context)


def render_users(request: Request, *, web: AdminWebSettings, data: dict[str, Any]) -> HTMLResponse:
    """③ 用户列表。"""
    context = _base_context(request, web, active="users", title="用户列表", data=data)
    return templates.TemplateResponse(request=request, name="users.html", context=context)


def render_orders(request: Request, *, web: AdminWebSettings, data: dict[str, Any]) -> HTMLResponse:
    """⑤ 订单记录。"""
    context = _base_context(request, web, active="orders", title="订单记录", data=data)
    return templates.TemplateResponse(request=request, name="orders.html", context=context)


def render_config(request: Request, *, web: AdminWebSettings, data: dict[str, Any]) -> HTMLResponse:
    """⑥ 系统配置。"""
    context = _base_context(request, web, active="config", title="系统配置", data=data)
    return templates.TemplateResponse(request=request, name="config.html", context=context)


def render_logs(
    request: Request, *, web: AdminWebSettings, data: dict[str, Any], action: str = ""
) -> HTMLResponse:
    """⑦ 操作日志。"""
    context = _base_context(request, web, active="logs", title="操作日志", data=data, action=action)
    return templates.TemplateResponse(request=request, name="logs.html", context=context)


def render_password(request: Request, *, web: AdminWebSettings) -> HTMLResponse:
    """① 改密码页。"""
    context = _base_context(request, web, active="password", title="修改密码")
    return templates.TemplateResponse(request=request, name="password.html", context=context)


__all__ = [
    "NAV",
    "fmt_int",
    "fmt_kg",
    "fmt_points",
    "fmt_time",
    "render_config",
    "render_items",
    "render_login",
    "render_logs",
    "render_orders",
    "render_overview",
    "render_password",
    "render_users",
    "templates",
]
