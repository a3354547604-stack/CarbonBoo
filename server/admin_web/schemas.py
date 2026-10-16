"""后台管理端的请求 / 响应模型（`{ok, data}` 信封统一取自 `app.schemas.common`）。

字段命名口径
------------
* 业务字段一律 **camelCase**（与服务端既有响应、附录 B §5.4 的 `onShelf` / `isDefaultFree` 一致）；
* 信封沿用 `OkEnvelope[T]` / `ErrorEnvelope`（附录 B §5.2），本模块不另立一套。

附录 B §5.4 **只冻结了路径与鉴权**，没有给 `/admin/*` 的响应体示例（那唯一一份示例是
`GET /api/v1/shop/items`）。因此这里的响应体是本切片定义并在 `admin_web/README.md` 里写明的契约，
商品目录那一份刻意**复用** `app.schemas.shop.ShopItemsData`，保证后台看到的价目表与客户端拉到的
是**同一个结构**（不多一条、不少一条）。
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

from app.schemas.shop import ShopItemData, ShopItemsData

__all__ = [
    "AdminItemUpdate",
    "AdminLoginData",
    "AdminLoginRequest",
    "AdminLogsData",
    "AdminOrdersData",
    "AdminUserRow",
    "AdminUsersData",
    "ChangePasswordData",
    "ChangePasswordRequest",
    "DeviceRow",
    "GoalReward",
    "IconUploadRequest",
    "LogoutData",
    "OpLogRow",
    "OrderRow",
    "OverviewData",
    "ShopItemCreate",
    "ShopItemData",
    "ShopItemsData",
    "SystemConfigData",
    "SystemConfigUpdate",
    "SystemConfigUpdateData",
]


# --------------------------------------------------------------------------- #
# ① 管理员登录 + 改密码
# --------------------------------------------------------------------------- #
class AdminLoginRequest(BaseModel):
    """`POST /admin/login` 请求体。"""

    username: str = Field(min_length=1, max_length=64, description="管理员用户名")
    password: str = Field(min_length=1, max_length=128, description="管理员口令（永不出现在日志里）")


class AdminLoginData(BaseModel):
    """`POST /admin/login` 响应体（附录 B §5.4：管理员登录 → `adminToken`）。

    同时会种一个 HttpOnly 会话 Cookie（浏览器服务端渲染页面用）；接口调用方忽略它即可。
    """

    adminToken: str = Field(description="管理端 JWT（密钥 ② + audience ②，与客户端令牌不通用）")
    adminId: str = Field(description="管理员行 id（admin_user.id）")
    username: str = Field(description="管理员用户名")
    expiresAt: int = Field(description="令牌到期时间（毫秒）")


class ChangePasswordRequest(BaseModel):
    """`POST /admin/password` 请求体（附录 B §5.4）。"""

    oldPassword: str = Field(min_length=1, max_length=128, description="当前口令")
    newPassword: str = Field(min_length=1, max_length=128, description="新口令（强口令策略见 admin_web/README.md）")


class ChangePasswordData(BaseModel):
    changed: bool = Field(default=True, description="恒为 true（失败走错误信封）")
    reloginRequired: bool = Field(default=True, description="改密后旧令牌仍有效期内可用；建议重新登录")


class LogoutData(BaseModel):
    loggedOut: bool = Field(default=True, description="恒为 true（服务端无状态，只清 Cookie）")


# --------------------------------------------------------------------------- #
# ② 商品管理
# --------------------------------------------------------------------------- #
class ShopItemCreate(BaseModel):
    """`POST /admin/items` 请求体。"""

    id: str = Field(min_length=2, max_length=36, description="商品编码（小写字母/数字/下划线，如 frame_09）")
    section: str = Field(default="frame", max_length=32, description="分区：frame | theme")
    name: str = Field(min_length=1, max_length=64, description="展示名")
    description: str | None = Field(default=None, max_length=255, description="一句话描述")
    price: int = Field(ge=0, le=10_000_000, description="价格（积分）")
    icon: str | None = Field(default=None, max_length=255, description="图标标识；缺省用 res://<id>")
    order: int = Field(default=0, ge=0, le=10_000, description="排序（升序）")
    onShelf: int = Field(default=1, ge=0, le=1, description="1 = 在架，0 = 已下架")
    isDefaultFree: int = Field(default=0, ge=0, le=1, description="1 = 默认免费")


class AdminItemUpdate(BaseModel):
    """`PATCH /admin/items/{id}` 请求体（附录 B §5.4：改价 / 改描述 / 排序 / 上下架）。

    PATCH 语义：**只改传了的字段**（`exclude_unset`），没传的保持库内现值。
    """

    name: str | None = Field(default=None, min_length=1, max_length=64)
    description: str | None = Field(default=None, max_length=255)
    price: int | None = Field(default=None, ge=0, le=10_000_000)
    order: int | None = Field(default=None, ge=0, le=10_000)
    onShelf: int | None = Field(default=None, ge=0, le=1)
    isDefaultFree: int | None = Field(default=None, ge=0, le=1)
    icon: str | None = Field(default=None, max_length=255, description="图标标识；也可用专门的图标上传接口")


class IconUploadRequest(BaseModel):
    """`POST /admin/items/{id}/icon` 的 JSON 形态请求体（浏览器表单走这条）。

    另一条形态是 `Content-Type: image/*` + 原始字节（curl / 脚本走那条）。两者落到同一个服务函数。
    刻意**不引入 `python-multipart`**：后台是本项目的可选件，不为它给服务端加一个运行时依赖。
    """

    filename: str = Field(default="icon.png", max_length=128, description="原始文件名（只用于取扩展名）")
    dataBase64: str = Field(min_length=1, description="图片字节的 base64（可带 data:image/...;base64, 前缀）")


# --------------------------------------------------------------------------- #
# ③ 用户列表
# --------------------------------------------------------------------------- #
class DeviceRow(BaseModel):
    """按 `device_id` 去重的设备行（口径见附录 B §3 注：后台的"设备列表"= 该用户已同步行按 device_id 去重）。"""

    deviceId: str = Field(description="客户端 device_id")
    lastSyncAt: int = Field(description="该设备最后一次上行/下行的时间（同步行 updated_at 的最大值）")
    rowCount: int = Field(description="该设备贡献的未删除同步行数")


class AdminUserRow(BaseModel):
    """一行账号（含其设备列表与记录数）。"""

    userId: str = Field(description="业务归属键（各表的 user_id）")
    username: str = Field(description="账号用户名；无账号只有数据时显示占位")
    isActive: int = Field(description="server_user.is_active（0 = 已注销，保留期内）")
    accountCreatedAt: int | None = Field(default=None, description="账号首次接入时间（server_user.created_at）")
    lastLoginAt: int | None = Field(default=None, description="账号最后一次登录时间")
    firstSeenAt: int | None = Field(default=None, description="云端数据最早出现时间（同步行 created_at 最小值）")
    lastSyncAt: int | None = Field(default=None, description="云端数据最后更新时间")
    recordCount: int = Field(default=0, description="碳记录数（carbon_record 未删除行）")
    rowCount: int = Field(default=0, description="参与同步的 9 张表的未删除行数合计")
    deviceCount: int = Field(default=0, description="设备数（按 device_id 去重）")
    devices: list[DeviceRow] = Field(default_factory=list, description="设备列表（按最后同步时间倒序）")


class AdminUsersData(BaseModel):
    total: int = Field(description="账号总数（分页前）")
    page: int = Field(description="当前页（从 1 开始）")
    pageSize: int = Field(description="每页条数")
    items: list[AdminUserRow] = Field(description="当前页账号")


# --------------------------------------------------------------------------- #
# ④ 数据总览
# --------------------------------------------------------------------------- #
class OverviewData(BaseModel):
    """`GET /admin/overview`（PLAN §13.2 ④：接入设备数、总记录数、今日新增、总减排量、总积分发放）。"""

    accountCount: int = Field(description="账号总数（server_user 行数）")
    activeAccountCount: int = Field(description="未注销账号数（is_active = 1）")
    deviceCount: int = Field(description="接入设备数（9 张同步表的 device_id 去重）")
    recordCount: int = Field(description="总记录数（carbon_record 未删除行）")
    todayRecordCount: int = Field(description="今日新增（created_at 落在服务端本地今天的未删除记录）")
    totalReductionKg: float = Field(description="总减排量（kg，4 位小数）")
    reductionByCategory: dict[str, float] = Field(description="总减排量按四大类行为拆分")
    totalPointsIssued: int = Field(description="总积分发放（正流水合计：记录分 + 目标奖励）")
    totalPointsSpent: int = Field(description="总积分支出（负流水绝对值合计：碳小铺 + 碳普惠）")
    totalPointsBalance: int = Field(description="发放 − 支出")
    orderCount: int = Field(description="订单数（user_purchase 未删除行）")
    itemCount: int = Field(description="商品数")
    onShelfItemCount: int = Field(description="在架商品数")
    shopVersion: str = Field(description="商品目录版本号（app_config['shop_items_version']）")
    lastSyncAt: int | None = Field(default=None, description="云端最后一次同步时间（9 张表 updated_at 最大值）")


# --------------------------------------------------------------------------- #
# ⑤ 订单记录
# --------------------------------------------------------------------------- #
class OrderRow(BaseModel):
    """一行订单（谁、什么时候、买了什么、花了多少分）。"""

    id: str = Field(description="user_purchase.id")
    userId: str = Field(description="购买者 user_id")
    username: str | None = Field(default=None, description="购买者账号名（无对应账号时为 null）")
    itemId: str = Field(description="商品编码")
    itemName: str | None = Field(default=None, description="商品名（按 shop_item 现值取，商品被删则 null）")
    pricePaid: int = Field(description="成交价（下单时的价格，不随后台改价变化）")
    purchasedAt: int = Field(description="购买时间（毫秒）")


class AdminOrdersData(BaseModel):
    total: int = Field(description="订单总数（分页前）")
    page: int = Field(description="当前页（从 1 开始）")
    pageSize: int = Field(description="每页条数")
    items: list[OrderRow] = Field(description="当前页订单（按下单时间倒序）")


# --------------------------------------------------------------------------- #
# ⑥ 系统配置
# --------------------------------------------------------------------------- #
class GoalReward(BaseModel):
    """一个目标的奖励分值（`goal_def`）。"""

    id: str
    name: str
    tier: str
    reward: int = Field(description="达成奖励积分（PLAN §10.1）")


class SystemConfigData(BaseModel):
    """`GET /admin/config` / `PUT /admin/config` 的业务数据（PLAN §13.2 ⑥）。"""

    dailyCap: int = Field(description="每日记录积分封顶值（app_config['points_daily_cap']，PLAN §9.2 默认 200）")
    badgesEnabled: int = Field(description="徽章开关：1 = 启用，0 = 关闭（app_config['badges_enabled']）")
    shopVersion: str = Field(description="商品目录版本号（改价后自动 bump，客户端据此整份覆盖）")
    goalRewards: list[GoalReward] = Field(description="11 个目标的奖励分值（goal_def，PLAN §10.1）")


class GoalRewardUpdate(BaseModel):
    id: str = Field(min_length=1, max_length=36)
    reward: int = Field(ge=0, le=1_000_000)


class SystemConfigUpdate(BaseModel):
    """`PUT /admin/config` 请求体：只改传了的项。"""

    dailyCap: int | None = Field(default=None, ge=0, le=1_000_000, description="每日记录积分封顶值")
    badgesEnabled: int | None = Field(default=None, ge=0, le=1, description="徽章开关")
    goalRewards: list[GoalRewardUpdate] | None = Field(default=None, description="目标奖励分值（按 id 逐个改）")


class SystemConfigUpdateData(BaseModel):
    """`PUT /admin/config` 响应体：改完后的完整配置（前台直接回显）。"""

    dailyCap: int
    badgesEnabled: int
    shopVersion: str
    goalRewards: list[GoalReward]
    changed: list[str] = Field(description="本次实际改动的项（如 ['dailyCap', 'goalRewards:S3']）")


# --------------------------------------------------------------------------- #
# ⑦ 操作日志
# --------------------------------------------------------------------------- #
class OpLogRow(BaseModel):
    """一行操作日志（谁改了价格、什么时候改的）。"""

    id: str
    adminId: str
    adminUsername: str | None = Field(default=None, description="操作人（按 admin_user 现值取）")
    action: str = Field(description="login | change_price | toggle_shelf | update_item | create_item | upload_icon | update_config | change_password | bootstrap_admin")
    targetType: str | None = Field(default=None, description="item | config | admin | goal")
    targetId: str | None = Field(default=None, description="目标行 id（商品编码 / 配置键 / 管理员 id）")
    detail: dict[str, Any] | None = Field(default=None, description="改前 / 改后（JSON 解析后）")
    ip: str | None = Field(default=None, description="调用方 IP")
    createdAt: int = Field(description="操作时间（毫秒）")


class AdminLogsData(BaseModel):
    total: int = Field(description="日志总数（分页前）")
    page: int = Field(description="当前页（从 1 开始）")
    pageSize: int = Field(description="每页条数")
    items: list[OpLogRow] = Field(description="当前页日志（按时间倒序）")


#: 页面/接口共用的格式判定（`security.wants_html` 的返回值语义）
PageFormat = Literal["json", "html"]
