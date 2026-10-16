"""服务端全局配置（唯一配置入口）。

职责
----
1. 把所有可变量（MySQL、JWT 密钥、账号策略）收敛到一个 `Settings`，任何模块**不得**直接读 `os.environ`。
2. 密钥只来自 `server/.env`（权限 600）或进程环境变量；**代码内不提供任何默认密钥**，缺失即启动失败。
3. 客户端 / 管理端两套独立 JWT 密钥（AGENTS §7.2），并在装载时就校验二者不相同。
4. 按 `--workers 2` 的口径收口 SQLAlchemy 连接池（pool_size=5, max_overflow=5，见 database.py）。

依据：docs/APPENDIX-B-data-and-api.md §5.2、docs/adr/0001-account-and-sync.md、AGENTS §6/§7.2。
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal
from urllib.parse import quote_plus

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

#: server/ 目录（配置与 SQL 的相对基准）
SERVER_DIR: Path = Path(__file__).resolve().parents[2]
#: 仓库根目录
REPO_ROOT: Path = SERVER_DIR.parent
#: 密钥文件（不进仓库，权限 600）
ENV_FILE: Path = SERVER_DIR / ".env"

#: 版本号（与因子库 CF-2026.2 同源；只有数值变化才升版本 —— APPENDIX-A §2.5 / B32）
#: ⚠ 这是**资料/产品版本号**；`/api/v1/health` 返回的是 API 版本号 `Settings.app_version`（默认 1.0.0，
#: 逐字对齐 APPENDIX-B §5.1 的响应示例），两者不要混用。
VERSION: str = "CF-2026.2"

#: 密钥最短长度：低于此长度直接拒绝启动
MIN_SECRET_LEN: int = 32

#: 已实现 / 预留的身份提供方（APPENDIX-B §7.1）
PROVIDER_IDS: tuple[str, ...] = ("local", "server", "huaweiId")


class Settings(BaseSettings):
    """全部运行期配置。环境变量名 = 字段名大写（大小写不敏感）。"""

    model_config = SettingsConfigDict(
        env_file=str(ENV_FILE),
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # ---------- 运行环境 ----------
    app_env: Literal["dev", "test", "prod"] = "dev"
    #: API 版本号：`GET /api/v1/health` 的 `version` 字段（APPENDIX-B §5.1 响应示例为 "1.0.0"）。
    #: 与资料版本号 VERSION(CF-2026.2) 是两件事 —— health 报 API 版本，不报资料版本。
    app_version: str = "1.0.0"
    app_host: str = "127.0.0.1"
    app_port: int = 8000
    api_prefix: str = "/api/v1"
    docs_url: str = "/docs"  # 置空字符串 = 无条件关闭 /docs 与 /openapi.json
    # None = 按环境取默认（非生产开、生产关）；True/False = 显式开关（路演前临时在 prod 打开）
    docs_enabled: bool | None = None

    # ---------- MySQL（只监听 127.0.0.1） ----------
    mysql_host: str = "127.0.0.1"
    mysql_port: int = 3306
    mysql_user: str = "carbonboo"
    mysql_password: str = ""
    mysql_db: str = "carbonboo"

    # ---------- SQLAlchemy 连接池（--workers 2 口径见 database.py） ----------
    db_pool_size: int = 5
    db_max_overflow: int = 5
    db_pool_recycle: int = 1800
    db_pool_timeout: int = 30
    db_echo: bool = False

    # ---------- 客户端（App）JWT ----------
    jwt_secret: str = ""
    jwt_algorithm: str = "HS256"
    jwt_issuer: str = "carbonboo-server"
    jwt_user_audience: str = "carbonboo-client"
    jwt_access_token_expires_minutes: int = 10080  # 7 天

    # ---------- 管理端（Web 后台）JWT：必须是另一把密钥 ----------
    admin_jwt_secret: str = ""
    # audience 与密钥一起构成两道隔离：只换密钥时，误配成同一把也不会让客户端令牌进 /admin
    jwt_admin_audience: str = "carbonboo-admin"
    admin_jwt_expires_minutes: int = 120

    # ---------- 账号策略 ----------
    auth_provider: str = "local"  # local | server | huaweiId（后两者预留未实现）
    account_purge_grace_days: int = 30  # 注销后软删除保留期（ADR-0001 决策 ③）
    login_rate_limit_per_minute: int = 10  # 0 = 关闭限流（仅测试用）
    # 账号格式边界逐字取自附录 B §5.2 错误码表：
    # USERNAME_INVALID「用户名不符合 4–20 位字母数字下划线」/ PASSWORD_INVALID「密码不符合 6–32 位」
    username_min_length: int = 4
    username_max_length: int = 20
    password_min_length: int = 6
    password_max_length: int = 32

    @field_validator("docs_enabled", mode="before")
    @classmethod
    def _blank_docs_enabled_means_auto(cls, value: object) -> object:
        """`.env` 里写 `DOCS_ENABLED=`（留空）等价于"未设置" → 按环境默认。

        理由：`.env` 常见写法是留空表示"用默认"，而 pydantic 对 `bool | None` 无法解析空串。
        """
        if isinstance(value, str) and not value.strip():
            return None
        return value

    @model_validator(mode="after")
    def _check_secrets(self) -> "Settings":
        for name, value in (("JWT_SECRET", self.jwt_secret), ("ADMIN_JWT_SECRET", self.admin_jwt_secret)):
            if not value or len(value) < MIN_SECRET_LEN:
                raise ValueError(
                    f"{name} 必须从环境变量 / server/.env（600）注入且长度 >= {MIN_SECRET_LEN}；"
                    f"见 server/.env.example（代码内不提供默认密钥）"
                )
        if self.jwt_secret == self.admin_jwt_secret:
            raise ValueError("JWT_SECRET 与 ADMIN_JWT_SECRET 必须不同：客户端与管理端是两套独立密钥（AGENTS §7.2）")
        if self.auth_provider not in PROVIDER_IDS:
            # 配置错误在启动时就报出来，不要等到某个请求 500
            raise ValueError(f"AUTH_PROVIDER={self.auth_provider!r} 不是已知提供方，可选：{list(PROVIDER_IDS)}")
        return self

    # ---------- 派生值 ----------
    @property
    def database_url(self) -> str:
        """SQLAlchemy 连接串（PyMySQL 驱动）。"""
        return (
            f"mysql+pymysql://{quote_plus(self.mysql_user)}:{quote_plus(self.mysql_password)}"
            f"@{self.mysql_host}:{self.mysql_port}/{self.mysql_db}?charset=utf8mb4"
        )

    @property
    def database_url_masked(self) -> str:
        """日志用：隐藏口令。"""
        return (
            f"mysql+pymysql://{self.mysql_user}:***"
            f"@{self.mysql_host}:{self.mysql_port}/{self.mysql_db}?charset=utf8mb4"
        )

    @property
    def effective_docs_url(self) -> str | None:
        """`/docs` 是否需要关闭（AGENTS §6：生产默认关闭，路演前临时开）。

        - `DOCS_URL` 为空 → 无条件关闭；
        - `DOCS_ENABLED` 未设（None）→ 非生产开、生产关；
        - `DOCS_ENABLED` 显式为 true/false → 以显式值为准（生产路演时可临时打开）。
        """
        if not self.docs_url:
            return None
        enabled = self.docs_enabled if self.docs_enabled is not None else not self.is_prod
        return self.docs_url if enabled else None

    @property
    def is_prod(self) -> bool:
        return self.app_env == "prod"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """进程内单例。测试若需改配置：先改环境变量，再 `get_settings.cache_clear()`。"""
    return Settings()


def reset_settings_cache() -> None:
    """清空配置缓存（供测试与 `uvicorn --reload` 使用）。"""
    get_settings.cache_clear()


__all__ = [
    "ENV_FILE",
    "Field",
    "MIN_SECRET_LEN",
    "PROVIDER_IDS",
    "REPO_ROOT",
    "SERVER_DIR",
    "Settings",
    "VERSION",
    "get_settings",
    "reset_settings_cache",
]
