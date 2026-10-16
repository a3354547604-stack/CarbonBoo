"""后台管理端命令行入口：创建 / 重置管理员账号（含忘记口令的找回路径）。

用法（在 `server/` 目录下）
--------------------------
    # 创建首个管理员（口令交互输入，不回显、不进 shell 历史）
    .venv/bin/python -m admin_web.cli create-admin --username carbonboo_admin

    # 忘记口令时重置（同一用户名，加 --reset）
    .venv/bin/python -m admin_web.cli create-admin --username carbonboo_admin --reset

    # 列出已有管理员（只看用户名与时间，不输出任何哈希）
    .venv/bin/python -m admin_web.cli list-admins

为什么需要它
------------
`admin_user` 的创建只有两条路径，且共用同一个服务函数（`services/accounts.create_admin`）：
① 首次登录时的环境变量引导（表为空 + `ADMIN_BOOTSTRAP_USERNAME/PASSWORD`）；
② 本命令行 —— 管理员忘记口令时**唯一**的正规找回方式（否则只能手工改库）。
两条路径都强制同一套强口令策略（≥12 位、≥3 类字符、非常见弱口令）。
"""

from __future__ import annotations

import argparse
import getpass
import logging
import sys

from sqlalchemy import select

from app.core.config import get_settings
from app.core.database import get_sessionmaker
from app.core.errors import AppError
from app.models import AdminUser

from admin_web.security import password_policy_problems
from admin_web.services import accounts

logger = logging.getLogger("carbonboo.admin.cli")

#: CLI 创建管理员时写的审计动作（与"环境变量引导"区分，便于回溯是谁加的账号）
ACTION_CLI_CREATE = "bootstrap_admin"


def _prompt_password(username: str) -> str:
    """交互式读口令（两次输入一致性校验 + 强口令预检，避免提交后才被服务层拒绝）。"""
    while True:
        password = getpass.getpass("管理员口令（≥12 位、≥3 类字符，输入不回显）：")
        problems = password_policy_problems(password)
        if password.lower() == username.lower():
            problems.append("不得与用户名相同")
        if problems:
            print("  口令不符合要求：" + "；".join(problems), file=sys.stderr)
            continue
        if password != getpass.getpass("再输入一次："):
            print("  两次输入不一致，请重来", file=sys.stderr)
            continue
        return password


def cmd_create_admin(args: argparse.Namespace) -> int:
    settings = get_settings()
    password = args.password or _prompt_password(args.username)

    session = get_sessionmaker()()
    try:
        admin = accounts.create_admin(
            session,
            username=args.username,
            password=password,
            settings=settings,
            ip="cli",
            operator_action=ACTION_CLI_CREATE,
            reset=args.reset,
        )
        action = "已重置口令" if args.reset else "已创建"
        print(f"{action}：{admin.username}（id={admin.id}）")
        return 0
    except AppError as exc:
        print(f"失败：{exc.message}", file=sys.stderr)
        return 1
    finally:
        session.close()


def cmd_list_admins(_: argparse.Namespace) -> int:
    session = get_sessionmaker()()
    try:
        rows = session.execute(select(AdminUser).order_by(AdminUser.created_at)).scalars().all()
        if not rows:
            print("（还没有管理员账号）")
            return 0
        for row in rows:
            last = row.last_login_at or "从未登录"
            print(f"{row.username}\tid={row.id}\tcreated_at={row.created_at}\tlast_login_at={last}")
        return 0
    finally:
        session.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m admin_web.cli", description="CarbonBoo 后台管理端运维命令")
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create-admin", help="创建管理员；--reset 时重置已有账号的口令")
    create.add_argument("--username", required=True, help="管理员用户名（4–20 位字母/数字/下划线）")
    create.add_argument("--password", default="", help="口令；省略则交互输入（不建议写在命令行）")
    create.add_argument("--reset", action="store_true", help="账号已存在时重置口令而不是报错")
    create.set_defaults(func=cmd_create_admin)

    listing = sub.add_parser("list-admins", help="列出管理员账号（不输出任何口令哈希）")
    listing.set_defaults(func=cmd_list_admins)
    return parser


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":  # pragma: no cover - CLI 入口
    raise SystemExit(main())
