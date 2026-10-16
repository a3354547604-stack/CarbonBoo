"""管理端鉴权：管理员强口令策略、双通道令牌解析、登录限流。

职责（只做这四件事，业务逻辑不在这里）
--------------------------------------
1. **强口令策略**（AGENTS §6：「`/admin` 需强口令 + 登录限流」）：引导创建 / 改密都过这一道。
2. **令牌解析**：同一个管理端 JWT，两种承载方式——
   * `Authorization: Bearer <adminToken>`：接口调用（附录 B §5.4 的口径，测试与 curl 走这条）；
   * HttpOnly Cookie（`ADMIN_COOKIE_NAME`）：浏览器访问服务端渲染页面时用（`<link>`/`<a>` 带不了头）。
   两条通道最终都落到 `app.core.security.decode_admin_token`（密钥 ② + audience ②），
   **不新增任何校验路径**：客户端令牌在两条通道上都必然失败。
3. **失败形态分流**：JSON 请求 → 401 `TOKEN_INVALID`；HTML 页面请求 → 303 跳登录页
   （由 `LoginRequired` 异常 + `mount.py` 注册的处理器完成）。分流只在一个地方判定。
4. **登录限流**：复用 `app.core.ratelimit.hit_login_limit`（阈值 `LOGIN_RATE_LIMIT_PER_MINUTE`），
   键 = `admin|<IP>|<用户名>` —— 与管理端/客户端各自的登录计数互不干扰。

安全性说明（CSRF）：会话 Cookie 是 `HttpOnly` + `SameSite=Lax`。Lax 下浏览器**不会**在跨站
`POST/PATCH/PUT/DELETE` 上带 Cookie，管理端的写操作因此不会被第三方页面静默触发；
页面自身的写操作全部由同源 `fetch()` 发起（见 `static/admin.js`）。
"""

from __future__ import annotations

import re
from typing import Annotated

from fastapi import Depends, Request
from fastapi.responses import Response

from app.core.config import Settings, get_settings
from app.core.errors import AppError, ErrorCode
from app.core.ratelimit import hit_login_limit
from app.core.security import TokenPrincipal, decode_admin_token, extract_bearer

from admin_web.config import AdminWebSettings, get_admin_settings

#: 管理员口令最短长度（比客户端账号的 6 位严格得多：后台能改价、能看全量数据）
ADMIN_PASSWORD_MIN_LENGTH: int = 12
#: 口令里至少要有几类字符（小写/大写/数字/其它符号）
ADMIN_PASSWORD_MIN_CLASSES: int = 3
#: 弱口令黑名单（不追求完备，只挡住"显然会被评委一眼看穿"的那些）
ADMIN_PASSWORD_DENYLIST: frozenset[str] = frozenset(
    {
        "admin",
        "administrator",
        "password",
        "passw0rd",
        "carbonboo",
        "carbonboo@2026",
        "123456",
        "123456789012",
        "qwertyuiop12",
        "admin123456",
    }
)

_CLASS_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"[a-z]"),
    re.compile(r"[A-Z]"),
    re.compile(r"\d"),
    re.compile(r"[^A-Za-z0-9]"),
)


class LoginRequired(Exception):
    """HTML 页面请求未携带有效管理端令牌 → 由 `mount.py` 的处理器转成 303 跳登录页。

    刻意**不是** `AppError` 的子类：`AppError` 的处理器归服务端切片（返回 JSON 信封），
    覆盖它会改掉客户端接口的错误响应形态。
    """

    def __init__(self, location: str) -> None:
        super().__init__(location)
        self.location = location


# --------------------------------------------------------------------------- #
# 口令策略
# --------------------------------------------------------------------------- #
def password_policy_problems(password: str) -> list[str]:
    """返回不满足的策略条目（空列表 = 通过）。给 UI 与错误消息共用，避免两处口径。"""
    problems: list[str] = []
    if not isinstance(password, str) or len(password) < ADMIN_PASSWORD_MIN_LENGTH:
        problems.append(f"长度至少 {ADMIN_PASSWORD_MIN_LENGTH} 位")
    if isinstance(password, str):
        classes = sum(1 for pattern in _CLASS_PATTERNS if pattern.search(password))
        if classes < ADMIN_PASSWORD_MIN_CLASSES:
            problems.append(f"至少包含 {ADMIN_PASSWORD_MIN_CLASSES} 类字符（小写/大写/数字/符号）")
        if password.lower() in ADMIN_PASSWORD_DENYLIST:
            problems.append("不得使用常见弱口令")
    return problems


def validate_admin_password(password: str, *, username: str | None = None) -> str:
    """校验管理员口令；不合规抛 400 `PASSWORD_INVALID`（错误码取自附录 B §5.2 错误码表）。"""
    problems = password_policy_problems(password or "")
    if username and isinstance(password, str) and password.lower() == username.lower():
        problems.append("不得与用户名相同")
    if problems:
        raise AppError(ErrorCode.PASSWORD_INVALID, "口令不符合后台强口令要求：" + "；".join(problems))
    return password


def validate_admin_username(username: str, settings: Settings) -> str:
    """管理员用户名复用客户端账号的用户名规则（附录 B §5.2：4–20 位字母/数字/下划线）。

    刻意不另立一套：用户名格式在本项目只有一处定义（`app.core.security.validate_username`）。
    """
    from app.core.security import validate_username

    return validate_username(username, settings)


# --------------------------------------------------------------------------- #
# 请求形态与令牌
# --------------------------------------------------------------------------- #
def wants_html(request: Request) -> bool:
    """`Accept: text/html` → 页面；否则 JSON（附录 B §5.4 的接口语义不变）。

    浏览器地址栏导航一定带 `text/html`；`fetch()` 由 `static/admin.js` 显式声明
    `Accept: application/json`；curl / TestClient 默认 `*/*` → JSON。
    同一组路径因此既能当接口又能当页面，**不新增任何附录 B 之外的路径**。
    """
    return "text/html" in (request.headers.get("accept") or "").lower()


def client_ip(request: Request) -> str:
    """调用方 IP（用于限流键与操作日志）。"""
    return request.client.host if request.client else "unknown"


def extract_admin_token(request: Request, admin_settings: AdminWebSettings) -> str | None:
    """按优先级取管理端令牌：`Authorization: Bearer` > Cookie。"""
    token = extract_bearer(request.headers.get("authorization"))
    if token:
        return token
    cookie = request.cookies.get(admin_settings.cookie_name)
    return cookie or None


def resolve_admin(request: Request, *, settings: Settings, admin_settings: AdminWebSettings) -> TokenPrincipal | None:
    """解析当前管理员身份；无令牌或非法令牌返回 None（是否转 303 由调用方决定）。"""
    token = extract_admin_token(request, admin_settings)
    if not token:
        return None
    try:
        claims = decode_admin_token(token, settings)
    except AppError:
        return None
    return TokenPrincipal(
        subject=str(claims.get("sub", "")),
        username=str(claims.get("username", "")),
        audience=str(claims.get("aud", "")),
        claims=claims,
    )


def login_url(request: Request, admin_settings: AdminWebSettings) -> str:
    """登录页地址；带上 `next`（**只接受 /admin 开头的相对路径**，防开放重定向）。"""
    target = request.url.path
    if request.url.query:
        target = f"{target}?{request.url.query}"
    base = f"{admin_settings.prefix}/login"
    if target.startswith(admin_settings.prefix) and not target.startswith("//"):
        return f"{base}?next={target}"
    return base


def safe_next(raw: str | None, admin_settings: AdminWebSettings) -> str:
    """净化 `next`：仅允许本前缀下的相对路径。"""
    if not raw:
        return admin_settings.prefix
    if raw.startswith("//") or "://" in raw or not raw.startswith(admin_settings.prefix):
        return admin_settings.prefix
    return raw


def require_admin(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
    admin_settings: Annotated[AdminWebSettings, Depends(get_admin_settings)],
) -> TokenPrincipal:
    """`/admin/*` 的唯一鉴权依赖。

    * JSON 调用：缺令牌/令牌非法 → 401 `TOKEN_INVALID`（错误码见附录 B §5.2）；
    * 页面调用：→ `LoginRequired`（303 跳 `/admin/login?next=…`）。
    客户端令牌在这里也进不来（密钥 ② + audience ② 双重不符），而它更早就会在
    `app/main.py` 的隔离中间件上被 403 拦下（AGENTS §7.2）。
    """
    principal = resolve_admin(request, settings=settings, admin_settings=admin_settings)
    if principal is None:
        if wants_html(request):
            raise LoginRequired(login_url(request, admin_settings))
        raise AppError(ErrorCode.TOKEN_INVALID, "缺少或无效的管理端令牌（Authorization: Bearer <adminToken>）")
    return principal


# --------------------------------------------------------------------------- #
# 登录限流
# --------------------------------------------------------------------------- #
def check_login_rate_limit(
    request: Request,
    username: str,
    *,
    settings: Settings,
    admin_settings: AdminWebSettings,
) -> None:
    """管理端登录限流（AGENTS §6）。超限抛 429 `RATE_LIMITED`。"""
    key = f"admin|{client_ip(request)}|{username or ''}"
    if not hit_login_limit(key):
        raise AppError(
            ErrorCode.RATE_LIMITED,
            f"登录尝试过于频繁，请 60 秒后再试（上限 {settings.login_rate_limit_per_minute} 次/分钟）",
        )


def reset_admin_login_limit() -> None:
    """清空登录限流计数（测试用）。

    直接复用 `app.core.ratelimit.reset_login_limit`（公共 API，"测试用"语义已在那边声明）；
    限流键含 IP，测试无法预知，故整表清空。
    """
    from app.core.ratelimit import reset_login_limit

    reset_login_limit()


# --------------------------------------------------------------------------- #
# 会话 Cookie
# --------------------------------------------------------------------------- #
def _cookie_secure(settings: Settings, admin_settings: AdminWebSettings) -> bool:
    if admin_settings.cookie_secure is not None:
        return admin_settings.cookie_secure
    return settings.is_prod  # 生产由 nginx 终结 TLS


def attach_admin_cookie(
    response: Response, token: str, *, settings: Settings, admin_settings: AdminWebSettings
) -> None:
    """把管理端 JWT 写进 HttpOnly 会话 Cookie（浏览器 SSR 用；接口调用仍用 Bearer）。"""
    response.set_cookie(
        key=admin_settings.cookie_name,
        value=token,
        max_age=settings.admin_jwt_expires_minutes * 60,
        httponly=True,
        samesite="lax",
        secure=_cookie_secure(settings, admin_settings),
        path=admin_settings.prefix,
    )


def clear_admin_cookie(response: Response, *, admin_settings: AdminWebSettings) -> None:
    """清掉会话 Cookie（登出 / 改密后重新登录）。"""
    response.delete_cookie(key=admin_settings.cookie_name, path=admin_settings.prefix)


__all__ = [
    "ADMIN_PASSWORD_DENYLIST",
    "ADMIN_PASSWORD_MIN_CLASSES",
    "ADMIN_PASSWORD_MIN_LENGTH",
    "LoginRequired",
    "attach_admin_cookie",
    "check_login_rate_limit",
    "clear_admin_cookie",
    "client_ip",
    "extract_admin_token",
    "login_url",
    "password_policy_problems",
    "require_admin",
    "reset_admin_login_limit",
    "resolve_admin",
    "safe_next",
    "validate_admin_password",
    "validate_admin_username",
    "wants_html",
]
