"""碳小铺取价：给客户端下发的商品目录与价格（S6，附录 B §5.4）。

职责
----
1. `GET /api/v1/shop/items` 的数据来源：服务端 `shop_item` 表（后台可改价，附录 B §5.4 的
   `/admin/items` PATCH 由 t6 实现；本模块只读，不改价）。
2. **版本号**：取 `app_config['shop_items_version']`（种子值是 `2026.02.01-1`，与附录 B §5.4 的
   响应示例逐字一致）。后台改价后应同时 bump 这个键——附录 B §5.4 写「后台改价**下次启动生效**」，
   客户端按版本号判断是否需要整份覆盖 `app_config['shop_items']`。
3. 目录里**包含已下架商品**（`onShelf = 0`）：附录 B §5.4 的响应示例带 `onShelf` 字段，
   客户端 `ShopRules.check` 正是靠它给出「该商品已下架」；过滤掉下架商品会让这条界面规则永远走不到。
4. 未登录也能取价（附录 B §5.4：**只有取价接口无需 token**）。铁律 1 的例外②：客户端启动拉取一次，
   服务端不可用 → 客户端**整份丢弃**并继续用内置默认价（`rawfile/shop/shop-items.json`）——
   这条回落逻辑在客户端（`HTTP_TIMEOUT_MS = 3000`），服务端只保证「拿到的是完整一份目录」。
5. 任何一步失败都**不返回半个目录**：查库异常直接冒泡成 500，让客户端走整份丢弃路径，
   而不是把空目录当成有效价目表覆盖掉内置价。
"""

from __future__ import annotations

import logging
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.content import AppConfig
from app.models.shop import ShopItem

logger = logging.getLogger("carbonboo.server.shop")

#: 商品目录版本号的配置键（app_config 主键）
SHOP_VERSION_KEY = "shop_items_version"

#: 目录缺省版本（app_config 里没有该键时使用；客户端据此判定"未拉到过版本"，仍会整份覆盖）
FALLBACK_VERSION = "0.0.0"


def current_version(db: Session) -> str:
    """读 `app_config['shop_items_version']`；缺失时返回缺省版本（不猜、不编造日期）。

    `value` 优先、`version` 兜底：种子把两者写成同一个值（`2026.02.01-1`，与附录 B §5.4 示例一致），
    但**契约里客户端覆盖的是 `value`**（"拉取并整份覆盖 `app_config['shop_items']`"，附录 B §5.4），
    所以以后台改价时改 `value` 为准。
    """
    row = db.execute(select(AppConfig).where(AppConfig.id == SHOP_VERSION_KEY)).scalar_one_or_none()
    if row is None or not (row.value or row.version):
        logger.warning("app_config['%s'] 缺失，商品目录以 %s 版本下发", SHOP_VERSION_KEY, FALLBACK_VERSION)
        return FALLBACK_VERSION
    return row.value or row.version or FALLBACK_VERSION


def list_items(db: Session) -> list[dict[str, Any]]:
    """全部商品（含下架），按 `section`、`order`、`id` 升序。

    顺序口径：**分区之间 frame → theme，分区内按 `order`** —— 与客户端内置
    `rawfile/shop/shop-items.json` 的顺序逐项一致（整份覆盖后本地顺序不变），
    同时满足附录 B §5.4 响应示例（`frame_01` 在 `theme_default` 之前）。
    """
    rows = (
        db.execute(select(ShopItem).order_by(ShopItem.section, ShopItem.order, ShopItem.id)).scalars().all()
    )
    return [
        {
            "id": item.id,
            "section": item.section,
            "name": item.name,
            "description": item.description,
            "price": item.price,
            "icon": item.icon,
            "order": item.order,
            "onShelf": item.on_shelf,
            "isDefaultFree": item.is_default_free,
        }
        for item in rows
    ]


def catalog(db: Session) -> dict[str, Any]:
    """取价接口的完整载荷：`{version, items}`（附录 B §5.4）。

    刻意不在这里做分页 / 过滤 / 排序参数：契约里没有，客户端也是「整份覆盖」，
    多一个查询参数就多一条与内置默认价不同的路径。
    """
    items = list_items(db)
    return {"version": current_version(db), "items": items}


__all__ = ["FALLBACK_VERSION", "SHOP_VERSION_KEY", "catalog", "current_version", "list_items"]
