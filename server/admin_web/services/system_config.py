"""⑥ 系统配置（`app_config` + `goal_def`）。

口径（PLAN §13.2 ⑥、附录 B §5.4、附录 D10-5）
---------------------------------------------
| 配置项 | 存储 | 说明 |
|---|---|---|
| 每日封顶值 | `app_config['points_daily_cap']` | 种子值 `200`（PLAN §9.2）；非空整数 |
| 徽章开关 | `app_config['badges_enabled']` | 本切片新增的键（原表只有 `points_daily_cap`/`shop_items_version`/`account_purge_retention_days`），默认 `1` |
| 目标奖励分值 | `goal_def.reward` | 11 个目标（PLAN §10.1 / 附录 B §8.1），按 `id` 逐个改 |
| 配置版本号 | `app_config['config_version']` | 保存成功后 bump（附录 B §5.5 的 ⚠️「版本必须真的会变」），格式 `<yyyy.MM.dd>-<n>` |

新增两个键名不违反任何契约：`app_config` 本来就是 key-value 配置表（附录 B §1.2），
而"徽章开关"是 PLAN §13.2 ⑥ / D10-5 明确要求可配的项 —— 文档没给它键名，本模块**在本文件与
`admin_web/README.md` 里写死**，避免两处口径。

下发通道与版本感知（原「⚠ 未决问题」已闭环）
------------------------------------------
附录 D10-5 的判据含「**App 侧能读到**」，而本切片当初只有商品目录下发通道（`GET /api/v1/shop/items`）。
该缺口已由两处补齐，本模块负责其中的**版本感知**：

* 通道：附录 B 新增 **§5.5** 冻结 `GET /api/v1/config`（免 Bearer，`server/app/api/v1/config.py`）——
  下发 `version` / `pointsDailyCap` / `badgesEnabled` / `goalRewards` / `serverTime`。
* 版本：那条 ⚠️ 要求「`PUT /admin/config` 成功保存后**必须**同步更新 `app_config['config_version']`」，
  否则客户端无法判断"内容是否变了"，"改了能读到"退化成碰运气 —— 就是本模块 `bump_version()` 的职责。
* **键名独立**：配置版本走 `config_version`，与商品目录的 `shop_items_version` **互不顶替**
  （附录 B §5.5 明确要求）—— 改一次价格不会让客户端以为"配置变了"，反之亦然。

版本号语义（一处需要写死的判断）
------------------------------
**`changed` 非空才 bump**：只有真的写进了至少一项配置，才推版本号。理由三条：
① 附录 B §5.5 的 ⚠️ 针对的是"内容变了客户端却感知不到"，无改动保存没有可感知的内容差异；
② 验收要求「不得出现『配置改了但版本没动』或**反过来**的中间态」——"版本动了但配置没改"正是反过来那半；
③ 与商品目录同一套语义（`catalog.update_item` 的空改动是幂等成功、**不 bump**），
   也让"每一次版本写入都伴随一条 `update_config` 审计"这一不变量成立（D10-6 可追溯）。
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.errors import AppError, ErrorCode
from app.core.security import now_ms
from app.models import AppConfig, GoalDef
from app.services import shop_service
from app.services.config_service import CONFIG_VERSION_KEY, FALLBACK_VERSION

from admin_web.schemas import SystemConfigUpdate
from admin_web.services import audit
from admin_web.services.base import transaction
# 版本号格式（`<yyyy.MM.dd>-<n>`，同日递增 / 跨日重置为 1）只有一处实现，
# 与商品目录共用：配置版本**键名独立**，但"什么算下一个版本"是同一条规则。
from admin_web.services.catalog import next_version

logger = logging.getLogger("carbonboo.admin.config")

#: 每日记录积分封顶（PLAN §9.2 默认 200；配置缺失时按文档默认值回显，不编造）
DAILY_CAP_KEY = "points_daily_cap"
DEFAULT_DAILY_CAP = 200
#: 徽章开关（1 = 启用，0 = 关闭；默认启用）
BADGES_ENABLED_KEY = "badges_enabled"
DEFAULT_BADGES_ENABLED = 1


def _read_int(db: Session, key: str, default: int) -> int:
    row = db.execute(select(AppConfig).where(AppConfig.id == key)).scalar_one_or_none()
    if row is None or row.value is None:
        return default
    try:
        return int(str(row.value).strip())
    except (TypeError, ValueError):
        logger.warning("app_config['%s'] 不是整数（现值 %r），按默认值 %s 回显", key, row.value, default)
        return default


def _write_int(db: Session, key: str, value: int, *, default: int) -> None:
    """写一个整数配置键（不存在则插入）。键名固定，值已被 Pydantic 约束为整数。"""
    row = db.execute(select(AppConfig).where(AppConfig.id == key)).scalar_one_or_none()
    stamp = now_ms()
    if row is None:
        db.add(AppConfig(id=key, value=str(value), version=None, fetched_at=None, created_at=stamp, updated_at=stamp))
        logger.info("新增系统配置 %s=%s（原缺省 %s）", key, value, default)
        return
    row.value = str(value)
    row.updated_at = stamp


def _stored_version(db: Session) -> str | None:
    """`app_config['config_version']` 的**实际存储值**（`value` 优先、`version` 兜底；缺失 → `None`）。

    与 `current_version()` 的差别只有"缺键返回 `None` 而不是 `"0.0.0"`"——审计里要区分
    「第一次保存（还没有这一行）」与「从 `0.0.0` 变成新版本」，前者写 `null` 才是真话。
    """
    row = db.execute(select(AppConfig).where(AppConfig.id == CONFIG_VERSION_KEY)).scalar_one_or_none()
    if row is None:
        return None
    return row.value or row.version or None


def current_version(db: Session) -> str:
    """读 `app_config['config_version']`：缺失 → `"0.0.0"`（非空，不回 null）。

    优先级（`value` → `version` 列）与 `app.services.config_service.current_version` **逐字一致**：
    两处读的是同一个键，口径分叉会让后台刚推上去的版本在客户端看不见（D10-5）。
    """
    return _stored_version(db) or FALLBACK_VERSION


def bump_version(db: Session, *, now: datetime | None = None) -> str:
    """把 `app_config['config_version']` 提到新版本并返回新值（**不 commit**，随业务事务一起提交）。

    格式 `<yyyy.MM.dd>-<n>`：同日递增、跨日重置为 1（规则与商品目录共用 `catalog.next_version`）。
    `value` 与 `version` 列**同写**：下发端读的是 `value or version`，只写一列会在另一列为空时读到旧值。
    键不存在时插入新行（`fetched_at=None`：这一行不是从客户端"取"回来的，没有服务端时间戳语义）。
    """
    before = _stored_version(db)
    new_version = next_version(before or "", now=now)
    stamp = now_ms()
    row = db.execute(select(AppConfig).where(AppConfig.id == CONFIG_VERSION_KEY)).scalar_one_or_none()
    if row is None:
        db.add(
            AppConfig(
                id=CONFIG_VERSION_KEY,
                value=new_version,
                version=new_version,
                fetched_at=None,
                created_at=stamp,
                updated_at=stamp,
            )
        )
    else:
        row.value = new_version
        row.version = new_version
        row.updated_at = stamp
    logger.info("app_config['%s']：%s → %s", CONFIG_VERSION_KEY, before or "(缺失)", new_version)
    return new_version


def goal_rewards(db: Session) -> list[dict[str, Any]]:
    """11 个目标的奖励分值（按 `order`，与 PLAN §10.1 的表格顺序一致）。"""
    rows = db.execute(select(GoalDef).order_by(GoalDef.order, GoalDef.id)).scalars().all()
    return [{"id": row.id, "name": row.name, "tier": row.tier, "reward": int(row.reward)} for row in rows]


def get_config(db: Session) -> dict[str, Any]:
    """当前系统配置（GET /admin/config）。"""
    return {
        "dailyCap": _read_int(db, DAILY_CAP_KEY, DEFAULT_DAILY_CAP),
        "badgesEnabled": _read_int(db, BADGES_ENABLED_KEY, DEFAULT_BADGES_ENABLED),
        "shopVersion": shop_service.current_version(db),
        "goalRewards": goal_rewards(db),
    }


def update_config(
    db: Session, payload: SystemConfigUpdate, *, admin_id: str, ip: str | None = None
) -> dict[str, Any]:
    """修改系统配置（PUT /admin/config）：只改传了的项，逐项写审计，**有改动才推版本号**。

    一次调用 = 一个事务（`transaction(db)`）：配置写入、`config_version` bump、`update_config`
    审计三者要么都生效、要么都回滚 —— 不会出现「配置改了版本没动」「版本动了配置没改」
    或「改了配置没留痕」的中间态（校验不通过抛 `AppError` → 整体回滚，版本号保持原值）。
    """
    changes: dict[str, Any] = {}
    changed: list[str] = []

    with transaction(db):
        before = get_config(db)

        if payload.dailyCap is not None and payload.dailyCap != before["dailyCap"]:
            _write_int(db, DAILY_CAP_KEY, payload.dailyCap, default=DEFAULT_DAILY_CAP)
            changes[DAILY_CAP_KEY] = {"before": before["dailyCap"], "after": payload.dailyCap}
            changed.append("dailyCap")

        if payload.badgesEnabled is not None and payload.badgesEnabled != before["badgesEnabled"]:
            _write_int(db, BADGES_ENABLED_KEY, payload.badgesEnabled, default=DEFAULT_BADGES_ENABLED)
            changes[BADGES_ENABLED_KEY] = {"before": before["badgesEnabled"], "after": payload.badgesEnabled}
            changed.append("badgesEnabled")

        if payload.goalRewards:
            rewards_before = {item["id"]: item["reward"] for item in before["goalRewards"]}
            for patch in payload.goalRewards:
                if patch.id not in rewards_before:
                    raise AppError(ErrorCode.NOT_FOUND, f"目标不存在：{patch.id}")
                if rewards_before[patch.id] == patch.reward:
                    continue
                goal = db.execute(select(GoalDef).where(GoalDef.id == patch.id)).scalar_one()
                changes.setdefault("goal_def.reward", {})[patch.id] = {
                    "before": rewards_before[patch.id],
                    "after": patch.reward,
                }
                goal.reward = patch.reward
                changed.append(f"goalRewards:{patch.id}")

        if changed:
            # 真的写进了至少一项配置 → 同事务推版本号（附录 B §5.5 的 ⚠️：保存成功后**必须**更新）。
            # 位置在审计之前，好让审计把"推到了哪个版本"一起记下来（D10-6 可追溯）。
            changes["configVersion"] = {"before": _stored_version(db), "after": bump_version(db)}
            audit.write_op_log(
                db,
                admin_id=admin_id,
                action=audit.ACTION_UPDATE_CONFIG,
                target_type="config",
                target_id=",".join(changed),
                detail=changes,
                ip=ip,
            )

        # 先 flush 再回读：Session 是 autoflush=False（app/core/database.py），
        # 新增的配置行若不显式 flush，回读会拿到"默认值"而不是刚写入的值。
        db.flush()
        after = get_config(db)

    return {**after, "changed": changed}


__all__ = [
    "BADGES_ENABLED_KEY",
    "CONFIG_VERSION_KEY",
    "DAILY_CAP_KEY",
    "DEFAULT_BADGES_ENABLED",
    "DEFAULT_DAILY_CAP",
    "FALLBACK_VERSION",
    "bump_version",
    "current_version",
    "get_config",
    "goal_rewards",
    "next_version",
    "update_config",
]
