"""请求/响应 Pydantic 模型（schema 层）。

字段名**直接采用附录 B §5.2 里的 JSON 键名**（camelCase），保证 /docs 里显示的契约与文档逐字一致，
不引入 alias 映射（少一层翻译就少一处口径分叉）。
"""

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

__all__ = [
    "AuthData",
    "DeleteAccountRequest",
    "ErrorEnvelope",
    "LoginRequest",
    "LogoutData",
    "MeData",
    "OkEnvelope",
    "PurgeData",
    "RegisterRequest",
]
