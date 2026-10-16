"""⑦ 操作日志（`admin_op_log`）—— 本模块是这张表**唯一**的写入点与读取点。

口径
----
* 表结构逐字取自附录 B §3：`action | target_type | target_id | detail | ip | created_at`。
  注释里给的 action 取值（`login | change_price | toggle_shelf | update_config ...`）就是本模块
  使用的枚举，另补三类后台动作：`create_item` / `update_item` / `upload_icon` / `change_password` /
  `bootstrap_admin`（新增取值只在 `admin_web/README.md` 登记，不改服务端切片任何文件）。
* `detail` 是 JSON 文本：**改前 / 改后**。写价格时形如
  `{"price": {"before": 1500, "after": 999}}`，界面据此能答出「谁把什么从多少改成了多少」。
* 口令相关动作**只记"改过"这件事**，绝不写口令、口令哈希或令牌（AGENTS §6）。
* 写入与业务改动在**同一事务**（见 `base.transaction`）：不会出现"改了价但没留痕"。
"""

from __future__ import annotations

import json
import logging
import uuid
from typing import Any

from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

from app.core.security import now_ms
from app.models import AdminOpLog, AdminUser

logger = logging.getLogger("carbonboo.admin.audit")

#: 本切片使用的 action 取值（附录 B §3 注释的三个 + 后台必需的四个）
ACTION_LOGIN = "login"
ACTION_LOGOUT = "logout"
ACTION_CHANGE_PASSWORD = "change_password"
ACTION_BOOTSTRAP_ADMIN = "bootstrap_admin"
ACTION_CREATE_ITEM = "create_item"
ACTION_CHANGE_PRICE = "change_price"
ACTION_TOGGLE_SHELF = "toggle_shelf"
ACTION_UPDATE_ITEM = "update_item"
ACTION_UPLOAD_ICON = "upload_icon"
ACTION_UPDATE_CONFIG = "update_config"

#: 中文动作名（界面展示用；日志表里存的仍是英文枚举，便于以后过滤）
ACTION_LABELS: dict[str, str] = {
    ACTION_LOGIN: "管理员登录",
    ACTION_LOGOUT: "管理员登出",
    ACTION_CHANGE_PASSWORD: "修改密码",
    ACTION_BOOTSTRAP_ADMIN: "初始化管理员",
    ACTION_CREATE_ITEM: "新增商品",
    ACTION_CHANGE_PRICE: "改价",
    ACTION_TOGGLE_SHELF: "上下架",
    ACTION_UPDATE_ITEM: "改商品信息",
    ACTION_UPLOAD_ICON: "上传图标",
    ACTION_UPDATE_CONFIG: "修改系统配置",
}


def write_op_log(
    db: Session,
    *,
    admin_id: str,
    action: str,
    target_type: str | None = None,
    target_id: str | None = None,
    detail: dict[str, Any] | None = None,
    ip: str | None = None,
    created_at: int | None = None,
) -> AdminOpLog:
    """追加一条操作日志（**不 commit**：与业务改动同一事务，见调用方）。"""
    row = AdminOpLog(
        id=str(uuid.uuid4()),
        admin_id=admin_id,
        action=action,
        target_type=target_type,
        target_id=target_id,
        detail=json.dumps(detail, ensure_ascii=False, sort_keys=True) if detail else None,
        ip=ip,
        created_at=created_at or now_ms(),
    )
    db.add(row)
    return row


def _parse_detail(raw: str | None) -> dict[str, Any] | None:
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except (ValueError, TypeError):
        return {"_raw": raw}
    return parsed if isinstance(parsed, dict) else {"_value": parsed}


def list_logs(
    db: Session, *, page: int = 1, page_size: int = 20, action: str | None = None
) -> dict[str, Any]:
    """按时间倒序分页列出日志，并带上操作人用户名（附录 D10-6：操作人 / 动作 / 时间）。

    排序键 `(created_at DESC, id DESC)`：同一毫秒内的多条日志（一次 PATCH 可能产生改价 +
    上下架两条）也有稳定顺序，翻页不会漏行/重行。
    `action` 为可选过滤（页面上的动作筛选），**在 SQL 里过滤**而不是在结果页里过滤 ——
    否则分页的 total 与实际条目对不上。
    """
    total = int(
        db.execute(
            select(func.count()).select_from(AdminOpLog).where(AdminOpLog.action == action)
            if action
            else select(func.count()).select_from(AdminOpLog)
        ).scalar_one()
    )
    statement = (
        select(AdminOpLog, AdminUser.username)
        .outerjoin(AdminUser, AdminUser.id == AdminOpLog.admin_id)
        .order_by(AdminOpLog.created_at.desc(), AdminOpLog.id.desc())
        .limit(page_size)
        .offset((page - 1) * page_size)
    )
    if action:
        statement = statement.where(AdminOpLog.action == action)
    rows = db.execute(statement).all()
    items = [
        {
            "id": row.id,
            "adminId": row.admin_id,
            "adminUsername": username,
            "action": row.action,
            "targetType": row.target_type,
            "targetId": row.target_id,
            "detail": _parse_detail(row.detail),
            "ip": row.ip,
            "createdAt": row.created_at,
        }
        for row, username in rows
    ]
    return {"total": total, "page": page, "pageSize": page_size, "items": items}


def recent_actions(db: Session, *, limit: int = 8) -> list[dict[str, Any]]:
    """总览页用的小快照（最近若干条操作）。"""
    return list_logs(db, page=1, page_size=limit)["items"]


def action_label(action: str) -> str:
    """英文 action → 中文标签（界面用；未知取值原样返回，不吞信息）。"""
    return ACTION_LABELS.get(action, action)


def count_by_action(db: Session) -> dict[str, int]:
    """按动作计数（总览页/自检用）。"""
    rows = db.execute(
        text("SELECT action, COUNT(*) AS n FROM admin_op_log GROUP BY action ORDER BY n DESC")
    ).all()
    return {str(action): int(n) for action, n in rows}


__all__ = [
    "ACTION_BOOTSTRAP_ADMIN",
    "ACTION_CHANGE_PASSWORD",
    "ACTION_CHANGE_PRICE",
    "ACTION_CREATE_ITEM",
    "ACTION_LABELS",
    "ACTION_LOGIN",
    "ACTION_LOGOUT",
    "ACTION_TOGGLE_SHELF",
    "ACTION_UPDATE_CONFIG",
    "ACTION_UPDATE_ITEM",
    "ACTION_UPLOAD_ICON",
    "action_label",
    "count_by_action",
    "list_logs",
    "recent_actions",
    "write_op_log",
]
