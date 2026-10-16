"""科普进度与全局配置 ORM 模型（附录 B §1.2：science_progress + app_config）。

服务端**不建 science_article 表**（§1.2：科普正文内置在 App，服务端只同步阅读进度）。
"""

from __future__ import annotations

from sqlalchemy import BigInteger, Index, String, Text, UniqueConstraint, text
from sqlalchemy.dialects.mysql import DOUBLE, TINYINT
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class ScienceProgress(Base):
    """science_progress —— 科普阅读进度 / 收藏（幂等键 uq_sp(user_id, article_id)）。"""

    __tablename__ = "science_progress"
    __table_args__ = (
        UniqueConstraint("user_id", "article_id", name="uq_sp"),
        Index("idx_sp_updated", "updated_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    article_id: Mapped[str] = mapped_column(String(64), nullable=False)
    progress: Mapped[float] = mapped_column(DOUBLE(asdecimal=False), nullable=False, server_default=text("0"))
    is_favorite: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    last_read_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    is_deleted: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


class AppConfig(Base):
    """app_config —— 服务端下发的全局配置（key = id；管理端 action=update_config）。"""

    __tablename__ = "app_config"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    value: Mapped[str] = mapped_column(Text, nullable=False)
    version: Mapped[str | None] = mapped_column(String(32), nullable=True)
    fetched_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)


__all__ = ["AppConfig", "ScienceProgress"]
