"""L3 账号链路测试（真实 MySQL）：建表/种子、注册、登录、me、登出、注销与恢复、口令哈希、配置口径。

每个用例都打到真实 ASGI 应用 + 真实 MySQL；**不使用任何 mock**。
对齐口径：docs/APPENDIX-B-data-and-api.md §1.2/§3/§5.2、docs/adr/0001-account-and-sync.md、AGENTS §6/§7.2。
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest
from sqlalchemy import text

from tests.conftest import (
    REPO_ROOT,
    SERVER_DIR,
    TEST_PASSWORD,
    auth_header,
    register_user,
    unique_username,
)

AUTH = "/api/v1/auth"
MS_PER_DAY = 86_400_000

#: 附录 B §1.2 的 21 张表（18 张同名同构 + 3 张管理表）
EXPECTED_TABLES = {
    "carbon_record",
    "carbon_factor_meta",
    "point_record",
    "point_daily_stat",
    "goal_def",
    "user_goal",
    "badge_def",
    "user_badge",
    "shop_item",
    "user_purchase",
    "user_appearance",
    "science_progress",
    "carbon_include",
    "share_record",
    "sync_log",
    "user_profile",
    "device_info",
    "app_config",
    "server_user",
    "admin_user",
    "admin_op_log",
}


def _insert_record(db_session, user_id: str, record_id: str = "rec-0001") -> None:
    """插入一条碳记录（用于验证注销时 9 张同步表的软删除传播）。"""
    db_session.execute(
        text(
            """
            INSERT INTO carbon_record
              (id, user_id, category, sub_type, amount, unit, occurred_at, reduction_kg,
               factor_value, factor_version, factor_source, confidence, point_awarded, point_capped,
               revision, is_abnormal, note, created_at, updated_at, is_deleted, device_id)
            VALUES
              (:id, :user_id, 'travel', 'walk', 3.0, 'km', :ts, 0.0000,
               0.0000, 'CF-2026.2', 'SRC-DERIVED', 'high', 0, 0, 0, 0, NULL, :ts, :ts, 0, 'dev-1')
            """
        ),
        {"id": record_id, "user_id": user_id, "ts": 1_755_009_600_000},
    )
    db_session.commit()


def _scalar(db_session, sql: str, **params):
    """读一个标量。

    先 `rollback()` 结束当前事务：MySQL 默认 REPEATABLE READ，测试自己的 Session 若在
    接口调用前就开了事务，之后会一直看到旧快照（会误判"软删除没生效"）。回滚后下一条语句
    重新开事务 → 读到接口已提交的真实状态。
    """
    db_session.rollback()
    return db_session.execute(text(sql), params).scalar()


# --------------------------------------------------------------------------- #
# 1) 工程与启动：配置注入 + 建表脚本 + 种子
# --------------------------------------------------------------------------- #
def test_settings_require_secrets_from_env(monkeypatch):
    """密钥只来自环境变量 / .env（600）：代码内无默认密钥，缺失或过短即拒绝启动。"""
    from app.core.config import Settings

    with pytest.raises(ValueError, match="JWT_SECRET"):
        Settings(_env_file=None, jwt_secret="", admin_jwt_secret="x" * 48)
    with pytest.raises(ValueError, match="长度"):
        Settings(_env_file=None, jwt_secret="short", admin_jwt_secret="x" * 48)
    with pytest.raises(ValueError, match="两套独立密钥"):
        Settings(_env_file=None, jwt_secret="y" * 48, admin_jwt_secret="y" * 48)


def test_env_example_documents_required_keys():
    """提交进仓库的只有 .env.example：它必须列全必需键（真实 .env 不进仓库、权限 600）。"""
    example = (SERVER_DIR / ".env.example").read_text(encoding="utf-8")
    for key in (
        "MYSQL_HOST",
        "MYSQL_PORT",
        "MYSQL_USER",
        "MYSQL_PASSWORD",
        "MYSQL_DB",
        "JWT_SECRET",
        "ADMIN_JWT_SECRET",
        "AUTH_PROVIDER",
        "ACCOUNT_PURGE_GRACE_DAYS",
    ):
        assert key in example, f".env.example 缺少 {key}"
    assert "600" in example, ".env.example 必须写明 600 权限要求"


def test_pool_sized_for_two_workers(monkeypatch):
    """AGENTS §7.2：`--workers 2` 时显式 pool_size=5, max_overflow=5, pool_recycle=1800。"""
    import app.core.database as database

    captured: dict[str, object] = {}

    def fake_create_engine(url, **kwargs):  # noqa: ANN001, ANN202
        captured["url"] = url
        captured.update(kwargs)
        return object()

    monkeypatch.setattr(database, "create_engine", fake_create_engine)
    from app.core.config import Settings

    settings = Settings(_env_file=None, jwt_secret="a" * 48, admin_jwt_secret="b" * 48)
    database.build_engine(settings)

    assert captured["pool_size"] == 5
    assert captured["max_overflow"] == 5
    assert captured["pool_recycle"] == 1800
    assert captured["pool_pre_ping"] is True
    # 2 × (5 + 5) = 20 < MySQL max_connections=30
    assert 2 * (int(captured["pool_size"]) + int(captured["max_overflow"])) < 30


def test_schema_sql_creates_21_tables(mysql_conn, db_session):
    """建表脚本 = 附录 B §1.2 的 21 张表（18 同名 + 3 管理表）。"""
    from app.core.database import get_engine
    from app.models import TABLE_COUNT, compare_with_database

    assert TABLE_COUNT == 21
    actual = set(
        db_session.execute(
            text(
                "SELECT table_name FROM information_schema.tables WHERE table_schema = :db"
            ),
            {"db": mysql_conn["db"]},
        ).scalars()
    )
    assert actual == EXPECTED_TABLES
    assert "science_article" not in actual, "客户端表 science_article 服务端不建（§1.2）"

    report = compare_with_database(get_engine())
    assert report["ok"] is True, json.dumps(report, ensure_ascii=False, indent=2)
    assert report["orm_table_count"] == report["db_table_count"] == 21


def test_admin_tables_match_appendix_b_section3(db_session):
    """3 张管理表逐字取自附录 B §3；server_user 不存 device_id（B35 契约）。"""
    server_user_cols = set(
        db_session.execute(
            text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = DATABASE() AND table_name = 'server_user'"
            )
        ).scalars()
    )
    assert server_user_cols == {
        "id",
        "user_id",
        "username",
        "password_hash",
        "created_at",
        "last_login_at",
        "is_active",
    }
    assert "device_id" not in server_user_cols

    admin_user_cols = set(
        db_session.execute(
            text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = DATABASE() AND table_name = 'admin_user'"
            )
        ).scalars()
    )
    assert admin_user_cols == {"id", "username", "password_hash", "created_at", "last_login_at"}

    op_log_cols = set(
        db_session.execute(
            text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = DATABASE() AND table_name = 'admin_op_log'"
            )
        ).scalars()
    )
    assert op_log_cols == {
        "id",
        "admin_id",
        "action",
        "target_type",
        "target_id",
        "detail",
        "ip",
        "created_at",
    }

    # B3 修复：carbon_record 必须有 revision（幂等键 <记录ID>#<revision>）
    assert "revision" in set(
        db_session.execute(
            text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = DATABASE() AND table_name = 'carbon_record'"
            )
        ).scalars()
    )


def test_seed_matches_docs(db_session):
    """种子数据来自附录 B §8：目标 11 / 徽章 8 / 商品 9，8 个头像框总价 51,000。"""
    assert _scalar(db_session, "SELECT COUNT(*) FROM goal_def") == 11
    assert _scalar(db_session, "SELECT COUNT(*) FROM badge_def") == 8
    assert _scalar(db_session, "SELECT COUNT(*) FROM shop_item") == 9
    assert _scalar(db_session, "SELECT SUM(price) FROM shop_item WHERE section = 'frame'") == 51000
    assert _scalar(db_session, "SELECT COUNT(*) FROM shop_item WHERE is_default_free = 1") == 1
    assert _scalar(db_session, "SELECT reward FROM goal_def WHERE id = 'S3'") == 15
    assert _scalar(db_session, "SELECT threshold FROM goal_def WHERE id = 'L1'") == 80
    assert _scalar(db_session, "SELECT version FROM carbon_factor_meta WHERE id = 'CF-2026.2'") == "CF-2026.2"


def test_schema_and_seed_are_idempotent(mysql_conn):
    """建表脚本与种子脚本可重复执行（部署与回归都要幂等）。"""
    from tests.conftest import SEED_SQL, SCHEMA_SQL, _connect, _exec_script

    connection = _connect(
        db=mysql_conn["db"],
        user=mysql_conn["user"],
        password=mysql_conn["password"],
        host=mysql_conn["host"],
        port=mysql_conn["port"],
    )
    try:
        _exec_script(connection, SCHEMA_SQL, skip_db_statements=True)
        first = _exec_script(connection, SEED_SQL, skip_db_statements=True)
        second = _exec_script(connection, SEED_SQL, skip_db_statements=True)
        cursor = connection.cursor()
        cursor.execute("SELECT COUNT(*) FROM goal_def")
        assert cursor.fetchone()[0] == 11
        cursor.execute("SELECT COUNT(*) FROM shop_item")
        assert cursor.fetchone()[0] == 9
        cursor.close()
    finally:
        connection.close()
    assert first == second  # 两次执行语句数一致且无异常


def test_openapi_exposes_five_auth_endpoints(client):
    """五个账号接口在 /docs 可见（OpenAPI 里逐条存在）。"""
    spec = client.get("/openapi.json").json()
    paths = spec["paths"]
    assert "/api/v1/auth/register" in paths
    assert "post" in paths["/api/v1/auth/register"]
    assert "post" in paths["/api/v1/auth/login"]
    assert "get" in paths["/api/v1/auth/me"]
    assert "post" in paths["/api/v1/auth/logout"]
    assert "delete" in paths["/api/v1/auth/account"]
    assert "/api/v1/health" in paths

    openapi_schemas = spec["components"]["schemas"]
    assert "userToken" in openapi_schemas["AuthData"]["properties"]
    assert "purgeAfter" in openapi_schemas["PurgeData"]["properties"]

    docs = client.get("/docs")
    assert docs.status_code == 200
    assert "swagger" in docs.text.lower()


def test_health(client, settings):
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    body = response.json()
    # 附录 B §5.1：health **不带 data 包装**，扁平 {ok, version, time}
    assert set(body) == {"ok", "version", "time"}, body
    assert body["ok"] is True
    assert body["version"] == settings.app_version == "1.0.0"
    assert abs(body["time"] - int(datetime.now(timezone.utc).timestamp() * 1000)) < 10_000


# --------------------------------------------------------------------------- #
# 2) 注册
# --------------------------------------------------------------------------- #
def test_register_returns_token_and_hashes_password(client, db_session):
    """注册成功即返回令牌；口令以 bcrypt 落库（绝不存明文）。"""
    account = register_user(client)
    assert account["userId"].startswith("u-")
    assert account["token"]

    row = db_session.execute(
        text("SELECT id, username, password_hash, is_active, last_login_at FROM server_user WHERE user_id = :uid"),
        {"uid": account["userId"]},
    ).one()
    assert row.username == account["username"]
    assert row.is_active == 1
    assert row.password_hash.startswith("$2")  # bcrypt
    assert row.password_hash != account["password"]
    assert TEST_PASSWORD not in row.password_hash

    from app.core.security import verify_password

    assert verify_password(TEST_PASSWORD, row.password_hash) is True
    assert verify_password(TEST_PASSWORD + "x", row.password_hash) is False


def test_register_duplicate_username_is_409(client):
    account = register_user(client)
    response = client.post(
        f"{AUTH}/register", json={"username": account["username"], "password": TEST_PASSWORD}
    )
    assert response.status_code == 409
    assert response.json() == {
        "ok": False,
        "code": "USERNAME_TAKEN",
        "message": "该用户名已被占用",
    }


@pytest.mark.parametrize(
    ("username", "password", "code"),
    [
        ("abc", TEST_PASSWORD, "USERNAME_INVALID"),         # 3 位 < 4
        ("a" * 21, TEST_PASSWORD, "USERNAME_INVALID"),      # 21 位 > 20
        ("has space", TEST_PASSWORD, "USERNAME_INVALID"),   # 含空格
        ("bad-name", TEST_PASSWORD, "USERNAME_INVALID"),    # 含连字符
        ("用户名四字", TEST_PASSWORD, "USERNAME_INVALID"),    # 非字母数字下划线
        (None, TEST_PASSWORD, "USERNAME_INVALID"),          # 缺失
        ("ok_user_1", "short", "PASSWORD_INVALID"),         # 5 位 < 6
        ("ok_user_2", "x" * 33, "PASSWORD_INVALID"),        # 33 位 > 32
        ("ok_user_3", "", "PASSWORD_INVALID"),              # 空
        (None, None, "USERNAME_INVALID"),                   # 全缺失 → 先报用户名
    ],
)
def test_register_validation_errors(client, username, password, code):
    """参数不合法 → 400 + 文档错误码（不是 Pydantic 的 422）。"""
    body = {}
    if username is not None:
        body["username"] = username
    if password is not None:
        body["password"] = password
    response = client.post(f"{AUTH}/register", json=body)
    assert response.status_code == 400
    assert response.json()["ok"] is False
    assert response.json()["code"] == code


def test_documented_example_credentials_are_accepted(client):
    """附录 B §5.2 的示例用户名/口令（harry_01 / abc12345）必须真的能注册并登录。

    边界口径 = §5.2 错误码表原文：用户名 4–20 位字母数字下划线、口令 6–32 位。
    多一条强度规则（例如强制符号）就会拒掉文档自己的示例 → 本用例即为该口径的守门测试。
    """
    response = client.post(
        f"{AUTH}/register", json={"username": "harry_01", "password": "abc12345"}
    )
    assert response.status_code == 201, response.text  # 附录 B §5.2 写死 `// res 201`
    login = client.post(f"{AUTH}/login", json={"username": "harry_01", "password": "abc12345"})
    assert login.status_code == 200, login.text
    assert login.json()["data"]["username"] == "harry_01"

    # 边界值：4 位与 20 位用户名、6 位与 32 位口令都合法
    for username, password in (("user", "abcdef"), ("u" * 20, "p" * 32)):
        assert client.post(f"{AUTH}/register", json={"username": username, "password": password}).status_code == 201
    for username, password in (("usr", "abcdef"), ("u" * 21, "abcdef"), ("user2", "abcde"), ("user3", "p" * 33)):
        assert client.post(f"{AUTH}/register", json={"username": username, "password": password}).status_code == 400


def test_register_ignores_client_context_and_device_id(client, db_session):
    """附录 B §5.2 示例体里的本地上下文（usingCount/mode/mergePolicy/deviceId）服务端忽略。"""
    username = unique_username()
    response = client.post(
        f"{AUTH}/register",
        json={
            "username": username,
            "password": TEST_PASSWORD,
            "deviceId": "dev-should-be-ignored",
            "usingCount": 0,
            "mode": "merge",
            "mergePolicy": "keep_local",
        },
    )
    assert response.status_code == 201, response.text
    assert response.json()["data"]["username"] == username
    # server_user 没有 device_id 列 → 无处可存，符合 B35 契约
    assert "device_id" not in set(
        db_session.execute(
            text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = DATABASE() AND table_name = 'server_user'"
            )
        ).scalars()
    )


def test_register_missing_body_is_400(client):
    response = client.post(f"{AUTH}/register", json={})
    assert response.status_code == 400
    assert response.json()["code"] == "USERNAME_INVALID"


# --------------------------------------------------------------------------- #
# 3) 登录 / me / 登出
# --------------------------------------------------------------------------- #
def test_login_success_updates_last_login_at(client, db_session):
    account = register_user(client)
    before = _scalar(
        db_session, "SELECT last_login_at FROM server_user WHERE user_id = :uid", uid=account["userId"]
    )
    response = client.post(
        f"{AUTH}/login", json={"username": account["username"], "password": account["password"]}
    )
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["userId"] == account["userId"]
    assert data["username"] == account["username"]
    assert data["userToken"]

    after = _scalar(
        db_session, "SELECT last_login_at FROM server_user WHERE user_id = :uid", uid=account["userId"]
    )
    assert after >= before


@pytest.mark.parametrize("password", ["WrongPass@2026", "", None])
def test_login_wrong_credentials_is_401(client, password):
    account = register_user(client)
    body = {"username": account["username"]}
    if password is not None:
        body["password"] = password
    response = client.post(f"{AUTH}/login", json=body)
    assert response.status_code == 401
    assert response.json()["code"] == "CREDENTIAL_INVALID"


def test_login_unknown_user_is_401(client):
    response = client.post(
        f"{AUTH}/login", json={"username": unique_username("nobody"), "password": TEST_PASSWORD}
    )
    assert response.status_code == 401
    assert response.json()["code"] == "CREDENTIAL_INVALID"


def test_me_requires_valid_token(client):
    account = register_user(client)
    ok = client.get(f"{AUTH}/me", headers=auth_header(account["token"]))
    assert ok.status_code == 200
    assert ok.json()["data"] == {"userId": account["userId"], "username": account["username"]}

    missing = client.get(f"{AUTH}/me")
    assert missing.status_code == 401
    assert missing.json()["code"] == "TOKEN_INVALID"

    garbage = client.get(f"{AUTH}/me", headers=auth_header("not-a-jwt"))
    assert garbage.status_code == 401
    assert garbage.json()["code"] == "TOKEN_INVALID"


def test_logout_is_stateless(client):
    account = register_user(client)
    response = client.post(f"{AUTH}/logout", headers=auth_header(account["token"]))
    assert response.status_code == 200
    assert response.json()["data"]["loggedOut"] is True
    # 服务端无状态：登出后令牌仍有效（客户端负责丢弃本地令牌）
    assert client.get(f"{AUTH}/me", headers=auth_header(account["token"])).status_code == 200

    assert client.post(f"{AUTH}/logout").status_code == 401


# --------------------------------------------------------------------------- #
# 4) 注销：软删除 + 30 天保留 + 期内可恢复
# --------------------------------------------------------------------------- #
def test_delete_account_soft_deletes_and_keeps_30_days(client, db_session):
    """注销语义（ADR-0001 决策 ③）：9 张同步表软删除、账号停用、旧令牌失效、保留 30 天。"""
    account = register_user(client)
    _insert_record(db_session, account["userId"])

    wrong = client.request(
        "DELETE", f"{AUTH}/account", headers=auth_header(account["token"]), json={"password": "Wrong@2026"}
    )
    assert wrong.status_code == 401
    assert wrong.json()["code"] == "CREDENTIAL_INVALID"
    assert _scalar(
        db_session, "SELECT is_active FROM server_user WHERE user_id = :uid", uid=account["userId"]
    ) == 1

    before = int(datetime.now(timezone.utc).timestamp() * 1000)
    response = client.request(
        "DELETE",
        f"{AUTH}/account",
        headers=auth_header(account["token"]),
        json={"password": account["password"]},
    )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    after = int(datetime.now(timezone.utc).timestamp() * 1000)
    # 保留 30 天（配置项 ACCOUNT_PURGE_GRACE_DAYS）
    assert before + 30 * MS_PER_DAY <= data["purgeAfter"] <= after + 30 * MS_PER_DAY
    # 响应体逐字对齐 §5.2：只有 {ok, data:{purgeAfter}}，没有多余派生字段
    assert set(response.json()) == {"ok", "data"}
    assert set(data) == {"purgeAfter"}

    # 云端数据仍在（软删除），行没被物理删除
    assert _scalar(db_session, "SELECT COUNT(*) FROM carbon_record WHERE user_id = :uid", uid=account["userId"]) == 1
    assert _scalar(
        db_session, "SELECT is_deleted FROM carbon_record WHERE user_id = :uid", uid=account["userId"]
    ) == 1
    assert _scalar(
        db_session, "SELECT is_active FROM server_user WHERE user_id = :uid", uid=account["userId"]
    ) == 0

    # 审计留痕
    detail = json.loads(
        _scalar(
            db_session,
            "SELECT detail FROM admin_op_log WHERE action = 'account_delete' AND target_id = :uid",
            uid=account["userId"],
        )
    )
    assert detail["graceDays"] == 30
    assert detail["deletedRows"] == 1
    assert "carbon_record" in detail["tables"]

    # 旧令牌立即失效
    stale = client.get(f"{AUTH}/me", headers=auth_header(account["token"]))
    assert stale.status_code == 401
    assert stale.json()["code"] == "TOKEN_INVALID"


def test_relogin_within_grace_restores_account(client, db_session):
    """保留期内用同一用户名 + 相同口令登录 = 恢复账号与云端数据。

    且只恢复"注销时打标的那批行"：用户自己早先删掉的行（注销前就是 is_deleted=1）不得复活。
    """
    account = register_user(client)
    _insert_record(db_session, account["userId"])
    # 用户自己删除的一行（时间戳明显早于注销时刻）
    _insert_record(db_session, account["userId"], record_id="rec-0002")
    db_session.execute(
        text(
            "UPDATE carbon_record SET is_deleted = 1, updated_at = :ts "
            "WHERE id = 'rec-0002' AND user_id = :uid"
        ),
        {"ts": 1_700_000_000_000, "uid": account["userId"]},
    )
    db_session.commit()

    client.request(
        "DELETE",
        f"{AUTH}/account",
        headers=auth_header(account["token"]),
        json={"password": account["password"]},
    )

    restored = client.post(
        f"{AUTH}/login", json={"username": account["username"], "password": account["password"]}
    )
    assert restored.status_code == 200, restored.text
    new_token = restored.json()["data"]["userToken"]
    assert client.get(f"{AUTH}/me", headers=auth_header(new_token)).status_code == 200
    assert _scalar(
        db_session, "SELECT is_active FROM server_user WHERE user_id = :uid", uid=account["userId"]
    ) == 1
    assert _scalar(
        db_session,
        "SELECT is_deleted FROM carbon_record WHERE id = 'rec-0001' AND user_id = :uid",
        uid=account["userId"],
    ) == 0
    # 用户自己删的那行仍然保持删除状态（恢复 ≠ 全量复活）
    assert _scalar(
        db_session,
        "SELECT is_deleted FROM carbon_record WHERE id = 'rec-0002' AND user_id = :uid",
        uid=account["userId"],
    ) == 1
    assert _scalar(
        db_session,
        "SELECT COUNT(*) FROM admin_op_log WHERE action = 'account_restore' AND target_id = :uid",
        uid=account["userId"],
    ) == 1


def test_relogin_after_grace_purges_account(client, db_session):
    """超过 30 天再用同口令登录：账号数据物理清除，凭据判为无效。"""
    account = register_user(client)
    _insert_record(db_session, account["userId"])
    client.request(
        "DELETE",
        f"{AUTH}/account",
        headers=auth_header(account["token"]),
        json={"password": account["password"]},
    )
    _backdate_delete(db_session, account["userId"], days=31)

    response = client.post(
        f"{AUTH}/login", json={"username": account["username"], "password": account["password"]}
    )
    assert response.status_code == 401
    assert response.json()["code"] == "CREDENTIAL_INVALID"
    assert _scalar(
        db_session, "SELECT COUNT(*) FROM server_user WHERE user_id = :uid", uid=account["userId"]
    ) == 0
    assert _scalar(
        db_session, "SELECT COUNT(*) FROM carbon_record WHERE user_id = :uid", uid=account["userId"]
    ) == 0
    # 审计留痕仍然保留（只留操作日志，不留个人数据）
    assert _scalar(
        db_session,
        "SELECT COUNT(*) FROM admin_op_log WHERE action = 'account_purge' AND target_id = :uid",
        uid=account["userId"],
    ) == 1


def test_purge_expired_accounts_operator_entry(client, db_session):
    """运维入口 `purge_expired_accounts()`：批量清除保留期届满的账号。"""
    from app.services.auth_provider import purge_expired_accounts

    fresh = register_user(client)
    stale = register_user(client)
    for account in (fresh, stale):
        client.request(
            "DELETE",
            f"{AUTH}/account",
            headers=auth_header(account["token"]),
            json={"password": account["password"]},
        )
    _backdate_delete(db_session, stale["userId"], days=31)

    assert purge_expired_accounts(db_session) == 1
    assert _scalar(
        db_session, "SELECT COUNT(*) FROM server_user WHERE user_id = :uid", uid=stale["userId"]
    ) == 0
    # 保留期未满的账号不受影响，且仍可在保留期内恢复
    assert _scalar(
        db_session, "SELECT is_active FROM server_user WHERE user_id = :uid", uid=fresh["userId"]
    ) == 0
    back = client.post(
        f"{AUTH}/login", json={"username": fresh["username"], "password": fresh["password"]}
    )
    assert back.status_code == 200


def _backdate_delete(db_session, user_id: str, *, days: int) -> None:
    """把注销审计记录的时间戳回拨到 N 天前（模拟保留期届满）。

    注意：9 张同步表里被软删除的行是**按注销时间戳**标记的，回拨审计记录同时把行的时间戳对齐，
    否则恢复逻辑的 `updated_at == deletionTs` 条件会失配（那是正常态，这里只测超期清除路径）。
    """
    backdated = int(datetime.now(timezone.utc).timestamp() * 1000) - days * MS_PER_DAY
    db_session.execute(
        text(
            "UPDATE admin_op_log SET created_at = :ts "
            "WHERE action = 'account_delete' AND target_id = :uid"
        ),
        {"ts": backdated, "uid": user_id},
    )
    db_session.execute(
        text("UPDATE carbon_record SET updated_at = :ts WHERE user_id = :uid"),
        {"ts": backdated, "uid": user_id},
    )
    db_session.commit()


# --------------------------------------------------------------------------- #
# 5) 接口契约：AuthProvider 抽象与预留提供方
# --------------------------------------------------------------------------- #
def test_auth_provider_registry_is_frozen():
    """§7.1 契约：local 已实现，server / huaweiId 预留；注册表与 config.PROVIDER_IDS 一致。"""
    from app.core.config import PROVIDER_IDS
    from app.services.auth_provider import PROVIDERS

    assert set(PROVIDERS) == {"local", "server", "huaweiId"} == set(PROVIDER_IDS)


def test_reserved_providers_fail_loudly(client, db_session, settings):
    """预留提供方被选中时响亮失败，不静默降级成 local。"""
    from app.core.errors import ProviderNotImplementedError
    from app.services.auth_provider import build_provider

    provider = build_provider("huaweiId", db_session, settings)
    assert provider.is_available() is False
    with pytest.raises(ProviderNotImplementedError):
        provider.register("someone", TEST_PASSWORD)

    with pytest.raises(Exception) as excinfo:
        build_provider("wechat", db_session, settings)
    assert "未知 AUTH_PROVIDER" in str(excinfo.value)


def test_health_endpoint_has_no_auth(client):
    """取价/健康检查这类端点不需要令牌（附录 B §5.1/§5.4：health 与 shop/items 无鉴权）。"""
    assert client.get("/api/v1/health").status_code == 200


# --------------------------------------------------------------------------- #
# 6) 登录限流（AGENTS §6）
# --------------------------------------------------------------------------- #
def test_login_rate_limited(client, monkeypatch):
    from app.core.config import reset_settings_cache
    from app.core.ratelimit import reset_login_limit

    monkeypatch.setenv("LOGIN_RATE_LIMIT_PER_MINUTE", "2")
    reset_settings_cache()
    reset_login_limit()
    try:
        account = register_user(client)
        payload = {"username": account["username"], "password": "WrongPass@2026"}
        assert client.post(f"{AUTH}/login", json=payload).status_code == 401
        assert client.post(f"{AUTH}/login", json=payload).status_code == 401
        limited = client.post(f"{AUTH}/login", json=payload)
        assert limited.status_code == 429
        assert limited.json()["code"] == "RATE_LIMITED"
    finally:
        reset_login_limit()
        reset_settings_cache()


# --------------------------------------------------------------------------- #
# 7) 仓库卫生：真实的 .env 不得进仓库（只允许 .env.example）
# --------------------------------------------------------------------------- #
#: 无 POSIX 权限位的文件系统类型（Windows 盘通过 9p/drvfs 挂进 WSL 时 mode 恒为 777）
_NO_POSIX_MODE_FS = {"9p", "drvfs", "vboxsf", "ntfs", "fuseblk", "cifs", "smb3"}


def _unescape_mount_point(raw: str) -> str:
    """`/proc/mounts` 里的挂载点用八进制转义（如 `C:\\134` → `C:\\`）。"""
    import re as _re

    return _re.sub(r"\\(\d{3})", lambda m: chr(int(m.group(1), 8)), raw)


def _mount_fstype(path: Path) -> str:
    """取该路径所在文件系统的类型（最长前缀匹配）。

    原生 Windows 上没有 `/proc/mounts`（`Path('/proc/mounts').read_text()` 会抛
    `FileNotFoundError`，t-Win 实测）：此时按 `ntfs` 处理 —— 它本就在
    `_NO_POSIX_MODE_FS` 里，因此仍走下面**更强**的 ACL 分支，而不是放宽断言跳过。
    WSL 下把 Windows 盘挂成 9p/drvfs 时走同一分支，两条路殊途同归。
    """
    mounts = Path("/proc/mounts")
    if os.name == "nt" or not mounts.exists():
        return "ntfs"
    target = str(path.resolve())
    best_mount, best_type = "", ""
    for line in mounts.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        mount = _unescape_mount_point(fields[1])
        if target == mount or target.startswith(mount.rstrip("/") + "/"):
            if len(mount) > len(best_mount):
                best_mount, best_type = mount, fields[2]
    return best_type


def _windows_acl_path(path: Path) -> str:
    """把绝对路径换算成 PowerShell 能直接用的 Windows 路径。

    原生 Windows 上 `resolve()` 已经是 `C:\\...`（原样返回）；WSL 上是 `/mnt/c/...`，
    需要还原成 `C:\\...`（旧实现在原生 Windows 上会算成 `C:\\C:\\...` 这种畸形路径）。
    """
    resolved = str(path.resolve())
    if os.name == "nt":
        return resolved
    return "C:\\" + resolved.removeprefix("/mnt/c/").replace("/", "\\")


def test_no_secret_files_in_repo():
    """server/ 下只允许提交 `.env.example`；真实 `.env` 必须①只有属主可读 ②不被 git 跟踪。

    本机仓库在 Windows 盘上（`/mnt/c`，9p/drvfs）：没有 POSIX 权限位，`chmod 600` 拿不到 600，
    所以"600 权限"的等价物是 Windows ACL 只授权属主 —— 用 `Get-Acl` 逐条核对，而不是放宽断言。
    """
    assert (SERVER_DIR / ".env.example").exists()

    # ① 真实 .env 不进仓库：必须被 .gitignore 覆盖，且确实未被跟踪
    ignored = subprocess.run(
        ["git", "check-ignore", "-q", "server/.env"], cwd=REPO_ROOT, capture_output=True, text=True
    )
    assert ignored.returncode == 0, "server/.env 必须被 .gitignore 忽略（AGENTS §7.3 禁止提交密钥）"
    tracked = subprocess.run(
        ["git", "ls-files", "--error-unmatch", "server/.env"], cwd=REPO_ROOT, capture_output=True, text=True
    )
    assert tracked.returncode != 0, "server/.env 不得被 git 跟踪"

    env_file = SERVER_DIR / ".env"
    if not env_file.exists():
        return  # 干净检出（CI/他人机器）没有 .env，只跑上面的仓库卫生断言

    # ② 密钥文件只对属主可读
    fstype = _mount_fstype(env_file)
    if fstype in _NO_POSIX_MODE_FS:
        powershell = (
            shutil.which("powershell.exe")
            or shutil.which("powershell")
            or "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
        )
        win_path = _windows_acl_path(env_file)
        acl = subprocess.run(
            [
                powershell,
                "-NoProfile",
                "-Command",
                f"(Get-Acl '{win_path}').Access | ForEach-Object {{ $_.IdentityReference.Value }}",
            ],
            capture_output=True,
            text=True,
        )
        assert acl.returncode == 0, f"读取 ACL 失败：{acl.stderr or acl.stdout}"
        identities = [line.strip() for line in acl.stdout.replace("\r", "").splitlines() if line.strip()]
        assert identities, f"server/.env 的 ACL 为空（等价于人人可读）：{acl.stdout!r}"
        broad = ("Everyone", "BUILTIN\\Users", "Authenticated Users", "Users", "INTERACTIVE")
        for identity in identities:
            assert not any(
                identity == name or identity.endswith("\\" + name) for name in broad
            ), f"server/.env 对 {identity} 开放（{fstype} 上请用 icacls /inheritance:r /grant:r <属主>:R）"
    else:
        mode = env_file.stat().st_mode & 0o777
        assert mode == 0o600, f"server/.env 权限应为 600，实际 {oct(mode)}（chmod 600 server/.env）"
