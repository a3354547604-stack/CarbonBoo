"""L3 测试：Web 后台管理端（`/admin`）—— 7 项功能 + 管理侧独立 JWT 隔离。

对齐契约
--------
* `docs/PLAN.md` §13.2（七项功能）/ §13.3（Jinja2 服务端渲染 + 少量原生 JS，无前端框架、无构建链）
* `docs/APPENDIX-B-data-and-api.md` §5.4（`/admin/*` 全部路径与鉴权口径）
* `docs/APPENDIX-D-acceptance.md` §1.10（D10-1…D10-8 的可执行化）
* `AGENTS.md` §6（`/admin` 需强口令 + 登录限流、客户端 token 访问 `/admin/*` 必须 403）/ §7.2

测试口径
--------
* 真实 MySQL 8 + 真实 ASGI（`TestClient`），**无 mock、不 skip**；夹具复用 `tests/conftest.py`
  （不修改它）：`clean_database`（每例清库重灌种子）、`client`、`db_session`、`settings`。
* 管理员首次创建走 **环境变量引导**（`ADMIN_BOOTSTRAP_USERNAME/PASSWORD` → 表为空时惰性创建），
  这正是文档之外本切片定的唯一引导口（另一条是 `python -m admin_web.cli create-admin`）。
* 上传目录指向 `tmp_path`（`ADMIN_UPLOAD_DIR`），测试不在仓库里留运行期文件。
"""

from __future__ import annotations

import base64
import json
from typing import Any

import pytest
from jose import jwt
from sqlalchemy import text

from app.core.config import Settings
from tests.conftest import auth_header, register_user, unique_username

ADMIN = "/admin"
SHOP = "/api/v1/shop/items"
AUTH = "/api/v1/auth"

#: 引导管理员（强口令：≥12 位 + 4 类字符 + 不在弱口令表）
ADMIN_USERNAME = "carbonboo_admin"
ADMIN_PASSWORD = "CarbonBoo#2026admin"
ADMIN_NEW_PASSWORD = "CarbonBoo#2027admin"

#: 客户端令牌访问这些路径必须 403（附录 B §5.4 的路径全集 + 未注册路径 + 两种写法）
ADMIN_PATHS = (
    "/admin",
    "/admin/",
    "/admin/login",
    "/admin/logout",
    "/admin/password",
    "/admin/items",
    "/admin/items/frame_01",
    "/admin/items/frame_01/icon",
    "/admin/users",
    "/admin/overview",
    "/admin/orders",
    "/admin/config",
    "/admin/logs",
    "/admin/icons/frame_01.png",
    "/admin/static/admin.css",
    "/admin/__probe_not_registered__",
)

#: 1×1 PNG（合法图片，用于图标上传用例）
PNG_1PX = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
)

HTML_ACCEPT = {"Accept": "text/html,application/xhtml+xml"}


# --------------------------------------------------------------------------- #
# 夹具
# --------------------------------------------------------------------------- #
@pytest.fixture(autouse=True)
def admin_env(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> Any:
    """每个用例：引导凭据 + 独立上传目录；用完清缓存与限流计数。"""
    from admin_web.config import reset_admin_settings_cache
    from admin_web.security import reset_admin_login_limit

    monkeypatch.setenv("ADMIN_BOOTSTRAP_USERNAME", ADMIN_USERNAME)
    monkeypatch.setenv("ADMIN_BOOTSTRAP_PASSWORD", ADMIN_PASSWORD)
    monkeypatch.setenv("ADMIN_UPLOAD_DIR", str(tmp_path / "icons"))
    reset_admin_settings_cache()
    reset_admin_login_limit()
    yield
    reset_admin_settings_cache()
    reset_admin_login_limit()


@pytest.fixture
def admin(client: Any) -> dict[str, Any]:
    """登录一次，返回 `{token, username, adminId}`（表为空 → 走环境变量引导创建）。"""
    response = client.post(f"{ADMIN}/login", json={"username": ADMIN_USERNAME, "password": ADMIN_PASSWORD})
    assert response.status_code == 200, f"管理员登录应 200，实际 {response.status_code}: {response.text}"
    data = response.json()["data"]
    assert data["adminToken"], "登录必须返回 adminToken（附录 B §5.4）"
    return {"token": data["adminToken"], "username": data["username"], "adminId": data["adminId"]}


@pytest.fixture
def admin_headers(admin: dict[str, Any]) -> dict[str, str]:
    return auth_header(admin["token"])


@pytest.fixture
def session_cookie(client: Any) -> dict[str, str]:
    """浏览器路径：登录后拿会话 Cookie（服务端渲染页面用），返回可直接塞给 client 的 headers。"""
    response = client.post(
        f"{ADMIN}/login",
        data={"username": ADMIN_USERNAME, "password": ADMIN_PASSWORD},
        follow_redirects=False,
    )
    assert response.status_code == 303, f"表单登录应 303 跳转，实际 {response.status_code}"
    cookie = response.cookies.get("carbonboo_admin_token")
    assert cookie, "表单登录必须下发 HttpOnly 会话 Cookie"
    return {"Cookie": f"carbonboo_admin_token={cookie}"}


def seed_business_rows(db_session: Any, *, user_id: str = "u-t6-0001", username: str = "t6user0001") -> None:
    """灌入一份最小业务数据：账号 + 2 条碳记录（两台设备）+ 1 条积分流水 + 1 笔订单。"""
    stamp = 1_760_000_000_000
    db_session.execute(
        text(
            "INSERT INTO server_user (id, user_id, username, password_hash, created_at, last_login_at, is_active) "
            "VALUES (:id, :uid, :name, :hash, :ts, :ts, 1)"
        ),
        {"id": f"su-{user_id}", "uid": user_id, "name": username, "hash": "$2b$12$" + "x" * 53, "ts": stamp},
    )
    for index, device in enumerate(("dev-a", "dev-b")):
        db_session.execute(
            text(
                "INSERT INTO carbon_record (id, user_id, category, sub_type, amount, unit, occurred_at, "
                "reduction_kg, factor_value, factor_version, factor_source, confidence, point_awarded, "
                "point_capped, revision, is_abnormal, note, created_at, updated_at, is_deleted, device_id) "
                "VALUES (:id, :uid, :cat, :sub, :amount, 'km', :ts, :kg, 0.1, 'CF-2026.2', 'SRC-DERIVED', "
                "'provisional', :points, 0, 0, 0, NULL, :ts, :ts, 0, :dev)"
            ),
            {
                "id": f"cr-{user_id}-{index}",
                "uid": user_id,
                "cat": "travel",
                "sub": "bicycle",
                "amount": 10.0,
                "ts": stamp + index,
                "kg": 2.5,
                "points": 250,
                "dev": device,
            },
        )
    db_session.execute(
        text(
            "INSERT INTO point_record (id, user_id, type, flow_kind, points, source_type, source_id, title, "
            "remark, occurred_at, created_at, updated_at, is_deleted, device_id) "
            "VALUES ('pr-t6-1', :uid, 'record', 'primary', 500, 'carbon_record', 'cr-1#0', '骑行', NULL, "
            ":ts, :ts, :ts, 0, 'dev-a')"
        ),
        {"uid": user_id, "ts": stamp},
    )
    db_session.execute(
        text(
            "INSERT INTO user_purchase (id, user_id, item_id, price_paid, purchased_at, created_at, updated_at, "
            "is_deleted, device_id) VALUES ('up-t6-1', :uid, 'frame_01', 1500, :ts, :ts, :ts, 0, 'dev-a')"
        ),
        {"uid": user_id, "ts": stamp},
    )
    db_session.commit()


# --------------------------------------------------------------------------- #
# ① 管理员登录 + 改密码（D10-1）
# --------------------------------------------------------------------------- #
def test_bootstrap_login_creates_first_admin_and_returns_admin_token(client: Any, admin: dict[str, Any], db_session: Any, settings: Any) -> None:
    """表为空 + 环境变量引导 → 创建首个管理员；返回值与令牌口径都按附录 B §5.4。"""
    claims = jwt.decode(
        admin["token"],
        settings.admin_jwt_secret,
        algorithms=[settings.jwt_algorithm],
        audience=Settings.model_fields["jwt_admin_audience"].default,
        issuer=settings.jwt_issuer,
    )
    assert claims["sub"] == admin["adminId"]

    row = db_session.execute(
        text("SELECT username, password_hash, last_login_at FROM admin_user WHERE id = :id"),
        {"id": admin["adminId"]},
    ).one()
    assert row.username == ADMIN_USERNAME
    assert row.password_hash.startswith("$2b$"), "口令必须以 bcrypt 哈希落库"
    assert row.password_hash != ADMIN_PASSWORD
    assert row.last_login_at, "登录成功要更新 last_login_at（同 §5.2 客户端登录口径）"

    logs = db_session.execute(
        text("SELECT action FROM admin_op_log WHERE admin_id = :id ORDER BY created_at"), {"id": admin["adminId"]}
    ).scalars().all()
    assert "bootstrap_admin" in logs and "login" in logs


def test_login_wrong_password_is_401_and_does_not_leak(client: Any, admin: dict[str, Any], settings: Any) -> None:
    response = client.post(f"{ADMIN}/login", json={"username": ADMIN_USERNAME, "password": "wrong-password"})
    assert response.status_code == 401
    assert response.json()["code"] == "CREDENTIAL_INVALID"
    text_body = response.text
    assert settings.admin_jwt_secret not in text_body
    assert settings.jwt_secret not in text_body
    assert "$2b$" not in text_body
    assert ADMIN_PASSWORD not in text_body


def test_unknown_admin_username_is_401_same_code(client: Any, admin: dict[str, Any]) -> None:
    """不区分"用户名不存在"与"口令错"（防账号枚举）。"""
    response = client.post(f"{ADMIN}/login", json={"username": "no_such_admin", "password": ADMIN_PASSWORD})
    assert response.status_code == 401
    assert response.json()["code"] == "CREDENTIAL_INVALID"


def test_bootstrap_with_weak_password_is_rejected(client: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """强口令策略在**引导创建**这一条路径上也生效（AGENTS §6：/admin 需强口令）。"""
    from admin_web.config import reset_admin_settings_cache

    monkeypatch.setenv("ADMIN_BOOTSTRAP_PASSWORD", "admin123456789")
    reset_admin_settings_cache()
    response = client.post(f"{ADMIN}/login", json={"username": ADMIN_USERNAME, "password": "admin123456789"})
    assert response.status_code == 400
    assert response.json()["code"] == "PASSWORD_INVALID"


def test_login_without_bootstrap_credentials_tells_operator_what_to_do(
    client: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """表为空且没配引导凭据：给可执行的提示，而不是含糊的"口令错误"。"""
    from admin_web.config import reset_admin_settings_cache

    monkeypatch.delenv("ADMIN_BOOTSTRAP_USERNAME", raising=False)
    monkeypatch.delenv("ADMIN_BOOTSTRAP_PASSWORD", raising=False)
    reset_admin_settings_cache()
    response = client.post(f"{ADMIN}/login", json={"username": ADMIN_USERNAME, "password": ADMIN_PASSWORD})
    assert response.status_code == 401
    assert "ADMIN_BOOTSTRAP_USERNAME" in response.json()["message"]
    assert "admin_web.cli create-admin" in response.json()["message"]


def test_form_login_sets_httponly_cookie_and_redirects(client: Any) -> None:
    """表单（无 JS）路径：303 跳到 `/admin` 并下发 HttpOnly + SameSite=Lax Cookie。"""
    response = client.post(
        f"{ADMIN}/login",
        data={"username": ADMIN_USERNAME, "password": ADMIN_PASSWORD, "next": "/admin/items"},
        follow_redirects=False,
    )
    assert response.status_code == 303
    assert response.headers["location"] == "/admin/items"
    cookie_header = response.headers.get("set-cookie", "")
    assert "carbonboo_admin_token=" in cookie_header
    assert "HttpOnly" in cookie_header
    assert "SameSite=lax" in cookie_header.lower().replace("samesite=lax", "SameSite=lax") or "samesite=lax" in cookie_header.lower()


def test_open_redirect_is_blocked(client: Any) -> None:
    """`next` 只接受 `/admin` 开头的相对路径（不接受外部站点）。"""
    response = client.post(
        f"{ADMIN}/login",
        data={"username": ADMIN_USERNAME, "password": ADMIN_PASSWORD, "next": "https://evil.example/steal"},
        follow_redirects=False,
    )
    assert response.status_code == 303
    assert response.headers["location"] == "/admin"


def test_change_password_makes_old_one_invalid(client: Any, admin_headers: dict[str, str], db_session: Any) -> None:
    """D10-1：改密码成功、旧密码失效、新密码可用；审计只记"改过"不记口令。"""
    response = client.post(
        f"{ADMIN}/password",
        headers=admin_headers,
        json={"oldPassword": ADMIN_PASSWORD, "newPassword": ADMIN_NEW_PASSWORD},
    )
    assert response.status_code == 200, response.text
    assert response.json()["data"]["changed"] is True

    assert client.post(f"{ADMIN}/login", json={"username": ADMIN_USERNAME, "password": ADMIN_PASSWORD}).status_code == 401
    assert (
        client.post(f"{ADMIN}/login", json={"username": ADMIN_USERNAME, "password": ADMIN_NEW_PASSWORD}).status_code
        == 200
    )

    detail = db_session.execute(
        text("SELECT detail FROM admin_op_log WHERE action = 'change_password'")
    ).scalar_one()
    assert "password" not in detail.replace("password_hash", "")
    assert ADMIN_NEW_PASSWORD not in detail and ADMIN_PASSWORD not in detail


def test_change_password_requires_correct_old_password(client: Any, admin_headers: dict[str, str]) -> None:
    response = client.post(
        f"{ADMIN}/password",
        headers=admin_headers,
        json={"oldPassword": "not-the-old-one", "newPassword": ADMIN_NEW_PASSWORD},
    )
    assert response.status_code == 401
    assert response.json()["code"] == "CREDENTIAL_INVALID"


@pytest.mark.parametrize(
    "weak",
    ["short12", "alllowercaseonly", "123456789012", "carbonboo@2026", ADMIN_USERNAME],
)
def test_change_password_rejects_weak_passwords(client: Any, admin_headers: dict[str, str], weak: str) -> None:
    response = client.post(
        f"{ADMIN}/password",
        headers=admin_headers,
        json={"oldPassword": ADMIN_PASSWORD, "newPassword": weak},
    )
    assert response.status_code == 400, f"{weak!r} 应被强口令策略拒绝，实际 {response.status_code}"
    assert response.json()["code"] == "PASSWORD_INVALID"


def test_login_page_is_server_rendered_html(client: Any) -> None:
    """附录 B §5.4 的 `GET /admin/login` = 后台登录页（HTML，无需令牌）。"""
    response = client.get(f"{ADMIN}/login")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert "管理员登录" in response.text and "<form" in response.text
    assert "/admin/static/admin.js" in response.text


def test_page_routes_split_json_401_and_html_303(client: Any) -> None:
    """未登录：JSON 请求 → 401 信封；HTML 请求 → 303 跳登录页（`next` 带原路径）。

    注意：本用例**不登录**。TestClient 自带 Cookie jar，先登录会让后续请求带上会话，
    所以"未登录"的断言必须与登录用例分开写。
    """
    for path in (f"{ADMIN}/password", ADMIN, f"{ADMIN}/items", f"{ADMIN}/logs"):
        assert client.get(path).status_code == 401, f"{path} 无令牌应 401（JSON）"
    redirect = client.get(f"{ADMIN}/password", headers=HTML_ACCEPT, follow_redirects=False)
    assert redirect.status_code == 303
    assert redirect.headers["location"].startswith("/admin/login?next=")
    assert "/admin/password" in redirect.headers["location"]


def test_password_page_renders_when_logged_in(client: Any, session_cookie: dict[str, str]) -> None:
    """会话 Cookie 登录后，改密码页可正常服务端渲染。"""
    page = client.get(f"{ADMIN}/password", headers={**session_cookie, **HTML_ACCEPT})
    assert page.status_code == 200
    assert "修改管理员密码" in page.text
