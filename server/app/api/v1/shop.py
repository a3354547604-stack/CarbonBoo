"""碳小铺取价接口（逐条对齐 docs/APPENDIX-B-data-and-api.md §5.4）。

    GET /api/v1/shop/items   商品目录与价格（**无需 token**）

口径（铁律 1 的例外②）
--------------------
* 这是**唯一不需要令牌的客户端接口**（附录 B §5.3 开头行明确）：未登录也能取价（用内置默认价也一样能用）。
* 客户端**启动时拉取一次**，成功则整份覆盖 `app_config['shop_items']`；失败或数据非法 → **整份丢弃**，
  继续用上一份有效配置；从未拉到过 → 用 `rawfile/shop/shop-items.json` 内置默认价（超时 3s）。
  这条回落规则在客户端（`HTTP_TIMEOUT_MS = 3000`）；服务端只保证「要么给完整一份目录，要么报错」。
* 后台改价**下次启动生效**（附录 B §5.4）；改价接口 `/admin/items` 由 t6 实现，不在本模块。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.schemas.common import ErrorEnvelope, OkEnvelope
from app.schemas.shop import ShopItemsData
from app.services import shop_service

router = APIRouter()

_ERROR_RESPONSES: dict[int | str, dict[str, object]] = {
    500: {"model": ErrorEnvelope, "description": "服务端异常（SERVER_ERROR）；客户端应整份丢弃并回落内置默认价"},
}


@router.get(
    "/items",
    summary="商品目录与价格",
    description=(
        "返回全部商品（含已下架，`onShelf = 0`）与目录版本号。客户端启动拉取一次并整份覆盖本地价目表；"
        "本接口失败或返回非法数据时，客户端**整份丢弃**并回落到内置默认价（`rawfile/shop/shop-items.json`）。"
    ),
    response_model=OkEnvelope[ShopItemsData],
    responses=_ERROR_RESPONSES,
)
def items(db: Annotated[Session, Depends(get_db)]) -> OkEnvelope[ShopItemsData]:
    return OkEnvelope[ShopItemsData](data=ShopItemsData(**shop_service.catalog(db)))


__all__ = ["router"]
