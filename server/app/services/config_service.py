"""客户端可读配置的下发（S6 收尾，附录 B §5.5 / 验收 D10-5）。

职责
----
1. **唯一的下行通道**：把后台 `/admin/config` 能改的三项系统配置交给 App ——
   `app_config['points_daily_cap']`（每日记录积分封顶）、`app_config['badges_enabled']`（徽章开关）、
   `goal_def` 逐行的奖励分值。t6 报出的缺口正是「后台只写不读」：D10-5 要求「改完 App 侧能读到」，
   而 §5.4 当时只有商品目录的下发通道，没有配置通道。
2. **只读**：不写 `app_config`、不写 `admin_op_log`、不写 `sync_log`（§5.5 语义边界）。客户端是冷启动
   拉一次，但把只读接口做成"带审计的写"会让日志表被无意义地撑大。
3. **不新增表**：`goalRewards` 直接来自既有 `goal_def`（§5.5：不新增表）。
4. **缺失/非法 → 文档默认值，不改写库、不报错**（§5.5 缺失列）：
   `version → "0.0.0"`、`pointsDailyCap → 200`、`badgesEnabled → true`。
   查库异常**直接冒泡成 500**（`{ok:false, code:"SERVER_ERROR"}`），让客户端走「整份丢弃」——
   绝不返回半份配置被客户端当成有效值写进本地 `app_config['server_config']`。

口径细节（两处需要写死的判断）
------------------------------
* **`version` 的优先级**：先 `value`、再 `version` 列，与 `shop_service.current_version` 同一套规则，
  但**键名独立**（`config_version` ≠ `shop_items_version`）—— 否则改一次价格就把配置版本顶掉，
  客户端会以为"配置变了"（§5.5 明确要求独立键名）。
* **`pointsDailyCap` 为负**：契约字段是「非负整数」，而客户端规则是「任一字段非法 → 整份丢弃」。
  所以库里出现负数时**按默认值 200 下发**（并记 warning），而不是原样回 `-1` —— 原样回会让
  客户端把`封顶值 / 徽章开关 / 目标奖励`三项一起丢掉。负数只能来自手工改库：后台 `PUT /admin/config`
  的 `dailyCap` 约束是 `ge=0`（`admin_web/schemas.py` 的 `SystemConfigUpdate`）。
* **`goalRewards` 不做隐式过滤**：§5.5 写的是「逐行」，且上游 `GoalRewardUpdate.reward` 约束 `ge=0`，
  因此这里不为了"防御脏数据"而悄悄删条目（那会与契约的「逐行」矛盾，也让条目数对不上）。
"""

from __future__ import annotations

import logging
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import now_ms
from app.models import AppConfig, GoalDef

logger = logging.getLogger("carbonboo.server.config")

#: 配置版本号的键（§5.5：与商品目录**独立**的键名）
CONFIG_VERSION_KEY = "config_version"

#: 键缺失时的缺省版本（非空，不回 null）
FALLBACK_VERSION = "0.0.0"

#: 每日记录积分封顶的键（种子 200，见 sql/seed.sql；后台 /admin/config 可改）
DAILY_CAP_KEY = "points_daily_cap"

#: 每日记录积分封顶的缺省值（PLAN §9.2 / 附录 B §5.5 缺失列）
DEFAULT_DAILY_CAP = 200

#: 徽章开关的键（1 = 启用 / 0 = 关闭；由 t6 的后台系统配置写入）
BADGES_ENABLED_KEY = "badges_enabled"

#: 徽章开关缺省值（§5.5：缺省启用）
DEFAULT_BADGES_ENABLED = True


def _config_row(db: Session, key: str) -> AppConfig | None:
    """按主键取一行 `app_config`（不存在返回 None）。"""
    return db.execute(select(AppConfig).where(AppConfig.id == key)).scalar_one_or_none()


def current_version(db: Session) -> str:
    """读 `app_config['config_version']`：`value` 优先、`version` 列兜底；都没有 → `"0.0.0"`。

    与 `shop_service.current_version` 的区别只有键名（这就是"独立键名"的全部含义）：
    版本必须真的会变，客户端才可能判断"内容是否变了"（§5.5 的 ⚠️）。
    """
    row = _config_row(db, CONFIG_VERSION_KEY)
    if row is None or not (row.value or row.version):
        logger.info("app_config['%s'] 缺失，配置版本以 %s 下发", CONFIG_VERSION_KEY, FALLBACK_VERSION)
        return FALLBACK_VERSION
    return row.value or row.version or FALLBACK_VERSION


def points_daily_cap(db: Session) -> int:
    """读 `app_config['points_daily_cap']`：缺键 / 非整数 / 负数 → `200`（不写库、不报错）。"""
    row = _config_row(db, DAILY_CAP_KEY)
    if row is None or row.value is None:
        return DEFAULT_DAILY_CAP
    try:
        value = int(str(row.value).strip())
    except (TypeError, ValueError):
        logger.warning("app_config['%s'] 不是整数（现值 %r），按默认值 %s 下发", DAILY_CAP_KEY, row.value, DEFAULT_DAILY_CAP)
        return DEFAULT_DAILY_CAP
    if value < 0:
        # 契约字段是「非负整数」；原样下发会让客户端整份丢弃（把另外两项也一起丢掉）
        logger.warning("app_config['%s'] 为负数（现值 %s），按默认值 %s 下发", DAILY_CAP_KEY, value, DEFAULT_DAILY_CAP)
        return DEFAULT_DAILY_CAP
    return value


def badges_enabled(db: Session) -> bool:
    """读 `app_config['badges_enabled']`：`1 → True`、`0 → False`；缺键 / 非整数 → `True`。

    只把库内的 `1`/`0` 当作存储表示，**不下发整数**（§5.5 的 ⚠️：客户端要的是布尔语义）。
    """
    row = _config_row(db, BADGES_ENABLED_KEY)
    if row is None or row.value is None:
        return DEFAULT_BADGES_ENABLED
    try:
        value = int(str(row.value).strip())
    except (TypeError, ValueError):
        logger.warning(
            "app_config['%s'] 不是 1/0（现值 %r），按缺省启用下发", BADGES_ENABLED_KEY, row.value
        )
        return DEFAULT_BADGES_ENABLED
    return value != 0


def goal_rewards(db: Session) -> list[dict[str, Any]]:
    """目标奖励分值：`goal_def` 逐行，按 `goal_def.id` 升序（§5.5 的取值来源）。

    刻意**不**复用后台的 `admin_web.services.system_config.goal_rewards`：那个是给管理端回显用的
    （带 `name` / `tier`、按 `order` 排），客户端契约只要 `{goalId, reward}` 且按 `id` 升序 ——
    直接复用会把管理端的展示字段泄漏进公共契约，也让两处排序口径互相牵制。
    """
    rows = db.execute(select(GoalDef.id, GoalDef.reward).order_by(GoalDef.id)).all()
    return [{"goalId": row[0], "reward": int(row[1])} for row in rows]


def payload(db: Session, *, now: int | None = None) -> dict[str, Any]:
    """`GET /api/v1/config` 的完整载荷（§5.5 的 `data`）。

    顺序固定 `version → pointsDailyCap → badgesEnabled → goalRewards → serverTime`，
    与文档的响应示例同序（便于人工比对 openapi / 响应体）。
    """
    return {
        "version": current_version(db),
        "pointsDailyCap": points_daily_cap(db),
        "badgesEnabled": badges_enabled(db),
        "goalRewards": goal_rewards(db),
        "serverTime": now_ms() if now is None else now,
    }


__all__ = [
    "BADGES_ENABLED_KEY",
    "CONFIG_VERSION_KEY",
    "DAILY_CAP_KEY",
    "DEFAULT_BADGES_ENABLED",
    "DEFAULT_DAILY_CAP",
    "FALLBACK_VERSION",
    "badges_enabled",
    "current_version",
    "goal_rewards",
    "payload",
    "points_daily_cap",
]
