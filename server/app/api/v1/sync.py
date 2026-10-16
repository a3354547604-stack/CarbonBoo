"""同步接口（逐条对齐 docs/APPENDIX-B-data-and-api.md §5.3，经 ADR-0001 口径改写）。

    POST /api/v1/sync/push     推送增量（服务端按 §6 的 LWW 合并，返回需回写的行）
    GET  /api/v1/sync/pull     拉取增量（`updated_at > since`，含软删除行）
    GET  /api/v1/sync/status   云端统计（各表条数、最后时间、最近一次同步日志）

口径
----
* **服务端同步是必做主通路**（ADR-0001）：跨设备一致性只由本组接口承担；
  鸿蒙分布式协同是近场演示层（附录 B §6.6），服务端不实现、也不影响这里的任何行为。
* **未登录不调用本组接口**：三个端点都要客户端令牌（`Authorization: Bearer <userToken>`），
  身份一律取自**令牌**（`provider.current_session`），请求体里的 `userId` 只用于**对账**：
  与令牌账号不一致直接 403，绝不允许把别的账号的行写进本账号。
* 注销后的账号 `current_session` 会 401（`is_active = 0`），因此保留期内**旧令牌不能同步**，
  用同一用户名 + 相同口令重新登录（恢复）后才继续（ADR-0001 决策 ③）。
* 本模块**只依赖 `AuthProvider` 抽象**（源码级可由 tests/test_authz.py 的扫描断言），
  不 import 任何具体 provider。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.errors import AppError, ErrorCode
from app.core.security import bearer_token, now_ms
from app.schemas.common import ErrorEnvelope, OkEnvelope
from app.schemas.sync import SyncPullData, SyncPushData, SyncPushRequest, SyncStatusData
from app.services import sync_service
from app.services.auth_provider import AuthProvider, get_auth_provider

router = APIRouter()

_ERROR_RESPONSES: dict[int | str, dict[str, object]] = {
    400: {"model": ErrorEnvelope, "description": "请求体不合法（INVALID_REQUEST）：未知同步表 / tables 不是行数组"},
    401: {"model": ErrorEnvelope, "description": "令牌缺失/非法/过期，或账号已注销（TOKEN_INVALID / TOKEN_EXPIRED）"},
    403: {"model": ErrorEnvelope, "description": "请求体 userId 或行内 user_id 与令牌账号不一致（FORBIDDEN）"},
}


def _session(provider: AuthProvider, token: str):
    """令牌 → 会话（账号不存在 / 已注销 / 令牌失效都会在这里变成 401）。"""
    return provider.current_session(token)


@router.post(
    "/push",
    summary="推送增量（LWW 合并）",
    description=(
        "把本机 `updated_at > lastSyncAt` 的行推给服务端，服务端按附录 B §6.3 合并：\n"
        "· 只增账本（point_record / carbon_include）→ 同 id 或业务唯一键已存在即跳过，永不 UPDATE；\n"
        "· 其余 7 张表 → 完整 LWW（updated_at 大者胜；平局比 deviceId 字典序）；\n"
        "· 真冲突 = 两端自上次同步后都改过这一行；跨设备重复被去重计入 ignored（= skipped）；\n"
        "· `merged` 回带「服务端版本更胜」的行，客户端回写后两端收敛。\n"
        "时钟：可选 `clientNow`，offsetMs = 服务端时钟 − 客户端时钟，容差 ±5 分钟，超容差仍继续（写 sync_log.error_msg）。"
    ),
    response_model=OkEnvelope[SyncPushData],
    responses=_ERROR_RESPONSES,
)
def push(
    payload: SyncPushRequest,
    token: Annotated[str, Depends(bearer_token)],
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
    db: Annotated[Session, Depends(get_db)],
) -> OkEnvelope[SyncPushData]:
    session = _session(provider, token)
    if payload.userId is not None and payload.userId != session.user_id:
        raise AppError(
            ErrorCode.FORBIDDEN,
            "请求体 userId 与令牌账号不一致；同步只允许操作本账号的云数据（ADR-0001：可见范围由服务端鉴权决定）",
        )
    outcome = sync_service.push(
        db,
        user_id=session.user_id,
        device_id=payload.deviceId,
        last_sync_at=payload.lastSyncAt,
        tables=payload.tables,
        client_now=payload.clientNow,
    )
    return OkEnvelope[SyncPushData](
        data=SyncPushData(
            accepted=outcome.accepted,
            skipped=outcome.skipped,
            ignored=outcome.ignored,
            rejected=outcome.rejected,
            conflicts=outcome.conflicts,
            serverTime=now_ms(),
            offsetMs=outcome.offset_ms,
            clockWarning=outcome.clock_warning,
            acceptedByTable=outcome.accepted_by_table,
            merged=outcome.merged,
            errors=outcome.errors,
        )
    )


@router.get(
    "/pull",
    summary="拉取增量",
    description=(
        "返回本账号 9 张参与同步表里 `updated_at > since` 的行（含 `is_deleted = 1` 的软删除行 —— "
        "删除靠 LWW + 软删除标记传播，附录 B §1.3-4 / §6.4-2）。客户端按同一套 LWW 写回本机。"
    ),
    response_model=OkEnvelope[SyncPullData],
    responses=_ERROR_RESPONSES,
)
def pull(
    token: Annotated[str, Depends(bearer_token)],
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
    db: Annotated[Session, Depends(get_db)],
    since: Annotated[int, Query(ge=0, description="增量起点（毫秒）；0 = 全量（云端恢复/备份用）")] = 0,
) -> OkEnvelope[SyncPullData]:
    session = _session(provider, token)
    data = sync_service.pull(db, user_id=session.user_id, since=since)
    return OkEnvelope[SyncPullData](data=SyncPullData(**data))


@router.get(
    "/status",
    summary="云端统计",
    description=(
        "云端各表条数 / 软删除数 / 最后更新时间、出现过的 device_id（家庭合并视图用）、"
        "以及最近一次同步日志（状态、条数、冲突数、error_msg）。\n"
        "注意「待同步数」不在本接口：`sync_state` 是**仅客户端**的列（附录 B §1.3），"
        "pending 行数由客户端按 9 张表自己统计（附录 C §18.1 / 验收 D6-6）。"
    ),
    response_model=OkEnvelope[SyncStatusData],
    responses=_ERROR_RESPONSES,
)
def status(
    token: Annotated[str, Depends(bearer_token)],
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
    db: Annotated[Session, Depends(get_db)],
) -> OkEnvelope[SyncStatusData]:
    session = _session(provider, token)
    data = sync_service.status(db, user_id=session.user_id)
    return OkEnvelope[SyncStatusData](data=SyncStatusData(**data))


__all__ = ["router"]
