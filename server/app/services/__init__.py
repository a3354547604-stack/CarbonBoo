"""服务层包。

本切片（t3）只含 `app.services.auth_provider`；同步 / 取价 / 备份各自属 t5 切片，届时按同一分层新增。

⚠ 这里**故意不做 re-export**（`from app.services.auth_provider import ...` 直接引子模块）：
   运维入口 `python -m app.services.auth_provider` 要求运行 `auth_provider` 作为 `__main__`，
   若本 `__init__.py` 提前 import 它，runpy 会报 "found in sys.modules prior to execution" 警告，
   并让同一模块存在两份实例（`__main__` 与 `app.services.auth_provider`）。
"""
