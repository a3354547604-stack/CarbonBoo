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
            "VALUES (:id, :uid, 'record', 'primary', 500, 'carbon_record', :sid, '骑行', NULL, "
            ":ts, :ts, :ts, 0, 'dev-a')"
        ),
        {"id": f"pr-{user_id}-1", "uid": user_id, "sid": f"cr-{user_id}-0#0", "ts": stamp},
    )
    db_session.execute(
        text(
            "INSERT INTO user_purchase (id, user_id, item_id, price_paid, purchased_at, created_at, updated_at, "
            "is_deleted, device_id) VALUES (:id, :uid, 'frame_01', 1500, :ts, :ts, :ts, 0, 'dev-a')"
        ),
        {"id": f"up-{user_id}-1", "uid": user_id, "ts": stamp},
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


# --------------------------------------------------------------------------- #
# ② 商品管理（D10-2、D10-3）
# --------------------------------------------------------------------------- #
def test_items_json_is_the_same_shape_as_the_client_catalog(
    client: Any, admin_headers: dict[str, str]
) -> None:
    """后台看到的价目表与客户端取价**同一实现、同一结构**（不多一条、不少一条）。"""
    admin_payload = client.get(f"{ADMIN}/items", headers=admin_headers).json()["data"]
    client_payload = client.get(SHOP).json()["data"]
    assert admin_payload == client_payload
    assert len(admin_payload["items"]) == 9
    assert admin_payload["version"] == "2026.02.01-1"


def test_items_page_is_server_rendered(client: Any, session_cookie: dict[str, str]) -> None:
    """商品管理页由服务端渲染出真实数据（种子商品的名称与价格必须出现在 HTML 里）。"""
    page = client.get(f"{ADMIN}/items", headers={**session_cookie, **HTML_ACCEPT})
    assert page.status_code == 200
    assert "嫩芽" in page.text and "1500" in page.text and "frame_01" in page.text
    assert "2026.02.01-1" in page.text
    # 需要登录才有会话；未登录走的是 303（上面已单测），这里确认渲染确实发生了
    assert '<table class="table table-form">' in page.text


def test_price_change_writes_through_and_reaches_the_client_endpoint(
    client: Any, admin_headers: dict[str, str], db_session: Any
) -> None:
    """D10-3 改价生效链路：`PATCH /admin/items/{id}` → 库 → `GET /api/v1/shop/items` 报新价 + 新版本号。"""
    before = client.get(SHOP).json()["data"]

    response = client.patch(f"{ADMIN}/items/frame_01", headers=admin_headers, json={"price": 999})
    assert response.status_code == 200, response.text
    assert response.json()["data"]["price"] == 999

    stored = db_session.execute(text("SELECT price FROM shop_item WHERE id = 'frame_01'")).scalar_one()
    assert stored == 999

    after = client.get(SHOP).json()["data"]
    by_id = {item["id"]: item for item in after["items"]}
    assert by_id["frame_01"]["price"] == 999, "客户端启动取价必须拿到新价（附录 B §5.4）"
    assert after["version"] != before["version"], "改价必须 bump 商品目录版本号"
    assert len(after["items"]) == len(before["items"])

    version_row = db_session.execute(
        text("SELECT value FROM app_config WHERE id = 'shop_items_version'")
    ).scalar_one()
    assert version_row == after["version"]


def test_price_change_is_audited_with_before_and_after(
    client: Any, admin_headers: dict[str, str]
) -> None:
    """操作日志记录「谁改了价格、什么时候改的」（附录 D10-6 / PLAN §13.2 ⑦）。"""
    client.patch(f"{ADMIN}/items/frame_01", headers=admin_headers, json={"price": 1234})

    logs = client.get(f"{ADMIN}/logs?action=change_price", headers=admin_headers).json()["data"]
    assert logs["total"] == 1
    entry = logs["items"][0]
    assert entry["action"] == "change_price"
    assert entry["targetType"] == "item"
    assert entry["targetId"] == "frame_01"
    assert entry["adminUsername"] == ADMIN_USERNAME
    assert entry["createdAt"] > 0
    assert entry["detail"]["price"] == {"before": 1500, "after": 1234}


def test_patch_only_touches_the_fields_sent(
    client: Any, admin_headers: dict[str, str], db_session: Any
) -> None:
    """PATCH 语义：改描述不动价格；改排序不动在架状态（D10-2 的"改描述 / 排序"）。"""
    response = client.patch(
        f"{ADMIN}/items/frame_02", headers=admin_headers, json={"description": "复核过的描述"}
    )
    assert response.status_code == 200
    item = response.json()["data"]
    assert item["description"] == "复核过的描述"
    assert item["price"] == 2500 and item["onShelf"] == 1

    response = client.patch(f"{ADMIN}/items/frame_02", headers=admin_headers, json={"order": 42})
    assert response.json()["data"]["order"] == 42
    assert response.json()["data"]["description"] == "复核过的描述"

    row = db_session.execute(
        text("SELECT price, description, `order`, on_shelf FROM shop_item WHERE id = 'frame_02'")
    ).one()
    assert (row.price, row.description, row.order, row.on_shelf) == (2500, "复核过的描述", 42, 1)


def test_toggle_shelf_is_audited_and_client_sees_flag(client: Any, admin_headers: dict[str, str]) -> None:
    """上下架：库内 on_shelf 变化 + 客户端目录带 onShelf=0（客户端据此显示"该商品已下架"）。"""
    response = client.patch(f"{ADMIN}/items/frame_08", headers=admin_headers, json={"onShelf": 0})
    assert response.status_code == 200
    assert response.json()["data"]["onShelf"] == 0

    by_id = {item["id"]: item for item in client.get(SHOP).json()["data"]["items"]}
    assert by_id["frame_08"]["onShelf"] == 0

    logs = client.get(f"{ADMIN}/logs?action=toggle_shelf", headers=admin_headers).json()["data"]
    assert logs["total"] == 1
    assert logs["items"][0]["detail"]["onShelf"] == {"before": 1, "after": 0}
    assert logs["items"][0]["detail"]["shelfLabel"] == {"before": "在架", "after": "已下架"}


def test_noop_patch_writes_no_log_and_does_not_bump_version(
    client: Any, admin_headers: dict[str, str]
) -> None:
    """空改动是幂等成功：不写日志、不 bump 版本号（避免"改了价"的假记录）。"""
    before_version = client.get(SHOP).json()["data"]["version"]
    response = client.patch(f"{ADMIN}/items/frame_01", headers=admin_headers, json={"price": 1500})
    assert response.status_code == 200
    assert client.get(SHOP).json()["data"]["version"] == before_version
    # 登录本身会写 bootstrap_admin / login 两条日志，所以这里只断言"没有改价日志"
    assert client.get(f"{ADMIN}/logs?action=change_price", headers=admin_headers).json()["data"]["total"] == 0
    assert client.get(f"{ADMIN}/logs?action=update_item", headers=admin_headers).json()["data"]["total"] == 0


def test_create_item_and_reject_duplicate_id(client: Any, admin_headers: dict[str, str]) -> None:
    """新增商品（D10-2）；编码重复 → 400（错误码表里没有通用冲突码，按码表口径给 INVALID_REQUEST）。"""
    response = client.post(
        f"{ADMIN}/items",
        headers=admin_headers,
        json={"id": "frame_09", "section": "frame", "name": "春风", "price": 1200, "order": 9},
    )
    assert response.status_code == 201, response.text
    item = response.json()["data"]
    assert item["icon"] == "res://frame_09", "缺省 icon 与内置商品同形"
    assert item["onShelf"] == 1 and item["isDefaultFree"] == 0

    by_id = {row["id"]: row for row in client.get(SHOP).json()["data"]["items"]}
    assert by_id["frame_09"]["price"] == 1200 and len(by_id) == 10

    duplicate = client.post(
        f"{ADMIN}/items",
        headers=admin_headers,
        json={"id": "frame_09", "section": "frame", "name": "重复", "price": 1},
    )
    assert duplicate.status_code == 400
    assert duplicate.json()["code"] == "INVALID_REQUEST"

    bad_section = client.post(
        f"{ADMIN}/items",
        headers=admin_headers,
        json={"id": "frame_10", "section": "avatar", "name": "非法分区", "price": 1},
    )
    assert bad_section.status_code == 400

    logs = client.get(f"{ADMIN}/logs?action=create_item", headers=admin_headers).json()["data"]
    assert logs["total"] == 1 and logs["items"][0]["targetId"] == "frame_09"


@pytest.mark.parametrize(
    "bad_id",
    ["AB", "frame 09", "frame/09", "frame-09", "", "x" * 40],
)
def test_create_item_rejects_bad_ids(client: Any, admin_headers: dict[str, str], bad_id: str) -> None:
    response = client.post(
        f"{ADMIN}/items",
        headers=admin_headers,
        json={"id": bad_id, "section": "frame", "name": "非法", "price": 1},
    )
    assert response.status_code in (400, 422), f"{bad_id!r} 应被拒，实际 {response.status_code}"


def test_patch_unknown_item_is_404(client: Any, admin_headers: dict[str, str]) -> None:
    response = client.patch(f"{ADMIN}/items/no_such_item", headers=admin_headers, json={"price": 1})
    assert response.status_code == 404
    assert response.json()["code"] == "NOT_FOUND"


def test_icon_upload_raw_bytes_and_serving(client: Any, admin_headers: dict[str, str], db_session: Any) -> None:
    """传图标（D10-2）：`Content-Type: image/png` + 原始字节 → 落盘 + 写回 icon + 可回读。"""
    response = client.post(
        f"{ADMIN}/items/frame_03/icon",
        headers={**admin_headers, "Content-Type": "image/png"},
        content=PNG_1PX,
    )
    assert response.status_code == 200, response.text
    icon_url = response.json()["data"]["icon"]
    assert icon_url.startswith("/admin/icons/")
    assert icon_url.endswith(".png")

    stored = db_session.execute(text("SELECT icon FROM shop_item WHERE id = 'frame_03'")).scalar_one()
    assert stored == icon_url

    filename = icon_url.rsplit("/", 1)[-1]
    fetched = client.get(f"{ADMIN}/icons/{filename}", headers=admin_headers)
    assert fetched.status_code == 200
    assert fetched.content == PNG_1PX
    assert fetched.headers["content-type"] == "image/png"

    logs = client.get(f"{ADMIN}/logs?action=upload_icon", headers=admin_headers).json()["data"]
    assert logs["total"] == 1 and logs["items"][0]["targetId"] == "frame_03"


def test_icon_upload_json_base64_path(client: Any, admin_headers: dict[str, str]) -> None:
    """浏览器表单路径：`{filename, dataBase64}`（不引入 python-multipart）。"""
    response = client.post(
        f"{ADMIN}/items/frame_04/icon",
        headers=admin_headers,
        json={"filename": "my icon.png", "dataBase64": base64.b64encode(PNG_1PX).decode()},
    )
    assert response.status_code == 200, response.text
    assert response.json()["data"]["icon"].startswith("/admin/icons/frame_04-")


def test_icon_upload_rejects_non_image_and_bad_base64(client: Any, admin_headers: dict[str, str]) -> None:
    """按文件内容识别类型（不看扩展名／Content-Type）：伪造 png 的木马字节必须拒。"""
    not_an_image = client.post(
        f"{ADMIN}/items/frame_01/icon",
        headers={**admin_headers, "Content-Type": "image/png"},
        content=b"#!/bin/sh\necho pwned\n",
    )
    assert not_an_image.status_code == 400
    assert not_an_image.json()["code"] == "INVALID_REQUEST"

    bad_base64 = client.post(
        f"{ADMIN}/items/frame_01/icon",
        headers=admin_headers,
        json={"filename": "x.png", "dataBase64": "!!!not-base64!!!"},
    )
    assert bad_base64.status_code == 400

    empty = client.post(
        f"{ADMIN}/items/frame_01/icon",
        headers={**admin_headers, "Content-Type": "image/png"},
        content=b"",
    )
    assert empty.status_code == 400


def test_icon_upload_enforces_size_limit(client: Any, admin_headers: dict[str, str]) -> None:
    oversized = PNG_1PX + b"\x00" * (512 * 1024)
    response = client.post(
        f"{ADMIN}/items/frame_01/icon",
        headers={**admin_headers, "Content-Type": "image/png"},
        content=oversized,
    )
    assert response.status_code == 400
    assert "上限" in response.json()["message"]


def test_icon_path_traversal_is_rejected(client: Any, admin_headers: dict[str, str]) -> None:
    """路径穿越：`/admin/icons/..%2F..%2Fetc%2Fpasswd` 必须 404，不能读到仓库外的文件。"""
    for candidate in ("..%2F..%2Fetc%2Fpasswd", "..%2Fstore.py", "%2Fetc%2Fpasswd", ".hidden"):
        response = client.get(f"{ADMIN}/icons/{candidate}", headers=admin_headers)
        assert response.status_code == 404, f"{candidate} 应 404，实际 {response.status_code}"


def test_static_assets_are_whitelisted(client: Any) -> None:
    """后台静态资源只放行 admin.css / admin.js（无需令牌，且不含任何业务数据）。"""
    assert client.get(f"{ADMIN}/static/admin.css").status_code == 200
    js = client.get(f"{ADMIN}/static/admin.js")
    assert js.status_code == 200 and "fetch(" in js.text
    assert client.get(f"{ADMIN}/static/../admin_web/config.py").status_code in (400, 404)
    assert client.get(f"{ADMIN}/static/templates").status_code == 404


# --------------------------------------------------------------------------- #
# ③ 用户列表（D10-4）/ ④ 数据总览（D10-4）/ ⑤ 订单记录（D10-4）
# --------------------------------------------------------------------------- #
def test_users_list_reports_account_devices_and_counts(
    client: Any, admin_headers: dict[str, str], db_session: Any
) -> None:
    """③ 账号标识、首次接入、最后同步、记录数、设备列表（按 device_id 去重 + 各自最后同步）。"""
    seed_business_rows(db_session)

    data = client.get(f"{ADMIN}/users", headers=admin_headers).json()["data"]
    assert data["total"] == 1 and data["page"] == 1
    row = data["items"][0]
    assert row["userId"] == "u-t6-0001"
    assert row["username"] == "t6user0001"
    assert row["isActive"] == 1
    assert row["recordCount"] == 2
    assert row["deviceCount"] == 2
    assert {device["deviceId"] for device in row["devices"]} == {"dev-a", "dev-b"}
    assert row["devices"][0]["lastSyncAt"] >= row["devices"][1]["lastSyncAt"], "设备按最后同步时间倒序"
    assert row["rowCount"] == 4, "9 张同步表的未删除行：2 碳记录 + 1 积分流水 + 1 购买"
    assert row["firstSeenAt"] == 1_760_000_000_000


def test_users_list_paginates(client: Any, admin_headers: dict[str, str], db_session: Any) -> None:
    """D10-4 的"可翻页"：pageSize 与 page 生效，total 是分页前的总数。"""
    seed_business_rows(db_session, user_id="u-t6-0001", username="t6user0001")
    seed_business_rows(db_session, user_id="u-t6-0002", username="t6user0002")
    seed_business_rows(db_session, user_id="u-t6-0003", username="t6user0003")

    first = client.get(f"{ADMIN}/users?page=1&pageSize=2", headers=admin_headers).json()["data"]
    second = client.get(f"{ADMIN}/users?page=2&pageSize=2", headers=admin_headers).json()["data"]
    assert first["total"] == second["total"] == 3
    assert len(first["items"]) == 2 and len(second["items"]) == 1
    assert {row["userId"] for row in first["items"]} & {row["userId"] for row in second["items"]} == set()

    clamped = client.get(f"{ADMIN}/users?page=0&pageSize=99999", headers=admin_headers).json()["data"]
    assert clamped["page"] == 1, "page 越界夹到 1，不报 400（后台是人用的）"
    assert clamped["pageSize"] <= 200, "pageSize 有上限，避免一次拉全库"


def test_overview_numbers_match_the_database(client: Any, admin_headers: dict[str, str], db_session: Any) -> None:
    """④ 接入设备数 / 总记录数 / 今日新增 / 总减排量 / 总积分发放，逐项与库内一致。"""
    seed_business_rows(db_session)

    data = client.get(f"{ADMIN}/overview", headers=admin_headers).json()["data"]
    assert data["accountCount"] == 1 and data["activeAccountCount"] == 1
    assert data["deviceCount"] == 2
    assert data["recordCount"] == 2
    assert data["totalReductionKg"] == 5.0
    assert data["reductionByCategory"] == {"travel": 5.0}
    assert data["totalPointsIssued"] == 500
    assert data["totalPointsSpent"] == 0
    assert data["totalPointsBalance"] == 500
    assert data["orderCount"] == 1
    assert data["itemCount"] == 9 and data["onShelfItemCount"] == 9
    assert data["shopVersion"] == "2026.02.01-1"
    assert data["lastSyncAt"] == 1_760_000_000_001

    # 今日新增按 created_at 落本地今天的行数（种子的时间戳是过去，故为 0）
    assert data["todayRecordCount"] == 0
    stamp = int(__import__("time").time() * 1000)
    db_session.execute(text("UPDATE carbon_record SET created_at = :ts"), {"ts": stamp})
    db_session.commit()
    assert client.get(f"{ADMIN}/overview", headers=admin_headers).json()["data"]["todayRecordCount"] == 2


def test_overview_page_is_server_rendered(client: Any, session_cookie: dict[str, str]) -> None:
    """`/admin` 主页 = 数据总览页（服务端渲染，含五张 KPI 卡）。"""
    page = client.get(ADMIN, headers={**session_cookie, **HTML_ACCEPT})
    assert page.status_code == 200
    for label in ("接入设备数", "总记录数", "总减排量", "总积分发放", "账号数"):
        assert label in page.text, f"总览页缺少 KPI：{label}"
    assert "4 位小数，与契约同精度" in page.text


def test_orders_report_who_bought_what_for_how_much(
    client: Any, admin_headers: dict[str, str], db_session: Any
) -> None:
    """⑤ 谁、什么时候、买了什么、花了多少分；成交价按下单价（不随后台改价变化）。"""
    seed_business_rows(db_session)
    client.patch(f"{ADMIN}/items/frame_01", headers=admin_headers, json={"price": 4321})

    data = client.get(f"{ADMIN}/orders", headers=admin_headers).json()["data"]
    assert data["total"] == 1
    order = data["items"][0]
    assert order["userId"] == "u-t6-0001"
    assert order["username"] == "t6user0001"
    assert order["itemId"] == "frame_01"
    assert order["itemName"] == "嫩芽"
    assert order["pricePaid"] == 1500, "成交价是下单时的价格，不随后台改价变化"
    assert order["purchasedAt"] == 1_760_000_000_000


def test_orders_page_is_server_rendered(client: Any, session_cookie: dict[str, str], db_session: Any) -> None:
    seed_business_rows(db_session)
    page = client.get(f"{ADMIN}/orders", headers={**session_cookie, **HTML_ACCEPT})
    assert page.status_code == 200
    assert "t6user0001" in page.text and "嫩芽" in page.text and "1,500" in page.text


def test_users_page_is_server_rendered(client: Any, session_cookie: dict[str, str], db_session: Any) -> None:
    seed_business_rows(db_session)
    page = client.get(f"{ADMIN}/users", headers={**session_cookie, **HTML_ACCEPT})
    assert page.status_code == 200
    assert "t6user0001" in page.text and "dev-a" in page.text and "dev-b" in page.text


# --------------------------------------------------------------------------- #
# ⑥ 系统配置（D10-5）
# --------------------------------------------------------------------------- #
def test_config_get_reports_documented_defaults(client: Any, admin_headers: dict[str, str]) -> None:
    """⑥ 目标奖励分值 / 每日封顶值 / 徽章开关；封顶值默认 200（PLAN §9.2）。"""
    data = client.get(f"{ADMIN}/config", headers=admin_headers).json()["data"]
    assert data["dailyCap"] == 200
    assert data["badgesEnabled"] == 1
    assert data["shopVersion"] == "2026.02.01-1"
    rewards = {goal["id"]: goal["reward"] for goal in data["goalRewards"]}
    assert len(rewards) == 11, "11 个目标（PLAN §10.1）"
    assert (rewards["S1"], rewards["S2"], rewards["S3"]) == (20, 20, 15)


def test_config_put_persists_and_audits(client: Any, admin_headers: dict[str, str], db_session: Any) -> None:
    """PUT 只改传了的项：写 app_config / goal_def + 一条 update_config 审计（含改前 / 改后）。"""
    response = client.put(
        f"{ADMIN}/config",
        headers=admin_headers,
        json={"dailyCap": 300, "badgesEnabled": 0, "goalRewards": [{"id": "S3", "reward": 25}]},
    )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    assert data["dailyCap"] == 300
    assert data["badgesEnabled"] == 0
    assert data["changed"] == ["dailyCap", "badgesEnabled", "goalRewards:S3"]

    stored = dict(
        db_session.execute(text("SELECT id, value FROM app_config WHERE id IN ('points_daily_cap', 'badges_enabled')")).all()
    )
    assert stored["points_daily_cap"] == "300"
    assert stored["badges_enabled"] == "0"
    assert db_session.execute(text("SELECT reward FROM goal_def WHERE id = 'S3'")).scalar_one() == 25

    assert client.get(f"{ADMIN}/config", headers=admin_headers).json()["data"]["dailyCap"] == 300

    logs = client.get(f"{ADMIN}/logs?action=update_config", headers=admin_headers).json()["data"]
    assert logs["total"] == 1
    detail = logs["items"][0]["detail"]
    assert detail["points_daily_cap"] == {"before": 200, "after": 300}
    assert detail["badges_enabled"] == {"before": 1, "after": 0}
    assert detail["goal_def.reward"]["S3"] == {"before": 15, "after": 25}


def config_row(db_session: Any, key: str) -> Any:
    """读一行 `app_config`（返回 `Row(value, version)`；不存在返回 `None`）。

    先 `rollback()`：`db_session` 是默认隔离级别（REPEATABLE READ）的普通 Session，
    快照在**首条语句**时建立 —— 不丢弃它，PUT 之后再读会拿到"PUT 之前那份快照"。
    （既有用例只在 PUT 之后首读，所以没暴露这一点；下面的用例要在 PUT 前后各读一次。）
    """
    db_session.rollback()
    return db_session.execute(
        text("SELECT value, version FROM app_config WHERE id = :key"), {"key": key}
    ).first()


def test_config_put_bumps_config_version_same_day_increments(
    client: Any, admin_headers: dict[str, str], db_session: Any
) -> None:
    """附录 B §5.5 的 ⚠️：保存成功后**必须**更新 `app_config['config_version']`，同日递增（D10-5）。

    版本号是客户端判断"配置内容是否变了"的唯一依据（`GET /api/v1/config` 的 `data.version`），
    不 bump 则"后台改了 App 能读到"退化成碰运气。
    """
    from datetime import datetime

    from admin_web.services.system_config import CONFIG_VERSION_KEY

    assert config_row(db_session, CONFIG_VERSION_KEY) is None, "种子不写 config_version（缺键 → 端点下发 0.0.0）"
    assert client.get("/api/v1/config").json()["data"]["version"] == "0.0.0"

    today = datetime.now().astimezone().strftime("%Y.%m.%d")

    first = client.put(f"{ADMIN}/config", headers=admin_headers, json={"dailyCap": 300})
    assert first.status_code == 200, first.text
    row = config_row(db_session, CONFIG_VERSION_KEY)
    assert row is not None, "保存成功后 config_version 必须存在"
    assert row.value == f"{today}-1", f"格式必须是 <yyyy.MM.dd>-<n>，实际 {row.value!r}"
    assert row.version == row.value, "value 与 version 两列同写（下发端读 value or version）"

    audit = client.get(f"{ADMIN}/logs?action=update_config", headers=admin_headers).json()["data"]
    assert audit["total"] == 1
    assert audit["items"][0]["detail"]["configVersion"] == {"before": None, "after": f"{today}-1"}, (
        "首次保存前没有这一行 → 审计记 null 而不是编造 0.0.0"
    )

    second = client.put(f"{ADMIN}/config", headers=admin_headers, json={"dailyCap": 310})
    assert second.status_code == 200, second.text
    assert config_row(db_session, CONFIG_VERSION_KEY).value == f"{today}-2", "同日再次保存 → n 递增"

    # 交叉断言（t17 已落地的客户端端点，免 token）：下发的 version 就是库里这一份
    assert client.get("/api/v1/config").json()["data"]["version"] == f"{today}-2"


def test_config_version_next_format_resets_across_days() -> None:
    """格式 `<yyyy.MM.dd>-<n>`：同日递增、跨日（或首次保存）重置为 1。"""
    from datetime import datetime

    from admin_web.services.system_config import next_version

    midday = datetime(2026, 11, 7, 12, 0, 0)
    assert next_version("2026.11.07-3", now=midday) == "2026.11.07-4"
    assert next_version("2026.11.06-9", now=midday) == "2026.11.07-1", "跨日重置为 1"
    assert next_version("", now=midday) == "2026.11.07-1", "首次保存"


def test_config_put_failure_rolls_back_version_and_config(
    client: Any, admin_headers: dict[str, str], db_session: Any
) -> None:
    """验收：校验不通过 / 事务回滚时**不得** bump 版本号，也不得留下半份配置（同一事务）。"""
    ok = client.put(f"{ADMIN}/config", headers=admin_headers, json={"dailyCap": 300})
    assert ok.status_code == 200, ok.text
    good_version = config_row(db_session, "config_version").value

    unknown = client.put(
        f"{ADMIN}/config", headers=admin_headers, json={"goalRewards": [{"id": "ZZ", "reward": 1}]}
    )
    assert unknown.status_code == 404 and unknown.json()["code"] == "NOT_FOUND"

    # 关键用例：同一请求里「先写 dailyCap、再撞未知目标」→ 整个事务回滚
    partial = client.put(
        f"{ADMIN}/config",
        headers=admin_headers,
        json={"dailyCap": 400, "goalRewards": [{"id": "ZZ", "reward": 1}]},
    )
    assert partial.status_code == 404 and partial.json()["code"] == "NOT_FOUND"

    invalid = client.put(f"{ADMIN}/config", headers=admin_headers, json={"dailyCap": -1})
    assert invalid.status_code == 400 and invalid.json()["code"] == "INVALID_REQUEST"

    assert config_row(db_session, "config_version").value == good_version, "失败的保存不得 bump 版本号"
    assert config_row(db_session, "points_daily_cap").value == "300", (
        "回滚后封顶值保持失败前的值（不出现『配置改了版本没动』）"
    )
    assert client.get(f"{ADMIN}/config", headers=admin_headers).json()["data"]["dailyCap"] == 300


def test_config_no_op_save_does_not_bump_version(
    client: Any, admin_headers: dict[str, str], db_session: Any
) -> None:
    """无改动保存是幂等成功：不写第二条审计、不推版本号（与商品目录同语义）。

    "版本动了但配置没改"正是验收禁止的那一半中间态 —— 这里把它钉住。
    """
    assert client.put(f"{ADMIN}/config", headers=admin_headers, json={"dailyCap": 300}).status_code == 200
    before = config_row(db_session, "config_version").value

    same = client.put(f"{ADMIN}/config", headers=admin_headers, json={"dailyCap": 300, "badgesEnabled": 1})
    assert same.status_code == 200, same.text
    assert same.json()["data"]["changed"] == [], "无改动 → changed 为空"

    assert config_row(db_session, "config_version").value == before, "无改动不得推版本号"
    logs = client.get(f"{ADMIN}/logs?action=update_config", headers=admin_headers).json()["data"]
    assert logs["total"] == 1, "无改动不写审计（版本号也不会动）"


def test_config_put_rejects_unknown_goal_and_bad_values(client: Any, admin_headers: dict[str, str]) -> None:
    unknown = client.put(
        f"{ADMIN}/config", headers=admin_headers, json={"goalRewards": [{"id": "ZZ", "reward": 1}]}
    )
    assert unknown.status_code == 404 and unknown.json()["code"] == "NOT_FOUND"

    negative = client.put(f"{ADMIN}/config", headers=admin_headers, json={"dailyCap": -1})
    assert negative.status_code == 400 and negative.json()["code"] == "INVALID_REQUEST"

    bad_switch = client.put(f"{ADMIN}/config", headers=admin_headers, json={"badgesEnabled": 7})
    assert bad_switch.status_code == 400


def test_config_page_is_server_rendered(client: Any, session_cookie: dict[str, str]) -> None:
    page = client.get(f"{ADMIN}/config", headers={**session_cookie, **HTML_ACCEPT})
    assert page.status_code == 200
    assert "每日记录积分封顶值" in page.text and "徽章开关" in page.text and "光盘卫士" in page.text


# --------------------------------------------------------------------------- #
# ⑦ 操作日志（D10-6）
# --------------------------------------------------------------------------- #
def test_logs_are_newest_first_with_operator_and_action(client: Any, admin_headers: dict[str, str]) -> None:
    """D10-6：做 3 次后台操作 → 日志按时间倒序列出操作人 / 动作 / 时间。"""
    client.patch(f"{ADMIN}/items/frame_01", headers=admin_headers, json={"price": 1001})
    client.patch(f"{ADMIN}/items/frame_02", headers=admin_headers, json={"onShelf": 0})
    client.put(f"{ADMIN}/config", headers=admin_headers, json={"dailyCap": 210})

    data = client.get(f"{ADMIN}/logs", headers=admin_headers).json()["data"]
    assert data["total"] == 5, "3 次操作 + 引导创建 + 登录"
    assert [row["action"] for row in data["items"]] == [
        "update_config",
        "toggle_shelf",
        "change_price",
        "login",
        "bootstrap_admin",
    ]
    timestamps = [row["createdAt"] for row in data["items"]]
    assert timestamps == sorted(timestamps, reverse=True), "必须按时间倒序"
    assert all(row["adminUsername"] == ADMIN_USERNAME for row in data["items"])
    assert data["items"][0]["ip"], "日志要记调用方 IP"


def test_logs_page_is_server_rendered_and_filterable(client: Any, session_cookie: dict[str, str]) -> None:
    client.patch(f"{ADMIN}/items/frame_01", headers=session_cookie, json={"price": 1313})
    page = client.get(f"{ADMIN}/logs", headers={**session_cookie, **HTML_ACCEPT})
    assert page.status_code == 200
    assert "操作日志" in page.text and "改价" in page.text

    filtered = client.get(f"{ADMIN}/logs?action=change_price", headers={**session_cookie, **HTML_ACCEPT})
    assert filtered.status_code == 200
    assert "筛选：改价" in filtered.text


def test_logs_detail_never_contains_secrets(client: Any, admin_headers: dict[str, str], settings: Any) -> None:
    """日志与页面都不得出现密钥 / 口令 / 哈希。"""
    client.patch(f"{ADMIN}/items/frame_01", headers=admin_headers, json={"price": 777})
    raw = client.get(f"{ADMIN}/logs", headers=admin_headers).text
    for secret in (settings.admin_jwt_secret, settings.jwt_secret, ADMIN_PASSWORD, "$2b$"):
        assert secret not in raw


# --------------------------------------------------------------------------- #
# 管理侧独立 JWT 隔离（D10-7 / A13 / AGENTS §7.2）
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("path", ADMIN_PATHS)
def test_client_token_on_every_admin_path_is_forbidden(client: Any, path: str) -> None:
    """**客户端 token 访问任何 `/admin/*` 必须 403**（附录 B §5.4 / D10-7 / 验收 A13）。"""
    account = register_user(client)
    response = client.get(path, headers=auth_header(account["token"]), follow_redirects=False)
    assert response.status_code == 403, f"{path} 应 403，实际 {response.status_code}"
    body = response.json()
    assert body["ok"] is False and body["code"] == "FORBIDDEN" and body["message"]


def test_client_token_forbidden_on_admin_write_methods(client: Any) -> None:
    """写方法同样 403（不是只挡 GET）—— 中间件在进路由之前判定。"""
    account = register_user(client)
    headers = auth_header(account["token"])
    assert client.post(f"{ADMIN}/login", headers=headers, json={"username": "x", "password": "y"}).status_code == 403
    assert client.post(f"{ADMIN}/items", headers=headers, json={}).status_code == 403
    assert client.patch(f"{ADMIN}/items/frame_01", headers=headers, json={}).status_code == 403
    assert client.put(f"{ADMIN}/config", headers=headers, json={}).status_code == 403
    assert client.post(f"{ADMIN}/items/frame_01/icon", headers=headers, content=b"x").status_code == 403
    assert client.delete(f"{ADMIN}/items/frame_01", headers=headers).status_code == 403


def test_admin_token_is_not_accepted_by_the_client_api(client: Any, admin_headers: dict[str, str]) -> None:
    """反方向也隔离：管理端令牌打客户端接口 → 401 TOKEN_INVALID（两套 audience + 两把密钥）。"""
    response = client.get(f"{AUTH}/me", headers=admin_headers)
    assert response.status_code == 401
    assert response.json()["code"] == "TOKEN_INVALID"


def test_two_token_families_use_different_keys_and_audiences(client: Any, admin: dict[str, Any], settings: Any) -> None:
    """管理端令牌只能用管理侧密钥 + 管理侧 audience 校验（客户端密钥验不过）。"""
    from app.core.errors import AppError
    from app.core.security import decode_admin_token, decode_user_token

    aud_admin = Settings.model_fields["jwt_admin_audience"].default
    assert aud_admin == "carbonboo-admin"
    assert settings.jwt_secret != settings.admin_jwt_secret

    claims = jwt.decode(
        admin["token"],
        settings.admin_jwt_secret,
        algorithms=[settings.jwt_algorithm],
        audience=aud_admin,
        issuer=settings.jwt_issuer,
    )
    assert claims["aud"] == aud_admin

    with pytest.raises(AppError):
        decode_user_token(admin["token"], settings)
    # 客户端 token 交给管理端解码器也必须失败
    account = register_user(client)
    with pytest.raises(AppError):
        decode_admin_token(account["token"], settings)


def test_missing_or_garbage_token_is_not_403(client: Any) -> None:
    """403 专指"拿着客户端令牌闯管理端"；无令牌 / 坏令牌按 401 / 303 / 404 处理。"""
    assert client.get(f"{ADMIN}/items").status_code == 401
    assert client.get(f"{ADMIN}/items", headers=auth_header("not-a-jwt")).status_code == 401
    assert client.get(f"{ADMIN}/__probe_not_registered__").status_code == 404
    assert client.get(f"{ADMIN}/__probe_not_registered__", headers=auth_header("not-a-jwt")).status_code == 404


def test_admin_routes_do_not_touch_the_client_api_surface(client: Any) -> None:
    """后台只是挂载进来（可选件）：客户端 API 路径与鉴权行为一条不变。"""
    assert client.get("/api/v1/health").status_code == 200
    assert client.get(SHOP).status_code == 200, "取价仍无需令牌（唯一免令牌接口）"
    assert client.get(f"{AUTH}/me").status_code == 401


# --------------------------------------------------------------------------- #
# 强口令 + 登录限流（AGENTS §6）
# --------------------------------------------------------------------------- #
def test_admin_login_rate_limited_returns_429(client: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """登录限流：超限 → 429 RATE_LIMITED；且与客户端登录计数互不干扰。"""
    from app.core.config import reset_settings_cache
    from app.core.ratelimit import reset_login_limit

    monkeypatch.setenv("LOGIN_RATE_LIMIT_PER_MINUTE", "2")
    reset_settings_cache()
    reset_login_limit()
    try:
        payload = {"username": ADMIN_USERNAME, "password": "wrong-password"}
        assert client.post(f"{ADMIN}/login", json=payload).status_code == 401
        assert client.post(f"{ADMIN}/login", json=payload).status_code == 401
        limited = client.post(f"{ADMIN}/login", json=payload)
        assert limited.status_code == 429
        assert limited.json()["code"] == "RATE_LIMITED"

        # 客户端登录是另一把键（ip|username），不受管理端计数影响
        account = register_user(client)
        assert (
            client.post(
                f"{AUTH}/login", json={"username": account["username"], "password": account["password"]}
            ).status_code
            == 200
        )
    finally:
        reset_login_limit()
        reset_settings_cache()


def test_password_policy_module_is_the_single_source() -> None:
    """强口令策略只有一个定义处（security.password_policy_problems），引导 / 改密 / CLI 共用。"""
    from admin_web import security
    from admin_web.cli import cmd_create_admin

    assert security.ADMIN_PASSWORD_MIN_LENGTH >= 12
    assert security.password_policy_problems("CarbonBoo#2026admin") == []
    assert security.password_policy_problems("short") != []
    assert cmd_create_admin is not None


# --------------------------------------------------------------------------- #
# 结构与约定（PLAN §13.3 / AGENTS §7.1）
# --------------------------------------------------------------------------- #
def test_no_frontend_framework_and_no_build_chain() -> None:
    """页面是 Jinja2 服务端渲染 + 少量原生 JS：无前端框架、无构建链、无第三方包。"""
    from admin_web.config import ADMIN_WEB_DIR

    files = [path for path in ADMIN_WEB_DIR.rglob("*") if path.is_file() and "__pycache__" not in path.parts]
    names = {path.name for path in files}
    assert "package.json" not in names and "webpack.config.js" not in names and "vite.config.js" not in names
    assert not (ADMIN_WEB_DIR / "node_modules").exists()

    assert [path.name for path in files if path.suffix == ".js"] == ["admin.js"], "只有一个原生 JS 文件"
    assert [path.name for path in files if path.suffix == ".css"] == ["admin.css"], "只有一个 CSS 文件"

    forbidden = ("react.", "vue.js", "jquery", "getbootstrap", "bootstrap.min", "tailwind", "cdn.jsdelivr", "unpkg.com")
    for path in files:
        if path.suffix in (".html", ".js", ".css"):
            lowered = path.read_text(encoding="utf-8").lower()
            for token in forbidden:
                assert token not in lowered, f"{path.name} 出现了前端框架/ CDN 痕迹：{token}"


def test_pages_are_rendered_server_side_not_left_as_placeholders(client: Any, session_cookie: dict[str, str]) -> None:
    """模板真的被渲染过（没有残留 `{{ }}` / `{% %}`），且数据来自库（种子商品名出现在 HTML 里）。"""
    for path in (ADMIN, f"{ADMIN}/items", f"{ADMIN}/users", f"{ADMIN}/orders", f"{ADMIN}/config", f"{ADMIN}/logs"):
        page = client.get(path, headers={**session_cookie, **HTML_ACCEPT})
        assert page.status_code == 200, f"{path} 应 200（HTML 会话路径），实际 {page.status_code}"
        assert page.headers["content-type"].startswith("text/html")
        assert "{{" not in page.text and "{%" not in page.text, f"{path} 有未渲染的模板标记"
    items_page = client.get(f"{ADMIN}/items", headers={**session_cookie, **HTML_ACCEPT})
    assert "嫩芽" in items_page.text, "页面数据必须来自数据库（服务端渲染，而不是前端再拉一次）"


def test_admin_web_does_not_need_python_multipart(client: Any) -> None:
    """后台不依赖 python-multipart：源码里没有 request.form()/UploadFile，表单体自己解析。"""
    from admin_web.config import ADMIN_WEB_DIR

    for path in ADMIN_WEB_DIR.rglob("*.py"):
        source = path.read_text(encoding="utf-8")
        assert "await request.form(" not in source, f"{path.name} 调用了 request.form()（需要 python-multipart）"
        assert "UploadFile" not in source, f"{path.name} 用了 UploadFile（需要 python-multipart）"
        assert "python_multipart" not in source, f"{path.name} 直接引用了 python_multipart"
    assert client.get(f"{ADMIN}/login").status_code == 200


def test_mount_admin_is_idempotent_and_only_adds_admin_routes() -> None:
    """`mount_admin` 幂等；挂载只增不改：不覆盖服务端切片的 AppError 处理器。"""
    from fastapi import FastAPI

    from admin_web.mount import STATE_KEY, mount_admin

    def count_routes(app: Any) -> int:
        def walk(routes: Any) -> int:
            total = 0
            for route in routes:
                total += 1
                total += walk(getattr(route, "routes", []) or [])
            return total

        return walk(app.routes)

    bare = FastAPI()
    single, double = FastAPI(), FastAPI()
    mount_admin(single)
    mount_admin(double)
    mount_admin(double)  # 第二次必须是空操作
    assert count_routes(single) == count_routes(double), "重复挂载不得重复注册路由"
    assert count_routes(single) > count_routes(bare), "挂载确实加了路由（不是空挂）"
    assert getattr(double.state, STATE_KEY) is True

    from app.core.errors import AppError

    from app.main import create_app

    app = create_app()
    assert AppError in app.exception_handlers
    assert app.exception_handlers[AppError].__module__ == "app.main", "不得覆盖服务端切片的错误信封处理器"
    assert app.router is not None


def test_cli_create_admin_and_reset_password(client: Any, db_session: Any) -> None:
    """命令行创建 / 重置管理员（忘记口令的正规找回路径）；口令同样过强口令策略。"""
    from admin_web import cli

    assert cli.main(["create-admin", "--username", "cli_admin", "--password", ADMIN_PASSWORD]) == 0
    row = db_session.execute(text("SELECT id, password_hash FROM admin_user WHERE username = 'cli_admin'")).one()
    assert row.password_hash.startswith("$2b$")
    assert client.post(f"{ADMIN}/login", json={"username": "cli_admin", "password": ADMIN_PASSWORD}).status_code == 200

    # 已存在且没 --reset → 明确失败而不是静默改名
    assert cli.main(["create-admin", "--username", "cli_admin", "--password", ADMIN_PASSWORD]) == 1

    assert cli.main(["create-admin", "--username", "cli_admin", "--password", "weakpass1111", "--reset"]) == 1
    assert cli.main(["create-admin", "--username", "cli_admin", "--password", ADMIN_NEW_PASSWORD, "--reset"]) == 0
    assert client.post(f"{ADMIN}/login", json={"username": "cli_admin", "password": ADMIN_PASSWORD}).status_code == 401
    assert (
        client.post(f"{ADMIN}/login", json={"username": "cli_admin", "password": ADMIN_NEW_PASSWORD}).status_code == 200
    )
    assert cli.main(["list-admins"]) == 0


def test_malformed_json_body_is_400_not_500(client: Any, admin_headers: dict[str, str]) -> None:
    """手工读 body 的代价要自己补回来：坏 JSON / 字段不合法必须是 400 INVALID_REQUEST（不是 500）。"""
    broken = client.post(
        f"{ADMIN}/login",
        content=b"{not json",
        headers={"Content-Type": "application/json"},
    )
    assert broken.status_code == 400, f"坏 JSON 应 400，实际 {broken.status_code}"
    assert broken.json()["code"] == "INVALID_REQUEST"

    empty = client.post(f"{ADMIN}/login", content=b"", headers={"Content-Type": "application/json"})
    assert empty.status_code == 400

    wrong_types = client.post(
        f"{ADMIN}/login", headers={"Content-Type": "application/json"}, json={"username": 42, "password": ["x"]}
    )
    assert wrong_types.status_code == 400
    assert wrong_types.json()["code"] == "INVALID_REQUEST"

    patched = client.post(
        f"{ADMIN}/items/frame_01/icon",
        headers={**admin_headers, "Content-Type": "application/json"},
        content=b"{oops",
    )
    assert patched.status_code == 400
