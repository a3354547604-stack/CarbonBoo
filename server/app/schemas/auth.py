"""账号接口的请求/响应模型（逐字对齐 docs/APPENDIX-B-data-and-api.md §5.2）。

关于请求体的两点口径说明：
1. `username` / `password` 在 schema 层声明为可选，是为了让**语义错误**走文档规定的错误码
   （USERNAME_INVALID / PASSWORD_INVALID，400），而不是被 Pydantic 提前拦成 422；
   服务端在 AuthProvider 内强制要求二者存在且合法。
2. 附录 B §5.2 register 的示例体里有 `usingCount` / `mode` / `mergePolicy`，那是**客户端本地上下文**，
   服务端忽略未知字段（`extra="ignore"`）；`deviceId` 按 B35 契约已从注册/登录体移除，
   客户端若仍带上也会被忽略（server_user 表根本没有 device_id 列）。
"""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class _BodyModel(BaseModel):
    """请求体基类：忽略未知字段（兼容客户端多带的本地上下文）。"""

    model_config = ConfigDict(extra="ignore")


class RegisterRequest(_BodyModel):
    """POST /api/v1/auth/register 请求体。"""

    username: str | None = Field(
        default=None,
        description="用户名：4–20 位字母/数字/下划线（必填，缺失返回 USERNAME_INVALID）",
        examples=["harry_01"],
    )
    password: str | None = Field(
        default=None,
        description="口令：6–32 位（必填，缺失返回 PASSWORD_INVALID）",
        examples=["abc12345"],
    )


class LoginRequest(_BodyModel):
    """POST /api/v1/auth/login 请求体。"""

    username: str | None = Field(default=None, description="用户名", examples=["harry_01"])
    password: str | None = Field(default=None, description="口令", examples=["abc12345"])


class DeleteAccountRequest(_BodyModel):
    """DELETE /api/v1/auth/account 请求体：二次口令确认。"""

    password: str | None = Field(
        default=None,
        description="当前账号口令（二次确认；缺失或错误返回 CREDENTIAL_INVALID）",
        examples=["abc12345"],
    )


class AuthData(BaseModel):
    """注册 / 登录成功后的业务数据（§5.2：`{ userToken, userId, username }`）。"""

    userToken: str = Field(description="JWT 客户端令牌（密钥 ① 签发，audience=carbonboo-client）")
    userId: str = Field(description="云数据归属键，客户端写入各业务表的 user_id 列")
    username: str = Field(description="用户名")


class MeData(BaseModel):
    """GET /api/v1/auth/me 的业务数据。"""

    userId: str = Field(description="云数据归属键")
    username: str = Field(description="用户名")


class LogoutData(BaseModel):
    """POST /api/v1/auth/logout 的业务数据（服务端无状态，仅提示客户端清理本地令牌）。"""

    loggedOut: bool = Field(default=True, description="恒为 true；客户端应丢弃本地 tokens 并清除同步游标")


class PurgeData(BaseModel):
    """DELETE /api/v1/auth/account 的业务数据（注销语义：软删除保留 30 天，期内可恢复）。"""

    #: 严格对齐 APPENDIX-B §5.2 的响应体 `{ "ok": true, "data": { "purgeAfter": 1764892000000 } }`：
    #: 只给毫秒时间戳，不额外塞派生字段（时间点的文本化由客户端 Formatter 负责，铁律：格式统一走 Formatter）。
    purgeAfter: int = Field(description="物理清除时间点（毫秒时间戳）= 注销时刻 + ACCOUNT_PURGE_GRACE_DAYS 天")


__all__ = [
    "AuthData",
    "DeleteAccountRequest",
    "LoginRequest",
    "LogoutData",
    "MeData",
    "PurgeData",
    "RegisterRequest",
]
