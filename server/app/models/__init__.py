"""ORM 模型唯一出口。

21 张表 = 附录 B §1.2 的 18 张同名表（客户端 19 张去掉 `science_article`）+ §3 的 3 张管理表。

模块同时提供 `compare_with_database(engine)`：把 ORM 元数据与实际库结构（由 `server/sql/schema.sql`
建出来）逐表逐列比对，作为「ORM 与建表脚本不分叉」的可执行证据（由 tests/test_auth.py 断言 diff 为 0）。
"""

from __future__ import annotations

import re
from typing import Any

from sqlalchemy import inspect
from sqlalchemy.engine import Engine

from app.models.account import AdminOpLog, AdminUser, ServerUser
from app.models.badge import BadgeDef, UserBadge
from app.models.base import Base
from app.models.content import AppConfig, ScienceProgress
from app.models.goal import GoalDef, UserGoal
from app.models.ledger import (
    CarbonFactorMeta,
    CarbonRecord,
    PointDailyStat,
    PointRecord,
    ShareRecord,
    SyncLog,
)
from app.models.profile import DeviceInfo, UserProfile
from app.models.shop import CarbonInclude, ShopItem, UserAppearance, UserPurchase

#: 全部 ORM 模型（顺序与 schema.sql 一致）
ALL_MODELS: tuple[type[Base], ...] = (
    CarbonRecord,
    CarbonFactorMeta,
    PointRecord,
    PointDailyStat,
    GoalDef,
    UserGoal,
    BadgeDef,
    UserBadge,
    ShopItem,
    UserPurchase,
    UserAppearance,
    ScienceProgress,
    CarbonInclude,
    ShareRecord,
    SyncLog,
    UserProfile,
    DeviceInfo,
    AppConfig,
    ServerUser,
    AdminUser,
    AdminOpLog,
)

#: 服务端表总数（18 张同名表 + 3 张管理表）
TABLE_COUNT: int = 21

#: 参与同步的 9 张表（= 有 user_id 且带 is_deleted 的表；与附录 B §6 / D6-6「待同步数」口径一致）
SYNC_TABLE_NAMES: tuple[str, ...] = (
    "carbon_record",
    "point_record",
    "user_goal",
    "user_badge",
    "user_purchase",
    "user_appearance",
    "science_progress",
    "carbon_include",
    "user_profile",
)

#: 账号注销时需要软删除的归属表（与 SYNC_TABLE_NAMES 同源，避免两处口径分叉）
ACCOUNT_DATA_TABLE_NAMES: tuple[str, ...] = SYNC_TABLE_NAMES

_TYPE_BASE_ALIASES: dict[str, str] = {"INT": "INTEGER"}


def model_table_names() -> set[str]:
    """ORM 声明的表名集合。"""
    return set(Base.metadata.tables)


def normalize_type(type_obj: Any) -> str:
    """把 ORM 类型与 MySQL 反射类型归一到同一口径，便于比对。

    `INT`/`INTEGER`、`TINYINT(1)`/`TINYINT` 视为等价；`VARCHAR(n)` 保留长度。
    """
    text = str(type_obj).upper().replace(" ", "")
    match = re.match(r"^([A-Z]+)(?:\((\d+)(?:,(\d+))?\))?", text)
    if not match:
        return text
    base = _TYPE_BASE_ALIASES.get(match.group(1), match.group(1))
    if base == "VARCHAR":
        return f"VARCHAR({match.group(2)})" if match.group(2) else "VARCHAR"
    return base


def compare_with_database(engine: Engine) -> dict[str, Any]:
    """比对 ORM 元数据与真实库结构，返回逐项差异（全空 = 无分叉）。"""
    inspector = inspect(engine)
    db_tables = set(inspector.get_table_names())
    orm_tables = model_table_names()

    report: dict[str, Any] = {
        "orm_table_count": len(orm_tables),
        "db_table_count": len(db_tables),
        "missing_in_db": sorted(orm_tables - db_tables),
        "missing_in_orm": sorted(db_tables - orm_tables),
        "column_diffs": [],
        "pk_diffs": [],
        "index_diffs": [],
    }

    for table_name in sorted(orm_tables & db_tables):
        table = Base.metadata.tables[table_name]
        db_columns = {col["name"]: col for col in inspector.get_columns(table_name)}

        for name, column in table.columns.items():
            db_col = db_columns.get(name)
            if db_col is None:
                report["column_diffs"].append(f"{table_name}.{name}: 库中缺列")
                continue
            if normalize_type(db_col["type"]) != normalize_type(column.type):
                report["column_diffs"].append(
                    f"{table_name}.{name}: 类型 库={normalize_type(db_col['type'])} ORM={normalize_type(column.type)}"
                )
            if bool(db_col["nullable"]) != bool(column.nullable):
                report["column_diffs"].append(
                    f"{table_name}.{name}: 可空性 库={bool(db_col['nullable'])} ORM={bool(column.nullable)}"
                )
        for name in db_columns:
            if name not in table.columns:
                report["column_diffs"].append(f"{table_name}.{name}: ORM 缺列")

        db_pk = set(inspector.get_pk_constraint(table_name).get("constrained_columns") or [])
        orm_pk = {col.name for col in table.primary_key.columns}
        if db_pk != orm_pk:
            report["pk_diffs"].append(f"{table_name}: 库={sorted(db_pk)} ORM={sorted(orm_pk)}")

        db_indexes = {idx["name"] for idx in inspector.get_indexes(table_name) if idx.get("name")}
        db_indexes |= {uq["name"] for uq in inspector.get_unique_constraints(table_name) if uq.get("name")}
        orm_indexes = {index.name for index in table.indexes if index.name} | {
            constraint.name
            for constraint in table.constraints
            if constraint.name and constraint.name.startswith(("uq_", "idx_"))
        }
        if db_indexes != orm_indexes:
            report["index_diffs"].append(
                f"{table_name}: 库-ORM={sorted(db_indexes - orm_indexes)} ORM-库={sorted(orm_indexes - db_indexes)}"
            )

    report["ok"] = not (
        report["missing_in_db"]
        or report["missing_in_orm"]
        or report["column_diffs"]
        or report["pk_diffs"]
        or report["index_diffs"]
    )
    return report


__all__ = [
    "ACCOUNT_DATA_TABLE_NAMES",
    "ALL_MODELS",
    "AdminOpLog",
    "AdminUser",
    "AppConfig",
    "BadgeDef",
    "Base",
    "CarbonFactorMeta",
    "CarbonInclude",
    "CarbonRecord",
    "DeviceInfo",
    "GoalDef",
    "PointDailyStat",
    "PointRecord",
    "SYNC_TABLE_NAMES",
    "ScienceProgress",
    "ServerUser",
    "ShareRecord",
    "ShopItem",
    "SyncLog",
    "TABLE_COUNT",
    "UserAppearance",
    "UserBadge",
    "UserGoal",
    "UserProfile",
    "UserPurchase",
    "compare_with_database",
    "model_table_names",
    "normalize_type",
]
