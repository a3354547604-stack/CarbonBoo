"""服务层公共设施：事务边界、时间口径、分页。

只有三件事，且都只在这里定义一次：
1. `transaction(db)`：多表写入的事务边界（Service 层持有，页面/路由层不 commit）。
2. 时间口径：`now_ms()`（与客户端/服务端同一毫秒口径）与 `today_start_ms()`（"今日新增"的分日基准）。
   刻意用**服务端本地时区**的自然日，与附录 D「今日新增」的验收口径一致。
3. `normalize_paging(page, page_size)`：把 `page/pageSize` 收进合法区间，越界不报错而是夹紧
   （后台是给人用的，翻到第 999 页给空列表比 400 更友好）。
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime

from sqlalchemy.orm import Session

from app.core.security import now_ms

__all__ = ["MS_PER_DAY", "now_ms", "normalize_paging", "today_start_ms", "transaction"]

#: 一天的毫秒数
MS_PER_DAY: int = 86_400_000


@contextmanager
def transaction(db: Session) -> Iterator[Session]:
    """一个业务动作 = 一个事务。

    异常时回滚并原样抛出（由 `app/main.py` 的异常处理器翻成统一错误信封）；
    正常返回时提交。**审计日志与业务改动在同一事务里**——不会出现"改了价但没留痕"。
    """
    try:
        yield db
    except Exception:
        db.rollback()
        raise
    else:
        db.commit()


def today_start_ms() -> int:
    """服务端本地时区今天 00:00:00 的毫秒时间戳。"""
    local_now = datetime.now().astimezone()
    local_midnight = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    return int(local_midnight.timestamp() * 1000)


def normalize_paging(page: int, page_size: int, *, default: int, maximum: int) -> tuple[int, int, int]:
    """返回 `(page, page_size, offset)`：page ≥ 1、1 ≤ page_size ≤ maximum。"""
    safe_page = max(1, int(page or 1))
    safe_size = int(page_size or default)
    safe_size = min(max(1, safe_size), maximum)
    return safe_page, safe_size, (safe_page - 1) * safe_size
