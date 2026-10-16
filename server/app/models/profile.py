"""用户资料与设备 ORM 模型（附录 B §1.2：user_profile + device_info）。

`user_profile.user_id` 即账号归属键（= /auth 响应里的 userId）；首次安装时客户端本地
`user_profile.id` 用新 UUID 生成（B35 契约），服务端不参与该生成。
"""

from __future__ import annotations

from sqlalchemy import BigInteger, Index, String, Text, UniqueConstraint, text
from sqlalchemy.dialects.mysql import TINYINT
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class UserProfile(Base):
    """user_profile —— 用户资料（每个用户一行，uq_uprofile(user_id)）。"""

    __tablename__ = "user_profile"
    __table_args__ = (
        UniqueConstraint("user_id", name="uq_uprofile"),
        Index("idx_uprofile_updated", "updated_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    display_name: Mapped[str] = mapped_column(
        String(64), nullable=False, server_default=text("'碳小布用户'")
    )
    register_day: Mapped[str] = mapped_column(String(16), nullable=False)
    onboarded: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    last_active_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    is_deleted: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


class DeviceInfo(Base):
    """device_info —— 设备清单（多设备同步的 peer 记录；无 user_id，服务端按 device_id 归档）。"""

    __tablename__ = "device_info"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    device_id: Mapped[str] = mapped_column(String(64), nullable=False)
    device_name: Mapped[str | None] = mapped_column(String(64), nullable=True)
    device_model: Mapped[str | None] = mapped_column(String(64), nullable=True)
    is_self: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("1"))
    last_sync_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    paired_devices: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)


__all__ = ["DeviceInfo", "UserProfile"]
