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
