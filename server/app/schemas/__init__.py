"""请求/响应 Pydantic 模型（schema 层）。

字段名**直接采用附录 B 里的 JSON 键名**（camelCase），保证 /docs 里显示的契约与文档逐字一致，
不引入 alias 映射（少一层翻译就少一处口径分叉）。

* `auth` → 附录 B §5.2（账号）
* `sync` → 附录 B §5.3（同步 pull / push / status + 云端备份 / 恢复）
* `shop` → 附录 B §5.4（商品取价）
* `common` → 统一信封 `{ok, data}` / `{ok, code, message}`
"""

from app.schemas.auth import (
    AuthData,
    DeleteAccountRequest,
    LoginRequest,
    LogoutData,
    MeData,
    PurgeData,
    RegisterRequest,
)
from app.schemas.common import ErrorEnvelope, OkEnvelope
from app.schemas.shop import ShopItemData, ShopItemsData
from app.schemas.sync import (
    BackupDownloadData,
    BackupRestoreData,
    BackupUploadData,
    SnapshotRequest,
    SyncLogInfo,
    SyncPullData,
    SyncPushData,
    SyncPushRequest,
    SyncStatusData,
    SyncTableStat,
)

__all__ = [
    "AuthData",
    "BackupDownloadData",
    "BackupRestoreData",
    "BackupUploadData",
    "DeleteAccountRequest",
    "ErrorEnvelope",
    "LoginRequest",
    "LogoutData",
    "MeData",
    "OkEnvelope",
    "PurgeData",
    "RegisterRequest",
    "ShopItemData",
    "ShopItemsData",
    "SnapshotRequest",
    "SyncLogInfo",
    "SyncPullData",
    "SyncPushData",
    "SyncPushRequest",
    "SyncStatusData",
    "SyncTableStat",
]
