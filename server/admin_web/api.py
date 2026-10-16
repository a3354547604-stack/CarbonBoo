"""`/admin/*` JSON 接口（逐条对齐 `docs/APPENDIX-B-data-and-api.md` §5.4）。

| 方法 | 路径 | 鉴权 | 本模块的处理函数 |
|---|---|---|---|
| GET | `/admin/login` | 无 | `login_page`（服务端渲染登录页，见 `pages.py`） |
| POST | `/admin/login` | 无 | `login`（JSON → `adminToken`；表单 → 303 + 会话 Cookie） |
| POST | `/admin/password` | adminToken | `change_password` |
| GET | `/admin/items` | adminToken | `items`（JSON / HTML 二态） |
| POST | `/admin/items` | adminToken | `create_item` |
| PATCH | `/admin/items/{id}` | adminToken | `patch_item` |
| POST | `/admin/items/{id}/icon` | adminToken | `upload_icon` |
| GET | `/admin/users` | adminToken | `users` |
| GET | `/admin/overview` | adminToken | `overview` |
| GET | `/admin/orders` | adminToken | `orders` |
| GET | `/admin/config` | adminToken | `config`（JSON / HTML 二态） |
| PUT | `/admin/config` | adminToken | `update_config` |
| GET | `/admin/logs` | adminToken | `logs` |

外加三条**本可选件自有**的路由（附录 B §5.4 未列，登记在 `admin_web/README.md`）：

* `POST /admin/logout`：清会话 Cookie（管理端要有退出路径）；
* `GET /admin/icons/{filename}`：取回上传的图标（adminToken / 会话 Cookie）；
* `GET /admin/static/{filename}`：后台自有 CSS/JS 两个白名单文件（**无需令牌**，登录页也要样式）。

二态路由（同一个路径既能当接口又能当页面）
--------------------------------------------
`Accept: text/html` → 交给 `pages.py` 服务端渲染；否则 → JSON 信封。判定只在 `security.wants_html`
一处，浏览器地址栏导航一定带 `text/html`，`static/admin.js` 的 `fetch()` 显式要求 `application/json`。
这样附录 B §5.4 的路径表**一条不多、一条不少**。

鉴权
----
所有受保护路由用同一个依赖 `security.require_admin`（密钥 ② + audience ②）。
客户端令牌更早会被 `app/main.py` 的隔离中间件 403 拦下，两条防线都在。
"""

from __future__ import annotations

import logging
from typing import Annotated, Any
from urllib.parse import parse_qs

from fastapi import APIRouter, Depends, Request, Response, status
from fastapi.responses import FileResponse, RedirectResponse
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from app.core.config import Settings, get_settings
from app.core.database import get_db
from app.core.errors import AppError, ErrorCode
from app.schemas.common import ErrorEnvelope, OkEnvelope
from app.schemas.shop import ShopItemData, ShopItemsData
from app.core.security import TokenPrincipal

from admin_web import pages
from admin_web.config import STATIC_DIR, AdminWebSettings, get_admin_settings
from admin_web.schemas import (
    AdminItemUpdate,
    AdminLoginData,
    AdminLoginRequest,
    AdminLogsData,
    AdminOrdersData,
    AdminUsersData,
    ChangePasswordData,
    ChangePasswordRequest,
    IconUploadRequest,
    LogoutData,
    OverviewData,
    ShopItemCreate,
    SystemConfigData,
    SystemConfigUpdate,
    SystemConfigUpdateData,
)
from admin_web.security import (
    attach_admin_cookie,
    check_login_rate_limit,
    clear_admin_cookie,
    client_ip,
    require_admin,
    safe_next,
    wants_html,
)
from admin_web.services import accounts, audit, catalog, icons, stats, system_config
from admin_web.services.base import normalize_paging

logger = logging.getLogger("carbonboo.admin.api")

#: 后台自有静态资源白名单（只有这两个文件；`/admin/static/*` 不做目录列举）
STATIC_WHITELIST: frozenset[str] = frozenset({"admin.css", "admin.js"})

router = APIRouter(prefix="/admin", tags=["后台管理端"])

_ERROR_RESPONSES: dict[int | str, dict[str, Any]] = {
    400: {"model": ErrorEnvelope, "description": "参数不合法（INVALID_REQUEST / PASSWORD_INVALID / USERNAME_INVALID）"},
    401: {"model": ErrorEnvelope, "description": "凭据或令牌问题（CREDENTIAL_INVALID / TOKEN_INVALID）"},
    403: {"model": ErrorEnvelope, "description": "客户端令牌访问管理端（FORBIDDEN，由 main.py 的隔离中间件给出）"},
    404: {"model": ErrorEnvelope, "description": "资源不存在（NOT_FOUND）"},
    429: {"model": ErrorEnvelope, "description": "登录限流（RATE_LIMITED）"},
}

#: 依赖别名（FastAPI 依赖声明集中在这里，路由签名保持短）
AdminPrincipal = Annotated[TokenPrincipal, Depends(require_admin)]
DbSession = Annotated[Session, Depends(get_db)]
AppSettings = Annotated[Settings, Depends(get_settings)]
WebSettings = Annotated[AdminWebSettings, Depends(get_admin_settings)]


def _item_data(item: dict[str, Any]) -> ShopItemData:
    return ShopItemData(**item)


async def _read_json_body(request: Request, model: type[Any]) -> Any:
    """读并校验 JSON 请求体；任何解析 / 校验失败统一成 400 `INVALID_REQUEST`。

    为什么要这一步：为了让"同一路径既能收 JSON 又能收 urlencoded 表单"，本模块**手工**读 body，
    于是就拿不到 FastAPI 的自动校验（那会把 `RequestValidationError` 翻成 400）。手工读就必须自己
    把 `JSONDecodeError` / pydantic `ValidationError` 翻成同一个 400，否则坏 body 会变成 500 ——
    与附录 B §5.2「参数不合法 → 400 INVALID_REQUEST」不符。
    """
    try:
        payload = await request.json()
    except ValueError as exc:  # json.JSONDecodeError 是 ValueError 子类
        raise AppError(ErrorCode.INVALID_REQUEST, "请求体不是合法 JSON") from exc
    try:
        return model.model_validate(payload)
    except ValueError as exc:  # pydantic ValidationError 也是 ValueError 子类
        raise AppError(ErrorCode.INVALID_REQUEST, "请求体字段不合法（类型 / 长度 / 取值范围）") from exc


async def _read_urlencoded_form(request: Request) -> dict[str, str]:
    """解析 `application/x-www-form-urlencoded` 表单体（**不依赖 python-multipart**）。

    为什么不用 `request.form()`：Starlette 1.8 对**任何**表单类型都要求
    `python-multipart` 已安装（`_get_form` 里直接 assert），而 `python-multipart` 属于
    `server/requirements.txt`（服务端切片范围），本切片不擅自加运行时依赖。
    表单只承载 3 个短字符串字段（username / password / next），这里用标准库解析原始体，
    与 `admin.js` 的 fetch(JSON) 路径落到同一个服务函数。
    """
    raw = (await request.body()).decode("utf-8", errors="replace")
    parsed = parse_qs(raw, keep_blank_values=True)
    return {key: values[0] for key, values in parsed.items() if values}


# --------------------------------------------------------------------------- #
# ① 管理员登录 / 登出 / 改密码
# --------------------------------------------------------------------------- #
@router.get("/login", include_in_schema=False)
def login_page(request: Request, settings: AppSettings, web: WebSettings) -> Response:
    """后台登录页（附录 B §5.4 的 `GET /admin/login` = 登录页，永远是 HTML）。"""
    return pages.render_login(request, settings=settings, web=web)


@router.post(
    "/login",
    summary="管理员登录",
    description=(
        "管理员口令登录 → 返回 `adminToken`（管理侧独立 JWT：与客户端不同密钥、不同 audience）。"
        "浏览器表单（`application/x-www-form-urlencoded`）改走 303 + HttpOnly 会话 Cookie。"
    ),
    response_model=OkEnvelope[AdminLoginData],
    responses=_ERROR_RESPONSES,
)
async def login(
    request: Request,
    response: Response,
    settings: AppSettings,
    web: WebSettings,
    db: DbSession,
) -> Any:
    """登录：JSON 请求 → `{ok, data:{adminToken...}}`；表单请求 → 303 跳转。"""
    content_type = (request.headers.get("content-type") or "").lower()
    is_form = content_type.startswith("application/x-www-form-urlencoded")

    if is_form:
        form = await _read_urlencoded_form(request)
        username = str(form.get("username") or "")
        password = str(form.get("password") or "")
        target = safe_next(str(form.get("next") or ""), web)
    else:
        payload = await _read_json_body(request, AdminLoginRequest)
        username = payload.username
        password = payload.password
        target = safe_next(request.query_params.get("next"), web)

    check_login_rate_limit(request, username, settings=settings, admin_settings=web)
    try:
        data = accounts.login(
            db,
            username=username,
            password=password,
            settings=settings,
            admin_settings=web,
            ip=client_ip(request),
        )
    except AppError as exc:
        if not is_form:
            raise
        # 表单路径：重新渲染登录页并带上错误提示（不泄漏"用户名是否存在"）
        return pages.render_login(request, settings=settings, web=web, error=exc.message, status_code=exc.http_status)

    if is_form:
        redirect = RedirectResponse(target, status_code=status.HTTP_303_SEE_OTHER)
        attach_admin_cookie(redirect, data["adminToken"], settings=settings, admin_settings=web)
        return redirect

    response.headers["Cache-Control"] = "no-store"
    attach_admin_cookie(response, data["adminToken"], settings=settings, admin_settings=web)
    return OkEnvelope[AdminLoginData](data=AdminLoginData(**data))


@router.post(
    "/logout",
    summary="管理员登出",
    description="清掉会话 Cookie；管理端 JWT 无状态，过期自然失效（附录 B §5.4 未列，后台自有路由）。",
    response_model=OkEnvelope[LogoutData],
    responses=_ERROR_RESPONSES,
)
def logout(
    request: Request,
    response: Response,
    principal: AdminPrincipal,
    web: WebSettings,
    db: DbSession,
) -> OkEnvelope[LogoutData]:
    accounts.write_logout_log(
        db, admin_id=principal.subject, username=principal.username, ip=client_ip(request)
    )
    clear_admin_cookie(response, admin_settings=web)
    return OkEnvelope[LogoutData](data=LogoutData())


@router.post(
    "/password",
    summary="修改管理员密码",
    description="需提供当前口令；新口令须满足后台强口令策略（≥12 位、≥3 类字符、非常见弱口令）。",
    response_model=OkEnvelope[ChangePasswordData],
    responses=_ERROR_RESPONSES,
)
def change_password(
    request: Request,
    payload: ChangePasswordRequest,
    principal: AdminPrincipal,
    db: DbSession,
) -> OkEnvelope[ChangePasswordData]:
    accounts.change_password(
        db,
        admin_id=principal.subject,
        old_password=payload.oldPassword,
        new_password=payload.newPassword,
        ip=client_ip(request),
    )
    return OkEnvelope[ChangePasswordData](data=ChangePasswordData())


# --------------------------------------------------------------------------- #
# ② 商品管理
# --------------------------------------------------------------------------- #
@router.get(
    "/items",
    summary="商品列表",
    description="全部商品（含已下架）与目录版本号；与客户端 `GET /api/v1/shop/items` 同构（同一实现）。",
    response_model=OkEnvelope[ShopItemsData],
    responses=_ERROR_RESPONSES,
)
def items(request: Request, principal: AdminPrincipal, db: DbSession, web: WebSettings) -> Any:
    if wants_html(request):
        return pages.render_items(request, web=web, db=db)
    return OkEnvelope[ShopItemsData](data=ShopItemsData(**catalog.catalog(db)))


@router.post(
    "/items",
    summary="新增商品",
    description="新增一件商品并 bump 商品目录版本号（客户端下次启动整份覆盖生效）。",
    status_code=status.HTTP_201_CREATED,
    response_model=OkEnvelope[ShopItemData],
    responses=_ERROR_RESPONSES,
)
def create_item(
    request: Request,
    payload: ShopItemCreate,
    principal: AdminPrincipal,
    db: DbSession,
) -> OkEnvelope[ShopItemData]:
    item = catalog.create_item(db, payload, admin_id=principal.subject, ip=client_ip(request))
    return OkEnvelope[ShopItemData](data=_item_data(item))


@router.patch(
    "/items/{item_id}",
    summary="改价 / 改描述 / 排序 / 上下架",
    description="PATCH 语义：只改传了的字段。改价写 `change_price`、上下架写 `toggle_shelf`，并 bump 目录版本号。",
    response_model=OkEnvelope[ShopItemData],
    responses=_ERROR_RESPONSES,
)
def patch_item(
    request: Request,
    item_id: str,
    payload: AdminItemUpdate,
    principal: AdminPrincipal,
    db: DbSession,
) -> OkEnvelope[ShopItemData]:
    item = catalog.update_item(db, item_id, payload, admin_id=principal.subject, ip=client_ip(request))
    return OkEnvelope[ShopItemData](data=_item_data(item))


@router.post(
    "/items/{item_id}/icon",
    summary="上传商品图标",
    description=(
        "两种请求形态：`Content-Type: image/*` + 原始字节，或 `application/json` + `{filename, dataBase64}`。"
        "只接受 PNG / JPEG / WebP（按魔术字节识别），默认上限 512 KB。"
    ),
    response_model=OkEnvelope[ShopItemData],
    responses=_ERROR_RESPONSES,
)
async def upload_icon(
    request: Request,
    item_id: str,
    principal: AdminPrincipal,
    db: DbSession,
    web: WebSettings,
) -> OkEnvelope[ShopItemData]:
    content_type = (request.headers.get("content-type") or "").lower()
    if content_type.startswith("application/json"):
        payload = await _read_json_body(request, IconUploadRequest)
        raw = icons.decode_base64_payload(payload.dataBase64)
        original = payload.filename
    else:
        raw = await request.body()
        original = request.headers.get("x-filename") or f"{item_id}.png"

    # 落盘是阻塞 IO、写库是同步驱动：都放到线程池，别卡住事件循环
    url, filename = await run_in_threadpool(
        icons.save_icon,
        raw,
        item_id=item_id,
        upload_dir=web.resolved_upload_dir,
        url_prefix=web.icon_url_prefix,
        max_bytes=web.max_icon_bytes,
    )
    item = await run_in_threadpool(
        catalog.set_icon,
        db,
        item_id,
        url,
        admin_id=principal.subject,
        filename=original or filename,
        ip=client_ip(request),
    )
    return OkEnvelope[ShopItemData](data=_item_data(item))


@router.get(
    "/icons/{filename}",
    summary="取回上传的图标",
    description="后台自有路由（附录 B §5.4 未列）：返回上传的图标文件；客户端令牌访问同样 403。",
    response_class=FileResponse,
    responses=_ERROR_RESPONSES,
)
def get_icon(filename: str, principal: AdminPrincipal, web: WebSettings) -> FileResponse:
    path = icons.resolve_upload_path(web.resolved_upload_dir, filename)
    if not path.is_file():
        raise AppError(ErrorCode.NOT_FOUND, f"图标不存在：{filename}")
    return FileResponse(path, headers={"Cache-Control": "private, max-age=300"})


@router.get(
    "/static/{filename}",
    summary="后台自有静态资源",
    description="仅 `admin.css` / `admin.js` 两个白名单文件，无需令牌（登录页也要样式，且不含任何数据）。",
    response_class=FileResponse,
    include_in_schema=False,
)
def get_static(filename: str) -> FileResponse:
    if filename not in STATIC_WHITELIST:
        raise AppError(ErrorCode.NOT_FOUND, f"静态资源不存在：{filename}")
    path = STATIC_DIR / filename
    if not path.is_file():
        raise AppError(ErrorCode.NOT_FOUND, f"静态资源不存在：{filename}")
    return FileResponse(path, headers={"Cache-Control": "no-cache"})


# --------------------------------------------------------------------------- #
# ③④⑤ 用户列表 / 数据总览 / 订单记录
# --------------------------------------------------------------------------- #
@router.get(
    "/users",
    summary="用户 / 设备列表",
    description="账号标识、首次接入、最后同步、记录数、设备列表（按 device_id 去重 + 各设备最后同步时间）。",
    response_model=OkEnvelope[AdminUsersData],
    responses=_ERROR_RESPONSES,
)
def users(
    request: Request,
    principal: AdminPrincipal,
    db: DbSession,
    web: WebSettings,
    page: int = 1,
    pageSize: int = 0,
) -> Any:
    page, size, _ = normalize_paging(page, pageSize, default=web.page_size_default, maximum=web.page_size_max)
    data = stats.users(db, page=page, page_size=size)
    if wants_html(request):
        return pages.render_users(request, web=web, data=data)
    return OkEnvelope[AdminUsersData](data=AdminUsersData(**data))


@router.get(
    "/overview",
    summary="数据总览",
    description="接入设备数、总记录数、今日新增、总减排量、总积分发放（+ 商品/订单/目录版本）。",
    response_model=OkEnvelope[OverviewData],
    responses=_ERROR_RESPONSES,
)
def overview(request: Request, principal: AdminPrincipal, db: DbSession, web: WebSettings) -> Any:
    data = stats.overview(db)
    if wants_html(request):
        return pages.render_overview(request, web=web, db=db, data=data)
    return OkEnvelope[OverviewData](data=OverviewData(**data))


@router.get(
    "/orders",
    summary="订单记录",
    description="谁、什么时候、买了什么、花了多少分（成交价不随后台改价变化），按时间倒序分页。",
    response_model=OkEnvelope[AdminOrdersData],
    responses=_ERROR_RESPONSES,
)
def orders(
    request: Request,
    principal: AdminPrincipal,
    db: DbSession,
    web: WebSettings,
    page: int = 1,
    pageSize: int = 0,
) -> Any:
    page, size, _ = normalize_paging(page, pageSize, default=web.page_size_default, maximum=web.page_size_max)
    data = stats.orders(db, page=page, page_size=size)
    if wants_html(request):
        return pages.render_orders(request, web=web, data=data)
    return OkEnvelope[AdminOrdersData](data=AdminOrdersData(**data))


# --------------------------------------------------------------------------- #
# ⑥ 系统配置
# --------------------------------------------------------------------------- #
@router.get(
    "/config",
    summary="系统配置",
    description="目标奖励分值（goal_def）、每日封顶值、徽章开关（app_config）。",
    response_model=OkEnvelope[SystemConfigData],
    responses=_ERROR_RESPONSES,
)
def config(request: Request, principal: AdminPrincipal, db: DbSession, web: WebSettings) -> Any:
    data = system_config.get_config(db)
    if wants_html(request):
        return pages.render_config(request, web=web, data=data)
    return OkEnvelope[SystemConfigData](data=SystemConfigData(**data))


@router.put(
    "/config",
    summary="修改系统配置",
    description="只改传了的项；改动写 `update_config` 审计（含改前 / 改后）。",
    response_model=OkEnvelope[SystemConfigUpdateData],
    responses=_ERROR_RESPONSES,
)
def update_config(
    request: Request,
    payload: SystemConfigUpdate,
    principal: AdminPrincipal,
    db: DbSession,
) -> OkEnvelope[SystemConfigUpdateData]:
    data = system_config.update_config(db, payload, admin_id=principal.subject, ip=client_ip(request))
    return OkEnvelope[SystemConfigUpdateData](data=SystemConfigUpdateData(**data))


# --------------------------------------------------------------------------- #
# ⑦ 操作日志
# --------------------------------------------------------------------------- #
@router.get(
    "/logs",
    summary="操作日志",
    description="谁改了价格、什么时候改的；按时间倒序分页，`detail` 带改前 / 改后。",
    response_model=OkEnvelope[AdminLogsData],
    responses=_ERROR_RESPONSES,
)
def logs(
    request: Request,
    principal: AdminPrincipal,
    db: DbSession,
    web: WebSettings,
    page: int = 1,
    pageSize: int = 0,
    action: str = "",
) -> Any:
    page, size, _ = normalize_paging(page, pageSize, default=web.page_size_default, maximum=web.page_size_max)
    data = audit.list_logs(db, page=page, page_size=size, action=action or None)
    if wants_html(request):
        return pages.render_logs(request, web=web, data=data, action=action)
    return OkEnvelope[AdminLogsData](data=AdminLogsData(**data))


# --------------------------------------------------------------------------- #
# 登录页/总览页：`/admin` 与 `/admin/` 都指向总览页
# --------------------------------------------------------------------------- #
@router.get("", include_in_schema=False)
@router.get("/", include_in_schema=False)
def dashboard(request: Request, principal: AdminPrincipal, db: DbSession, web: WebSettings) -> Any:
    """`/admin` = 后台主页（数据总览）。

    未登录（无/非法管理端令牌）→ `require_admin` 抛 `LoginRequired` → 303 跳 `/admin/login?next=/admin`。
    """
    return pages.render_overview(request, web=web, db=db, data=stats.overview(db))


@router.get("/password", include_in_schema=False)
def password_page(request: Request, principal: AdminPrincipal, web: WebSettings) -> Response:
    """`GET /admin/password` = 改密码页（`POST /admin/password` 见上）。"""
    return pages.render_password(request, web=web)


__all__ = ["STATIC_WHITELIST", "router"]
