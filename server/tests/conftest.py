"""L3（服务端）测试夹具：真实 MySQL 8 + FastAPI TestClient。

设计口径
--------
1. **不打桩数据库**：L3 要证明的正是「真实 MySQL 上的账号与鉴权隔离」，因此建真库、跑真 SQL
   （`server/sql/schema.sql` + `seed.sql`，均由附录 B 生成）。
2. **只写测试库**：目标库名必须含 `test`（默认 `carbonboo_test`），否则直接停手 —— 防止误清开发库。
3. **机密不进仓库**：JWT 双密钥每个测试会话随机生成；MySQL 口令只从环境变量或 `server/.env`（600）
   读取，仓库内不写任何真实口令。缺失时**响亮失败并给出可执行命令**，绝不静默跳过
   （跳过会让「L3 未真实运行」看起来像绿的）。
4. 运行：
       cd server && python -m pytest tests/ -q
   若本机 MySQL 不在 3306：在 `server/.env` 写 `MYSQL_PORT=13307`，或命令行 `MYSQL_PORT=13307 pytest …`。
"""

from __future__ import annotations

import os
import secrets
import socket
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

SERVER_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = SERVER_DIR.parent
SCHEMA_SQL = SERVER_DIR / "sql" / "schema.sql"
SEED_SQL = SERVER_DIR / "sql" / "seed.sql"
#: 增量迁移目录（t5 起：schema.sql 是基线，这里是在已有库上的增量，必须幂等）
MIGRATIONS_DIR = SERVER_DIR / "sql" / "migrations"
ENV_FILE = SERVER_DIR / ".env"

#: 让 `import app.*` 在任何工作目录下都成立
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

#: 测试库名（必须含 test —— 见 _postgres_guard 之外的 _guard_test_db）
TEST_DB_NAME = "carbonboo_test"

#: 常用 MySQL 端口（本机 docker 容器把 3306 映射到 13307）
_PORT_CANDIDATES = (3306, 13307)


# --------------------------------------------------------------------------- #
# 配置发现：env > server/.env > 默认值（默认值里没有任何机密）
# --------------------------------------------------------------------------- #
def _read_dotenv(path: Path) -> dict[str, str]:
    """极简 .env 解析（KEY=VALUE，忽略注释；不引入额外依赖）。"""
    if not path.exists():
        return {}
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def _discover() -> dict[str, str]:
    """解析 MySQL 连接信息 + 建库用管理员凭据；端口按实际可达性挑选。"""
    file_values = _read_dotenv(ENV_FILE)
    env_values = {k: v for k, v in os.environ.items() if v}
    merged = {**file_values, **env_values}

    host = merged.get("MYSQL_HOST") or "127.0.0.1"
    user = merged.get("MYSQL_USER") or "carbonboo"
    password = merged.get("MYSQL_PASSWORD") or ""
    admin_user = merged.get("MYSQL_ADMIN_USER") or "root"
    admin_password = merged.get("MYSQL_ADMIN_PASSWORD") or ""

    candidates: list[int] = []
    if merged.get("MYSQL_PORT"):
        candidates.append(int(merged["MYSQL_PORT"]))
    candidates.extend(p for p in _PORT_CANDIDATES if p not in candidates)

    chosen: int | None = None
    for port in candidates:
        if _tcp_reachable(host, port):
            chosen = port
            break

    return {
        "host": host,
        "port": str(chosen or candidates[0]),
        "reachable": "1" if chosen is not None else "0",
        "user": user,
        "password": password,
        "admin_user": admin_user,
        "admin_password": admin_password,
        "db": merged.get("CARBONBOO_TEST_DB") or TEST_DB_NAME,
    }


def _tcp_reachable(host: str, port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


_MYSQL = _discover()

#: 测试专用 JWT 密钥（会话内随机，仓库内不留任何固定密钥）
os.environ.setdefault("JWT_SECRET", secrets.token_urlsafe(48))
os.environ.setdefault("ADMIN_JWT_SECRET", secrets.token_urlsafe(48))
os.environ.setdefault("APP_ENV", "test")
#: 默认关掉登录限流（限流有专门用例，见 test_authz.py::test_login_rate_limited）
os.environ.setdefault("LOGIN_RATE_LIMIT_PER_MINUTE", "0")
os.environ["MYSQL_HOST"] = _MYSQL["host"]
os.environ["MYSQL_PORT"] = _MYSQL["port"]
os.environ["MYSQL_USER"] = _MYSQL["user"]
os.environ["MYSQL_PASSWORD"] = _MYSQL["password"]
os.environ["MYSQL_DB"] = _MYSQL["db"]
os.environ["MYSQL_ADMIN_USER"] = _MYSQL["admin_user"]
os.environ["MYSQL_ADMIN_PASSWORD"] = _MYSQL["admin_password"]

_UNREACHABLE_HINT = f"""
STOP: 本机未找到可用的 MySQL，L3 用例无法真实运行（**不会**跳过，跳过会把"没跑"伪装成"通过"）。
冲突: 测试要连 {_MYSQL['host']}:{_MYSQL['port']}（探测端口 {_PORT_CANDIDATES}），TCP 不可达。
建议: 起一个只监听 127.0.0.1 的 MySQL 8 并按需在 server/.env（600）里写连接信息：
  docker run -d --name carbonboo-mysql -p 127.0.0.1:13307:3306 \\
    -e MYSQL_ROOT_PASSWORD=<root 口令> -e MYSQL_DATABASE=carbonboo \\
    -e MYSQL_USER=carbonboo -e MYSQL_PASSWORD=<应用口令> mysql:8.0 --max-connections=30
  printf 'MYSQL_HOST=127.0.0.1\\nMYSQL_PORT=13307\\nMYSQL_USER=carbonboo\\nMYSQL_PASSWORD=<应用口令>\\n\\
MYSQL_ADMIN_USER=root\\nMYSQL_ADMIN_PASSWORD=<root 口令>\\n' > server/.env && chmod 600 server/.env
"""


# --------------------------------------------------------------------------- #
# SQL 脚本执行
# --------------------------------------------------------------------------- #
def _split_statements(sql_text: str) -> list[str]:
    """按语句拆分 SQL 脚本（识别单引号串；本仓库脚本无需处理存储过程分隔符）。"""
    statements: list[str] = []
    buffer: list[str] = []
    in_string = False
    for char in sql_text:
        if char == "'":
            in_string = not in_string
        if char == ";" and not in_string:
            statements.append("".join(buffer).strip())
            buffer = []
            continue
        buffer.append(char)
    tail = "".join(buffer).strip()
    if tail:
        statements.append(tail)
    return [s for s in statements if s]


def _exec_script(connection: Any, path: Path, *, skip_db_statements: bool) -> int:
    """执行 SQL 脚本，返回语句数；`skip_db_statements` 时跳过 CREATE DATABASE / USE。"""
    executed = 0
    cursor = connection.cursor()
    try:
        for statement in _split_statements(path.read_text(encoding="utf-8")):
            upper = statement.upper()
            if skip_db_statements and (upper.startswith("CREATE DATABASE") or upper.startswith("USE ")):
                continue
            cursor.execute(statement)
            executed += 1
    finally:
        cursor.close()
    return executed


def _connect(*, db: str | None, user: str, password: str, host: str, port: int) -> Any:
    import pymysql

    return pymysql.connect(
        host=host,
        port=port,
        user=user,
        password=password,
        database=db,
        charset="utf8mb4",
        autocommit=True,
        connect_timeout=5,
    )


def _guard_test_db(db_name: str) -> None:
    """安全阀：只允许在名字含 test 的库上清理数据。"""
    if "test" not in db_name:
        pytest.exit(
            f"STOP: 目标库 `{db_name}` 名字不含 test，拒绝在它上面跑 L3（会清表）。"
            f"请设 CARBONBOO_TEST_DB=<库名含 test>。",
            returncode=2,
        )


# --------------------------------------------------------------------------- #
# 会话级：建库 + 建表 + 种子
# --------------------------------------------------------------------------- #
@pytest.fixture(scope="session")
def mysql_conn() -> Iterator[dict[str, Any]]:
    """确保测试库存在、表结构与种子就绪，并返回连接信息。"""
    if _MYSQL["reachable"] != "1":
        pytest.fail(_UNREACHABLE_HINT, pytrace=False)

    host, port, db_name = _MYSQL["host"], int(_MYSQL["port"]), _MYSQL["db"]
    _guard_test_db(db_name)

    # 1) 建库：优先管理员凭据（应用账号通常只有单库权限）
    created = False
    for user, password in (
        (_MYSQL["admin_user"], _MYSQL["admin_password"]),
        (_MYSQL["user"], _MYSQL["password"]),
    ):
        if not user:
            continue
        try:
            connection = _connect(db=None, user=user, password=password, host=host, port=port)
        except Exception:  # noqa: BLE001 - 逐个凭据尝试，失败继续
            continue
        try:
            cursor = connection.cursor()
            cursor.execute(
                f"CREATE DATABASE IF NOT EXISTS `{db_name}` "
                "DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"
            )
            cursor.close()
            created = True
            # 顺手把测试库权限授给应用账号（无权限时忽略：库本来就是它的）
            try:
                cursor = connection.cursor()
                cursor.execute(f"GRANT ALL PRIVILEGES ON `{db_name}`.* TO '{_MYSQL['user']}'@'%'")
                cursor.execute("FLUSH PRIVILEGES")
                cursor.close()
            except Exception:  # noqa: BLE001
                pass
            break
        except Exception:  # noqa: BLE001 - 例如无建库权限
            continue
        finally:
            connection.close()
    if not created:
        pytest.fail(
            "STOP: 无法创建测试库 %s（应用账号无建库权限且管理员凭据不可用）。\n"
            "建议: 在 server/.env 里补 MYSQL_ADMIN_USER / MYSQL_ADMIN_PASSWORD（仅建测试库用，不进仓库）。" % db_name,
            pytrace=False,
        )

    # 2) 建表 + 种子（脚本里跳过 CREATE DATABASE / USE）
    connection = _connect(
        db=db_name, user=_MYSQL["user"], password=_MYSQL["password"], host=host, port=port
    )
    try:
        tables = _exec_script(connection, SCHEMA_SQL, skip_db_statements=True)
        seeds = _exec_script(connection, SEED_SQL, skip_db_statements=True)
        # 增量迁移（t5 起）：schema.sql 是基线，sql/migrations/*.sql 是库上的增量。
        # 每次会话**按序执行一遍**，让「基线 + 迁移」这条真实部署路径也被 L3 覆盖；
        # 迁移脚本自身要求幂等，所以这里再执行一次也不该出错（第二条断言在 test_sync.py）。
        migrations = _apply_migrations(connection)
        cursor = connection.cursor()
        cursor.execute(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = %s", (db_name,)
        )
        table_count = int(cursor.fetchone()[0])
        cursor.close()
    finally:
        connection.close()

    yield {
        "host": host,
        "port": port,
        "db": db_name,
        "user": _MYSQL["user"],
        "password": _MYSQL["password"],
        "schema_statements": tables,
        "seed_statements": seeds,
        "table_count": table_count,
        "migrations": migrations,
    }


def migration_files() -> list[Path]:
    """按序号升序返回 `sql/migrations/*.sql`（不存在目录时返回空列表）。"""
    if not MIGRATIONS_DIR.exists():
        return []
    return sorted(path for path in MIGRATIONS_DIR.glob("*.sql") if path.name[:3].isdigit())


def _apply_migrations(connection: Any) -> dict[str, int]:
    """执行全部迁移脚本，返回 `{文件名: 语句数}`（幂等脚本，可重复执行）。"""
    applied: dict[str, int] = {}
    for path in migration_files():
        applied[path.name] = _exec_script(connection, path, skip_db_statements=True)
    return applied


def _all_tables(connection: Any, db_name: str) -> list[str]:
    cursor = connection.cursor()
    cursor.execute(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = %s ORDER BY table_name",
        (db_name,),
    )
    names = [row[0] for row in cursor.fetchall()]
    cursor.close()
    return names


def _truncate_and_seed(connection: Any, db_name: str) -> None:
    tables = _all_tables(connection, db_name)
    cursor = connection.cursor()
    cursor.execute("SET FOREIGN_KEY_CHECKS = 0")
    for name in tables:
        cursor.execute(f"TRUNCATE TABLE `{name}`")
    cursor.execute("SET FOREIGN_KEY_CHECKS = 1")
    cursor.close()
    _exec_script(connection, SEED_SQL, skip_db_statements=True)


@pytest.fixture(autouse=True)
def clean_database(mysql_conn: dict[str, Any]) -> Iterator[None]:
    """每个用例前清库并重灌静态字典：用例之间互不影响，且断言始终基于文档口径的种子。"""
    connection = _connect(
        db=mysql_conn["db"],
        user=mysql_conn["user"],
        password=mysql_conn["password"],
        host=mysql_conn["host"],
        port=mysql_conn["port"],
    )
    try:
        _truncate_and_seed(connection, mysql_conn["db"])
    finally:
        connection.close()
    yield


# --------------------------------------------------------------------------- #
# 应用 / 数据库 / HTTP 客户端
# --------------------------------------------------------------------------- #
@pytest.fixture
def settings() -> Any:
    """当前生效配置（测试库 + 随机密钥）。"""
    from app.core.config import get_settings, reset_settings_cache
    from app.core.database import reset_engine

    reset_settings_cache()
    reset_engine()
    return get_settings()


@pytest.fixture
def db_session(settings: Any) -> Iterator[Any]:
    """直连测试库的 Session（用于断言落库结果：哈希、软删除标记、行数）。"""
    from app.core.database import get_sessionmaker

    session = get_sessionmaker()()
    try:
        yield session
    finally:
        session.close()


@pytest.fixture
def app(settings: Any) -> Any:
    """被测 FastAPI 应用（同一个 `create_app`，与生产/uvicorn 完全一致）。"""
    from app.main import create_app

    return create_app(settings)


@pytest.fixture
def client(app: Any) -> Iterator[Any]:
    """TestClient：真实走 ASGI 中间件、路由、异常处理器与数据库。"""
    from fastapi.testclient import TestClient

    with TestClient(app) as test_client:
        yield test_client


# --------------------------------------------------------------------------- #
# 用例通用小工具
# --------------------------------------------------------------------------- #
TEST_PASSWORD = "CarbonBoo@2026"


def unique_username(prefix: str = "t3user") -> str:
    """每个用例一个不重名的用户名（用户名唯一索引）。"""
    return f"{prefix}{secrets.token_hex(4)}"


def register_user(client: Any, username: str | None = None, password: str = TEST_PASSWORD) -> dict[str, Any]:
    """注册一个账号，返回 `{username, password, token, userId}`。"""
    username = username or unique_username()
    response = client.post("/api/v1/auth/register", json={"username": username, "password": password})
    assert response.status_code == 201, f"注册应返回 201（附录 B §5.2），实际 {response.status_code}: {response.text}"
    data = response.json()["data"]
    return {
        "username": username,
        "password": password,
        "token": data["userToken"],
        "userId": data["userId"],
    }


def auth_header(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


__all__ = [
    "MIGRATIONS_DIR",
    "REPO_ROOT",
    "SCHEMA_SQL",
    "SEED_SQL",
    "SERVER_DIR",
    "TEST_DB_NAME",
    "TEST_PASSWORD",
    "auth_header",
    "migration_files",
    "register_user",
    "unique_username",
]
