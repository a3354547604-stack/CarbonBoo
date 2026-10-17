"""L3 配置下发通道测试（真实 MySQL + 真实 ASGI 应用，**无 mock、无 skip**）。

覆盖（附录 B §5.5 / 验收 D10-5）
------------------------------
* `GET /api/v1/config` **无需令牌**（与 §5.4 的取价同组：公共只读配置，未登录也要能读到）；
* 响应形状逐字对齐 §5.5：`{ok, data:{version, pointsDailyCap, badgesEnabled, goalRewards:[{goalId,reward}], serverTime}}`
  —— camelCase、不泄漏 snake_case 列名；
* **`badgesEnabled` 是 JSON 布尔**：断言**原始响应文本**里是 `true`/`false`
  （不能用 `is True`，因为 `True == 1` 会被整数 `1` 骗过 —— §5.5 的 ⚠️ 条款）；
* 三项配置**真的来自库**：改库后端点读回新值（D10-5 的闭环证据）；
* `goalRewards` 来自既有 `goal_def` 表（按 `id` 升序、11 条），**未新增任何表**；
* 缺键回落：`config_version` 缺失 → `"0.0.0"`；`points_daily_cap` 缺失 → `200`；`badges_enabled` 缺失 → `true`；
  且**回落时都不改写库**（只读端点的本分）；
* 库异常 → HTTP 500 + `{ok:false, code:"SERVER_ERROR"}`（客户端据此整份丢弃）。

对齐口径：docs/APPENDIX-B-data-and-api.md §5.4/§5.5、AGENTS §2 铁律 1、§6、PLAN §13.2 ⑥。
"""

from __future__ import annotations

import json
import re
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

CONFIG = "/api/v1/config"
ADMIN = "/admin"

#: 引导管理员（强口令：≥12 位 + 4 类字符 + 不在弱口令表，与 test_admin.py 同口径）
ADMIN_USERNAME = "carbonboo_admin"
ADMIN_PASSWORD = "CarbonBoo#2026admin"

#: 附录 B §5.5 响应示例里的字段全集（顺序也照文档）
EXPECTED_FIELDS = ["version", "pointsDailyCap", "badgesEnabled", "goalRewards", "serverTime"]

#: 静态字典的 11 个目标（sql/seed.sql 灌入 `goal_def`；与 PLAN §10.1 同源）
EXPECTED_GOAL_COUNT = 11

#: 不该出现在响应里的库内列名 / snake_case 字段（泄漏 = 把数据库表示带进公共契约）
FORBIDDEN_KEYS = (
    "config_version",
    "points_daily_cap",
    "badges_enabled",
    "goal_id",
    "fetched_at",
    "created_at",
    "updated_at",
    "is_deleted",
)


# --------------------------------------------------------------------------- #
# 免鉴权 + 形状
# --------------------------------------------------------------------------- #
def test_config_needs_no_token(client):
    """未登录也能读到配置（§5.5 鉴权：无）—— 不返回 401/403。"""
    response = client.get(CONFIG)
    assert response.status_code == 200, f"公共只读配置不应要求登录，实际 {response.status_code}: {response.text}"
    assert response.json()["ok"] is True


def test_config_not_rejected_with_broken_authorization_header(client):
    """带一个**垃圾** Authorization 头也必须 200：配置端点根本不看令牌（与取价同款）。"""
    response = client.get(CONFIG, headers={"Authorization": "Bearer not-a-real-token"})
    assert response.status_code == 200, "配置端点不参与鉴权，伪令牌不该让它 401"


@pytest.mark.parametrize("token", ["not-a-jwt", "Bearer-in-body", ""])
def test_config_ignores_client_token(client, token):
    """**任意令牌（含非法/空的）**调用都不被 401/403 拒绝（它是公共配置，不是 `/admin/*`）。"""
    response = client.get(CONFIG, headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 200


def test_config_shape_matches_appendix_b(client):
    """字段名与顺序逐字对齐 §5.5（camelCase；不出现任何 snake_case 列名）。"""
    body = client.get(CONFIG).json()
    data = body["data"]
    assert list(data.keys()) == EXPECTED_FIELDS, f"字段与顺序必须逐字对齐 §5.5，实际 {list(data.keys())}"
    for key in FORBIDDEN_KEYS:
        assert key not in data, f"响应里不该出现列名 {key}"
    assert data["version"] == "0.0.0", "种子里没有 config_version 键 → 缺省版本（非空，不回 null）"
    assert data["pointsDailyCap"] == 200, "种子 points_daily_cap = 200"
    assert data["badgesEnabled"] is True, "缺键 → 缺省启用"
    assert isinstance(data["serverTime"], int) and not isinstance(data["serverTime"], bool)
    assert data["serverTime"] > 1_700_000_000_000, "serverTime 是毫秒时间戳"


def test_config_badges_enabled_is_json_boolean_not_integer(client, db_session):
    """§5.5 的 ⚠️：库内 `1`/`0` 必须序列化成 JSON 布尔 `true`/`false`，**不能**回整数。

    断言**原始响应文本**（`json.loads` 之后 `True == 1` 会掩盖这个缺陷）。
    """
    db_session.execute(
        text("INSERT INTO app_config (id, value, version, fetched_at, created_at, updated_at) "
             "VALUES ('badges_enabled', '1', NULL, NULL, 1, 1) "
             "ON DUPLICATE KEY UPDATE value = VALUES(value)")
    )
    db_session.commit()
    raw_true = client.get(CONFIG).text
    assert re.search(r'"badgesEnabled"\s*:\s*true', raw_true), f"库内 1 必须序列化为 JSON 布尔 true：{raw_true}"

    db_session.execute(text("UPDATE app_config SET value = '0' WHERE id = 'badges_enabled'"))
    db_session.commit()
    raw_false = client.get(CONFIG).text
    assert re.search(r'"badgesEnabled"\s*:\s*false', raw_false), f"库内 0 必须序列化为 JSON 布尔 false：{raw_false}"

    # 再确认一遍"没被 1 骗过"：解析后的类型必须是 bool
    assert json.loads(raw_false)["data"]["badgesEnabled"] is False


# --------------------------------------------------------------------------- #
# D10-5 闭环：后台改 → 端点读回新值（真库）
# --------------------------------------------------------------------------- #
def test_config_reads_daily_cap_from_database(client, db_session):
    """后台改 `app_config['points_daily_cap']` → 端点下发新值（D10-5 的封顶值一半）。"""
    db_session.execute(text("UPDATE app_config SET value = '50' WHERE id = 'points_daily_cap'"))
    db_session.commit()
    assert client.get(CONFIG).json()["data"]["pointsDailyCap"] == 50

    db_session.execute(text("UPDATE app_config SET value = '999' WHERE id = 'points_daily_cap'"))
    db_session.commit()
    assert client.get(CONFIG).json()["data"]["pointsDailyCap"] == 999, "改大也要如实下发（不封顶在服务端）"


def test_config_reads_badges_enabled_from_database(client, db_session):
    """后台关徽章开关 → 端点下发 `false`（D10-5 的徽章开关一半）。"""
    db_session.execute(
        text("INSERT INTO app_config (id, value, version, fetched_at, created_at, updated_at) "
             "VALUES ('badges_enabled', '0', NULL, NULL, 1, 1) "
             "ON DUPLICATE KEY UPDATE value = VALUES(value)")
    )
    db_session.commit()
    assert client.get(CONFIG).json()["data"]["badgesEnabled"] is False


def test_config_reads_goal_rewards_from_existing_goal_def_table(client, db_session):
    """后台改 `goal_def.reward` → 端点下发新分值；且 `goalRewards` 就是既有表的逐行（未新增表）。"""
    before = client.get(CONFIG).json()["data"]["goalRewards"]
    assert len(before) == EXPECTED_GOAL_COUNT, "11 个目标逐行下发（§5.5：goal_def 逐行）"
    assert [row["goalId"] for row in before] == sorted(row["goalId"] for row in before), "按 goal_def.id 升序"
    assert set(before[0]) == {"goalId", "reward"}, "每项只有 goalId / reward 两个字段"

    first_id = before[0]["goalId"]
    db_session.execute(text("UPDATE goal_def SET reward = reward + 7 WHERE id = :gid"), {"gid": first_id})
    db_session.commit()
    after = {row["goalId"]: row["reward"] for row in client.get(CONFIG).json()["data"]["goalRewards"]}
    assert after[first_id] == before[0]["reward"] + 7, "端点必须读库而不是内置常量（D10-5）"


def test_config_goal_def_table_is_still_the_only_source(client, db_session):
    """`goalRewards` 不新增表：条目数 = `goal_def` 行数（删一行 → 少一条）。"""
    db_session.execute(text("DELETE FROM goal_def WHERE id = 'L1'"))
    db_session.commit()
    rows = client.get(CONFIG).json()["data"]["goalRewards"]
    assert len(rows) == EXPECTED_GOAL_COUNT - 1
    assert "L1" not in [row["goalId"] for row in rows]


def test_config_version_priority_and_fallback(client, db_session):
    """`version` 取 `app_config['config_version']`：`value` 优先、`version` 列兜底、缺键 → `0.0.0`。"""
    db_session.execute(
        text("INSERT INTO app_config (id, value, version, fetched_at, created_at, updated_at) "
             "VALUES ('config_version', '2026-11-06-1', '2026-11-06-0', 1, 1, 1) "
             "ON DUPLICATE KEY UPDATE value = VALUES(value), version = VALUES(version)")
    )
    db_session.commit()
    assert client.get(CONFIG).json()["data"]["version"] == "2026-11-06-1", "value 优先于 version 列"

    db_session.execute(text("UPDATE app_config SET value = '' WHERE id = 'config_version'"))
    db_session.commit()
    assert client.get(CONFIG).json()["data"]["version"] == "2026-11-06-0", "value 为空 → 取 version 列"

    db_session.execute(text("DELETE FROM app_config WHERE id = 'config_version'"))
    db_session.commit()
    assert client.get(CONFIG).json()["data"]["version"] == "0.0.0", "键不存在 → 缺省版本（非空）"


def test_config_version_bump_is_visible_to_client(client, db_session):
    """版本号变化必须被端点如实下发（客户端据此判断"内容是否变了"，§5.5 的 ⚠️）。

    注意：**写入侧**（`PUT /admin/config` 成功后递增 `config_version`）不在本端点的职责内，
    见 t6 的 `/admin/config`；这里只证明"库里改了就一定读得到"。
    """
    db_session.execute(
        text("INSERT INTO app_config (id, value, version, fetched_at, created_at, updated_at) "
             "VALUES ('config_version', 'v1', NULL, NULL, 1, 1) "
             "ON DUPLICATE KEY UPDATE value = VALUES(value)")
    )
    db_session.commit()
    assert client.get(CONFIG).json()["data"]["version"] == "v1"
    db_session.execute(text("UPDATE app_config SET value = 'v2' WHERE id = 'config_version'"))
    db_session.commit()
    assert client.get(CONFIG).json()["data"]["version"] == "v2"


# --------------------------------------------------------------------------- #
# D10-5 闭环：**后台 PUT /admin/config** → `GET /api/v1/config` 读回新值（真库、真接口）
# --------------------------------------------------------------------------- #
@pytest.fixture
def admin_env(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> Any:
    """引导凭据 + 独立上传目录（与 test_admin.py 同款；用完清缓存与限流计数）。"""
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
def admin_headers(client: Any, admin_env: Any) -> dict[str, str]:
    """登录后台并返回管理端 Bearer 头（表为空 → 走环境变量引导创建）。"""
    response = client.post(f"{ADMIN}/login", json={"username": ADMIN_USERNAME, "password": ADMIN_PASSWORD})
    assert response.status_code == 200, f"管理员登录应 200，实际 {response.status_code}: {response.text}"
    token = response.json()["data"]["adminToken"]
    assert token, "登录必须返回 adminToken（附录 B §5.4）"
    return {"Authorization": f"Bearer {token}"}


def test_admin_config_write_is_visible_to_client_endpoint(client, admin_headers):
    """**D10-5 的闭环证据**：后台改封顶值 + 徽章开关 + 一个目标奖励 → `/api/v1/config` 全部读回新值。"""
    goal_id = client.get(CONFIG).json()["data"]["goalRewards"][0]["goalId"]
    goal_reward_before = client.get(CONFIG).json()["data"]["goalRewards"][0]["reward"]

    put = client.put(
        f"{ADMIN}/config",
        headers=admin_headers,
        json={"dailyCap": 66, "badgesEnabled": 0, "goalRewards": [{"id": goal_id, "reward": 42}]},
    )
    assert put.status_code == 200, f"后台保存系统配置应 200，实际 {put.status_code}: {put.text}"
    assert set(put.json()["data"]["changed"]) >= {"dailyCap", "badgesEnabled"}, "后台必须如实报出改了哪几项"

    data = client.get(CONFIG).json()["data"]
    assert data["pointsDailyCap"] == 66, "后台把封顶值改小 → 客户端端点必须读到 66"
    assert data["badgesEnabled"] is False, "后台关徽章开关 → 客户端端点必须读到 false"
    rewards = {row["goalId"]: row["reward"] for row in data["goalRewards"]}
    assert rewards[goal_id] == 42, f"后台改目标奖励 → 客户端端点必须读到 42（原 {goal_reward_before}）"

    # 再改回去也应立刻可见（证明不是"只生效一次"）
    assert client.put(
        f"{ADMIN}/config", headers=admin_headers, json={"dailyCap": 200, "badgesEnabled": 1}
    ).status_code == 200
    data2 = client.get(CONFIG).json()["data"]
    assert (data2["pointsDailyCap"], data2["badgesEnabled"]) == (200, True)


def test_admin_config_write_is_visible_and_endpoint_does_not_rewrite(client, admin_headers):
    """只读端点不写 `app_config`（§5.5 语义边界；铁律 1：客户端本地值由客户端自己管）。

    这里的读法用**独立引擎的新连接**逐次读：conftest 的 `db_session` 是 REPEATABLE READ 下的
    长事务，快照在首个 SELECT 时就固定了，看不到其后由 HTTP 连接提交的写入（会假失败）。
    """
    from app.core.database import get_engine

    def snapshot() -> dict[str, str]:
        with get_engine().connect() as conn:
            return dict(conn.execute(text("SELECT id, value FROM app_config")).all())

    before = snapshot()
    assert client.put(f"{ADMIN}/config", headers=admin_headers, json={"dailyCap": 123}).status_code == 200
    after_write = snapshot()
    assert after_write.get("points_daily_cap") == "123", "后台写入必须真的落库"
    assert after_write.get("points_daily_cap") != before.get("points_daily_cap"), "种子值 200 → 123"

    client.get(CONFIG)  # 端点只读
    client.get(CONFIG)
    assert snapshot() == after_write, "GET /api/v1/config 不得新增/改动 app_config 任何一行"


# --------------------------------------------------------------------------- #
# 缺键回落 + 只读（不改写库）
# --------------------------------------------------------------------------- #
def test_config_fallbacks_when_keys_missing(client, db_session):
    """三项全部缺键 → 文档默认值（`0.0.0` / `200` / `true`），且**不写库**。"""
    db_session.execute(text("DELETE FROM app_config WHERE id IN ('config_version', 'points_daily_cap', 'badges_enabled')"))
    db_session.commit()
    data = client.get(CONFIG).json()["data"]
    assert (data["version"], data["pointsDailyCap"], data["badgesEnabled"]) == ("0.0.0", 200, True)

    still_missing = db_session.execute(
        text("SELECT COUNT(*) FROM app_config WHERE id IN ('config_version', 'points_daily_cap', 'badges_enabled')")
    ).scalar_one()
    assert still_missing == 0, "只读端点不得把默认值写回库（§5.5 语义边界：不写 app_config）"


@pytest.mark.parametrize("bad_value", ["abc", "", "12.5", "  ", "null"])
def test_config_daily_cap_falls_back_when_not_integer(client, db_session, bad_value):
    """`points_daily_cap` 不是整数 → 下发 `200`（不报错、不改写库）。"""
    db_session.execute(
        text("UPDATE app_config SET value = :v WHERE id = 'points_daily_cap'"), {"v": bad_value}
    )
    db_session.commit()
    assert client.get(CONFIG).json()["data"]["pointsDailyCap"] == 200


def test_config_daily_cap_negative_falls_back_instead_of_poisoning_client(client, db_session):
    """库里出现负数 → 下发 `200` 而不是 `-1`。

    原因：契约字段是「非负整数」，而客户端规则是「任一字段非法 → 整份丢弃」。
    原样回 `-1` 会让客户端把**封顶值 + 徽章开关 + 目标奖励**三项一起丢掉（§5.5 客户端口径第 2 条）。
    """
    db_session.execute(text("UPDATE app_config SET value = '-1' WHERE id = 'points_daily_cap'"))
    db_session.commit()
    assert client.get(CONFIG).json()["data"]["pointsDailyCap"] == 200


def test_config_does_not_write_audit_or_sync_logs(client, db_session):
    """只读端点不写 `admin_op_log` / `sync_log`（§5.5 语义边界）。"""
    client.get(CONFIG)
    client.get(CONFIG)
    for table in ("admin_op_log", "sync_log"):
        count = db_session.execute(text(f"SELECT COUNT(*) FROM {table}")).scalar_one()
        assert count == 0, f"{table} 不该被只读的配置端点写入"


# --------------------------------------------------------------------------- #
# 失败路径：整份丢弃（客户端据此回落本机配置）
# --------------------------------------------------------------------------- #
def test_config_failure_returns_error_envelope_so_client_can_discard(app, monkeypatch):
    """库异常 → 500 + 统一错误信封（客户端规则：非 200 / 数据非法 → 整份丢弃）。

    刻意用 `raise_server_exceptions=False`，走的就是真机看到的那个响应。
    """
    from app.services import config_service

    def boom(_db):  # noqa: ANN001, ANN202
        raise RuntimeError("模拟数据库故障（配置下发回落用例）")

    monkeypatch.setattr(config_service, "payload", boom)
    with TestClient(app, raise_server_exceptions=False) as failing_client:
        response = failing_client.get(CONFIG)

    assert response.status_code == 500, "非 200 才会触发客户端的整份丢弃"
    body = response.json()
    assert body["ok"] is False and body["code"] == "SERVER_ERROR"
    assert "goalRewards" not in body and "goalRewards" not in body.get("data", {}), "绝不返回半份配置"
    assert "模拟数据库故障" not in response.text, "错误响应不回显异常文本（不泄密）"


def test_config_and_health_and_shop_coexist(client):
    """`/config` 与既有 `/health`、`/shop/items` 互不影响（各自的回落规则独立，§5.5 口径第 6 条）。"""
    assert client.get("/api/v1/health").status_code == 200
    assert client.get("/api/v1/shop/items").status_code == 200
    assert client.get(CONFIG).status_code == 200
