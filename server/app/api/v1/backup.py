"""云端备份 / 恢复接口（附录 B §5.3 标题行 + PLAN §7.8；ADR-0001 例外集第 4 项）。

    POST /api/v1/sync/backup           上传全量快照（只存快照，不做自动合并）
    GET  /api/v1/sync/backup           下载云端快照（恢复即覆盖的数据源）
    POST /api/v1/sync/backup/restore   用快照覆盖云端副本（恢复前先返回原状快照）

口径
----
* 附录 B §5.3 只列了 `pull` / `push` / `status` 三行端点，云端备份被写成「全量快照上传 / 下载覆盖」，
  因此客户端 t4 用 `POST /sync/push`（`since = 0`）+ `GET /sync/pull?since=0` 实现备份/恢复
  （`SyncService.fullUpload/fullRestore`）。本组端点是**同一份云端副本**的显式快照语义，
  与那条路径写的是同一批表，不会分叉；差别只在**不做 LWW 合并**：
  「只存快照、不做自动合并、恢复即覆盖、恢复前生成快照」（验收口径 / PLAN §7.8）。
* 未登录不调用本组接口（铁律 1：例外集里只有「云端备份」这一类，且必须登录）。
* 端点行本身在附录 B §5.3 缺行 —— 已列入本任务报告的「附录 B 需同步修正的行号清单」，
  待文档补齐后本模块不必改动（请求/响应体与 §5.3 的 push/pull 同形）。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.errors import AppError, ErrorCode
from app.core.security import bearer_token, now_ms
from app.schemas.common import ErrorEnvelope, OkEnvelope
from app.schemas.sync import BackupDownloadData, BackupRestoreData, BackupUploadData, SnapshotRequest
from app.services import backup_service
from app.services.auth_provider import AuthProvider, get_auth_provider

router = APIRouter()

_ERROR_RESPONSES: dict[int | str, dict[str, object]] = {
    400: {"model": ErrorEnvelope, "description": "请求体不合法（INVALID_REQUEST）：未知表 / tables 不是行数组 / 空快照"},
    401: {"model": ErrorEnvelope, "description": "令牌缺失/非法/过期，或账号已注销（TOKEN_INVALID / TOKEN_EXPIRED）"},
    403: {"model": ErrorEnvelope, "description": "请求体 userId 与令牌账号不一致（FORBIDDEN）"},
}


def _user_id(provider: AuthProvider, token: str, payload_user_id: str | None) -> str:
    session = provider.current_session(token)
    if payload_user_id is not None and payload_user_id != session.user_id:
        raise AppError(ErrorCode.FORBIDDEN, "请求体 userId 与令牌账号不一致；备份只允许操作本账号的云数据")
    return session.user_id


@router.post(
    "/backup",
    summary="上传云端备份快照",
    description=(
        "把一份全量快照写进云端副本：同 id 覆盖、新 id 插入，**不做 LWW 比较、不算冲突、不用 lastSyncAt**。"
        "业务唯一键撞车计 `ignored` 并写明原因（不做自动合并）。"
    ),
    response_model=OkEnvelope[BackupUploadData],
    responses=_ERROR_RESPONSES,
)
def create_backup(
    payload: SnapshotRequest,
    token: Annotated[str, Depends(bearer_token)],
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
    db: Annotated[Session, Depends(get_db)],
) -> OkEnvelope[BackupUploadData]:
    user_id = _user_id(provider, token, payload.userId)
    data = backup_service.upload(db, user_id=user_id, device_id=payload.deviceId, tables=payload.tables)
    return OkEnvelope[BackupUploadData](data=BackupUploadData(**data))


@router.get(
    "/backup",
    summary="下载云端备份快照",
    description="整份返回本账号 9 张参与同步表的云端行（含软删除行）+ 快照时间；客户端据此「恢复即覆盖」本机。",
    response_model=OkEnvelope[BackupDownloadData],
    responses=_ERROR_RESPONSES,
)
def download_backup(
    token: Annotated[str, Depends(bearer_token)],
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
    db: Annotated[Session, Depends(get_db)],
) -> OkEnvelope[BackupDownloadData]:
    session = provider.current_session(token)
    data = backup_service.snapshot(db, user_id=session.user_id)
    return OkEnvelope[BackupDownloadData](
        data=BackupDownloadData(
            serverTime=now_ms(),
            snapshotAt=data["snapshotAt"],
            totalRows=data["totalRows"],
            tables=data["tables"],
        )
    )


@router.post(
    "/backup/restore",
    summary="用快照覆盖云端副本",
    description=(
        "恢复即覆盖：payload 里出现的表整体对齐快照（LWW 表按快照删/写；只增账本 `point_record` / "
        "`carbon_include` **只补不删**，铁律 4）。覆盖前先把云端原状整份读出，随响应 `preRestore` 返回，"
        "由调用方落盘保存（恢复前生成快照）。"
    ),
    response_model=OkEnvelope[BackupRestoreData],
    responses=_ERROR_RESPONSES,
)
def restore_backup(
    payload: SnapshotRequest,
    token: Annotated[str, Depends(bearer_token)],
    provider: Annotated[AuthProvider, Depends(get_auth_provider)],
    db: Annotated[Session, Depends(get_db)],
) -> OkEnvelope[BackupRestoreData]:
    user_id = _user_id(provider, token, payload.userId)
    data = backup_service.restore(db, user_id=user_id, device_id=payload.deviceId, tables=payload.tables)
    return OkEnvelope[BackupRestoreData](data=BackupRestoreData(**data))


__all__ = ["router"]
