#!/usr/bin/env bash
# 离线 L1 执行器入口 —— 一条命令完成「转译 + 执行 + 基准复算」。
#
# 用法：
#   bash tests/tools/l1_offline/run_tests.sh              # 全部用例
#   L1_VERBOSE=1 bash tests/tools/l1_offline/run_tests.sh # 附带 hilog 与失败堆栈
#
# 退出码：0 = 全通过；1 = 有用例失败或基准不一致；2 = 环境/转译问题。
#
# 环境要求（本机实测在本文件头说明，避免"在我机器上能跑"）：
#   - Node ≥ 22.5（需要内置 `node:sqlite`；**SDK 自带的 node 是 18，没有这个模块**，因此脚本会自动挑选）
#   - esbuild：默认 ~/harmony-toolchain/esbuild/bin/esbuild，可用 ESBUILD=... 覆盖
#
# 本脚本不联网、不 npm install、不写仓库（中间产物只落系统临时目录）。

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

has_sqlite() {
  "$1" -e "require('node:sqlite')" >/dev/null 2>&1
}

pick_node() {
  if [ -n "${NODE:-}" ]; then
    if has_sqlite "$NODE"; then
      printf '%s' "$NODE"
      return 0
    fi
    echo "NODE=$NODE 不支持 node:sqlite（需要 Node ≥ 22.5）" >&2
    return 1
  fi
  # 候选顺序：PATH 上的 node → 常见绝对路径 → SDK 自带 node（18，仅用于给出准确报错）
  local candidates=()
  if command -v node >/dev/null 2>&1; then
    candidates+=("$(command -v node)")
  fi
  candidates+=("/usr/bin/node" "/usr/local/bin/node")
  local c
  for c in "${candidates[@]}"; do
    if [ -x "$c" ] && has_sqlite "$c"; then
      printf '%s' "$c"
      return 0
    fi
  done
  echo "找不到支持 node:sqlite 的 Node（需要 ≥ 22.5）。请设 NODE=/path/to/node22。" >&2
  return 2
}

NODE_BIN="$(pick_node)" || exit 2

exec "$NODE_BIN" --enable-source-maps "$HERE/runners/offline_run.mjs" "$@"
