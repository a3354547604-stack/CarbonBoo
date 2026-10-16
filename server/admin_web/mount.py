"""后台挂载点：`mount_admin(app)` —— 本包对外**唯一**的集成接口。

集成说明（一行）
----------------
`server/app/main.py` 里已预留 `try: from admin_web.mount import mount_admin … mount_admin(app)`；
本模块把 `/admin/*` 的全部路由与一个异常处理器挂到应用上，**不改 main.py 一行**，也不占用
`/api/v1/*` 的任何路径（是可选件，缺了它客户端 API 一切照常 —— ADR-0001）。

挂载后新增的内容只有两类：

1. `admin_web.api.router`（`prefix="/admin"`）：附录 B §5.4 的全部管理端路径 + 三条后台自有路由
   （`POST /admin/logout`、`GET /admin/icons/{filename}`、`GET /admin/static/{filename}`）；
2. 一个异常处理器：`LoginRequired` → 303 跳 `/admin/login?next=…`。
   它是**本包私有**的异常类型，不会覆盖服务端切片对 `AppError` 的处理（客户端接口的错误信封不受影响）。

为什么处理器在这里注册而不是在 `api.py`：路由与全局钩子都属于"挂载"这件事，放在同一个缝里
可以一眼看清"后台给应用加了什么"。
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request, status
from fastapi.responses import RedirectResponse
from starlette.responses import Response

from admin_web import api
from admin_web.security import LoginRequired

logger = logging.getLogger("carbonboo.admin.mount")

#: 挂载标记（防止同一个 app 被重复挂载导致路由重复注册）
STATE_KEY = "carbonboo_admin_mounted"


async def _login_required_handler(request: Request, exc: Exception) -> Response:
    """未登录的页面请求 → 303 跳登录页（JSON 请求走 `AppError` → 401，不经过这里）。"""
    location = getattr(exc, "location", "/admin/login")
    return RedirectResponse(location, status_code=status.HTTP_303_SEE_OTHER)


def mount_admin(app: FastAPI) -> None:
    """把 Web 后台管理端挂到 `app` 上（幂等：同一个 app 重复调用是空操作）。"""
    if getattr(app.state, STATE_KEY, False):
        logger.debug("后台已挂载过，跳过重复挂载")
        return

    app.include_router(api.router)
    # Starlette 的 add_exception_handler 支持任意异常类；这里只登记本包私有的 LoginRequired，
    # 不碰 AppError（那是服务端切片的处理器，覆盖它会让 /api/v1/* 的错误信封变形）。
    app.add_exception_handler(LoginRequired, _login_required_handler)
    setattr(app.state, STATE_KEY, True)

    routes = sorted(
        {getattr(route, "path", "") for route in api.router.routes if getattr(route, "path", "")}
    )
    logger.info("Web 后台管理端已挂载：%d 条路由 %s", len(routes), routes)


__all__ = ["STATE_KEY", "mount_admin"]
