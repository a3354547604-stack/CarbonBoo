"""统一错误码与异常。

错误码取自 docs/APPENDIX-B-data-and-api.md §5.2「错误码」表；`INVALID_REQUEST` 是文档未列出的
补充码，用于请求体结构/类型错误（附录 B §5.2 只规定了业务语义错误），在 server/README.md 中已注明。

HTTP 状态映射同样以 §5.2 为准：
    400 参数不合法 / 401 未登录或凭据错误 / 403 无权访问 / 404 资源不存在 / 409 用户名占用 / 429 限流 / 500 服务端异常
"""

from __future__ import annotations

from enum import Enum


class ErrorCode(str, Enum):
    """`ok: false` 响应体里的 `code`。"""

    INVALID_REQUEST = "INVALID_REQUEST"  # 400 请求体结构/类型不合法（补充码）
    USERNAME_INVALID = "USERNAME_INVALID"  # 400 用户名格式或长度不合法
    PASSWORD_INVALID = "PASSWORD_INVALID"  # 400 口令不满足强度要求
    USERNAME_TAKEN = "USERNAME_TAKEN"  # 409 用户名已被占用
    CREDENTIAL_INVALID = "CREDENTIAL_INVALID"  # 401 用户名或口令错误
    TOKEN_EXPIRED = "TOKEN_EXPIRED"  # 401 令牌过期，客户端应重新登录
    TOKEN_INVALID = "TOKEN_INVALID"  # 401 令牌缺失/非法/账号已注销
    FORBIDDEN = "FORBIDDEN"  # 403 无权访问（含客户端 token 访问 /admin/*）
    NOT_FOUND = "NOT_FOUND"  # 404 资源不存在
    RATE_LIMITED = "RATE_LIMITED"  # 429 登录限流
    SERVER_ERROR = "SERVER_ERROR"  # 500 服务端异常


#: 错误码 → HTTP 状态码（APPENDIX-B §5.2 错误码表）
ERROR_HTTP_STATUS: dict[ErrorCode, int] = {
    ErrorCode.INVALID_REQUEST: 400,
    ErrorCode.USERNAME_INVALID: 400,
    ErrorCode.PASSWORD_INVALID: 400,
    ErrorCode.USERNAME_TAKEN: 409,
    ErrorCode.CREDENTIAL_INVALID: 401,
    ErrorCode.TOKEN_EXPIRED: 401,
    ErrorCode.TOKEN_INVALID: 401,
    ErrorCode.FORBIDDEN: 403,
    ErrorCode.NOT_FOUND: 404,
    ErrorCode.RATE_LIMITED: 429,
    ErrorCode.SERVER_ERROR: 500,
}


#: HTTP 状态码 → 兜底错误码（框架自身产生、没有走 AppError 的响应，例如 404 路由不存在）。
#: 仅为统一响应信封用；业务错误一律显式 AppError(code=...)（§5.2 错误码表）。
HTTP_STATUS_ERROR_CODE: dict[int, ErrorCode] = {
    400: ErrorCode.INVALID_REQUEST,
    401: ErrorCode.TOKEN_INVALID,
    403: ErrorCode.FORBIDDEN,
    404: ErrorCode.NOT_FOUND,
    405: ErrorCode.INVALID_REQUEST,
    409: ErrorCode.USERNAME_TAKEN,
    429: ErrorCode.RATE_LIMITED,
    500: ErrorCode.SERVER_ERROR,
}


class AppError(Exception):
    """业务异常：由 main.py 的异常处理器统一翻译成 `{ok, code, message}` + HTTP 状态码。"""

    def __init__(self, code: ErrorCode, message: str, *, http_status: int | None = None) -> None:
        super().__init__(message)
        self.code: ErrorCode = code
        self.message: str = message
        self.http_status: int = http_status or ERROR_HTTP_STATUS.get(code, 500)

    def to_body(self) -> dict[str, object]:
        return {"ok": False, "code": self.code.value, "message": self.message}

    def __repr__(self) -> str:  # pragma: no cover - 调试用
        return f"AppError(code={self.code.value!r}, http_status={self.http_status}, message={self.message!r})"


class ProviderNotImplementedError(AppError):
    """预留的 AuthProvider（server / huaweiId）被选用时的明确失败。"""

    def __init__(self, provider_id: str) -> None:
        super().__init__(
            ErrorCode.SERVER_ERROR,
            f"AuthProvider '{provider_id}' 为预留实现，尚未启用（当前可用：local）",
        )
        self.provider_id = provider_id


__all__ = [
    "AppError",
    "ERROR_HTTP_STATUS",
    "HTTP_STATUS_ERROR_CODE",
    "ErrorCode",
    "ProviderNotImplementedError",
]
