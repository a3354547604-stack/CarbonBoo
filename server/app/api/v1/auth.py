"""账号接口（逐条对齐 docs/APPENDIX-B-data-and-api.md §5.2）。

    POST   /api/v1/auth/register   注册（成功即登录，返回 userToken）
    POST   /api/v1/auth/login      口令登录
    GET    /api/v1/auth/me         当前账号（Bearer 客户端令牌）
    POST   /api/v1/auth/logout     登出（服务端无状态）
    DELETE /api/v1/auth/account    注销账号（软删除 + 保留 30 天可恢复；需二次口令）

本模块**只**依赖 `AuthProvider` 抽象（AGENTS §6 / ADR-0001）：不 import 任何具体 provider
（tests/test_authz.py 用源码扫描断言这一点）。错误响应统一由 main.py 的异常处理器翻译成
`{ok:false, code, message}`，这里不写 try/except。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Request, status

from app.core.config import Settings, get_settings
from app.core.errors import AppError, ErrorCode
from app.core.ratelimit import hit_login_limit
from app.core.security import bearer_token
from app.schemas.auth import (
    AuthData,
    DeleteAccountRequest,
    LoginRequest,
    LogoutData,
    MeData,
    PurgeData,
    RegisterRequest,
)
from app.schemas.common import ErrorEnvelope, OkEnvelope
from app.services.auth_provider import AuthProvider, AuthSession, get_auth_provider

router = APIRouter()

#: 文档化的失败响应（/docs 里每个端点都能看到 400/401/409/429 的响应体结构）
_ERROR_RESPONSES: dict[int | str, dict[str, object]] = {
    400: {"model": ErrorEnvelope, "description": "参数不合法（USERNAME_INVALID / PASSWORD_INVALID / INVALID_REQUEST）"},
    401: {"model": ErrorEnvelope, "description": "凭据错误或令牌失效（CREDENTIAL_INVALID / TOKEN_EXPIRED / TOKEN_INVALID）"},
    403: {"model": ErrorEnvelope, "description": "无权访问（FORBIDDEN）"},
    409: {"model": ErrorEnvelope, "description": "用户名已被占用（USERNAME_TAKEN）"},
    429: {"model": ErrorEnvelope, "description": "登录过于频繁（RATE_LIMITED）"},
}


def _auth_payload(session: AuthSession) -> AuthData:
    return AuthData(userToken=session.token, userId=session.user_id, username=session.username)


def _client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


@router.post(
    "/register",
    summary="注册账号",
    description="创建账号（用户名 4–20 位字母/数字/下划线；口令 6–32 位，口径见附录 B §5.2），成功即返回登录令牌。",
    status_code=status.HTTP_201_CREATED,  # 附录 B §5.2 写死 `// res 201`
    response_model=OkEnvelope[AuthData],
    responses=_ERROR_RESPONSES,
)
def register(
    payload: RegisterRequest,
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
) -> OkEnvelope[AuthData]:
    return OkEnvelope[AuthData](data=_auth_payload(provider.register(payload.username, payload.password)))


@router.post(
    "/login",
    summary="登录",
    description="口令登录。账号处于注销保留期（30 天）内且口令正确 → 自动恢复账号及其云端数据。",
    response_model=OkEnvelope[AuthData],
    responses=_ERROR_RESPONSES,
)
def login(
    payload: LoginRequest,
    request: Request,
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> OkEnvelope[AuthData]:
    # 登录限流（AGENTS §6）：键 = 客户端 IP + 用户名；阈值 LOGIN_RATE_LIMIT_PER_MINUTE（0 = 关闭）
    if not hit_login_limit(f"{_client_ip(request)}|{payload.username or ''}"):
        raise AppError(
            ErrorCode.RATE_LIMITED,
            f"登录尝试过于频繁，请 {60} 秒后再试（上限 {settings.login_rate_limit_per_minute} 次/分钟）",
        )
    return OkEnvelope[AuthData](data=_auth_payload(provider.login(payload.username, payload.password)))


@router.get(
    "/me",
    summary="当前账号",
    description="用客户端令牌换取当前账号身份（服务端会确认账号仍存在且未注销）。",
    response_model=OkEnvelope[MeData],
    responses=_ERROR_RESPONSES,
)
def me(
    token: Annotated[str, Depends(bearer_token)],
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
) -> OkEnvelope[MeData]:
    session = provider.current_session(token)
    return OkEnvelope[MeData](data=MeData(userId=session.user_id, username=session.username))


@router.post(
    "/logout",
    summary="登出",
    description="服务端无状态：不维护会话表，令牌自然到期；客户端应丢弃本地令牌（并清除同步游标）。",
    response_model=OkEnvelope[LogoutData],
    responses=_ERROR_RESPONSES,
)
def logout(
    token: Annotated[str, Depends(bearer_token)],
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
) -> OkEnvelope[LogoutData]:
    session = provider.current_session(token)
    provider.logout(session)
    return OkEnvelope[LogoutData](data=LogoutData(loggedOut=True))


@router.delete(
    "/account",
    summary="注销账号",
    description=(
        "注销语义（ADR-0001 决策 ③）：云端数据**软删除并保留 30 天**，期内用同一用户名 + 相同口令登录可恢复；"
        "逾期物理清除（返回 purgeAfter 时间点）。需二次口令确认。"
    ),
    response_model=OkEnvelope[PurgeData],
    responses=_ERROR_RESPONSES,
)
def delete_account(
    token: Annotated[str, Depends(bearer_token)],
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
    payload: DeleteAccountRequest | None = None,
) -> OkEnvelope[PurgeData]:
    purge_after = provider.delete_account(token, payload.password if payload else None)
    return OkEnvelope[PurgeData](data=PurgeData(purgeAfter=purge_after))


__all__ = ["router"]
