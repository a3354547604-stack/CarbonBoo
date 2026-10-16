"""口令哈希与 JWT 签发/校验（客户端与管理端两套独立密钥）。

职责
----
* 口令：bcrypt 单向哈希（passlib CryptContext，rounds=12），落库列 `server_user.password_hash`。
* 令牌：JWT（HS256），签发与校验成对出现；客户端令牌 audience=carbonboo-client，
  管理端令牌 audience=carbonboo-admin，**两把密钥 + 两个 audience**，任一维度不符即 401。
* FastAPI 依赖：`require_user` / `require_admin`，供各路由声明鉴权要求。

为什么 audience 也要区分：只换密钥时，若密钥被误配成同一把（或未来加了密钥轮换），
audience 仍能保证「同一把密钥签出的客户端令牌进不了 /admin」。
依据：docs/APPENDIX-B-data-and-api.md §5.2、AGENTS.md §6/§7.2、docs/adr/0001-account-and-sync.md。
"""

from __future__ import annotations

import logging
import re
import time
import uuid
from dataclasses import dataclass, field
from typing import Annotated, Any

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from jose.exceptions import ExpiredSignatureError
from passlib.context import CryptContext

from app.core.config import Settings, get_settings
from app.core.errors import AppError, ErrorCode

logger = logging.getLogger("carbonboo.server.security")

#: 用户名字符集：字母/数字/下划线（长度区间见 Settings.username_min_length / max_length）
#: 规则逐字取自附录 B §5.2 错误码表：「USERNAME_INVALID | 400 | 用户名不符合 4–20 位字母数字下划线」
USERNAME_RE = re.compile(r"^[A-Za-z0-9_]+$")

_pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto", bcrypt__rounds=12)


def now_ms() -> int:
    """当前时间（毫秒，全服务端时间戳口径与客户端一致）。"""
    return int(time.time() * 1000)


# --------------------------------------------------------------------------- #
# 口令
# --------------------------------------------------------------------------- #
def hash_password(plain: str) -> str:
    """bcrypt 哈希（每次调用盐不同；同一口令两次结果不同）。"""
    return _pwd_context.hash(plain)


def verify_password(plain: str, hashed: str) -> bool:
    """常量时间校验；哈希串损坏时返回 False 而不是抛异常（避免把库内异常暴露成 500）。"""
    try:
        return _pwd_context.verify(plain, hashed)
    except (ValueError, TypeError):  # pragma: no cover - 仅在库内哈希被损坏时发生
        logger.warning("password_hash 无法解析，按校验失败处理")
        return False


def validate_username(username: str, settings: Settings) -> str:
    """校验用户名格式，返回原样用户名（不做大小写折叠，用户名区分大小写）。

    规则 = 附录 B §5.2：4–20 位字母/数字/下划线（不要求字母开头，不允许空格与连字符）。
    """
    if (
        not isinstance(username, str)
        or not USERNAME_RE.match(username)
        or not (settings.username_min_length <= len(username) <= settings.username_max_length)
    ):
        raise AppError(
            ErrorCode.USERNAME_INVALID,
            f"用户名须为 {settings.username_min_length}–{settings.username_max_length} 位字母/数字/下划线",
        )
    return username


def validate_password(password: str, settings: Settings) -> str:
    """校验口令：只约束长度区间。

    规则 = 附录 B §5.2「PASSWORD_INVALID | 400 | 密码不符合 6–32 位」；文档示例口令 `abc12345`
    必须可用，故**不额外要求符号或字母数字组合**（多一条规则就会拒掉文档自己的示例）。
    """
    if not isinstance(password, str):
        raise AppError(ErrorCode.PASSWORD_INVALID, "口令必须是字符串")
    if not (settings.password_min_length <= len(password) <= settings.password_max_length):
        raise AppError(
            ErrorCode.PASSWORD_INVALID,
            f"口令长度须在 {settings.password_min_length}–{settings.password_max_length} 位之间",
        )
    return password


# --------------------------------------------------------------------------- #
# JWT
# --------------------------------------------------------------------------- #
def _create_token(
    *,
    subject: str,
    username: str,
    secret: str,
    audience: str,
    algorithm: str,
    issuer: str,
    expires_minutes: int,
) -> tuple[str, int]:
    """签发 JWT，返回 (token, 过期时间毫秒)。"""
    issued_at = int(time.time())
    expires_at = issued_at + expires_minutes * 60
    claims: dict[str, Any] = {
        "sub": subject,
        "username": username,
        "aud": audience,
        "iss": issuer,
        "iat": issued_at,
        "nbf": issued_at,
        "exp": expires_at,
        "jti": uuid.uuid4().hex,
    }
    token = jwt.encode(claims, secret, algorithm=algorithm)
    return token, expires_at * 1000


def create_user_token(user_id: str, username: str, settings: Settings | None = None) -> tuple[str, int]:
    """客户端（App）令牌：密钥 ①，audience=carbonboo-client。"""
    settings = settings or get_settings()
    return _create_token(
        subject=user_id,
        username=username,
        secret=settings.jwt_secret,
        audience=settings.jwt_user_audience,
        algorithm=settings.jwt_algorithm,
        issuer=settings.jwt_issuer,
        expires_minutes=settings.jwt_access_token_expires_minutes,
    )


def create_admin_token(admin_id: str, username: str, settings: Settings | None = None) -> tuple[str, int]:
    """管理端（Web 后台）令牌：密钥 ②，audience=carbonboo-admin。"""
    settings = settings or get_settings()
    return _create_token(
        subject=admin_id,
        username=username,
        secret=settings.admin_jwt_secret,
        audience=settings.jwt_admin_audience,
        algorithm=settings.jwt_algorithm,
        issuer=settings.jwt_issuer,
        expires_minutes=settings.admin_jwt_expires_minutes,
    )


def _decode_token(token: str, *, secret: str, audience: str, settings: Settings) -> dict[str, Any]:
    try:
        return jwt.decode(
            token,
            secret,
            algorithms=[settings.jwt_algorithm],
            audience=audience,
            issuer=settings.jwt_issuer,
        )
    except ExpiredSignatureError as exc:
        raise AppError(ErrorCode.TOKEN_EXPIRED, "令牌已过期，请重新登录") from exc
    except JWTError as exc:
        # 签名不符（另一套密钥）/ audience 不符（客户端令牌进管理端）/ 结构损坏，一律 401
        raise AppError(ErrorCode.TOKEN_INVALID, "令牌非法或已失效") from exc


def decode_user_token(token: str, settings: Settings | None = None) -> dict[str, Any]:
    """校验客户端令牌；用管理端密钥签的令牌在这里必然失败（两套密钥不通用）。"""
    settings = settings or get_settings()
    return _decode_token(
        token, secret=settings.jwt_secret, audience=settings.jwt_user_audience, settings=settings
    )


def decode_admin_token(token: str, settings: Settings | None = None) -> dict[str, Any]:
    """校验管理端令牌。"""
    settings = settings or get_settings()
    return _decode_token(
        token, secret=settings.admin_jwt_secret, audience=settings.jwt_admin_audience, settings=settings
    )


def extract_bearer(authorization: str | None) -> str | None:
    """从 `Authorization: Bearer <token>` 取出令牌；缺失或格式不符返回 None。"""
    if not authorization:
        return None
    parts = authorization.split(None, 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None
    return parts[1].strip() or None


# --------------------------------------------------------------------------- #
# FastAPI 鉴权依赖
# --------------------------------------------------------------------------- #
#: /docs 的 Authorize 按钮 + 每个受保护端点的锁标记（客户端令牌；管理端令牌由下面的 AdminToken 提供）
bearer_scheme = HTTPBearer(
    auto_error=False,
    scheme_name="ClientToken",
    description="客户端令牌：`Authorization: Bearer <userToken>`（register/login 返回）",
)
admin_bearer_scheme = HTTPBearer(
    auto_error=False,
    scheme_name="AdminToken",
    description="管理端令牌：`Authorization: Bearer <adminToken>`（/admin/login 返回，另一把密钥签发）",
)


@dataclass(frozen=True)
class TokenPrincipal:
    """已通过校验的调用方身份（`/admin/*` 路由用）。"""

    subject: str  # 管理端 = admin_user.id
    username: str
    audience: str
    claims: dict[str, Any] = field(default_factory=dict)


def bearer_token(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)] = None,
) -> str:
    """取出客户端 Bearer 令牌；缺失或格式不符 → 401 TOKEN_INVALID。"""
    token = credentials.credentials if credentials else None
    if not token:
        raise AppError(ErrorCode.TOKEN_INVALID, "缺少 Authorization: Bearer <token>")
    return token


def require_admin(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(admin_bearer_scheme)] = None,
    settings: Annotated[Settings, Depends(get_settings)] = None,  # type: ignore[assignment]
) -> TokenPrincipal:
    """管理端鉴权依赖（供 t6 的 `/admin/*` 路由使用）：只认密钥 ② 签发的管理端令牌。

    客户端令牌在这里必然 401（密钥与 audience 双重不符）；而客户端令牌访问 `/admin/*` 的
    403 由 `main.py` 的隔离中间件提前给出（AGENTS §7.2）。
    """
    token = credentials.credentials if credentials else None
    if not token:
        raise AppError(ErrorCode.TOKEN_INVALID, "缺少 Authorization: Bearer <token>")
    claims = decode_admin_token(token, settings)
    return TokenPrincipal(
        subject=str(claims.get("sub", "")),
        username=str(claims.get("username", "")),
        audience=str(claims.get("aud", "")),
        claims=claims,
    )


__all__ = [
    "USERNAME_RE",
    "TokenPrincipal",
    "admin_bearer_scheme",
    "bearer_scheme",
    "bearer_token",
    "create_admin_token",
    "create_user_token",
    "decode_admin_token",
    "decode_user_token",
    "extract_bearer",
    "hash_password",
    "now_ms",
    "require_admin",
    "validate_password",
    "validate_username",
    "verify_password",
]
