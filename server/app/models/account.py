"""账号与管理端 ORM 模型 —— 附录 B §3 三张管理表。

`server_user` 是账号表：**不存 device_id**（B35 契约：注册/登录请求体去掉了 deviceId，
设备维度只存在于客户端与业务表），主键 `id` 是账号行 id，`user_id` 是客户端业务数据的归属键
（= /auth 响应里的 `userId`，客户端把它写进各业务表的 `user_id` 列）。
"""

from __future__ import annotations

from sqlalchemy import BigInteger, Index, String, Text, UniqueConstraint, text
from sqlalchemy.dialects.mysql import TINYINT
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class ServerUser(Base):
    """server_user —— 账号（用户名 + bcrypt 口令哈希 + 云数据归属键 user_id）。"""

    __tablename__ = "server_user"
    __table_args__ = (
        UniqueConstraint("username", name="uq_su_username"),
        UniqueConstraint("user_id", name="uq_su_userid"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)  # 与客户端 user_id 对应
    username: Mapped[str] = mapped_column(String(64), nullable=False)
    password_hash: Mapped[str] = mapped_column(String(100), nullable=False)  # bcrypt
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    last_login_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    is_active: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("1"))


class AdminUser(Base):
    """admin_user —— 管理端账号（Web 后台，独立于客户端账号，且用独立 JWT 密钥）。"""

    __tablename__ = "admin_user"
    __table_args__ = (UniqueConstraint("username", name="uq_au_username"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    username: Mapped[str] = mapped_column(String(64), nullable=False)
    password_hash: Mapped[str] = mapped_column(String(100), nullable=False)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    last_login_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)


class AdminOpLog(Base):
    """admin_op_log —— 管理端/账号生命周期操作审计。

    注销（DELETE /api/v1/auth/account）与恢复也会写这里（action=account_delete / account_restore），
    恢复窗口与「物理清除」判定都读最新一条生命周期记录，语义不散落在别处。
    """

    __tablename__ = "admin_op_log"
    __table_args__ = (Index("idx_aol_admin", "admin_id", text("created_at DESC")),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    admin_id: Mapped[str] = mapped_column(String(36), nullable=False)
    #: login | change_price | toggle_shelf | update_config | account_delete | account_restore | account_purge
    action: Mapped[str] = mapped_column(String(64), nullable=False)
    target_type: Mapped[str | None] = mapped_column(String(32), nullable=True)
    target_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    detail: Mapped[str | None] = mapped_column(Text, nullable=True)  # JSON：改前 / 改后
    ip: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)


#: 账号生命周期相关的 admin_op_log.action 取值
ACTION_ACCOUNT_DELETE = "account_delete"
ACTION_ACCOUNT_RESTORE = "account_restore"
ACTION_ACCOUNT_PURGE = "account_purge"

__all__ = [
    "ACTION_ACCOUNT_DELETE",
    "ACTION_ACCOUNT_PURGE",
    "ACTION_ACCOUNT_RESTORE",
    "AdminOpLog",
    "AdminUser",
    "ServerUser",
]
