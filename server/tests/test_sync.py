"""L3 同步链路测试（真实 MySQL + 真实 ASGI 应用，**无 mock、无 skip**）。

覆盖
----
* §5.3 `pull` / `push` / `status` 的请求与响应形状（含客户端 `SyncService.applyPull` 读的
  `data.serverTime` / `data.tables` 两个键）；
* §6.3 LWW：新者胜 / 旧者保留并回写 `merged` / 平局比 `deviceId` 字典序；
* §6.4-3 双重幂等：账本表 `INSERT IGNORE` + 业务唯一键兜底，被忽略的行计入 `ignored`；
* §6.4-1 真冲突定义收紧为「两端自上次同步后都改过」，平局分支同一条件计数；
* §6.4-2 软删除（`is_deleted = 1` + 更新 `updated_at`）随增量传播；
* §6.4-6 时钟基准：`offsetMs = 服务端时钟 − 客户端时钟`，±5 分钟容差，超容差写
  `sync_log.error_msg` 但**继续合并**；
* 越权：请求体 `userId` / 行内 `user_id` 与令牌账号不一致 → 403 且**一行都不写**；
* 备份 / 恢复：只存快照（不做 LWW）、恢复即覆盖、恢复前生成快照、账本表只补不删；
* 首次登录「本机历史数据全部上传并入账号」在服务端一侧的行为（ADDR-0001 决策 ①）；
* 注销后云端软删除 + 保留期内恢复，且保留期内**旧令牌不能同步**（ADR-0001 决策 ③）；
* `sql/migrations/*.sql` 的幂等执行与 `uq_pr_source` 按 user_id 隔离；
* `main.py` 的 Web 后台可选挂载点（t6 用 `admin_web.mount.mount_admin`）。

对齐口径：docs/APPENDIX-B-data-and-api.md §5.3/§6、docs/adr/0001-account-and-sync.md、AGENTS §6/§7.2。
每个用例都打到真实 MySQL；断言的数据一律来自接口响应或真实库查询，不用打桩值。
"""

from __future__ import annotations

import sys
import types

import pytest
from sqlalchemy import text

from tests.conftest import (
    MIGRATIONS_DIR,
    SERVER_DIR,
    TEST_PASSWORD,
    auth_header,
    migration_files,
    register_user,
    unique_username,
)

SYNC = "/api/v1/sync"
PUSH = f"{SYNC}/push"
PULL = f"{SYNC}/pull"
STATUS = f"{SYNC}/status"
BACKUP = f"{SYNC}/backup"
RESTORE = f"{SYNC}/backup/restore"

#: 固定时间基准（附录 B §5.3 响应示例里的 1762300000000），让 LWW 判定完全确定
T0 = 1_762_300_000_000
MS_PER_DAY = 86_400_000
MS_PER_MINUTE = 60_000

#: 参与同步的 9 张表（= 客户端 ClientSchema.SYNCED_TABLES，附录 B §6.5）
SYNCED_TABLES = (
    "carbon_record",
    "point_record",
    "user_goal",
    "user_badge",
    "user_purchase",
    "user_appearance",
    "science_progress",
    "carbon_include",
    "user_profile",
)

#: 只增账本（永不 UPDATE、永不物理删除）
LEDGER_TABLES = ("point_record", "carbon_include")


# --------------------------------------------------------------------------- #
# 行构造器（列名逐字取附录 B §2 的建表列）
# --------------------------------------------------------------------------- #
def carbon_record(
    user_id: str,
    rid: str = "rec-0001",
    *,
    amount: float = 1.0,
    updated_at: int = T0,
    is_deleted: int = 0,
    device_id: str | None = "d-a",
) -> dict[str, object]:
    return {
        "id": rid,
        "user_id": user_id,
        "category": "travel",
        "sub_type": "walk",
        "amount": amount,
        "unit": "km",
        "occurred_at": T0 - 1000,
        "reduction_kg": 0.0,
        "factor_value": 0.0,
        "factor_version": "CF-2026.2",
        "factor_source": "SRC-DERIVED",
        "confidence": "verified",
        "point_awarded": 0,
        "point_capped": 0,
        "revision": 0,
        "is_abnormal": 0,
        "created_at": T0 - 1000,
        "updated_at": updated_at,
        "is_deleted": is_deleted,
        "device_id": device_id,
    }


def point_record(
    user_id: str,
    rid: str = "pr-0001",
    *,
    source_type: str = "goal",
    source_id: str = "S1:D:2026-11-06",
    flow_kind: str = "primary",
    points: int = 20,
    type_: str = "goal",
    updated_at: int = T0,
    device_id: str | None = "d-a",
) -> dict[str, object]:
    return {
        "id": rid,
        "user_id": user_id,
        "type": type_,
        "flow_kind": flow_kind,
        "points": points,
        "source_type": source_type,
        "source_id": source_id,
        "title": "零碳出行",
        "remark": None,
        "occurred_at": T0 - 1000,
        "created_at": T0 - 1000,
        "updated_at": updated_at,
        "is_deleted": 0,
        "device_id": device_id,
    }


def user_purchase(
    user_id: str, rid: str = "up-0001", *, item_id: str = "frame_01", updated_at: int = T0, device_id: str = "d-a"
) -> dict[str, object]:
    return {
        "id": rid,
        "user_id": user_id,
        "item_id": item_id,
        "price_paid": 1500,
        "purchased_at": T0 - 1000,
        "created_at": T0 - 1000,
        "updated_at": updated_at,
        "is_deleted": 0,
        "device_id": device_id,
    }


def user_profile(
    user_id: str, rid: str = "uprofile-0001", *, updated_at: int = T0, device_id: str = "d-a"
) -> dict[str, object]:
    return {
        "id": rid,
        "user_id": user_id,
        "display_name": "碳小布用户",
        "register_day": "2026-11-06",
        "onboarded": 1,
        "created_at": T0 - 1000,
        "updated_at": updated_at,
        "is_deleted": 0,
        "device_id": device_id,
    }


# --------------------------------------------------------------------------- #
# 请求小工具
# --------------------------------------------------------------------------- #
def push(
    client,
    account: dict[str, object],
    tables: dict[str, list[dict[str, object]]],
    *,
    device_id: str = "d-a",
    last_sync_at: int = 0,
    user_id: str | None = None,
    client_now: int | None = None,
):
    body: dict[str, object] = {
        "userId": user_id if user_id is not None else account["userId"],
        "deviceId": device_id,
        "lastSyncAt": last_sync_at,
        "tables": tables,
    }
    if client_now is not None:
        body["clientNow"] = client_now
    return client.post(PUSH, headers=auth_header(str(account["token"])), json=body)


def pull(client, account: dict[str, object], since: int = 0):
    return client.get(PULL, headers=auth_header(str(account["token"])), params={"since": since})


def status(client, account: dict[str, object]):
    return client.get(STATUS, headers=auth_header(str(account["token"])))


def data_of(response) -> dict:
    assert response.status_code == 200, f"期望 200，实际 {response.status_code}: {response.text}"
    payload = response.json()
    assert payload["ok"] is True
    return payload["data"]


def login(client, account: dict[str, object]):
    response = client.post(
        "/api/v1/auth/login",
        json={"username": account["username"], "password": account["password"]},
    )
    assert response.status_code == 200, response.text
    return response.json()["data"]


# --------------------------------------------------------------------------- #
# 1) 鉴权与契约形状
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    ("method", "path", "payload"),
    [
        ("POST", PUSH, {"userId": "u-someone", "deviceId": "d-a", "lastSyncAt": 0, "tables": {}}),
        ("GET", PULL, None),
        ("GET", STATUS, None),
        ("GET", BACKUP, None),
        ("POST", RESTORE, {"userId": "u-someone", "tables": {"carbon_record": []}}),
    ],
)
def test_sync_endpoints_require_client_token(client, method, path, payload):
    """同步 / 备份五个端点都要客户端令牌（未登录不调用本组接口，铁律 1）。"""
    response = client.request(method, path, json=payload) if payload is not None else client.request(method, path)
    assert response.status_code == 401
    assert response.json()["code"] in {"TOKEN_INVALID", "TOKEN_EXPIRED"}


def test_push_response_shape_matches_appendix_b(client):
    """push 响应的键 = 附录 B §5.3 的 accepted/skipped/conflicts/serverTime/merged（另有 ignored/rejected）。"""
    account = register_user(client)
    payload = data_of(push(client, account, {"carbon_record": [carbon_record(str(account["userId"]))]}))
    assert set(payload) >= {"accepted", "skipped", "conflicts", "serverTime", "merged"}
    assert {"ignored", "rejected", "offsetMs", "acceptedByTable", "errors"} <= set(payload)
    assert payload["accepted"] == 1
    assert payload["skipped"] == payload["ignored"] + payload["rejected"] == 0
    assert payload["merged"] == {}
    assert payload["serverTime"] >= T0


def test_pull_response_shape_matches_client_reader(client):
    """pull 响应必须带 `data.serverTime` 与 `data.tables`（客户端 `SyncService.applyPull` 读这两个键）。"""
    account = register_user(client)
    payload = data_of(pull(client, account))
    assert payload["since"] == 0
    assert payload["serverTime"] > 0
    assert set(payload["tables"]) == set(SYNCED_TABLES), "9 张参与同步表必须都在响应里（空表给空数组）"
    assert all(rows == [] for rows in payload["tables"].values())


@pytest.mark.parametrize("table", ["point_daily_stat", "share_record", "sync_log", "science_article"])
def test_push_rejects_tables_outside_the_nine(client, table):
    """非参与同步表整批 400（point_daily_stat 是派生缓存、sync_log 本机专属…见附录 B §2/§6.5）。"""
    account = register_user(client)
    response = push(client, account, {table: [{"id": "x"}]})
    assert response.status_code == 400
    assert response.json()["code"] == "INVALID_REQUEST"


def test_pull_increment_is_strictly_greater(client):
    """增量口径 `updated_at > since`：since 等于该行时间时不重复下发。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id, updated_at=T0)]}))

    assert [r["id"] for r in data_of(pull(client, account, since=T0))["tables"]["carbon_record"]] == []
    rows = data_of(pull(client, account, since=T0 - 1))["tables"]["carbon_record"]
    assert [r["id"] for r in rows] == ["rec-0001"]
    assert rows[0]["updated_at"] == T0


def test_pull_returns_json_numbers_not_decimal_strings(client):
    """浮点列必须是 JSON 数值：`mysql.DOUBLE` 默认 `asdecimal=True` 会给出 `Decimal('2.0000000000')`，
    序列化后变成字符串 `"2.0000000000"`，客户端 `numOf(row, 'amount')` 会读到非数字。

    因此模型统一写 `DOUBLE(asdecimal=False)`（见 app/models/base.py 的类型映射约定）。
    """
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, amount=2.0)]},
        )
    )
    row = data_of(pull(client, account))["tables"]["carbon_record"][0]
    assert isinstance(row["amount"], float) and row["amount"] == 2.0
    assert isinstance(row["reduction_kg"], float)
    assert isinstance(row["updated_at"], int)
    assert isinstance(row["is_deleted"], int)


def test_server_tables_have_no_sync_state_column(client, db_session):
    """`sync_state` 是**仅客户端**的列（附录 B §1.3）：服务端不建它，status 也不报「待同步数」。"""
    account = register_user(client)
    columns = set(
        db_session.execute(
            text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = DATABASE() AND table_name = 'carbon_record'"
            )
        ).scalars()
    )
    assert "sync_state" not in columns

    payload = data_of(status(client, account))
    flat = str(payload)
    assert "pending" not in flat and "syncState" not in flat and "sync_state" not in flat


# --------------------------------------------------------------------------- #
# 2) 幂等：id 去重 / 业务唯一键兜底
# --------------------------------------------------------------------------- #
def test_append_only_dedup_by_id_counts_ignored(client):
    """账本表同 id 第二次推送 → ignored（跳过），不入第二次账（附录 B §6.3:906）。"""
    account = register_user(client)
    user_id = str(account["userId"])
    row = point_record(user_id)

    first = data_of(push(client, account, {"point_record": [row]}))
    assert (first["accepted"], first["ignored"]) == (1, 0)

    second = data_of(push(client, account, {"point_record": [row]}))
    assert second["accepted"] == 0
    assert second["ignored"] == 1
    assert second["skipped"] == 1
    assert second["errors"], "被忽略的行必须有可展示的原因（面板「跨设备重复已去重」）"

    assert len(data_of(pull(client, account))["tables"]["point_record"]) == 1


def test_append_only_never_updates_existing_row(client, db_session):
    """铁律 4：账本流水只增不删、永不 UPDATE —— 即使对端时间更新。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"point_record": [point_record(user_id, points=20)]}))

    tampered = point_record(user_id, points=999, updated_at=T0 + 60_000, device_id="d-b")
    outcome = data_of(push(client, account, {"point_record": [tampered]}, device_id="d-b"))
    assert outcome["accepted"] == 0
    assert outcome["ignored"] == 1

    points = db_session.execute(
        text("SELECT points FROM point_record WHERE id = 'pr-0001' AND user_id = :uid"), {"uid": user_id}
    ).scalar_one()
    assert points == 20, "已入账的流水绝不能被后来的行改写"


def test_business_key_dedup_across_devices_for_same_user(client):
    """跨设备重复发放只入账一次：两个设备各带不同 id、同一业务唯一键 → 第二条计入 ignored。"""
    account = register_user(client)
    user_id = str(account["userId"])
    a = point_record(user_id, "pr-device-a", source_id="S1:D:2026-11-06", device_id="d-a")
    b = point_record(user_id, "pr-device-b", source_id="S1:D:2026-11-06", device_id="d-b")

    data_of(push(client, account, {"point_record": [a]}, device_id="d-a"))
    outcome = data_of(push(client, account, {"point_record": [b]}, device_id="d-b"))

    assert outcome["accepted"] == 0
    assert outcome["ignored"] == 1
    assert len(data_of(pull(client, account))["tables"]["point_record"]) == 1


def test_business_key_is_scoped_per_user(client):
    """业务唯一键按账号隔离：两个账号同日达成同名目标，各入各的账（uq_pr_source 含 user_id）。

    这是 `uq_pr_source(source_type, source_id, flow_kind)` 缺 `user_id` 的回归用例：
    索引不含账号时，后一个账号的合法流水会被唯一索引挡下（丢积分）。
    """
    first = register_user(client, username=unique_username("acctone"))
    second = register_user(client, username=unique_username("accttwo"))
    same_key = dict(source_id="S1:D:2026-11-06", source_type="goal", flow_kind="primary")

    data_of(push(client, first, {"point_record": [point_record(str(first["userId"]), "pr-one", **same_key)]}))
    outcome = data_of(push(client, second, {"point_record": [point_record(str(second["userId"]), "pr-two", **same_key)]}))

    assert outcome["accepted"] == 1, "另一个账号的同名业务键不得顶掉本账号的入账"
    assert outcome["ignored"] == 0
    assert len(data_of(pull(client, first))["tables"]["point_record"]) == 1
    assert len(data_of(pull(client, second))["tables"]["point_record"]) == 1


def test_purchase_duplicate_keeps_one_row_and_merges_back(client):
    """有唯一键的 LWW（user_purchase）：重复购买只保留一行，另一端按 merged 收敛。

    历史错误注释「另一端那条被忽略，等于退回多扣的分」不成立：服务端**不产生任何 reverse 流水**，
    等价关系是「记账上没有多扣一次分」，而不是"退回"。本用例同时断言服务端不伪造流水。
    """
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"user_purchase": [user_purchase(user_id, "up-a")]}, device_id="d-a"))

    outcome = data_of(
        push(client, account, {"user_purchase": [user_purchase(user_id, "up-b", updated_at=T0 + 5000)]}, device_id="d-b")
    )
    assert outcome["accepted"] == 0
    assert outcome["ignored"] == 1
    assert [row["id"] for row in outcome["merged"].get("user_purchase", [])] == ["up-a"], "必须回写服务端版本"

    rows = data_of(pull(client, account))["tables"]["user_purchase"]
    assert [row["id"] for row in rows] == ["up-a"], "同一 (user_id, item_id) 只保留一行"
    assert data_of(pull(client, account))["tables"]["point_record"] == [], "服务端不产生任何流水（无 reverse、无 adjust）"


# --------------------------------------------------------------------------- #
# 3) LWW：新者胜 / 旧者保留 / 平局
# --------------------------------------------------------------------------- #
def test_lww_newer_remote_wins(client):
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id, amount=1.0)]}, device_id="d-a"))

    outcome = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, amount=2.0, updated_at=T0 + 1000, device_id="d-b")]},
            device_id="d-b",
        )
    )
    assert outcome["accepted"] == 1
    rows = data_of(pull(client, account))["tables"]["carbon_record"]
    assert rows[0]["amount"] == 2.0
    assert rows[0]["device_id"] == "d-b"


def test_lww_older_remote_keeps_server_and_merges_back(client):
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id, amount=5.0, updated_at=T0)]}, device_id="d-a"))

    outcome = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, amount=1.0, updated_at=T0 - 10_000, device_id="d-b")]},
            device_id="d-b",
        )
    )
    assert outcome["accepted"] == 0
    assert outcome["rejected"] == 1
    assert outcome["skipped"] == 1
    merged = outcome["merged"]["carbon_record"]
    assert len(merged) == 1 and merged[0]["amount"] == 5.0 and merged[0]["updated_at"] == T0

    rows = data_of(pull(client, account))["tables"]["carbon_record"]
    assert rows[0]["amount"] == 5.0, "服务端版本不受旧行影响"


def test_lww_tie_break_by_device_id_lexicographic(client):
    """平局（updatedAt 相等）→ deviceId 字典序大者胜，两端同一规则。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id, amount=1.0, device_id="d-m")]}))

    bigger = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, amount=9.0, device_id="d-z")]},
            device_id="d-z",
        )
    )
    assert bigger["accepted"] == 1
    assert data_of(pull(client, account))["tables"]["carbon_record"][0]["amount"] == 9.0

    smaller = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, amount=0.0, device_id="d-a")]},
            device_id="d-a",
        )
    )
    assert smaller["accepted"] == 0 and smaller["ignored"] == 1
    assert smaller["errors"], "被去重/回写的行都要有可展示的原因（面板用）"
    assert [row["amount"] for row in smaller["merged"]["carbon_record"]] == [9.0]
    assert data_of(pull(client, account))["tables"]["carbon_record"][0]["amount"] == 9.0


def test_true_conflict_requires_both_sides_changed_since_last_sync(client):
    """真冲突 = 两端自上次同步后都改过这一行（附录 B §6.3:912）。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id, updated_at=T0)]}, device_id="d-a"))

    # ① 只有对端改过（服务端那一行自 lastSyncAt 起没动）→ 不是冲突
    only_remote = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, updated_at=T0 + 1000, device_id="d-b")]},
            device_id="d-b",
            last_sync_at=T0,
        )
    )
    assert only_remote["accepted"] == 1
    assert only_remote["conflicts"] == 0

    # ② 服务端那一行在 lastSyncAt 之后也被改过 → 两端都改过 = 真冲突
    data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, updated_at=T0 + 5000, device_id="d-a")]},
            device_id="d-a",
            last_sync_at=T0,
        )
    )
    both_changed = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, updated_at=T0 + 6000, device_id="d-b")]},
            device_id="d-b",
            last_sync_at=T0,
        )
    )
    assert both_changed["accepted"] == 1
    assert both_changed["conflicts"] == 1


def test_tie_branch_counts_conflict_with_the_same_condition(client):
    """平局分支的冲突计数与「真冲突」同一条件（附录 B §6.3:919）。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id, device_id="d-a")]}, device_id="d-a"))

    tied = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, device_id="d-z")]},
            device_id="d-z",
            last_sync_at=T0 - 1,  # 两端 updatedAt(=T0) 都 > lastSyncAt
        )
    )
    assert tied["accepted"] == 1
    assert tied["conflicts"] == 1

    # 同一平局，但 lastSyncAt 不满足条件 → 不计数（同一条件，两个分支一致）
    data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, updated_at=T0 + 1000, device_id="d-a")]},
            device_id="d-a",
        )
    )
    tied_again = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, updated_at=T0 + 1000, device_id="d-z")]},
            device_id="d-z",
            last_sync_at=T0 + 1000,  # 两端 updatedAt(=T0+1000) 都不 > lastSyncAt
        )
    )
    assert tied_again["accepted"] == 1
    assert tied_again["conflicts"] == 0


# --------------------------------------------------------------------------- #
# 4) 软删除传播
# --------------------------------------------------------------------------- #
def test_soft_delete_propagates_through_pull(client, db_session):
    """软删除 = `is_deleted = 1` + 更新 `updated_at`；靠 LWW 取胜并随增量下发（§1.3-4 / §6.4-2）。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id, updated_at=T0)]}, device_id="d-a"))

    deleted = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, updated_at=T0 + 1000, is_deleted=1, device_id="d-a")]},
            device_id="d-a",
        )
    )
    assert deleted["accepted"] == 1, "软删除行按普通行参与 LWW"

    rows = data_of(pull(client, account, since=T0))["tables"]["carbon_record"]
    assert len(rows) == 1 and rows[0]["is_deleted"] == 1 and rows[0]["updated_at"] == T0 + 1000

    alive = db_session.execute(
        text("SELECT is_deleted, updated_at FROM carbon_record WHERE id = 'rec-0001' AND user_id = :uid"),
        {"uid": user_id},
    ).one()
    assert (int(alive[0]), int(alive[1])) == (1, T0 + 1000), "软删除不物理删除（否则删除无法传播）"
    assert db_session.execute(
        text("SELECT COUNT(*) FROM carbon_record WHERE user_id = :uid"), {"uid": user_id}
    ).scalar_one() == 1


def test_delete_wins_only_when_it_is_newer(client):
    """删除也要按 LWW 竞争：旧的「未删除」行不能把新的软删除顶回去。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, updated_at=T0, is_deleted=1, device_id="d-a")]},
            device_id="d-a",
        )
    )
    older = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, updated_at=T0 - 1, is_deleted=0, device_id="d-b")]},
            device_id="d-b",
        )
    )
    assert older["accepted"] == 0 and older["rejected"] == 1
    assert data_of(pull(client, account))["tables"]["carbon_record"][0]["is_deleted"] == 1


# --------------------------------------------------------------------------- #
# 5) 时钟基准与容差
# --------------------------------------------------------------------------- #
def test_clock_within_tolerance_has_no_warning(client, db_session):
    account = register_user(client)
    user_id = str(account["userId"])
    now = int(__import__("time").time() * 1000)
    outcome = data_of(
        push(client, account, {"carbon_record": [carbon_record(user_id, updated_at=now)]}, client_now=now - 1000)
    )
    assert outcome["accepted"] == 1
    assert 0 < outcome["offsetMs"] < 5 * MS_PER_MINUTE
    assert outcome["clockWarning"] is None
    error_msg = db_session.execute(
        text("SELECT error_msg FROM sync_log WHERE user_id = :uid ORDER BY started_at DESC LIMIT 1"),
        {"uid": user_id},
    ).scalar_one_or_none()
    assert error_msg is None


def test_clock_beyond_tolerance_records_error_but_continues(client, db_session):
    """超 ±5 分钟容差：记 `sync_log.error_msg`，但**仍然继续合并**（附录 B §6.4-6）。"""
    account = register_user(client)
    user_id = str(account["userId"])
    now = int(__import__("time").time() * 1000)
    outcome = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, updated_at=now)]},
            client_now=now - 10 * MS_PER_MINUTE,  # 客户端时钟慢 10 分钟
        )
    )
    assert outcome["accepted"] == 1, "超容差不阻断同步"
    assert outcome["offsetMs"] > 5 * MS_PER_MINUTE
    assert outcome["clockWarning"] and "容差" in outcome["clockWarning"]

    row = db_session.execute(
        text("SELECT status, error_msg FROM sync_log WHERE user_id = :uid ORDER BY started_at DESC LIMIT 1"),
        {"uid": user_id},
    ).one()
    assert "容差" in str(row[1]), "超容差必须留痕到 sync_log.error_msg"
    assert str(row[0]) in {"success", "partial"}


def test_clock_offset_is_applied_to_lww_comparison(client):
    """比较前把对端时间戳换算到服务端基准：客户端时钟偏快时，它的「较新」行不会再赢。"""
    import time

    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id, amount=5.0, updated_at=T0)]}))

    now = int(time.time() * 1000)
    outcome = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, amount=1.0, updated_at=T0 + 100_000, device_id="d-b")]},
            device_id="d-b",
            client_now=now + 10 * MS_PER_MINUTE,  # 客户端时钟快 10 分钟 → offsetMs 为负
        )
    )
    assert outcome["offsetMs"] < 0
    assert outcome["accepted"] == 0 and outcome["rejected"] == 1, "换算后该行其实比服务端旧"
    assert data_of(pull(client, account))["tables"]["carbon_record"][0]["amount"] == 5.0

    behind = data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, amount=7.0, updated_at=T0 - 100_000, device_id="d-b")]},
            device_id="d-b",
            client_now=now - 10 * MS_PER_MINUTE,  # 客户端时钟慢 10 分钟 → offsetMs 为正
        )
    )
    assert behind["offsetMs"] > 0
    assert behind["accepted"] == 1, "换算后该行其实比服务端新"
    assert data_of(pull(client, account))["tables"]["carbon_record"][0]["amount"] == 7.0


# --------------------------------------------------------------------------- #
# 6) 越权与账号隔离
# --------------------------------------------------------------------------- #
def test_body_user_id_mismatch_is_forbidden(client):
    account = register_user(client)
    response = push(client, account, {}, user_id="u-someone-else")
    assert response.status_code == 403
    assert response.json()["code"] == "FORBIDDEN"


def test_foreign_row_is_rejected_and_nothing_is_written(client, db_session):
    """行内 user_id 与令牌账号不一致 → 整批 403，一行都不写（避免把别人的数据搬进本账号）。"""
    mine = register_user(client, username=unique_username("minemine"))
    other = register_user(client, username=unique_username("otherone"))
    response = push(
        client,
        mine,
        {
            "carbon_record": [
                carbon_record(str(mine["userId"]), "rec-mine"),
                carbon_record(str(other["userId"]), "rec-other"),
            ]
        },
    )
    assert response.status_code == 403
    assert response.json()["code"] == "FORBIDDEN"
    written = db_session.execute(
        text("SELECT COUNT(*) FROM carbon_record WHERE id IN ('rec-mine', 'rec-other')")
    ).scalar_one()
    assert written == 0, "越权请求必须整体回滚"


def test_pull_and_status_are_scoped_to_token_account(client):
    first = register_user(client, username=unique_username("scopeone"))
    second = register_user(client, username=unique_username("scopetwo"))
    data_of(push(client, first, {"carbon_record": [carbon_record(str(first["userId"]), "rec-first")]}))
    data_of(push(client, second, {"carbon_record": [carbon_record(str(second["userId"]), "rec-second")]}))

    assert [r["id"] for r in data_of(pull(client, first))["tables"]["carbon_record"]] == ["rec-first"]
    assert [r["id"] for r in data_of(pull(client, second))["tables"]["carbon_record"]] == ["rec-second"]
    assert data_of(status(client, first))["totalRows"] == 1


# --------------------------------------------------------------------------- #
# 7) status
# --------------------------------------------------------------------------- #
def test_status_reports_cloud_counts_devices_and_last_sync(client):
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id, device_id="d-a")]}, device_id="d-a"))
    data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, "rec-0002", updated_at=T0 + 1000, device_id="d-b")]},
            device_id="d-b",
        )
    )
    data_of(
        push(
            client,
            account,
            {"point_record": [point_record(user_id, device_id="d-b")]},
            device_id="d-b",
        )
    )

    payload = data_of(pull(client, account))
    assert len(payload["tables"]["carbon_record"]) == 2

    stats = data_of(status(client, account))
    by_name = {row["name"]: row for row in stats["tables"]}
    assert [row["name"] for row in stats["tables"]] == list(SYNCED_TABLES), "表序固定（附录 B §6.5）"
    assert stats["totalRows"] == 3
    assert by_name["carbon_record"]["count"] == 2
    assert by_name["carbon_record"]["lastUpdatedAt"] == T0 + 1000
    assert by_name["point_record"]["count"] == 1
    assert by_name["user_badge"]["count"] == 0 and by_name["user_badge"]["lastUpdatedAt"] == 0
    assert stats["devices"] == ["d-a", "d-b"]
    assert stats["lastSync"]["direction"] == "pull"  # 上面刚拉过一次
    assert stats["lastSync"]["status"] == "success"


def test_status_reports_deleted_rows(client):
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(
        push(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, is_deleted=1)]},
            device_id="d-a",
        )
    )
    by_name = {row["name"]: row for row in data_of(status(client, account))["tables"]}
    assert by_name["carbon_record"]["count"] == 1
    assert by_name["carbon_record"]["deletedCount"] == 1


# --------------------------------------------------------------------------- #
# 8) 云端备份 / 恢复
# --------------------------------------------------------------------------- #
def upload(client, account, tables, *, device_id="d-a"):
    return client.post(
        BACKUP,
        headers=auth_header(str(account["token"])),
        json={"userId": account["userId"], "deviceId": device_id, "tables": tables},
    )


def restore(client, account, tables, *, device_id="d-a"):
    return client.post(
        RESTORE,
        headers=auth_header(str(account["token"])),
        json={"userId": account["userId"], "deviceId": device_id, "tables": tables},
    )


def test_backup_upload_then_download_roundtrip(client):
    account = register_user(client)
    user_id = str(account["userId"])
    outcome = data_of(
        upload(
            client,
            account,
            {"carbon_record": [carbon_record(user_id)], "user_profile": [user_profile(user_id)]},
        )
    )
    assert outcome["stored"] == 2 and outcome["ignored"] == 0 and outcome["rejected"] == 0

    snapshot = data_of(client.get(BACKUP, headers=auth_header(str(account["token"]))))
    assert snapshot["totalRows"] == 2
    assert snapshot["snapshotAt"] == T0
    ids = {name: [row["id"] for row in rows] for name, rows in snapshot["tables"].items()}
    assert ids["carbon_record"] == ["rec-0001"] and ids["user_profile"] == ["uprofile-0001"]
    assert set(ids) == set(SYNCED_TABLES)


def test_backup_upload_stores_snapshot_without_lww_merging(client):
    """只存快照：比云端**更旧**的行也照样覆盖（这不是增量合并，不比较 updated_at）。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id, amount=5.0, updated_at=T0)]}))

    outcome = data_of(
        upload(client, account, {"carbon_record": [carbon_record(user_id, amount=1.0, updated_at=T0 - 500_000)]})
    )
    assert outcome["stored"] == 1 and outcome["ignored"] == 0
    rows = data_of(client.get(BACKUP, headers=auth_header(str(account["token"]))))["tables"]["carbon_record"]
    assert rows[0]["amount"] == 1.0 and rows[0]["updated_at"] == T0 - 500_000


def test_backup_upload_counts_business_key_collision_as_ignored(client):
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(upload(client, account, {"point_record": [point_record(user_id, "pr-a")]}))
    outcome = data_of(upload(client, account, {"point_record": [point_record(user_id, "pr-b")]}))
    assert outcome["stored"] == 0 and outcome["ignored"] == 1
    assert outcome["errors"], "冲突必须写明原因（不做自动合并）"
    snapshot = data_of(client.get(BACKUP, headers=auth_header(str(account["token"]))))
    assert len(snapshot["tables"]["point_record"]) == 1


def test_backup_restore_overwrites_and_returns_pre_restore_snapshot(client):
    """恢复即覆盖：快照里没有的行被移除；覆盖前的原状随 `preRestore` 返回（恢复前生成快照）。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(
        push(
            client,
            account,
            {
                "carbon_record": [
                    carbon_record(user_id, "rec-keep", updated_at=T0),
                    carbon_record(user_id, "rec-drop", updated_at=T0 + 1000),
                ]
            },
        )
    )

    outcome = data_of(
        restore(
            client,
            account,
            {"carbon_record": [carbon_record(user_id, "rec-keep", amount=3.0, updated_at=T0 + 5000)]},
        )
    )
    assert outcome["restored"] == 1
    assert outcome["removed"] == 1, "快照里没有的行必须被移除（恢复即覆盖）"
    assert outcome["preRestoreAt"] >= T0
    pre_ids = {row["id"] for row in outcome["preRestore"]["carbon_record"]}
    assert pre_ids == {"rec-keep", "rec-drop"}, "恢复前快照 = 覆盖前的云端原状"

    rows = data_of(pull(client, account, since=0))["tables"]["carbon_record"]
    assert [row["id"] for row in rows] == ["rec-keep"]
    assert rows[0]["amount"] == 3.0 and rows[0]["updated_at"] == T0 + 5000


def test_backup_restore_never_deletes_ledger_rows(client):
    """铁律 4：账本表恢复只补不删、不改 —— 快照里没有的流水仍在云端。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(
        push(
            client,
            account,
            {
                "point_record": [
                    point_record(user_id, "pr-keep", source_id="S1:D:2026-11-06"),
                    point_record(user_id, "pr-extra", source_id="S2:D:2026-11-06"),
                ]
            },
        )
    )

    outcome = data_of(
        restore(client, account, {"point_record": [point_record(user_id, "pr-keep", source_id="S1:D:2026-11-06")]})
    )
    assert outcome["removed"] == 0, "账本流水只增不删"
    ids = {row["id"] for row in data_of(pull(client, account, since=0))["tables"]["point_record"]}
    assert ids == {"pr-keep", "pr-extra"}


def test_backup_restore_rejects_empty_snapshot(client):
    account = register_user(client)
    response = restore(client, account, {})
    assert response.status_code == 400
    assert response.json()["code"] == "INVALID_REQUEST"


def test_backup_rejects_unknown_table(client):
    account = register_user(client)
    response = upload(client, account, {"point_daily_stat": [{"id": "x"}]})
    assert response.status_code == 400
    assert response.json()["code"] == "INVALID_REQUEST"


# --------------------------------------------------------------------------- #
# 9) 首次登录全量并入账号 / 注销保留期
# --------------------------------------------------------------------------- #
def test_first_login_full_upload_attaches_local_history(client):
    """ADR-0001 决策 ①：登录后把本机历史**全部上传并入账号**（客户端改挂 user_id，服务端全量接收）。

    服务端一侧的可核实行为：带账号令牌、user_id = 账号 userId 的全量行被整批接收并可按 `since=0` 拉回。
    """
    account = register_user(client)
    user_id = str(account["userId"])
    history = {
        "carbon_record": [carbon_record(user_id, "rec-0001"), carbon_record(user_id, "rec-0002", updated_at=T0 + 1)],
        "point_record": [point_record(user_id)],
        "user_goal": [
            {
                "id": "ug-0001",
                "user_id": user_id,
                "goal_id": "S1",
                "period_key": "D:2026-11-06",
                "progress": 1,
                "threshold": 1,
                "settled": 1,
                "created_at": T0 - 1000,
                "updated_at": T0,
                "is_deleted": 0,
                "device_id": "d-a",
            }
        ],
        "user_profile": [user_profile(user_id)],
    }
    outcome = data_of(push(client, account, history, device_id="d-a"))
    assert outcome["accepted"] == 5
    assert outcome["ignored"] == 0 and outcome["rejected"] == 0

    pulled = data_of(pull(client, account, since=0))["tables"]
    assert len(pulled["carbon_record"]) == 2
    assert len(pulled["point_record"]) == 1
    assert len(pulled["user_goal"]) == 1
    assert len(pulled["user_profile"]) == 1
    assert data_of(status(client, account))["totalRows"] == 5


def test_guest_rows_cannot_be_uploaded_under_an_account_token(client):
    """`local-guest` 的行不能被账号令牌直接写进账号：改挂 user_id 是客户端 `AccountMigrator` 的职责。"""
    account = register_user(client, username=unique_username("guestone"))
    response = push(client, account, {"carbon_record": [carbon_record("local-guest", "rec-guest")]}, user_id=None)
    assert response.status_code == 403
    assert response.json()["code"] == "FORBIDDEN"


def test_deleted_account_cannot_sync_and_cloud_rows_are_soft_deleted_then_restored(client, db_session):
    """ADR-0001 决策 ③：注销 → 云端软删除保留 30 天；保留期内旧令牌失效、重新登录即恢复。"""
    account = register_user(client)
    user_id = str(account["userId"])
    data_of(push(client, account, {"carbon_record": [carbon_record(user_id)]}, device_id="d-a"))

    deleted = client.request(
        "DELETE",
        "/api/v1/auth/account",
        headers=auth_header(str(account["token"])),
        json={"password": TEST_PASSWORD},
    )
    assert deleted.status_code == 200, deleted.text
    purge_after = deleted.json()["data"]["purgeAfter"]
    assert abs(purge_after - int(__import__("time").time() * 1000) - 30 * MS_PER_DAY) < 60_000, "保留 30 天"

    blocked = push(client, account, {"carbon_record": [carbon_record(user_id, amount=9.0, updated_at=T0 + 1000)]})
    assert blocked.status_code == 401, "注销后旧令牌不能再同步"
    assert blocked.json()["code"] in {"TOKEN_INVALID", "TOKEN_EXPIRED"}

    stored = db_session.execute(
        text("SELECT is_deleted, updated_at FROM carbon_record WHERE id = 'rec-0001' AND user_id = :uid"),
        {"uid": user_id},
    ).one()
    assert int(stored[0]) == 1 and int(stored[1]) > T0, "云端数据软删除（保留 30 天，未物理删除）"
    assert db_session.execute(
        text("SELECT COUNT(*) FROM carbon_record WHERE user_id = :uid"), {"uid": user_id}
    ).scalar_one() == 1

    restored_account = login(client, account)
    # 恢复后这些行的 updated_at 已被改成恢复时刻；用当前时间戳推一版新的，才会按 LWW 取胜
    current = int(__import__("time").time() * 1000) + 1000
    resumed = data_of(push(client, account, {"carbon_record": [carbon_record(user_id, updated_at=current)]}))
    assert resumed["accepted"] == 1
    assert restored_account["userId"] == user_id

    # MySQL 默认 REPEATABLE READ：db_session 这个长事务要先收尾，才能看到 HTTP 侧刚写下的恢复结果
    db_session.commit()
    after = db_session.execute(
        text("SELECT is_deleted FROM carbon_record WHERE id = 'rec-0001' AND user_id = :uid"), {"uid": user_id}
    ).scalar_one()
    assert int(after) == 0, "保留期内恢复 → 云端行回到未删除态"


# --------------------------------------------------------------------------- #
# 10) 迁移 / ORM / 挂载点
# --------------------------------------------------------------------------- #
def test_uq_pr_source_index_is_scoped_per_user(db_session):
    """`uq_pr_source` 必须含 `user_id`（服务端多账号共库的唯一正确形态；附录 B §2:142 待同步修正）。"""
    columns = db_session.execute(
        text(
            "SELECT column_name FROM information_schema.statistics "
            "WHERE table_schema = DATABASE() AND table_name = 'point_record' "
            "AND index_name = 'uq_pr_source' ORDER BY seq_in_index"
        )
    ).scalars().all()
    assert tuple(columns) == ("user_id", "source_type", "source_id", "flow_kind")


def test_migrations_are_executable_and_idempotent(mysql_conn):
    """`sql/migrations/*.sql` 必须存在、可执行、可重复执行（部署与测试共用的同一批脚本）。"""
    from tests.conftest import _apply_migrations, _connect

    files = migration_files()
    assert files, "sql/migrations/ 下应有增量迁移脚本"
    assert all(path.parent == MIGRATIONS_DIR for path in files)
    applied_in_fixture = mysql_conn["migrations"]
    assert set(applied_in_fixture) == {path.name for path in files}
    assert all(count > 0 for count in applied_in_fixture.values()), "每个迁移脚本都要真的执行了语句"

    connection = _connect(
        db=mysql_conn["db"],
        user=mysql_conn["user"],
        password=mysql_conn["password"],
        host=mysql_conn["host"],
        port=int(mysql_conn["port"]),
    )
    try:
        first = _apply_migrations(connection)
        second = _apply_migrations(connection)  # 幂等：再跑一遍不该报错
    finally:
        connection.close()
    assert set(first) == set(second) == {path.name for path in files}


def test_admin_web_mount_point_is_optional_and_honoured(settings, monkeypatch):
    """`main.py` 预留的 Web 后台挂载点：t6 提供 `admin_web.mount.mount_admin` 时被调用，缺失时静默跳过。"""
    from app.main import create_app

    calls: list[object] = []
    package = types.ModuleType("admin_web")
    module = types.ModuleType("admin_web.mount")
    module.mount_admin = lambda app: calls.append(app)  # type: ignore[attr-defined]
    package.mount = module  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "admin_web", package)
    monkeypatch.setitem(sys.modules, "admin_web.mount", module)

    mounted = create_app(settings)
    assert calls == [mounted], "存在 admin_web.mount 时必须挂载（可选件，但缝要在）"

    monkeypatch.delitem(sys.modules, "admin_web.mount")
    still_ok = create_app(settings)
    assert still_ok is not None, "缺失 admin_web 时必须静默跳过，不影响客户端 API"


def test_main_py_uses_admin_web_mount_and_creates_no_app_admin_package():
    """挂载点写死在 main.py，且本切片**没有**创建 `server/app/admin/`（Web 后台归 t6 的 `server/admin_web/`）。"""
    source = (SERVER_DIR / "app" / "main.py").read_text(encoding="utf-8")
    assert "from admin_web.mount import mount_admin" in source
    assert "except Exception" in source
    assert not (SERVER_DIR / "app" / "admin").exists(), "Web 后台管理端不在 t5 范围（由 t6 建 server/admin_web/）"
    assert not (SERVER_DIR / "templates").exists()
    assert not (SERVER_DIR / "static").exists()
