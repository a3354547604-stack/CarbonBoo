#!/usr/bin/env bash
# =============================================================================
# CarbonBoo · systemd 单元与 timer 的**真启动**（tests/tools/deploy_e2e/run_systemd.sh）
#
# 职责（t75 补 t56 的未运行项②）
# ------------------------------
# t56 只做到「静态校验」：`systemd-analyze verify` + 单元内容逐条核对，理由是「WSL 无 PID1 systemd」。
# 本脚本把单元**真的启动一次**：在一个 **PID1 = systemd** 的容器里真装出 `/opt/carbonboo/` 布局，
# `systemctl daemon-reload` → `start` → `status` / `journalctl -u` 留证；再把 `carbonboo-purge.timer`
# 起起来、`list-timers` 列出，并用**容器内的临时副本**（`OnCalendar` 改成每分钟）真触发一次 purge。
#
# 被测实物（`server/deploy/systemd/` 三个文件）**一个字节都不改**：
# 只读挂载仓库 → `install -m 644` 到容器 `/etc/systemd/system/`，并逐文件比对 sha256。
#
# 派生清单（与真机的差异，全部逐条打印）
# -------------------------------------
#   D1 容器内的 `/opt/carbonboo/server` 是仓库 `server/` 的副本（tar 管道，排除 `.venv`/`__pycache__`）
#   D2 容器内的 `.venv` 用容器自带 python3.11 现建 + `pip install -r requirements.txt`（走阿里云镜像，
#      与 requirements.txt 头注释口径一致）；pip 不通时回退「复制宿主 venv 的 site-packages + 生成
#      uvicorn 控制台脚本」，并在输出里写明走了哪条路
#   D3 `/opt/carbonboo/server/.env` 由仓库 `.env` 派生：只换 `MYSQL_DB`（指向任务库，**不碰生产库**），
#      密钥逐字沿用、从不打印
#   D4 容器的 `carbonboo-purge-e2e.timer` 是 `carbonboo-purge.timer` 的**容器内临时副本**，
#      `OnCalendar` 改为每分钟，只为在本轮内真触发一次；仓库文件与其安装副本都不动
#
# 与真机的差异（结论边界）
# ------------------------
# 容器里的 systemd 不是云 VM 的 PID1，内核/权限是 `--privileged` + `--cgroupns=host` 给的；
# 这验的是「单元本身能被 systemd 接受并真的拉起进程」，不是云厂商镜像、不是公网 systemd 生命周期。
#
# 用法
# ----
#   bash tests/tools/deploy_e2e/run_systemd.sh              # 跑完清理容器与任务库
#   L1_KEEP=1 bash tests/tools/deploy_e2e/run_systemd.sh    # 保留现场（$WORK，含全部原始输出）
#
# 退出码：0 = 全部断言通过；1 = 有断言失败；2 = 环境不可达（docker/镜像/端口/仓库文件/pip）
# 输出约定：每行 `PASS: <名字>` / `FAIL: <名字>`（供 run.sh 汇总），其余为原始输出与 `NOTE:`
# =============================================================================

set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SERVER="$ROOT/server"
UNITS="$SERVER/deploy/systemd"

SD_IMAGE="${DEPLOY_E2E_SD_IMAGE:-jrei/systemd-debian:12}"
# t75：最小 Debian 镜像里连 python3/tar 都没有，而容器内 apt 依赖 Debian 镜像站（实测出现过 502 Bad Gateway
# 导致「环境不可达」）。这里先用**本地已有的两个镜像**派生一个把 python3.11/venv/tar 烘进去的镜像（只联网这一步，
# 之后每次跑都不再联网装包）；派生失败（镜像站不可用）则回退到上游镜像，容器内 apt 兜底。
SD_PREPARED_IMAGE="${DEPLOY_E2E_SD_PREPARED_IMAGE:-carbonboo-systemd-e2e:12}"
SD_APT_MIRROR="${DEPLOY_E2E_SD_APT_MIRROR:-http://mirrors.aliyun.com/}"
SD_NAME="${DEPLOY_E2E_SD_NAME:-carbonboo-deploy-sd-e2e}"
SD_DB="${DEPLOY_E2E_SD_DB:-carbonboo_deploy_e2e_sd}"
PIP_INDEX="${DEPLOY_E2E_PIP_INDEX:-https://mirrors.aliyun.com/pypi/simple/}"
MYSQL_CONTAINER="${DEPLOY_E2E_MYSQL_CONTAINER:-carbonboo-mysql}"
APP_PORT="${DEPLOY_E2E_SD_APP_PORT:-8000}"
KEEP="${L1_KEEP:-0}"
PIP_TIMEOUT="${DEPLOY_E2E_PIP_TIMEOUT:-900}"

WORK="$(mktemp -d /tmp/cbsd.XXXXXX)"
LOGS="$WORK/logs"; mkdir -p "$LOGS"

PASS=0
FAIL=0
declare -a FAILED_NAMES=()

echo_pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
echo_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf 'FAIL: %s\n' "$1"; }
note() { printf 'NOTE: %s\n' "$*"; }
say() { printf '\n=== %s ===\n' "$*"; }

CONTAINER_STARTED=0
DB_CREATED=0

sd_cleanup() {
  if [[ "${CONTAINER_STARTED}" == "1" ]]; then
    docker exec "${SD_NAME}" systemctl disable --now carbonboo-purge-e2e.timer >/dev/null 2>&1
    docker exec "${SD_NAME}" systemctl disable --now carbonboo-purge.timer >/dev/null 2>&1
    docker exec "${SD_NAME}" systemctl stop carbonboo-server >/dev/null 2>&1
    docker rm -f "${SD_NAME}" >/dev/null 2>&1
  fi
  if [[ "${DB_CREATED}" == "1" ]]; then
    mysql_admin -e "DROP DATABASE IF EXISTS \`${SD_DB}\`;" >/dev/null 2>&1
  fi
  if [[ "${KEEP}" == "1" ]]; then
    printf '\n（L1_KEEP=1，保留现场：%s）\n' "${WORK}"
  else
    rm -rf "${WORK}"
  fi
}

fatal() {
  printf '\nENV-FAIL: %s\n' "$1" >&2
  sd_cleanup
  exit 2
}

# 容器内执行（不带 stdin，避免 docker exec 抢走脚本的 stdin）
dsh() { docker exec "${SD_NAME}" sh -c "$1"; }
# 容器内执行并把 stdout 落盘留证
dsh_log() { local name="$1"; shift; docker exec "${SD_NAME}" sh -c "$1" >"${LOGS}/${name}.txt" 2>&1; }

env_get() {
  grep -E "^${1}=" "${SERVER}/.env" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}

# 管理员身份连任务库（凭据只来自 server/.env，从不打印）：宿主 → 项目 MySQL 容器
mysql_admin() {
  docker exec -e MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" -i "${MYSQL_CONTAINER}" \
    mysql -u"${MYSQL_ADMIN_USER}" --default-character-set=utf8mb4 "$@"
}

# =============================================================== 0. 环境检查 ===
say "0. 环境检查（缺任一项 = 环境不可达，退出码 2）"
command -v docker >/dev/null 2>&1 || fatal "没有 docker"
docker info >/dev/null 2>&1 || fatal "docker 不可用"
for f in carbonboo-server.service carbonboo-purge.service carbonboo-purge.timer; do
  [[ -f "${UNITS}/${f}" ]] || fatal "缺 ${UNITS}/${f}"
done
[[ -f "${SERVER}/.env" ]] || fatal "缺 ${SERVER}/.env"
[[ -f "${SERVER}/sql/schema.sql" && -f "${SERVER}/sql/seed.sql" ]] || fatal "缺 sql/schema.sql 或 sql/seed.sql"
docker inspect "${MYSQL_CONTAINER}" >/dev/null 2>&1 || fatal "项目 MySQL 容器 ${MYSQL_CONTAINER} 不存在"
[[ "$(docker inspect -f '{{.State.Running}}' "${MYSQL_CONTAINER}" 2>/dev/null)" == "true" ]] \
  || fatal "${MYSQL_CONTAINER} 未在运行"
if ss -lnt 2>/dev/null | grep -qE ":${APP_PORT}\b"; then
  fatal "宿主端口 ${APP_PORT} 已被占用（systemd 单元要绑 127.0.0.1:${APP_PORT}）"
fi
MYSQL_ADMIN_USER="$(env_get MYSQL_ADMIN_USER)"
MYSQL_ADMIN_PASSWORD="$(env_get MYSQL_ADMIN_PASSWORD)"
[[ -n "${MYSQL_ADMIN_USER}" && -n "${MYSQL_ADMIN_PASSWORD}" ]] || fatal "server/.env 缺 MYSQL_ADMIN_USER/PASSWORD"

# --- systemd 基础镜像就绪（缺则 docker pull；仅此处允许联网） ---
if ! docker image inspect "${SD_IMAGE}" >/dev/null 2>&1; then
  note "本地没有镜像 ${SD_IMAGE}，尝试 docker pull（本脚本是唯一允许联网拉取的地方）"
  if ! timeout 600 docker pull "${SD_IMAGE}" >"${LOGS}/docker_pull.txt" 2>&1; then
    tail -5 "${LOGS}/docker_pull.txt" >&2
    fatal "拉取 ${SD_IMAGE} 失败（见上面原始输出）"
  fi
fi

# --- 预备镜像（把 python3.11/venv/tar 烘进去，避免每次跑都依赖 Debian 镜像站） ---
SD_IMAGE_USE="${SD_IMAGE}"
SD_PREPARED=0
if docker image inspect "${SD_PREPARED_IMAGE}" >/dev/null 2>&1; then
  SD_IMAGE_USE="${SD_PREPARED_IMAGE}"; SD_PREPARED=1
  note "预备镜像 ${SD_PREPARED_IMAGE} 就绪（python3/venv/tar 已烘入，本轮不需要容器内 apt）"
else
  mkdir -p "${WORK}/img"
  cat > "${WORK}/img/Dockerfile" <<DOCKERFILE
FROM ${SD_IMAGE}
RUN sed -i "s|http://deb.debian.org/|${SD_APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources \
 && apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-venv tar ca-certificates \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  note "本地没有预备镜像，尝试用 ${SD_IMAGE} + 镜像站 ${SD_APT_MIRROR} 派生（只这一次联网装包）"
  if timeout 900 docker build -q -t "${SD_PREPARED_IMAGE}" "${WORK}/img" >"${LOGS}/docker_build.txt" 2>&1; then
    SD_IMAGE_USE="${SD_PREPARED_IMAGE}"; SD_PREPARED=1
    note "派生镜像 ${SD_PREPARED_IMAGE} 建成（下次跑直接复用）"
  else
    tail -6 "${LOGS}/docker_build.txt" >&2
    note "派生镜像失败（镜像站不可用？）⇒ 回退上游镜像 ${SD_IMAGE}，由容器内 apt 兜底"
  fi
fi
note "镜像 ${SD_IMAGE_USE} 就绪（prepared=${SD_PREPARED}）；宿主 ${APP_PORT} 空闲；${MYSQL_CONTAINER} 运行中"

# ===================================================== 1. 起 PID1 systemd 容器 ===
say "1. 起容器（PID1 = systemd，--privileged --cgroupns=host --network host）"
docker rm -f "${SD_NAME}" >/dev/null 2>&1
if ! docker run -d --name "${SD_NAME}" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp --network host \
  -v "${SERVER}:/repo/server:ro" -v "${UNITS}:/repo/systemd:ro" \
  "${SD_IMAGE_USE}" >"${LOGS}/docker_run.txt" 2>&1; then
  cat "${LOGS}/docker_run.txt" >&2
  fatal "docker run 失败"
fi
CONTAINER_STARTED=1

SD_STATE=""
for _ in $(seq 1 30); do
  SD_STATE="$(dsh 'systemctl is-system-running' 2>&1 | head -1 | tr -d '\r')"
  case "${SD_STATE}" in running | degraded) break ;; esac
  sleep 2
done
dsh_log sd_baseline 'cat /proc/1/comm; echo "---"; cat /etc/os-release | head -2; echo "---"; systemctl --version | head -1'
cat "${LOGS}/sd_baseline.txt" | sed 's/^/    /'
if [[ "${SD_STATE}" == "running" || "${SD_STATE}" == "degraded" ]]; then
  echo_pass "1.1 容器内 PID1 systemd 可用（is-system-running=${SD_STATE}）"
else
  echo_fail "1.1 容器内 systemd 未就绪（is-system-running=${SD_STATE}）"
fi
if [[ "$(dsh 'cat /proc/1/comm' 2>/dev/null | tr -d '\r')" == "systemd" ]]; then
  echo_pass "1.2 /proc/1/comm = systemd（PID 1 就是 systemd，不是 shim）"
else
  echo_fail "1.2 /proc/1/comm ≠ systemd"
fi

# ============================================ 2. 容器内 python3 + 任务库 + 布局 ===
say "2. 容器内准备（python3.11 / /opt/carbonboo 布局 / 任务库 ${SD_DB}）"
# 最小 Debian 镜像里连 python3/tar 都没有。用预备镜像时这一步天然满足（不联网）；
# 回退到上游镜像时才走容器内 apt，并把 Debian 源换成镜像站 + 最多 3 次重试（实测上游会有 502）。
if dsh 'command -v python3 >/dev/null 2>&1 && command -v tar >/dev/null 2>&1'; then
  note "容器内已具备 python3/tar（预备镜像，未联网安装）"
else
  note "容器内缺 python3/tar ⇒ 用镜像站 ${SD_APT_MIRROR} 安装（最多 3 次重试）"
  apt_ok=0
  for _try in 1 2 3; do
    if dsh "sed -i \"s|http://deb.debian.org/|${SD_APT_MIRROR}|g\" /etc/apt/sources.list.d/debian.sources 2>/dev/null; export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq python3 python3-venv tar ca-certificates" \
      >"${LOGS}/apt.txt" 2>&1; then
      apt_ok=1; break
    fi
    note "    第 ${_try} 次 apt 失败，重试…"
    sleep 3
  done
  if [[ "${apt_ok}" != "1" ]]; then
    tail -8 "${LOGS}/apt.txt" >&2
    fatal "容器内 apt-get install python3 python3-venv tar ca-certificates 失败（三次重试后仍失败，见上面原始输出）"
  fi
fi
PY_VER="$(dsh 'python3 -V' 2>&1 | tr -d '\r')"
note "容器内 ${PY_VER}（/usr/bin/python3）"
echo "${PY_VER}" | grep -q '^Python 3\.11' \
  && echo_pass "2.1 容器内 python3 = ${PY_VER}（与仓库 requirements.txt 的 3.11+ 口径一致）" \
  || echo_fail "2.1 容器内 python3 版本异常：${PY_VER}"

# carbonboo 用户/组（单元里写死 User=carbonboo Group=carbonboo）
dsh 'getent group carbonboo >/dev/null || groupadd --system carbonboo; getent passwd carbonboo >/dev/null || useradd --system --gid carbonboo --home-dir /opt/carbonboo --shell /usr/sbin/nologin carbonboo' \
  >"${LOGS}/useradd.txt" 2>&1
if [[ "$(dsh 'id -u carbonboo 2>/dev/null' | tr -d '\r')" =~ ^[0-9]+$ ]]; then
  echo_pass "2.2 建出 carbonboo 用户/组（$(dsh 'id carbonboo' 2>/dev/null | tr -d '\r')）"
else
  echo_fail "2.2 carbonboo 用户未建出"
fi

# D1：仓库 server/ 的副本（排除 .venv 与 __pycache__；仓库文件只读挂载，绝不改写）
dsh 'mkdir -p /opt/carbonboo && tar -cf - -C /repo server --exclude=server/.venv --exclude=server/.git --exclude="*__pycache__*" | tar -xf - -C /opt/carbonboo' \
  >"${LOGS}/copy_server.txt" 2>&1
dsh_log layout_ls 'ls -1 /opt/carbonboo/server | head -20; echo "--- app:"; ls -1 /opt/carbonboo/server/app | head -10'
if dsh 'test -s /opt/carbonboo/server/app/main.py && test -d /opt/carbonboo/server/admin_web && echo yes' | grep -q yes; then
  echo_pass "2.3 /opt/carbonboo/server 布局就位（$(tr '\n' ' ' <"${LOGS}/layout_ls.txt" | head -c 120)）"
else
  tail -5 "${LOGS}/copy_server.txt" | sed 's/^/    /'
  echo_fail "2.3 /opt/carbonboo/server 布局不完整"
fi

# D2：真 venv + 依赖（pip 走阿里云镜像；不通则回退复制宿主 venv 的 site-packages）
say "2b. 建 venv 并装依赖（D2）"
# D1 说明：真机安装时 `/opt/carbonboo/server/.venv` 由部署者现建；副本里若残留宿主的 `.venv`（排除规则
# 在部分 tar 实现下对 `-C` 相对名不生效）会让 `python3 -m venv` 撞上既有 venv 而报错，因此先清干净。
dsh 'rm -rf /opt/carbonboo/server/.venv' >"${LOGS}/venv_clean.txt" 2>&1
VENV_MODE="pip"
if ! dsh "python3 -m venv /opt/carbonboo/server/.venv" >"${LOGS}/venv.txt" 2>&1; then
  note "带 pip 的 venv 建失败，退回 --without-pip；原始报错："
  tail -4 "${LOGS}/venv.txt" | sed 's/^/    /'
  dsh "rm -rf /opt/carbonboo/server/.venv; python3 -m venv --without-pip /opt/carbonboo/server/.venv" \
    >>"${LOGS}/venv.txt" 2>&1
  VENV_MODE="copy"
fi
if [[ "${VENV_MODE}" == "pip" ]]; then
  if timeout "${PIP_TIMEOUT}" docker exec "${SD_NAME}" sh -c \
    "/opt/carbonboo/server/.venv/bin/pip install -q -r /opt/carbonboo/server/requirements.txt -i ${PIP_INDEX}" \
    >"${LOGS}/pip.txt" 2>&1; then
    note "pip install -r requirements.txt 成功（镜像 ${PIP_INDEX}）"
  else
    VENV_MODE="copy"
    note "pip 不通（尾部原始输出见下），回退 D2b：从只读挂载复制宿主 venv 的 site-packages + 生成 uvicorn 控制台脚本"
    tail -5 "${LOGS}/pip.txt" | sed 's/^/    /'
  fi
fi

if [[ "${VENV_MODE}" == "copy" ]]; then
  # 宿主 venv 已由只读挂载挂在 /repo/server/.venv（同一 Python 3.11 小版本），直接复制其 site-packages；
  # 真机上这一步由 pip 完成，容器里是等价物。uvicorn 控制台脚本按 pip 的生成形态手写。
  dsh 'mkdir -p /opt/carbonboo/server/.venv/lib/python3.11/site-packages
cp -a /repo/server/.venv/lib/python3.11/site-packages/. /opt/carbonboo/server/.venv/lib/python3.11/site-packages/' \
    >"${LOGS}/pkgs_copy.txt" 2>&1
  dsh 'cat > /opt/carbonboo/server/.venv/bin/uvicorn <<"EOF"
#!/opt/carbonboo/server/.venv/bin/python3
# -*- coding: utf-8 -*-
import re
import sys
from uvicorn.main import main
if __name__ == "__main__":
    sys.argv[0] = re.sub(r"(-script\.pyw|\.exe)?$", "", sys.argv[0])
    sys.exit(main())
EOF
chmod +x /opt/carbonboo/server/.venv/bin/uvicorn' >"${LOGS}/console_script.txt" 2>&1
fi

# 单元以 User=carbonboo 运行 ⇒ /opt/carbonboo 整棵必须对该用户可读可执行（真机属主也是 carbonboo）；
# 不做这一步，systemd 会以 203/EXEC「Failed to execute …: Permission denied」反复重启（本轮已实测踩到）
dsh 'chown -R carbonboo:carbonboo /opt/carbonboo && chmod 755 /opt/carbonboo /opt/carbonboo/server' \
  >"${LOGS}/chown.txt" 2>&1

if dsh 'test -x /opt/carbonboo/server/.venv/bin/uvicorn && test -x /opt/carbonboo/server/.venv/bin/python && echo ok' \
  | grep -q ok; then
  echo_pass "2.4 .venv 就绪（uvicorn 控制台脚本 + python 均在单元写死的路径上；依赖来源=${VENV_MODE}）"
else
  echo_fail "2.4 .venv 未能就绪（来源=${VENV_MODE}）"
fi
if [[ "$(dsh 'stat -c "%U:%G" /opt/carbonboo/server/.venv/bin/uvicorn' 2>/dev/null | tr -d '\r')" == "carbonboo:carbonboo" ]]; then
  echo_pass "2.4b /opt/carbonboo 属主 = carbonboo:carbonboo（单元降权后仍可 exec）"
else
  echo_fail "2.4b 属主不是 carbonboo:carbonboo（$(dsh 'stat -c "%U:%G" /opt/carbonboo/server/.venv/bin/uvicorn' 2>/dev/null | tr -d '\r')）"
fi
UV_VER="$(dsh '/opt/carbonboo/server/.venv/bin/python -c "import uvicorn,fastapi,sqlalchemy,pymysql,jinja2,jose,passlib;print(uvicorn.__version__+\" \"+fastapi.__version__)"' 2>&1 | tail -1 | tr -d '\r')"
if [[ "${UV_VER}" =~ ^[0-9]+\.[0-9]+([.0-9]+)?\ [0-9]+\.[0-9]+([.0-9]+)?$ ]]; then
  echo_pass "2.5 依赖可导入（uvicorn/fastapi=${UV_VER}）"
else
  echo_fail "2.5 依赖导入失败：$(printf '%s' "${UV_VER}" | head -c 160)"
fi

# D3：派生 .env（只换 MYSQL_DB，指向任务库；密钥原样、不打印）
dsh 'sed -e "s|^MYSQL_DB=.*|MYSQL_DB='"${SD_DB}"'|" /repo/server/.env > /opt/carbonboo/server/.env && chmod 600 /opt/carbonboo/server/.env && chown carbonboo:carbonboo /opt/carbonboo/server/.env' \
  >"${LOGS}/env_derive.txt" 2>&1
note "D3 /opt/carbonboo/server/.env 派生：$(dsh 'grep -c . /opt/carbonboo/server/.env' | tr -d '\r') 行，MYSQL_DB=$(dsh 'grep "^MYSQL_DB=" /opt/carbonboo/server/.env' | tr -d '\r' | cut -d= -f2)"

# 任务库（宿主侧建，容器通过 --network host 的 127.0.0.1:13307 访问）
mysql_admin -e "DROP DATABASE IF EXISTS \`${SD_DB}\`; CREATE DATABASE \`${SD_DB}\` DEFAULT CHARACTER SET utf8mb4;" \
  >"${LOGS}/db_create.txt" 2>&1 || fatal "建任务库 ${SD_DB} 失败"
DB_CREATED=1
sed -e 's/`carbonboo`/`'"${SD_DB}"'`/g' -e "s/^USE carbonboo;/USE \`${SD_DB}\`;/" "${SERVER}/sql/schema.sql" \
  >"${WORK}/schema.sql"
sed -e "s/^USE carbonboo;/USE \`${SD_DB}\`;/" "${SERVER}/sql/seed.sql" >"${WORK}/seed.sql"
mysql_admin "${SD_DB}" <"${WORK}/schema.sql" >"${LOGS}/db_schema.txt" 2>&1 || fatal "导入 schema.sql 失败"
mysql_admin "${SD_DB}" <"${WORK}/seed.sql" >"${LOGS}/db_seed.txt" 2>&1 || fatal "导入 seed.sql 失败"
TBL_CNT="$(mysql_admin -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${SD_DB}';" 2>/dev/null | tr -d '[:space:]')"
[[ "${TBL_CNT}" == "21" ]] && echo_pass "2.6 任务库 ${SD_DB} 就绪（21 张表，不碰生产库 carbonboo）" \
  || echo_fail "2.6 任务库表数 = ${TBL_CNT}（期望 21）"

# ================================================== 3. 装单元（逐字节，仓库原文） ===
say "3. 单元文件装进容器 /etc/systemd/system/（仓库原件，逐字节比对）"
dsh 'install -m 644 /repo/systemd/carbonboo-server.service /repo/systemd/carbonboo-purge.service /repo/systemd/carbonboo-purge.timer /etc/systemd/system/' \
  >"${LOGS}/install_units.txt" 2>&1
SAME=1
for f in carbonboo-server.service carbonboo-purge.service carbonboo-purge.timer; do
  repo_sha="$(sha256sum "${UNITS}/${f}" | cut -d' ' -f1)"
  ctr_sha="$(dsh "sha256sum /etc/systemd/system/${f}" 2>/dev/null | cut -d' ' -f1 | tr -d '\r')"
  note "    ${f} repo=${repo_sha:0:16}… 容器=${ctr_sha:0:16}…"
  [[ "${repo_sha}" == "${ctr_sha}" && -n "${ctr_sha}" ]] || SAME=0
done
[[ "${SAME}" == "1" ]] && echo_pass "3.1 三个单元装进容器后与仓库文件 sha256 逐字节一致（未改一个字）" \
  || echo_fail "3.1 容器内单元与仓库文件 sha256 不一致"

RC_DR="$(dsh 'systemctl daemon-reload; echo RC=$?' 2>&1 | tr -d '\r' | grep -o 'RC=[0-9]*' | cut -d= -f2)"
[[ "${RC_DR}" == "0" ]] && echo_pass "3.2 systemctl daemon-reload 成功（rc=${RC_DR}）" \
  || echo_fail "3.2 daemon-reload rc=${RC_DR}"

dsh_log unit_cat 'for u in carbonboo-server carbonboo-purge; do systemctl cat $u | sed -n "1,40p"; echo "-----"; done'

# ============================================================ 4. 真启动 server ===
say "4. systemctl start carbonboo-server → status / journalctl / 真实探活"
RC_START="$(dsh 'systemctl start carbonboo-server 2>&1; echo RC=$?' | tr -d '\r' | grep -o 'RC=[0-9]*' | cut -d= -f2)"
[[ "${RC_START}" == "0" ]] && echo_pass "4.1 systemctl start carbonboo-server 返回 0" \
  || echo_fail "4.1 systemctl start carbonboo-server 返回 ${RC_START}"

ACTIVE=""
for _ in $(seq 1 30); do
  ACTIVE="$(dsh 'systemctl is-active carbonboo-server' 2>&1 | tr -d '\r')"
  MAINPID_NOW="$(dsh 'systemctl show carbonboo-server -p MainPID --value' 2>&1 | tr -d '\r')"
  if [[ "${ACTIVE}" == "active" && "${MAINPID_NOW}" =~ ^[1-9][0-9]*$ ]]; then break; fi
  sleep 2
done
dsh_log sd_status 'systemctl status carbonboo-server --no-pager -l'
cat "${LOGS}/sd_status.txt" | sed 's/^/    /'
[[ "${ACTIVE}" == "active" ]] && echo_pass "4.2 systemctl is-active carbonboo-server = active（单元真的拉起并常驻）" \
  || echo_fail "4.2 systemctl is-active carbonboo-server = ${ACTIVE}"
# 反假绿：只看 is-active 会被 Restart=always 的「activating (auto-restart)」骗过去（本轮实测踩到 203/EXEC 循环），
# 因此再钉住「有真实主进程 PID」且「重启计数不增长」。
NRESTARTS="$(dsh 'systemctl show carbonboo-server -p NRestarts --value' 2>/dev/null | tr -d '\r')"
if [[ "${MAINPID_NOW}" =~ ^[1-9][0-9]*$ ]] && [[ "${NRESTARTS:-9}" =~ ^[0-9]+$ ]] && (( NRESTARTS <= 1 )); then
  echo_pass "4.2b 主进程真实存在且未反复重启（MainPID=${MAINPID_NOW} NRestarts=${NRESTARTS}）"
else
  echo_fail "4.2b 主进程不健康（MainPID=${MAINPID_NOW:-?} NRestarts=${NRESTARTS:-?}）"
fi

dsh_log sd_journal 'journalctl -u carbonboo-server --no-pager -n 40'
say "4b. journalctl -u carbonboo-server（尾部）"
tail -14 "${LOGS}/sd_journal.txt" | sed 's/^/    /'

# 真实探活：单元把 uvicorn 绑在 127.0.0.1:8000。**探针必须在容器内做**——Docker Desktop 的
# `--network host` 落在 docker-desktop VM 的网络命名空间里，宿主 WSL 的 127.0.0.1 看不到容器内的
# 127.0.0.1（宿主侧实测 curl → 000 / connection refused，见下面的 NOTE）。容器内 127.0.0.1:8000
# 与真机「同机 nginx → 127.0.0.1:8000」是同一个语义。
HEALTH=""
for _ in $(seq 1 30); do
  HEALTH="$(dsh 'python3 - <<"PY"
import json, urllib.request
try:
    r = urllib.request.urlopen("http://127.0.0.1:8000/api/v1/health", timeout=5)
    print(r.status, r.read().decode()[:160])
except Exception as exc:
    print("ERR", exc)
PY' 2>&1 | tr -d '\r' | tail -1)"
  [[ "${HEALTH}" == 200* ]] && break
  sleep 2
done
printf '%s' "${HEALTH}" >"${LOGS}/health_by_unit.txt"
HOST_PROBE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:${APP_PORT}/api/v1/health 2>&1 | tail -1)"
note "D5 宿主侧 curl 127.0.0.1:${APP_PORT} → ${HOST_PROBE}（Docker Desktop 的 --network host 在 docker-desktop VM 的 netns 里，宿主看不到；探活改在容器内做）"
if [[ "${HEALTH}" == 200* && "${HEALTH}" == *'"ok":true'* ]]; then
  echo_pass "4.3 单元拉起的 uvicorn 真答业务：容器内 GET http://127.0.0.1:${APP_PORT}/api/v1/health → ${HEALTH:0:110}"
else
  echo_fail "4.3 单元拉起的服务未答 200（容器内探针：${HEALTH:0:140}）"
fi
ADMIN_MOUNT="$(dsh 'python3 - <<"PY"
import urllib.request
try:
    r = urllib.request.urlopen("http://127.0.0.1:8000/admin/login", timeout=5)
    print(r.status, len(r.read()))
except Exception as exc:
    print("ERR", exc)
PY' 2>&1 | tr -d '\r' | tail -1)"
if [[ "${ADMIN_MOUNT}" == 200* ]]; then
  echo_pass "4.4 /admin 随服务一起被拉起：容器内 GET /admin/login → ${ADMIN_MOUNT:0:60}"
else
  echo_fail "4.4 /admin 未挂载（容器内 GET /admin/login → ${ADMIN_MOUNT:0:120}）"
fi

dsh_log sd_show 'systemctl show carbonboo-server -p User -p Group -p Restart -p RestartUSec -p MainPID -p ProtectionMode -p ProtectSystem -p ReadWritePaths -p NoNewPrivileges -p PrivateTmp'
say "4c. systemctl show（单元真实生效的加固/身份）"
cat "${LOGS}/sd_show.txt" | sed 's/^/    /'
grep -q '^User=carbonboo' "${LOGS}/sd_show.txt" && echo_pass "4.5 进程身份 User=carbonboo（单元里的降权真的生效）" \
  || echo_fail "4.5 systemctl show 未给出 User=carbonboo"
grep -q '^Restart=always' "${LOGS}/sd_show.txt" && echo_pass "4.6 Restart=always 生效（systemd 读到的重启策略）" \
  || echo_fail "4.6 systemctl show 未给出 Restart=always"

# ======================================================= 5. timer 真启动+真触发 ===
say "5. carbonboo-purge.timer：start → list-timers → 真触发一次 purge"
RC_T="$(dsh 'systemctl start carbonboo-purge.timer 2>&1; echo RC=$?' | tr -d '\r' | grep -o 'RC=[0-9]*' | cut -d= -f2)"
T_ACTIVE="$(dsh 'systemctl is-active carbonboo-purge.timer' 2>&1 | tr -d '\r')"
dsh_log sd_timers 'systemctl list-timers --all --no-pager'
say "5a. systemctl list-timers --all"
cat "${LOGS}/sd_timers.txt" | sed 's/^/    /'
[[ "${RC_T}" == "0" && "${T_ACTIVE}" == "active" ]] \
  && echo_pass "5.1 systemctl start carbonboo-purge.timer rc=0 且 is-active=active" \
  || echo_fail "5.1 timer 启动异常（rc=${RC_T} active=${T_ACTIVE}）"
grep -q 'carbonboo-purge.timer' "${LOGS}/sd_timers.txt" \
  && echo_pass "5.2 timer 被 list-timers 列出（下一触发时刻见上表：OnCalendar=*-*-* 04:23:00）" \
  || echo_fail "5.2 list-timers 里没有 carbonboo-purge.timer"

# D4：容器内临时副本（OnCalendar 每分钟 + 去掉 600s 随机延迟），只为真触发一次；仓库文件与其安装副本都不动
dsh 'sed -e "s|^OnCalendar=.*|OnCalendar=*:*:00|" -e "s|^RandomizedDelaySec=.*|RandomizedDelaySec=0s|" \
  /etc/systemd/system/carbonboo-purge.timer > /etc/systemd/system/carbonboo-purge-e2e.timer
systemctl daemon-reload
systemctl start carbonboo-purge-e2e.timer' >"${LOGS}/timer_e2e.txt" 2>&1
note "D4 容器内临时副本 /etc/systemd/system/carbonboo-purge-e2e.timer：$(dsh 'grep -E "^(OnCalendar|RandomizedDelaySec|Persistent|Unit)=" /etc/systemd/system/carbonboo-purge-e2e.timer' | tr -d '\r' | tr '\n' ' ')"
dsh_log sd_timers_e2e 'systemctl list-timers --all --no-pager'
grep -E 'carbonboo-purge-e2e.timer' "${LOGS}/sd_timers_e2e.txt" | sed 's/^/    /' || true
dsh 'sha256sum /etc/systemd/system/carbonboo-purge.timer' >"${LOGS}/timer_orig_sha.txt" 2>&1
PURGE_RAN=0
for _ in $(seq 1 60); do
  if dsh 'journalctl -u carbonboo-purge --no-pager' 2>/dev/null | grep -q 'purge_expired_accounts'; then
    PURGE_RAN=1
    break
  fi
  sleep 2
done
dsh_log sd_purge_journal 'journalctl -u carbonboo-purge --no-pager -n 40'
say "5b. journalctl -u carbonboo-purge（真触发一次 purge 的原始输出）"
tail -12 "${LOGS}/sd_purge_journal.txt" | sed 's/^/    /'
[[ "${PURGE_RAN}" == "1" ]] \
  && echo_pass "5.3 timer 真触发了一次 carbonboo-purge.service（journal 里有 purge_expired_accounts 输出）" \
  || echo_fail "5.3 120s 内未等到 purge 被触发（journal 无输出）"
if grep -q '物理清除' "${LOGS}/sd_purge_journal.txt"; then
  echo_pass "5.4 purge 运维入口真跑通（$(grep -m1 '物理清除' "${LOGS}/sd_purge_journal.txt" | sed 's/^ *//' | head -c 90)）"
else
  echo_fail "5.4 purge 未打印运维入口输出"
fi
dsh_log sd_purge_show 'systemctl show carbonboo-purge.service -p Result -p ExecMainStatus -p ExecMainStartTimestamp -p User -p Type'
if grep -q '^Result=success' "${LOGS}/sd_purge_show.txt" && grep -q '^ExecMainStatus=0' "${LOGS}/sd_purge_show.txt" \
  && grep -qE '^ExecMainStartTimestamp=[^=]' "${LOGS}/sd_purge_show.txt"; then
  echo_pass "5.5 carbonboo-purge.service 真的被触发过且成功（$(grep -E '^ExecMainStartTimestamp=' "${LOGS}/sd_purge_show.txt" | head -c 60) Result=success ExecMainStatus=0）"
else
  echo_fail "5.5 purge 未真正运行过或结果非 success/0：$(tr '\n' ' ' <"${LOGS}/sd_purge_show.txt" | head -c 160)"
fi
if dsh 'test "$(sha256sum /etc/systemd/system/carbonboo-purge.timer | cut -d" " -f1)" = "$(sha256sum /repo/systemd/carbonboo-purge.timer | cut -d" " -f1)" && echo ok' | grep -q ok; then
  echo_pass "5.6 容器内 carbonboo-purge.timer 副本与仓库文件仍逐字节一致（改的只是 e2e 临时副本）"
else
  echo_fail "5.6 容器内 timer 副本被改动（不该发生）"
fi

# ================================================================== 6. 结论 ====
say "6. 收尾（停止单元、删容器与任务库）"
sd_cleanup
CONTAINER_STARTED=0
DB_CREATED=0

printf '\n──── systemd 真启动汇总 ────\n'
printf 'PASS=%d FAIL=%d\n' "${PASS}" "${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  printf '失败项：%s\n' "${FAILED_NAMES[*]}"
  printf 'RESULT: FAIL\n'
  exit 1
fi
printf 'RESULT: PASS\n'
exit 0
