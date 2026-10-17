#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CarbonBoo 设计令牌 → 色板图 → 视觉模型判读（「判图腿」的可复现证据）。

职责：
  ① 从仓库**真实源** `app/entry/src/main/ets/util/AppTheme.ets` 里解析 §3.1 的颜色令牌。
     **不手抄常数表**：源码改了，这里解析出来的东西就跟着改；解析结果全部回显到 stdout，
     一眼能看出「这张图用的是 AppTheme 的真实色值」。
  ② 用这些真实色值渲染一张色板 PNG：每色一块，块上标注色名 / 十六进制 / 用途。
     背景直接用令牌 `COLOR_BG`（不是随便挑一个底色），让「背景色」这一问有据可依。
  ③ 从凭据库 `.dsh/.credentials.yaml → refs.ARK_API_KEY` 取 key（**不回显、不落盘**，
     只打印前缀与长度），调 ARK coding 端点让视觉模型判读，把**原始响应**打到 stdout。
  ④ 按「背景色 + 至少 N 个色块的名称/色值」判 PASS/FAIL：非 0 退出即失败。
     失败时一定打印原因（不静默通过）。

边界（重要，别把这条腿当截图腿）：
  本工具验的是**设计令牌色板**，不是**页面截图外观**。它能证明的是「视觉模型通道可用，
  且能把我们自己的设计令牌如实读出来」；它**不能**替代 18 个页面的视觉走查 ——
  截图腿缺 hdc / 模拟器 / Previewer（glibc 2.43），至今一张页面截图都产生不出来。
  两条腿不可互相顶替。

用法（一般由同目录 run.sh 调用）：
    python3 vision_check.py --apptheme <AppTheme.ets> [--outdir DIR] [--keep]
"""

from __future__ import annotations

import argparse
import atexit
import base64
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request

# ---------------------------------------------------------------- 常量（都可用参数覆盖）

DEFAULT_ENDPOINT = "https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions"
DEFAULT_MODEL = "deepseek-v4-1-flash-260910"
DEFAULT_CREDS = "/mnt/c/Users/Administrator/.dsh/.credentials.yaml"
DEFAULT_KEY_REF = "ARK_API_KEY"
REQUEST_TIMEOUT = 120

# 判定门槛：至少要有多少个色块被模型正确说出（名称或十六进制任一命中即算）
DEFAULT_MIN_MATCHED = 8


# ---------------------------------------------------------------- 工具函数


def to_native(path):
    """把 WSL 路径翻成 Windows 原生路径（用 Windows python 时 PIL 才有）。

    /mnt/c/Users/x -> C:/Users/x；非 nt 平台原样返回。
    """
    if os.name != "nt":
        return path
    m = re.match(r"^/mnt/([a-zA-Z])/(.*)$", path)
    if m:
        return m.group(1).upper() + ":/" + m.group(2)
    return path


_CLEANUP = {"dir": None}


def _cleanup_tmpdir():
    """失败路径也要收拾产物目录（否则每次失败都在临时目录里留一张 PNG）。"""
    d = _CLEANUP.get("dir")
    if not d:
        return
    try:
        shutil.rmtree(to_native(d), ignore_errors=True)
    except Exception:
        pass


def die(msg, code):
    print("错误：" + msg, file=sys.stderr)
    print("RUN_RESULT=ERROR", file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------- ① 解析 AppTheme.ets

TOKEN_RE = re.compile(
    r"static\s+readonly\s+((?:COLOR|CAT)_[A-Z0-9_]+)\s*:\s*string\s*=\s*'(#[0-9A-Fa-f]{6})'"
)
DOC_RE = re.compile(r"/\*\*((?:(?!\*/).)*)\*/\s*$", re.S)


def _clean_doc(doc):
    """把 `/** ... */` 的内容压成一行用途说明（吃掉 `*` 与前导空格）。"""
    lines = []
    for raw in doc.splitlines():
        line = raw.strip()
        if line.startswith("*"):
            line = line[1:].strip()
        if line:
            lines.append(line)
    return " ".join(lines).strip()


def parse_apptheme(path, want_section="3.1"):
    """返回 [(name, '#RRGGBB', purpose)]，顺序即源码顺序。

    只取 `§3.1 颜色` 段里的 `string = '#......'` 令牌；尺寸/字体/其它段一律不碰。
    """
    with open(to_native(path), encoding="utf-8") as fh:
        text = fh.read()

    tokens = []
    for m in TOKEN_RE.finditer(text):
        name, hexv = m.group(1), m.group(2)
        purpose = ""
        doc = DOC_RE.search(text[: m.start()])
        if doc:
            purpose = _clean_doc(doc.group(1))
        tokens.append((name, hexv.upper(), purpose))

    # 去重（同名只留第一次出现），保持顺序
    seen = set()
    uniq = []
    for name, hexv, purpose in tokens:
        if name in seen:
            continue
        seen.add(name)
        uniq.append((name, hexv, purpose))

    if not uniq:
        die(
            "从 %s 里一个颜色令牌都没解析出来（源码结构变了？检查 TOKEN_RE 与 §%s 段）"
            % (path, want_section),
            2,
        )
    return uniq


# ---------------------------------------------------------------- ② 生成色板图


def _luminance(hexv):
    r, g, b = (int(hexv[i : i + 2], 16) / 255.0 for i in (1, 3, 5))

    def lin(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def _text_color(bg_hex):
    return (17, 17, 17) if _luminance(bg_hex) > 0.45 else (255, 255, 255)


def _load_font(size, cjk=False):
    from PIL import ImageFont

    cands = []
    if cjk:
        cands += ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"]
        cands += ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
    else:
        cands += ["C:/Windows/Fonts/arial.ttf", "C:/Windows/Fonts/consola.ttf"]
        cands += [
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        ]
    for c in cands:
        if os.path.exists(to_native(c)):
            try:
                return ImageFont.truetype(to_native(c), size)
            except Exception:
                continue
    try:
        return ImageFont.load_default(size)
    except Exception:
        return ImageFont.load_default()


def render_palette(tokens, out_png, bg_hex="#FFFFFF"):
    from PIL import Image, ImageDraw

    cols = 4
    pad, gap = 36, 18
    cell_w, cell_h = 330, 190
    rows = (len(tokens) + cols - 1) // cols
    title_h = 92

    width = pad * 2 + cols * cell_w + (cols - 1) * gap
    height = title_h + pad + rows * cell_h + (rows - 1) * gap + pad

    img = Image.new("RGB", (width, height), tuple(int(bg_hex[i : i + 2], 16) for i in (1, 3, 5)))
    d = ImageDraw.Draw(img)

    f_title = _load_font(24)
    f_name = _load_font(21)
    f_hex = _load_font(26)
    f_use = _load_font(14, cjk=True)

    title_col = _text_color(bg_hex)
    d.text(
        (pad, 26),
        "CarbonBoo design tokens palette  ·  %d colours  ·  source: AppTheme.ets" % len(tokens),
        fill=title_col,
        font=f_title,
    )
    d.text(
        (pad, 58),
        "grid %dx%d  ·  page background = %s" % (rows, cols, bg_hex),
        fill=title_col,
        font=f_use,
    )

    for idx, (name, hexv, purpose) in enumerate(tokens):
        r, c = divmod(idx, cols)
        x = pad + c * (cell_w + gap)
        y = title_h + pad + r * (cell_h + gap)
        fill = tuple(int(hexv[i : i + 2], 16) for i in (1, 3, 5))
        d.rectangle([x, y, x + cell_w, y + cell_h], fill=fill, outline=(90, 90, 90))
        tc = _text_color(hexv)
        d.text((x + 14, y + 14), name, fill=tc, font=f_name)
        d.text((x + 14, y + 48), hexv, fill=tc, font=f_hex)
        if purpose:
            label = purpose if len(purpose) <= 30 else purpose[:29] + "…"
            d.text((x + 14, y + 92), label, fill=tc, font=f_use)
        d.text((x + 14, y + cell_h - 30), "#%02d  row %d col %d" % (idx + 1, r + 1, c + 1), fill=tc, font=f_use)

    img.save(to_native(out_png), "PNG")
    return out_png, (rows, cols)


def verify_palette_pixels(tokens, png_path, rows_cols):
    """自检：渲出来的每个色块**像素值**必须等于解析到的令牌色值。

    这条自检把「渲染器自己漂了」这类假绿挡在外面 —— 模型判读用的是同一张图，
    若图里颜色和令牌对不上，整个证据就无效。返回 (ok, 明细 list)。
    """
    from PIL import Image

    cols = rows_cols[1]
    pad, gap, cell_w, cell_h, title_h = 36, 18, 330, 190, 92
    img = Image.open(to_native(png_path)).convert("RGB")
    details, ok = [], True
    for idx, (name, hexv, _p) in enumerate(tokens):
        r, c = divmod(idx, cols)
        x = pad + c * (cell_w + gap) + 5
        y = title_h + pad + r * (cell_h + gap) + cell_h - 5
        got = img.getpixel((x, y))
        exp = tuple(int(hexv[i : i + 2], 16) for i in (1, 3, 5))
        same = got == exp
        ok = ok and same
        details.append((name, hexv, exp, got, same))
    return ok, details


# ---------------------------------------------------------------- ③ 取 key（不落盘不回显）


def read_key(creds_path, ref):
    """从凭据库取 key。先试 yaml（若装了），否则用行解析 —— 两种都只做读取。"""
    native = to_native(creds_path)
    if not os.path.exists(native):
        die("凭据库不存在：%s（key 应在此文件的 refs.%s）" % (creds_path, ref), 4)
    raw = open(native, encoding="utf-8", errors="replace").read()
    key = None
    try:
        import yaml  # type: ignore

        data = yaml.safe_load(raw) or {}
        key = (data.get("refs") or {}).get(ref)
    except Exception:
        key = None
    if not key:
        # 行解析：进入 `refs:` 块后找两条空格缩进的 `KEY: value`，遇到顶格键即结束
        in_refs = False
        for line in raw.splitlines():
            if re.match(r"^refs:\s*$", line):
                in_refs = True
                continue
            if in_refs:
                if re.match(r"^\S", line):
                    break
                m = re.match(r"^\s+%s:\s*(\S+)\s*$" % re.escape(ref), line)
                if m:
                    key = m.group(1)
                    break
    if not key:
        die("凭据库 %s 里没有 refs.%s（或值为空）" % (creds_path, ref), 4)
    key = str(key).strip().strip("'\"")
    if len(key) < 8:
        die("refs.%s 取到的值过短（长度 %d），疑似占位符" % (ref, len(key)), 4)
    return key


def mask(key):
    return "%s…%s (len=%d)" % (key[:6], key[-2:], len(key))


# ---------------------------------------------------------------- ④ 调视觉模型


PROMPT = """这张图是由 CarbonBoo 的设计令牌（AppTheme.ets）自动生成的**色板图**，每个矩形块是一种设计令牌颜色，块上写着色名、十六进制色值和用途。

请严格按下面 3 点回答，不要只说「我看到一张色板图」：
1) 最外层**背景**是什么颜色？请给出近似十六进制值与明暗描述（例如「#F5F7F6，很浅的近白」）。
2) 色块按**几行几列**排布？一共多少个色块？
3) 按**从上到下、从左到右**的顺序，逐个列出每个色块的**色名**与**十六进制色值**（能列多少列多少，不要编造图里没有的色值）。"""


def call_vision(endpoint, model, key, image_png, prompt):
    with open(to_native(image_png), "rb") as fh:
        b64 = base64.b64encode(fh.read()).decode("ascii")
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
                ],
            }
        ],
        "temperature": 0,
    }
    req = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
        method="POST",
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            status = resp.status
            body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        print("HTTP_STATUS = %d" % exc.code)
        print("RAW_BODY = %s" % body)
        die(
            "端点返回 HTTP %d（不是 200）：先确认 key 有效/未过期、model 名与端点路径对不对。原文见上"
            % exc.code,
            3,
        )
    except urllib.error.URLError as exc:
        die(
            "连不上视觉端点 %s（%s）—— 本机可能无出网/需要代理；请检查网络后重跑"
            % (endpoint, exc.reason),
            3,
        )
    except Exception as exc:  # 超时等
        die("调用视觉端点失败：%s: %s" % (type(exc).__name__, exc), 3)
    return status, body, time.time() - t0


# ---------------------------------------------------------------- 判定


LIGHT_WORDS = ("浅", "近白", "灰白", "白", "亮", "淡")
DARK_WORDS = ("深色", "深灰", "深绿", "暗", "黑色", "黑底", "深蓝")
REFUSALS = ("我无法", "无法查看", "不能查看", "看不到图", "i cannot", "i can't", "sorry")


def judge(answer, tokens, bg_hex, min_matched):
    """返回 (ok, reasons, matched, missing)。"""
    low = answer.lower()
    reasons = []

    if any(r in low for r in REFUSALS):
        return False, ["模型答「无法查看图片」一类拒答，判读未发生"], [], [t[0] for t in tokens]

    norm = low.replace("#", "").replace(" ", "")
    matched, missing = [], []
    for name, hexv, _purpose in tokens:
        hexn = hexv.lstrip("#").lower()
        if name.lower() in low or hexn in norm:
            matched.append(name)
        else:
            missing.append(name)
    reasons.append("色块命中 %d/%d（名称或十六进制任一命中）" % (len(matched), len(tokens)))

    if len(matched) < min_matched:
        reasons.append("低于门槛：至少需要 %d 个色块被正确说出" % min_matched)

    # 背景判定：只看含「背景」的那几句，要求出现「浅/白/亮」一类，且不出现「深/暗/黑」
    bg_ok = False
    for sent in re.split(r"[。；;\n]", answer):
        if "背景" in sent:
            if any(w in sent for w in LIGHT_WORDS) and not any(w in sent for w in DARK_WORDS):
                bg_ok = True
            break
    bg_hex_seen = bg_hex.lstrip("#").lower() in norm
    reasons.append(
        "背景色：%s（令牌 %s；答案%s给出该十六进制）"
        % ("描述为浅色 ✓" if bg_ok else "未描述为浅色 ✗", bg_hex, "有" if bg_hex_seen else "未")
    )

    ok = bg_ok and len(matched) >= min_matched
    return ok, reasons, matched, missing


# ---------------------------------------------------------------- main


def _force_utf8_stdout():
    """Windows 上默认 GBK/ cp936 会把中文与 ✓ 打成乱码或抛 UnicodeEncodeError。

    本工具的输出要能直接贴进报告，所以统一按 UTF-8 写 stdout/stderr。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def main(argv=None):
    _force_utf8_stdout()
    ap = argparse.ArgumentParser(description="CarbonBoo 设计令牌色板 → 视觉模型判读")
    ap.add_argument("--apptheme", required=True, help="app/entry/src/main/ets/util/AppTheme.ets 路径")
    ap.add_argument("--outdir", default=None, help="产物目录（默认建在系统临时目录）")
    ap.add_argument("--keep", action="store_true", help="保留产物目录（默认运行结束后删除）")
    ap.add_argument("--endpoint", default=os.environ.get("VISION_ENDPOINT", DEFAULT_ENDPOINT))
    ap.add_argument("--model", default=os.environ.get("VISION_MODEL", DEFAULT_MODEL))
    ap.add_argument("--creds", default=os.environ.get("VISION_CREDS", DEFAULT_CREDS))
    ap.add_argument("--key-ref", default=os.environ.get("VISION_KEY_REF", DEFAULT_KEY_REF))
    ap.add_argument("--min-matched", type=int, default=DEFAULT_MIN_MATCHED)
    args = ap.parse_args(argv)

    print("=== ① 解析真实设计令牌（源：%s）===" % args.apptheme)
    tokens = parse_apptheme(args.apptheme)
    for i, (name, hexv, purpose) in enumerate(tokens, 1):
        print("  %2d. %-22s %s  %s" % (i, name, hexv, purpose or "（源码无用途注释）"))
    print("  共解析到 %d 个颜色令牌" % len(tokens))

    bg = next((h for n, h, _p in tokens if n == "COLOR_BG"), "#FFFFFF")
    outdir = args.outdir or tempfile.mkdtemp(prefix="carbonboo_vision_")
    os.makedirs(to_native(outdir), exist_ok=True)
    if not args.keep:
        _CLEANUP["dir"] = outdir
        atexit.register(_cleanup_tmpdir)
    png = os.path.join(outdir, "tokens_palette.png")

    print("=== ② 渲染色板图（背景用令牌 COLOR_BG=%s）===" % bg)
    png_path, (rows, cols) = render_palette(tokens, png, bg_hex=bg)
    size = os.path.getsize(to_native(png_path))
    print("  PNG = %s  (%d bytes, %dx%d 网格)" % (png_path, size, rows, cols))
    px_ok, px_details = verify_palette_pixels(tokens, png_path, (rows, cols))
    print("  自检：色块像素 == 令牌色值  %d/%d %s"
          % (sum(1 for d in px_details if d[4]), len(px_details), "✓" if px_ok else "✗"))
    if not px_ok:
        bad = [d for d in px_details if not d[4]][:5]
        for name, hexv, exp, got, _s in bad:
            print("    不一致：%s %s 期望 %s 实得 %s" % (name, hexv, exp, got), file=sys.stderr)
        die("渲染色板与解析到的令牌不一致（渲染器漂了），证据无效", 2)

    print("=== ③ 取 key（凭据库 %s → refs.%s）===" % (args.creds, args.key_ref))
    key = read_key(args.creds, args.key_ref)
    print("  key = %s  （不落盘、不回显明文）" % mask(key))
    env_key = os.environ.get("ARK_API_KEY", "")
    print("  环境变量 ARK_API_KEY = %s" % ("<非空，但本工具不用它>" if env_key else "<未设置>"))

    print("=== ④ 调视觉模型判读（model=%s）===" % args.model)
    print("  endpoint = %s" % args.endpoint)
    status, body, elapsed = call_vision(args.endpoint, args.model, key, png_path, PROMPT)
    print("  HTTP_STATUS = %d   elapsed = %.1fs" % (status, elapsed))
    print("--- RAW_RESPONSE_BEGIN ---")
    print(body)
    print("--- RAW_RESPONSE_END ---")

    try:
        parsed = json.loads(body)
        answer = parsed["choices"][0]["message"].get("content") or ""
    except Exception as exc:
        die("响应不是预期的 chat.completion 结构（%s），无法判定" % exc, 3)
    if not answer.strip():
        die("模型 content 为空（可能被内容策略拦截或只返回了 reasoning），无法判定", 3)
    print("--- MODEL_ANSWER_BEGIN ---")
    print(answer)
    print("--- MODEL_ANSWER_END ---")

    print("=== ⑤ 判定 ===")
    ok, reasons, matched, missing = judge(answer, tokens, bg, args.min_matched)
    for r in reasons:
        print("  - " + r)
    print("  命中色块：%s" % (", ".join(matched) if matched else "（无）"))
    if missing:
        print("  未命中：%s" % ", ".join(missing))
    print("  PNG 保留：%s" % png_path if args.keep else "  PNG 保留：不保留（加 --keep 或 VISION_CHECK_KEEP=1 可留下）")

    if not args.keep:
        _CLEANUP["dir"] = None
        try:
            shutil.rmtree(to_native(outdir), ignore_errors=True)
        except Exception:
            pass

    if ok:
        print("RESULT: PASS —— 视觉模型通道可用，且判读了 AppTheme 真实色板（背景 + %d/%d 色块）" % (len(matched), len(tokens)))
        return 0
    print("RESULT: FAIL —— 判读未达门槛（背景=%s，色块 %d/%d < %d）" % ("ok" if "描述为浅色 ✓" in " ".join(reasons) else "bad", len(matched), len(tokens), args.min_matched))
    return 1


if __name__ == "__main__":
    sys.exit(main())
