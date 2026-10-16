"""FastAPI 应用入口（uvicorn app.main:app）。

职责
----
1. 组装应用：配置（环境变量 / .env 注入）、路由、异常处理器、管理端隔离中间件。
2. **管理端隔离**（AGENTS §7.2 硬约束）：`/admin/*` 只认管理端令牌（密钥 ②）。
   客户端令牌（密钥 ① 签发）访问任何 `/admin/*` 一律 403 —— 由中间件在进入路由**之前**判定，
   因此即使某一层忘了加鉴权依赖，客户端令牌也进不去。
3. 预留 Web 后台挂载点（可选件，由 t6 在 `server/admin_web/mount.py` 提供 `mount_admin(app)`）。

启动：
    cd server && .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 2
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy import text
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api.v1 import router as api_v1_router
from app.core.config import VERSION, Settings, get_settings
from app.core.database import get_engine
from app.core.errors import AppError, ErrorCode, HTTP_STATUS_ERROR_CODE
from app.core.security import decode_user_token, extract_bearer

logger = logging.getLogger("carbonboo.server")

#: 管理端路径前缀：客户端令牌在此前缀下必须 403
ADMIN_PATH_PREFIX = "/admin"

_DESCRIPTION = """
CarbonBoo（碳小布）个人碳账本 · 服务端 API。

* 口径来源：`docs/APPENDIX-B-data-and-api.md`（表与接口）、`docs/adr/0001-account-and-sync.md`（账号与同步决策）。
* 服务端是**必做件**：账号 + 多设备同步 + 商品取价 + 云端备份；**唯一可选项是 Web 后台管理端**。
* 未登录 = 纯单机：服务端不做任何隐式上传，登录后才有多设备同步 / 云端备份 / 家庭合并统计。
* 鉴权：客户端与管理端**两套独立 JWT 密钥**；客户端令牌访问任何 `/admin/*` 一律 403。
* 版本：{version}
""".format(version=VERSION)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """启动自检：库结构由 sql/schema.sql 负责（幂等），这里只做连通性检查与日志。"""
    settings = get_settings()
    logger.info(
        "CarbonBoo 服务端启动 env=%s dsn=%s docs=%s auth_provider=%s",
        settings.app_env,
        settings.database_url_masked,
        settings.effective_docs_url or "(关闭)",
        settings.auth_provider,
    )
    try:
        with get_engine().connect() as connection:
            connection.execute(text("SELECT 1"))
        logger.info("MySQL 连通性检查：通过")
    except Exception:
        logger.exception("MySQL 连通性检查：失败（请确认已执行 sql/schema.sql 且服务已启动）")
        if settings.is_prod:
            # 生产环境宁可起不来，也不要“起来了但每个请求都 500”
            raise
    yield
    logger.info("CarbonBoo 服务端已停止")


def create_app(settings: Settings | None = None) -> FastAPI:
    """构造 FastAPI 应用（测试可传入自定义 Settings）。"""
    settings = settings or get_settings()

    app = FastAPI(
        title="CarbonBoo 服务端 API",
        description=_DESCRIPTION,
        version=VERSION,
        docs_url=settings.effective_docs_url,
        openapi_url="/openapi.json" if settings.effective_docs_url else None,
        redoc_url=None,
        lifespan=lifespan,
    )

    # ---------- 路由 ----------
    app.include_router(api_v1_router, prefix=settings.api_prefix)

    # ---------- 异常处理器：统一 {ok, code, message} ----------
    @app.exception_handler(AppError)
    async def _app_error(request: Request, exc: AppError) -> JSONResponse:
        return JSONResponse(status_code=exc.http_status, content=exc.to_body())

    @app.exception_handler(RequestValidationError)
    async def _invalid_request(request: Request, exc: RequestValidationError) -> JSONResponse:
        logger.info("请求体校验失败 %s %s: %s", request.method, request.url.path, exc.errors())
        return JSONResponse(
            status_code=400,
            content={
                "ok": False,
                "code": ErrorCode.INVALID_REQUEST.value,
                "message": "请求体结构或参数类型不合法",
            },
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        """框架自身产生的 HTTP 错误（404 路由不存在、405 方法不允许）也走统一信封。

        口径：`{ok:false, code, message}`（附录 B §5.2）。管理端挂载前 `/admin/*` 会落到这里
        返回 404 —— 与 t6 的约定：403 只由中间件（客户端令牌）产生，其余按实际状态码。
        """
        http_status = int(exc.status_code)
        code = HTTP_STATUS_ERROR_CODE.get(http_status)
        if code is None:
            code = ErrorCode.SERVER_ERROR if http_status >= 500 else ErrorCode.INVALID_REQUEST
        message = exc.detail if isinstance(exc.detail, str) and exc.detail else code.value
        if http_status >= 500:
            logger.exception("HTTP %s %s %s", http_status, request.method, request.url.path)
        return JSONResponse(status_code=http_status, content={"ok": False, "code": code.value, "message": message})

    # ---------- 管理端隔离中间件 ----------
    @app.middleware("http")
    async def _isolate_admin_scope(request: Request, call_next):  # type: ignore[no-untyped-def]
        path = request.url.path
        if path == ADMIN_PATH_PREFIX or path.startswith(ADMIN_PATH_PREFIX + "/"):
            token = extract_bearer(request.headers.get("authorization"))
            if token:
                try:
                    decode_user_token(token, settings)  # 客户端密钥 ①
                except AppError:
                    pass  # 不是合法客户端令牌：交由 /admin 自己的鉴权处理（管理端令牌走密钥 ②）
                else:
                    logger.warning("客户端令牌尝试访问管理端：%s %s", request.method, path)
                    return JSONResponse(
                        status_code=403,
                        content={
                            "ok": False,
                            "code": ErrorCode.FORBIDDEN.value,
                            "message": "客户端令牌无权访问管理端（客户端与管理端是两套独立令牌）",
                        },
                    )
        return await call_next(request)

    # ---------- 可选管理后台挂载点（t6 在 server/admin_web/mount.py 提供） ----------
    _mount_optional_admin(app)

    return app


def _mount_optional_admin(app: FastAPI) -> None:
    """尝试挂载 Web 管理后台（可选件，ADR-0001）。缺失或失败都不影响客户端 API。"""
    try:
        from admin_web.mount import mount_admin  # type: ignore[import-not-found]
    except Exception:
        logger.info("未挂载管理后台：admin_web.mount 不可用（可选件，见 ADR-0001）")
        return
    try:
        mount_admin(app)
        logger.info("已挂载 Web 管理后台：%s/*", ADMIN_PATH_PREFIX)
    except Exception:
        logger.exception("挂载管理后台失败，已忽略（不影响客户端 API）")


#: uvicorn 入口
app = create_app()


__all__ = ["ADMIN_PATH_PREFIX", "app", "create_app", "lifespan"]
