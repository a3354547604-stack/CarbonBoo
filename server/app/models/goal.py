"""目标 ORM 模型（附录 B §1.2：goal_def 静态字典 + user_goal 用户进度）。"""

from __future__ import annotations

from sqlalchemy import BigInteger, Index, Integer, String, Text, UniqueConstraint, text
from sqlalchemy.dialects.mysql import DOUBLE, TINYINT
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class GoalDef(Base):
    """goal_def —— 目标定义（11 个目标，静态字典，由 sql/seed.sql 灌入）。"""

    __tablename__ = "goal_def"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    name: Mapped[str] = mapped_column(String(64), nullable=False)
    tier: Mapped[str] = mapped_column(String(16), nullable=False)
    period: Mapped[str] = mapped_column(String(16), nullable=False)
    metric: Mapped[str] = mapped_column(String(32), nullable=False)
    category: Mapped[str | None] = mapped_column(String(32), nullable=True)
    sub_types: Mapped[str | None] = mapped_column(Text, nullable=True)
    unit: Mapped[str | None] = mapped_column(String(16), nullable=True)
    threshold: Mapped[float] = mapped_column(DOUBLE(asdecimal=False), nullable=False)
    reward: Mapped[int] = mapped_column(Integer, nullable=False)
    icon: Mapped[str] = mapped_column(String(255), nullable=False)
    order: Mapped[int] = mapped_column(Integer, nullable=False)  # MySQL 保留字，SQLAlchemy 会自动加反引号
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)


class UserGoal(Base):
    """user_goal —— 用户目标进度（幂等键 uq_ug(user_id, goal_id, period_key)）。"""

    __tablename__ = "user_goal"
    __table_args__ = (
        UniqueConstraint("user_id", "goal_id", "period_key", name="uq_ug"),
        Index("idx_ug_updated", "updated_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    goal_id: Mapped[str] = mapped_column(String(32), nullable=False)
    period_key: Mapped[str] = mapped_column(String(32), nullable=False)
    progress: Mapped[float] = mapped_column(DOUBLE(asdecimal=False), nullable=False, server_default=text("0"))
    threshold: Mapped[float] = mapped_column(DOUBLE(asdecimal=False), nullable=False)
    settled: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    settled_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    is_deleted: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


__all__ = ["GoalDef", "UserGoal"]
