#!/usr/bin/env bash
# CarbonBoo 一键复现编排（repro）
#
# 职责：在**一份干净副本**里按序调用仓库自带的门禁工具，逐条记 PASS / FAIL / ENV-SKIP 与退出码，
#       最后给一行总结。本脚本**只做编排**：不内联任何算法、期望值或断言 —— 每条判定都来自
#       被调工具自己的退出码（`tests/tools/l1_offline/*`、`tests/tools/check_l0.py`、
#       `server/tests/`、`hvigorw`）。
#
# 退出码：0 = 全部 PASS（可含 ENV-SKIP 混合）；1 = 有 FAIL；2 = 全部 ENV-SKIP。
#
# 环境变量（都可缺省）：
#   REPRO_LOG_DIR   日志目录（缺省 mktemp -d）
#   REPRO_KEEP=1    跑完保留日志目录（缺省保留路径会被打印）
#   REPRO_ONLY=l0|l1|l1test|pytest|hap   只跑其中一条（排障用）
#   ESBUILD / NODE  透传给 l1_offline（见 tests/tools/l1_offline/run.sh 的说明）
#   MYSQL_*         透传给 server/tests（见 server/README.md §8；也可用 server/.env）
#   CARBONBOO_TEST_DB  测试库名（缺省 carbonboo_test_repro）
#
# 用法：bash tests/tools/repro/run.sh          # 在副本根目录或任意位置均可（脚本自己定位仓库根）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT" || { echo "REPRO: 无法进入仓库根 $ROOT"; exit 2; }

LOG_DIR="${REPRO_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/cbrepro-XXXXXX")}"
mkdir -p "$LOG_DIR" || exit 2
ONLY="${REPRO_ONLY:-}"

PASS_N=0; FAIL_N=0; SKIP_N=0
declare -a ROWS=()

say() { printf '%s\n' "$*"; }

record() { # record <PASS|FAIL|ENV-SKIP> <name> <exit-code> <log-path>
  local st="$1" name="$2" code="$3" log="$4"
  case "$st" in
    PASS)     PASS_N=$((PASS_N + 1)) ;;
    FAIL)     FAIL_N=$((FAIL_N + 1)) ;;
    ENV-SKIP) SKIP_N=$((SKIP_N + 1)) ;;
  esac
  ROWS+=("$(printf '%-9s %-10s exit=%-3s %s' "$st" "$name" "$code" "$log")")
  say "[$st] $name (exit=$code)"
}

selected() { # selected <gate-key>：REPRO_ONLY 过滤
  [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]
}

# ---------------------------------------------------------------- 0. 现场快照
say "== CarbonBoo 复现编排 =="
say "仓库根 : $ROOT"
say "日志目录 : $LOG_DIR"
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  say "git HEAD : $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo '(无法读取)')"
  DIRTY="$(git -C "$ROOT" status --short 2>/dev/null | wc -l | tr -d ' ')"
  say "未提交改动行数 : $DIRTY（0 表示干净副本）"
else
  say "git      : 本副本无 .git（仅解包的字节），跳过 HEAD/status 快照"
fi

# ---------------------------------------------------------------- 1. L0 文档与数值一致性
if selected l0; then
  LOG="$LOG_DIR/l0.log"
  python3 tests/tools/check_l0.py --strict >"$LOG" 2>&1
  CODE=$?
  case "$CODE" in
    0) record PASS l0 "$CODE" "$LOG" ;;
    *) record FAIL l0 "$CODE" "$LOG" ;;
  esac
fi

# ---------------------------------------------------------------- 2. 离线 L1：纯逻辑复算（run.sh）
if selected l1; then
  LOG="$LOG_DIR/l1.log"
  bash tests/tools/l1_offline/run.sh >"$LOG" 2>&1
  CODE=$?
  case "$CODE" in
    0) record PASS l1 "$CODE" "$LOG" ;;        # 工具约定：0=全过
    2) record ENV-SKIP l1 "$CODE" "$LOG" ;;    # 工具约定：2=环境不可达（缺 esbuild/node）
    *) record FAIL l1 "$CODE" "$LOG" ;;
  esac
fi

# ---------------------------------------------------------------- 3. 离线 L1：hypium 用例（run_tests.sh）
if selected l1test; then
  LOG="$LOG_DIR/l1test.log"
  bash tests/tools/l1_offline/run_tests.sh >"$LOG" 2>&1
  CODE=$?
  case "$CODE" in
    0) record PASS l1test "$CODE" "$LOG" ;;
    2) record ENV-SKIP l1test "$CODE" "$LOG" ;;
    *) record FAIL l1test "$CODE" "$LOG" ;;
  esac
fi

# ---------------------------------------------------------------- 4. L3：服务端 pytest（真实 MySQL）
# 环境前提（文档出处：server/README.md §8、docs/toolchain/server-env.md）：
#   ① server/.venv/bin/python（首次需 `python3.11 -m venv .venv && .venv/bin/pip install -r requirements.txt`，要网络）
#   ② 可达的 MySQL 8（本机为容器 carbonboo-mysql，127.0.0.1:13307）+ 凭据（.env 或 MYSQL_* 环境变量）
if selected pytest; then
  LOG="$LOG_DIR/pytest.log"
  PY="server/.venv/bin/python"
  MYSQL_HOST_E="${MYSQL_HOST:-}"; MYSQL_PORT_E="${MYSQL_PORT:-}"
  if [ -f server/.env ]; then
    [ -n "$MYSQL_HOST_E" ] || MYSQL_HOST_E="$(grep -E '^MYSQL_HOST=' server/.env | head -1 | cut -d= -f2-)"
    [ -n "$MYSQL_PORT_E" ] || MYSQL_PORT_E="$(grep -E '^MYSQL_PORT=' server/.env | head -1 | cut -d= -f2-)"
    for k in MYSQL_USER MYSQL_PASSWORD MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD; do
      eval "v=\${$k:-}"
      if [ -z "$v" ]; then
        eval "export $k=\"\$(grep -E '^$k=' server/.env | head -1 | cut -d= -f2-)\""
      fi
    done
  fi
  MYSQL_HOST_E="${MYSQL_HOST_E:-127.0.0.1}"
  MYSQL_PORT_E="${MYSQL_PORT_E:-13307}"   # docs/toolchain/server-env.md §1：本项目实测用 13307

  DB_UP=0
  if (exec 3<>"/dev/tcp/$MYSQL_HOST_E/$MYSQL_PORT_E") 2>/dev/null; then DB_UP=1; fi

  if [ -z "${MYSQL_PASSWORD:-}" ]; then
    { say "缺少 MySQL 凭据：server/.env 不存在，且 MYSQL_PASSWORD 未设置。"
      say "按 server/README.md §8 的「没有 .env」形式传入环境变量："
      say "  MYSQL_HOST=127.0.0.1 MYSQL_PORT=13307 MYSQL_USER=... MYSQL_PASSWORD=... \\"
      say "  MYSQL_ADMIN_USER=root MYSQL_ADMIN_PASSWORD=... bash tests/tools/repro/run.sh"; } >"$LOG" 2>&1
    record ENV-SKIP pytest 2 "$LOG"
  elif [ ! -x "$PY" ]; then
    { say "server/.venv/bin/python 不存在。按 server/README.md §2 建："
      say "  cd server && python3.11 -m venv .venv && .venv/bin/pip install -r requirements.txt -i https://mirrors.aliyun.com/pypi/simple/"
      say "（首次需要网络：PyPI 镜像）"; } >"$LOG" 2>&1
    record ENV-SKIP pytest 2 "$LOG"
  elif [ "$DB_UP" != "1" ]; then
    { say "MySQL 不可达：$MYSQL_HOST_E:$MYSQL_PORT_E"
      say "按 server/README.md §8 的容器方式起库，或用 MYSQL_* 指向已有实例。"; } >"$LOG" 2>&1
    record ENV-SKIP pytest 2 "$LOG"
  else
    # 必须 cd 到 server/ 再跑：pytest 的 tests/ 在 server/ 下（在仓库根跑会 exit 5 = no tests ran）
    ( cd server && \
      MYSQL_HOST="$MYSQL_HOST_E" MYSQL_PORT="$MYSQL_PORT_E" \
      CARBONBOO_TEST_DB="${CARBONBOO_TEST_DB:-carbonboo_test_repro}" \
        ./.venv/bin/python -m pytest tests/ -q ) >"$LOG" 2>&1
    CODE=$?
    case "$CODE" in
      0) record PASS pytest "$CODE" "$LOG" ;;
      *) record FAIL pytest "$CODE" "$LOG" ;;
    esac
  fi
fi

# ---------------------------------------------------------------- 5. 鸿蒙构建（assembleHap）
# 环境前提（文档出处：docs/toolchain/harmony-cli-build.md §1/§3）：
#   ① 命令行工具链装在 ~/harmony-toolchain/（仓库外），`source ~/harmony-toolchain/env.sh` 后 hvigorw 才在 PATH
#   ② app/hvigor/hvigor-config.json5 里两条 file: 绝对路径必须指向该工具链（换机器要改，见文件内注释）
if selected hap; then
  LOG="$LOG_DIR/hap.log"
  ENV_SH="${HARMONY_ENV_SH:-$HOME/harmony-toolchain/env.sh}"
  if [ ! -f "$ENV_SH" ]; then
    { say "缺少工具链入口：$ENV_SH"
      say "按 docs/toolchain/harmony-cli-build.md §1 安装 CLT/SDK/JDK，并让 env.sh 就位。"; } >"$LOG" 2>&1
    record ENV-SKIP hap 2 "$LOG"
  else
    ( set +u
      # shellcheck disable=SC1090
      source "$ENV_SH" >/dev/null 2>&1
      [ -n "${DEVECO_SDK_HOME:-}" ] && export OHOS_BASE_SDK_HOME="$DEVECO_SDK_HOME"
      if ! command -v hvigorw >/dev/null 2>&1; then
        say "env.sh 已 source，但 hvigorw 不在 PATH（docs/toolchain/harmony-cli-build.md §3）"
        exit 2
      fi
      cd app && hvigorw --no-daemon assembleHap
    ) >"$LOG" 2>&1
    CODE=$?
    case "$CODE" in
      0) record PASS hap "$CODE" "$LOG" ;;
      2) record ENV-SKIP hap "$CODE" "$LOG" ;;
      *) record FAIL hap "$CODE" "$LOG" ;;
    esac
  fi
fi

# ---------------------------------------------------------------- 6. 总结（一行）
say ""
say "---- 逐条 ----"
for row in "${ROWS[@]}"; do say "$row"; done
say ""
TOTAL=$((PASS_N + FAIL_N + SKIP_N))
say "REPRO: PASS=$PASS_N FAIL=$FAIL_N ENV-SKIP=$SKIP_N TOTAL=$TOTAL log_dir=$LOG_DIR"

if [ "${REPRO_KEEP:-0}" != "1" ]; then
  say "（日志目录默认保留，便于取证；如需清理：rm -rf \"$LOG_DIR\"）"
fi

if [ "$FAIL_N" -gt 0 ]; then exit 1; fi
if [ "$TOTAL" -eq 0 ] || [ "$PASS_N" -eq 0 ]; then exit 2; fi
exit 0
