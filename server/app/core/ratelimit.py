"""登录限流（AGENTS §6：`/admin` 需强口令 + 登录限流；客户端登录同样限流）。

实现：进程内滑动窗口计数器，键 = `<客户端IP>|<用户名>`，窗口 60 秒，
阈值 `LOGIN_RATE_LIMIT_PER_MINUTE`（0 = 关闭）。单进程内足够挡住暴力试口令；
多 worker 部署时为每个 worker 各自计数（上限 = 阈值 × worker 数），如需严格全局限流换 Redis（属 t5 同步切片）。

放在 core 而不是 provider 内：限流是 HTTP 面（需要客户端 IP）的关切，不应污染身份提供方实现。
"""

from __future__ import annotations

import threading
import time
from collections import defaultdict, deque

from app.core.config import get_settings

_WINDOW_SECONDS: float = 60.0
_hits: dict[str, deque[float]] = defaultdict(deque)
_lock = threading.Lock()


def hit_login_limit(key: str, *, now: float | None = None, limit: int | None = None) -> bool:
    """记一次登录尝试。返回 True = 允许，False = 超限（调用方应返回 429 RATE_LIMITED）。"""
    if limit is None:
        limit = get_settings().login_rate_limit_per_minute
    if limit <= 0:
        return True
    current = time.monotonic() if now is None else now
    with _lock:
        bucket = _hits[key]
        while bucket and current - bucket[0] > _WINDOW_SECONDS:
            bucket.popleft()
        if len(bucket) >= limit:
            return False
        bucket.append(current)
        return True


def reset_login_limit(key: str | None = None) -> None:
    """清空限流计数（测试用；key=None 清空全部）。"""
    with _lock:
        if key is None:
            _hits.clear()
        else:
            _hits.pop(key, None)


__all__ = ["hit_login_limit", "reset_login_limit"]
