#!/usr/bin/env bash
# t61 并发/竞态端到端证据 —— 一条命令可复现
#
#   bash tests/tools/concurrency_e2e/run.sh          # 全跑
#   CONC_ONLY=s1,s5 bash tests/tools/concurrency_e2e/run.sh
#   CONC_KEEP=1 bash tests/tools/concurrency_e2e/run.sh   # 保留临时目录（取证用）
#
# 退出码：0 = 全部断言通过，且无**门禁级**发现（见下）
#         1 = 有断言失败，或有门禁级发现（CONC_STRICT_CONTRACT=1 生效时）
#         2 = 环境不可达（缺 docker / MySQL 容器 / 端口 / venv / 建库失败）
#
# 严格模式（t66 F2）：本脚本**显式导出** `CONC_STRICT_CONTRACT=1`，让「门禁级发现」真影响退出码 ——
#   门禁级 = 默认 severity ∈ blocker|high（被测代码缺陷/协议偏差，典型是 S2b 的 LWW 丢更新：
#   修复一旦回归，run.sh 必须变红，而不是打印一行 STOP 后照样 RESULT: PASS）。
#   「契约口径待裁决」类发现（S3 封顶归属、S1-note 的服务端结构差异）显式 gating=False，只报告不拦。
#
# 边界：本脚本只读 server/**、app/**，一行都不改；所有写操作只落在 `carbonboo_conc_*` 任务库。
set -uo pipefail

# t66 F2：严格模式默认开启（此处显式导出，拒绝「静默假绿」；覆盖外部传入的 0）
export CONC_STRICT_CONTRACT=1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

say() { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
fail_env() { printf '[ENV] %s\n' "$*" >&2; printf 'RESULT: ENV-UNREACHABLE\n' >&2; exit 2; }

WORK="$(mktemp -d /tmp/cbconc.XXXXXX)" || fail_env "mktemp 失败"
UVICORN_PID=""
DB_NAME=""
KEEP="${CONC_KEEP:-0}"
PORT=""

kill_uvicorn() {
  # uvicorn --workers 2 = 1 supervisor + 2 worker；SIGTERM 由 supervisor 向下传播。
  # 再补一条 pkill 兜底：round 1 实测出现过 supervisor 已退出、worker 仍占端口的情况。
  if [[ -n "${UVICORN_PID:-}" ]]; then
    kill -TERM "$UVICORN_PID" 2>/dev/null || true
    for _ in $(seq 1 60); do kill -0 "$UVICORN_PID" 2>/dev/null || break; sleep 0.2; done
    kill -KILL "$UVICORN_PID" 2>/dev/null || true
    wait "$UVICORN_PID" 2>/dev/null || true
    UVICORN_PID=""
  fi
  if [[ -n "${PORT:-}" ]]; then
    pkill -f "uvicorn app.main:app --host 127.0.0.1 --port ${PORT} " 2>/dev/null || true
    sleep 0.3
  fi
}

cleanup() {
  local rc=$?
  kill_uvicorn
  if [[ -n "$DB_NAME" ]]; then
    docker exec -i "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PASS" \
      -e "DROP DATABASE IF EXISTS \`$DB_NAME\`" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP" == "1" ]]; then
    info "保留现场：$WORK（CONC_KEEP=1）"
  else
    rm -rf "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- 0) 环境可达性
say "=== 0) 环境检查 ==="
command -v docker >/dev/null 2>&1 || fail_env "没有 docker"
CONTAINER="${CONC_CONTAINER:-carbonboo-mysql}"
docker inspect "$CONTAINER" >/dev/null 2>&1 || fail_env "容器 $CONTAINER 不存在"
[[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == "true" ]] || fail_env "容器 $CONTAINER 未运行"

ENV_FILE="$REPO/server/.env"
[[ -f "$ENV_FILE" ]] || fail_env "缺少 server/.env"
env_value() { # $1 = 键名；只回显值，不打印到日志
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -1 | sed 's/[[:space:]]*$//'
}
DB_HOST="$(env_value MYSQL_HOST)"; DB_PORT="$(env_value MYSQL_PORT)"
DB_USER="$(env_value MYSQL_USER)"; DB_PASS="$(env_value MYSQL_PASSWORD)"
ADMIN_USER="$(env_value MYSQL_ADMIN_USER)"; ADMIN_PASS="$(env_value MYSQL_ADMIN_PASSWORD)"
[[ -n "$DB_HOST" && -n "$DB_PORT" && -n "$DB_USER" ]] || fail_env "server/.env 缺 MYSQL_* 键"
[[ -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]] || fail_env "server/.env 缺 MYSQL_ADMIN_* 键（建库/清理需要）"
info "MySQL = ${DB_HOST}:${DB_PORT}  用户 = ${DB_USER}（口令不回显）"

timeout 5 bash -c "</dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null || fail_env "MySQL ${DB_HOST}:${DB_PORT} 连不上"
PY_BIN="$REPO/server/.venv/bin/python"
[[ -x "$PY_BIN" ]] || fail_env "缺少 server/.venv/bin/python"
"$PY_BIN" -c 'import httpx, pymysql' 2>/dev/null || fail_env "venv 缺 httpx / pymysql"

# 端口：随机挑一个空闲的（避开 8031/8041/18099 等既有占用）
for _ in $(seq 1 40); do
  PORT=$(( (RANDOM % 400) + 18300 ))
  if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; then break; fi
  PORT=""
done
[[ -n "$PORT" ]] || fail_env "找不到空闲端口"
info "uvicorn 端口 = ${PORT}"

# ---------------------------------------------------------------- 1) 任务专属库
say; say "=== 1) 建任务专属库并灌 schema + seed ==="
DB_NAME="carbonboo_conc_$(head -c 6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 6)"
[[ "$DB_NAME" == carbonboo_conc_* ]] || fail_env "库名生成失败"
info "库名 = ${DB_NAME}（跑完 drop；不碰生产库 carbonboo）"

docker exec -i "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PASS" \
  -e "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci" \
  || fail_env "建库失败"

# schema.sql / seed.sql 里的库名是生产库名，这里**只在管道里**替换成任务库（仓库文件一字不改）
"$PY_BIN" - "$DB_NAME" > "$WORK/schema.sql" <<'PY'
import re, sys
db = sys.argv[1]
src = open("server/sql/schema.sql", encoding="utf-8").read()
src = src.replace("`carbonboo`", f"`{db}`")          # :23 CREATE DATABASE / :25 USE
sys.stdout.write(src)
PY
"$PY_BIN" - "$DB_NAME" > "$WORK/seed.sql" <<'PY'
import sys
db = sys.argv[1]
src = open("server/sql/seed.sql", encoding="utf-8").read()
src = src.replace("USE carbonboo;", f"USE `{db}`;")   # :21
sys.stdout.write(src)
PY

docker exec -i "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PASS" --default-character-set=utf8mb4 \
  < "$WORK/schema.sql" >/dev/null 2>"$WORK/schema.err" || { cat "$WORK/schema.err" >&2; fail_env "schema.sql 导入失败"; }
docker exec -i "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PASS" --default-character-set=utf8mb4 \
  < "$WORK/seed.sql" >/dev/null 2>"$WORK/seed.err" || { cat "$WORK/seed.err" >&2; fail_env "seed.sql 导入失败"; }

TABLE_COUNT=$(docker exec -i "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PASS" -N -B -e \
  "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB_NAME'")
info "任务库表数 = ${TABLE_COUNT}（期望 ≥ 21）"
[[ "$TABLE_COUNT" -ge 21 ]] || fail_env "schema 导入后表数不足：${TABLE_COUNT}"

# 生产库行数快照（只读；跑完对比，证明没碰过生产库）。用精确 COUNT(*)，不用 TABLE_ROWS 估算。
PROD_SNAPSHOT() {
  "$PY_BIN" - "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" <<'PY2'
import sys, pymysql
host, port, user, pw = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
conn = pymysql.connect(host=host, port=port, user=user, password=pw, database="carbonboo", charset="utf8mb4")
cur = conn.cursor()
cur.execute("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='carbonboo' ORDER BY TABLE_NAME")
for (t,) in cur.fetchall():
    cur.execute(f"SELECT COUNT(*) FROM `{t}`")
    print(f"{t}\t{cur.fetchone()[0]}")
conn.close()
PY2
}
PROD_SNAPSHOT > "$WORK/prod_before.txt"
say "生产库 carbonboo 精确行数快照（跑前，只读，$(wc -l < "$WORK/prod_before.txt") 张表）已记入现场：$WORK/prod_before.txt"

# ---------------------------------------------------------------- 2) 起 uvicorn --workers 2
say; say "=== 2) 启动 uvicorn --workers 2（pid 记入 $WORK/uvicorn.pid） ==="
export MYSQL_HOST="$DB_HOST" MYSQL_PORT="$DB_PORT" MYSQL_USER="$DB_USER" MYSQL_PASSWORD="$DB_PASS" \
       MYSQL_DB="$DB_NAME" APP_ENV=dev
export JWT_SECRET="$(env_value JWT_SECRET)" ADMIN_JWT_SECRET="$(env_value ADMIN_JWT_SECRET)"
[[ -n "$JWT_SECRET" && -n "$ADMIN_JWT_SECRET" ]] || fail_env "server/.env 缺 JWT_SECRET / ADMIN_JWT_SECRET"

( cd "$REPO/server" && "$PY_BIN" -m uvicorn app.main:app --host 127.0.0.1 --port "$PORT" \
    --workers 2 --no-access-log > "$WORK/uvicorn.log" 2>&1 & echo $! > "$WORK/uvicorn.pid" )
UVICORN_PID="$(cat "$WORK/uvicorn.pid")"
info "uvicorn supervisor pid = ${UVICORN_PID}（--workers 2 ⇒ 1 supervisor + 2 worker）"

READY=0
for i in $(seq 1 240); do
  if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/v1/config" 2>/dev/null | grep -q '^200$'; then
    READY=1; break
  fi
  kill -0 "$UVICORN_PID" 2>/dev/null || break
  (( i % 40 == 0 )) && info "等待就绪 ${i}/240（冷启动首次 import FastAPI 栈可能要 10–30 s）"
  sleep 0.5
done
if [[ "$READY" != "1" ]]; then
  say "--- uvicorn.log 尾部 ---"; tail -40 "$WORK/uvicorn.log" >&2
  fail_env "uvicorn 未就绪（端口 $PORT）"
fi
info "服务端就绪：http://127.0.0.1:${PORT}（worker 数见日志）"
grep -E "Started parent process|Started server process|Uvicorn running" "$WORK/uvicorn.log" | sed 's/^/    /' || true

# ---------------------------------------------------------------- 3) 跑探针
say; say "=== 3) 并发探针（真实 MySQL + 2 worker） ==="
CONC_BASE_URL="http://127.0.0.1:${PORT}" \
CONC_MYSQL_HOST="$DB_HOST" CONC_MYSQL_PORT="$DB_PORT" \
CONC_MYSQL_USER="$DB_USER" CONC_MYSQL_PASSWORD="$DB_PASS" CONC_MYSQL_DB="$DB_NAME" \
CONC_UVICORN_LOG="$WORK/uvicorn.log" \
"$PY_BIN" tests/tools/concurrency_e2e/lib/conc_probe.py
PROBE_RC=$?
say "PROBE_EXIT=${PROBE_RC}"

# ---------------------------------------------------------------- 4) 清理与自证
say; say "=== 4) 清理与自证 ==="
kill_uvicorn
PORT_LEFT=OPEN
for _ in $(seq 1 40); do   # worker 退出可能有几百毫秒延迟，等到 CLOSED 或超时 8 s
  if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; then PORT_LEFT=CLOSED; break; fi
  sleep 0.2
done
say "uvicorn 端口 ${PORT} 状态 = ${PORT_LEFT}（期望 CLOSED）"

docker exec -i "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PASS" \
  -e "DROP DATABASE IF EXISTS \`$DB_NAME\`" >/dev/null 2>&1
LEFTOVER=$(docker exec -i "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PASS" -N -B -e "SHOW DATABASES" 2>/dev/null \
  | grep -c '^carbonboo_conc_' || true)
say "SHOW DATABASES 中 carbonboo_conc_* 遗留数 = ${LEFTOVER}（期望 0）"
docker exec -i "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PASS" -N -B -e "SHOW DATABASES" 2>/dev/null \
  | sed 's/^/    /' | grep -E 'carbonboo($|_conc)' || true

PROD_SNAPSHOT > "$WORK/prod_after.txt"
if diff -q "$WORK/prod_before.txt" "$WORK/prod_after.txt" >/dev/null 2>&1; then
  say "生产库 carbonboo 精确行数：跑前 == 跑后（逐表 COUNT(*) 一致）"
else
  say "生产库 carbonboo 精确行数：**有差异**（见 $WORK/prod_before.txt vs prod_after.txt）"
fi

PGC=$(ps -eo pid,args | grep -E 'uvicorn app\.main:app .*--port '"?${PORT}"? | grep -v grep | wc -l)
say "残留 uvicorn 进程数 = ${PGC}（期望 0）"

DB_NAME=""   # 已 drop，避免 trap 重复
if [[ "$PROBE_RC" == "0" ]]; then
  say "RESULT: PASS"
  exit 0
else
  say "RESULT: FAIL（探针退出码 ${PROBE_RC}）"
  exit 1
fi
