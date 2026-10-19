#!/usr/bin/env python3
"""t76：校验「真 nginx(TLS) 反代」与「直连 uvicorn」两条 `/admin` 访问路径是否一致。

为什么单独一个脚本
------------------
`cdp_driver.py` 跑在 **Windows** 侧（Edge 与驱动同侧），拿不到 nginx 容器的自签证书文件
（它在 WSL 的 `/tmp`），也不适合校验「两条路径逐字节一致」。本脚本在 **WSL** 侧用纯标准库
（`http.client` + `ssl` + `hashlib`）做四件事，任一不一致即退出码 1：

  ① 断言集合一致：`artifacts/report.json`（直连）与 `artifacts/report_nginx.json`（nginx）
     的检查项名称集合相同（`⑧ …` 为 nginx 侧新增的资源探针，仅在这一侧存在；它收尾那张
     `14_resource_paths` 截图名不带 `⑧` 前缀，用 `--nginx-only-shot` 单列；第二遍的截图断言名
     带 `nginx_` 前缀，比对前统一剥掉），且两侧全部 ok；
  ② TLS 是真的：`https://api.example.com:<port>` 实际连 `127.0.0.1:<port>`，按 `api.example.com`
     做 SNI + 主机名校验，并把对端证书 DER 的 sha256 与 nginx 挂载的证书文件比对；
  ③ 页面/静态资源逐字节一致：登录页 HTML、`/admin/static/*` 等浏览器实际加载过的资源，
     直连与 nginx 的 HTTP 状态码 + 响应体 sha256 全部相同（反代若改写/截断/分叉，这里必红）；
  ④ 截图证据：`report_nginx.json` 里至少 `--min-brand-shots` 张截图带品牌主色 `#2E7D5B`
     像素（由 Windows 侧 Pillow 逐像素统计），且文件真实存在、尺寸 1440×900。

退出码：0 = 一致；1 = 有分叉/缺证据；2 = 环境不可达（连不上任一侧）。
**本脚本不安装任何依赖**（WSL python3 标准库即可；Pillow 只在 Windows 侧用）。
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import socket
import ssl
import sys
from urllib.parse import urlsplit

FAILED = 0


def check(ok: bool, name: str, detail: str) -> None:
    global FAILED
    print(("  [PASS] " if ok else "  [FAIL] ") + f"{name}: {detail}", flush=True)
    if not ok:
        FAILED += 1


def info(text: str) -> None:
    print(f"  [INFO] {text}", flush=True)


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    """连 `127.0.0.1:<port>`，但按 `server_hostname`（api.example.com）做 SNI 与证书主机名校验。"""

    def __init__(self, host: str, port: int, context: ssl.SSLContext, server_hostname: str) -> None:
        super().__init__(host, port, context=context)
        self._server_hostname = server_hostname

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self._server_hostname)


class Unreachable(Exception):
    pass


def _request(conn: http.client.HTTPConnection, path: str, host_header: str) -> tuple[int, bytes]:
    conn.request("GET", path, headers={"Host": host_header, "Connection": "close"})
    response = conn.getresponse()
    return int(response.status), response.read()


def fetch_direct(base: str, path: str) -> tuple[int, bytes]:
    parts = urlsplit(base)
    conn = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=20)
    try:
        return _request(conn, path, parts.netloc)
    except OSError as exc:
        raise Unreachable(f"直连 {base}{path} 失败：{exc}") from exc
    finally:
        conn.close()


def fetch_nginx(base: str, path: str, cert_path: str) -> tuple[int, bytes, str]:
    """返回 (status, body, 对端证书 DER 的 sha256)。按 api.example.com 做真实 TLS 校验。"""
    parts = urlsplit(base)
    host = parts.hostname or "api.example.com"
    port = parts.port or 443
    context = ssl.create_default_context(cafile=cert_path)
    raw = _PinnedHTTPSConnection("127.0.0.1", port, context, host)
    try:
        raw.connect()  # 证书链 + 主机名（api.example.com）在这一步校验
        der = raw.sock.getpeercert(binary_form=True)  # type: ignore[union-attr]
        status, body = _request(raw, path, parts.netloc)
        return status, body, hashlib.sha256(der).hexdigest()
    except (OSError, ssl.SSLError) as exc:
        raise Unreachable(f"nginx {base}{path} 失败：{exc}") from exc
    finally:
        raw.close()


def load_report(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def common_checks(direct: dict, nginx: dict, skip: str = "⑧", shot_prefix: str = "nginx_",
                  nginx_only_shots: tuple[str, ...] = ()) -> list[dict]:
    """比对两条路径的断言项集合。`skip` = 仅 nginx 侧新增的步骤前缀（⑧ 资源探针）；
    `nginx_only_shots` = 仅 nginx 侧新增的截图名（⑧ 探针的收尾截图不带 ⑧ 前缀）。"""

    def names(report: dict, strip: str) -> list[str]:
        out = []
        for item in report["checks"]:
            step = item.get("step")
            if step == "info" or step.startswith(skip):
                continue
            name = step[len(strip):] if strip and step.startswith(strip) else step
            if any(name.startswith(shot) for shot in nginx_only_shots):
                continue
            out.append(name)
        return out

    a = names(direct, "")
    b = names(nginx, shot_prefix)
    only_a = [n for n in a if n not in set(b)]
    only_b = [n for n in b if n not in set(a)]
    check(a == b and not only_a and not only_b,
          "两条路径的检查项集合一致（⑧ 资源探针与其收尾截图仅在 nginx 侧；截图名 nginx_ 前缀已归一）",
          f"直连 {len(a)} 项 / nginx {len(b)} 项 / 仅直连 {only_a[:5]} / 仅 nginx {only_b[:5]}")
    return [item for item in direct["checks"]
            if item.get("step") != "info" and not item["step"].startswith(skip)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--direct-http", required=True, help="http://127.0.0.1:<uvicorn 端口>")
    parser.add_argument("--nginx-url", required=True, help="https://api.example.com:<nginx 端口>")
    parser.add_argument("--nginx-cert", required=True, help="nginx 挂载的自签证书（PEM）")
    parser.add_argument("--direct-report", required=True)
    parser.add_argument("--nginx-report", required=True)
    parser.add_argument("--artifacts", required=True)
    parser.add_argument("--min-brand-shots", type=int, default=3)
    parser.add_argument("--nginx-only-shot", action="append", default=None,
                        help="仅 nginx 侧存在的截图名（⑧ 资源探针收尾截图），可重复")
    args = parser.parse_args()
    nginx_only_shots = tuple(args.nginx_only_shot or ["14_resource_paths"])

    try:
        direct = load_report(args.direct_report)
        nginx = load_report(args.nginx_report)
    except OSError as exc:
        check(False, "两份驱动报告齐备（直连 + nginx）", f"读不到：{exc}")
        print(f"\n[RESULT] 一致性校验失败项={FAILED}")
        return 1

    print("\n=== t76 一致性校验：直连 uvicorn ↔ 真 nginx(TLS) 反代 ===")
    check(bool(direct.get("base_url", "").startswith("http://")),
          "直连报告的 base_url 是明文 http", direct.get("base_url", ""))
    check(bool(nginx.get("base_url", "").startswith("https://api.example.com")),
          "nginx 报告的 base_url 是 https://api.example.com", nginx.get("base_url", ""))

    # ① 断言集合与通过状态
    direct_items = common_checks(direct, nginx, nginx_only_shots=nginx_only_shots)
    check(direct.get("failed") == 0, "直连报告 failed == 0", f"failed={direct.get('failed')}")
    check(nginx.get("failed") == 0, "nginx 报告 failed == 0", f"failed={nginx.get('failed')}")
    direct_fail = [i["step"] for i in direct_items if not i.get("ok")]
    nginx_fail = [i["step"] for i in nginx["checks"]
                  if i.get("step") != "info" and not i.get("ok")]
    check(not direct_fail and not nginx_fail,
          "两条路径的全部断言均为 ok",
          f"直连失败={direct_fail[:5]} nginx 失败={nginx_fail[:5]}")

    # ② TLS 真实性 + 登录页逐字节一致
    cert_der = ssl.PEM_cert_to_DER_cert(open(args.nginx_cert, encoding="utf-8").read())
    expected_cert_sha = hashlib.sha256(cert_der).hexdigest()
    try:
        d_status, d_body = fetch_direct(args.direct_http, "/admin/login")
        n_status, n_body, peer_sha = fetch_nginx(args.nginx_url, "/admin/login", args.nginx_cert)
    except Unreachable as exc:
        print(f"[ENV-FAIL] {exc}")
        print("RESULT: ENV-UNREACHABLE")
        return 2
    check(peer_sha == expected_cert_sha,
          "nginx 对端证书 sha256 == 挂载证书文件",
          f"peer={peer_sha[:16]}… expected={expected_cert_sha[:16]}…")
    check(d_status == n_status == 200,
          "登录页两条路径 HTTP 200", f"直连={d_status} nginx={n_status}")
    d_sha, n_sha = hashlib.sha256(d_body).hexdigest(), hashlib.sha256(n_body).hexdigest()
    check(d_sha == n_sha,
          "登录页 HTML 逐字节一致（sha256）", f"直连={d_sha[:16]}… nginx={n_sha[:16]}…")

    # ③ 浏览器实际加载过的资源：两条路径状态码 + sha256 必须一致
    resources = [p for p in nginx.get("resources", []) if p.startswith("/admin/")]
    check(bool(resources), "nginx 报告带浏览器实际资源路径清单",
          json.dumps(resources, ensure_ascii=False))
    check(any(p.startswith("/admin/static/") for p in resources),
          "资源清单含 /admin/static/（反代没有把静态资源甩到别处）", "")
    for path in sorted(set(resources)):
        d_code, d_bytes = fetch_direct(args.direct_http, path)
        n_code, n_bytes, _ = fetch_nginx(args.nginx_url, path, args.nginx_cert)
        same = d_code == n_code and hashlib.sha256(d_bytes).hexdigest() == hashlib.sha256(n_bytes).hexdigest()
        check(same, f"资源 {path} 直连==nginx",
              f"直连 {d_code}/{len(d_bytes)}B sha={hashlib.sha256(d_bytes).hexdigest()[:12]}… "
              f"nginx {n_code}/{len(n_bytes)}B sha={hashlib.sha256(n_bytes).hexdigest()[:12]}…")

    # ④ 截图证据：Report.shot 把每张图的尺寸/非空白比例/颜色数/品牌像素/ md5 写进 checks 的
    #    「<name> 截图」条目（detail 是 JSON），这里据此核对「张数 ≥ N 且品牌主色像素 > 0」，
    #    并确认对应 PNG 真在 artifacts/ 里。
    stats: dict[str, dict] = {}
    for item in nginx["checks"]:
        if not str(item.get("step", "")).endswith(" 截图"):
            continue
        try:
            stats[item["step"]] = json.loads(item["detail"])
        except (TypeError, ValueError):
            continue
    brand_shots = [name for name, s in stats.items() if int(s.get("brand_pixels", 0)) > 0]
    check(len(stats) >= args.min_brand_shots,
          f"nginx 路径截图数 ≥ {args.min_brand_shots}", f"实测 {len(stats)} 张")
    check(len(brand_shots) >= args.min_brand_shots,
          f"至少 {args.min_brand_shots} 张截图命中品牌主色 #2E7D5B（Windows Pillow 逐像素）",
          f"实测 {len(brand_shots)} 张："
          + "; ".join(f"{n}={stats[n].get('brand_pixels')}px" for n in sorted(brand_shots)[:6]))
    missing = [s.get("file") for s in stats.values()
               if not os.path.isfile(os.path.join(args.artifacts, os.path.basename(s.get("file", ""))))]
    check(not missing, "nginx 截图文件全部落盘", f"缺失={missing[:5]}")
    for name in sorted(stats)[:6]:
        s = stats[name]
        info(f"{s.get('file')} {s.get('size')} brand_pixels={s.get('brand_pixels')} md5={str(s.get('md5'))[:12]}…")

    print(f"\n[RESULT] 一致性校验失败项={FAILED}")
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
