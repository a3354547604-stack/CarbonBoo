#!/usr/bin/env bash
# 未登录 = 纯单机：两段方向相反的可执行证据（t58）。
#
# 用法：
#   bash tests/tools/offline_first/run.sh              # 两段都跑（默认）
#   OFFLINE_FIRST_ONLY=1 bash tests/tools/offline_first/run.sh   # 只跑第一段（断网）
#   OFFLINE_FIRST_ONLY=2 bash tests/tools/offline_first/run.sh   # 只跑第二段（有网）
#
# 退出码：0 = 全部断言通过；1 = 有断言失败；2 = 环境不可达（node 版本/esbuild/仓库结构）。
#
# 边界：这是**离线执行器**（esbuild 转译 + Node 垫片），不是真机 hypium，也不是 L2 端侧集成。
# 它证明的是 **Service 层**的本机优先；`pages/`、`components/` 不进转译集，界面层不在本工具范围内。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
MODE="${OFFLINE_FIRST_ONLY:-all}"

echo "── 未登录 = 纯单机（offline_first） ──"
echo "仓库根 : ${REPO}"
echo "模式   : OFFLINE_FIRST_ONLY=${MODE}"

if [[ ! -d "${REPO}/app/entry/src/main/ets/viewmodel" ]]; then
  echo "ENV: 找不到 ${REPO}/app/entry/src/main/ets/viewmodel（不在仓库根运行？）"
  exit 2
fi

NODE="${NODE:-node}"
if ! command -v "${NODE}" >/dev/null 2>&1; then
  echo "ENV: 找不到 node（可用 NODE=/path/to/node 指定）"
  exit 2
fi
if ! "${NODE}" -e 'const s = process.versions.node.split(".").map(Number); process.exit(s[0] > 22 || (s[0] === 22 && s[1] >= 5) ? 0 : 1)'; then
  echo "ENV: node ${NODE} 版本过低（需要 ≥ 22.5，才有内置 node:sqlite）"
  exit 2
fi
echo "node   : $("${NODE}" -v)（$(command -v "${NODE}")）"

mkdir -p "${HERE}/artifacts"
LOG="${HERE}/artifacts/run-$(date +%Y%m%d-%H%M%S).txt"

"${NODE}" --enable-source-maps "${HERE}/probe.mjs" 2>&1 | tee "${LOG}"
RC="${PIPESTATUS[0]}"

echo ""
echo "日志   : ${LOG}"
echo "退出码 : ${RC}（0=全过 / 1=有失败 / 2=环境）"
exit "${RC}"
