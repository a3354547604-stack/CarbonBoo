"""同步与云端备份的请求/响应模型（对齐 docs/APPENDIX-B-data-and-api.md §5.3）。

字段名**直接采用附录 B 的 JSON 键名**（camelCase），不引入 alias 映射（少一层翻译就少一处口径分叉）。

与附录 B §5.3 的两处有意补充（都在 server/README.md 里写明，并列入「附录 B 需同步修正的行」）：
1. `clientNow`（可选）：附录 B §6.4-6 要求「握手时测得 `offsetMs = 本机时钟 − 对端时钟`」，
   但 §5.3 的 push 请求体示例里没有任何时钟字段，服务端无从测得偏移 —— 故接收一个**可选**的
   `clientNow`（客户端当前时钟毫秒）。缺失时按「无偏移」处理（不做时钟校正），而不是猜一个值。
2. `ignored` 与 `skipped`：§5.3 的响应示例给的是 `skipped`，§6.4-3 的散文要求「被忽略的行计入 `ignored`」。
   两者是**同一个计数器**（id / 业务唯一键去重被丢弃的行数），两个名字都给，避免下游各按一种名字对接。
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class _BodyModel(BaseModel):
    """请求体基类：忽略未知字段（客户端可能带上本地上下文字段，例如 `sync_state`）。"""

    model_config = ConfigDict(extra="ignore")


# --------------------------------------------------------------------------- #
# 同步（§5.3 pull / push / status）
# --------------------------------------------------------------------------- #
class SyncPushRequest(_BodyModel):
    """POST /api/v1/sync/push 请求体（附录 B §5.3）。"""

    userId: str | None = Field(default=None, description="云数据归属键；必须与令牌账号一致，否则整批 403")
    deviceId: str | None = Field(default=None, description="推送方设备标识（行内缺 device_id 时据此补齐）")
    lastSyncAt: int = Field(default=0, description="该设备上次成功同步的时间（毫秒）；用于区分「真冲突」与普通覆盖")
    clientNow: int | None = Field(
        default=None,
        description="客户端当前时钟（毫秒，可选）。用于测 offsetMs = 服务端时钟 − 客户端时钟；±5 分钟容差",
    )
    tables: dict[str, list[dict[str, Any]]] = Field(
        default_factory=dict,
        description="表名 → 行数组；只接受参与同步的 9 张表（附录 B §6.5），出现其它表名整批 400",
    )


class SyncPushData(BaseModel):
    """POST /api/v1/sync/push 的业务数据（逐字对齐附录 B §5.3 的响应示例，另补 ignored/rejected/errors）。"""

    accepted: int = Field(description="写入成功（新增或按 LWW 覆盖）的行数")
    skipped: int = Field(description="未被采纳的行数 = ignored + rejected（附录 B §5.3 的字段名）")
    ignored: int = Field(description="跨设备重复已去重（id 或业务唯一键命中已有行）的行数（附录 B §6.4-3 的字段名）")
    rejected: int = Field(description="未采纳且保留服务端版本的行数（已随 merged 回写；含非法行/越权行）")
    conflicts: int = Field(description="真冲突数 = 两端自上次同步后都改过这一行")
    serverTime: int = Field(description="服务端当前时间（毫秒）")
    offsetMs: int = Field(description="服务端时钟 − 客户端时钟（客户端未提供 clientNow 时为 0，表示未校正）")
    clockWarning: str | None = Field(default=None, description="时钟偏移超容差时的提示（超容差仍继续合并）")
    acceptedByTable: dict[str, int] = Field(default_factory=dict, description="每张表采纳的行数")
    merged: dict[str, list[dict[str, Any]]] = Field(
        default_factory=dict, description="服务端版本更胜、需要客户端回写的行（按表分组）"
    )
    errors: list[str] = Field(default_factory=list, description="逐行问题说明（去重/非法/越权），最多保留 50 条")


class SyncPullData(BaseModel):
    """GET /api/v1/sync/pull 的业务数据。"""

    serverTime: int = Field(description="服务端当前时间（毫秒）")
    since: int = Field(description="回显请求的增量起点（毫秒）")
    tables: dict[str, list[dict[str, Any]]] = Field(description="表名 → 增量行（updated_at > since，含软删除行）")


class SyncTableStat(BaseModel):
    """单张同步表的云端统计。"""

    name: str = Field(description="表名")
    count: int = Field(description="云端行数（含软删除行）")
    deletedCount: int = Field(description="其中 is_deleted = 1 的行数")
    lastUpdatedAt: int = Field(description="该表 updated_at 最大值（无行时为 0）")


class SyncLogInfo(BaseModel):
    """最近一次同步日志（附录 B §2 的 sync_log 表；服务端侧记录）。"""

    direction: str = Field(description="push | pull | both")
    status: str = Field(description="success | partial | failed")
    pushedCount: int = Field(description="上行行数")
    pulledCount: int = Field(description="下行行数")
    conflictCount: int = Field(description="冲突数")
    errorMsg: str | None = Field(default=None, description="错误/告警说明（含时钟超容差记录）")
    startedAt: int = Field(description="开始时间（毫秒）")
    finishedAt: int | None = Field(default=None, description="结束时间（毫秒）")


class SyncStatusData(BaseModel):
    """GET /api/v1/sync/status 的业务数据（云端统计：各表条数、最后时间）。"""

    userId: str = Field(description="云数据归属键")
    serverTime: int = Field(description="服务端当前时间（毫秒）")
    totalRows: int = Field(description="9 张同步表的云端行数合计")
    tables: list[SyncTableStat] = Field(description="逐表统计（顺序固定为附录 B §6.5 的表序）")
    devices: list[str] = Field(description="该账号数据里出现过的 device_id（去重、升序；家庭合并视图用）")
    lastSync: SyncLogInfo | None = Field(default=None, description="最近一次同步日志（从未同步时为 null）")


# --------------------------------------------------------------------------- #
# 云端备份 / 恢复（§5.3 标题行「云端备份 / 恢复」；附录 B 未给出端点行，见 README 的待修正清单）
# --------------------------------------------------------------------------- #
class SnapshotRequest(_BodyModel):
    """云端备份 / 恢复的请求体：一份全量快照（9 张表的行数组）。"""

    userId: str | None = Field(default=None, description="云数据归属键；必须与令牌账号一致")
    deviceId: str | None = Field(default=None, description="发起方设备标识（仅记日志）")
    tables: dict[str, list[dict[str, Any]]] = Field(
        default_factory=dict, description="表名 → 行数组（全量快照，允许含软删除行）"
    )


class BackupUploadData(BaseModel):
    """POST /api/v1/sync/backup：只存快照，不做自动合并。"""

    stored: int = Field(description="写入快照的行数（新增 + 按 id 覆盖）")
    ignored: int = Field(description="已有同 id 行且内容无需改变、被忽略的行数")
    rejected: int = Field(description="非法行 / 越权行数")
    snapshotAt: int = Field(description="快照落库时间（毫秒）")
    serverTime: int = Field(description="服务端当前时间（毫秒）")
    tables: dict[str, int] = Field(default_factory=dict, description="每表写入行数")
    errors: list[str] = Field(default_factory=list, description="逐行问题说明（最多 50 条）")


class BackupDownloadData(BaseModel):
    """GET /api/v1/sync/backup：下载云端快照（恢复即覆盖的数据源）。"""

    serverTime: int = Field(description="服务端当前时间（毫秒）")
    snapshotAt: int = Field(description="云端快照时间 = 9 张表 updated_at 的最大值（无数据时为 0）")
    totalRows: int = Field(description="快照行数合计")
    tables: dict[str, list[dict[str, Any]]] = Field(description="表名 → 全量行（含软删除行）")


class BackupRestoreData(BaseModel):
    """POST /api/v1/sync/backup/restore：恢复即覆盖 + 恢复前生成快照。"""

    restored: int = Field(description="按快照写入/覆盖的云端行数")
    removed: int = Field(description="快照里不存在、已从云端移除的行数")
    preRestoreAt: int = Field(description="恢复前快照的生成时间（毫秒）")
    preRestore: dict[str, list[dict[str, Any]]] = Field(
        description="恢复前生成的云端快照（覆盖前的原状，由调用方落盘保存；服务端不新建表）"
    )
    serverTime: int = Field(description="服务端当前时间（毫秒）")
    tables: dict[str, int] = Field(default_factory=dict, description="每表恢复行数")


__all__ = [
    "BackupDownloadData",
    "BackupRestoreData",
    "BackupUploadData",
    "SnapshotRequest",
    "SyncLogInfo",
    "SyncPullData",
    "SyncPushData",
    "SyncPushRequest",
    "SyncStatusData",
    "SyncTableStat",
]
