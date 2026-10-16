"""② 商品管理（`shop_item` + `app_config['shop_items_version']`）。

口径（PLAN §13.2 ②/§13.3、附录 B §5.4、PLAN §11.1）
----------------------------------------------------
* **读**一律复用服务端的取价服务（`app.services.shop_service`）：后台看到的价目表与客户端
  `GET /api/v1/shop/items` 拿到的是**同一个函数**产出的同一个结构。这里绝不另写一份查询，
  否则"后台显示的价格"与"客户端拿到的价格"会分叉——那正是本任务要证明的那条链路。
* **写**（本模块持有）：
  1. 改 `shop_item` 行（新增 / 改价 / 改描述 / 排序 / 上下架 / 换图标）；
  2. **bump 版本号** `app_config['shop_items_version']` —— 客户端按版本号判断是否需要整份覆盖
     （附录 B §5.4「后台改价**下次启动生效**」）。版本号形如 `YYYY.MM.DD-N`（同日递增 N），
     与种子值 `2026.02.01-1` 同构。
  3. 每次改动写 `admin_op_log`（**一条动作一行**：改价 → `change_price`，上下架 → `toggle_shelf`，
     其余字段 → `update_item`），`detail` 里带改前 / 改后。
* 客户端无权改价：改价能力只在本模块（AGENTS §6 / PLAN §13.1）。
"""

from __future__ import annotations

import re
import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.errors import AppError, ErrorCode
from app.core.security import now_ms
from app.models import AppConfig, ShopItem
from app.services import shop_service

from admin_web.schemas import AdminItemUpdate, ShopItemCreate
from admin_web.services import audit
from admin_web.services.base import transaction

#: 商品分区（PLAN §11.1：头像框 frame / 主题 theme；头像不占商品位）
ALLOWED_SECTIONS: tuple[str, ...] = ("frame", "theme")

#: 商品编码格式（内置商品全是 `frame_01` / `theme_default` 这种小写下划线）
ITEM_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_]{1,35}$")

#: 目录版本号形状：`2026.02.01-1`（附录 B §5.4 响应示例的种子值）
VERSION_RE = re.compile(r"^(\d{4}\.\d{2}\.\d{2})-(\d+)$")

#: 参与"改前/改后"对比的列（icon 也在这里：上传图标同时改 icon 列）
TRACKED_FIELDS: tuple[str, ...] = ("name", "description", "price", "order", "onShelf", "isDefaultFree", "icon")


def list_items(db: Session) -> list[dict[str, Any]]:
    """全部商品（含已下架），**复用取价服务的同一实现**。"""
    return shop_service.list_items(db)


def catalog(db: Session) -> dict[str, Any]:
    """`{version, items}` —— 与客户端 `GET /api/v1/shop/items` 的 data 完全同构（附录 B §5.4）。"""
    return shop_service.catalog(db)


def current_version(db: Session) -> str:
    return shop_service.current_version(db)


def next_version(current: str, *, now: datetime | None = None) -> str:
    """下一个目录版本号：`2026.02.01-1` → 同日 `2026.02.01-2`；换日 → `<今日>-1`。"""
    today = (now or datetime.now().astimezone()).strftime("%Y.%m.%d")
    match = VERSION_RE.match((current or "").strip())
    if match and match.group(1) == today:
        return f"{today}-{int(match.group(2)) + 1}"
    return f"{today}-1"


def bump_version(db: Session) -> str:
    """把 `app_config['shop_items_version']` 提到新版本（不 commit，随业务事务一起提交）。"""
    row = db.execute(select(AppConfig).where(AppConfig.id == shop_service.SHOP_VERSION_KEY)).scalar_one_or_none()
    new_version = next_version(row.value or row.version if row else "")
    stamp = now_ms()
    if row is None:
        row = AppConfig(
            id=shop_service.SHOP_VERSION_KEY,
            value=new_version,
            version=new_version,
            fetched_at=None,
            created_at=stamp,
            updated_at=stamp,
        )
        db.add(row)
    else:
        row.value = new_version
        row.version = new_version
        row.updated_at = stamp
    return new_version


def get_item(db: Session, item_id: str) -> ShopItem:
    """按 id 取商品；不存在 → 404 `NOT_FOUND`（附录 B §5.2 错误码表）。"""
    row = db.execute(select(ShopItem).where(ShopItem.id == item_id)).scalar_one_or_none()
    if row is None:
        raise AppError(ErrorCode.NOT_FOUND, f"商品不存在：{item_id}")
    return row


def _validate_item_id(item_id: str) -> str:
    if not ITEM_ID_RE.match(item_id or ""):
        raise AppError(
            ErrorCode.INVALID_REQUEST,
            "商品编码只能是小写字母/数字/下划线，2–36 位（如 frame_09、theme_summer）",
        )
    return item_id


def _validate_section(section: str) -> str:
    if section not in ALLOWED_SECTIONS:
        raise AppError(ErrorCode.INVALID_REQUEST, f"商品分区只能是 {' | '.join(ALLOWED_SECTIONS)}")
    return section


def _snapshot(row: ShopItem) -> dict[str, Any]:
    return {field: getattr(row, _column(field)) for field in TRACKED_FIELDS}


def _column(field: str) -> str:
    """请求字段 → 列名（只有 `onShelf` / `isDefaultFree` 与列名不同）。"""
    return {"onShelf": "on_shelf", "isDefaultFree": "is_default_free"}.get(field, field)


def _as_dict(row: ShopItem) -> dict[str, Any]:
    """一行 → 附录 B §5.4 的 items[] 元素（字段名与客户端取价完全一致）。"""
    return {
        "id": row.id,
        "section": row.section,
        "name": row.name,
        "description": row.description,
        "price": row.price,
        "icon": row.icon,
        "order": row.order,
        "onShelf": row.on_shelf,
        "isDefaultFree": row.is_default_free,
    }


def create_item(db: Session, payload: ShopItemCreate, *, admin_id: str, ip: str | None = None) -> dict[str, Any]:
    """新增商品（附录 B §5.4 `POST /admin/items`）。

    编码重复 → 400 `INVALID_REQUEST`（附录 B §5.2 的错误码表里没有通用冲突码，
    这里不新造码；HTTP 语义上是冲突，但**码表是契约**，以码表为准）。
    """
    _validate_item_id(payload.id)
    _validate_section(payload.section)

    with transaction(db):
        if db.execute(select(ShopItem).where(ShopItem.id == payload.id)).scalar_one_or_none() is not None:
            raise AppError(ErrorCode.INVALID_REQUEST, f"商品编码已存在：{payload.id}")
        stamp = now_ms()
        row = ShopItem(
            id=payload.id,
            section=payload.section,
            name=payload.name,
            description=payload.description,
            price=payload.price,
            icon=payload.icon or f"res://{payload.id}",
            order=payload.order,
            on_shelf=payload.onShelf,
            is_default_free=payload.isDefaultFree,
            created_at=stamp,
            updated_at=stamp,
        )
        db.add(row)
        db.flush()
        version = bump_version(db)
        audit.write_op_log(
            db,
            admin_id=admin_id,
            action=audit.ACTION_CREATE_ITEM,
            target_type="item",
            target_id=row.id,
            detail={"after": _snapshot(row), "shopVersion": version},
            ip=ip,
        )
        snapshot = _as_dict(row)
    return snapshot


def update_item(
    db: Session,
    item_id: str,
    payload: AdminItemUpdate,
    *,
    admin_id: str,
    ip: str | None = None,
) -> dict[str, Any]:
    """PATCH 商品（附录 B §5.4：改价 / 改描述 / 排序 / 上下架）。

    PATCH 语义：只处理 `exclude_unset` 传了的字段；空改动是**幂等成功**（不 bump 版本、不写日志）。
    """
    patch_raw = payload.model_dump(exclude_unset=True)
    if not patch_raw:
        return _as_dict(get_item(db, item_id))

    with transaction(db):
        row = get_item(db, item_id)
        before = _snapshot(row)
        changes: dict[str, dict[str, Any]] = {}
        for field, value in patch_raw.items():
            column = _column(field)
            if field == "icon" and value is None:
                value = f"res://{row.id}"
            if getattr(row, column) != value:
                changes[field] = {"before": before[field], "after": value}
                setattr(row, column, value)
        if not changes:
            return _as_dict(row)

        row.updated_at = now_ms()
        version = bump_version(db)
        _log_changes(db, admin_id=admin_id, item_id=item_id, changes=changes, version=version, ip=ip)
        snapshot = _as_dict(row)
    return snapshot


def set_icon(
    db: Session,
    item_id: str,
    icon_url: str,
    *,
    admin_id: str,
    filename: str,
    ip: str | None = None,
) -> dict[str, Any]:
    """把上传成功的图标地址写回 `shop_item.icon`（文件落盘在调用方 `icons` 服务里完成）。"""
    with transaction(db):
        row = get_item(db, item_id)
        before = row.icon
        row.icon = icon_url
        row.updated_at = now_ms()
        version = bump_version(db)
        audit.write_op_log(
            db,
            admin_id=admin_id,
            action=audit.ACTION_UPLOAD_ICON,
            target_type="item",
            target_id=item_id,
            detail={
                "icon": {"before": before, "after": icon_url},
                "filename": filename,
                "shopVersion": version,
            },
            ip=ip,
        )
        snapshot = _as_dict(row)
    return snapshot


def _log_changes(
    db: Session,
    *,
    admin_id: str,
    item_id: str,
    changes: dict[str, dict[str, Any]],
    version: str,
    ip: str | None,
) -> None:
    """按"一条动作一行"拆日志：price → change_price，onShelf → toggle_shelf，其余 → update_item。"""
    price = changes.pop("price", None)
    if price is not None:
        audit.write_op_log(
            db,
            admin_id=admin_id,
            action=audit.ACTION_CHANGE_PRICE,
            target_type="item",
            target_id=item_id,
            detail={"price": price, "shopVersion": version},
            ip=ip,
        )
    shelf = changes.pop("onShelf", None)
    if shelf is not None:
        audit.write_op_log(
            db,
            admin_id=admin_id,
            action=audit.ACTION_TOGGLE_SHELF,
            target_type="item",
            target_id=item_id,
            detail={
                "onShelf": shelf,
                "shelfLabel": {"before": "在架" if shelf["before"] else "已下架", "after": "在架" if shelf["after"] else "已下架"},
                "shopVersion": version,
            },
            ip=ip,
        )
    if changes:
        audit.write_op_log(
            db,
            admin_id=admin_id,
            action=audit.ACTION_UPDATE_ITEM,
            target_type="item",
            target_id=item_id,
            detail={**changes, "shopVersion": version},
            ip=ip,
        )


def new_item_id(prefix: str = "item") -> str:
    """生成一个新商品编码（新增表单里默认填好，减少手滑）。"""
    return f"{prefix}_{uuid.uuid4().hex[:6]}"


__all__ = [
    "ALLOWED_SECTIONS",
    "ITEM_ID_RE",
    "TRACKED_FIELDS",
    "VERSION_RE",
    "bump_version",
    "catalog",
    "create_item",
    "current_version",
    "get_item",
    "list_items",
    "new_item_id",
    "next_version",
    "set_icon",
    "update_item",
]
