#!/usr/bin/env bash
# =============================================================================
# CarbonBoo · server/deploy/ 容器化**实跑**（tests/tools/deploy_e2e/run.sh）
#
# 职责
# ----
# 把 `server/deploy/` 的四件实物真跑一遍（不是 `bash -n` / `systemd-analyze` 那类静态检查）：
#   ① nginx/carbonboo.conf → 装进 nginx:alpine；`nginx -t`（**仓库那份字节**）+ `nginx -T` 留档；
#                            验 TLS 终止 / HTTP→HTTPS 301 / 反代上游真实响应 / `/docs` 生产关闭 /
#                            `/admin` 与登录接口限流真拒绝
#   ② TLS                  → openssl 现场签发自签证书（带 SAN），`curl --cacert` 走 HTTPS 拿 200
#   ③ 应用                  → 仓库 `server/` 真实代码起 uvicorn（`app.main:app --workers 2`，
#                            与 systemd 单元 ExecStart 同形），连任务专属库（schema.sql + seed.sql）
#   ④ backup-mysql.sh      → 真跑出 dump（表数/体积/gzip 完整性），再**真还原**到临时库逐表比对
#   ⑤ migrate.sh + systemd → dry-run 与真跑对照、安全阀（含 test 库名拒跑、无 mysql 客户端拒跑）、
#                            systemd 单元静态校验（并如实记「systemd 未运行」）
#
# 用法：  bash tests/tools/deploy_e2e/run.sh              # 全跑，结束后清理
#         L1_KEEP=1 bash tests/tools/deploy_e2e/run.sh    # 保留现场（证书/dump/日志）便于翻证据
#
# 退出码：0 = 全部探针通过；1 = 有探针失败；2 = 环境不可达（Docker/镜像/容器/依赖/端口/仓库文件）
#
# 对仓库文件的处理（**一个字节都不改仓库**）
# ---------------------------------------
# * `server/deploy/**`、`server/sql/*.sql`、`server/.env` 一律**只读挂载**，全部派生副本放 $WORK；
# * 需要换算的「环境事实」只有下面 4 类，全部逐条打印在输出里（见 §0 派生清单）：
#     S1 nginx 上游 `127.0.0.1:8000` → `<应用容器名>:8000`（5 处）
#        理由：真实部署里 nginx 与 uvicorn 同机，上游就是 localhost:8000；这里是两容器，各自的
#        127.0.0.1 指向自己。语义不变（后端仍只被 nginx 访问、不对外发布）。
#        同时**另有一步**用仓库原文件（零改写）跑 `nginx -t` 并留 sha256 证明仓库那份本身合法。
#     S2 uvicorn `--host 127.0.0.1` → `--host 0.0.0.0`（容器内监听；容器端口不发布到宿主）
#        以及 `--forwarded-allow-ips=127.0.0.1` → `=*`（nginx 不再与应用同机，代理源 IP 不是 127.0.0.1）
#     S3 派生 `.env`：MYSQL_HOST 127.0.0.1→容器名、MYSQL_PORT 13307→3306、MYSQL_DB →任务库、
#        APP_ENV dev→prod（要验「`/docs` 生产默认关闭」这条口径）、补 ADMIN_BOOTSTRAP_*（仓库 .env 未设，
#        用于把 `/admin` 挂起来做 403 对照）。**密钥逐字沿用仓库 .env，从不打印**。
#     S4 `sql/schema.sql` / `sql/seed.sql` 里写死的生产库名 → 任务库（只在派生副本里替换）
# * 证书：自签证书挂到配置里写死的 `/etc/letsencrypt/live/api.example.com/`（**不改配置里的路径**）；
#   域名用 `curl --resolve` 指向 127.0.0.1（**不改 server_name**）；
# * 端口：配置里仍是 `listen 80/443`，用 `docker -p` 映射到宿主 10080/10443（无文本替换）。

# 结论边界（务必连同 REPORT.md 一起读）
# --------------------------------
# 验的是**配置与链路**：同一份 nginx 配置、同一份备份脚本、同一份迁移脚本、同一个 uvicorn 启动形态。
# 不是真实域名/备案/ACME 签发机构，不是真实云 VM 的 systemd 托管，也不是真实网络边界（限流在单机回环上打）。
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
SERVER="${REPO}/server"
CONF="${SERVER}/deploy/nginx/carbonboo.conf"
BACKUP_SH="${SERVER}/deploy/backup-mysql.sh"
MIGRATE_SH="${SERVER}/deploy/migrate.sh"
SYSTEMD_DIR="${SERVER}/deploy/systemd"

NET="carbonboo-deploy-e2e-net"
APP_NAME="carbonboo-deploy-e2e-app"
WEB_NAME="carbonboo-deploy-e2e-nginx"
BAK_NAME="carbonboo-deploy-e2e-backup"
E2E_DB="carbonboo_deploy_e2e"
E2E_DB_RESTORE="carbonboo_deploy_e2e_restore"
DOMAIN="api.example.com"
HTTP_PORT=10080
HTTPS_PORT=10443
NGINX_IMAGE="nginx:alpine"
PY_IMAGE="python:3.11-slim"
MYSQL_IMAGE="mysql:8.0"
APP_USER_NAME="deploy_e2e_1"
APP_USER_PASS='Passw0rd!2026'
KEEP="${L1_KEEP:-0}"

PASS=0
FAIL=0
declare -a FAILED_NAMES=()
WORK=""
NET_CREATED=0
MYSQL_ATTACHED=0

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_yel=""; c_off=""; }

log()  { printf '\n=== %s ===\n' "$*"; }
note() { printf '  %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '%s  PASS%s %s\n' "${c_grn}" "${c_off}" "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '%s  FAIL%s %s\n' "${c_red}" "${c_off}" "$1"; }
fatal() {
  printf '\n%s  ENV%s %s\n' "${c_yel}" "${c_off}" "$1" >&2
  cleanup
  exit 2
}
# assert <名字> <退出码>
assert_rc() { local n="$1" rc="$2"; if [[ "${rc}" == "0" ]]; then ok "${n}"; else bad "${n}（rc=${rc}）"; fi; }

cleanup() {
  docker rm -f "${BAK_NAME}" "${WEB_NAME}" "${APP_NAME}" >/dev/null 2>&1
  if [[ "${MYSQL_ATTACHED}" == "1" ]]; then
    docker network disconnect "${NET}" carbonboo-mysql >/dev/null 2>&1
  fi
  if [[ "${NET_CREATED}" == "1" ]]; then docker network rm "${NET}" >/dev/null 2>&1; fi
  if [[ -n "${WORK}" && -f "${WORK}/app.env" ]]; then
    MYSQL_PWD="$(env_get MYSQL_ADMIN_PASSWORD)" mysql_root -e \
      "DROP DATABASE IF EXISTS \`${E2E_DB}\`; DROP DATABASE IF EXISTS \`${E2E_DB_RESTORE}\`;" >/dev/null 2>&1
  fi
  if [[ "${KEEP}" == "1" ]]; then
    [[ -n "${WORK}" ]] && printf '\n（L1_KEEP=1，保留现场：%s）\n' "${WORK}"
  else
    [[ -n "${WORK}" && -d "${WORK}" ]] && rm -rf "${WORK}"
  fi
}

# ---------------------------------------------------------------- .env 读取 ---
ENV_FILE="${SERVER}/.env"
env_get() {
  local key="$1"
  grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}

# --------------------------------------------------------------- MySQL 客户端 ---
# 以管理员身份连库（凭据只来自 server/.env，绝不打印）。默认在**派生网络**里按容器名连。
mysql_root() {
  docker run --rm -i --network "${NET}" -e MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" "${MYSQL_IMAGE}" \
    mysql --protocol=TCP -h"${MYSQL_HOST_FOR_CONTAINER}" -P"${MYSQL_PORT_FOR_CONTAINER}" \
    -u"${MYSQL_ADMIN_USER}" "$@"
}

# ------------------------------------------------------------------ HTTPS 请求 ---
# web <curl 参数...>：走 nginx 的 HTTPS（自签 CA + --resolve），stdout 为响应体，HTTP 码写到 $WEB_CODE
WEB_CODE=""
web() {
  local out
  out="$(curl -sS -m 20 --cacert "${CERTS}/fullchain.pem" \
      --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
      -w $'\n__CODE__%{http_code}' "$@" "https://${DOMAIN}:${HTTPS_PORT}${WEB_PATH}" 2>&1)"
  WEB_CODE="${out##*__CODE__}"
  printf '%s' "${out%$'\n'__CODE__*}"
}
# web_status <method> <path> [extra curl args...] → 打印 HTTP 码
web_status() {
  local method="$1" path="$2"; shift 2
  curl -sS -m 20 -o /dev/null -w '%{http_code}' --cacert "${CERTS}/fullchain.pem" \
    --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" -X "${method}" "$@" \
    "https://${DOMAIN}:${HTTPS_PORT}${path}" 2>/dev/null
}

# =============================================================== 0. 环境检查 ===
log "0. 环境检查"
command -v docker >/dev/null 2>&1 || fatal "没有 docker"
docker info >/dev/null 2>&1 || fatal "docker 不可用（docker info 失败）"
[[ -f "${CONF}" ]] || fatal "缺 ${CONF}"
[[ -f "${BACKUP_SH}" ]] || fatal "缺 ${BACKUP_SH}"
[[ -f "${MIGRATE_SH}" ]] || fatal "缺 ${MIGRATE_SH}"
[[ -f "${ENV_FILE}" ]] || fatal "缺 ${ENV_FILE}"
[[ -d "${SERVER}/.venv/lib/python3.11/site-packages" ]] || fatal "缺 server/.venv/lib/python3.11/site-packages"
command -v openssl >/dev/null 2>&1 || fatal "没有 openssl"
command -v curl >/dev/null 2>&1 || fatal "没有 curl"
docker inspect carbonboo-mysql >/dev/null 2>&1 || fatal "项目 MySQL 容器 carbonboo-mysql 不存在"
[[ "$(docker inspect -f '{{.State.Running}}' carbonboo-mysql 2>/dev/null)" == "true" ]] || fatal "carbonboo-mysql 未在运行"
for img in "${NGINX_IMAGE}" "${PY_IMAGE}" "${MYSQL_IMAGE}"; do
  docker image inspect "${img}" >/dev/null 2>&1 || fatal "缺镜像 ${img}（本任务禁止联网拉取）"
done
for p in "${HTTP_PORT}" "${HTTPS_PORT}"; do
  if ss -lnt 2>/dev/null | grep -qE ":${p}\b"; then fatal "宿主端口 ${p} 已被占用"; fi
done
note "docker: $(docker info --format '{{.OperatingSystem}} {{.ServerVersion}}')"
note "镜像: ${NGINX_IMAGE} / ${PY_IMAGE} / ${MYSQL_IMAGE} 均在本地"
note "宿主 ${HTTP_PORT}/${HTTPS_PORT} 空闲；carbonboo-mysql 运行中"

WORK="$(mktemp -d /tmp/cbe2e.XXXXXX)"
CERTS="${WORK}/certs"; mkdir -p "${CERTS}" "${WORK}/logs" "${WORK}/backups"
EVID="${WORK}/logs/evidence.txt"
: > "${EVID}"

MYSQL_ADMIN_USER="$(env_get MYSQL_ADMIN_USER)"
MYSQL_ADMIN_PASSWORD="$(env_get MYSQL_ADMIN_PASSWORD)"
MYSQL_HOST_FOR_CONTAINER="carbonboo-mysql"
MYSQL_PORT_FOR_CONTAINER="3306"

# ========================================================== 1. 派生文件（S1–S4） ===
log "1. 派生清单（逐条列出：改了什么、为什么）"
S1_CNT=0
sed 's|http://127\.0\.0\.1:8000|http://'"${APP_NAME}"':8000|g' "${CONF}" > "${WORK}/carbonboo.conf"
S1_CNT="$(grep -c "proxy_pass http://${APP_NAME}:8000" "${WORK}/carbonboo.conf")"
note "S1 nginx 上游：127.0.0.1:8000 → ${APP_NAME}:8000（${S1_CNT} 处；两容器拓扑，语义不变）"
note "S2 uvicorn：--host 127.0.0.1 → 0.0.0.0；--forwarded-allow-ips=127.0.0.1 → *（容器内监听 + 跨容器代理）"
sed -e "s|^MYSQL_HOST=.*|MYSQL_HOST=${MYSQL_HOST_FOR_CONTAINER}|" \
    -e "s|^MYSQL_PORT=.*|MYSQL_PORT=${MYSQL_PORT_FOR_CONTAINER}|" \
    -e "s|^MYSQL_DB=.*|MYSQL_DB=${E2E_DB}|" \
    -e "s|^APP_ENV=.*|APP_ENV=prod|" "${ENV_FILE}" > "${WORK}/app.env"
grep -q '^ADMIN_BOOTSTRAP_USERNAME=' "${WORK}/app.env" || cat >> "${WORK}/app.env" <<'EOF'
ADMIN_BOOTSTRAP_USERNAME=cbadmin
ADMIN_BOOTSTRAP_PASSWORD=DeployE2E!2026x
EOF
note "S3 派生 .env 的改动（其余行逐字节沿用仓库 .env，密钥不打印）："
grep -nE '^(MYSQL_HOST|MYSQL_PORT|MYSQL_DB|APP_ENV|ADMIN_BOOTSTRAP_USERNAME|ADMIN_BOOTSTRAP_PASSWORD)=' "${WORK}/app.env" | sed 's/^/    /'
sed -e 's/`carbonboo`/`'"${E2E_DB}"'`/g' -e "s/^USE carbonboo;/USE \`${E2E_DB}\`;/" "${SERVER}/sql/schema.sql" > "${WORK}/schema.sql"
sed -e "s/^USE carbonboo;/USE \`${E2E_DB}\`;/" "${SERVER}/sql/seed.sql" > "${WORK}/seed.sql"
note "S4 schema/seed 的库名替换（仓库原生文件写死生产库名 carbonboo）："
diff <(grep -nE 'DATABASE|^USE ' "${SERVER}/sql/schema.sql" | sed 's/^[0-9]*://') \
     <(grep -nE 'DATABASE|^USE ' "${WORK}/schema.sql" | sed 's/^[0-9]*://') | sed 's/^/    /'
note "S1 的完整 diff（仓库文件 vs 运行文件）保存在 ${WORK}/logs/conf.diff"
diff -u "${CONF}" "${WORK}/carbonboo.conf" > "${WORK}/logs/conf.diff" || true
print_conf_diff_lines="$(grep -c '^[-+][^-+]' "${WORK}/logs/conf.diff")"
note "    该 diff 的变更行数 = ${print_conf_diff_lines}（应等于 ${S1_CNT} 的一倍：每处一行替换）"
note "S6 应用容器挂载：仓库 server/ 只读（不改仓库一个字）+ 一个**可写**的上传目录"
note "    ${WORK}/icons → /app/admin_web/static/uploads/icons（真机上 /opt/carbonboo/server 本身可写，" 
note "    单元里 ReadWritePaths=/opt/carbonboo/server；不给可写挂载时 7.5b.7 图标上传会 500 Errno 30）"

# ============================================================ 2. 网络与 MySQL ===
log "2. 派生网络 + 任务专属库"
docker network create "${NET}" >/dev/null 2>&1 || fatal "创建网络 ${NET} 失败"
NET_CREATED=1
# 项目 MySQL 在默认 bridge 上（无 DNS），按容器名互访需要临时挂到派生网络（收尾 disconnect，可逆）
docker network connect "${NET}" carbonboo-mysql >/dev/null 2>&1 || fatal "把 carbonboo-mysql 挂到 ${NET} 失败"
MYSQL_ATTACHED=1
note "carbonboo-mysql 已临时加入 ${NET}（收尾 disconnect；这是唯一一处触碰项目容器的动作，只加不减数据）"

mysql_root -e "DROP DATABASE IF EXISTS \`${E2E_DB}\`; DROP DATABASE IF EXISTS \`${E2E_DB_RESTORE}\`;" >/dev/null 2>&1
mysql_root -e "CREATE DATABASE \`${E2E_DB}\` DEFAULT CHARACTER SET utf8mb4;" >/dev/null 2>&1
mysql_root "${E2E_DB}" < "${WORK}/schema.sql" > "${WORK}/logs/schema.log" 2>&1 \
  && rc_schema=0 || rc_schema=$?
assert_rc "2.1 导入 schema.sql（派生副本，21 张表）" "${rc_schema}"
mysql_root -e "CREATE DATABASE IF NOT EXISTS \`${E2E_DB_RESTORE}\` DEFAULT CHARACTER SET utf8mb4;" >/dev/null 2>&1
mysql_root "${E2E_DB}" < "${WORK}/seed.sql" > "${WORK}/logs/seed.log" 2>&1 && rc_seed=0 || rc_seed=$?
assert_rc "2.2 导入 seed.sql（静态字典）" "${rc_seed}"
TBL_CNT="$(mysql_root -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${E2E_DB}';" 2>/dev/null | tr -d '[:space:]')"
if [[ "${TBL_CNT}" == "21" ]]; then ok "2.3 任务库表数 = 21"; else bad "2.3 任务库表数 = ${TBL_CNT}（期望 21）"; fi
SHOP_ROWS="$(mysql_root -N -B -e "SELECT COUNT(*) FROM \`${E2E_DB}\`.shop_item;" 2>/dev/null | tr -d '[:space:]')"
if [[ "${SHOP_ROWS:-0}" -ge 9 ]]; then ok "2.4 种子生效（shop_item 行数 = ${SHOP_ROWS}）"; else bad "2.4 种子未生效（shop_item = ${SHOP_ROWS}）"; fi

# ================================================================ 3. TLS 证书 ===
log "3. openssl 现场签发自签证书（带 SAN）"
openssl req -x509 -newkey rsa:2048 -sha256 -days 30 -nodes \
  -keyout "${CERTS}/privkey.pem" -out "${CERTS}/fullchain.pem" \
  -subj "/C=CN/O=CarbonBoo Deploy E2E/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN},DNS:localhost,IP:127.0.0.1" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" > "${WORK}/logs/openssl.log" 2>&1 \
  && rc_cert=0 || rc_cert=$?
assert_rc "3.1 openssl 签发成功（fullchain.pem + privkey.pem）" "${rc_cert}"
chmod 600 "${CERTS}/privkey.pem"; chmod 644 "${CERTS}/fullchain.pem"
openssl x509 -in "${CERTS}/fullchain.pem" -noout -subject -issuer -dates -ext subjectAltName \
  > "${WORK}/logs/cert.txt" 2>&1
cat "${WORK}/logs/cert.txt" | sed 's/^/    /'
if grep -q "DNS:${DOMAIN}" "${WORK}/logs/cert.txt"; then ok "3.2 证书 SAN 含 DNS:${DOMAIN}（+localhost/127.0.0.1）"; else bad "3.2 证书 SAN 不含 ${DOMAIN}"; fi
NOT_AFTER="$(openssl x509 -in "${CERTS}/fullchain.pem" -noout -enddate | cut -d= -f2)"
if openssl x509 -in "${CERTS}/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1; then ok "3.3 证书当前有效（notAfter=${NOT_AFTER}）"; else bad "3.3 证书已过期"; fi

# ================================================ 4. nginx：仓库原文件 nginx -t ===
log "4. nginx -t 用**仓库原文件**（零改写）"
docker run --rm -v "${CONF}:/etc/nginx/conf.d/carbonboo.conf:ro" \
  -v "${CERTS}:/etc/letsencrypt/live/${DOMAIN}:ro" \
  -v /dev/null:/etc/nginx/conf.d/default.conf:ro \
  "${NGINX_IMAGE}" sh -c 'nginx -t 2>&1; echo "EXIT=$?";
    echo "IN_CONTAINER_SHA256=$(sha256sum /etc/nginx/conf.d/carbonboo.conf | cut -d" " -f1)"' \
  > "${WORK}/logs/nginx_t_asis.log" 2>&1
cat "${WORK}/logs/nginx_t_asis.log" | sed 's/^/    /'
grep -q 'syntax is ok' "${WORK}/logs/nginx_t_asis.log" && grep -q 'test is successful' "${WORK}/logs/nginx_t_asis.log" \
  && ok "4.1 仓库原文件 nginx -t 通过（证书路径/上游 127.0.0.1:8000 均在原地）" \
  || bad "4.1 仓库原文件 nginx -t 未通过"
REPO_CONF_SHA="$(sha256sum "${CONF}" | cut -d' ' -f1)"
IN_CONF_SHA="$(grep -o 'IN_CONTAINER_SHA256=[0-9a-f]*' "${WORK}/logs/nginx_t_asis.log" | cut -d= -f2)"
if [[ "${REPO_CONF_SHA}" == "${IN_CONF_SHA}" && -n "${IN_CONF_SHA}" ]]; then
  ok "4.2 容器内读到的配置与仓库文件逐字节一致（sha256 ${REPO_CONF_SHA:0:16}…）"
else
  bad "4.2 容器内 sha256(${IN_CONF_SHA:0:16}…) ≠ 仓库 sha256(${REPO_CONF_SHA:0:16}…)"
fi

# ======================================================= 5. 起应用（仓库代码） ===
log "5. 起应用容器（仓库 server/ 代码 + repo venv 的 site-packages）"
docker rm -f "${APP_NAME}" >/dev/null 2>&1
# S6：仓库挂载是只读的（不改仓库一个字），而后台图标上传要往 admin_web/static/uploads/icons 写盘；
#     真机上 /opt/carbonboo/server 本身可写（单元里 ReadWritePaths=/opt/carbonboo/server），
#     所以这里单独把上传目录挂成可写（语义等价，改动写进 §1 的派生清单）。
mkdir -p "${WORK}/icons"
docker run -d --name "${APP_NAME}" --network "${NET}" \
  -v "${SERVER}:/app:ro" \
  -v "${SERVER}/.venv/lib/python3.11/site-packages:/sitepkgs:ro" \
  -v "${WORK}/app.env:/app/.env:ro" \
  -v "${WORK}/icons:/app/admin_web/static/uploads/icons" \
  -e PYTHONPATH=/sitepkgs -w /app "${PY_IMAGE}" \
  python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 2 \
    --proxy-headers --forwarded-allow-ips='*' > "${WORK}/logs/app_run.log" 2>&1 \
  && rc_app=0 || rc_app=$?
assert_rc "5.1 应用容器启动（uvicorn app.main:app --workers 2，与 systemd ExecStart 同形）" "${rc_app}"
READY=0
for _ in $(seq 1 60); do
  if docker exec "${APP_NAME}" python -c "
import urllib.request,sys
try:
    r=urllib.request.urlopen('http://127.0.0.1:8000/api/v1/health',timeout=3)
    sys.exit(0 if r.status==200 else 1)
except Exception:
    sys.exit(1)
" >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
if [[ "${READY}" == "1" ]]; then
  ok "5.2 应用就绪：容器内 GET /api/v1/health → 200"
  docker exec "${APP_NAME}" python -c "
import urllib.request
print(urllib.request.urlopen('http://127.0.0.1:8000/api/v1/health',timeout=5).read().decode()[:200])" \
    > "${WORK}/logs/health_direct.txt" 2>&1
  note "    直连响应：$(head -c 160 "${WORK}/logs/health_direct.txt")"
else
  bad "5.2 应用 60s 内未就绪"
  docker logs --tail 30 "${APP_NAME}" > "${WORK}/logs/app_fail.log" 2>&1
  note "    应用日志尾部："; tail -12 "${WORK}/logs/app_fail.log" | sed 's/^/      /'
fi
ORD_CNT="$(mysql_root -N -B -e "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${E2E_DB}' AND column_name='order';" 2>/dev/null | tr -d '[:space:]')"
note "    （顺带核对保留字列：本库名为 order 的列有 ${ORD_CNT} 个 —— 这是 t46/t49 的引号修复对象）"

# ==================================================== 6. 起 nginx（派生上游） ===
log "6. 起 nginx 容器（派生副本，唯一改动 = 上游地址 S1）"
docker rm -f "${WEB_NAME}" >/dev/null 2>&1
docker run -d --name "${WEB_NAME}" --network "${NET}" \
  -p "127.0.0.1:${HTTP_PORT}:80" -p "127.0.0.1:${HTTPS_PORT}:443" \
  -v "${WORK}/carbonboo.conf:/etc/nginx/conf.d/carbonboo.conf:ro" \
  -v "${CERTS}:/etc/letsencrypt/live/${DOMAIN}:ro" \
  -v /dev/null:/etc/nginx/conf.d/default.conf:ro \
  "${NGINX_IMAGE}" > "${WORK}/logs/nginx_run.log" 2>&1 && rc_web=0 || rc_web=$?
assert_rc "6.1 nginx 容器启动（-p 127.0.0.1:${HTTP_PORT}→80、:${HTTPS_PORT}→443）" "${rc_web}"
docker exec "${WEB_NAME}" nginx -t > "${WORK}/logs/nginx_t_runtime.log" 2>&1 \
  && rc_nt=0 || rc_nt=$?
assert_rc "6.2 运行中容器 nginx -t" "${rc_nt}"
docker exec "${WEB_NAME}" nginx -T > "${WORK}/logs/nginx_T_dump.txt" 2>&1
note "    nginx -T 原文（含证书路径与上游）已留档：${WORK}/logs/nginx_T_dump.txt（$(wc -l < "${WORK}/logs/nginx_T_dump.txt") 行）"
for pat in "zone=carbonboo_login" "server_name ${DOMAIN}" "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "http://${APP_NAME}:8000"; do
  grep -qF "${pat}" "${WORK}/logs/nginx_T_dump.txt" && ok "6.3 运行配置含『${pat}』" || bad "6.3 运行配置缺『${pat}』"
done
sed -n '/configuration file \/etc\/nginx\/conf.d\/carbonboo.conf/,/^}/p' "${WORK}/logs/nginx_T_dump.txt" \
  | head -60 > "${WORK}/logs/nginx_T_repo_section.txt" 2>/dev/null || true

# ============================================================ 7. 端到端探针 ===
log "7. 经 nginx 的 HTTPS 端到端探针"

# 7.1 TLS 终止 + 健康检查（README §3 口径）
HEALTH_BODY="$(curl -sS -m 20 --cacert "${CERTS}/fullchain.pem" \
  --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
  -w '\n__CODE__%{http_code}' "https://${DOMAIN}:${HTTPS_PORT}/api/v1/health" 2>&1)"
HEALTH_CODE="${HEALTH_BODY##*__CODE__}"
HEALTH_JSON="${HEALTH_BODY%$'\n'__CODE__*}"
printf '%s' "${HEALTH_JSON}" > "${WORK}/logs/health_via_nginx.txt"
if [[ "${HEALTH_CODE}" == "200" ]] && printf '%s' "${HEALTH_JSON}" | grep -q '"ok":true'; then
  ok "7.1 TLS 终止 + 反代上游：GET /api/v1/health → 200 ${HEALTH_JSON}"
else
  bad "7.1 GET /api/v1/health → ${HEALTH_CODE}（体：${HEALTH_JSON:0:120}）"
fi

# 7.2 HTTP → HTTPS 301
REDIR="$(curl -sS -m 20 -o /dev/null -w '%{http_code} %{redirect_url}' \
  -H "Host: ${DOMAIN}" "http://127.0.0.1:${HTTP_PORT}/" 2>&1)"
printf '%s' "${REDIR}" > "${WORK}/logs/http_redirect.txt"
if [[ "${REDIR}" == 301*"https://${DOMAIN}/"* ]]; then
  ok "7.2 HTTP→HTTPS：http://${DOMAIN}:${HTTP_PORT}/ → ${REDIR}"
else
  bad "7.2 HTTP→HTTPS 重定向异常：${REDIR}"
fi
ACME_CODE="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -H "Host: ${DOMAIN}" \
  "http://127.0.0.1:${HTTP_PORT}/.well-known/acme-challenge/probe" 2>&1)"
if [[ "${ACME_CODE}" == "404" ]]; then ok "7.2b ACME 路径未被 301（404，留给 certbot 的 webroot）"; else note "    ACME 路径返回 ${ACME_CODE}（INFO）"; fi

# 7.3 免鉴权业务接口：取价
SHOP_BODY="$(curl -sS -m 20 --cacert "${CERTS}/fullchain.pem" --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
  -w '\n__CODE__%{http_code}' "https://${DOMAIN}:${HTTPS_PORT}/api/v1/shop/items" 2>&1)"
SHOP_CODE="${SHOP_BODY##*__CODE__}"; SHOP_JSON="${SHOP_BODY%$'\n'__CODE__*}"
printf '%s' "${SHOP_JSON}" > "${WORK}/logs/shop_items.txt"
if [[ "${SHOP_CODE}" == "200" ]] && printf '%s' "${SHOP_JSON}" | grep -q 'frame_01'; then
  ok "7.3 免鉴权业务接口：GET /api/v1/shop/items → 200，含 frame_01（${#SHOP_JSON} 字节）"
else
  bad "7.3 GET /api/v1/shop/items → ${SHOP_CODE}（体：${SHOP_JSON:0:120}）"
fi

# 7.4 /docs 生产关闭（APP_ENV=prod）
DOCS_CODE="$(web_status GET /docs)"
OPENAPI_CODE="$(web_status GET /openapi.json)"
if [[ "${DOCS_CODE}" == "404" && "${OPENAPI_CODE}" == "404" ]]; then
  ok "7.4 生产关闭 /docs：GET /docs → 404、GET /openapi.json → 404（APP_ENV=prod）"
else
  bad "7.4 /docs=${DOCS_CODE}、/openapi.json=${OPENAPI_CODE}（期望均 404）"
fi

# 7.5 客户端令牌打 /admin/* → 403
REG_BODY="$(curl -sS -m 20 --cacert "${CERTS}/fullchain.pem" --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"${APP_USER_NAME}\",\"password\":\"${APP_USER_PASS}\"}" \
  -w '\n__CODE__%{http_code}' "https://${DOMAIN}:${HTTPS_PORT}/api/v1/auth/register" 2>&1)"
REG_CODE="${REG_BODY##*__CODE__}"; REG_JSON="${REG_BODY%$'\n'__CODE__*}"
printf '%s' "${REG_JSON}" > "${WORK}/logs/register.json"
USER_TOKEN="$(printf '%s' "${REG_JSON}" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("data",{}).get("userToken",""))
except Exception: print("")' 2>/dev/null)"
note "    注册客户端账号 ${APP_USER_NAME} → HTTP ${REG_CODE}（令牌长度 ${#USER_TOKEN}）"
ADMIN_CODE="$(web_status GET /admin/users -H "Authorization: Bearer ${USER_TOKEN}")"
ADMIN_BODY="$(curl -sS -m 20 --cacert "${CERTS}/fullchain.pem" --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
  -H "Authorization: Bearer ${USER_TOKEN}" "https://${DOMAIN}:${HTTPS_PORT}/admin/users" 2>&1)"
printf '%s' "${ADMIN_BODY}" > "${WORK}/logs/admin_403.txt"
if [[ -n "${USER_TOKEN}" && "${ADMIN_CODE}" == "403" ]]; then
  ok "7.5 客户端令牌打 /admin/users → 403（$(printf '%s' "${ADMIN_BODY}" | head -c 100)）"
else
  bad "7.5 客户端令牌打 /admin/users → ${ADMIN_CODE}（期望 403；体：${ADMIN_BODY:0:120}）"
fi
ADMIN_LOGIN_CODE="$(web_status GET /admin/login)"
if [[ "${ADMIN_LOGIN_CODE}" == "200" || "${ADMIN_LOGIN_CODE}" == "303" ]]; then
  note "    管理端已挂载：GET /admin/login → ${ADMIN_LOGIN_CODE}（INFO）"
else
  note "    管理端未挂载或异常：GET /admin/login → ${ADMIN_LOGIN_CODE}（INFO，403 中间件仍已生效）"
fi

# 7.5b 管理端 /admin 经 nginx+TLS 的真往返（t75 补 t56 的未运行项①：登录→列表→总览→配置→图标→改密→登出）
#     放在 7.6 之前：本节的 auth 请求量很小（用户名固定 cbadmin，远低于应用层 10 次/分），
#     而 7.6 需要先「未超阈值」拿到 200（7.6c），不能被这里先耗尽 zone。
log "7.5b 管理端 /admin 经 nginx 端到端（真 TLS + 真 Cookie 会话）"
ADMIN_USER="$(grep -m1 '^ADMIN_BOOTSTRAP_USERNAME=' "${WORK}/app.env" | cut -d= -f2-)"
ADMIN_PASS="$(grep -m1 '^ADMIN_BOOTSTRAP_PASSWORD=' "${WORK}/app.env" | cut -d= -f2-)"
ADMIN_NEW_PASS='DeployE2E!2026y'
JAR="${WORK}/admin_cookies.txt"; : > "${JAR}"
admin_curl() { curl -sS -m 25 --cacert "${CERTS}/fullchain.pem" --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
  -b "${JAR}" -c "${JAR}" "$@"; }
admin_code() { curl -sS -m 25 -o /dev/null -w '%{http_code}' --cacert "${CERTS}/fullchain.pem" \
  --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" -b "${JAR}" -c "${JAR}" "$@"; }
ASPECT="https://${DOMAIN}:${HTTPS_PORT}"

# 7.5b.1 登录页（Accept: text/html → HTML 渲染；无该头 → JSON 信封，见 security.wants_html）
LOGIN_PAGE="$(admin_curl -H 'Accept: text/html' -w '\n__CODE__%{http_code}' "${ASPECT}/admin/login" 2>&1)"
LP_CODE="${LOGIN_PAGE##*__CODE__}"; LP_BODY="${LOGIN_PAGE%$'\n'__CODE__*}"
printf '%s' "${LP_BODY}" > "${WORK}/logs/admin_login_page.html"
if [[ "${LP_CODE}" == "200" ]] && printf '%s' "${LP_BODY}" | grep -qiE '<form|<!doctype'; then
  ok "7.5b.1 GET /admin/login（Accept: text/html）→ 200 且是 HTML 表单页（${#LP_BODY} 字节）"
else
  bad "7.5b.1 GET /admin/login → ${LP_CODE}（体：${LP_BODY:0:120}）"
fi

# 7.5b.2 错误口令 → 401（JSON 路径）
BAD_BODY="$(admin_curl -w '\n__CODE__%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"definitely-wrong-2026\"}" "${ASPECT}/admin/login" 2>&1)"
BAD_CODE="${BAD_BODY##*__CODE__}"
if [[ "${BAD_CODE}" == "401" ]]; then
  ok "7.5b.2 错误口令 POST /admin/login（JSON）→ 401（$(printf '%s' "${BAD_BODY%$'\n'__CODE__*}" | head -c 90)）"
else
  bad "7.5b.2 错误口令 POST /admin/login → ${BAD_CODE}（期望 401）"
fi

# 7.5b.3 正确口令 → 200 + adminToken + Set-Cookie（管理侧独立 JWT）
LOGIN_BODY="$(admin_curl -D "${WORK}/logs/admin_login_headers.txt" -w '\n__CODE__%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" "${ASPECT}/admin/login" 2>&1)"
LOGIN_CODE="${LOGIN_BODY##*__CODE__}"; LOGIN_JSON="${LOGIN_BODY%$'\n'__CODE__*}"
printf '%s' "${LOGIN_JSON}" > "${WORK}/logs/admin_login.json"
ADMIN_TOKEN="$(printf '%s' "${LOGIN_JSON}" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("data",{}).get("adminToken",""))
except Exception: print("")' 2>/dev/null)"
COOKIE_SET="$(grep -ci 'set-cookie: carbonboo_admin_token=' "${WORK}/logs/admin_login_headers.txt" 2>/dev/null || true)"
if [[ "${LOGIN_CODE}" == "200" && -n "${ADMIN_TOKEN}" && "${COOKIE_SET}" -ge 1 ]]; then
  ok "7.5b.3 正确口令 → 200 + adminToken（长度 ${#ADMIN_TOKEN}）+ Set-Cookie: carbonboo_admin_token（HttpOnly 会话）"
else
  bad "7.5b.3 登录失败（code=${LOGIN_CODE} token 长度 ${#ADMIN_TOKEN} Set-Cookie 次数 ${COOKIE_SET}）"
fi

# 7.5b.4 用户列表（7.5 刚注册的客户端账号必须在里面）
USERS_BODY="$(admin_curl -w '\n__CODE__%{http_code}' "${ASPECT}/admin/users" 2>&1)"
USERS_CODE="${USERS_BODY##*__CODE__}"; USERS_JSON="${USERS_BODY%$'\n'__CODE__*}"
printf '%s' "${USERS_JSON}" > "${WORK}/logs/admin_users.json"
if [[ "${USERS_CODE}" == "200" ]] && printf '%s' "${USERS_JSON}" | grep -q "${APP_USER_NAME}"; then
  ok "7.5b.4 GET /admin/users → 200 且含 7.5 注册的客户端账号 ${APP_USER_NAME}（会话 Cookie 生效）"
else
  bad "7.5b.4 GET /admin/users → ${USERS_CODE}，未找到 ${APP_USER_NAME}（体：${USERS_JSON:0:120}）"
fi

# 7.5b.5 数据总览
OV_BODY="$(admin_curl -w '\n__CODE__%{http_code}' "${ASPECT}/admin/overview" 2>&1)"
OV_CODE="${OV_BODY##*__CODE__}"; OV_JSON="${OV_BODY%$'\n'__CODE__*}"
printf '%s' "${OV_JSON}" > "${WORK}/logs/admin_overview.json"
if [[ "${OV_CODE}" == "200" ]] && printf '%s' "${OV_JSON}" | grep -q '"ok":true'; then
  ok "7.5b.5 GET /admin/overview → 200（$(printf '%s' "${OV_JSON}" | head -c 100)…）"
else
  bad "7.5b.5 GET /admin/overview → ${OV_CODE}（体：${OV_JSON:0:120}）"
fi

# 7.5b.6 配置读 → 写 → 回显（PUT 只改传了的项，回 changed）
CFG_BEFORE="$(admin_curl "${ASPECT}/admin/config" 2>&1)"
CAP_BEFORE="$(printf '%s' "${CFG_BEFORE}" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("data",{}).get("dailyCap",""))
except Exception: print("")' 2>/dev/null)"
PUT_BODY="$(admin_curl -w '\n__CODE__%{http_code}' -X PUT -H 'Content-Type: application/json' \
  -d '{"dailyCap":250}' "${ASPECT}/admin/config" 2>&1)"
PUT_CODE="${PUT_BODY##*__CODE__}"; PUT_JSON="${PUT_BODY%$'\n'__CODE__*}"
printf '%s' "${PUT_JSON}" > "${WORK}/logs/admin_config_put.json"
CFG_AFTER="$(admin_curl "${ASPECT}/admin/config" 2>&1)"
CAP_AFTER="$(printf '%s' "${CFG_AFTER}" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("data",{}).get("dailyCap",""))
except Exception: print("")' 2>/dev/null)"
if [[ "${PUT_CODE}" == "200" ]] && printf '%s' "${PUT_JSON}" | grep -q 'dailyCap' \
  && [[ "${CAP_AFTER}" == "250" ]]; then
  ok "7.5b.6 GET /admin/config dailyCap=${CAP_BEFORE} → PUT {\"dailyCap\":250} → 200 changed=$(printf '%s' "${PUT_JSON}" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("data",{}).get("changed"))
except Exception: print("?")' 2>/dev/null) → 回显 dailyCap=${CAP_AFTER}"
else
  bad "7.5b.6 配置写入/回显异常（PUT=${PUT_CODE} 回显=${CAP_AFTER} 体：${PUT_JSON:0:120}）"
fi

# 7.5b.7 图标上传（image/png 原始字节）→ 7.5b.8 取回
PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=='
printf '%s' "${PNG_B64}" | base64 -d > "${WORK}/t75_icon.png"
ICON_BODY="$(admin_curl -w '\n__CODE__%{http_code}' -X POST -H 'Content-Type: image/png' --data-binary "@${WORK}/t75_icon.png" \
  "${ASPECT}/admin/items/frame_01/icon" 2>&1)"
ICON_CODE="${ICON_BODY##*__CODE__}"; ICON_JSON="${ICON_BODY%$'\n'__CODE__*}"
printf '%s' "${ICON_JSON}" > "${WORK}/logs/admin_icon_upload.json"
ICON_NAME="$(printf '%s' "${ICON_JSON}" | grep -oE '/admin/icons/[A-Za-z0-9._-]+' | head -1 | sed 's|/admin/icons/||')"
if [[ "${ICON_CODE}" == "200" && -n "${ICON_NAME}" ]]; then
  ok "7.5b.7 POST /admin/items/frame_01/icon（Content-Type: image/png + $(stat -c%s "${WORK}/t75_icon.png") 字节）→ 200，落盘 ${ICON_NAME}"
else
  bad "7.5b.7 图标上传失败（code=${ICON_CODE} 体：${ICON_JSON:0:140}）"
fi
if [[ -n "${ICON_NAME}" ]]; then
  ICON_DL="${WORK}/logs/icon_downloaded.bin"
  ICON_HDRS="$(admin_curl -D - -o "${ICON_DL}" -w '\n__CODE__%{http_code}' "${ASPECT}/admin/icons/${ICON_NAME}" 2>&1)"
  ICON_DL_CODE="${ICON_HDRS##*__CODE__}"
  ICON_DL_BYTES="$(stat -c%s "${ICON_DL}" 2>/dev/null || echo 0)"
  if [[ "${ICON_DL_CODE}" == "200" ]] && [[ "${ICON_DL_BYTES}" -gt 0 ]] \
    && printf '%s' "${ICON_HDRS}" | grep -qi 'content-type: image/png'; then
    ok "7.5b.8 GET /admin/icons/${ICON_NAME} → 200 + image/png（${ICON_DL_BYTES} 字节）"
  else
    bad "7.5b.8 取回调标失败（code=${ICON_DL_CODE} bytes=${ICON_DL_BYTES}）"
  fi
else
  bad "7.5b.8 取回调标失败（上传未返回文件名）"
fi

# 7.5b.9 改密 → 旧口令失效 / 新口令可用
PW_BODY="$(admin_curl -w '\n__CODE__%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "{\"oldPassword\":\"${ADMIN_PASS}\",\"newPassword\":\"${ADMIN_NEW_PASS}\"}" "${ASPECT}/admin/password" 2>&1)"
PW_CODE="${PW_BODY##*__CODE__}"
OLD_AGAIN="$(admin_curl -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" "${ASPECT}/admin/login" 2>/dev/null)"
NEW_OK="$(admin_curl -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_NEW_PASS}\"}" "${ASPECT}/admin/login" 2>/dev/null)"
if [[ "${PW_CODE}" == "200" && "${OLD_AGAIN}" == "401" && "${NEW_OK}" == "200" ]]; then
  ok "7.5b.9 POST /admin/password → 200；旧口令再登录 ${OLD_AGAIN}、新口令登录 ${NEW_OK}（改密真的生效）"
else
  bad "7.5b.9 改密链异常（改密=${PW_CODE} 旧口令=${OLD_AGAIN} 新口令=${NEW_OK}）"
fi

# 7.5b.10 登出 → 会话 Cookie 失效
OUT_BODY="$(admin_curl -w '\n__CODE__%{http_code}' -X POST "${ASPECT}/admin/logout" 2>&1)"
OUT_CODE="${OUT_BODY##*__CODE__}"; OUT_JSON="${OUT_BODY%$'\n'__CODE__*}"
AFTER_OUT="$(admin_curl -o /dev/null -w '%{http_code}' -H 'Accept: text/html' "${ASPECT}/admin/users" 2>/dev/null)"
if [[ "${OUT_CODE}" == "200" ]] && printf '%s' "${OUT_JSON}" | grep -q 'loggedOut' \
  && [[ "${AFTER_OUT}" != "200" ]]; then
  ok "7.5b.10 POST /admin/logout → 200 loggedOut；登出后再取 /admin/users → ${AFTER_OUT}（会话已失效）"
else
  bad "7.5b.10 登出链异常（logout=${OUT_CODE} 登出后取列表=${AFTER_OUT}）"
fi

# 7.5b.11 客户端令牌经 nginx 打 /admin/* 一律 403（管理端与客户端两套 JWT）
C403_ALL=1
for p in /admin/users /admin/overview /admin/config /admin/icons/none.png; do
  c="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' --cacert "${CERTS}/fullchain.pem" \
      --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" -H "Authorization: Bearer ${USER_TOKEN}" \
      "${ASPECT}${p}" 2>/dev/null)"
  note "    客户端令牌 → ${p}：${c}"
  [[ "${c}" == "403" ]] || C403_ALL=0
done
if [[ -n "${USER_TOKEN}" && "${C403_ALL}" == "1" ]]; then
  ok "7.5b.11 客户端令牌经 nginx 打 /admin/users、/admin/overview、/admin/config、/admin/icons/* → 全部 403"
else
  bad "7.5b.11 客户端令牌打 /admin/* 未全部 403（见上面逐条）"
fi

# 7.6 限流（放在最后：zone 是共享的，避免污染前面的正常请求）
log "7.6 限流实测（zone=carbonboo_login，rate=20r/m）"
LIMIT_429=0; LIMIT_OTHER=0
for i in $(seq 1 40); do
  c="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' --cacert "${CERTS}/fullchain.pem" \
      --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" -X POST -H 'Content-Type: application/json' \
      -d '{"username":"nobody","password":"wrongpass"}' \
      "https://${DOMAIN}:${HTTPS_PORT}/api/v1/auth/login" 2>/dev/null)"
  if [[ "${c}" == "429" ]]; then LIMIT_429=$((LIMIT_429+1)); else LIMIT_OTHER=$((LIMIT_OTHER+1)); fi
done
note "    POST /api/v1/auth/login × 40 → 429=${LIMIT_429} 其它=${LIMIT_OTHER}"
if [[ "${LIMIT_429}" -gt 0 ]]; then
  ok "7.6a 登录接口超阈值被拒：40 次里 ${LIMIT_429} 次拿到 429（limit_req_status 429 生效）"
else
  bad "7.6a 登录接口未触发限流（429 次数 0）"
fi
LIMIT_503=0; LIMIT_SHOP_OK=0
for i in $(seq 1 30); do
  c="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' --cacert "${CERTS}/fullchain.pem" \
      --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
      "https://${DOMAIN}:${HTTPS_PORT}/api/v1/shop/items" 2>/dev/null)"
  if [[ "${c}" == "503" ]]; then LIMIT_503=$((LIMIT_503+1)); elif [[ "${c}" == "200" ]]; then LIMIT_SHOP_OK=$((LIMIT_SHOP_OK+1)); fi
done
note "    GET /api/v1/shop/items × 30 → 503=${LIMIT_503} 200=${LIMIT_SHOP_OK}"
if [[ "${LIMIT_503}" -gt 0 ]]; then
  ok "7.6b 取价接口超阈值被拒：30 次里 ${LIMIT_503} 次拿到 503（该 location 未设 limit_req_status → nginx 默认 503）"
else
  bad "7.6b 取价接口未触发限流（503 次数 0）"
fi
if [[ "${LIMIT_SHOP_OK}" -gt 0 ]]; then
  ok "7.6c 同接口未超阈值时仍正常 200（${LIMIT_SHOP_OK} 次）"
else
  bad "7.6c 取价接口在阈值内也拿不到 200"
fi
# 7.6d 管理端登录路径也吃同一个 zone（证明 nginx 自己那层没被旁路；每次换 username 以排除应用层
#      `admin|<IP>|<username>` 计数器的干扰，423/429 只能来自 nginx 的 limit_req）
N429_ADMIN=0; OTHER_ADMIN=0
for i in $(seq 1 12); do
  c="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' --cacert "${CERTS}/fullchain.pem" \
      --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" -X POST -H 'Content-Type: application/json' \
      -d "{\"username\":\"probe_${i}\",\"password\":\"wrong-${i}-pass\"}" \
      "https://${DOMAIN}:${HTTPS_PORT}/admin/login" 2>/dev/null)"
  if [[ "${c}" == "429" ]]; then N429_ADMIN=$((N429_ADMIN+1)); else OTHER_ADMIN=$((OTHER_ADMIN+1)); fi
done
note "    POST /admin/login × 12（每次不同 username）→ 429=${N429_ADMIN} 其它=${OTHER_ADMIN}"
if [[ "${N429_ADMIN}" -gt 0 ]]; then
  ok "7.6d 管理端登录路径共享 carbonboo_login zone：12 次里 ${N429_ADMIN} 次 429（nginx 层限流对 /admin/(login|password) 生效）"
else
  bad "7.6d 管理端登录路径未触发 nginx 限流（429 次数 0）"
fi

# ============================================================ 8. 备份与还原 ===
log "8. backup-mysql.sh 真跑 + 真还原"
docker rm -f "${BAK_NAME}" >/dev/null 2>&1
docker run --rm --name "${BAK_NAME}" --network "${NET}" \
  -v "${SERVER}/deploy:/opt/carbonboo/server/deploy:ro" \
  -v "${WORK}/app.env:/opt/carbonboo/server/.env:ro" \
  -v "${WORK}/backups:/var/backups/carbonboo" \
  -e CARBONBOO_BACKUP_DIR=/var/backups/carbonboo \
  "${MYSQL_IMAGE}" bash /opt/carbonboo/server/deploy/backup-mysql.sh \
  > "${WORK}/logs/backup.log" 2>&1 && rc_bak=0 || rc_bak=$?
sed 's/^/    /' "${WORK}/logs/backup.log"
assert_rc "8.1 backup-mysql.sh 退出码 0" "${rc_bak}"
DUMP="$(ls -1 "${WORK}"/backups/carbonboo-*.sql.gz 2>/dev/null | head -1)"
if [[ -n "${DUMP}" && -s "${DUMP}" ]]; then
  DUMP_SIZE="$(stat -c%s "${DUMP}")"
  ok "8.2 dump 非空：$(basename "${DUMP}") ${DUMP_SIZE} 字节（$(du -h "${DUMP}" | cut -f1)）"
else
  bad "8.2 未产出 dump 文件"
fi
if [[ -n "${DUMP}" ]]; then
  # dump 由容器内 root 按 600 写出（脚本第 48 行 chmod 600），WSL 侧读不了 → 一律用容器读
  docker run --rm -v "${WORK}/backups:/b:ro" "${MYSQL_IMAGE}" bash -c '
    f="$(ls /b/carbonboo-*.sql.gz | head -1)"
    gzip -t "$f" && echo "GZIP_OK" || echo "GZIP_BAD"
    echo "SIZE=$(stat -c%s "$f")"
    echo "PERM=$(stat -c%a "$f")"
    echo "TABLES=$(zcat "$f" | grep -c "^CREATE TABLE")"
    echo "UNCOMPRESSED_BYTES=$(zcat "$f" | wc -c)"
    echo "FIRST_LINE=$(zcat "$f" | head -1)"
  ' > "${WORK}/logs/dump_check.log" 2>&1
  sed 's/^/    /' "${WORK}/logs/dump_check.log"
  grep -q '^GZIP_OK$' "${WORK}/logs/dump_check.log" && ok "8.3 gzip 完整性校验通过（容器内 gzip -t）" || bad "8.3 gzip 文件损坏"
  DUMP_TABLES="$(grep -o '^TABLES=[0-9]*' "${WORK}/logs/dump_check.log" | cut -d= -f2)"
  if [[ "${DUMP_TABLES}" == "21" ]]; then ok "8.4 dump 内 CREATE TABLE 数 = 21"; else bad "8.4 dump 内 table 数 = ${DUMP_TABLES}（期望 21）"; fi
  PERM="$(grep -o '^PERM=[0-9]*' "${WORK}/logs/dump_check.log" | cut -d= -f2)"
  [[ "${PERM}" == "600" ]] && ok "8.5 dump 权限 = 600（脚本第 48 行 chmod）" || bad "8.5 dump 权限 = ${PERM}（期望 600）"
  UNZ="$(grep -o '^UNCOMPRESSED_BYTES=[0-9]*' "${WORK}/logs/dump_check.log" | cut -d= -f2)"
  note "    解压后 ${UNZ} 字节（$(grep -o '^FIRST_LINE=.*' "${WORK}/logs/dump_check.log" | cut -d= -f2-)）"
  grep -q 'find "${BACKUP_DIR}" -name .carbonboo-\*.sql.gz. -type f -mtime "+${KEEP_DAYS}" -print -delete' "${BACKUP_SH}" \
    && ok "8.6 14 天轮转逻辑在脚本内（find ... -mtime +KEEP_DAYS -print -delete）" \
    || bad "8.6 未在脚本中找到 14 天轮转逻辑"
  # 真还原：把 dump 导入临时库（在**另一个**容器里做，证明备份可被独立恢复）
  docker run --rm --network "${NET}" -e MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" \
    -e MH="${MYSQL_HOST_FOR_CONTAINER}" -e MP="${MYSQL_PORT_FOR_CONTAINER}" \
    -e MU="${MYSQL_ADMIN_USER}" -e RDB="${E2E_DB_RESTORE}" \
    -v "${WORK}/backups:/b:ro" "${MYSQL_IMAGE}" bash -c '
      f="$(ls /b/carbonboo-*.sql.gz | head -1)"
      zcat "$f" | mysql --protocol=TCP -h"$MH" -P"$MP" -u"$MU" "$RDB"
    ' > "${WORK}/logs/restore.log" 2>&1 && rc_res=0 || rc_res=$?
  assert_rc "8.7 把 dump 导回临时库 ${E2E_DB_RESTORE}（独立容器执行）" "${rc_res}"
  TABLES="$(mysql_root -N -B -e "SELECT table_name FROM information_schema.tables WHERE table_schema='${E2E_DB}' ORDER BY table_name;" 2>/dev/null | tr -d '\r')"
  ROWDIFF=0; ROWS_REPORT=""
  for t in ${TABLES}; do
    a="$(mysql_root -N -B -e "SELECT COUNT(*) FROM \`${E2E_DB}\`.\`${t}\`;" 2>/dev/null | tr -d '[:space:]')"
    b="$(mysql_root -N -B -e "SELECT COUNT(*) FROM \`${E2E_DB_RESTORE}\`.\`${t}\`;" 2>/dev/null | tr -d '[:space:]')"
    [[ "${a}" == "${b}" ]] || ROWDIFF=$((ROWDIFF+1))
    ROWS_REPORT="${ROWS_REPORT}$(printf '%-24s %6s %6s\n' "${t}" "${a}" "${b}")"$'\n'
  done
  printf '%s' "${ROWS_REPORT}" > "${WORK}/logs/rowcounts.txt"
  note "    逐表行数（源库 / 还原库）保存在 ${WORK}/logs/rowcounts.txt："
  printf '%s' "${ROWS_REPORT}" | sed -n '1,6p' | sed 's/^/      /'
  note "    …（共 $(printf '%s' "${TABLES}" | wc -w) 张表）"
  if [[ "${ROWDIFF}" == "0" ]]; then ok "8.8 还原后逐表行数与源库完全一致（21/21 表）"; else bad "8.8 还原后有 ${ROWDIFF} 张表行数不一致"; fi
fi

# ================================================ 9. migrate.sh 与 systemd ===
log "9. migrate.sh（dry-run / 真跑 / 两个安全阀）"
docker run --rm --network "${NET}" \
  -v "${SERVER}/deploy:/opt/carbonboo/server/deploy:ro" \
  -v "${SERVER}/sql:/opt/carbonboo/server/sql:ro" \
  -v "${WORK}/app.env:/opt/carbonboo/server/.env:ro" \
  "${MYSQL_IMAGE}" bash /opt/carbonboo/server/deploy/migrate.sh "${E2E_DB}" --dry-run \
  > "${WORK}/logs/migrate_dry.log" 2>&1 && rc_md=0 || rc_md=$?
sed 's/^/    /' "${WORK}/logs/migrate_dry.log"
assert_rc "9.1 migrate.sh --dry-run 退出码 0（只列不连库）" "${rc_md}"
docker run --rm --network "${NET}" \
  -v "${SERVER}/deploy:/opt/carbonboo/server/deploy:ro" \
  -v "${SERVER}/sql:/opt/carbonboo/server/sql:ro" \
  -v "${WORK}/app.env:/opt/carbonboo/server/.env:ro" \
  "${MYSQL_IMAGE}" bash /opt/carbonboo/server/deploy/migrate.sh "${E2E_DB}" \
  > "${WORK}/logs/migrate_real.log" 2>&1 && rc_mr=0 || rc_mr=$?
sed 's/^/    /' "${WORK}/logs/migrate_real.log"
assert_rc "9.2 migrate.sh 真跑任务库退出码 0" "${rc_mr}"
grep -q 'user_id,source_type,source_id,flow_kind' "${WORK}/logs/migrate_real.log" \
  && ok "9.3 迁移后 uq_pr_source 索引列 = user_id,source_type,source_id,flow_kind" \
  || bad "9.3 uq_pr_source 索引列校验未通过"
docker run --rm -v "${SERVER}/deploy:/opt/carbonboo/server/deploy:ro" \
  "${MYSQL_IMAGE}" bash /opt/carbonboo/server/deploy/migrate.sh carbonboo_test_guard \
  > "${WORK}/logs/migrate_guard_testname.log" 2>&1 && rc_g1=0 || rc_g1=$?
if [[ "${rc_g1}" == "2" ]] && grep -q 'STOP: 库名' "${WORK}/logs/migrate_guard_testname.log"; then
  ok "9.4 安全阀①：库名含 test → 拒跑（exit 2）"
else
  bad "9.4 安全阀①失效（rc=${rc_g1}）"
fi
# 安全阀② 要的是「有 bash、**没有 mysql 客户端**」的环境。原实现用 alpine + `apk add bash`，
# 一旦拉不到 Alpine 镜像源就变成 rc=127（command not found）→ 门禁假红。改用本地已在的 ${PY_IMAGE}
# （python:3.11-slim：自带 bash、无 mysql/mariadb 客户端），语义完全相同且不依赖网络。
docker run --rm --network "${NET}" -v "${SERVER}/deploy:/opt/carbonboo/server/deploy:ro" \
  -v "${SERVER}/sql:/opt/carbonboo/server/sql:ro" \
  "${PY_IMAGE}" bash /opt/carbonboo/server/deploy/migrate.sh carbonboo_deploy_e2e \
  > "${WORK}/logs/migrate_guard_noclient.log" 2>&1 && rc_g2=0 || rc_g2=$?
if [[ "${rc_g2}" == "3" ]]; then
  ok "9.5 安全阀②：无 mysql 客户端 → 拒跑（exit 3，不静默跳过迁移）"
else
  bad "9.5 安全阀②失效（rc=${rc_g2}）"
fi

log "9.6 systemd 单元（静态校验；真启动见 9.8）"
if command -v systemd-analyze >/dev/null 2>&1; then
  # (a) 原样对仓库路径做 verify（/mnt/c 由 drvfs 挂载，权限位被放成 0777 + 生产安装路径 /opt/carbonboo 本机不存在）
  systemd-analyze verify "${SYSTEMD_DIR}"/*.service "${SYSTEMD_DIR}"/*.timer \
    > "${WORK}/logs/systemd_verify_raw.log" 2>&1 && rc_sd=0 || rc_sd=$?
  note "    9.6a 对仓库路径原样 verify：退出码 = ${rc_sd}（原文 ${WORK}/logs/systemd_verify_raw.log）"
  ERR_SD="$(grep -c 'is not executable: No such file or directory' "${WORK}/logs/systemd_verify_raw.log")"
  OTHER_SD="$(grep -v 'is marked executable\|is marked world-writable\|is not executable: No such file or directory\|^$' "${WORK}/logs/systemd_verify_raw.log" | wc -l)"
  sed -n '7,9p' "${WORK}/logs/systemd_verify_raw.log" | sed 's/^/      /'
  if [[ "${ERR_SD}" == "2" && "${OTHER_SD}" == "0" ]]; then
    ok "9.6a 原样 verify 的报错全部可归因于环境（drvfs 权限位 + 生产路径 /opt/carbonboo 不存在），无语法/依赖类错误"
  else
    bad "9.6a 原样 verify 出现非环境类错误（not-executable=${ERR_SD} 其它=${OTHER_SD}）"
  fi
  # (b) 把单元复制到非 drvfs 的临时目录 + 644，并把 ExecStart 的 /opt/carbonboo 前缀换成 stub（S5）
  STUB="${WORK}/stub/opt/carbonboo/server/.venv/bin"
  mkdir -p "${STUB}" "${WORK}/units"
  for b in python uvicorn; do printf '#!/bin/sh\nexit 0\n' > "${STUB}/${b}"; chmod 755 "${STUB}/${b}"; done
  for f in "${SYSTEMD_DIR}"/*.service "${SYSTEMD_DIR}"/*.timer; do
    sed "s#/opt/carbonboo#${WORK}/stub/opt/carbonboo#g" "$f" > "${WORK}/units/$(basename "$f")"
  done
  chmod 644 "${WORK}/units"/*
  systemd-analyze verify "${WORK}/units"/*.service "${WORK}/units"/*.timer \
    > "${WORK}/logs/systemd_verify_stub.log" 2>&1 && rc_sd2=0 || rc_sd2=$?
  note "    9.6b 单元复制到 ${WORK}/units（mode 644）+ ExecStart 前缀 S5 换成 stub：退出码 = ${rc_sd2}"
  sed -n '1,6p' "${WORK}/logs/systemd_verify_stub.log" | sed 's/^/      /'
  if [[ "${rc_sd2}" == "0" ]]; then ok "9.6b 单元语法/指令/依赖全部通过 systemd-analyze verify（唯一失败原因是生产安装路径不存在）"; else bad "9.6b 单元本体有错（rc=${rc_sd2}）"; fi
else
  note "    systemd-analyze 不存在 → 记「未运行」"; bad "9.6 systemd-analyze 不可用（未运行）"
fi
grep -q 'ExecStart=/opt/carbonboo/server/.venv/bin/uvicorn app.main:app' "${SYSTEMD_DIR}/carbonboo-server.service" \
  && grep -q -- '--workers 2' "${SYSTEMD_DIR}/carbonboo-server.service" \
  && ok "9.7 单元 ExecStart 与本次实跑的应用启动形态一致（uvicorn app.main:app --workers 2）" \
  || bad "9.7 单元 ExecStart 与实跑形态不一致"
if command -v systemctl >/dev/null 2>&1; then
  note "    systemctl: $(command -v systemctl)（宿主 PID1 = $(ps -p 1 -o comm= 2>/dev/null || echo '?')；单元的真启动由 9.8 在 PID1=systemd 的容器里做）"
else
  note "    systemctl 不存在 → 静态校验到 9.6 为止（真启动见 9.8）"
fi
# 9.6c/9.6d 单元内容逐条核对（这部分与 systemd-analyze 无关，是纯文本事实）
SVC="${SYSTEMD_DIR}/carbonboo-server.service"; PURGE="${SYSTEMD_DIR}/carbonboo-purge.service"; TMR="${SYSTEMD_DIR}/carbonboo-purge.timer"
sd_miss=""
for pat in 'ExecStart=/opt/carbonboo/server/.venv/bin/uvicorn app.main:app' '--host 127.0.0.1' '--port 8000' '--workers 2' '--proxy-headers' '--forwarded-allow-ips=127.0.0.1' 'User=carbonboo' 'After=network-online.target mysql.service' 'Restart=always' 'RestartSec=3' 'EnvironmentFile=-/opt/carbonboo/server/deploy/carbonboo.env' 'ProtectSystem=strict' 'NoNewPrivileges=true' 'Type=simple'; do
  grep -q -- "${pat}" "${SVC}" || sd_miss="${sd_miss} [${pat}]"
done
if [[ -z "${sd_miss}" ]]; then ok "9.6c carbonboo-server.service 的 ExecStart/加固/重启策略 14 项逐条命中"; else bad "9.6c server.service 缺：${sd_miss}"; fi
sd_miss=""
for pat in 'Type=oneshot' 'User=carbonboo' 'ExecStart=/opt/carbonboo/server/.venv/bin/python -m app.services.auth_provider' 'OnCalendar=\*-\*-\* 04:23:00' 'RandomizedDelaySec=600' 'Persistent=true' 'Unit=carbonboo-purge.service' 'WantedBy=timers.target'; do
  grep -q -- "${pat}" "${PURGE}" "${TMR}" || sd_miss="${sd_miss} [${pat}]"
done
if [[ -z "${sd_miss}" ]]; then ok "9.6d purge.service/.timer（30 天物理清除 + 每日 04:23 + 随机延迟 + 持久化）逐条命中"; else bad "9.6d purge 单元缺：${sd_miss}"; fi
if grep -qE 'JWT_SECRET|MYSQL_PASSWORD|ADMIN_JWT_SECRET|password=' "${SVC}" "${PURGE}" "${TMR}"; then
  bad "9.6e 单元文件里出现机密字样（密钥只应进 server/.env）"
else
  ok "9.6e 三个单元文件内无机密（密钥只从 server/.env 600 读）"
fi

# ================================== 9.8 systemd 单元与 timer 的真启动（t75） ====
# t56 的「未运行项②」在本轮被关掉：宿主 WSL 的 PID1 **就是 systemd**（实测 `ps -p 1 -o comm=` → systemd、
# `systemctl is-system-running` → running），但没有 root（`sudo -n` 需交互认证），所以真启动放在
# **PID1 = systemd 的容器**里做：真装 /opt/carbonboo 布局 → 装三个单元（逐字节）→ start → status/journalctl
# → list-timers → 用容器内的临时副本（OnCalendar 每分钟 + RandomizedDelaySec=0）真触发一次 purge。
log "9.8 systemd 真启动（PID1=systemd 容器：单元 + timer 真拉起，t75 补 t56 未运行项②）"
SD_LOG="${WORK}/logs/run_systemd.log"
L1_KEEP="${KEEP}" bash "${HERE}/run_systemd.sh" >"${SD_LOG}" 2>&1 && rc_sd3=0 || rc_sd3=$?
grep -E '^(PASS|FAIL): ' "${SD_LOG}" | sed 's/^/  /' || true
note "    子脚本退出码 = ${rc_sd3}（0=全过 1=有失败 2=环境不可达）；原始输出 ${SD_LOG}"
if [[ "${rc_sd3}" == "0" ]]; then
  ok "9.8 systemd 真启动：三个单元与 purge timer 在 PID1=systemd 的容器里真跑通（逐条 PASS 见上）"
elif [[ "${rc_sd3}" == "1" ]]; then
  sd_fails="$(grep -c '^FAIL: ' "${SD_LOG}")"
  tail -8 "${SD_LOG}" | sed 's/^/      /'
  bad "9.8 systemd 真启动有 ${sd_fails} 条断言未过（细节见 ${SD_LOG}）"
else
  bad "9.8 systemd 真启动**未运行**（环境不可达，子脚本退出码 ${rc_sd3}；原始输出 ${SD_LOG}）"
fi

# ================================================================ 10. 收尾 ====
log "10. 收尾清理"
docker rm -f "${APP_NAME}" "${WEB_NAME}" "${BAK_NAME}" >/dev/null 2>&1
LEFT="$(docker ps -a --format '{{.Names}}' | grep -c 'carbonboo-deploy-e2e')"
if [[ "${LEFT}" == "0" ]]; then ok "10.1 本工具的三个容器已全部删除"; else bad "10.1 残留容器 ${LEFT} 个"; fi
MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" mysql_root -e \
  "DROP DATABASE IF EXISTS \`${E2E_DB}\`; DROP DATABASE IF EXISTS \`${E2E_DB_RESTORE}\`;" >/dev/null 2>&1
DBS_LEFT="$(mysql_root -N -B -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name IN ('${E2E_DB}','${E2E_DB_RESTORE}');" 2>/dev/null | tr -d '[:space:]')"
if [[ "${DBS_LEFT}" == "0" ]]; then ok "10.2 两个临时库已删除"; else bad "10.2 残留临时库 ${DBS_LEFT} 个"; fi
docker network disconnect "${NET}" carbonboo-mysql >/dev/null 2>&1; MYSQL_ATTACHED=0
NETS="$(docker inspect carbonboo-mysql --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
note "    carbonboo-mysql 现在的网络：${NETS}"
docker network rm "${NET}" >/dev/null 2>&1; NET_CREATED=0
NET_LEFT="$(docker network ls --format '{{.Name}}' | grep -c 'carbonboo-deploy-e2e')"
if [[ "${NET_LEFT}" == "0" ]]; then ok "10.3 派生网络已删除"; else bad "10.3 残留网络"; fi
GITDIRTY="$(cd "${REPO}" && git status --short -- app/ server/ docs/ tests/cases/ 2>/dev/null | wc -l)"
if [[ "${GITDIRTY}" == "0" ]]; then ok "10.4 被测路径 git status 干净（app/ server/ docs/ tests/cases/）"; else bad "10.4 被测路径有 ${GITDIRTY} 处改动"; fi

# ============================================================== 11. 结果 ======
log "11. 结果"
printf '探针：PASS=%d FAIL=%d\n' "${PASS}" "${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  printf '失败项：\n'; for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "${n}"; done
fi
printf '证据目录：%s（nginx -T 原文、证书、dump、逐表行数、各探针原始输出）\n' "${WORK}"
if [[ "${KEEP}" == "1" ]]; then
  printf '（L1_KEEP=1：现场保留在 %s）\n' "${WORK}"
else
  printf '提示：想保留现场请用 L1_KEEP=1 重跑（默认删除 %s）\n' "${WORK}"
fi
printf '\n未运行清单（明确**不算通过**，与上面 PASS 严格分开）：\n'
printf '  - N1 systemd 真启动已由 9.8 关闭（PID1=systemd 容器内装单元→daemon-reload→start→status→journalctl→\n'
printf '       list-timers→真触发一次 purge）；**仍未运行**的是真云 VM 上的开机自启持久化（跨重启的 enable 状态）\n'
printf '       与 systemd-analyze security 评分 —— 容器不是云主机，这一条不冒充\n'
printf '  - N2 certbot 真实签发与续期未跑：未接 ACME 服务器（不联网），证书用 openssl 自签替代\n'
printf '  - N3 公网域名 api.example.com 的 DNS/防火墙/WAF 未验证：只有本机端口映射 + Host 头\n'
printf '  - N4 mysqldump 的锁表与耗时未做规模测试：任务库只有种子级数据（解压后 KB 级）\n'
printf '  - N5 生产 MySQL 普通用户凭据未验证：本工具用 server/.env 里的管理员凭据建库/还原\n'
if [[ "${FAIL}" -eq 0 ]]; then
  printf 'RESULT: PASS —— server/deploy/ 四件实物容器化实跑全部通过\n'
  exit 0
else
  printf 'RESULT: FAIL —— %d 项未通过\n' "${FAIL}"
  exit 1
fi
