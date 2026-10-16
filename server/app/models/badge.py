"""徽章 ORM 模型（附录 B §1.2：badge_def 静态字典 + user_badge 用户解锁进度）。

徽章不发分（附录 D §9 口径：徽章 6/8 只做展示），因此 user_badge 不产生积分流水。
"""

from __future__ import annotations

from sqlalchemy import BigInteger, Index, Integer, String, UniqueConstraint, text
from sqlalchemy.dialects.mysql import DOUBLE, TINYINT
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class BadgeDef(Base):
    """badge_def —— 徽章定义（静态字典，由 sql/seed.sql 灌入）。"""

    __tablename__ = "badge_def"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    name: Mapped[str] = mapped_column(String(64), nullable=False)
    description: Mapped[str] = mapped_column(String(255), nullable=False)
    tier: Mapped[str] = mapped_column(String(16), nullable=False)
    icon: Mapped[str] = mapped_column(String(255), nullable=False)
    metric: Mapped[str] = mapped_column(String(32), nullable=False)
    threshold: Mapped[float] = mapped_column(DOUBLE, nullable=False)
    order: Mapped[int] = mapped_column(Integer, nullable=False)  # MySQL 保留字
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)


class UserBadge(Base):
    """user_badge —— 用户徽章解锁状态（幂等键 uq_ub(user_id, badge_id)）。"""

    __tablename__ = "user_badge"
    __table_args__ = (
        UniqueConstraint("user_id", "badge_id", name="uq_ub"),
        Index("idx_ub_updated", "updated_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    badge_id: Mapped[str] = mapped_column(String(64), nullable=False)
    unlocked: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    unlocked_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    progress: Mapped[float] = mapped_column(DOUBLE, nullable=False, server_default=text("0"))
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    is_deleted: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


__all__ = ["BadgeDef", "UserBadge"]
