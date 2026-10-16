"""数据库引擎与会话（SQLAlchemy 2.x 同步）。

连接池口径（AGENTS §7.2 / PLAN §4.3）
------------------------------------
`uvicorn --workers 2` 时若用 SQLAlchemy 默认的 `pool_size=5, max_overflow=10`：
    2 × (5 + 10) = 30 —— 正好打满 MySQL `max_connections=30`
因此**显式**收口为 `pool_size=5, max_overflow=5, pool_recycle=1800`：
    2 × (5 + 5) = 20 < 30，留出 10 个连接给管理端 / 运维 / mysqldump。
`pool_recycle=1800` 避免 MySQL 默认 `wait_timeout` 主动断连导致的 "MySQL server has gone away"。

引擎按需惰性创建（`get_engine()`），测试可以在导入后改环境变量再 `reset_engine()`。
"""

from __future__ import annotations

import logging
from collections.abc import Iterator

from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import Settings, get_settings

logger = logging.getLogger("carbonboo.server.db")


def build_engine(settings: Settings | None = None) -> Engine:
    """按配置创建引擎（连接池参数显式写死，见模块头注释）。"""
    settings = settings or get_settings()
    engine = create_engine(
        settings.database_url,
        pool_pre_ping=True,  # 取连接前探活，配合 pool_recycle 抗 wait_timeout
        pool_size=settings.db_pool_size,
        max_overflow=settings.db_max_overflow,
        pool_recycle=settings.db_pool_recycle,
        pool_timeout=settings.db_pool_timeout,
        echo=settings.db_echo,
        future=True,
    )
    logger.info(
        "SQLAlchemy 引擎就绪 dsn=%s pool_size=%d max_overflow=%d pool_recycle=%d "
        "（--workers 2 时 2×(%d+%d)=%d 连接，MySQL max_connections=30）",
        settings.database_url_masked,
        settings.db_pool_size,
        settings.db_max_overflow,
        settings.db_pool_recycle,
        settings.db_pool_size,
        settings.db_max_overflow,
        2 * (settings.db_pool_size + settings.db_max_overflow),
    )
    return engine


_engine: Engine | None = None
_sessionmaker: sessionmaker[Session] | None = None


def get_engine() -> Engine:
    """进程内单例引擎。"""
    global _engine
    if _engine is None:
        _engine = build_engine()
    return _engine


def get_sessionmaker() -> sessionmaker[Session]:
    """进程内单例 Session 工厂。

    `expire_on_commit=False`：commit 后仍可安全读取已加载属性（服务层返回值需要）。
    """
    global _sessionmaker
    if _sessionmaker is None:
        _sessionmaker = sessionmaker(
            bind=get_engine(),
            autoflush=False,
            autocommit=False,
            expire_on_commit=False,
            class_=Session,
        )
    return _sessionmaker


def get_db() -> Iterator[Session]:
    """FastAPI 依赖：每个请求一个 Session，异常回滚，结束关闭。"""
    session = get_sessionmaker()()
    try:
        yield session
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def reset_engine() -> None:
    """丢弃单例引擎与 Session 工厂（测试 / 配置变更后调用）。"""
    global _engine, _sessionmaker
    if _engine is not None:
        _engine.dispose()
    _engine = None
    _sessionmaker = None


__all__ = [
    "build_engine",
    "get_db",
    "get_engine",
    "get_sessionmaker",
    "reset_engine",
]
