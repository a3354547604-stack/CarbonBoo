#!/usr/bin/env bash
# 判图腿（视觉模型通道）的可复现入口 —— 设计令牌色板 → 视觉模型判读。
#
# 它做什么：从仓库真实源 app/entry/src/main/ets/util/AppTheme.ets 解析颜色令牌 →
# 渲染色板 PNG → 调 ARK 视觉模型判读 → 打印原始响应 → 给 PASS/FAIL。
#
# 它**不**做什么：不产生任何页面截图（截图腿缺 hdc/模拟器/Previewer，仍不可用），
# 因此**不能**替代 18 页视觉走查。详见同目录 README.md。
#
# 退出码：0 = PASS；1 = 判读未达门槛；2 = 环境不满足（无 Pillow / 缺 AppTheme.ets）；
#         3 = 网络或端点错误；4 = 取不到 key。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
APP_THEME="$REPO_ROOT/app/entry/src/main/ets/util/AppTheme.ets"
SCRIPT="$HERE/vision_check.py"

if [[ ! -f "$APP_THEME" ]]; then
  echo "错误：找不到设计令牌源 $APP_THEME（本工具必须从真实源码解析，不内置常数表）" >&2
  echo "RUN_EXIT=2"
  exit 2
fi
if [[ ! -f "$SCRIPT" ]]; then
  echo "错误：缺少 $SCRIPT" >&2
  echo "RUN_EXIT=2"
  exit 2
fi

# --- 选一个**带 Pillow** 的解释器：Windows python 才有 PIL，WSL python3 只有 yaml。
#     顺序可以用 VISION_PYTHON 覆盖。
PICKED=""
CANDIDATES=()
[[ -n "${VISION_PYTHON:-}" ]] && CANDIDATES+=("$VISION_PYTHON")
CANDIDATES+=("/mnt/c/Users/Administrator/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe")
for c in python3 python; do
  p="$(command -v "$c" 2>/dev/null || true)"
  [[ -n "$p" ]] && CANDIDATES+=("$p")
done
TRIED=()
for c in "${CANDIDATES[@]}"; do
  [[ -x "$c" || -f "$c" ]] || continue
  TRIED+=("$c")
  if "$c" -c "import PIL" >/dev/null 2>&1; then
    PICKED="$c"
    break
  fi
done

if [[ -z "$PICKED" ]]; then
  echo "错误：没找到带 Pillow(PIL) 的 python 解释器 —— 本工具要画色板 PNG。" >&2
  echo "  试过：${TRIED[*]:-（无可执行候选）}" >&2
  echo "  办法：装 Pillow，或用 VISION_PYTHON=/path/to/python 指定一个带 PIL 的解释器。" >&2
  echo "RUN_EXIT=2"
  exit 2
fi

# 用 Windows python 时必须把 WSL 路径翻成 Windows 路径（含脚本自身）
conv() {
  case "$PICKED" in
    *.exe)
      if command -v wslpath >/dev/null 2>&1; then wslpath -w "$1" 2>/dev/null || printf '%s\n' "$1";
      else printf '%s\n' "$1"; fi
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

echo "解释器 = $PICKED（$( ("$PICKED" -c 'import sys;print(sys.version.split()[0])') 2>/dev/null || echo '?' ) )"
echo "令牌源 = $APP_THEME"
echo

ARGS=(--apptheme "$(conv "$APP_THEME")")
[[ -n "${VISION_ENDPOINT:-}" ]] && ARGS+=(--endpoint "$VISION_ENDPOINT")
[[ -n "${VISION_MODEL:-}" ]] && ARGS+=(--model "$VISION_MODEL")
[[ -n "${VISION_CREDS:-}" ]] && ARGS+=(--creds "$VISION_CREDS")
[[ -n "${VISION_KEY_REF:-}" ]] && ARGS+=(--key-ref "$VISION_KEY_REF")
[[ -n "${VISION_MIN_MATCHED:-}" ]] && ARGS+=(--min-matched "$VISION_MIN_MATCHED")
[[ -n "${VISION_CHECK_OUTDIR:-}" ]] && ARGS+=(--outdir "$(conv "$VISION_CHECK_OUTDIR")")
[[ -n "${VISION_CHECK_KEEP:-}" ]] && ARGS+=(--keep)

"$PICKED" "$(conv "$SCRIPT")" "${ARGS[@]}"
RUN_EXIT=$?
echo "RUN_EXIT=$RUN_EXIT"
exit $RUN_EXIT
