"""② 传图标：图片字节的校验、落盘与寻址（文件系统，不落库）。

设计要点
--------
* **不引入 `python-multipart`**：后台是可选件，为它给服务端加一个运行时依赖不划算。
  上传走两条等价形态，最终都汇到 `save_icon()`：
  1. `Content-Type: image/*` + 原始字节（curl / 脚本）；
  2. `application/json` + `{"filename": ..., "dataBase64": ...}`（浏览器表单，见 `static/admin.js`）。
* **不信任客户端声明的类型**：按魔术字节嗅探（`config.ICON_MAGIC`），只接受 png / jpeg / webp。
  刻意不支持 SVG（可内嵌脚本）——后台不需要矢量图标。
* **文件名由内容决定**：`<item_id>-<sha1(内容)[:10]><ext>`。同一张图重复上传 = 覆盖同一个文件，
  上传目录不会长草；也天然挡住 `../` 之类的路径穿越（名字不由用户输入决定）。
* **目录**：`ADMIN_UPLOAD_DIR`（默认 `server/admin_web/static/uploads/icons/`），
  该目录下的 `.gitignore` 让上传物不进仓库（AGENTS §7.3 禁止提交运行期产物）。
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import logging
import os
from pathlib import Path

from app.core.errors import AppError, ErrorCode

from admin_web.config import ALLOWED_ICON_TYPES, ICON_MAGIC

logger = logging.getLogger("carbonboo.admin.icons")


def sniff_image_type(raw: bytes) -> str | None:
    """按魔术字节判断图片类型；不认识返回 None（不猜）。"""
    for magic, mime in ICON_MAGIC:
        if raw.startswith(magic):
            if mime == "image/webp" and raw[8:12] != b"WEBP":
                return None
            return mime
    return None


def decode_base64_payload(data: str) -> bytes:
    """解码 base64（允许 `data:image/png;base64,` 前缀）；非法 → 400 `INVALID_REQUEST`。"""
    payload = data.strip()
    if payload.startswith("data:"):
        _, _, payload = payload.partition(",")
    try:
        return base64.b64decode(payload, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise AppError(ErrorCode.INVALID_REQUEST, "图标数据不是合法的 base64") from exc


def save_icon(
    raw: bytes,
    *,
    item_id: str,
    upload_dir: Path,
    url_prefix: str,
    max_bytes: int,
) -> tuple[str, str]:
    """校验并落盘，返回 `(可访问路径, 文件名)`。

    失败一律 400 `INVALID_REQUEST`（附录 B §5.2 错误码表；后台不新造错误码）。
    """
    if not raw:
        raise AppError(ErrorCode.INVALID_REQUEST, "图标内容为空")
    if len(raw) > max_bytes:
        raise AppError(
            ErrorCode.INVALID_REQUEST,
            f"图标过大：{len(raw)} 字节 > 上限 {max_bytes} 字节（ADMIN_MAX_ICON_BYTES 可调）",
        )
    mime = sniff_image_type(raw)
    if mime is None:
        raise AppError(ErrorCode.INVALID_REQUEST, "只接受 PNG / JPEG / WebP 图片（按文件内容识别，不看扩展名）")
    # 后缀表与 config.ALLOWED_ICON_TYPES 同源（一处定义，见 config.py）
    extension = ALLOWED_ICON_TYPES[mime]

    digest = hashlib.sha1(raw).hexdigest()[:10]  # noqa: S324 - 去重标识，非安全用途
    filename = f"{item_id}-{digest}{extension}"

    target_dir = Path(upload_dir)
    target_dir.mkdir(parents=True, exist_ok=True)
    path = resolve_upload_path(target_dir, filename)
    tmp_path = path.with_suffix(path.suffix + ".part")
    tmp_path.write_bytes(raw)
    os.replace(tmp_path, path)  # 原子替换：并发/中断都不会留下半个文件
    logger.info("图标已落盘 %s（%s，%d 字节）", path.name, mime, len(raw))
    return f"{url_prefix.rstrip('/')}/{filename}", filename


def resolve_upload_path(upload_dir: Path, filename: str) -> Path:
    """把文件名解析到上传目录内（**只接受纯文件名**；任何路径成分一律拒绝）。"""
    if not filename or "/" in filename or "\\" in filename or filename.startswith("."):
        raise AppError(ErrorCode.NOT_FOUND, "图标文件名非法")
    base = Path(upload_dir).resolve()
    candidate = (base / filename).resolve()
    if base not in candidate.parents:
        raise AppError(ErrorCode.NOT_FOUND, "图标文件名非法")
    return candidate


def icon_filename_from_url(icon_url: str, controller_prefix: str) -> str | None:
    """从 `shop_item.icon` 反解出文件名（仅当它是本后台上传的图标时）。"""
    prefix = f"{controller_prefix.rstrip('/')}/"
    if not icon_url.startswith(prefix):
        return None
    return icon_url[len(prefix) :] or None


__all__ = [
    "decode_base64_payload",
    "icon_filename_from_url",
    "resolve_upload_path",
    "save_icon",
    "sniff_image_type",
]
