"""API v1 路由聚合 + 健康检查。

`/api/v1/health` 用于部署探活（不含业务，属本切片自检用）；账号接口在 `app/api/v1/auth.py`。
t5 会在此追加 sync / shop / backup 路由（本切片**不**创建那些文件）。
"""

from __future__ import annotations

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.api.v1 import auth
from app.core.config import get_settings
from app.core.security import now_ms

router = APIRouter()


class HealthData(BaseModel):
    """健康检查响应（**不带 data 包装**，逐字对齐附录 B §5.1 的响应示例）。

    口径来源：`docs/APPENDIX-B-data-and-api.md` §5.1
        `GET /api/v1/health` → `{ "ok": true, "version": "1.0.0", "time": 1762300000000 }`
    注意与 §5.2 的区别：§5.2 的业务响应统一是 `{ ok, data }`，health 是扁平结构。
    `version` = 服务端 API 版本号（`APP_VERSION`，默认 1.0.0），不是资料版本号 CF-xxxx.x。
    """

    ok: bool = Field(default=True, description="探活成功恒为 true")
    version: str = Field(description="服务端 API 版本号（APP_VERSION，附录 B §5.1 示例为 1.0.0）")
    time: int = Field(description="服务端当前时间（毫秒）")


@router.get(
    "/health",
    summary="健康检查",
    tags=["系统"],
    response_model=HealthData,
)
def health() -> HealthData:
    """探活：进程活着即 200（不探测数据库，避免探活把 DB 打满）。"""
    return HealthData(ok=True, version=get_settings().app_version, time=now_ms())


# 账号接口（AGENTS §4 · S6 第一段）
router.include_router(auth.router, prefix="/auth", tags=["账号"])

__all__ = ["HealthData", "router"]
