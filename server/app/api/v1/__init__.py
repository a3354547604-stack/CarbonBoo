"""API v1 路由聚合 + 健康检查。

    GET  /api/v1/health               存活检查（§5.1，扁平响应）
    POST /api/v1/auth/*               账号：register / login / me / logout / account（§5.2）
    POST /api/v1/sync/push            推送增量（LWW 合并，§5.3）
    GET  /api/v1/sync/pull            拉取增量（§5.3）
    GET  /api/v1/sync/status          云端统计（§5.3）
    POST /api/v1/sync/backup          上传云端备份快照（§5.3 的「云端备份 / 恢复」；不做自动合并）
    GET  /api/v1/sync/backup          下载云端快照（恢复即覆盖的数据源）
    POST /api/v1/sync/backup/restore  用快照覆盖云端副本（恢复前先生成快照）
    GET  /api/v1/shop/items           商品目录与价格（§5.4，**无需 token**）

`/admin/*` 的 Web 后台管理端**不在这里**：它是可选件，由 t6 在 `server/admin_web/` 实现，
经 `app/main.py` 的 `_mount_optional_admin` 挂载（ADR-0001）。
"""

from __future__ import annotations

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.api.v1 import auth, backup, shop, sync
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

# 多设备同步（S6 主通路，ADR-0001）：跨设备一致性只由这组接口承担
router.include_router(sync.router, prefix="/sync", tags=["同步"])

# 云端备份 / 恢复（同一份云端副本的快照语义：只存快照、不做自动合并、恢复即覆盖）
router.include_router(backup.router, prefix="/sync", tags=["云端备份"])

# 商品取价（唯一无需令牌的接口；失败时客户端整份丢弃 → 内置默认价）
router.include_router(shop.router, prefix="/shop", tags=["碳小铺"])

__all__ = ["HealthData", "router"]
