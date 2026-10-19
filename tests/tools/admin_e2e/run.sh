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

# t76 追加：真 nginx(TLS) 图层默认开启（CB_ADMIN_E2E_NGINX=0 可退回 t55 的纯直连路径）。
# 镜像不存在属于「环境不可达」而非「断言失败」——先于建库/起服务端判定，退出码 2。
if [ "${CB_ADMIN_E2E_NGINX:-1}" = "1" ]; then
  if ! docker image inspect "${CB_ADMIN_E2E_NGINX_IMAGE:-nginx:alpine}" >/dev/null 2>&1; then
    envfail "nginx 镜像不可用（CB_ADMIN_E2E_NGINX_IMAGE=${CB_ADMIN_E2E_NGINX_IMAGE:-nginx:alpine}，docker image inspect 失败）"
    log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
    exit 2
  fi
fi

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
  # t76：真 nginx(TLS) 图层的容器 / 第二份 Edge profile / 仓库外的第二份 run.json 一并清掉
  nginx_cleanup_guard
  mysql_root -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; DROP USER IF EXISTS '$DB_USER'@'%';" >/dev/null 2>&1
  rm -f "$WIN_TMP/cb-admin-e2e-run.json" "$WIN_TMP/cb-admin-e2e-run-nginx.json"
}

# t76 追加：该函数在 4b 阶段定义变量之前也可能被 cleanup 调到（env 早退），故全部用 :- 兜底。
nginx_cleanup_guard() {
  docker rm -f "${NGINX_NAME:-cb-admin-e2e-nginx}" >/dev/null 2>&1
  powershell.exe -NoProfile -Command \
    "Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | Where-Object { \$_.CommandLine -like '*${WIN_PROFILE_NGINX_NAME:-cb-admin-e2e-nginx-profile}*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" \
    >/dev/null 2>&1
  rm -rf "${WIN_PROFILE_NGINX_WSL:-/nonexistent-cb-profile}" 2>/dev/null
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

# 清理时机：只在**环境检查全部通过之后、驱动启动之前**清目录。
# 改前这行在脚本开头（env 早退分支之前），一次 env 不可达的失败跑会清掉上一轮的有效截图（t55 踩过）。
rm -rf "$ARTIFACTS"
mkdir -p "$ARTIFACTS"

log ""
log "=== 浏览器级端到端驱动（Edge headless + CDP over WebSocket） ==="
PYTHONIOENCODING=utf-8 PYTHONUTF8=1 "$WINPY" "$(printf '%s' "$HERE/cdp_driver.py" | sed 's|^/mnt/c/|C:/|')" \
  "$RUNJSON_WIN_ARG" 2>&1 | tee "$TMP/driver.log"
DRIVER_EXIT="${PIPESTATUS[0]}"

log ""
log "=== 截图归档 ==="
ls -l "$ARTIFACTS" 2>/dev/null | sed -n '1,40p'

# =========================================================================== #
# 4b. t76 追加：真浏览器图层 —— 经真 nginx(TLS) 反代再跑一遍（第二遍）
#
#     上面第 4 步是「Windows Edge → WSL uvicorn 直连」。本阶段在两者之间插入
#     **仓库里真正要上生产的那份 nginx 站点配置**（`server/deploy/nginx/carbonboo.conf`，
#     一字不改，只派生副本改证书路径与上游地址），以容器 `nginx:alpine` + 自签证书做
#     TLS 终止与 `/admin` 反代；然后用**同一套** Edge headless + CDP 驱动
#     （`cdp_driver.py`，t76 只加了 origin 改写/自签证书/资源探针三个开关）从
#     `https://api.example.com:10443` 把/七项功能与四条鉴权边界**再跑一遍**。
#
#     随后 `compare_paths.py` 在 WSL 侧逐字节比对两条路径：登录页 HTML、浏览器实际
#     加载过的 `/admin/static/*` 资源（状态码 + sha256）、断言项集合、TLS 对端证书。
#     任一不一致 → 退出码 1；nginx 起不来 / 不可达 → 退出码 2（沿用 t55 约定）。
#
#     可覆盖：CB_ADMIN_E2E_NGINX=0 关闭本阶段（退回 t55 行为）；
#             CB_ADMIN_E2E_NGINX_IMAGE / _HTTPS_PORT / _HTTP_PORT / _CDP_PORT。
# =========================================================================== #
NGINX_NAME="cb-admin-e2e-nginx"
NGINX_IMAGE="${CB_ADMIN_E2E_NGINX_IMAGE:-nginx:alpine}"
NGINX_HTTPS_PORT="${CB_ADMIN_E2E_NGINX_HTTPS_PORT:-10443}"
NGINX_HTTP_PORT="${CB_ADMIN_E2E_NGINX_HTTP_PORT:-10080}"
NGINX_CDP_PORT="${CB_ADMIN_E2E_NGINX_CDP_PORT:-9334}"
NGINX_DIR="$TMP/nginx"
NGINX_TARGET="127.0.0.1"
WIN_PROFILE_NGINX_NAME="cb-admin-e2e-nginx-profile"
WIN_PROFILE_NGINX_WSL="$WIN_TMP/$WIN_PROFILE_NGINX_NAME"
WIN_PROFILE_NGINX="C:/Users/Administrator/AppData/Local/Temp/$WIN_PROFILE_NGINX_NAME"
WIN_RUNJSON_NGINX="$WIN_TMP/cb-admin-e2e-run-nginx.json"
WIN_RUNJSON_NGINX_ARG="C:/Users/Administrator/AppData/Local/Temp/cb-admin-e2e-run-nginx.json"
NGINX_DRIVER_EXIT=0
NGINX_PASS=0
NGINX_FAIL=0
COMPARE_EXIT=0
PROD_SAME=1

# 生产库（carbonboo）逐表精确行数：本工具只建/删任务库，生产库必须跑前==跑后
prod_counts() {
  local tables t
  tables="$(mysql_root -N -B -e "SELECT table_name FROM information_schema.tables WHERE table_schema='carbonboo' AND table_type='BASE TABLE' ORDER BY table_name;" 2>/dev/null | tr -d '\r')"
  for t in $tables; do
    printf '%s\t%s\n' "$t" "$(mysql_root -N -B -e "SELECT COUNT(*) FROM \`carbonboo\`.\`$t\`;" 2>/dev/null | tr -d '\r')"
  done
}

if [ "${CB_ADMIN_E2E_NGINX:-1}" = "1" ]; then
  log ""
  log "=== t76：真浏览器图层经真 nginx(TLS) 反代（Edge headless + CDP，第二遍） ==="

  info "生产库 carbonboo 逐表行数（nginx 图层跑前）"
  prod_counts > "$TMP/prod_counts_before.txt" 2>/dev/null || true
  info "已记录 $(wc -l < "$TMP/prod_counts_before.txt" | tr -d ' ') 张表"

  # ---- 自签证书（仅本阶段临时用，落在 /tmp，不进仓库） ----
  rm -rf "$NGINX_DIR"; mkdir -p "$NGINX_DIR/certs"
  if ! openssl req -x509 -newkey rsa:2048 -nodes -keyout "$NGINX_DIR/certs/privkey.pem" \
       -out "$NGINX_DIR/certs/fullchain.pem" -days 2 -subj "/CN=api.example.com" \
       -addext "subjectAltName=DNS:api.example.com" > "$NGINX_DIR/openssl.log" 2>&1; then
    envfail "自签证书生成失败（$NGINX_DIR/openssl.log）"
    log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
    exit 2
  fi

  # ---- 派生 nginx 配置：只改证书路径 + 上游地址；仓库里的 conf 一字不改 ----
  sed -e 's|/etc/letsencrypt/live/api.example.com/fullchain.pem|/etc/nginx/tls/fullchain.pem|' \
      -e 's|/etc/letsencrypt/live/api.example.com/privkey.pem|/etc/nginx/tls/privkey.pem|' \
      -e "s|http://127.0.0.1:8000|http://host.docker.internal:$PORT|g" \
      "$SERVER/deploy/nginx/carbonboo.conf" > "$NGINX_DIR/carbonboo.conf"
  UPSTREAM_HITS="$(grep -c "host.docker.internal:$PORT" "$NGINX_DIR/carbonboo.conf" || true)"
  if [ "${UPSTREAM_HITS:-0}" -lt 1 ]; then
    envfail "派生配置里没有替换出上游 host.docker.internal:$PORT（仓库 conf 结构变了？）"
    log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
    exit 2
  fi
  info "nginx 配置派生完成：上游 127.0.0.1:8000 → host.docker.internal:$PORT（替换 $UPSTREAM_HITS 处），证书 → /etc/nginx/tls/"

  # ---- 起真 nginx(TLS) 容器 ----
  docker rm -f "$NGINX_NAME" >/dev/null 2>&1
  if ! docker run -d --name "$NGINX_NAME" --add-host "host.docker.internal:host-gateway" \
       -p "$NGINX_HTTPS_PORT:443" -p "$NGINX_HTTP_PORT:80" \
       -v "$NGINX_DIR/carbonboo.conf:/etc/nginx/conf.d/default.conf:ro" \
       -v "$NGINX_DIR/certs:/etc/nginx/tls:ro" \
       "$NGINX_IMAGE" > "$NGINX_DIR/docker-run.log" 2>&1; then
    envfail "nginx 容器启动失败（$NGINX_IMAGE）：$(tail -2 "$NGINX_DIR/docker-run.log" | tr '\n' ' ')"
    log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
    exit 2
  fi

  code=""
  for i in $(seq 1 80); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 2 \
        --resolve "api.example.com:$NGINX_HTTPS_PORT:127.0.0.1" \
        "https://api.example.com:$NGINX_HTTPS_PORT/admin/login" || true)"
    [ "$code" = "200" ] && break
    sleep 0.5
  done
  if [ "${code:-}" != "200" ]; then
    envfail "nginx(TLS) 反代未就绪：GET /admin/login → ${code:-000}（容器日志见下）"
    docker logs --tail 8 "$NGINX_NAME" 2>&1
    log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
    exit 2
  fi
  info "nginx(TLS) 就绪：https://api.example.com:$NGINX_HTTPS_PORT/admin/login → HTTP 200（HTTP→HTTPS 跳转端口 $NGINX_HTTP_PORT）"

  # ---- Windows 侧（Edge 所在侧）可达性：WSL localhost 转发优先，失败再试 WSL eth0 IP ----
  win_code="$(powershell.exe -NoProfile -Command \
    "curl.exe -s -k --max-time 6 -o NUL -w '%{http_code}' --resolve api.example.com:$NGINX_HTTPS_PORT:127.0.0.1 https://api.example.com:$NGINX_HTTPS_PORT/admin/login" \
    2>/dev/null | tr -d '\r\n ')"
  if [ "$win_code" != "200" ]; then
    NGINX_TARGET="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    info "Windows localhost 不通（${win_code:-无输出}），改用 WSL eth0 IP：$NGINX_TARGET"
    win_code="$(powershell.exe -NoProfile -Command \
      "curl.exe -s -k --max-time 6 -o NUL -w '%{http_code}' --resolve api.example.com:$NGINX_HTTPS_PORT:$NGINX_TARGET https://api.example.com:$NGINX_HTTPS_PORT/admin/login" \
      2>/dev/null | tr -d '\r\n ')"
  fi
  if [ "$win_code" != "200" ]; then
    envfail "Windows 侧访问 nginx 不可达（localhost 与 $NGINX_TARGET 均非 200：${win_code:-无输出}）"
    log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
    exit 2
  fi
  info "Windows 侧可达：Edge 目标 api.example.com → $NGINX_TARGET:$NGINX_HTTPS_PORT（HTTP $win_code）"

  # ---- 第二份 Edge（独立 profile + 独立 CDP 端口；profile 必须 Windows 路径） ----
  # `--no-proxy-server`：本机 Windows 配了系统代理时，Chromium 对**主机名**请求会走代理
  # （实测无此开关时 https://api.example.com:10443 报 ERR_CONNECTION_RESET/ABORTED，而
  #  `--dump-dom https://127.0.0.1:10443/...` 正常）——这是浏览器侧环境问题，不是反代缺陷。
  info "启动 Edge headless（CDP 端口 $NGINX_CDP_PORT，profile $WIN_PROFILE_NGINX，--ignore-certificate-errors --no-proxy-server）"
  powershell.exe -NoProfile -Command \
    "Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | Where-Object { \$_.CommandLine -like '*$WIN_PROFILE_NGINX_NAME*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" \
    >/dev/null 2>&1
  rm -rf "$WIN_PROFILE_NGINX_WSL" 2>/dev/null
  nohup "$EDGE" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
    --remote-debugging-port="$NGINX_CDP_PORT" --user-data-dir="$WIN_PROFILE_NGINX" \
    --ignore-certificate-errors --no-proxy-server \
    --host-resolver-rules="MAP api.example.com $NGINX_TARGET" \
    "about:blank" > "$TMP/edge_nginx.log" 2>&1 &
  EDGE_NGINX_PID=$!
  sleep 6
  if ! grep -q "DevTools listening on" "$TMP/edge_nginx.log" 2>/dev/null; then
    sleep 6
  fi
  if ! grep -q "DevTools listening on" "$TMP/edge_nginx.log" 2>/dev/null; then
    envfail "第二份 Edge 未起来（$TMP/edge_nginx.log 无 'DevTools listening on'）"
    tail -5 "$TMP/edge_nginx.log" 2>/dev/null
    log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
    exit 2
  fi
  info "Edge(nginx) CDP 已监听：$(grep -m1 'DevTools listening on' "$TMP/edge_nginx.log" | sed 's/^.*DevTools listening on //')"

  # ---- 第二份 run.json：浏览器 origin = https://api.example.com，探针 origin = 直连 uvicorn ----
  # 口令必须接上第一遍的状态：第二遍开始时管理员口令已经是第一遍 ⑥ 改成的 $NEW_PW，
  # 若仍用引导口令 $ADMIN_PW 会「口令错误」——这是同一套用例连跑两遍的必然，不是缺陷。
  NEW_PW_2="Ch4nged2-$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)"
  cat > "$WIN_RUNJSON_NGINX" <<JSON
{
  "base_url": "https://api.example.com:$NGINX_HTTPS_PORT",
  "http_probe_base_url": "http://127.0.0.1:$PORT",
  "insecure_tls": true,
  "cdp_http": "http://127.0.0.1:$NGINX_CDP_PORT",
  "artifacts_dir": "$(printf '%s' "$ARTIFACTS" | sed 's|^/mnt/c/|C:/|')",
  "viewport": [1440, 900],
  "admin_username": "$ADMIN_USER",
  "admin_password": "$NEW_PW",
  "admin_new_password": "$NEW_PW_2",
  "client_username": "$CLIENT_USER",
  "client_password": "$CLIENT_PW",
  "item_id": "frame_01",
  "upload_png": "$(printf '%s' "$UPLOAD_PNG_WIN" | sed 's|\\\\|\\|g')",
  "shot_prefix": "nginx_",
  "report_name": "report_nginx.json",
  "resource_probe": true
}
JSON

  log ""
  log "--- 第二遍：经 nginx(TLS) 的浏览器级端到端驱动 ---"
  PYTHONIOENCODING=utf-8 PYTHONUTF8=1 "$WINPY" "$(printf '%s' "$HERE/cdp_driver.py" | sed 's|^/mnt/c/|C:/|')" \
    "$WIN_RUNJSON_NGINX_ARG" 2>&1 | tee "$TMP/driver_nginx.log"
  NGINX_DRIVER_EXIT="${PIPESTATUS[0]}"
  NGINX_PASS="$(grep -c '\[PASS\]' "$TMP/driver_nginx.log" 2>/dev/null | head -1)"; NGINX_PASS="${NGINX_PASS:-0}"
  NGINX_FAIL="$(grep -c '\[FAIL\]' "$TMP/driver_nginx.log" 2>/dev/null | head -1)"; NGINX_FAIL="${NGINX_FAIL:-0}"
  info "nginx 路径驱动：PASS=$NGINX_PASS FAIL=$NGINX_FAIL exit=$NGINX_DRIVER_EXIT"

  log ""
  log "--- t76：两条路径一致性校验（WSL python3，纯标准库；TLS 按 api.example.com 真校验）---"
  python3 "$HERE/compare_paths.py" \
    --direct-http "http://127.0.0.1:$PORT" \
    --nginx-url "https://api.example.com:$NGINX_HTTPS_PORT" \
    --nginx-cert "$NGINX_DIR/certs/fullchain.pem" \
    --direct-report "$ARTIFACTS/report.json" \
    --nginx-report "$ARTIFACTS/report_nginx.json" \
    --artifacts "$ARTIFACTS" --min-brand-shots 3 2>&1 | tee "$TMP/compare.log"
  COMPARE_EXIT="${PIPESTATUS[0]}"
  COMPARE_PASS="$(grep -c '\[PASS\]' "$TMP/compare.log" 2>/dev/null | head -1)"; COMPARE_PASS="${COMPARE_PASS:-0}"
  COMPARE_FAIL="$(grep -c '\[FAIL\]' "$TMP/compare.log" 2>/dev/null | head -1)"; COMPARE_FAIL="${COMPARE_FAIL:-0}"
  info "一致性校验：PASS=$COMPARE_PASS FAIL=$COMPARE_FAIL exit=$COMPARE_EXIT"

  log ""
  log "--- nginx 路径截图（artifacts/nginx_*.png）---"
  ls -l "$ARTIFACTS"/nginx_*.png 2>/dev/null | sed -n '1,20p'

  # ---- 生产库行数跑前==跑后 ----
  prod_counts > "$TMP/prod_counts_after.txt" 2>/dev/null || true
  if diff -u "$TMP/prod_counts_before.txt" "$TMP/prod_counts_after.txt" > "$TMP/prod_counts.diff" 2>&1; then
    info "生产库 carbonboo 逐表行数：跑前==跑后（$(wc -l < "$TMP/prod_counts_before.txt" | tr -d ' ') 张表）"
  else
    PROD_SAME=0
    fail "生产库 carbonboo 行数发生变化（见 /tmp/cb-admin-e2e/prod_counts.diff）："
    sed -n '1,20p' "$TMP/prod_counts.diff"
  fi

  log ""
  log "=== 结论（t76：直连 + 真 nginx(TLS) 反代 两条路径）==="
  D_PASS="$(grep -c '\[PASS\]' "$TMP/driver.log" 2>/dev/null | head -1)"; D_PASS="${D_PASS:-0}"
  D_FAIL="$(grep -c '\[FAIL\]' "$TMP/driver.log" 2>/dev/null | head -1)"; D_FAIL="${D_FAIL:-0}"
  log "直连 checks: PASS=$D_PASS FAIL=$D_FAIL driver_exit=$DRIVER_EXIT"
  log "nginx checks: PASS=$NGINX_PASS FAIL=$NGINX_FAIL driver_exit=$NGINX_DRIVER_EXIT compare_exit=$COMPARE_EXIT"
  if [ "$DRIVER_EXIT" = "0" ] && [ "$NGINX_DRIVER_EXIT" = "0" ] && [ "$COMPARE_EXIT" = "0" ] && [ "$PROD_SAME" = "1" ]; then
    log "RESULT: PASS —— 直连与真 nginx(TLS) 反代两条路径均由真实 Edge headless + CDP 驱动通过"
    exit 0
  elif [ "$DRIVER_EXIT" = "2" ] || [ "$NGINX_DRIVER_EXIT" = "2" ] || [ "$COMPARE_EXIT" = "2" ]; then
    log "RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）"
    exit 2
  else
    log "RESULT: FAIL —— 见上面的 [FAIL] 行、artifacts/report_nginx.json 与 /tmp/cb-admin-e2e/compare.log"
    exit 1
  fi
fi

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
