"""Web 后台管理端自有配置（`server/admin_web/` 的唯一配置入口）。

为什么还需要一个配置类（app/core/config.py 已经是"唯一配置入口"）
------------------------------------------------------------------
`app/core/config.py` 由服务端切片（t3/t5）持有，本切片**不改它**（写入范围互斥）。
但后台管理端有几项只属于它的可变量（首次管理员引导口令、图标上传目录与上限、分页尺寸、
会话 Cookie 名），把它们塞进 `Settings` 会越界。因此这里定义一个**独立**的 pydantic-settings 类：

* 环境变量前缀固定 `ADMIN_`（`model_config.env_prefix`），与 `Settings`（客户端 JWT）不重叠；
  唯一共用的是同一个 `server/.env` 文件（600）——密钥/口令只从那里或进程环境注入，**代码内无默认口令**。
* 与业务/JWT 相关的配置（管理端密钥、audience、过期时间、是否生产）**一律仍读 `app.core.config`**，
  这里不复述、不覆盖：钥匙只有一把，避免"两处都能配密钥"的分叉。

**本模块不得直接读 `os.environ`**（沿用 `app/core/config.py` 的口径）。
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

from app.core.config import ENV_FILE, SERVER_DIR

#: 本包目录（模板 / 静态资源 / 上传目录的相对基准）
ADMIN_WEB_DIR: Path = Path(__file__).resolve().parent
#: 上传图标落盘目录（不属于任何已冻结契约，是本可选件的自有存储）
DEFAULT_UPLOAD_DIR: Path = ADMIN_WEB_DIR / "static" / "uploads" / "icons"
#: Jinja2 模板目录（不放 `server/templates/`：那是服务端切片的写入范围）
TEMPLATES_DIR: Path = ADMIN_WEB_DIR / "templates"
#: 后台自有静态资源目录（仅 CSS / JS 两个白名单文件对外只读）
STATIC_DIR: Path = ADMIN_WEB_DIR / "static"

#: 允许上传的图标类型 → 落盘后缀。**不含 SVG**：SVG 可内嵌脚本，后台不做二次清洗。
ALLOWED_ICON_TYPES: dict[str, str] = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/webp": ".webp",
}

#: 图标内容嗅探用的魔术字节（不信任客户端声明的 Content-Type）
ICON_MAGIC: tuple[tuple[bytes, str], ...] = (
    (b"\x89PNG\r\n\x1a\n", "image/png"),
    (b"\xff\xd8\xff", "image/jpeg"),
    (b"RIFF", "image/webp"),  # 需再看 offset 8..12 == b"WEBP"
)


class AdminWebSettings(BaseSettings):
    """后台管理端配置（环境变量前缀 `ADMIN_`）。"""

    model_config = SettingsConfigDict(
        env_file=str(ENV_FILE),
        env_file_encoding="utf-8",
        env_prefix="ADMIN_",
        extra="ignore",
        case_sensitive=False,
    )

    # ---------- 首次管理员引导（可选） ----------
    #: 仅当 `admin_user` 表为空、且请求的用户名/口令与这两项一致时，才创建首个管理员。
    #: 表非空后该路径彻底失效（改密走 /admin/password，找回走 `python -m admin_web.cli create-admin --reset`）。
    bootstrap_username: str = ""
    bootstrap_password: str = ""

    # ---------- 图标上传 ----------
    upload_dir: Path = DEFAULT_UPLOAD_DIR
    max_icon_bytes: int = 512 * 1024
    #: 上传后的图标对外访问路径：`<icon_url_prefix>/<文件名>`
    icon_url_prefix: str = "/admin/icons"

    # ---------- 列表分页 ----------
    page_size_default: int = 20
    page_size_max: int = 200

    # ---------- 后台会话 Cookie ----------
    #: 浏览器页面（服务端渲染）用 HttpOnly Cookie 承载同一个管理端 JWT；
    #: 接口调用仍按附录 B §5.4 用 `Authorization: Bearer <adminToken>`。
    cookie_name: str = "carbonboo_admin_token"
    #: None = 按 APP_ENV 判定（生产置 Secure，TLS 由 nginx 终结）
    cookie_secure: bool | None = None
    #: 页面路由前缀（与 app/main.py 的 ADMIN_PATH_PREFIX 同值；那里是隔离中间件的判定口径）
    prefix: str = "/admin"

    @property
    def resolved_upload_dir(self) -> Path:
        """上传目录的绝对路径（相对路径按 `server/` 解析）。"""
        path = self.upload_dir
        return path if path.is_absolute() else (SERVER_DIR / path)

    @property
    def has_bootstrap_credentials(self) -> bool:
        return bool(self.bootstrap_username.strip() and self.bootstrap_password)


@lru_cache(maxsize=1)
def get_admin_settings() -> AdminWebSettings:
    """进程内单例（测试改环境变量后调用 `reset_admin_settings_cache()`）。"""
    return AdminWebSettings()


def reset_admin_settings_cache() -> None:
    """清空配置缓存（测试用）。"""
    get_admin_settings.cache_clear()


__all__ = [
    "ADMIN_WEB_DIR",
    "ALLOWED_ICON_TYPES",
    "DEFAULT_UPLOAD_DIR",
    "ICON_MAGIC",
    "STATIC_DIR",
    "TEMPLATES_DIR",
    "AdminWebSettings",
    "get_admin_settings",
    "reset_admin_settings_cache",
]
