"""CarbonBoo 服务端应用包。

切片：S6 服务端地基（t3）—— 账号体系 + 鉴权隔离的最低可用切片。
依据：docs/adr/0001-account-and-sync.md（服务端必做）、docs/APPENDIX-B-data-and-api.md §5.2、AGENTS.md §6/§7.2。
"""

from app.core.config import VERSION as __version__

__all__ = ["__version__"]
