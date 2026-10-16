"""⑥ 系统配置（`app_config` + `goal_def`）。

口径（PLAN §13.2 ⑥、附录 B §5.4、附录 D10-5）
---------------------------------------------
| 配置项 | 存储 | 说明 |
|---|---|---|
| 每日封顶值 | `app_config['points_daily_cap']` | 种子值 `200`（PLAN §9.2）；非空整数 |
| 徽章开关 | `app_config['badges_enabled']` | 本切片新增的键（原表只有 `points_daily_cap`/`shop_items_version`/`account_purge_retention_days`），默认 `1` |
| 目标奖励分值 | `goal_def.reward` | 11 个目标（PLAN §10.1 / 附录 B §8.1），按 `id` 逐个改 |

新增两个键名不违反任何契约：`app_config` 本来就是 key-value 配置表（附录 B §1.2），
而"徽章开关"是 PLAN §13.2 ⑥ / D10-5 明确要求可配的项 —— 文档没给它键名，本模块**在本文件与
`admin_web/README.md` 里写死**，避免两处口径。

⚠ 未决问题（见 `admin_web/README.md` §未决问题与任务报告）：附录 D10-5 的通过判据含「App 侧能读到」，
但附录 B §5.4 / PLAN §13.3 只定义了**商品目录**的下发通道（`GET /api/v1/shop/items`），
没有任何接口把 `points_daily_cap` / `badges_enabled` / `goal_def.reward` 下发给客户端。
按 AGENTS §1.3 停手规则，本模块**只把服务端侧写正确**（保存成功、可回读、有审计），
不自行新增客户端接口（那属于 `server/app/` 的写入范围）。
"""

from __future__ import annotations

import logging
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.errors import AppError, ErrorCode
from app.core.security import now_ms
from app.models import AppConfig, GoalDef
from app.services import shop_service

from admin_web.schemas import SystemConfigUpdate
from admin_web.services import audit
from admin_web.services.base import transaction

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
    """修改系统配置（PUT /admin/config）：只改传了的项，逐项写审计。"""
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
    "DAILY_CAP_KEY",
    "DEFAULT_BADGES_ENABLED",
    "DEFAULT_DAILY_CAP",
    "get_config",
    "goal_rewards",
    "update_config",
]
