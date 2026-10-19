#!/usr/bin/env bash
# CarbonBoo `/admin` 浏览器级端到端验证 —— 一把跑完（Edge headless + CDP）。
#
# 能力
# ----
# 起**真实服务端**（项目 MySQL 容器 carbonboo-mysql → 127.0.0.1:13307 的一个任务专属库）
# + **真实浏览器**（Windows 侧 Edge headless，CDP 端口 9333），由 `cdp_driver.py` 驱动
# `/admin` 的七项功能与四条鉴权边界，逐项留 HTTP 状态码、页面文本命中、截图像素校验。
#
# 退出码
# ------
#   0 = 全部断言通过（含 7 项功能 + 鉴权边界）
#   1 = 有断言失败（看 stdout 的 [FAIL] 行与 artifacts/report.json）
#   2 = 环境不可达（MySQL 容器 / Edge / CDP / 服务端 任一不可用）—— 如实记「未运行」，不算通过
#
# 边界（写死，不许含糊）
# ----------------------
# * 本脚本**不碰** `app/**`、`server/**`、`tests/cases/**`：它只读 `server/sql/*.sql` 建任务库，
#   只**启动**服务端进程（不改一行代码），跑完删库、杀进程。
# * 浏览器在 **Windows** 侧跑：WSL 是 NAT 模式，WSL→Windows 的入站被挡（实测 curl 超时 exit 28），
#   Edge 的 DevTools 端口只监听 Windows 的 127.0.0.1，所以驱动必须与 Edge 同侧（见 cdp_driver.py 头注释）。
# * 口令：引导口令与改密口令都是本脚本**临时生成**的，只经 `$TMP/run.json`（仓库外）传给驱动，
#   不写入任何被提交的文件；跑完删库即失效。
# * 本脚本**不安装任何依赖**：Windows python 用系统自带的 Pillow，服务端用 `server/.venv`。

set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SERVER="$ROOT/server"
ARTIFACTS="$HERE/artifacts"

DB_NAME="${CB_ADMIN_E2E_DB:-carbonboo_admin_e2e}"
DB_USER="cb_e2e"
PORT="${CB_ADMIN_E2E_PORT:-8041}"
CDP_PORT="${CB_ADMIN_E2E_CDP_PORT:-9333}"
MYSQL_CONTAINER="${CB_ADMIN_E2E_CONTAINER:-carbonboo-mysql}"
EDGE="/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
WINPY="/mnt/c/Users/Administrator/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"
WIN_TMP="/mnt/c/Users/Administrator/AppData/Local/Temp"
WIN_PROFILE_NAME="cb-admin-e2e-profile"
WIN_PROFILE_WSL="$WIN_TMP/$WIN_PROFILE_NAME"
# Edge 是 Windows 二进制：--user-data-dir 必须给 Windows 路径。
# 给 /mnt/c/... 会被忽略并退回用户默认 profile（跨轮串 Cookie，实测已踩）。
WIN_PROFILE="C:/Users/Administrator/AppData/Local/Temp/$WIN_PROFILE_NAME"
TMP="/tmp/cb-admin-e2e"

UVICORN_PID=""
EDGE_PID=""

log()  { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; }
envfail() { printf '[ENV-FAIL] %s\n' "$*"; }

mkdir -p "$TMP"
rm -rf "$ARTIFACTS"
mkdir -p "$ARTIFACTS"

# --------------------------------------------------------------------------- #
# 0. 环境可达性（任何一条不通 → 退出码 2，绝不降级冒充）
# --------------------------------------------------------------------------- #
env_checks() {
  local ok=0
  if ! docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER" >/dev/null 2>&1; then
    envfail "MySQL 容器 $MYSQL_CONTAINER 不可用（docker inspect 失败）"; ok=1
  elif [ "$(docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER")" != "true" ]; then
    envfail "MySQL 容器 $MYSQL_CONTAINER 未在运行"; ok=1
  fi
  if [ ! -x "$EDGE" ]; then envfail "Edge 不存在或不可执行：$EDGE"; ok=1; fi
  if [ ! -x "$WINPY" ]; then envfail "Windows python 不存在：$WINPY"; ok=1; fi
  if [ ! -x "$SERVER/.venv/bin/uvicorn" ]; then envfail "缺 $SERVER/.venv/bin/uvicorn"; ok=1; fi
  if [ ! -f "$SERVER/.env" ]; then envfail "缺 $SERVER/.env（MySQL 管理凭据）"; ok=1; fi
  return $ok
}

if ! env_checks; then
  log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
  exit 2
fi

MYSQL_ADMIN_PASSWORD="$(grep -E '^MYSQL_ADMIN_PASSWORD=' "$SERVER/.env" | cut -d= -f2-)"
if [ -z "$MYSQL_ADMIN_PASSWORD" ]; then
  envfail "$SERVER/.env 里没有 MYSQL_ADMIN_PASSWORD"
  log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
  exit 2
fi

# --------------------------------------------------------------------------- #
# 1. 任务专属库 + schema/seed（库名只在此处替换，不改仓库里的 .sql 文件）
# --------------------------------------------------------------------------- #
E2E_PW="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
ADMIN_USER="e2e_admin"
ADMIN_PW="Br4nd-$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)"
NEW_PW="Ch4nged-$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)"
CLIENT_USER="e2e_client_$$"
CLIENT_PW="client-$(head -c 10 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 10)"

mysql_root() {
  docker exec -e MYSQL_PWD="$MYSQL_ADMIN_PASSWORD" -i "$MYSQL_CONTAINER" mysql -uroot "$@"
}

info "准备任务库 $DB_NAME（容器 $MYSQL_CONTAINER）"
if ! mysql_root -e "
  DROP DATABASE IF EXISTS \`$DB_NAME\`;
  CREATE DATABASE \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
  CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$E2E_PW';
  GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
  FLUSH PRIVILEGES;
" > "$TMP/mysql_prepare.log" 2>&1; then
  envfail "建库/建用户失败：$(tail -3 "$TMP/mysql_prepare.log")"
  log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
  exit 2
fi

# 只替换 `CREATE DATABASE`/`USE` 两处库名（仓库内的 .sql 一字不改）
sed -e "s/^CREATE DATABASE IF NOT EXISTS \`carbonboo\`/CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`/" \
    -e "s/^USE \`carbonboo\`;/USE \`$DB_NAME\`;/" "$SERVER/sql/schema.sql" \
  | mysql_root > "$TMP/mysql_schema.log" 2>&1
SCHEMA_EXIT=$?
sed -e "s/^USE carbonboo;/USE \`$DB_NAME\`;/" "$SERVER/sql/seed.sql" \
  | mysql_root > "$TMP/mysql_seed.log" 2>&1
SEED_EXIT=$?
TABLES="$(mysql_root -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null | tr -d '\r')"
if [ "$SCHEMA_EXIT" != "0" ] || [ "$SEED_EXIT" != "0" ] || [ "${TABLES:-0}" -lt 20 ]; then
  envfail "schema/seed 未成功（schema_exit=$SCHEMA_EXIT seed_exit=$SEED_EXIT tables=${TABLES:-?}）"
  tail -3 "$TMP/mysql_schema.log" "$TMP/mysql_seed.log" 2>/dev/null
  mysql_root -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" >/dev/null 2>&1
  log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
  exit 2
fi
info "任务库就绪：21 张表期望，实测 tables=$TABLES"

# --------------------------------------------------------------------------- #
# 2. 起真实服务端（uvicorn，独立端口）
# --------------------------------------------------------------------------- #
cleanup() {
  if [ -n "$UVICORN_PID" ] && kill -0 "$UVICORN_PID" 2>/dev/null; then
    kill "$UVICORN_PID" 2>/dev/null
    sleep 1
    kill -9 "$UVICORN_PID" 2>/dev/null
  fi
  # 只关「我们自己这份 profile」的 Edge 进程，不动用户其它 Edge 窗口
  powershell.exe -NoProfile -Command \
    "Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | Where-Object { \$_.CommandLine -like '*$WIN_PROFILE_NAME*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" \
    >/dev/null 2>&1
  mysql_root -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; DROP USER IF EXISTS '$DB_USER'@'%';" >/dev/null 2>&1
  rm -f "$WIN_TMP/cb-admin-e2e-run.json"
}
trap cleanup EXIT

info "启动 uvicorn（127.0.0.1:$PORT → 库 $DB_NAME）"
(
  cd "$SERVER" || exit 1
  MYSQL_DB="$DB_NAME" MYSQL_USER="$DB_USER" MYSQL_PASSWORD="$E2E_PW" APP_ENV=dev \
  ADMIN_BOOTSTRAP_USERNAME="$ADMIN_USER" ADMIN_BOOTSTRAP_PASSWORD="$ADMIN_PW" \
  nohup "$SERVER/.venv/bin/uvicorn" app.main:app --host 0.0.0.0 --port "$PORT" \
    > "$TMP/uvicorn.log" 2>&1 &
  echo $! > "$TMP/uvicorn.pid"
)
UVICORN_PID="$(cat "$TMP/uvicorn.pid" 2>/dev/null || echo '')"
# `/mnt/c` 上首次 import 整个 FastAPI/SQLAlchemy 栈可能到 30–60 s（实测冷缓存 5 s、极冷时可更久），
# 故最多等 120 s，并把期间的 HTTP 码如实打出来，避免「等太短 → 误判 ENV-UNREACHABLE」。
code=""
for i in $(seq 1 240); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/admin/login" || true)"
  [ "$code" = "200" ] && break
  if [ $((i % 20)) -eq 0 ]; then info "等待服务端就绪… ${i}/240（当前 HTTP ${code:-000}）"; fi
  sleep 0.5
done
if [ "${code:-}" != "200" ]; then
  envfail "服务端未就绪：GET /admin/login → ${code:-无响应}（日志 $TMP/uvicorn.log）"
  info "uvicorn 进程：$(ps -p "${UVICORN_PID:-0}" -o pid=,stat=,cmd= 2>/dev/null || echo '不存在')"
  tail -8 "$TMP/uvicorn.log" 2>/dev/null
  log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
  exit 2
fi
info "服务端就绪：GET /admin/login → HTTP 200"

# --------------------------------------------------------------------------- #
# 3. 起真实浏览器（Edge headless，CDP 9333）—— 与驱动同侧（Windows）
# --------------------------------------------------------------------------- #
info "生成上传夹具 PNG（Windows 侧，Pillow）"
# 用正斜杠的 Windows 路径：PIL 与 CDP DOM.setFileInputFiles 都接受
UPLOAD_PNG_WIN="C:/Users/Administrator/AppData/Local/Temp/cb-admin-e2e-icon.png"
"$WINPY" -c "
from PIL import Image
img = Image.new('RGB', (96, 96), (46, 125, 91))
for x in range(96):
    img.putpixel((x, x), (255, 255, 255))
img.save(r'$UPLOAD_PNG_WIN')
print('fixture:', r'$UPLOAD_PNG_WIN')
" || { envfail "生成上传夹具失败"; log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"; exit 2; }

info "启动 Edge headless（CDP 端口 $CDP_PORT，profile $WIN_PROFILE）"
powershell.exe -NoProfile -Command \
  "Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | Where-Object { \$_.CommandLine -like '*$WIN_PROFILE_NAME*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" \
  >/dev/null 2>&1
rm -rf "$WIN_PROFILE_WSL" 2>/dev/null
nohup "$EDGE" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
  --remote-debugging-port="$CDP_PORT" --user-data-dir="$WIN_PROFILE" "about:blank" \
  > "$TMP/edge.log" 2>&1 &
EDGE_PID=$!
sleep 6
if ! grep -q "DevTools listening on" "$TMP/edge.log" 2>/dev/null; then
  sleep 6
fi
if ! grep -q "DevTools listening on" "$TMP/edge.log" 2>/dev/null; then
  envfail "Edge 未起来（$TMP/edge.log 无 'DevTools listening on'）"
  tail -5 "$TMP/edge.log" 2>/dev/null
  log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
  exit 2
fi
info "Edge CDP 已监听：$(grep -m1 'DevTools listening on' "$TMP/edge.log" | sed 's/^.*DevTools listening on //')"

# --------------------------------------------------------------------------- #
# 4. 驱动（Windows python；口令只经仓库外的 $TMP/run.json 传递）
# --------------------------------------------------------------------------- #
# run.json 必须落在 **Windows 可见** 的路径：驱动是 Windows python，看不到 WSL 的 /tmp
RUNJSON_WIN="$WIN_TMP/cb-admin-e2e-run.json"
RUNJSON_WIN_ARG="C:/Users/Administrator/AppData/Local/Temp/cb-admin-e2e-run.json"
cat > "$RUNJSON_WIN" <<JSON
{
  "base_url": "http://127.0.0.1:$PORT",
  "cdp_http": "http://127.0.0.1:$CDP_PORT",
  "artifacts_dir": "$(printf '%s' "$ARTIFACTS" | sed 's|^/mnt/c/|C:/|')",
  "viewport": [1440, 900],
  "admin_username": "$ADMIN_USER",
  "admin_password": "$ADMIN_PW",
  "admin_new_password": "$NEW_PW",
  "client_username": "$CLIENT_USER",
  "client_password": "$CLIENT_PW",
  "item_id": "frame_01",
  "upload_png": "$(printf '%s' "$UPLOAD_PNG_WIN" | sed 's|\\\\|\\|g')"
}
JSON

log ""
log "=== 浏览器级端到端驱动（Edge headless + CDP over WebSocket） ==="
PYTHONIOENCODING=utf-8 PYTHONUTF8=1 "$WINPY" "$(printf '%s' "$HERE/cdp_driver.py" | sed 's|^/mnt/c/|C:/|')" \
  "$RUNJSON_WIN_ARG" 2>&1 | tee "$TMP/driver.log"
DRIVER_EXIT="${PIPESTATUS[0]}"

log ""
log "=== 截图归档 ==="
ls -l "$ARTIFACTS" 2>/dev/null | sed -n '1,40p'

log ""
log "=== 结论 ==="
PASS_COUNT="$(grep -c '\[PASS\]' "$TMP/driver.log" 2>/dev/null | head -1)"; PASS_COUNT="${PASS_COUNT:-0}"
FAIL_COUNT="$(grep -c '\[FAIL\]' "$TMP/driver.log" 2>/dev/null | head -1)"; FAIL_COUNT="${FAIL_COUNT:-0}"
log "checks: PASS=$PASS_COUNT FAIL=$FAIL_COUNT  driver_exit=$DRIVER_EXIT"
if [ "$DRIVER_EXIT" = "0" ]; then
  log "RESULT: PASS —— /admin 七项功能与鉴权边界均由真实浏览器驱动通过"
  exit 0
elif [ "$DRIVER_EXIT" = "2" ]; then
  log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
  exit 2
else
  log "RESULT: FAIL —— 见上面的 [FAIL] 行与 artifacts/report.json"
  exit 1
fi
