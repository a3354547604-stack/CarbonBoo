"""③ 用户列表 / ④ 数据总览 / ⑤ 订单记录（全部只读聚合）。

口径来源
--------
* PLAN §13.2 ③④⑤：用户列表 = 设备/账号标识、首次接入时间、最后同步时间、记录数；
  数据总览 = 接入设备数、总记录数、今日新增、总减排量、总积分发放；订单记录 = 谁在什么时间买了什么、花了多少分。
* 附录 B §3 注：后台"设备列表"口径 = **该用户已同步行按 `device_id` 去重 + 各自最后一次同步时间**。
  `server_user` 不存 `device_id`（B35/B40 契约），所以设备维度只能从业务行聚合出来。
* "参与同步的表"集合直接取 `app.models.SYNC_TABLE_NAMES`（9 张）——**不在这里抄一份表名**，
  否则客户端"待同步数"口径（D6-6）与后台口径会分叉。

全部是只读查询（`SELECT`），不写库、不开事务：
后台的总览是**基于"已上行到服务端的数据"**的统计，客户端本机数据以本机为准（铁律 1）。
聚合一律交给 SQL `SUM/COUNT`（AGENTS §3：禁止用浮点累加求总量）。
"""

from __future__ import annotations

import logging
from typing import Any

from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

from app.models import SYNC_TABLE_NAMES, ServerUser, ShopItem, UserPurchase
from app.services import shop_service

from admin_web.services.base import today_start_ms

logger = logging.getLogger("carbonboo.admin.stats")

#: 参与同步的 9 张表的公共列（每张表都有这四列 + is_deleted，见附录 B §1.2）
_SYNC_COLUMNS = "user_id, device_id, created_at, updated_at"

#: 9 张同步表按用户/设备的联合视图（SQL 里拼表名，表名来自常量元组，不含任何外部输入）
_SYNC_UNION = " UNION ALL ".join(
    f"SELECT {_SYNC_COLUMNS} FROM `{name}` WHERE is_deleted = 0" for name in SYNC_TABLE_NAMES
)
_DEVICE_UNION = " UNION ALL ".join(
    f"SELECT {_SYNC_COLUMNS} FROM `{name}` WHERE is_deleted = 0 AND device_id IS NOT NULL"
    for name in SYNC_TABLE_NAMES
)

#: 四大类行为（APPENDIX-C §3.1 的 cat_*），总览页按此给出减排量拆分
CATEGORY_LABELS: dict[str, str] = {
    "travel": "绿色出行",
    "utility": "节水节电",
    "recycle": "旧物回收",
    "plate": "光盘行动",
}


def _scalar_int(db: Session, sql: str) -> int:
    value = db.execute(text(sql)).scalar()
    return int(value or 0)


def _scalar_float(db: Session, sql: str) -> float:
    value = db.execute(text(sql)).scalar()
    return float(value or 0)


def overview(db: Session) -> dict[str, Any]:
    """数据总览（PLAN §13.2 ④）。"""
    today = today_start_ms()

    account_count = _scalar_int(db, "SELECT COUNT(*) FROM server_user")
    active_account_count = _scalar_int(db, "SELECT COUNT(*) FROM server_user WHERE is_active = 1")
    device_count = _scalar_int(db, f"SELECT COUNT(DISTINCT device_id) FROM ({_DEVICE_UNION}) AS s")
    record_count = _scalar_int(db, "SELECT COUNT(*) FROM carbon_record WHERE is_deleted = 0")
    today_record_count = _scalar_int(
        db, f"SELECT COUNT(*) FROM carbon_record WHERE is_deleted = 0 AND created_at >= {int(today)}"
    )
    total_reduction = _scalar_float(
        db, "SELECT COALESCE(SUM(reduction_kg), 0) FROM carbon_record WHERE is_deleted = 0"
    )

    by_category = {
        str(category): round(float(total or 0), 4)
        for category, total in db.execute(
            text(
                "SELECT category, COALESCE(SUM(reduction_kg), 0) AS total FROM carbon_record "
                "WHERE is_deleted = 0 GROUP BY category ORDER BY category"
            )
        ).all()
    }

    # 收入 = 正流水（记录分 + 目标奖励）；支出 = 负流水绝对值（碳小铺 + 碳普惠）。
    # 口径同铁律 4：余额 = 收入合计 − 支出合计（服务端只反映已上行的流水）。
    total_issued = _scalar_int(db, "SELECT COALESCE(SUM(points), 0) FROM point_record WHERE is_deleted = 0 AND points > 0")
    total_spent = _scalar_int(
        db, "SELECT COALESCE(-SUM(points), 0) FROM point_record WHERE is_deleted = 0 AND points < 0"
    )
    order_count = _scalar_int(db, "SELECT COUNT(*) FROM user_purchase WHERE is_deleted = 0")
    item_count = _scalar_int(db, "SELECT COUNT(*) FROM shop_item")
    on_shelf_count = _scalar_int(db, "SELECT COUNT(*) FROM shop_item WHERE on_shelf = 1")
    last_sync_at = db.execute(text(f"SELECT MAX(updated_at) FROM ({_SYNC_UNION}) AS s")).scalar()

    return {
        "accountCount": account_count,
        "activeAccountCount": active_account_count,
        "deviceCount": device_count,
        "recordCount": record_count,
        "todayRecordCount": today_record_count,
        "totalReductionKg": round(total_reduction, 4),
        "reductionByCategory": by_category,
        "totalPointsIssued": total_issued,
        "totalPointsSpent": total_spent,
        "totalPointsBalance": total_issued - total_spent,
        "orderCount": order_count,
        "itemCount": item_count,
        "onShelfItemCount": on_shelf_count,
        "shopVersion": shop_service.current_version(db),
        "lastSyncAt": int(last_sync_at) if last_sync_at is not None else None,
    }


def _sync_aggregates(db: Session) -> tuple[dict[str, dict[str, Any]], dict[str, list[dict[str, Any]]]]:
    """返回 `(按用户聚合, 按用户+设备聚合)`。"""
    per_user: dict[str, dict[str, Any]] = {}
    for user_id, first_seen, last_sync, row_count in db.execute(
        text(
            f"SELECT user_id, MIN(created_at) AS first_seen, MAX(updated_at) AS last_sync, COUNT(*) AS `rows` "
            f"FROM ({_SYNC_UNION}) AS s GROUP BY user_id"
        )
    ).all():
        per_user[str(user_id)] = {
            "firstSeenAt": int(first_seen) if first_seen is not None else None,
            "lastSyncAt": int(last_sync) if last_sync is not None else None,
            "rowCount": int(row_count or 0),
        }

    per_device: dict[str, list[dict[str, Any]]] = {}
    for user_id, device_id, last_sync, row_count in db.execute(
        text(
            f"SELECT user_id, device_id, MAX(updated_at) AS last_sync, COUNT(*) AS `rows` "
            f"FROM ({_DEVICE_UNION}) AS s GROUP BY user_id, device_id ORDER BY last_sync DESC"
        )
    ).all():
        per_device.setdefault(str(user_id), []).append(
            {
                "deviceId": str(device_id),
                "lastSyncAt": int(last_sync) if last_sync is not None else 0,
                "rowCount": int(row_count or 0),
            }
        )
    return per_user, per_device


def users(db: Session, *, page: int = 1, page_size: int = 20) -> dict[str, Any]:
    """用户 / 设备列表（PLAN §13.2 ③，附录 B §3 注的设备口径）。

    合并两个来源：`server_user`（账号）与业务表里出现过的 `user_id`（理论上应一一对应，
    但保留并集，避免"账号行没了、数据还在"时后台看不见数据）。排序：账号创建时间倒序。

    分页参数由 **HTTP 边界**（api.py / pages.py，那里才有 `AdminWebSettings`）用
    `base.normalize_paging` 夹紧后传入；本函数只负责切片。
    """
    per_user, per_device = _sync_aggregates(db)

    record_counts: dict[str, int] = {
        str(user_id): int(count or 0)
        for user_id, count in db.execute(
            text("SELECT user_id, COUNT(*) FROM carbon_record WHERE is_deleted = 0 GROUP BY user_id")
        ).all()
    }

    merged: dict[str, dict[str, Any]] = {}
    for account in db.execute(select(ServerUser)).scalars().all():
        merged[account.user_id] = {
            "userId": account.user_id,
            "username": account.username,
            "isActive": int(account.is_active),
            "accountCreatedAt": int(account.created_at),
            "lastLoginAt": int(account.last_login_at) if account.last_login_at is not None else None,
        }
    for user_id in per_user:
        merged.setdefault(
            user_id,
            {
                "userId": user_id,
                "username": f"（无账号）{user_id[:8]}",
                "isActive": 0,
                "accountCreatedAt": None,
                "lastLoginAt": None,
            },
        )

    rows: list[dict[str, Any]] = []
    for user_id, base in merged.items():
        aggregate = per_user.get(user_id, {})
        devices = per_device.get(user_id, [])
        rows.append(
            {
                **base,
                "firstSeenAt": aggregate.get("firstSeenAt"),
                "lastSyncAt": aggregate.get("lastSyncAt"),
                "recordCount": record_counts.get(user_id, 0),
                "rowCount": aggregate.get("rowCount", 0),
                "deviceCount": len(devices),
                "devices": devices,
            }
        )

    rows.sort(key=lambda row: (-(row["accountCreatedAt"] or 0), row["userId"]))
    total = len(rows)
    start = (page - 1) * page_size
    return {"total": total, "page": page, "pageSize": page_size, "items": rows[start : start + page_size]}


def orders(db: Session, *, page: int = 1, page_size: int = 20) -> dict[str, Any]:
    """订单记录（PLAN §13.2 ⑤）：谁、什么时候、买了什么、花了多少分。

    `price_paid` 是**下单时的成交价**（不随后台改价变化）；`itemName` 取商品现值，
    商品行被删时为 null（订单本身不删——它是对账依据）。
    """
    total = int(
        db.execute(select(func.count()).select_from(UserPurchase).where(UserPurchase.is_deleted == 0)).scalar_one()
    )
    rows = (
        db.execute(
            select(UserPurchase, ServerUser.username, ShopItem.name)
            .outerjoin(ServerUser, ServerUser.user_id == UserPurchase.user_id)
            .outerjoin(ShopItem, ShopItem.id == UserPurchase.item_id)
            .where(UserPurchase.is_deleted == 0)
            .order_by(UserPurchase.purchased_at.desc(), UserPurchase.id.desc())
            .limit(page_size)
            .offset((page - 1) * page_size)
        )
        .all()
    )
    items = [
        {
            "id": purchase.id,
            "userId": purchase.user_id,
            "username": username,
            "itemId": purchase.item_id,
            "itemName": item_name,
            "pricePaid": int(purchase.price_paid),
            "purchasedAt": int(purchase.purchased_at),
        }
        for purchase, username, item_name in rows
    ]
    return {"total": total, "page": page, "pageSize": page_size, "items": items}


def item_counts_by_section(db: Session) -> dict[str, int]:
    """按分区统计商品数（后台商品页的顶部小计）。"""
    rows = db.execute(
        text("SELECT section, COUNT(*) AS n FROM shop_item GROUP BY section ORDER BY section")
    ).all()
    return {str(section): int(count or 0) for section, count in rows}


def record_counts_by_category(db: Session) -> dict[str, int]:
    """按四大类统计记录数（总览页条形图的分母）。"""
    rows = db.execute(
        text(
            "SELECT category, COUNT(*) AS n FROM carbon_record WHERE is_deleted = 0 "
            "GROUP BY category ORDER BY n DESC"
        )
    ).all()
    return {str(category): int(count or 0) for category, count in rows}


__all__ = [
    "CATEGORY_LABELS",
    "item_counts_by_section",
    "orders",
    "overview",
    "record_counts_by_category",
    "users",
]
