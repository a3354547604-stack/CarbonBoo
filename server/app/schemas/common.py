"""统一响应包装。

附录 B §5.2「所有接口返回 `{ "ok": true, "data": {...} }`」：
成功 = OkEnvelope[T]，失败 = ErrorEnvelope（HTTP 状态码见 core/errors.ERROR_HTTP_STATUS）。
"""

from __future__ import annotations

from typing import Generic, TypeVar

from pydantic import BaseModel, ConfigDict, Field

T = TypeVar("T")


class OkEnvelope(BaseModel, Generic[T]):
    """成功响应：`{ "ok": true, "data": { ... } }`。"""

    model_config = ConfigDict(json_schema_extra={"example": {"ok": True}})

    ok: bool = Field(default=True, description="恒为 true（失败响应由 ErrorEnvelope 表达）")
    data: T = Field(description="业务数据")


class ErrorEnvelope(BaseModel):
    """失败响应：`{ "ok": false, "code": "...", "message": "..." }`（错误码表见附录 B §5.2）。"""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {"ok": False, "code": "CREDENTIAL_INVALID", "message": "用户名或口令错误"}
        }
    )

    ok: bool = Field(default=False, description="恒为 false")
    code: str = Field(description="错误码，见附录 B §5.2 错误码表")
    message: str = Field(description="面向用户的中文提示")


__all__ = ["ErrorEnvelope", "OkEnvelope"]
