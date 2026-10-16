"""碳小铺取价的响应模型（逐字对齐 docs/APPENDIX-B-data-and-api.md §5.4）。

字段名直接用契约里的 camelCase（`onShelf` / `isDefaultFree`），不引 alias 映射。
`description` 是附录 B §5.4 响应示例里没列、但客户端 `ShopItem` 类型与内置
`rawfile/shop/shop-items.json` 都有的字段 —— 服务端把它一并下发，两侧数据结构一致。
"""

from __future__ import annotations

from pydantic import BaseModel, Field


class ShopItemData(BaseModel):
    """一件商品（附录 B §5.4 的 items[] 元素）。"""

    id: str = Field(description="商品编码：frame_01..frame_08 / theme_default")
    section: str = Field(description="分区：frame | theme")
    name: str = Field(description="展示名")
    description: str | None = Field(default=None, description="一句话描述（客户端内置价目表同字段）")
    price: int = Field(description="价格（积分）")
    icon: str = Field(description="图标标识，如 res://frame_01")
    order: int = Field(description="排序（升序）")
    onShelf: int = Field(description="1 = 在架，0 = 已下架（客户端据此显示「该商品已下架」）")
    isDefaultFree: int = Field(description="1 = 默认免费主题")


class ShopItemsData(BaseModel):
    """GET /api/v1/shop/items 的业务数据（附录 B §5.4）。"""

    version: str = Field(description="目录版本号（app_config['shop_items_version']），客户端据此判断是否整份覆盖")
    items: list[ShopItemData] = Field(description="全部商品（含已下架），按 order、id 升序")


__all__ = ["ShopItemData", "ShopItemsData"]
