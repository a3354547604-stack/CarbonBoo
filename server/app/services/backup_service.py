"""云端备份 / 恢复（S6；附录 B §5.3 标题行「云端备份 / 恢复」+ PLAN §7.8）。

口径（一句话：只存快照、不做自动合并、恢复即覆盖、恢复前生成快照）
------------------------------------------------------------------
1. **只存快照**：`upload()` 把一份全量快照按 `id` 写进云端副本（同 id 覆盖、新 id 插入），
   **不做 LWW 比较、不算冲突、不用 `lastSyncAt`** —— 快照就是快照，不是一次增量合并。
   客户端那条「云端备份」走的是 `/sync/push`（`since = 0`，附录 B §5.3 未定义独立备份端点）；
   本模块给的是**同一份云端副本的显式快照语义**，两者写的是同一批表，不会分叉。
2. **不做自动合并**：上传不会把快照与云端已有行「混合」出第三种状态；冲突（业务唯一键撞车）
   一律计 `ignored` 并写明原因，绝不悄悄改数据。
3. **恢复即覆盖**：`restore()` **只覆盖快照里出现的表**（payload 没提到的表原样不动，避免误清库）：
   - LWW 表（可改可删 7 张）：云端行整体对齐快照 —— 快照里没有的行**移除**，快照里的行原样写入；
   - 只增账本（`point_record` / `carbon_include`）：**只补不删**（铁律 4：流水只增不删），
     缺的行补上，多出来的行保留，也绝不 UPDATE 已有流水。
4. **恢复前生成快照**：覆盖**之前**先把云端原状整份读出来，随响应 `preRestore` 返回，由调用方落盘。
   服务端不新建表存历史快照（21 张表是冻结契约，附录 B §1.2），因此这份「恢复前快照」走响应体，
   而不是偷偷写进某个新表。
5. **事务边界在本层**：恢复是一次事务（覆盖 + sync_log 一起提交），失败整体回滚，绝不留半覆盖状态。
"""

from __future__ import annotations

import logging
from typing import Any, Mapping

from sqlalchemy import select
from sqlalchemy.dialects.mysql import insert as mysql_insert
from sqlalchemy.orm import Session

from app.core.errors import AppError, ErrorCode
from app.core.security import now_ms
from app.models import SYNC_TABLE_NAMES
from app.models.base import Base
from app.services.sync_service import (
    MODE_APPEND_ONLY,
    SYNC_MODES,
    _diagnose_ignored,
    _find_business_key_row,
    normalize_row,
    write_sync_log,
)

logger = logging.getLogger("carbonboo.server.backup")

#: 响应里最多回带多少条逐行说明
MAX_ERRORS = 50


# --------------------------------------------------------------------------- #
# 读：当前云端快照
# --------------------------------------------------------------------------- #
def snapshot(db: Session, *, user_id: str) -> dict[str, Any]:
    """整份云端快照（9 张表全量，含软删除行 —— 软删除也是状态的一部分）。"""
    tables: dict[str, list[dict[str, Any]]] = {}
    total = 0
    latest = 0
    for name in SYNC_TABLE_NAMES:
        table = Base.metadata.tables[name]
        rows = db.execute(select(table).where(table.c.user_id == user_id).order_by(table.c.updated_at, table.c.id)).mappings().all()
        tables[name] = [dict(row) for row in rows]
        total += len(rows)
        for row in rows:
            latest = max(latest, int(row["updated_at"]))
    return {"tables": tables, "totalRows": total, "snapshotAt": latest}


# --------------------------------------------------------------------------- #
# 写：上传快照
# --------------------------------------------------------------------------- #
def upload(
    db: Session,
    *,
    user_id: str,
    device_id: str | None,
    tables: Mapping[str, list[dict[str, Any]]],
) -> dict[str, Any]:
    """把一份全量快照写进云端（只存快照，不做自动合并）。"""
    started_at = now_ms()
    _reject_unknown_tables(tables)
    stored = 0
    ignored = 0
    rejected = 0
    per_table: dict[str, int] = {}
    errors: list[str] = []

    def note(message: str) -> None:
        if len(errors) < MAX_ERRORS:
            errors.append(message)
        else:  # pragma: no cover - 仅畸形快照下命中
            logger.warning("备份逐行说明超过 %d 条：%s", MAX_ERRORS, message)

    for name, rows in tables.items():
        if not isinstance(rows, list):
            raise AppError(ErrorCode.INVALID_REQUEST, f"tables.{name} 必须是行数组")
        table = Base.metadata.tables[name]
        for raw in rows:
            values, error = normalize_row(name, raw, user_id=user_id, device_id=device_id)
            if error:
                rejected += 1
                note(error)
                continue
            existing = db.execute(select(table).where(table.c.id == values["id"]).limit(1)).mappings().first()
            if existing is not None:
                if existing["user_id"] != user_id:
                    rejected += 1
                    note(f"{name}.id={values['id']} 已属于账号 {existing['user_id']}，拒绝覆盖")
                    continue
                # 快照即真相：同 id 直接覆盖（不比较 updated_at —— 这不是合并）
                payload = {key: value for key, value in values.items() if key != "id"}
                db.execute(table.update().where(table.c.id == values["id"], table.c.user_id == user_id).values(**payload))
                stored += 1
                per_table[name] = per_table.get(name, 0) + 1
                continue

            business = _find_business_key_row(db, name, user_id, values)
            if business is not None:
                ignored += 1
                note(f"{name} 业务唯一键 {business[0]} 已在云端，快照里的这一行未写入（不做自动合并）")
                continue
            inserted = db.execute(mysql_insert(table).prefix_with("IGNORE").values(**values)).rowcount or 0
            if inserted:
                stored += 1
                per_table[name] = per_table.get(name, 0) + 1
                continue
            kind, row = _diagnose_ignored(db, name, user_id, values)
            if kind == "foreign":
                rejected += 1
                note(
                    f"{name}.id={values['id']} 被唯一索引拒绝且冲突行属于另一账号"
                    f"（user_id={row['user_id'] if row else '?'}）—— 唯一索引缺少 user_id，见附录 B §2:142"
                )
            else:
                ignored += 1
                note(f"{name}.id={values['id']} 与云端已有行重复，快照里的这一行未写入")

    write_sync_log(
        db,
        user_id=user_id,
        device_id=device_id,
        direction="push",
        status="partial" if rejected else "success",
        pulled_count=0,
        pushed_count=stored,
        conflict_count=0,
        error_msg=errors[0] if rejected else None,
        started_at=started_at,
    )
    db.commit()
    logger.info("云端备份上传 user_id=%s stored=%d ignored=%d rejected=%d", user_id, stored, ignored, rejected)
    return {
        "stored": stored,
        "ignored": ignored,
        "rejected": rejected,
        "snapshotAt": now_ms(),
        "serverTime": now_ms(),
        "tables": per_table,
        "errors": errors,
    }


# --------------------------------------------------------------------------- #
# 写：恢复即覆盖
# --------------------------------------------------------------------------- #
def restore(
    db: Session,
    *,
    user_id: str,
    device_id: str | None,
    tables: Mapping[str, list[dict[str, Any]]],
) -> dict[str, Any]:
    """用快照覆盖云端副本（恢复即覆盖），并在覆盖前生成云端原状快照（preRestore）。"""
    started_at = now_ms()
    _reject_unknown_tables(tables)
    if not tables:
        raise AppError(ErrorCode.INVALID_REQUEST, "恢复必须带 tables（快照内容）；空快照会覆盖成空库")

    # ① 恢复前生成快照（覆盖前先读原状；服务端不新建表，随响应返回给调用方落盘）
    pre = snapshot(db, user_id=user_id)
    pre_restore_at = now_ms()

    restored = 0
    removed = 0
    per_table: dict[str, int] = {}
    errors: list[str] = []

    for name, rows in tables.items():
        if not isinstance(rows, list):
            raise AppError(ErrorCode.INVALID_REQUEST, f"tables.{name} 必须是行数组")
        table = Base.metadata.tables[name]
        mode = SYNC_MODES[name]
        normalized: list[tuple[dict[str, Any], str | None]] = [
            normalize_row(name, raw, user_id=user_id, device_id=device_id) for raw in rows
        ]
        snapshot_ids = {values["id"] for values, error in normalized if not error}

        if mode == MODE_APPEND_ONLY:
            # 铁律 4：账本流水只增不删，恢复只能补缺，不能删也不能改
            for values, error in normalized:
                if error:
                    errors.append(error)
                    continue
                if _find_business_key_row(db, name, user_id, values) is not None:
                    continue
                inserted = db.execute(mysql_insert(table).prefix_with("IGNORE").values(**values)).rowcount or 0
                if inserted:
                    restored += 1
                    per_table[name] = per_table.get(name, 0) + 1
            continue

        # LWW 表：整体对齐快照 —— 快照里没有的行移除
        doomed = db.execute(
            select(table.c.id).where(table.c.user_id == user_id, table.c.id.not_in(snapshot_ids or {""}))
        ).scalars().all()
        if doomed:
            db.execute(table.delete().where(table.c.user_id == user_id, table.c.id.in_(list(doomed))))
            removed += len(doomed)

        for values, error in normalized:
            if error:
                errors.append(error)
                continue
            # 覆盖：同 id 先删后插（保证与快照逐列一致，不保留任何云端残留字段）
            db.execute(table.delete().where(table.c.id == values["id"], table.c.user_id == user_id))
            inserted = db.execute(mysql_insert(table).prefix_with("IGNORE").values(**values)).rowcount or 0
            if inserted:
                restored += 1
                per_table[name] = per_table.get(name, 0) + 1
                continue
            kind, row = _diagnose_ignored(db, name, user_id, values)
            errors.append(
                f"{name}.id={values['id']} 恢复时被唯一索引拒绝（{kind}"
                + (f"，冲突行 user_id={row['user_id']}" if row else "")
                + "）"
            )

    write_sync_log(
        db,
        user_id=user_id,
        device_id=device_id,
        direction="both",
        status="partial" if errors else "success",
        pulled_count=0,
        pushed_count=restored,
        conflict_count=0,
        error_msg=errors[0] if errors else None,
        started_at=started_at,
    )
    db.commit()
    logger.info("云端恢复 user_id=%s restored=%d removed=%d", user_id, restored, removed)
    return {
        "restored": restored,
        "removed": removed,
        "preRestoreAt": pre_restore_at,
        "preRestore": pre["tables"],
        "serverTime": now_ms(),
        "tables": per_table,
    }


def _reject_unknown_tables(tables: Mapping[str, list[dict[str, Any]]]) -> None:
    """只接受参与同步的 9 张表：未知表名整批 400（不静默丢掉一份快照）。"""
    unknown = sorted(name for name in tables if name not in SYNC_MODES)
    if unknown:
        raise AppError(
            ErrorCode.INVALID_REQUEST,
            f"未知的表：{unknown}；云端备份只覆盖参与同步的 9 张表 {list(SYNC_TABLE_NAMES)}（附录 B §6.5）",
        )


__all__ = ["MAX_ERRORS", "restore", "snapshot", "upload"]
