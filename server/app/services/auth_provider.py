"""登录/账号的提供方抽象与实现（`local` 已实现，`server` / `huaweiId` 预留）。

契约来源
--------
docs/APPENDIX-B-data-and-api.md §7.1（冻结的接口契约，六个方法：isAvailable / register / login /
logout / currentSession / deleteAccount）+ docs/adr/0001-account-and-sync.md + AGENTS.md §6。

客户端版本的方法是无参的（客户端自己持有当前会话）；服务端是**无状态**的，调用方身份由 JWT 传入，
因此服务端同形接口把身份显式作为参数 —— `logout(session)` / `current_session(token)` /
`delete_account(token, password)`。能力集合与 §7.1 完全一致，这正是「上层不直接依赖具体 provider」的那道缝：
api 层只 import 本模块的 `AuthProvider` 抽象与 `get_auth_provider` 依赖，永远不 import `LocalAuthProvider`。

注销口径（用户拍板 / ADR-0001 决策 ③，B35 契约）：**云端数据软删除 + 保留 30 天 + 期内可恢复**
------------------------------------------------------------------------------
* `DELETE /auth/account`：把该账号在 9 张同步表里 `is_deleted=0` 的行置 1（`updated_at` 统一写成同一毫秒），
  `server_user.is_active=0`，并写 `admin_op_log(action=account_delete, detail={deletedRows, deletionTs, graceDays})`。
* 保留期内用**同一用户名 + 相同口令**登录 → 自动恢复：把这些行置回 `is_deleted=0`、`is_active=1`，
  写 `action=account_restore`（恢复后这些行的 `updated_at` 已变 → 客户端同步会上行一版）；
  注销后旧令牌立即失效（`current_session` 发现 `is_active=0` 即 401）。
* 超过 30 天 → 物理清除（该账号在 9 张表的行 + `server_user` 行；`admin_op_log` 审计留痕）：
  发生在 (a) 同一用户名再次登录（惰性）与 (b) 运维调用 `purge_expired_accounts()`（见文件末 `__main__`）。

运维入口：`python -m app.services.auth_provider`（或 `purge_expired_accounts()`）执行超期物理清除。
"""

from __future__ import annotations

import json
import logging
import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Annotated

from fastapi import Depends
from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.config import PROVIDER_IDS, Settings, get_settings
from app.core.database import get_db, get_sessionmaker
from app.core.errors import AppError, ErrorCode, ProviderNotImplementedError
from app.core.security import (
    create_user_token,
    decode_user_token,
    hash_password,
    now_ms,
    validate_password,
    validate_username,
    verify_password,
)
from app.models import ACCOUNT_DATA_TABLE_NAMES, AdminOpLog, Base, ServerUser
from app.models.account import ACTION_ACCOUNT_DELETE, ACTION_ACCOUNT_PURGE, ACTION_ACCOUNT_RESTORE

logger = logging.getLogger("carbonboo.server.auth")

_MS_PER_DAY = 86_400_000

#: 审计表里账号生命周期的目标类型（admin_op_log.target_type）
TARGET_TYPE_SERVER_USER = "server_user"


# --------------------------------------------------------------------------- #
# 返回值
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class AuthSession:
    """一次已建立的会话（对应 §7.1 的 `AuthSession`）。"""

    user_id: str
    username: str
    provider_id: str
    token: str
    expires_at: int  # 毫秒


# --------------------------------------------------------------------------- #
# 抽象
# --------------------------------------------------------------------------- #
class AuthProvider(ABC):
    """身份提供方抽象（六方法契约，见模块头注释）。"""

    #: 提供方标识：local | server | huaweiId
    id: str = ""

    @abstractmethod
    def is_available(self) -> bool:
        """当前环境是否可用（local = 数据库可达）。"""

    @abstractmethod
    def register(self, username: str | None, password: str | None) -> AuthSession:
        """注册新账号并直接返回会话。用户名为空 → USERNAME_INVALID；口令不合法 → PASSWORD_INVALID。"""

    @abstractmethod
    def login(self, username: str | None, password: str | None) -> AuthSession:
        """口令登录（注销保留期内同口令登录 = 恢复账号）。凭据错误一律 CREDENTIAL_INVALID。"""

    @abstractmethod
    def logout(self, session: AuthSession) -> None:
        """登出。服务端无状态：不维护会话表，令牌自然到期。"""

    @abstractmethod
    def current_session(self, token: str) -> AuthSession:
        """校验令牌并确认账号仍然有效；失效 / 已注销 → TOKEN_INVALID。"""

    @abstractmethod
    def delete_account(self, token: str, password: str | None) -> int:
        """注销账号（软删除 + 30 天保留），返回物理清除时间点（毫秒）。"""


# --------------------------------------------------------------------------- #
# local 实现
# --------------------------------------------------------------------------- #
def _load_user_by_username(db: Session, username: str) -> ServerUser | None:
    return db.execute(select(ServerUser).where(ServerUser.username == username)).scalar_one_or_none()


def _load_user_by_user_id(db: Session, user_id: str) -> ServerUser | None:
    return db.execute(select(ServerUser).where(ServerUser.user_id == user_id)).scalar_one_or_none()


def _insert_op_log(
    db: Session,
    *,
    admin_id: str,
    action: str,
    target_id: str | None,
    detail: dict[str, object] | None = None,
    ip: str | None = None,
    created_at: int | None = None,
) -> None:
    """写一条 admin_op_log（账号生命周期与运营操作共用一张审计表）。

    `created_at` 可显式传入：注销时必须与"给数据行盖的时间戳"**同一个毫秒值**，
    恢复逻辑正是用 `updated_at == 注销时间戳` 精确认出"注销时打标的那批行"
    （见 `_set_data_deleted(only_row_ts=...)`），两次取 `now_ms()` 会差几毫秒而永远匹配不上。
    """
    db.add(
        AdminOpLog(
            id=str(uuid.uuid4()),
            admin_id=admin_id,
            action=action,
            target_type=TARGET_TYPE_SERVER_USER,
            target_id=target_id,
            detail=json.dumps(detail, ensure_ascii=False) if detail else None,
            ip=ip,
            created_at=now_ms() if created_at is None else created_at,
        )
    )


def _latest_lifecycle_op(db: Session, user_id: str) -> AdminOpLog | None:
    """取该账号最近一条生命周期记录（account_delete / account_restore）。

    查 `target_id`（= 云端归属键 `server_user.user_id`）而不是 `admin_id`：
    `admin_op_log.admin_id` 是 NOT NULL 的"操作者"列，账号注销/恢复的操作者就是账号行自身
    （写的是 `server_user.id`，与 `user_id` 是两个不同的 UUID）；账号在云端语境下的身份是 `user_id`，
    因此生命周期回溯一律按 `target_id + target_type` 匹配。
    """
    return db.execute(
        select(AdminOpLog)
        .where(
            AdminOpLog.target_id == user_id,
            AdminOpLog.target_type == TARGET_TYPE_SERVER_USER,
            AdminOpLog.action.in_([ACTION_ACCOUNT_DELETE, ACTION_ACCOUNT_RESTORE]),
        )
        .order_by(AdminOpLog.created_at.desc(), AdminOpLog.id.desc())
        .limit(1)
    ).scalar_one_or_none()


def _set_data_deleted(db: Session, user_id: str, *, deleted: bool, timestamp: int, only_row_ts: int | None = None) -> int:
    """把该账号在 9 张同步表里的行统一置为 deleted / restored，返回受影响行数。"""
    rows = 0
    for table_name in ACCOUNT_DATA_TABLE_NAMES:
        table = Base.metadata.tables[table_name]
        conditions = [table.c.user_id == user_id, table.c.is_deleted == (0 if deleted else 1)]
        if only_row_ts is not None:
            conditions.append(table.c.updated_at == only_row_ts)
        result = db.execute(
            table.update().where(*conditions).values(is_deleted=1 if deleted else 0, updated_at=timestamp)
        )
        rows += result.rowcount or 0
    return rows


class LocalAuthProvider(AuthProvider):
    """自建账号体系（用户名 + bcrypt 口令 + JWT）。数据库不可达时 `is_available()` 为 False。"""

    id = "local"

    def __init__(self, db: Session, settings: Settings | None = None) -> None:
        self._db = db
        self._settings = settings or get_settings()

    # ---------- 可用性 ----------
    def is_available(self) -> bool:
        try:
            self._db.execute(text("SELECT 1"))
            return True
        except Exception:  # pragma: no cover - 仅在数据库宕机时命中
            logger.warning("local 身份提供方不可用：数据库不可达")
            return False

    # ---------- 注册 ----------
    def register(self, username: str | None, password: str | None) -> AuthSession:
        username = validate_username(username or "", self._settings)
        password = validate_password(password or "", self._settings)
        if _load_user_by_username(self._db, username) is not None:
            raise AppError(ErrorCode.USERNAME_TAKEN, "该用户名已被占用")

        timestamp = now_ms()
        user = ServerUser(
            id=str(uuid.uuid4()),
            # userId 用 "u-" 前缀（与附录 B §5.2 示例 "u-..." 同形），"u-"+32hex = 34 字符，落在 VARCHAR(36) 内
            user_id=f"u-{uuid.uuid4().hex}",
            username=username,
            password_hash=hash_password(password),
            created_at=timestamp,
            last_login_at=timestamp,
            is_active=1,
        )
        self._db.add(user)
        try:
            self._db.commit()
        except IntegrityError as exc:  # 并发注册同名：唯一索引兜底
            self._db.rollback()
            raise AppError(ErrorCode.USERNAME_TAKEN, "该用户名已被占用") from exc

        token, expires_at = create_user_token(user.user_id, user.username, self._settings)
        return AuthSession(
            user_id=user.user_id,
            username=user.username,
            provider_id=self.id,
            token=token,
            expires_at=expires_at,
        )

    # ---------- 登录 ----------
    def login(self, username: str | None, password: str | None) -> AuthSession:
        user = _load_user_by_username(self._db, username or "")
        invalid = AppError(ErrorCode.CREDENTIAL_INVALID, "用户名或口令错误")
        if user is None or not verify_password(password or "", user.password_hash):
            raise invalid

        if not user.is_active and not self._restore_if_within_grace(user):
            raise invalid

        user.last_login_at = now_ms()
        self._db.commit()
        token, expires_at = create_user_token(user.user_id, user.username, self._settings)
        return AuthSession(
            user_id=user.user_id,
            username=user.username,
            provider_id=self.id,
            token=token,
            expires_at=expires_at,
        )

    # ---------- 登出 ----------
    def logout(self, session: AuthSession) -> None:
        # 服务端无状态：不落库。令牌到期即失效（AGENTS §6「服务端地址..」同一取向：不做会话表）。
        logger.debug("logout user_id=%s（无状态，无需服务端动作）", session.user_id)

    # ---------- 会话校验 ----------
    def current_session(self, token: str) -> AuthSession:
        claims = decode_user_token(token, self._settings)
        user = _load_user_by_user_id(self._db, str(claims.get("sub", "")))
        if user is None or not user.is_active:
            raise AppError(ErrorCode.TOKEN_INVALID, "账号不存在或已注销，请重新登录")
        return AuthSession(
            user_id=user.user_id,
            username=user.username,
            provider_id=self.id,
            token=token,
            expires_at=int(claims.get("exp", 0)) * 1000,
        )

    # ---------- 注销 ----------
    def delete_account(self, token: str, password: str | None) -> int:
        session = self.current_session(token)
        user = _load_user_by_user_id(self._db, session.user_id)
        if user is None:
            raise AppError(ErrorCode.TOKEN_INVALID, "账号不存在或已注销，请重新登录")
        if not verify_password(password or "", user.password_hash):
            raise AppError(ErrorCode.CREDENTIAL_INVALID, "口令错误，无法注销账号")

        grace_days = self._settings.account_purge_grace_days
        deletion_ts = now_ms()
        rows = _set_data_deleted(self._db, user.user_id, deleted=True, timestamp=deletion_ts)
        user.is_active = 0
        _insert_op_log(
            self._db,
            admin_id=user.id,
            action=ACTION_ACCOUNT_DELETE,
            target_id=user.user_id,
            detail={
                "deletedRows": rows,
                "deletionTs": deletion_ts,
                "graceDays": grace_days,
                "tables": list(ACCOUNT_DATA_TABLE_NAMES),
            },
            created_at=deletion_ts,
        )
        self._db.commit()
        logger.info("账号注销（软删除）user_id=%s rows=%d 保留 %d 天", user.user_id, rows, grace_days)
        return deletion_ts + grace_days * _MS_PER_DAY

    # ---------- 内部：保留期内恢复 / 超期惰性清除 ----------
    def _restore_if_within_grace(self, user: ServerUser) -> bool:
        op = _latest_lifecycle_op(self._db, user.user_id)
        if op is None:  # 没有注销记录却已停用：异常态，不擅自恢复
            return False
        grace_ms = self._settings.account_purge_grace_days * _MS_PER_DAY
        if now_ms() - op.created_at > grace_ms:
            _purge_account(self._db, user, reason="超过保留期，登录时惰性清除")
            self._db.commit()
            return False
        restore_ts = now_ms()
        rows = _set_data_deleted(self._db, user.user_id, deleted=False, timestamp=restore_ts, only_row_ts=op.created_at)
        user.is_active = 1
        _insert_op_log(
            self._db,
            admin_id=user.id,
            action=ACTION_ACCOUNT_RESTORE,
            target_id=user.user_id,
            detail={"restoredRows": rows, "deletedAt": op.created_at, "restoredTs": restore_ts},
        )
        logger.info("账号在保留期内恢复 user_id=%s rows=%d", user.user_id, rows)
        return True


def _purge_account(db: Session, user: ServerUser, *, reason: str) -> int:
    """物理清除一个账号的云端数据与账号行（审计表保留）。"""
    rows = 0
    for table_name in ACCOUNT_DATA_TABLE_NAMES:
        table = Base.metadata.tables[table_name]
        result = db.execute(table.delete().where(table.c.user_id == user.user_id))
        rows += result.rowcount or 0
    _insert_op_log(
        db,
        admin_id=user.id,
        action=ACTION_ACCOUNT_PURGE,
        target_id=user.user_id,
        detail={"purgedRows": rows, "reason": reason, "tables": list(ACCOUNT_DATA_TABLE_NAMES)},
    )
    db.delete(user)
    logger.info("账号物理清除 user_id=%s rows=%d reason=%s", user.user_id, rows, reason)
    return rows


def purge_expired_accounts(db: Session | None = None) -> int:
    """物理清除所有「注销已超过保留期」的账号，返回清除的账号数（运维入口 / 定时任务）。"""
    owns_session = db is None
    session = db or get_sessionmaker()()
    settings = get_settings()
    grace_ms = settings.account_purge_grace_days * _MS_PER_DAY
    removed = 0
    try:
        inactive_users = session.execute(select(ServerUser).where(ServerUser.is_active == 0)).scalars().all()
        for user in inactive_users:
            op = _latest_lifecycle_op(session, user.user_id)
            if op is None or op.action != ACTION_ACCOUNT_DELETE:
                continue  # 已恢复或记录缺失：不动
            if now_ms() - op.created_at > grace_ms:
                _purge_account(session, user, reason="保留期届满（运维批量清除）")
                removed += 1
        session.commit()
    finally:
        if owns_session:
            session.close()
    return removed


# --------------------------------------------------------------------------- #
# 预留提供方
# --------------------------------------------------------------------------- #
class _ReservedAuthProvider(AuthProvider):
    """预留槽位：保证 `AUTH_PROVIDER=server|huaweiId` 时**响亮失败**而不是静默降级。"""

    def is_available(self) -> bool:
        return False

    def _raise(self) -> None:
        raise ProviderNotImplementedError(self.id)

    def register(self, username: str | None, password: str | None) -> AuthSession:
        self._raise()

    def login(self, username: str | None, password: str | None) -> AuthSession:
        self._raise()

    def logout(self, session: AuthSession) -> None:
        self._raise()

    def current_session(self, token: str) -> AuthSession:
        self._raise()

    def delete_account(self, token: str, password: str | None) -> int:
        self._raise()


class ServerAuthProvider(_ReservedAuthProvider):
    """预留：把身份交给远端账号服务（B §7.1 的 server 模式）。"""

    id = "server"


class HuaweiAuthProvider(_ReservedAuthProvider):
    """预留：华为账号（Account Kit）。AGENTS §6 明确**不做**，但保留槽位以便将来接入。"""

    id = "huaweiId"


#: 提供方注册表（键必须是 config.PROVIDER_IDS 的子集）
PROVIDERS: dict[str, type[AuthProvider]] = {
    "local": LocalAuthProvider,
    "server": ServerAuthProvider,
    "huaweiId": HuaweiAuthProvider,
}

assert set(PROVIDERS) == set(PROVIDER_IDS), "PROVIDERS 与 config.PROVIDER_IDS 必须一致"


def build_provider(provider_id: str, db: Session, settings: Settings | None = None) -> AuthProvider:
    """按配置构造提供方实例（api 层请改用 `get_auth_provider` 依赖）。"""
    provider_cls = PROVIDERS.get(provider_id)
    if provider_cls is None:
        raise AppError(ErrorCode.SERVER_ERROR, f"未知 AUTH_PROVIDER：{provider_id}")
    if provider_cls is LocalAuthProvider:
        return LocalAuthProvider(db, settings)
    return provider_cls()


def get_auth_provider(
    db: Annotated[Session, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> AuthProvider:
    """FastAPI 依赖：解析当前生效的身份提供方（api 层只需要这一个名字）。"""
    return build_provider(settings.auth_provider, db, settings)


__all__ = [
    "AuthProvider",
    "AuthSession",
    "HuaweiAuthProvider",
    "LocalAuthProvider",
    "PROVIDERS",
    "ServerAuthProvider",
    "build_provider",
    "get_auth_provider",
    "purge_expired_accounts",
]


if __name__ == "__main__":  # pragma: no cover - 运维入口
    # 用法：cd server && python -m app.services.auth_provider
    _count = purge_expired_accounts()
    _stamp = datetime.now(timezone.utc).isoformat()
    print(f"[{_stamp}] purge_expired_accounts: 物理清除 {_count} 个超期账号")
    print(f"保留期：{get_settings().account_purge_grace_days} 天（timedelta={timedelta(days=get_settings().account_purge_grace_days)}）")
