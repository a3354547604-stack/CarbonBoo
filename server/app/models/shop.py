"""碳小铺 / 外观 / 碳普惠 ORM 模型（附录 B §1.2 的 4 张同名表）。

`shop_item` 是服务端取价的数据源（登录后拉取；失败降级为内置默认价，铁律 1 例外②）。
"""

from __future__ import annotations

from sqlalchemy import BigInteger, Index, Integer, String, UniqueConstraint, text
from sqlalchemy.dialects.mysql import TINYINT
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class ShopItem(Base):
    """shop_item —— 商品定义与价格（服务端可改价，管理端 action=change_price）。"""

    __tablename__ = "shop_item"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    section: Mapped[str] = mapped_column(String(32), nullable=False)
    name: Mapped[str] = mapped_column(String(64), nullable=False)
    description: Mapped[str | None] = mapped_column(String(255), nullable=True)
    price: Mapped[int] = mapped_column(Integer, nullable=False)
    icon: Mapped[str] = mapped_column(String(255), nullable=False)
    order: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))  # MySQL 保留字
    on_shelf: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("1"))
    is_default_free: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)


class UserPurchase(Base):
    """user_purchase —— 购买记录（幂等键 uq_up(user_id, item_id)）。"""

    __tablename__ = "user_purchase"
    __table_args__ = (
        UniqueConstraint("user_id", "item_id", name="uq_up"),
        Index("idx_up_updated", "updated_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    item_id: Mapped[str] = mapped_column(String(64), nullable=False)
    price_paid: Mapped[int] = mapped_column(Integer, nullable=False)
    purchased_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    is_deleted: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


class UserAppearance(Base):
    """user_appearance —— 当前外观（每个用户一行，uq_ua(user_id)）。"""

    __tablename__ = "user_appearance"
    __table_args__ = (
        UniqueConstraint("user_id", name="uq_ua"),
        Index("idx_ua_updated", "updated_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    avatar_id: Mapped[str] = mapped_column(String(64), nullable=False)
    frame_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    theme_id: Mapped[str] = mapped_column(String(64), nullable=False)
    nickname: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    is_deleted: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


class CarbonInclude(Base):
    """carbon_include —— 碳普惠（积分兑换减排量）记录。"""

    __tablename__ = "carbon_include"
    __table_args__ = (
        Index("idx_ci_user_time", "user_id", text("occurred_at DESC")),
        Index("idx_ci_updated", "updated_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    action: Mapped[str] = mapped_column(String(32), nullable=False)
    points_spent: Mapped[int] = mapped_column(Integer, nullable=False)
    coin_amount: Mapped[int] = mapped_column(Integer, nullable=False)
    benefit_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    benefit_name: Mapped[str | None] = mapped_column(String(128), nullable=True)
    occurred_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    is_deleted: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


__all__ = ["CarbonInclude", "ShopItem", "UserAppearance", "UserPurchase"]
