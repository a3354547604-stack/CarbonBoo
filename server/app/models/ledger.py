"""台账与流水 ORM 模型（附录 B §1.2 的 6 张同名表）。

`is_deleted` = 软删除标记：这些带 user_id 的表都是同步参与表，删除以 LWW 传播，
注销账号时把该账号的行置 1（保留 30 天可恢复），见 services/auth_provider.py。
"""

from __future__ import annotations

from sqlalchemy import BigInteger, Index, Integer, String, Text, UniqueConstraint, text
from sqlalchemy.dialects.mysql import DOUBLE, TINYINT
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class CarbonRecord(Base):
    """carbon_record —— 碳记录（因子快照随记录落库，铁律 3）。"""

    __tablename__ = "carbon_record"
    __table_args__ = (
        Index("idx_cr_user_time", "user_id", text("occurred_at DESC")),
        Index("idx_cr_user_cat", "user_id", "category", text("occurred_at DESC")),
        Index("idx_cr_updated", "updated_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    category: Mapped[str] = mapped_column(String(32), nullable=False)
    sub_type: Mapped[str] = mapped_column(String(64), nullable=False)
    amount: Mapped[float] = mapped_column(DOUBLE(asdecimal=False), nullable=False)
    unit: Mapped[str] = mapped_column(String(16), nullable=False)
    occurred_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    reduction_kg: Mapped[float] = mapped_column(DOUBLE(asdecimal=False), nullable=False)
    factor_value: Mapped[float] = mapped_column(DOUBLE(asdecimal=False), nullable=False)
    factor_version: Mapped[str] = mapped_column(String(32), nullable=False)
    factor_source: Mapped[str] = mapped_column(String(64), nullable=False)
    confidence: Mapped[str] = mapped_column(String(16), nullable=False)
    point_awarded: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    point_capped: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    revision: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    is_abnormal: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    is_deleted: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


class CarbonFactorMeta(Base):
    """carbon_factor_meta —— 因子库版本元数据（无 user_id，全局单例语义）。"""

    __tablename__ = "carbon_factor_meta"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    version: Mapped[str] = mapped_column(String(32), nullable=False)
    source_updated: Mapped[str | None] = mapped_column(String(64), nullable=True)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)


class PointRecord(Base):
    """point_record —— 积分流水（只增不删，铁律 4；flow_kind 区分收入/支出，B35 契约）。"""

    __tablename__ = "point_record"
    __table_args__ = (
        # 业务唯一键；**含 user_id** —— 服务端多账号共库，而 source_id 取值口径不含账号
        # （附录 B §2:135-138），少了 user_id 会让两个账号的同名目标互相顶掉。
        # 附录 B §2:142 需同步修正；迁移见 sql/migrations/001_uq_pr_source_user_id.sql。
        UniqueConstraint("user_id", "source_type", "source_id", "flow_kind", name="uq_pr_source"),
        Index("idx_pr_user_time", "user_id", text("occurred_at DESC")),
        Index("idx_pr_cap", "user_id", "occurred_at", "source_type", "is_deleted"),
        Index("idx_pr_updated", "updated_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    type: Mapped[str] = mapped_column(String(32), nullable=False)
    flow_kind: Mapped[str] = mapped_column(String(16), nullable=False)  # primary | reverse
    points: Mapped[int] = mapped_column(Integer, nullable=False)
    source_type: Mapped[str] = mapped_column(String(32), nullable=False)
    source_id: Mapped[str] = mapped_column(String(128), nullable=False)
    title: Mapped[str] = mapped_column(String(128), nullable=False)
    remark: Mapped[str | None] = mapped_column(Text, nullable=True)
    occurred_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    is_deleted: Mapped[int] = mapped_column(TINYINT, nullable=False, server_default=text("0"))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


class PointDailyStat(Base):
    """point_daily_stat —— 每日积分统计（复合主键 user_id + day_key，B4 契约）。"""

    __tablename__ = "point_daily_stat"
    __table_args__ = (Index("idx_pds_day", text("day_key DESC")),)

    user_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    day_key: Mapped[str] = mapped_column(String(16), primary_key=True)
    record_points: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    goal_points: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    spent_points: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    record_count: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    rebuilt_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)


class ShareRecord(Base):
    """share_record —— 分享卡片记录（只增，无 is_deleted）。"""

    __tablename__ = "share_record"
    __table_args__ = (Index("idx_sr_user_time", "user_id", text("created_at DESC")),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    card_size: Mapped[str] = mapped_column(String(32), nullable=False)
    reduction_kg: Mapped[float] = mapped_column(DOUBLE(asdecimal=False), nullable=False)
    badge_count: Mapped[int] = mapped_column(Integer, nullable=False)
    saved_path: Mapped[str | None] = mapped_column(String(255), nullable=True)
    shared_to: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)


class SyncLog(Base):
    """sync_log —— 同步日志（供「待同步数 / 冲突记录」展示；t5 同步切片写入）。"""

    __tablename__ = "sync_log"
    __table_args__ = (Index("idx_sl_user_time", "user_id", text("created_at DESC")),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    peer_device: Mapped[str | None] = mapped_column(String(64), nullable=True)
    direction: Mapped[str] = mapped_column(String(16), nullable=False)  # push | pull
    status: Mapped[str] = mapped_column(String(16), nullable=False)  # success | partial | failed
    pulled_count: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    pushed_count: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    conflict_count: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text("0"))
    error_msg: Mapped[str | None] = mapped_column(Text, nullable=True)
    started_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    finished_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger, nullable=False)


__all__ = [
    "CarbonFactorMeta",
    "CarbonRecord",
    "PointDailyStat",
    "PointRecord",
    "ShareRecord",
    "SyncLog",
]
