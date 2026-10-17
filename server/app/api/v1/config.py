"""客户端可读配置接口（逐条对齐 docs/APPENDIX-B-data-and-api.md §5.5）。

    GET /api/v1/config   全局可读配置（**无需 token**）

口径
----
* **鉴权：无**（§5.5 表头；与 §5.4 的 `GET /api/v1/shop/items` 同组）：公共只读配置，
  **未登录也要能读到** —— 它只下发「下行的默认值」，不含任何账号数据（铁律 1：本机仍是唯一真相源）。
* 这是验收 **D10-5**「后台改目标奖励分值 / 每日封顶值 / 徽章开关 → App 侧能读到」的**唯一通道**；
  t6 报出的缺口正是「后台只写不读」：`PUT /admin/config` 当时没有任何下发对象。
* **只读**：不写 `app_config`、不写 `admin_op_log`、不写 `sync_log`（§5.5 语义边界）。
  客户端冷启动拉一次，把只读接口做成"带审计的写"只会让日志表被无意义地撑大。
* 失败（查库异常）→ 统一错误信封 `{ok:false, code:"SERVER_ERROR"}` + HTTP 500（§5.5 的 res 500 示例）：
  客户端据此**整份丢弃**并沿用上一份有效配置 —— 半份配置比没有配置更糟。

取值规则（逐字见 `app/services/config_service.py` 的模块注释）：`version` 读独立键
`app_config['config_version']` 且**非空**（缺失 → `"0.0.0"`）；`pointsDailyCap` 缺失/非整数 → `200`；
`badgesEnabled` 由库内 `1`/`0` **序列化为 JSON 布尔**；`goalRewards` 由既有 `goal_def` 表逐行生成
（按 `id` 升序，**不新增表**）；`serverTime` 为服务端毫秒时间戳。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.schemas.common import ErrorEnvelope, OkEnvelope
from app.schemas.config import ConfigData
from app.services import config_service

router = APIRouter()

_ERROR_RESPONSES: dict[int | str, dict[str, object]] = {
    500: {
        "model": ErrorEnvelope,
        "description": "服务端配置读取失败（SERVER_ERROR）；客户端应整份丢弃并沿用上一份有效配置/内置种子",
    },
}


@router.get(
    "",
    summary="全局可读配置（系统配置下发通道）",
    description=(
        "下发后台 `/admin/config` 可改的三项系统配置：每日记录积分封顶 `pointsDailyCap`、"
        "徽章开关 `badgesEnabled`（**JSON 布尔**）、目标奖励分值 `goalRewards`（来自既有 `goal_def` 表）。"
        "**无需令牌**（公共只读配置）；本接口只读、不写任何日志表、不回写客户端本地值。"
        "客户端冷启动拉取一次并整份覆盖本机 `app_config['server_config']`；"
        "本接口失败或返回非法数据时，客户端**整份丢弃**（本机仍是唯一真相源，铁律 1）。"
    ),
    response_model=OkEnvelope[ConfigData],
    responses=_ERROR_RESPONSES,
)
def config(db: Annotated[Session, Depends(get_db)]) -> OkEnvelope[ConfigData]:
    """返回整份配置（§5.5）；任一项缺失走文档默认值，查库异常冒泡成 500 让客户端整份丢弃。"""
    return OkEnvelope[ConfigData](data=ConfigData(**config_service.payload(db)))


__all__ = ["router"]
