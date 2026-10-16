"""L3 取价链路测试（真实 MySQL + 真实 ASGI 应用，**无 mock、无 skip**）。

覆盖（附录 B §5.4）
------------------
* `GET /api/v1/shop/items` **无需令牌**（唯一不需要 token 的客户端接口）；
* 响应形状逐字对齐 §5.4：`{ok, data:{version, items:[{id, section, name, price, icon, order, onShelf, isDefaultFree}]}}`
  —— camelCase、`order` 是整数、不泄漏 snake_case 列名；
* 目录**含已下架商品**（`onShelf = 0`）并如实带标志，客户端 `ShopRules.check` 才能显示「该商品已下架」；
* 价格来自库（后台改价 → 下次启动生效），不是内置常量；8 个头像框总价 51,000（附录 B §8.3）；
* 目录版本取 `app_config['shop_items_version']`，缺键时给缺省版本而不是编造日期；
* **失败即整份丢弃**：库异常时返回 `{ok:false, code:"SERVER_ERROR"}` 的信封（客户端据此走内置默认价），
  绝不返回"半个目录"被客户端当成有效价目表覆盖掉。

对齐口径：docs/APPENDIX-B-data-and-api.md §5.4/§8.3、AGENTS §2 铁律 1 例外②、PLAN §11.6。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

SHOP = "/api/v1/shop/items"

#: 附录 B §8.3 的 9 件商品（8 框 + 1 免费主题），与 sql/seed.sql 同源
EXPECTED_IDS = [f"frame_0{i}" for i in range(1, 9)] + ["theme_default"]
FRAME_TOTAL_PRICE = 51_000  # 附录 B §8.3 写死：8 个头像框总价 51,000 分


def test_shop_items_needs_no_token(client):
    """未登录也能取价（附录 B §5.4：只有取价接口无需 token）。"""
    response = client.get(SHOP)
    assert response.status_code == 200
    payload = response.json()
    assert payload["ok"] is True
    assert payload["data"]["version"] == "2026.02.01-1", "版本号来自 app_config['shop_items_version']"
    assert len(payload["data"]["items"]) == 9


def test_shop_items_shape_matches_appendix_b(client):
    """字段名逐字对齐 §5.4 的响应示例（camelCase，不出现 snake_case 列名）。"""
    item = client.get(SHOP).json()["data"]["items"][0]
    assert set(item) >= {"id", "section", "name", "price", "icon", "order", "onShelf", "isDefaultFree"}
    assert "description" in item, "客户端 ShopItem 有 description（内置价目表同字段）"
    for snake in ("on_shelf", "is_default_free", "created_at", "updated_at"):
        assert snake not in item, f"响应里不该出现列名 {snake}"
    assert isinstance(item["order"], int) and not isinstance(item["order"], bool)
    assert isinstance(item["price"], int)
    assert item["id"] == "frame_01" and item["name"] == "嫩芽" and item["price"] == 1500
    assert item["icon"] == "res://frame_01" and item["onShelf"] == 1 and item["isDefaultFree"] == 0


def test_shop_items_order_and_catalog_match_seed(client):
    """目录顺序 = `section, order, id`（分区之间 frame → theme，与内置价目表同序）。"""
    items = client.get(SHOP).json()["data"]["items"]
    assert [item["id"] for item in items] == EXPECTED_IDS
    assert [item["order"] for item in items] == [1, 2, 3, 4, 5, 6, 7, 8, 1]
    assert [item["section"] for item in items] == ["frame"] * 8 + ["theme"]
    frames = [item for item in items if item["section"] == "frame"]
    assert sum(item["price"] for item in frames) == FRAME_TOTAL_PRICE
    theme = items[-1]
    assert (theme["price"], theme["isDefaultFree"]) == (0, 1)


def test_shop_items_include_off_shelf_items_with_flag(client, db_session):
    """下架商品仍下发（带 `onShelf = 0`）：过滤掉它，客户端的「该商品已下架」规则永远走不到。"""
    db_session.execute(text("UPDATE shop_item SET on_shelf = 0 WHERE id = 'frame_08'"))
    db_session.commit()

    items = client.get(SHOP).json()["data"]["items"]
    assert [item["id"] for item in items] == EXPECTED_IDS
    by_id = {item["id"]: item for item in items}
    assert by_id["frame_08"]["onShelf"] == 0
    assert by_id["frame_01"]["onShelf"] == 1


def test_shop_price_comes_from_database_not_a_constant(client, db_session):
    """后台改价（t6 的 `/admin/items` PATCH 走同一张表）→ 接口按库报价，**下次启动生效**。"""
    db_session.execute(text("UPDATE shop_item SET price = 1234 WHERE id = 'frame_01'"))
    db_session.execute(text("UPDATE app_config SET value = '2026.11.06-2' WHERE id = 'shop_items_version'"))
    db_session.commit()

    payload = client.get(SHOP).json()["data"]
    by_id = {item["id"]: item for item in payload["items"]}
    assert by_id["frame_01"]["price"] == 1234
    assert payload["version"] == "2026.11.06-2"


def test_shop_version_fallback_when_config_missing(client, db_session):
    """`app_config['shop_items_version']` 缺失 → 给缺省版本，但目录仍必须是**完整一份**。"""
    from app.services.shop_service import FALLBACK_VERSION

    db_session.execute(text("DELETE FROM app_config WHERE id = 'shop_items_version'"))
    db_session.commit()

    payload = client.get(SHOP).json()["data"]
    assert payload["version"] == FALLBACK_VERSION
    assert len(payload["items"]) == 9, "版本号缺失不能导致目录残缺"


def test_shop_failure_returns_error_envelope_so_client_can_discard(app, monkeypatch):
    """库异常 → 500 + 统一错误信封（客户端规则：非 200 / 数据非法 → 整份丢弃 → 内置默认价）。

    这里刻意用 `raise_server_exceptions=False`，走的就是浏览器/真机看到的那个响应。
    """
    from app.services import shop_service

    def boom(_db):  # noqa: ANN001, ANN202
        raise RuntimeError("模拟数据库故障（取价回落用例）")

    monkeypatch.setattr(shop_service, "list_items", boom)
    with TestClient(app, raise_server_exceptions=False) as failing_client:
        response = failing_client.get(SHOP)

    assert response.status_code == 500, "非 200 才会触发客户端的整份丢弃"
    body = response.json()
    assert body["ok"] is False and body["code"] == "SERVER_ERROR"
    assert "items" not in body and "items" not in body.get("data", {})
    assert "模拟数据库故障" not in response.text, "错误响应不回显异常文本（不泄密）"


def test_shop_health_and_shop_coexist(client):
    """取价与探活都在 v1 前缀下，且取价不因鉴权中间件被拦（`/admin` 隔离只管 /admin/*）。"""
    assert client.get("/api/v1/health").status_code == 200
    assert client.get(SHOP).status_code == 200


@pytest.mark.parametrize("token", ["not-a-jwt", "Bearer-in-body"])
def test_shop_items_ignores_broken_authorization_header(client, token):
    """取价无需令牌：带了非法 Authorization 也照样返回目录（客户端未登录时可能带着空 token）。"""
    response = client.get(SHOP, headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 200
    assert len(response.json()["data"]["items"]) == 9
