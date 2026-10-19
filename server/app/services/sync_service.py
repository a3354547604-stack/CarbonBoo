"""多设备云端同步：增量 pull / push + LWW 合并（S6 主通路，ADR-0001）。

职责与口径
----------
1. **唯一真通路**：跨设备一致性由本模块承担（附录 B §5.3/§6 + ADR-0001）。鸿蒙分布式协同是
   近场演示层，不在服务端实现，也不影响本模块（附录 B §6.6）。
2. **参与同步的 9 张表**：`app.models.SYNC_TABLE_NAMES`（单一来源，与客户端
   `ClientSchema.SYNCED_TABLES` 逐字一致）；`point_daily_stat` 是派生缓存、**不参与同步**
   （附录 B §2 注释），`sync_state` 是**仅客户端**的列（附录 B §1.3），服务端没有这一列，
   收到的行里带 `sync_state` 会被按「未知列」忽略。
3. **合并策略**（附录 B §6.5，表分组唯一来源）：
   - 只增账本 `point_record` / `carbon_include` → `append_only`：同 `id` 已存在即跳过，**永不 UPDATE**（铁律 4）；
   - 可改可删 `carbon_record` / `user_goal` / `user_badge` / `user_purchase` / `user_appearance` /
     `science_progress` / 单例行 `user_profile` → `lww`：完整 LWW。
4. **双重幂等**（附录 B §6.4-3）：写入统一走 `INSERT IGNORE`，并在此之前按**业务唯一键**判重；
   被丢弃的行计入 `ignored`（§5.3 里叫 `skipped`），面板显示为「跨设备重复已去重」。
   业务键在**服务端按 (user_id, 业务键) 判定**——服务端是多账号共库，唯一键必须含 `user_id`：
   `uq_pr_source(source_type, source_id, flow_kind)` 少一个 `user_id`（附录 B §2:142），
   会让两个账号同一天达成的同名目标互相顶掉；该索引由 `sql/migrations/001_*.sql` 就地修正，
   代码侧仍以 (user_id, 业务键) 为准，另在 `_diagnose_ignored` 里对「撞到别人的行」做响亮拒绝。
5. **真冲突**：`l.updated_at > lastSyncAt AND r.updated_at > lastSyncAt`（两端自上次同步后都改过），
   平局分支用**同一条件**计数（附录 B §6.3:912/919）。
6. **软删除即普通行**（附录 B §1.3-4 / §6.4-2）：`is_deleted = 1` 的行照常参与 LWW 与增量，
   删除因此可传播；本模块不对软删除行做任何特殊照顾，也不物理删除任何账本行。
7. **时钟基准**：`offset_ms = 服务端时钟 − 客户端时钟`（请求体可选 `clientNow`），比较前把对端
   时间戳换算到服务端基准；**容差 ±5 分钟**，超容差写 `sync_log.error_msg` 但**继续合并**（§6.4-6）。
8. **事务边界在本层**：一次 push / pull / status 的所有写库（含 `sync_log`）在同一事务里提交；
   任何异常由 `db` 依赖回滚，绝不留下半批数据。
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass, field
from typing import Any, Mapping

from sqlalchemy import and_, case, func, or_, select
from sqlalchemy.dialects.mysql import insert as mysql_insert
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from app.core.errors import AppError, ErrorCode
from app.core.security import now_ms
from app.models import SYNC_TABLE_NAMES, normalize_type
from app.models.base import Base
from app.models.ledger import SyncLog

logger = logging.getLogger("carbonboo.server.sync")

#: 时钟容差：±5 分钟（附录 B §6.4-6）
CLOCK_TOLERANCE_MS = 5 * 60 * 1000

#: 合并模式
MODE_APPEND_ONLY = "append_only"
MODE_LWW = "lww"

#: 表 → 合并模式（附录 B §6.5 的唯一实现依据；新增表必须在此显式登记，否则 push 直接 400）
SYNC_MODES: dict[str, str] = {
    # 只增（账本）：同 id 即跳过，永不 UPDATE（铁律 4）
    "point_record": MODE_APPEND_ONLY,
    "carbon_include": MODE_APPEND_ONLY,
    # 可改可删：完整 LWW
    "carbon_record": MODE_LWW,
    "user_goal": MODE_LWW,
    "user_badge": MODE_LWW,
    "user_purchase": MODE_LWW,  # 有唯一键的 LWW，uq_up(user_id, item_id) 兜底
    "user_appearance": MODE_LWW,
    "science_progress": MODE_LWW,
    "user_profile": MODE_LWW,  # 单例行，uq_uprofile(user_id) 兜底
}

#: 业务唯一键（不含 user_id —— 判定时一律与 user_id 组合，见模块头注释第 4 条）。
#: 空元组 = 该表除主键 `id` 外没有业务唯一键；`None` = 每个 user_id 恒一行的单例表。
BUSINESS_KEYS: dict[str, tuple[str, ...]] = {
    "point_record": ("source_type", "source_id", "flow_kind"),  # uq_pr_source（B35 契约，按 flow_kind 区分入账/冲正）
    "user_goal": ("goal_id", "period_key"),  # uq_ug
    "user_badge": ("badge_id",),  # uq_ub
    "user_purchase": ("item_id",),  # uq_up
    "science_progress": ("article_id",),  # uq_sp
    "carbon_record": (),  # 幂等键只有 id（记录类流水的幂等键是 <记录id>#<revision>，落在 point_record 上）
    "carbon_include": (),  # 幂等键只有 id
    "user_appearance": (),  # uq_ua(user_id) 单例
    "user_profile": (),  # uq_uprofile(user_id) 单例
}

#: 每个 user_id 恒一行的单例表（uq_ua / uq_uprofile）
SINGLETON_TABLES: tuple[str, ...] = ("user_appearance", "user_profile")

#: 响应里最多回带多少条逐行说明（防止一个畸形客户端把响应体撑爆）
MAX_ERRORS = 50

assert set(SYNC_MODES) == set(SYNC_TABLE_NAMES), "SYNC_MODES 必须与 SYNC_TABLE_NAMES 逐字一致"
assert set(BUSINESS_KEYS) == set(SYNC_TABLE_NAMES), "BUSINESS_KEYS 必须与 SYNC_TABLE_NAMES 逐字一致"


# --------------------------------------------------------------------------- #
# 结果
# --------------------------------------------------------------------------- #
@dataclass
class PushOutcome:
    """一次 push 的合并结果（字段口径见附录 B §5.3）。"""

    accepted: int = 0
    ignored: int = 0  # 跨设备重复已去重（id / 业务唯一键）
    rejected: int = 0  # 保留服务端版本 / 非法行 / 越权行
    conflicts: int = 0  # 真冲突：两端自上次同步后都改过
    offset_ms: int = 0
    clock_warning: str | None = None
    accepted_by_table: dict[str, int] = field(default_factory=dict)
    merged: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)
    status: str = "success"

    @property
    def skipped(self) -> int:
        """附录 B §5.3 的 `skipped` = 未被采纳的行（去重 + 保留服务端版本）。"""
        return self.ignored + self.rejected

    def note(self, message: str) -> None:
        """记一条逐行说明（超过上限后只是不再回带，仍写日志）。"""
        if len(self.errors) < MAX_ERRORS:
            self.errors.append(message)
        else:  # pragma: no cover - 仅在畸形客户端下命中
            logger.warning("同步逐行说明超过 %d 条，后续仅写日志：%s", MAX_ERRORS, message)

    def merge_back(self, table: str, row: Mapping[str, Any]) -> None:
        """把「服务端版本更胜」的行记进 merged，让客户端回写后两端收敛。"""
        self.merged.setdefault(table, []).append(dict(row))

    def count(self, table: str) -> None:
        self.accepted_by_table[table] = self.accepted_by_table.get(table, 0) + 1


# --------------------------------------------------------------------------- #
# 行归一化（JSON → 列值）
# --------------------------------------------------------------------------- #
_INT_TYPES = {"BIGINT", "INTEGER", "TINYINT", "SMALLINT"}
_STR_TYPES = {"TEXT", "LONGTEXT", "MEDIUMTEXT", "CHAR"}


def _coerce(column_type: Any, value: Any, label: str) -> Any:
    """按列类型把 JSON 值转成本库可写的类型；类型明显不对就抛 ValueError（行级拒绝，不整批失败）。"""
    base = normalize_type(column_type)
    if base in _INT_TYPES:
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            if not value.is_integer():
                raise ValueError(f"{label} 需要整数，收到小数 {value!r}")
            return int(value)
        if isinstance(value, str) and value.strip().lstrip("+-").isdigit():
            return int(value.strip())
        raise ValueError(f"{label} 需要整数，收到 {type(value).__name__}")
    if base == "DOUBLE":
        if isinstance(value, bool):
            raise ValueError(f"{label} 需要数值，收到布尔值")
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            return float(value.strip())
        raise ValueError(f"{label} 需要数值，收到 {type(value).__name__}")
    if base.startswith("VARCHAR") or base in _STR_TYPES:
        if isinstance(value, str):
            return value
        raise ValueError(f"{label} 需要字符串，收到 {type(value).__name__}")
    # 其它类型（本项目 schema 里没有）：原样透传，由数据库报错
    return value


def table_columns(table: str) -> dict[str, Any]:
    """表的 ORM 列定义（列名 → Column）。"""
    return {column.name: column for column in Base.metadata.tables[table].columns}


def normalize_row(table: str, raw: Mapping[str, Any], *, user_id: str, device_id: str | None) -> tuple[dict[str, Any], str | None]:
    """把一行 JSON 归一到列值字典。

    返回 `(values, error)`；`error` 非空表示该行不合法（调用方计入 rejected，不写库）。
    未知列（例如客户端多带的 `sync_state`、或响应里回带的派生列）一律忽略，不算错误。
    """
    if not isinstance(raw, Mapping):
        return {}, f"行不是对象，收到 {type(raw).__name__}"
    columns = table_columns(table)
    values: dict[str, Any] = {}
    for name, value in raw.items():
        column = columns.get(name)
        if column is None:
            continue  # 未知列：忽略（sync_state 等仅客户端的列走这里）
        if value is None:
            continue
        try:
            values[name] = _coerce(column.type, value, f"{table}.{name}")
        except ValueError as exc:
            return {}, str(exc)
    row_id = values.get("id")
    if not isinstance(row_id, str) or not row_id:
        return {}, f"{table} 缺主键 id"
    # 归属键一律以令牌账号为准（越权行由调用方提前整批拒绝）
    values["user_id"] = user_id
    if device_id and not values.get("device_id"):
        values["device_id"] = device_id
    if "updated_at" not in values:
        return {}, f"{table}.id={row_id} 缺 updated_at（LWW 依据，附录 B §1.3）"
    missing = [
        name
        for name, column in columns.items()
        if name not in values and not column.nullable and column.default is None and column.server_default is None
    ]
    if missing:
        return {}, f"{table}.id={row_id} 缺必填列：{sorted(missing)}"
    return values, None


# --------------------------------------------------------------------------- #
# 业务唯一键判定
# --------------------------------------------------------------------------- #
def _as_dict(row: Mapping[str, Any] | None) -> dict[str, Any] | None:
    return None if row is None else dict(row)


def _find_business_key_row(db: Session, table_name: str, user_id: str, values: Mapping[str, Any]) -> tuple[str, dict[str, Any]] | None:
    """按 (user_id, 业务唯一键) 找已有行；没有唯一键返回 None。"""
    if table_name in SINGLETON_TABLES:
        table = Base.metadata.tables[table_name]
        found = db.execute(select(table).where(table.c.user_id == user_id).limit(1)).mappings().first()
        return None if found is None else (f"user_id={user_id}（单例行）", dict(found))

    keys = BUSINESS_KEYS.get(table_name, ())
    if not keys:
        return None
    table = Base.metadata.tables[table_name]
    conditions = [table.c.user_id == user_id]
    for key in keys:
        if values.get(key) is None:
            return None  # 缺键值就不判重（是否必填由 normalize_row 的必填列检查负责）
        conditions.append(table.c[key] == values[key])
    found = db.execute(select(table).where(*conditions).limit(1)).mappings().first()
    if found is None:
        return None
    described = ", ".join(f"{key}={values[key]!r}" for key in keys)
    return (f"{described}（user_id={user_id}）", dict(found))


def _diagnose_ignored(db: Session, table_name: str, user_id: str, values: Mapping[str, Any]) -> tuple[str, dict[str, Any] | None]:
    """`INSERT IGNORE` 被丢弃后，查清到底撞了谁（三种：同 id、业务键、别人的行）。

    第三种是**契约缺陷的兜底**：`uq_pr_source` 少了 `user_id`（附录 B §2:142）时，
    另一个账号的同名业务键会顶掉本账号的合法入账。这种情况**绝不能**悄悄计成「跨设备重复已去重」，
    必须响亮拒绝并写进 errors / sync_log（序号 001 的迁移会把该索引补上 `user_id`）。
    """
    table = Base.metadata.tables[table_name]
    row_id = values.get("id")
    same_id = db.execute(select(table).where(table.c.id == row_id).limit(1)).mappings().first()
    if same_id is not None:
        if same_id["user_id"] == user_id:
            return ("duplicate", dict(same_id))
        return ("foreign", dict(same_id))

    found = _find_business_key_row(db, table_name, user_id, values)
    if found is not None:
        return ("duplicate", found[1])

    # 业务键在库里存在，但属于另一个账号 —— 唯一索引未按 user_id 隔离
    keys = BUSINESS_KEYS.get(table_name, ())
    if keys:
        conditions = [table.c[key] == values.get(key) for key in keys if values.get(key) is not None]
        if len(conditions) == len(keys) and keys:
            other = db.execute(select(table).where(*conditions).limit(1)).mappings().first()
            if other is not None:
                return ("foreign", dict(other))
    return ("unknown", None)


# --------------------------------------------------------------------------- #
# push
# --------------------------------------------------------------------------- #
#: 同一批 push 遇到 InnoDB 死锁 / 锁等待超时时的整事务重放上限（MySQL 官方建议：死锁用重试解决）
PUSH_MAX_ATTEMPTS = 5

#: 可重放的 MySQL 锁错误码：1213 = 死锁（Deadlock found），1205 = 锁等待超时（Lock wait timeout）
RETRYABLE_LOCK_ERRNOS = (1213, 1205)


def _is_retryable_lock_error(exc: OperationalError) -> bool:
    """InnoDB 死锁 / 锁等待超时是**并发争用**而不是逻辑错误，整事务重放即可收敛。"""
    original = getattr(exc, "orig", None)
    code = original.args[0] if original is not None and original.args else None
    return code in RETRYABLE_LOCK_ERRNOS


def push(
    db: Session,
    *,
    user_id: str,
    device_id: str | None,
    last_sync_at: int,
    tables: Mapping[str, list[dict[str, Any]]],
    client_now: int | None = None,
) -> PushOutcome:
    """合并一批上行增量（服务端是接收方 = 附录 B §6.3 伪码里的 `local`）。

    并发：多个 push 同时写同一行时，InnoDB 可能以死锁（1213）中止其中一个事务 —— 典型成因是
    「多个事务同时 `INSERT IGNORE` 同一主键、再各自把共享行锁升级为排他行锁」。整个 push 是
    **可重放的幂等 LWW 合并**（同样的入参重放一次结果相同），所以按 MySQL 官方建议整事务重放：
    最多 `PUSH_MAX_ATTEMPTS` 次，仍失败才上抛 500。这不改变并发度，只是把被中止的事务再做一遍。
    """
    attempt = 0
    while True:
        attempt += 1
        try:
            return _push_once(
                db,
                user_id=user_id,
                device_id=device_id,
                last_sync_at=last_sync_at,
                tables=tables,
                client_now=client_now,
            )
        except OperationalError as exc:
            db.rollback()
            if attempt >= PUSH_MAX_ATTEMPTS or not _is_retryable_lock_error(exc):
                raise
            logger.warning(
                "sync push 并发锁冲突（%s），整事务重放第 %d/%d 次：user_id=%s",
                exc.orig,
                attempt,
                PUSH_MAX_ATTEMPTS,
                user_id,
            )


def _push_once(
    db: Session,
    *,
    user_id: str,
    device_id: str | None,
    last_sync_at: int,
    tables: Mapping[str, list[dict[str, Any]]],
    client_now: int | None = None,
) -> PushOutcome:
    """`push` 的单次执行（一次事务）：合并 → 计状态 → 写 `sync_log` → 提交。"""
    started_at = now_ms()
    outcome = PushOutcome()

    unknown = sorted(name for name in tables if name not in SYNC_MODES)
    if unknown:
        raise AppError(
            ErrorCode.INVALID_REQUEST,
            f"未知的同步表：{unknown}；参与同步的只有 {list(SYNC_TABLE_NAMES)}（附录 B §6.5）",
        )

    # 越权行整批拒绝：不允许把别的账号的行写进本账号，也不允许把本账号的行写到别人名下
    for name, rows in tables.items():
        if not isinstance(rows, list):
            raise AppError(ErrorCode.INVALID_REQUEST, f"tables.{name} 必须是行数组")
        for raw in rows:
            other = raw.get("user_id") if isinstance(raw, Mapping) else None
            if other is not None and str(other) != user_id:
                raise AppError(
                    ErrorCode.FORBIDDEN,
                    f"{name} 的行 user_id={other!r} 与令牌账号不一致，已整批拒绝（一行都不写）",
                )

    # 时钟：offset_ms = 服务端时钟 − 客户端时钟（§6.4-6 的「本机时钟 − 对端时钟」，本机 = 服务端）
    if client_now:
        outcome.offset_ms = started_at - int(client_now)
        if abs(outcome.offset_ms) > CLOCK_TOLERANCE_MS:
            outcome.clock_warning = (
                f"客户端时钟与服务端相差 {outcome.offset_ms / 1000:.1f} 秒，超出 ±5 分钟容差；"
                f"已按 offsetMs={outcome.offset_ms} 换算到服务端基准后继续合并（附录 B §6.4-6）"
            )
            outcome.note(outcome.clock_warning)
            outcome.status = "partial"

    for name, rows in tables.items():
        mode = SYNC_MODES[name]
        for raw in rows:
            values, error = normalize_row(name, raw, user_id=user_id, device_id=device_id)
            if error:
                outcome.rejected += 1
                outcome.note(error)
                continue
            if mode == MODE_APPEND_ONLY:
                _merge_append_only(db, name, user_id=user_id, values=values, outcome=outcome)
            else:
                _merge_lww(
                    db,
                    name,
                    user_id=user_id,
                    values=values,
                    last_sync_at=int(last_sync_at or 0),
                    offset_ms=outcome.offset_ms,
                    outcome=outcome,
                )

    if outcome.rejected and outcome.status == "success":
        outcome.status = "partial"
    # 不容错：`errors` 为空而 rejected > 0 只可能是漏写 note 的代码缺陷，用 `clock_warning or ...` 兜住，
    # 不让「记日志」这一步把整批同步打成 500。
    error_msg = outcome.clock_warning or (outcome.errors[0] if outcome.errors else None)
    write_sync_log(
        db,
        user_id=user_id,
        device_id=device_id,
        direction="push",
        status=outcome.status,
        pulled_count=0,
        pushed_count=outcome.accepted,
        conflict_count=outcome.conflicts,
        error_msg=error_msg,
        started_at=started_at,
    )
    db.commit()
    logger.info(
        "sync push user_id=%s device=%s accepted=%d ignored=%d rejected=%d conflicts=%d offset_ms=%d",
        user_id,
        device_id,
        outcome.accepted,
        outcome.ignored,
        outcome.rejected,
        outcome.conflicts,
        outcome.offset_ms,
    )
    return outcome


def _merge_append_only(db: Session, table_name: str, *, user_id: str, values: dict[str, Any], outcome: PushOutcome) -> None:
    """只增账本：同 id 或业务键已存在即跳过；**永不 UPDATE**（铁律 4）。"""
    table = Base.metadata.tables[table_name]
    found = db.execute(select(table).where(table.c.id == values["id"]).limit(1)).mappings().first()
    if found is not None:
        outcome.ignored += 1
        outcome.note(f"{table_name}.id={values['id']} 已存在，按键去重（不入第二次账）")
        return
    business = _find_business_key_row(db, table_name, user_id, values)
    if business is not None:
        outcome.ignored += 1
        outcome.note(f"{table_name} 业务唯一键 {business[0]} 已入账，跨设备重复已去重")
        return
    inserted = db.execute(mysql_insert(table).prefix_with("IGNORE").values(**values)).rowcount or 0
    if inserted:
        outcome.accepted += 1
        outcome.count(table_name)
        return
    kind, row = _diagnose_ignored(db, table_name, user_id, values)
    if kind == "foreign":
        outcome.rejected += 1
        outcome.status = "partial"
        outcome.note(
            f"{table_name}.id={values['id']} 被数据库唯一索引拒绝，但冲突行属于另一账号"
            f"（user_id={row['user_id'] if row else '?'}）—— 唯一索引缺少 user_id，见附录 B §2:142 与 sql/migrations/001"
        )
        return
    outcome.ignored += 1
    outcome.note(f"{table_name}.id={values['id']} 被唯一索引拒绝，已计入跨设备重复")


def _read_row_for_update(db: Session, table_name: str, *, row_id: str) -> dict[str, Any] | None:
    """当前读（`SELECT ... FOR UPDATE`）取一行的**最新已提交**版本。

    MySQL 默认 REPEATABLE READ：普通 `SELECT` 读的是事务开始时的快照，看不到并发事务刚提交的行。
    因此并发归因、以及「0 行 UPDATE」之后的回写，都必须用当前读 —— 否则回写出去的是过期版本，
    两端永远收敛不到一起（t61 的 S2 观测：16 并发重推同一行时快照归因落到 unknown）。
    """
    table = Base.metadata.tables[table_name]
    row = db.execute(select(table).where(table.c.id == row_id).with_for_update()).mappings().first()
    return dict(row) if row is not None else None


def _merge_lww(
    db: Session,
    table_name: str,
    *,
    user_id: str,
    values: dict[str, Any],
    last_sync_at: int,
    offset_ms: int,
    outcome: PushOutcome,
) -> None:
    """完整 LWW（附录 B §6.3）：`rUpdated > l.updatedAt` 取远端；相等比 deviceId 字典序；否则保留服务端版本。

    t63：并发下「比较 + 写入」必须原子化（见下方「方案①」），否则旧版本会覆盖新版本（丢更新）。
    """
    table = Base.metadata.tables[table_name]
    row_id = values["id"]
    existing = db.execute(select(table).where(table.c.id == row_id).limit(1)).mappings().first()

    if existing is None:
        business = _find_business_key_row(db, table_name, user_id, values)
        if business is not None:
            # 同业务键、不同 id（跨设备各买/各达成一次）→ 只保留一行，另一端按 merged 收敛
            outcome.ignored += 1
            outcome.note(f"{table_name} 业务唯一键 {business[0]} 已存在，跨设备重复已去重（id={row_id} 未写入）")
            outcome.merge_back(table_name, business[1])
            return
        inserted = db.execute(mysql_insert(table).prefix_with("IGNORE").values(**values)).rowcount or 0
        if inserted:
            outcome.accepted += 1
            outcome.count(table_name)
            return
        # 并发下 `INSERT IGNORE` 会被抢先（同 id 的另一个事务先提交、本事务只能忽略）→ 用**当前读**
        # 拿「最新已提交行」，再走下面的归属检查 + LWW 比较。只靠本事务快照归因，会把「其实已有别的
        # 版本」误判成「未识别冲突来源」计 rejected（t61 S2 实测：16 并发重推同一行时出现该归因）。
        existing = _read_row_for_update(db, table_name, row_id=row_id)
        if existing is None:
            kind, row = _diagnose_ignored(db, table_name, user_id, values)
            if kind == "duplicate":
                outcome.ignored += 1
                outcome.note(f"{table_name}.id={row_id} 命中已有行（业务唯一键），跨设备重复已去重")
                if row is not None:
                    outcome.merge_back(table_name, row)
                return
            if kind == "foreign":
                outcome.rejected += 1
                outcome.status = "partial"
                outcome.note(
                    f"{table_name}.id={row_id} 被数据库唯一索引拒绝，但冲突行属于另一账号"
                    f"（user_id={row['user_id'] if row else '?'}）—— 唯一索引缺少 user_id，见附录 B §2:142 与 sql/migrations/001"
                )
                return
            outcome.rejected += 1
            outcome.status = "partial"
            outcome.note(f"{table_name}.id={row_id} 写入被数据库拒绝（未识别冲突来源）")
            return
        # 当前读拿到了并发事务刚提交的行：继续走下面的归属检查与 LWW 比较（后续并发由 WHERE 把关）

    if existing["user_id"] != user_id:
        outcome.rejected += 1
        outcome.status = "partial"
        outcome.note(f"{table_name}.id={row_id} 已属于账号 {existing['user_id']}，拒绝覆盖")
        return

    # ── LWW：比较与写入原子化（t63「方案①」）──────────────────────────────────
    # 判据与改前逐字一致（含平局比 deviceId 字典序），但改由**同一条 UPDATE 的 WHERE** 求值：
    # `updated_at < :remote` 或（`updated_at = :remote` 且 `device_id < :remote_device`）。
    # 为什么不用「先 SELECT 比大小、再无条件 UPDATE」：两个并发事务会读到同一旧行、各自通过比较，
    # 后提交的**更旧**版本覆盖更新的版本（t61 实测 32 轮里 11 轮丢更新）。InnoDB 的 UPDATE 是当前读
    # （current read）并对命中行加行锁；把比较放进 WHERE 后，比较与写入由同一条语句、同一把锁完成，
    # 后到的事务在锁上等待、拿到锁后对「最新已提交版本」重新求值 WHERE，不满足即 0 行 ⇒ 不会降级覆盖。
    # 选它而不是 `SELECT ... FOR UPDATE` 整段锁行或 `INSERT ... ON DUPLICATE KEY UPDATE IF()`：
    # 少一次往返、不改事务隔离级别、也不必把平局规则抄成第二种写法。
    remote_updated = int(values["updated_at"]) + offset_ms  # 对端时间 → 服务端基准
    remote_device = str(values.get("device_id") or "")
    local_updated = int(existing["updated_at"])  # 快照值：只喂「真冲突」计数（与改前同一条件）

    written = _apply_update(
        db,
        table_name,
        row_id=row_id,
        user_id=user_id,
        values=values,
        if_newer_than=(remote_updated, remote_device),
    )
    if written:
        outcome.accepted += 1
        outcome.count(table_name)
        if local_updated > last_sync_at and int(values["updated_at"]) > last_sync_at:
            outcome.conflicts += 1
        return

    # 0 行 = 有人把该行推进到了「不低于远端」的版本（或远端本来就旧 / 平局不占优）。
    # 用当前读取最新已提交行来归类与回写：过期的快照回写会让两端永远收敛不到一起。
    current = _read_row_for_update(db, table_name, row_id=row_id) or existing
    current_updated = int(current["updated_at"])
    current_device = str(current.get("device_id") or "")
    if remote_updated == current_updated and remote_device <= current_device:
        # deviceId 相同 = 同一版本；deviceId 更小 = 对端该让位 → 都保留服务端版本
        outcome.ignored += 1
        outcome.note(
            f"{table_name}.id={row_id} 与已有行同一版本（deviceId={remote_device or '(空)'}），"
            f"按键去重，保留服务端版本并回写"
        )
        outcome.merge_back(table_name, current)
        return

    # 远端更旧：保留服务端版本，并让客户端回写（否则两端不收敛）
    outcome.rejected += 1
    outcome.note(f"{table_name}.id={row_id} 比服务端版本旧，保留服务端版本并回写（不做降级覆盖）")
    outcome.merge_back(table_name, current)


def _apply_update(
    db: Session,
    table_name: str,
    *,
    row_id: str,
    user_id: str,
    values: Mapping[str, Any],
    if_newer_than: tuple[int, str] | None = None,
) -> int:
    """写入 LWW 胜出版本，返回真正写入的行数（0 = 比较没通过，行已被「不低于远端」的版本占住）。

    `if_newer_than=(服务端基准 updated_at, device_id)` 把 §6.3 的比较条件推进 `UPDATE ... WHERE`，
    让「比较 + 写入」在同一条语句、同一把行锁里完成（见 `_merge_lww` 的「方案①」）。
    """
    table = Base.metadata.tables[table_name]
    payload = {name: value for name, value in values.items() if name != "id"}
    payload["user_id"] = user_id
    statement = table.update().where(table.c.id == row_id, table.c.user_id == user_id)
    if if_newer_than is not None:
        remote_updated, remote_device = if_newer_than
        # 平局规则（附录 B §6.3）：updated_at 相等时 device_id 字典序大者胜；NULL 视为空串
        statement = statement.where(
            or_(
                table.c.updated_at < remote_updated,
                and_(
                    table.c.updated_at == remote_updated,
                    func.coalesce(table.c.device_id, "") < remote_device,
                ),
            )
        )
    return int(db.execute(statement.values(**payload)).rowcount or 0)


# --------------------------------------------------------------------------- #
# pull / status
# --------------------------------------------------------------------------- #
def pull(db: Session, *, user_id: str, since: int) -> dict[str, Any]:
    """拉取增量：9 张表里 `updated_at > since` 的行（含软删除行，让删除能传播）。"""
    started_at = now_ms()
    tables: dict[str, list[dict[str, Any]]] = {}
    total = 0
    for name in SYNC_TABLE_NAMES:
        table = Base.metadata.tables[name]
        rows = (
            db.execute(
                select(table)
                .where(table.c.user_id == user_id, table.c.updated_at > int(since))
                .order_by(table.c.updated_at, table.c.id)
            )
            .mappings()
            .all()
        )
        tables[name] = [dict(row) for row in rows]
        total += len(rows)
    write_sync_log(
        db,
        user_id=user_id,
        device_id=None,
        direction="pull",
        status="success",
        pulled_count=total,
        pushed_count=0,
        conflict_count=0,
        error_msg=None,
        started_at=started_at,
    )
    db.commit()
    return {"tables": tables, "serverTime": now_ms(), "since": int(since)}


def status(db: Session, *, user_id: str) -> dict[str, Any]:
    """云端统计：各表条数 / 软删除数 / 最后更新时间 + 出现过的 device_id + 最近一次同步日志。"""
    stats: list[dict[str, Any]] = []
    total_rows = 0
    devices: set[str] = set()
    for name in SYNC_TABLE_NAMES:
        table = Base.metadata.tables[name]
        count, deleted, last_updated = db.execute(
            select(
                func.count(),
                func.coalesce(func.sum(case((table.c.is_deleted == 1, 1), else_=0)), 0),
                func.coalesce(func.max(table.c.updated_at), 0),
            ).where(table.c.user_id == user_id)
        ).one()
        stats.append(
            {"name": name, "count": int(count), "deletedCount": int(deleted), "lastUpdatedAt": int(last_updated)}
        )
        total_rows += int(count)
        for (device_id,) in db.execute(
            select(table.c.device_id).where(table.c.user_id == user_id, table.c.device_id.is_not(None)).distinct()
        ).all():
            if device_id:
                devices.add(str(device_id))

    last = db.execute(
        select(SyncLog).where(SyncLog.user_id == user_id).order_by(SyncLog.started_at.desc(), SyncLog.id.desc()).limit(1)
    ).scalar_one_or_none()
    return {
        "userId": user_id,
        "serverTime": now_ms(),
        "totalRows": total_rows,
        "tables": stats,
        "devices": sorted(devices),
        "lastSync": None
        if last is None
        else {
            "direction": last.direction,
            "status": last.status,
            "pushedCount": last.pushed_count,
            "pulledCount": last.pulled_count,
            "conflictCount": last.conflict_count,
            "errorMsg": last.error_msg,
            "startedAt": last.started_at,
            "finishedAt": last.finished_at,
        },
    }


# --------------------------------------------------------------------------- #
# sync_log
# --------------------------------------------------------------------------- #
def write_sync_log(
    db: Session,
    *,
    user_id: str,
    device_id: str | None,
    direction: str,
    status: str,
    pulled_count: int,
    pushed_count: int,
    conflict_count: int,
    error_msg: str | None,
    started_at: int,
) -> None:
    """写一行服务端 `sync_log`（附录 B §2 表 16；客户端另有一张同名的本机日志表）。"""
    db.add(
        SyncLog(
            id=str(uuid.uuid4()),
            user_id=user_id,
            peer_device=device_id,
            direction=direction,
            status=status,
            pulled_count=pulled_count,
            pushed_count=pushed_count,
            conflict_count=conflict_count,
            error_msg=error_msg,
            started_at=started_at,
            finished_at=now_ms(),
            created_at=started_at,
        )
    )


__all__ = [
    "BUSINESS_KEYS",
    "CLOCK_TOLERANCE_MS",
    "MODE_APPEND_ONLY",
    "MODE_LWW",
    "SINGLETON_TABLES",
    "SYNC_MODES",
    "PushOutcome",
    "normalize_row",
    "pull",
    "push",
    "status",
    "table_columns",
    "write_sync_log",
]
