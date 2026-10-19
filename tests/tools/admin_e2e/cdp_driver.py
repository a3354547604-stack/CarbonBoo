#!/usr/bin/env python3
"""CarbonBoo `/admin` 浏览器级端到端驱动（Edge headless + CDP over WebSocket）。

为什么这个脚本跑在 **Windows** python 上
--------------------------------------
本机 WSL 是 NAT 模式：**WSL → Windows 的入站连接被挡**（实测 `curl http://<win-ip>:9333/json/version`
超时 6 s，exit 28），而 Edge 的 DevTools 端口在 Windows 侧只监听 `127.0.0.1`（`--remote-debugging-address`
是 Linux-only 开关，Windows 上无效；启动日志仍是 `DevTools listening on ws://127.0.0.1:9333/...`）。
反向 **Windows → WSL 的 localhost 转发是通的**（实测 Windows python 打 WSL `127.0.0.1:8055` 得 200），
所以「Edge 在 Windows 里访问 WSL 里的 uvicorn」可行，而「WSL 侧驱动 Edge 的 CDP」不可行。
⇒ 驱动必须与 Edge 同侧（Windows）；Windows python 没有 `websockets`/`httpx`，
故这里用 **纯标准库** 实现 RFC6455 客户端 + `urllib`，截图像素校验用 Windows python 自带的 Pillow。

依赖：Windows python 3.12+（`socket`/`struct`/`select`/`urllib` 标准库）、Pillow。
      **不安装任何新包**；只写 `artifacts_dir` 下的截图与 `report.json`。

用法（由 `run.sh` 调用）：
    python.exe cdp_driver.py <config.json>

退出码：0 = 全部断言通过；1 = 有断言失败；2 = 环境不可达（CDP / 服务端连不上）。
"""

from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import select
import socket
import struct
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

from PIL import Image

# Windows 控制台默认 cp936：不显式改成 UTF-8，中文在 WSL 终端里会是乱码
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

#: 品牌主色（`docs/APPENDIX-C-ui-screens.md` §3.1 → `admin_web/static/admin.css` `--primary`）
BRAND = (46, 125, 91)


class EnvUnreachable(Exception):
    """CDP 或服务端连不上 → 退出码 2（如实记「未运行」，不得降级冒充）。"""


class CheckFailed(Exception):
    """断言失败 → 退出码 1。"""


# --------------------------------------------------------------------------- #
# 极简 WebSocket 客户端（RFC6455：客户端掩码 + 文本帧 + 分片 + ping/pong）
# --------------------------------------------------------------------------- #
class WebSocket:
    def __init__(self, url: str, timeout: float = 45.0) -> None:
        if not url.startswith("ws://"):
            raise EnvUnreachable(f"只支持 ws:// ：{url}")
        rest = url[len("ws://") :]
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        self.host = host
        self.port = int(port or 80)
        self.path = "/" + path
        self.timeout = timeout
        self.sock: socket.socket | None = None
        self._buf = b""

    def connect(self) -> None:
        try:
            self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        except OSError as exc:
            raise EnvUnreachable(f"连不上 CDP {self.host}:{self.port} —— {exc}") from exc
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode())
        header = b""
        while b"\r\n\r\n" not in header:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise EnvUnreachable("WebSocket 握手时连接被关闭")
            header += chunk
        head, _, remainder = header.partition(b"\r\n\r\n")
        self._buf = remainder
        status_line = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if " 101" not in status_line:
            raise EnvUnreachable(f"WebSocket 握手未返回 101：{status_line}")
        self.sock.settimeout(self.timeout)

    def readable(self, timeout: float) -> bool:
        """缓冲里还有整帧、或 socket 在 timeout 内可读 → True（不消费数据）。"""
        if self._buf:
            return True
        ready, _, _ = select.select([self.sock], [], [], max(0.0, timeout))  # type: ignore[list-item]
        return bool(ready)

    def _read_exact(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = self.sock.recv(262144)  # type: ignore[union-attr]
            if not chunk:
                raise EnvUnreachable("CDP 连接被对端关闭")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def _frame(self, opcode: int, payload: bytes) -> bytes:
        header = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
        return bytes(header) + masked

    def send_text(self, text: str) -> None:
        self.sock.sendall(self._frame(0x1, text.encode()))  # type: ignore[union-attr]

    def recv_message(self) -> str:
        """读一条完整消息（自动拼接分片、回 pong）；调用方需先用 readable() 确认有数据。"""
        data = bytearray()
        while True:
            b0, b1 = self._read_exact(2)
            fin = b0 & 0x80
            opcode = b0 & 0x0F
            masked = b1 & 0x80
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else None
            payload = self._read_exact(length) if length else b""
            if mask:
                payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
            if opcode == 0x8:
                raise EnvUnreachable("服务端发来 Close 帧")
            if opcode == 0x9:
                self.sock.sendall(self._frame(0xA, payload))  # type: ignore[union-attr]
                continue
            if opcode == 0xA:
                continue
            data += payload
            if fin:
                return bytes(data).decode("utf-8", errors="replace")

    def close(self) -> None:
        try:
            if self.sock is not None:
                self.sock.close()
        except OSError:
            pass


# --------------------------------------------------------------------------- #
# CDP 会话
# --------------------------------------------------------------------------- #
class Cdp:
    def __init__(self, ws_url: str) -> None:
        self.ws = WebSocket(ws_url)
        self.ws.connect()
        self._next_id = 0
        self.events: list[dict] = []
        self._methods: dict[str, str] = {}
        # pump() 期间可能先收到带 id 的响应帧：必须缓存，否则 call() 永远等不到 → 假超时
        self._pending: dict[int, dict] = {}
        self._redirects: list[dict] = []
        self.dialogs: list[dict] = []

    def call(self, method: str, params: dict | None = None, timeout: float = 60.0) -> dict:
        self._next_id += 1
        message_id = self._next_id
        self.ws.send_text(json.dumps({"id": message_id, "method": method, "params": params or {}}))
        cached = self._pending.pop(message_id, None)
        if cached is not None:
            if "error" in cached:
                raise CheckFailed(f"CDP {method} 报错：{cached['error']}")
            return cached.get("result", {})
        deadline = time.time() + timeout
        while time.time() < deadline:
            if not self.ws.readable(max(0.0, deadline - time.time())):
                raise EnvUnreachable(f"CDP {method} 超时（{timeout}s）")
            msg = json.loads(self.ws.recv_message())
            if msg.get("id") == message_id:
                if "error" in msg:
                    raise CheckFailed(f"CDP {method} 报错：{msg['error']}")
                return msg.get("result", {})
            if "id" in msg:
                self._pending[int(msg["id"])] = msg
            elif "method" in msg:
                self._remember(msg)
        raise EnvUnreachable(f"CDP {method} 超时（{timeout}s）")

    def _dismiss_dialog(self, params: dict) -> None:
        """原生 alert 会阻塞渲染进程（Runtime.evaluate 永不返回）——收到就记下并放行。"""
        self.dialogs.append({"type": params.get("type"), "message": params.get("message")})
        self._next_id += 1
        self.ws.send_text(json.dumps({
            "id": self._next_id, "method": "Page.handleJavaScriptDialog", "params": {"accept": True},
        }))

    def _remember(self, msg: dict) -> None:
        if msg.get("method") == "Page.javascriptDialogOpening":
            self._dismiss_dialog(msg.get("params", {}))
        if msg.get("method") == "Network.requestWillBeSent":
            params = msg.get("params", {})
            request = params.get("request", {})
            self._methods[params.get("requestId", "")] = request.get("method", "")
            # 302/303 这类重定向在 CDP 里不会单独发 responseReceived：
            # 它挂在「重定向后那个请求」的 requestWillBeSent.redirectResponse 上。必须单独收，
            # 否则「未登录访问 /admin/users → 303」这条断言永远看不到 303（假失败）。
            # 注意：redirectResponse 是 params 的兄弟字段，不在 params.request 里面
            redirect = params.get("redirectResponse")
            if isinstance(redirect, dict):
                self._redirects.append({
                    "url": redirect.get("url", ""),
                    "status": int(redirect.get("status", 0)),
                    "method": request.get("method", ""),
                })
        self.events.append(msg)

    def drain(self) -> None:
        self.events = []
        self._redirects = []
        self.dialogs = []

    def pump(self, seconds: float) -> None:
        """在 seconds 内尽量多收事件（不阻塞等待）。"""
        deadline = time.time() + seconds
        while True:
            remaining = deadline - time.time()
            if remaining <= 0 or not self.ws.readable(remaining):
                return
            msg = json.loads(self.ws.recv_message())
            if "id" in msg:
                self._pending[int(msg["id"])] = msg
            elif "method" in msg:
                self._remember(msg)

    def responses(self) -> list[dict]:
        """本轮收集到的 HTTP 响应（url / status / method），含重定向那一跳。"""
        out = list(self._redirects)
        for msg in self.events:
            if msg.get("method") != "Network.responseReceived":
                continue
            params = msg.get("params", {})
            response = params.get("response", {})
            out.append(
                {
                    "url": response.get("url", ""),
                    "status": int(response.get("status", 0)),
                    "method": self._methods.get(params.get("requestId", ""), ""),
                }
            )
        return out


# --------------------------------------------------------------------------- #
# HTTP 小工具（不跟随重定向，用来如实看 303 / 403）
# --------------------------------------------------------------------------- #
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def http(method: str, url: str, payload: object = None, headers: dict | None = None,
         raw: bytes | None = None, timeout: float = 20.0) -> tuple[int, dict, bytes]:
    """返回 (status, headers, body)；3xx 不跟随，作为状态如实返回。"""
    request = urllib.request.Request(url, data=raw, method=method)
    if payload is not None:
        request.data = json.dumps(payload).encode()
        request.add_header("Content-Type", "application/json")
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    # 头部统一小写存放：HTTP 头名大小写不敏感，但 dict() 会保留服务端原始大小写，
    # 直接 .get('Location') 可能取不到（实测 FastAPI 发的是小写 location）。
    def _lower(headers_map: object) -> dict:
        return {str(k).lower(): str(v) for k, v in headers_map.items()}  # type: ignore[attr-defined]

    try:
        with _OPENER.open(request, timeout=timeout) as response:
            return int(response.status), _lower(response.headers), response.read()
    except urllib.error.HTTPError as exc:
        return int(exc.code), _lower(exc.headers), exc.read()


# --------------------------------------------------------------------------- #
# 断言与截图报告
# --------------------------------------------------------------------------- #
class Report:
    def __init__(self, artifacts_dir: str) -> None:
        self.dir = artifacts_dir
        self.items: list[dict] = []
        self.shots: dict[str, str] = {}
        self.shots_by_name: dict[str, dict] = {}
        self.failed = 0

    def check(self, name: str, ok: bool, detail: str) -> bool:
        self.items.append({"step": name, "ok": bool(ok), "detail": detail})
        print(("  [PASS] " if ok else "  [FAIL] ") + f"{name}: {detail}", flush=True)
        if not ok:
            self.failed += 1
        return ok

    def info(self, text: str) -> None:
        self.items.append({"step": "info", "ok": True, "detail": text})
        print(f"  [INFO] {text}", flush=True)

    def shot(self, name: str, data: bytes, *, min_nonwhite: float = 0.004,
             min_colors: int = 16, green_min: int = 0, viewport: tuple[int, int],
             dup_ok: bool = False) -> dict:
        path = os.path.join(self.dir, f"{name}.png")
        with open(path, "wb") as handle:
            handle.write(data)
        image = Image.open(io.BytesIO(data)).convert("RGB")
        width, height = image.size
        colors = image.getcolors(maxcolors=1 << 24) or []
        total = width * height
        nonwhite = sum(count for count, color in colors
                       if not (color[0] >= 250 and color[1] >= 250 and color[2] >= 250))
        green = sum(count for count, color in colors
                    if abs(color[0] - BRAND[0]) <= 14 and abs(color[1] - BRAND[1]) <= 14
                    and abs(color[2] - BRAND[2]) <= 14)
        md5 = hashlib.md5(data).hexdigest()
        duplicate = self.shots.get(md5)
        self.shots[md5] = name
        ratio = round(nonwhite / total, 4)
        stats = {
            "file": os.path.basename(path), "size": [width, height], "bytes": len(data),
            "md5": md5, "nonwhite_ratio": ratio, "unique_colors": len(colors), "brand_pixels": green,
        }
        self.check(f"{name} 截图尺寸 == {viewport[0]}x{viewport[1]}",
                   (width, height) == viewport, f"实测 {width}x{height}，{len(data)} 字节")
        self.check(f"{name} 非空白像素比例 ≥ {min_nonwhite}", ratio >= min_nonwhite,
                   f"nonwhite_ratio={ratio}")
        self.check(f"{name} 颜色数 ≥ {min_colors}", len(colors) >= min_colors,
                   f"unique_colors={len(colors)}")
        if green_min:
            self.check(f"{name} 品牌主色 #2E7D5B 像素 ≥ {green_min}", green >= green_min,
                       f"brand_pixels={green}")
        if not dup_ok:
            self.check(f"{name} 不是别页截图的副本", duplicate is None,
                       f"md5={md5[:12]}…" + (f"，与 {duplicate} 相同！" if duplicate else "（首见）"))
        elif duplicate:
            self.info(f"{name} 与 {duplicate} 同画面（预期：同一登录页状态）md5={md5[:12]}…")
        self.items.append({"step": f"{name} 截图", "ok": True, "detail": json.dumps(stats)})
        self.shots_by_name[name] = stats
        print(f"  [SHOT] artifacts/{os.path.basename(path)} {width}x{height} bytes={len(data)} "
              f"nonwhite={ratio} colors={len(colors)} brand={green} md5={md5[:12]}", flush=True)
        return stats

    def save(self, extra: dict) -> str:
        path = os.path.join(self.dir, "report.json")
        payload = {"checks": self.items, "failed": self.failed, "shots": self.shots}
        payload.update(extra)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
        return path


# --------------------------------------------------------------------------- #
# 页面操作 helpers
# --------------------------------------------------------------------------- #
def js(cdp: Cdp, expression: str, *, await_promise: bool = False, timeout: float = 60.0):
    params = {"expression": expression, "returnByValue": True, "awaitPromise": await_promise}
    try:
        result = cdp.call("Runtime.evaluate", params, timeout=timeout)
    except EnvUnreachable:
        # 导航瞬间可能整帧不回：短睡后重试一次（不改任何断言口径）
        time.sleep(1.0)
        try:
            result = cdp.call("Runtime.evaluate", params, timeout=timeout)
        except EnvUnreachable as exc:
            raise EnvUnreachable(f"{exc}；表达式片段：{expression[:80]!r}") from exc
    if result.get("exceptionDetails"):
        raise CheckFailed(f"页面 JS 抛错：{json.dumps(result['exceptionDetails'], ensure_ascii=False)[:300]}")
    return result.get("result", {}).get("value")


def _path_of(url: str) -> str:
    """只取路径部分：`.../admin/login?next=/admin/users` 与 `/admin/users` 不能混为一谈。"""
    return url.split("?", 1)[0]


def goto(cdp: Cdp, url: str, timeout: float = 30.0) -> list[dict]:
    cdp.drain()
    nav = cdp.call("Page.navigate", {"url": url})
    if isinstance(nav, dict) and nav.get("errorText"):
        raise CheckFailed(f"Page.navigate 失败（{nav['errorText']}）：{url}")
    last = "（未取到）"
    # 允许同源重定向（例如未登录访问 /admin/users → 303 → /admin/login?next=...）：
    # 只要求「没有停在 about:blank / 错误页」，具体语义由各自的断言负责。
    parsed = urlsplit(url)
    origin = f"{parsed.scheme}://{parsed.netloc}"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            state = js(cdp, "document.readyState")
            here = js(cdp, "location.href")
            last = f"readyState={state} href={here} title={js(cdp, 'document.title')}"
            if state == "complete" and str(here).startswith(origin):
                time.sleep(0.4)
                return cdp.responses()
        except (CheckFailed, EnvUnreachable) as exc:
            last = f"evaluate 异常：{exc}"
        time.sleep(0.3)
    raise CheckFailed(f"等待页面加载超时：{url}｜最后观测 {last}")


def wait_until(cdp: Cdp, expression: str, timeout: float = 25.0, interval: float = 0.25) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if js(cdp, expression) is True:
                return True
        except (CheckFailed, EnvUnreachable):
            pass
        time.sleep(interval)
    return False


def wait_for_response(cdp: Cdp, needle: str, method: str | None = None,
                      timeout: float = 25.0) -> dict | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        for item in cdp.responses():
            if needle in _path_of(item["url"]) and (method is None or item["method"] == method):
                return item
        cdp.pump(0.25)
    return None


def find_response(responses: list[dict], needle: str, method: str | None = None) -> dict | None:
    for item in responses:
        if needle in _path_of(item["url"]) and (method is None or item["method"] == method):
            return item
    return None


def describe(hit: dict | None) -> str:
    return f"实测 HTTP {hit['status']} {hit['method']}" if hit else "未捕获到该请求"


def body_text(cdp: Cdp) -> str:
    return js(cdp, "document.body ? document.body.innerText : ''") or ""


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
def main() -> int:
    if len(sys.argv) < 2:
        print("用法：cdp_driver.py <config.json>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as handle:
        cfg = json.load(handle)

    base = cfg["base_url"].rstrip("/")
    cdp_http = cfg["cdp_http"].rstrip("/")
    artifacts = cfg["artifacts_dir"]
    viewport = (int(cfg["viewport"][0]), int(cfg["viewport"][1]))
    os.makedirs(artifacts, exist_ok=True)
    report = Report(artifacts)
    admin_user = cfg["admin_username"]
    admin_pass = cfg["admin_password"]
    new_pass = cfg["admin_new_password"]
    item_id = cfg.get("item_id", "frame_01")
    upload_png = cfg["upload_png"]

    # 0) 服务端与 CDP 可达性（不可达 → 退出码 2，如实记未运行）
    status, _, _ = http("GET", f"{base}/admin/login")
    if status != 200:
        raise EnvUnreachable(f"服务端 {base}/admin/login 返回 {status}，不是 200")
    print(f"[ENV] 服务端 {base}/admin/login → HTTP {status}", flush=True)

    version_status, _, version_body = http("GET", f"{cdp_http}/json/version")
    if version_status != 200:
        raise EnvUnreachable(f"CDP {cdp_http}/json/version 返回 {version_status}")
    version = json.loads(version_body.decode())
    print(f"[ENV] CDP 可达：{version.get('Browser')} / 协议 {version.get('Protocol-Version')}", flush=True)
    browser_ws = version["webSocketDebuggerUrl"]

    page_status, _, page_body = http("PUT", f"{cdp_http}/json/new?about:blank")
    if page_status not in (200, 201):
        raise EnvUnreachable(f"CDP 新建标签页失败：HTTP {page_status}")
    target = json.loads(page_body.decode())
    cdp = Cdp(target["webSocketDebuggerUrl"])
    cdp.call("Page.enable")
    cdp.call("Runtime.enable")
    cdp.call("Network.enable")
    cdp.call("Network.setCacheDisabled", {"cacheDisabled": True})
    # 起始态必须是「未登录」：清掉浏览器侧全部 Cookie，不依赖 profile 是否干净
    cdp.call("Network.clearBrowserCookies")
    print("[ENV] 已清空浏览器 Cookie（保证从未登录态开始）", flush=True)
    cdp.call("Emulation.setDeviceMetricsOverride",
             {"width": viewport[0], "height": viewport[1], "deviceScaleFactor": 1, "mobile": False})
    print(f"[ENV] 已连页面目标 {target.get('id')}，视口 {viewport[0]}x{viewport[1]}", flush=True)

    def screenshot(name: str, **kwargs) -> dict:
        result = cdp.call("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
        return report.shot(name, base64.b64decode(result["data"]), viewport=viewport, **kwargs)

    # ------------------------------------------------------------------ ① 登录
    print("\n=== ① 登录（浏览器真实表单提交）===", flush=True)
    responses = goto(cdp, f"{base}/admin/login")
    report.info("① 诊断：location.href=" + str(js(cdp, "location.href"))
                + " title=" + str(js(cdp, "document.title"))
                + " readyState=" + str(js(cdp, "document.readyState"))
                + " hasLoginForm=" + str(js(cdp, "!!document.querySelector('#login-form')"))
                + " h1=" + str(js(cdp, "document.querySelector('h1') ? document.querySelector('h1').textContent : '（无 h1）'")))
    report.info("① 诊断：本次导航抓到的响应 = " + (
        "；".join(f"{r['method']} {_path_of(r['url'])} → {r['status']}" for r in responses) or "（空）"))
    _html = js(cdp, "document.documentElement ? document.documentElement.outerHTML : ''")
    report.info("① 诊断：DOM 前 240 字 = " + (str(_html)[:240].replace(chr(10), " ") if _html else "（空）"))
    hit = find_response(responses, "/admin/login")
    report.check("① GET /admin/login 状态码 200", bool(hit) and hit["status"] == 200, describe(hit))
    login_text = body_text(cdp)
    report.check("① 登录页关键文本命中",
                 "管理员登录" in login_text and "碳小布" in login_text,
                 f"innerText 含「管理员登录」={'管理员登录' in login_text}、含「碳小布」={'碳小布' in login_text}")
    report.check("① 登录页有 #login-form 表单（username/password）",
                 js(cdp, "!!document.querySelector('#login-form input[name=username]') "
                         "&& !!document.querySelector('#login-form input[name=password]')") is True,
                 "实测 has_user_input="
                 + str(js(cdp, "!!document.querySelector('#login-form input[name=username]')"))
                 + " has_pass_input="
                 + str(js(cdp, "!!document.querySelector('#login-form input[name=password]')")))
    screenshot("01_login_page", green_min=200)

    js(cdp, f"document.querySelector('#login-form input[name=username]').value = {json.dumps(admin_user)};"
            f"document.querySelector('#login-form input[name=password]').value = {json.dumps(admin_pass)};"
            "true")
    cdp.drain()
    js(cdp, "document.querySelector('#login-form button[type=submit]').click(); true")
    navigated = wait_until(cdp, "location.pathname === '/admin'", timeout=25)
    report.check("① 提交后浏览器进入 /admin", navigated, f"location.pathname={js(cdp, 'location.pathname')}")
    time.sleep(0.5)
    overview_text = body_text(cdp)
    report.check("① 登录后总览页关键文本命中",
                 "数据总览" in overview_text and admin_user in overview_text,
                 f"含「数据总览」={'数据总览' in overview_text}、含管理员名={admin_user in overview_text}")
    report.check("① 会话令牌是 HttpOnly（页面脚本读不到）",
                 js(cdp, "document.cookie.indexOf('carbonboo_admin_token') < 0") is True,
                 "document.cookie 不含 carbonboo_admin_token")
    shot01 = report.shots_by_name.get("01_login_page")
    shot02 = screenshot("02_after_login")
    report.check("① 登录后画面与登录页确实不同（截图 md5 不同）",
                 shot02["md5"] != shot01["md5"],
                 f"{shot01['md5'][:12]}… vs {shot02['md5'][:12]}…")

    # 注册一个客户端账号：让 ② 的用户列表有真实行，并用于 ⑦ 的跨 audience 403 探测
    client_user = cfg["client_username"]
    client_pass = cfg["client_password"]
    reg_status, _, _ = http("POST", f"{base}/api/v1/auth/register",
                            payload={"username": client_user, "password": client_pass})
    report.info(f"已注册客户端账号 {client_user}（POST /api/v1/auth/register → HTTP {reg_status}）")

    # ------------------------------------------------------------------ ② 用户列表
    print("\n=== ② 用户列表 ===", flush=True)
    responses = goto(cdp, f"{base}/admin/users")
    hit = find_response(responses, "/admin/users")
    report.check("② GET /admin/users 状态码 200", bool(hit) and hit["status"] == 200, describe(hit))
    users_text = body_text(cdp)
    report.check("② 用户页关键文本命中",
                 "用户列表" in users_text and "账号与设备" in users_text,
                 "innerText 含「用户列表」与「账号与设备」（空库时另有「还没有账号…」）")
    report.check("② 用户页表头渲染（账号/user_id/首次接入/设备）",
                 all(k in users_text for k in ("账号", "首次接入", "最后同步", "设备")),
                 "innerText 含表头「账号」「首次接入」「最后同步」「设备（按 device_id 去重）」")
    report.check("② 用户列表里出现刚注册的客户端账号（库内真值）",
                 client_user in users_text,
                 f"innerText 含 {client_user}（空库会显示「还没有账号…」，也可）")
    report.check("② 该页确由服务端渲染（含侧栏导航与页脚口径）",
                 "客户端只读取价，无权改价" in users_text,
                 "innerText 含侧栏文案「客户端只读取价，无权改价」")
    screenshot("03_users")

    # ------------------------------------------------------------------ ③ 操作日志
    print("\n=== ③ 操作日志 ===", flush=True)
    responses = goto(cdp, f"{base}/admin/logs")
    hit = find_response(responses, "/admin/logs")
    report.check("③ GET /admin/logs 状态码 200", bool(hit) and hit["status"] == 200, describe(hit))
    logs_text = body_text(cdp)
    report.check("③ 日志页关键文本命中",
                 "操作日志" in logs_text and "操作人" in logs_text and "改前 / 改后" in logs_text,
                 "innerText 含「操作日志」标题与「操作人」「改前 / 改后」表头")
    report.check("③ 日志里已有本次管理员的登录记录（浏览器看到的库内真值）",
                 admin_user in logs_text,
                 f"innerText 含管理员名 {admin_user}（登录时写 admin_op_log）")
    screenshot("04_logs")

    # ------------------------------------------------------------------ ④ 系统配置读 + 写
    print("\n=== ④ 系统配置：读 + 写 ===", flush=True)
    responses = goto(cdp, f"{base}/admin/config")
    hit = find_response(responses, "/admin/config")
    report.check("④ GET /admin/config 状态码 200", bool(hit) and hit["status"] == 200, describe(hit))
    config_text = body_text(cdp)
    before_cap = js(cdp, "document.querySelector('#config-form input[name=dailyCap]').value")
    report.check("④ 配置页关键文本命中",
                 "系统配置" in config_text and "每日" in config_text and "保存" in config_text,
                 f"innerText 含「系统配置」；dailyCap 输入框当前值={before_cap}")
    screenshot("05_config_read")

    new_cap = 240 if str(before_cap) != "240" else 260
    cdp.drain()
    js(cdp, f"document.querySelector('#config-form input[name=dailyCap]').value = '{new_cap}'; true")
    js(cdp, "document.querySelector('#config-form button[type=submit]').click(); true")
    put_hit = wait_for_response(cdp, "/admin/config", method="PUT", timeout=25)
    report.check("④ 浏览器提交表单 → PUT /admin/config 状态码 200",
                 bool(put_hit) and put_hit["status"] == 200, describe(put_hit))
    report.info(f"配置写入：dailyCap {before_cap} → {new_cap}（表单提交，admin.js 同源 fetch）")
    time.sleep(1.5)  # admin.js 保存后 location.reload()
    responses = goto(cdp, f"{base}/admin/config")
    after_cap = js(cdp, "document.querySelector('#config-form input[name=dailyCap]').value")
    report.check("④ 重载后服务端回显新值（写入真落库）", str(after_cap) == str(new_cap),
                 f"写前={before_cap} → 写 {new_cap} → 重载后={after_cap}")
    hit = find_response(responses, "/admin/config")
    report.check("④ 重载 GET /admin/config 状态码 200", bool(hit) and hit["status"] == 200, describe(hit))
    screenshot("06_config_write")

    # ------------------------------------------------------------------ ⑤ 图标上传
    print("\n=== ⑤ 商品图标上传（真实 <input type=file> + CDP DOM.setFileInputFiles）===", flush=True)
    responses = goto(cdp, f"{base}/admin/items")
    hit = find_response(responses, "/admin/items", method="GET")
    report.check("⑤ GET /admin/items 状态码 200", bool(hit) and hit["status"] == 200, describe(hit))
    items_text = body_text(cdp)
    report.check("⑤ 商品页关键文本命中",
                 "商品管理" in items_text and "保存" in items_text and "新增" in items_text,
                 "innerText 含「商品管理」标题与「保存」「新增商品」按钮")
    selector = f'input[data-action="upload-icon"][data-item-id="{item_id}"]'
    report.check("⑤ 页面上存在该商品的文件上传控件",
                 js(cdp, f"!!document.querySelector('{selector}')") is True, f"{selector} 命中")
    cdp.drain()
    document = cdp.call("DOM.getDocument", {"depth": -1})
    node = cdp.call("DOM.querySelector",
                    {"nodeId": document["root"]["nodeId"], "selector": selector})
    node_id = int(node.get("nodeId", 0))
    report.check("⑤ DOM.querySelector 拿到上传控件 nodeId", node_id > 0, f"nodeId={node_id}")
    report.info(f"上传夹具（Windows 真实文件）：{upload_png}（96x96 PNG，品牌色）")
    cdp.call("DOM.setFileInputFiles", {"files": [upload_png], "nodeId": node_id})
    post_hit = wait_for_response(cdp, f"/admin/items/{item_id}/icon", method="POST", timeout=25)
    report.check(f"⑤ POST /admin/items/{item_id}/icon 状态码 200",
                 bool(post_hit) and post_hit["status"] == 200, describe(post_hit))
    items_json = js(cdp, "(async () => { const r = await fetch('/admin/items', "
                         "{headers: {Accept: 'application/json'}}); const j = await r.json();"
                         f" const it = (j.data.items || []).find(x => x.id === '{item_id}');"
                         " return JSON.stringify({status: r.status, icon: it ? it.icon : null}); })()",
                    await_promise=True)
    item_state = json.loads(items_json) if items_json else {}
    icon_url = str(item_state.get("icon") or "")
    report.check("⑤ 库内该商品的 icon 已指向 /admin/icons/*（页面内 fetch JSON 实读）",
                 icon_url.startswith("/admin/icons/"),
                 f"GET /admin/items（Accept: application/json）→ status={item_state.get('status')} icon={icon_url}")
    probe_json = js(cdp, f"(async () => {{ const r = await fetch({json.dumps(icon_url)});"
                          " const b = new Uint8Array(await r.arrayBuffer());"
                          " return JSON.stringify({status: r.status, ct: r.headers.get('content-type'),"
                          " head: Array.from(b.slice(0, 8)), len: b.length}); })()", await_promise=True)
    probe = json.loads(probe_json) if probe_json else {}
    report.check("⑤ GET /admin/icons/<file> 可取回且确实是 PNG 字节",
                 probe.get("status") == 200 and list(probe.get("head", []))[:4] == [137, 80, 78, 71],
                 f"status={probe.get('status')} content-type={probe.get('ct')} "
                 f"magic={probe.get('head')} bytes={probe.get('len')}")
    time.sleep(1.2)
    goto(cdp, f"{base}/admin/items")
    report.check("⑤ 重载商品页后能看到新图标（<img> 指向 /admin/icons/）",
                 js(cdp, f"!!document.querySelector('img[src*=\"/admin/icons/\"]')") is True,
                 "document.querySelector('img[src*=\"/admin/icons/\"]') 命中")
    screenshot("07_items_icon")

    # ------------------------------------------------------------------ ⑥ 改密
    print("\n=== ⑥ 修改管理员口令 ===", flush=True)
    responses = goto(cdp, f"{base}/admin/password")
    hit = find_response(responses, "/admin/password")
    report.check("⑥ GET /admin/password 状态码 200", bool(hit) and hit["status"] == 200, describe(hit))
    password_text = body_text(cdp)
    report.check("⑥ 改密页关键文本命中",
                 "修改密码" in password_text and "口令" in password_text and "≥12" in password_text,
                 "innerText 含「修改密码」「口令」「≥12 位」策略说明")
    screenshot("08_password")
    cdp.drain()
    js(cdp, "document.querySelector('#password-form input[name=oldPassword]').value = "
            f"{json.dumps(admin_pass)};"
            "document.querySelector('#password-form input[name=newPassword]').value = "
            f"{json.dumps(new_pass)};"
            "document.querySelector('#password-form input[name=confirmPassword]').value = "
            f"{json.dumps(new_pass)}; true")
    js(cdp, "document.querySelector('#password-form button[type=submit]').click(); true")
    changed = wait_until(cdp, "document.body.innerText.indexOf('口令已更新') >= 0", timeout=20)
    post_hit = wait_for_response(cdp, "/admin/password", method="POST", timeout=5)
    report.check("⑥ POST /admin/password 状态码 200", bool(post_hit) and post_hit["status"] == 200,
                 describe(post_hit))
    report.check("⑥ 页面回显「口令已更新」", changed, "innerText 含「口令已更新（旧口令即时失效）」")

    # ------------------------------------------------------------------ ⑦ 登出 + 鉴权边界
    print("\n=== ⑦ 登出 + 鉴权边界 ===", flush=True)
    cookies = cdp.call("Network.getCookies", {})
    token_before = next((c.get("value", "") for c in cookies.get("cookies", [])
                         if c.get("name") == "carbonboo_admin_token"), "")
    report.check("⑦ 登出前浏览器持有会话 Cookie（HttpOnly，CDP 可见）", bool(token_before),
                 f"carbonboo_admin_token 长度={len(token_before)}")
    cdp.drain()
    js(cdp, "document.querySelector('button[data-action=\"logout\"]').click(); true")
    logged_out = wait_until(cdp, "location.pathname === '/admin/login'", timeout=20)
    logout_hit = wait_for_response(cdp, "/admin/logout", method="POST", timeout=5)
    report.check("⑦ POST /admin/logout 状态码 200", bool(logout_hit) and logout_hit["status"] == 200,
                 describe(logout_hit))
    report.check("⑦ 登出后浏览器被带回登录页", logged_out and "管理员登录" in body_text(cdp),
                 f"location.pathname={js(cdp, 'location.pathname')}")
    cookies_after = cdp.call("Network.getCookies", {})
    still = [c for c in cookies_after.get("cookies", [])
             if c.get("name") == "carbonboo_admin_token" and c.get("value")]
    report.check("⑦ 登出后浏览器已不持有会话 Cookie（正向对照）", not still,
                 f"Network.getCookies 中 carbonboo_admin_token 条数={len(still)}")
    screenshot("09_after_logout", green_min=200, dup_ok=True)

    responses = goto(cdp, f"{base}/admin/users")
    hit = find_response(responses, "/admin/users", method="GET")
    side_status, side_headers, _ = http("GET", f"{base}/admin/users",
                                        headers={"Accept": "text/html"})
    report.info("⑦ 本次导航期间浏览器抓到的 /admin 相关响应：" + (
        "；".join(f"{r['method']} {_path_of(r['url'])} → {r['status']}"
                  for r in responses if "/admin" in r["url"]) or "（无）"))
    report.check("⑦ 未登录访问 /admin/users → 303 跳登录页（浏览器实看）",
                 bool(hit) and hit["status"] == 303, describe(hit))
    report.check("⑦ 未登录访问 /admin/users → 303（旁路 urllib 不跟随重定向，原始状态码）",
                 side_status == 303,
                 f"HTTP {side_status}，Location={side_headers.get('location', '（无）')}")
    report.check("⑦ 未登录访问 /admin/users 最终停在登录页",
                 js(cdp, "location.pathname") == "/admin/login" and "管理员登录" in body_text(cdp),
                 f"location.pathname={js(cdp, 'location.pathname')}")
    screenshot("10_users_unauthenticated", green_min=200, dup_ok=True)

    replay_status, _, replay_body = http("GET", f"{base}/admin/users",
                                         headers={"Cookie": f"carbonboo_admin_token={token_before}"})
    replay_note = ("管理端 JWT 无状态、服务端不吊销（`admin_web/api.py:214` 已写明「过期自然失效」）："
                   "浏览器侧 Cookie 已被清（正向对照通过），但把被清掉的令牌原样重放仍 200")
    report.info(f"旁路对照（非浏览器）：旧 Cookie 原样重放 → HTTP {replay_status}"
                f"（{len(replay_body)} 字节）；{replay_note}")

    # 客户端 JWT 打 /admin/* 必须 403（由浏览器 fetch 发起）
    client_user = cfg["client_username"]
    client_pass = cfg["client_password"]
    login_status, _, login_body = http("POST", f"{base}/api/v1/auth/login",
                                       payload={"username": client_user, "password": client_pass})
    client_token = ""
    if login_status == 200:
        client_token = json.loads(login_body.decode()).get("data", {}).get("userToken", "")
    fetch_expr = ("(async () => { const r = await fetch('/admin/users', {headers: "
                  f"{{Authorization: 'Bearer {client_token}'}}}});"
                  " const t = await r.text(); let code = ''; try { code = JSON.parse(t).code } catch (e) {}"
                  " return JSON.stringify({status: r.status, code: code}); })()")
    fetch_result = json.loads(js(cdp, fetch_expr, await_promise=True)) if client_token else {}
    report.check("⑦ 客户端令牌（aud=carbonboo-client）由浏览器打 /admin/users 必须 403",
                 fetch_result.get("status") == 403 and fetch_result.get("code") == "FORBIDDEN",
                 f"客户端账号 {client_user} 登录 HTTP {login_status} → 浏览器 fetch 实测 "
                 f"HTTP {fetch_result.get('status')} code={fetch_result.get('code')}")
    screenshot("11_client_token_probe", dup_ok=True)

    # 改密的负向 + 正向对照（浏览器真实表单）
    # 上一步 303 已把浏览器带到 /admin/login，这里先确认它确实在登录页，不再重新导航
    report.check("⑥ 负向对照前浏览器确实停在登录页",
                 js(cdp, "location.pathname") == "/admin/login"
                 and "管理员登录" in body_text(cdp),
                 f"location.pathname={js(cdp, 'location.pathname')}")
    js(cdp, f"document.querySelector('#login-form input[name=username]').value = {json.dumps(admin_user)};"
            f"document.querySelector('#login-form input[name=password]').value = {json.dumps(admin_pass)}; true")
    cdp.drain()
    js(cdp, "document.querySelector('#login-form button[type=submit]').click(); true")
    fail_hit = wait_for_response(cdp, "/admin/login", method="POST", timeout=25)
    time.sleep(1.2)
    report.check("⑥ 负向对照：改密后旧口令登录被拒（POST /admin/login → 401）",
                 bool(fail_hit) and fail_hit["status"] == 401, describe(fail_hit))
    # 修后语义（t59）：登录失败必须走**页内 #flash**，不得再弹原生 window.alert。
    # 改前这里断言的是「dialog 必须出现」（反过来的期望），现已翻转为正向断言。
    dialogs = list(cdp.dialogs)
    flash_probe = js(cdp, "(function(){var b=document.getElementById('flash');"
                          "if(!b){return JSON.stringify({found:false});}"
                          "return JSON.stringify({found:true,text:b.textContent,"
                          "hidden:b.hidden,cls:b.className});})()")
    flash = json.loads(flash_probe) if isinstance(flash_probe, str) else {}
    report.check("⑥ 失败提示不再走浏览器原生 alert（Page.javascriptDialogOpening 事件数应为 0）",
                 not dialogs,
                 f"dialogs={len(dialogs)}（改前 1 条 type=alert message='管理员用户名或口令错误'）；"
                 f"本条即 §R12.6-1 的修复验证")
    report.check("⑥ 失败提示落在页内 #flash（文本非空、可见、不再是模态弹窗）",
                 flash.get("found") is True and bool(str(flash.get("text", "")).strip())
                 and flash.get("hidden") is False,
                 f"#flash found={flash.get('found')} hidden={flash.get('hidden')} "
                 f"text={str(flash.get('text', ''))!r} class={flash.get('cls')!r}")
    report.check("⑥ 旧口令被拒后仍停在登录页", js(cdp, "location.pathname") == "/admin/login",
                 f"location.pathname={js(cdp, 'location.pathname')}")
    screenshot("12_old_password_rejected", green_min=200, dup_ok=True)

    js(cdp, "var n = document.querySelector('#login-form input[name=next]');"
            "if (n) { n.value = '/admin'; } true")
    js(cdp, f"document.querySelector('#login-form input[name=password]').value = {json.dumps(new_pass)}; true")
    js(cdp, "document.querySelector('#login-form button[type=submit]').click(); true")
    relogin = wait_until(cdp, "location.pathname === '/admin'", timeout=25)
    report.check("⑥ 正向对照：新口令在浏览器里登录成功并进入总览页",
                 relogin and "数据总览" in body_text(cdp),
                 f"location.pathname={js(cdp, 'location.pathname')}")
    screenshot("13_relogin_new_password")

    try:
        browser = Cdp(browser_ws)
        browser.call("Browser.close", timeout=10)
    except Exception as exc:  # noqa: BLE001 - 关浏览器失败不影响结论，run.sh 还有兜底
        print(f"  [WARN] Browser.close 未成功（{exc}），由 run.sh 兜底清理", flush=True)

    report_path = report.save({
        "dialogs": cdp.dialogs,
        "base_url": base,
        "browser": version.get("Browser"),
        "viewport": list(viewport),
        "admin_username": admin_user,
        "item_id": item_id,
    })
    print(f"\n[REPORT] {report_path}", flush=True)
    print(f"[RESULT] checks={len(report.items)} failed={report.failed}", flush=True)
    return 0 if report.failed == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except EnvUnreachable as error:
        print(f"[ENV-FAIL] {error}", file=sys.stderr, flush=True)
        sys.exit(2)
    except CheckFailed as error:
        print(f"[CHECK-FAIL] {error}", file=sys.stderr, flush=True)
        sys.exit(1)
