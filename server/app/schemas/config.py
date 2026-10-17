"""`GET /api/v1/config` 的响应模型（逐字对齐 docs/APPENDIX-B-data-and-api.md §5.5）。

字段名直接用契约里的 camelCase（`pointsDailyCap` / `badgesEnabled` / `goalRewards` / `serverTime`），
不引 alias 映射 —— 与 §5.4 的 `ShopItemsData` 同一风格。

**`badgesEnabled` 是 JSON 布尔**（§5.5 的 ⚠️ 行）：库内 `1`/`0` 只是存储表示，
把整数回给客户端等于把「数据库表示」泄漏进公共契约；这里用 `bool` 类型完成序列化，
并默认 `true`（缺键 = 缺省启用，§5.5 缺失列）。
"""

from __future__ import annotations

from pydantic import BaseModel, Field


class GoalRewardData(BaseModel):
    """一条目标奖励分值（§5.5 的 `goalRewards[]` 元素）。"""

    goalId: str = Field(description="目标编码，= 服务端 goal_def.id（S1..S5 / M1..M5 / L1）")
    reward: int = Field(description="达成奖励积分（非负整数，= goal_def.reward）")


class ConfigData(BaseModel):
    """`GET /api/v1/config` 的业务数据（附录 B §5.5）。"""

    version: str = Field(
        description="本份配置的版本号（app_config['config_version']，缺失时 \"0.0.0\"，非空）；客户端只比较「与上一份是否相同」"
    )
    pointsDailyCap: int = Field(description="记录类积分每日封顶（app_config['points_daily_cap']，缺失/非法时 200）")
    badgesEnabled: bool = Field(
        description="徽章开关（app_config['badges_enabled'] 的 1/0 → JSON 布尔；缺失时 true）"
    )
    goalRewards: list[GoalRewardData] = Field(
        description="目标奖励分值（服务端 goal_def 逐行，按 id 升序；表为空则空数组 = 客户端用内置种子）"
    )
    serverTime: int = Field(description="服务端当前毫秒时间戳")


__all__ = ["ConfigData", "GoalRewardData"]
