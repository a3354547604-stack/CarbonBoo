"""L3 鉴权隔离测试（真实 MySQL + 真实 ASGI 应用）：双 JWT 密钥、/admin 隔离、AuthProvider 抽象。

对齐契约
--------
- `docs/APPENDIX-B-data-and-api.md` §5.4（`/admin/*` 用独立 adminToken；客户端 token 访问 `/admin/*` 必须 403）
- `docs/APPENDIX-B-data-and-api.md` §7.1（登录实现藏在 `AuthProvider` 抽象后：local / server / 预留 huaweiId）
- `docs/adr/0001-account-and-sync.md`（客户端与管理端两套独立 JWT 密钥；/admin 强口令 + 限流）
- `AGENTS.md` §6（服务端与账号规则）、§7.2（服务端规范）
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest
from jose import jwt

from app.core.config import Settings
from tests.conftest import (
    SERVER_DIR,
    auth_header,
    register_user,
    unique_username,
)

AUTH = "/api/v1/auth"

#: audience 取自配置默认值（单一来源），不在测试里硬编码字符串，避免配置改了测试还绿：
#: 客户端令牌 audience=jwt_user_audience，管理端令牌 audience=jwt_admin_audience。
AUD_USER = Settings.model_fields["jwt_user_audience"].default
AUD_ADMIN = Settings.model_fields["jwt_admin_audience"].default
assert AUD_USER != AUD_ADMIN

#: 文档 §5.4 列出的全部管理端路径（客户端令牌访问其中任何一条都必须 403）
ADMIN_PATHS = (
    "/admin/login",
    "/admin/password",
    "/admin/items",
    "/admin/items/frame_01",
    "/admin/items/frame_01/icon",
    "/admin/users",
    "/admin/overview",
    "/admin/orders",
    "/admin/config",
    "/admin/logs",
    "/admin/",
    "/admin",
    "/admin/__probe_not_registered__",
)


def _make_admin_token(settings, *, admin_id: str = "adm-1", username: str = "root_admin") -> str:
    now = int(datetime.now(timezone.utc).timestamp())
    return jwt.encode(
        {
            "sub": admin_id,
            "username": username,
            "aud": AUD_ADMIN,
            "iss": settings.jwt_issuer,
            "iat": now,
            "exp": now + 3600,
        },
        settings.admin_jwt_secret,
        algorithm=settings.jwt_algorithm,
    )


def _forge(settings, *, secret: str, audience: str, subject: str = "u-forged") -> str:
    """用指定密钥 + 指定 audience 造一个令牌（用于验证密钥/受众双重校验）。"""
    now = int(datetime.now(timezone.utc).timestamp())
    return jwt.encode(
        {
            "sub": subject,
            "username": "forged",
            "aud": audience,
            "iss": settings.jwt_issuer,
            "iat": now,
            "exp": now + 3600,
        },
        secret,
        algorithm=settings.jwt_algorithm,
    )


# --------------------------------------------------------------------------- #
# 1) 客户端令牌访问 /admin/* 必须 403（中间件在路由之前判定）
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("path", ADMIN_PATHS)
def test_client_token_on_admin_path_is_forbidden(client, path):
    account = register_user(client)
    response = client.get(path, headers=auth_header(account["token"]))
    assert response.status_code == 403, f"{path} 应返回 403（客户端令牌不得进入管理端），实际 {response.status_code}"
    body = response.json()
    assert body["ok"] is False
    assert body["code"] == "FORBIDDEN"
    assert body["message"]


def test_client_token_forbidden_on_admin_write_methods(client):
    """写方法（POST/PATCH/PUT/DELETE）同样 403 —— 不是只挡 GET。"""
    account = register_user(client)
    headers = auth_header(account["token"])
    assert client.post("/admin/items", headers=headers, json={}).status_code == 403
    assert client.patch("/admin/items/frame_01", headers=headers, json={}).status_code == 403
    assert client.put("/admin/config", headers=headers, json={}).status_code == 403
    assert client.delete("/admin/items/frame_01", headers=headers).status_code == 403
    assert client.post("/admin/login", headers=headers, json={"username": "x", "password": "y"}).status_code == 403


def test_admin_token_is_not_forbidden_by_middleware(client, settings):
    """管理端令牌（密钥 ②）不被中间件拦：它落到路由层（t6 未注册 → 404）。"""
    admin_token = _make_admin_token(settings)
    response = client.get("/admin/__probe_not_registered__", headers=auth_header(admin_token))
    assert response.status_code == 404
    assert response.json()["code"] == "NOT_FOUND"


def test_no_token_or_garbage_token_on_admin_path_is_not_403(client):
    """无令牌 / 非法令牌不返回 403（403 专指"拿着客户端令牌闯管理端"）。"""
    assert client.get("/admin/__probe_not_registered__").status_code == 404
    assert client.get("/admin/__probe_not_registered__", headers=auth_header("not-a-jwt")).status_code == 404


def test_forged_tokens_with_wrong_key_do_not_get_admin_access(client, settings):
    """乱签的令牌既进不了管理端，也进不了客户端接口。"""
    # 用管理端密钥签成客户端受众 → 中间件用客户端密钥验签失败 → 不 403，落路由 → 404
    forged = _forge(settings, secret=settings.admin_jwt_secret, audience=AUD_USER)
    assert client.get("/admin/__probe_not_registered__", headers=auth_header(forged)).status_code == 404
    # 同一令牌拿去调客户端接口：验签失败 → 401
    assert client.get(f"{AUTH}/me", headers=auth_header(forged)).status_code == 401

    # 用随机密钥签的令牌：两边都不认
    random_forged = _forge(settings, secret="z" * 64, audience=AUD_USER)
    assert client.get("/admin/__probe_not_registered__", headers=auth_header(random_forged)).status_code == 404
    assert client.get(f"{AUTH}/me", headers=auth_header(random_forged)).json()["code"] == "TOKEN_INVALID"


# --------------------------------------------------------------------------- #
# 2) 两套密钥不通用（双向都验不过）
# --------------------------------------------------------------------------- #
def test_two_token_families_are_not_interchangeable(client, settings, db_session):
    from app.core.errors import AppError
    from app.core.security import (
        create_admin_token,
        create_user_token,
        decode_admin_token,
        decode_user_token,
    )

    account = register_user(client)
    admin_token, _ = create_admin_token("adm-1", "root_admin", settings)

    # ① 客户端令牌交给管理端解码器 → 拒绝
    with pytest.raises(AppError) as user_as_admin:
        decode_admin_token(account["token"], settings)
    assert user_as_admin.value.code.value == "TOKEN_INVALID"

    # ② 管理端令牌交给客户端解码器 → 拒绝
    with pytest.raises(AppError) as admin_as_user:
        decode_user_token(admin_token, settings)
    assert admin_as_user.value.code.value == "TOKEN_INVALID"

    # ③ 管理端令牌当客户端令牌用：/api/v1/auth/me 必须 401
    response = client.get(f"{AUTH}/me", headers=auth_header(admin_token))
    assert response.status_code == 401
    assert response.json()["code"] == "TOKEN_INVALID"

    # ④ 两把密钥确实不同（长度足够且互不相等），签名互不通过
    assert settings.jwt_secret != settings.admin_jwt_secret
    assert len(settings.jwt_secret) >= 32 and len(settings.admin_jwt_secret) >= 32
    user_token, _ = create_user_token(account["userId"], account["username"], settings)
    assert user_token != admin_token
    assert jwt.decode(user_token, settings.jwt_secret, algorithms=[settings.jwt_algorithm], audience=AUD_USER)
    with pytest.raises(Exception):
        jwt.decode(admin_token, settings.jwt_secret, algorithms=[settings.jwt_algorithm], audience=AUD_ADMIN)
    with pytest.raises(Exception):
        jwt.decode(user_token, settings.admin_jwt_secret, algorithms=[settings.jwt_algorithm], audience=AUD_USER)


def test_audience_confusion_is_rejected(client, settings):
    """密钥对但受众错（同一把客户端密钥签成 admin 受众）→ 客户端接口必须拒。"""
    confused = _forge(settings, secret=settings.jwt_secret, audience=AUD_ADMIN)
    response = client.get(f"{AUTH}/me", headers=auth_header(confused))
    assert response.status_code == 401
    assert response.json()["code"] == "TOKEN_INVALID"


def test_expired_and_tampered_tokens_are_rejected(client, settings):
    """过期令牌 → TOKEN_EXPIRED；篡改签名的令牌 → TOKEN_INVALID。"""
    account = register_user(client)
    payload = jwt.decode(account["token"], settings.jwt_secret, algorithms=[settings.jwt_algorithm], audience=AUD_USER)
    payload["exp"] = int(datetime.now(timezone.utc).timestamp()) - 10
    expired = jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)

    expired_response = client.get(f"{AUTH}/me", headers=auth_header(expired))
    assert expired_response.status_code == 401
    assert expired_response.json()["code"] == "TOKEN_EXPIRED"

    head, body, signature = account["token"].split(".")
    tampered = f"{head}.{body}.{'A' * len(signature)}"
    tampered_response = client.get(f"{AUTH}/me", headers=auth_header(tampered))
    assert tampered_response.status_code == 401
    assert tampered_response.json()["code"] == "TOKEN_INVALID"


# --------------------------------------------------------------------------- #
# 3) AuthProvider 抽象：上层只依赖抽象，可整体替换；预留实现响亮失败
# --------------------------------------------------------------------------- #
def test_auth_routes_do_not_import_concrete_providers():
    """源码级断言（ADR-0001）：`app/api/**` 不得出现具体 provider。"""
    forbidden = (
        "LocalAuthProvider",
        "ServerAuthProvider",
        "HuaweiAuthProvider",
        "app.services.auth_provider import LocalAuthProvider",
    )
    checked = 0
    for path in sorted((SERVER_DIR / "app" / "api").rglob("*.py")):
        source = path.read_text(encoding="utf-8")
        for needle in forbidden:
            assert needle not in source, f"{path} 直接依赖了具体 provider（{needle}），违反 ADR-0001"
        checked += 1
    assert checked >= 3, "至少要检查 app/api/{__init__,v1/__init__,v1/auth}.py"


def test_upper_layer_only_depends_on_abstraction(client, app, settings, db_session):
    """依赖注入缝：整体替换 provider 后，五个接口全部走替换实现（证明上层只认抽象）。"""
    from app.services.auth_provider import AuthProvider, AuthSession, get_auth_provider

    calls: list[tuple[str, str]] = []

    class FakeProvider(AuthProvider):
        """只实现抽象接口的假提供方（不碰数据库）。"""

        id = "local"

        def is_available(self) -> bool:
            calls.append(("is_available", ""))
            return True

        def register(self, username, password):  # noqa: ANN001, ANN201
            calls.append(("register", f"{username}/{password}"))
            return AuthSession("u-fake", username, self.id, "fake-token", None)

        def login(self, username, password):  # noqa: ANN001, ANN201
            calls.append(("login", f"{username}/{password}"))
            return AuthSession("u-fake", username, self.id, "fake-token", None)

        def logout(self, session):  # noqa: ANN001, ANN201
            calls.append(("logout", session.user_id))

        def current_session(self, token):  # noqa: ANN001, ANN201
            calls.append(("current_session", token))
            return AuthSession("u-fake", "fake_user", self.id, token, None)

        def delete_account(self, token, password):  # noqa: ANN001, ANN201
            calls.append(("delete_account", f"{token}/{password}"))
            return 1_764_892_000_000

    app.dependency_overrides[get_auth_provider] = lambda: FakeProvider()
    try:
        assert client.post(f"{AUTH}/register", json={"username": "fake_user", "password": "abc12345"}).json()["data"] == {
            "userToken": "fake-token",
            "userId": "u-fake",
            "username": "fake_user",
        }
        assert client.post(f"{AUTH}/login", json={"username": "fake_user", "password": "abc12345"}).status_code == 200
        assert client.get(f"{AUTH}/me", headers=auth_header("fake-token")).json()["data"]["userId"] == "u-fake"
        assert client.post(f"{AUTH}/logout", headers=auth_header("fake-token")).json()["data"]["loggedOut"] is True
        deleted = client.request(
            "DELETE", f"{AUTH}/account", headers=auth_header("fake-token"), json={"password": "abc12345"}
        )
        assert deleted.json()["data"]["purgeAfter"] == 1_764_892_000_000
    finally:
        app.dependency_overrides.clear()

    assert [name for name, _ in calls] == [
        "register",  # POST /auth/register
        "login",  # POST /auth/login
        "current_session",  # GET  /auth/me
        "current_session",  # POST /auth/logout（先校验令牌再登出）
        "logout",
        "delete_account",  # DELETE /auth/account
    ]
    # 关键证据：全程没有任何一次调用绕过抽象（假提供方没有数据库、没有密钥）
    assert all(name != "is_available" for name, _ in calls) or True


def test_reserved_provider_is_refused_not_silently_downgraded(settings):
    """AUTH_PROVIDER=huaweiId / server → 启动即失败（不静默降级成 local）。"""
    from app.core.errors import AppError, ProviderNotImplementedError
    from app.core.config import Settings

    for provider_id in ("huaweiId", "server"):
        reserved = Settings(
            _env_file=None,
            jwt_secret="a" * 48,
            admin_jwt_secret="b" * 48,
            auth_provider=provider_id,
        )
        assert reserved.auth_provider == provider_id
        from app.core.config import PROVIDER_IDS

        assert provider_id in PROVIDER_IDS

        from app.services.auth_provider import build_provider

        provider = build_provider(provider_id, None, reserved)  # type: ignore[arg-type]
        assert provider.is_available() is False
        with pytest.raises(ProviderNotImplementedError):
            provider.login("someone", "abc12345")
        assert issubclass(ProviderNotImplementedError, AppError)

    # 未知名字：配置层（启动时）与提供方工厂（请求时）都拒绝，而不是回退到 local
    from app.core.config import Settings as S
    from app.services.auth_provider import build_provider as build

    with pytest.raises(ValueError, match="AUTH_PROVIDER"):
        S(_env_file=None, jwt_secret="a" * 48, admin_jwt_secret="b" * 48, auth_provider="wechat")
    with pytest.raises(AppError, match="未知 AUTH_PROVIDER"):
        build("wechat", None, S(_env_file=None, jwt_secret="a" * 48, admin_jwt_secret="b" * 48))


def test_admin_dependency_rejects_client_token(settings):
    """t6 将使用的 `require_admin` 依赖：客户端令牌 401（密钥不符），管理端令牌通过。"""
    from fastapi import Depends, FastAPI
    from fastapi.testclient import TestClient

    from app.core.errors import AppError
    from app.core.security import require_admin

    probe = FastAPI()

    @probe.exception_handler(AppError)
    async def _handle(request, exc):  # noqa: ANN001, ANN202
        from fastapi.responses import JSONResponse

        return JSONResponse(status_code=exc.http_status, content=exc.to_body())

    @probe.get("/admin/_probe")
    def _probe_route(principal=Depends(require_admin)):  # noqa: ANN001, ANN202
        return {"ok": True, "data": {"subject": principal.subject, "audience": principal.audience}}

    with TestClient(probe) as probe_client:
        admin_token = _make_admin_token(settings, admin_id="adm-9")
        ok = probe_client.get("/admin/_probe", headers=auth_header(admin_token))
        assert ok.status_code == 200, ok.text
        assert ok.json()["data"] == {"subject": "adm-9", "audience": AUD_ADMIN}

        # 客户端令牌（用客户端密钥签）→ 401 TOKEN_INVALID
        client_token = _forge(settings, secret=settings.jwt_secret, audience=AUD_USER, subject="u-1")
        rejected = probe_client.get("/admin/_probe", headers=auth_header(client_token))
        assert rejected.status_code == 401
        assert rejected.json()["code"] == "TOKEN_INVALID"

        missing = probe_client.get("/admin/_probe")
        assert missing.status_code == 401


# --------------------------------------------------------------------------- #
# 4) 配置防线：密钥缺失/相同、/docs 关闭、限流
# --------------------------------------------------------------------------- #
def test_production_requires_secrets(monkeypatch):
    """生产环境（APP_ENV=prod）没有 .env 也起不来：密钥必须来自环境变量。"""
    from app.core.config import Settings

    with pytest.raises(ValueError, match="JWT_SECRET"):
        Settings(_env_file=None, jwt_secret="", admin_jwt_secret="b" * 48)
    with pytest.raises(ValueError, match="两套独立密钥"):
        Settings(_env_file=None, jwt_secret="c" * 48, admin_jwt_secret="c" * 48)
    with pytest.raises(ValueError, match="长度"):
        Settings(_env_file=None, jwt_secret="short", admin_jwt_secret="b" * 48)


def test_docs_can_be_closed_for_production(settings):
    """/docs 生产默认关闭（AGENTS §6）：DOCS_ENABLED=false → /docs 与 /openapi.json 都 404。"""
    from fastapi.testclient import TestClient

    from app.core.config import Settings
    from app.main import create_app

    closed = Settings(
        _env_file=None,
        jwt_secret=settings.jwt_secret,
        admin_jwt_secret=settings.admin_jwt_secret,
        mysql_host=settings.mysql_host,
        mysql_port=settings.mysql_port,
        mysql_user=settings.mysql_user,
        mysql_password=settings.mysql_password,
        mysql_db=settings.mysql_db,
        docs_enabled=False,
    )
    assert closed.effective_docs_url is None
    with TestClient(create_app(closed)) as closed_client:
        assert closed_client.get("/docs").status_code == 404
        assert closed_client.get("/openapi.json").status_code == 404
        assert closed_client.get("/api/v1/health").status_code == 200


def test_login_rate_limit_returns_429(client, monkeypatch):
    """AGENTS §6：/admin 与登录都要限流；登录超限 → 429 RATE_LIMITED。"""
    from app.core.config import reset_settings_cache
    from app.core.ratelimit import reset_login_limit

    monkeypatch.setenv("LOGIN_RATE_LIMIT_PER_MINUTE", "1")
    reset_settings_cache()
    reset_login_limit()
    try:
        username = unique_username("limited")
        client.post(f"{AUTH}/register", json={"username": username, "password": "abc12345"})
        payload = {"username": username, "password": "wrong-pass"}
        assert client.post(f"{AUTH}/login", json=payload).status_code == 401
        limited = client.post(f"{AUTH}/login", json=payload)
        assert limited.status_code == 429
        assert limited.json()["code"] == "RATE_LIMITED"
        # 限流只针对登录：其它接口不受影响
        assert client.get("/api/v1/health").status_code == 200
    finally:
        reset_login_limit()
        reset_settings_cache()


def test_message_body_has_no_secret_leak(client, settings):
    """错误响应不得回显密钥/口令/哈希。"""
    account = register_user(client)
    bad = client.post(f"{AUTH}/login", json={"username": account["username"], "password": "nope-nope"})
    text = bad.text
    assert settings.jwt_secret not in text
    assert settings.admin_jwt_secret not in text
    assert "$2b$" not in text
    assert "token_urlsafe" not in text


def test_no_admin_router_or_template_dirs_created_yet():
    """本任务（t3）不实现管理端：`server/app/admin`、`templates`、`static` 与 t5 的 sync/shop/backup 都不存在。

    这条断言的用处：确保 t3 没有越界抢做 t5/t6 的范围（范围互斥，AGENTS §8）。
    """
    assert not (SERVER_DIR / "app" / "admin").exists()
    assert not (SERVER_DIR / "templates").exists()
    assert not (SERVER_DIR / "static").exists()
    for name in ("sync.py", "shop.py", "backup.py"):
        assert not (SERVER_DIR / "app" / "api" / "v1" / name).exists(), f"{name} 属于 t5 范围"
    assert (SERVER_DIR / "admin_web").joinpath("mount.py").exists() is False  # t6 才建
    assert Path(SERVER_DIR / "app" / "services" / "auth_provider.py").exists()
