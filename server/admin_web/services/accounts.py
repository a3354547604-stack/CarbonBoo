"""① 管理员账号（`admin_user`）—— 登录、改密码、首次引导、命令行找回。

口径（PLAN §13.2 ①/§13.1、附录 B §3/§5.4、AGENTS §6）
-------------------------------------------------------
* 管理员账号**独立于任何用户体系**：`admin_user` 与 `server_user` 之间没有任何外键关系，
  后台看得到用户数据、用户数据里看不到后台。
* 登录成功签发**管理侧独立 JWT**（密钥 ② + audience ②，见 `app.core.security.create_admin_token`）；
  本模块不自己拼 JWT，也不碰客户端密钥。
* **口令只以 bcrypt 哈希落库**（`app.core.security.hash_password`），日志/审计里只记"改过"。
* 首次引导：`admin_user` 表为空 且 `ADMIN_BOOTSTRAP_USERNAME/PASSWORD` 已配置且匹配时，
  才创建首个管理员（这条路径在表非空后彻底失效）。引导与命令行创建**共用** `create_admin()`。
* 改密码要求提供**旧口令**（防止拿到一个未过期的令牌就能永久占号）。
"""

from __future__ import annotations

import logging
import uuid
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.config import Settings
from app.core.errors import AppError, ErrorCode
from app.core.security import create_admin_token, hash_password, now_ms, verify_password
from app.models import AdminUser

from admin_web.config import AdminWebSettings
from admin_web.security import validate_admin_password, validate_admin_username
from admin_web.services import audit
from admin_web.services.base import transaction

logger = logging.getLogger("carbonboo.admin.accounts")


def count_admins(db: Session) -> int:
    """管理员总数（首次引导的判定依据）。"""
    return int(db.execute(select(func.count()).select_from(AdminUser)).scalar_one())


def get_admin(db: Session, admin_id: str) -> AdminUser | None:
    return db.execute(select(AdminUser).where(AdminUser.id == admin_id)).scalar_one_or_none()


def get_admin_by_username(db: Session, username: str) -> AdminUser | None:
    return db.execute(select(AdminUser).where(AdminUser.username == username)).scalar_one_or_none()


def create_admin(
    db: Session,
    *,
    username: str,
    password: str,
    settings: Settings,
    ip: str | None = None,
    operator_action: str = audit.ACTION_BOOTSTRAP_ADMIN,
    reset: bool = False,
) -> AdminUser:
    """创建（或 `reset=True` 时重置口令）管理员。强口令与用户名规则在这里强制执行。

    单事务：写 `admin_user` + 写审计（`bootstrap_admin` / `change_password`）。
    """
    validate_admin_username(username, settings)
    validate_admin_password(password, username=username)

    with transaction(db):
        existing = get_admin_by_username(db, username)
        if existing is not None and not reset:
            raise AppError(ErrorCode.INVALID_REQUEST, f"管理员用户名已存在：{username}")
        if existing is not None:
            existing.password_hash = hash_password(password)
            row = existing
        else:
            row = AdminUser(
                id=str(uuid.uuid4()),
                username=username,
                password_hash=hash_password(password),
                created_at=now_ms(),
                last_login_at=None,
            )
            db.add(row)
        db.flush()
        audit.write_op_log(
            db,
            admin_id=row.id,
            action=operator_action,
            target_type="admin",
            target_id=row.id,
            detail={"username": row.username, "reset": bool(existing is not None)},
            ip=ip,
        )
    return row


def ensure_bootstrap_admin(
    db: Session, *, settings: Settings, admin_settings: AdminWebSettings, ip: str | None = None
) -> AdminUser | None:
    """表为空且环境变量给了引导凭据时，惰性创建首个管理员；否则返回 None。

    为什么惰性（登录时才建）而不是启动时建：后台是**可选件**，缺库/缺权限都不能影响
    客户端 API（`app/main.py` 的挂载点必须是"挂了也不炸"）。登录那一刻库一定可用。
    """
    if count_admins(db) > 0 or not admin_settings.has_bootstrap_credentials:
        return None
    username = admin_settings.bootstrap_username.strip()
    logger.warning(
        "admin_user 为空且检测到 ADMIN_BOOTSTRAP_USERNAME：创建首个管理员 %s（该引导路径随后失效）",
        username,
    )
    return create_admin(
        db,
        username=username,
        password=admin_settings.bootstrap_password,
        settings=settings,
        ip=ip,
        operator_action=audit.ACTION_BOOTSTRAP_ADMIN,
    )


def login(
    db: Session,
    *,
    username: str,
    password: str,
    settings: Settings,
    admin_settings: AdminWebSettings,
    ip: str | None = None,
) -> dict[str, Any]:
    """管理员登录：校验口令 → 记 `last_login_at` → 写审计 → 签发管理端令牌。

    失败一律 401 `CREDENTIAL_INVALID`（不区分"用户名不存在"与"口令错误"，避免账号枚举）。
    """
    ensure_bootstrap_admin(db, settings=settings, admin_settings=admin_settings, ip=ip)

    if count_admins(db) == 0:
        # 表为空且没配引导凭据：与其报"口令错误"（让人以为是自己记错了），不如直接说清怎么初始化
        raise AppError(
            ErrorCode.CREDENTIAL_INVALID,
            "后台尚未初始化管理员：请配置 ADMIN_BOOTSTRAP_USERNAME / ADMIN_BOOTSTRAP_PASSWORD，"
            "或执行 python -m admin_web.cli create-admin --username <名字>",
        )

    admin = get_admin_by_username(db, username)
    if admin is None or not verify_password(password, admin.password_hash):
        raise AppError(ErrorCode.CREDENTIAL_INVALID, "管理员用户名或口令错误")

    with transaction(db):
        admin.last_login_at = now_ms()
        audit.write_op_log(
            db,
            admin_id=admin.id,
            action=audit.ACTION_LOGIN,
            target_type="admin",
            target_id=admin.id,
            detail={"username": admin.username},
            ip=ip,
        )

    token, expires_at = create_admin_token(admin.id, admin.username, settings)
    return {
        "adminToken": token,
        "adminId": admin.id,
        "username": admin.username,
        "expiresAt": expires_at,
    }


def change_password(
    db: Session,
    *,
    admin_id: str,
    old_password: str,
    new_password: str,
    ip: str | None = None,
) -> None:
    """改密码（附录 D10-1：改完旧密码即时失效）。"""
    admin = get_admin(db, admin_id)
    if admin is None:
        # 令牌合法但管理员行没了（被手工删库）：按未授权处理，不假装成功
        raise AppError(ErrorCode.TOKEN_INVALID, "管理员账号不存在，请重新登录")
    if not verify_password(old_password, admin.password_hash):
        raise AppError(ErrorCode.CREDENTIAL_INVALID, "当前口令不正确")
    if verify_password(new_password, admin.password_hash):
        raise AppError(ErrorCode.PASSWORD_INVALID, "新口令不能与当前口令相同")
    validate_admin_password(new_password, username=admin.username)

    with transaction(db):
        admin.password_hash = hash_password(new_password)
        audit.write_op_log(
            db,
            admin_id=admin.id,
            action=audit.ACTION_CHANGE_PASSWORD,
            target_type="admin",
            target_id=admin.id,
            # 只记"改过"，永不记口令或其哈希（AGENTS §6）
            detail={"username": admin.username, "changed": True},
            ip=ip,
        )
    logger.info("管理员 %s 已改密码", admin.username)


def write_logout_log(db: Session, *, admin_id: str, username: str, ip: str | None = None) -> None:
    """登出也留痕（服务端无状态，只记一条）。"""
    with transaction(db):
        audit.write_op_log(
            db,
            admin_id=admin_id,
            action=audit.ACTION_LOGOUT,
            target_type="admin",
            target_id=admin_id,
            detail={"username": username},
            ip=ip,
        )


__all__ = [
    "change_password",
    "count_admins",
    "create_admin",
    "ensure_bootstrap_admin",
    "get_admin",
    "get_admin_by_username",
    "login",
    "write_logout_log",
]
