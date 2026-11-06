#!/usr/bin/env bash
# ============================================================================
# CarbonBoo · 容器版 MySQL 定时备份（server/deploy/docker/backup.sh）
#
#   bash deploy/docker/backup.sh [保留天数，默认 14]
#
# 职责：对 compose 里的 mysql 容器做 mysqldump（--single-transaction，不锁表），
#       按 carbonboo-YYYYmmdd-HHmm.sql.gz 落盘，并清理过期备份。
#       systemd 变体用 deploy/backup-mysql.sh；容器版没有宿主 mysql 客户端，故走 docker exec。
#
#   cron 示例（每天 03:20）：
#     20 3 * * * root /opt/carbonboo/server/deploy/docker/backup.sh 14 >> /var/log/carbonboo-backup.log 2>&1
# ============================================================================
set -euo pipefail

CONTAINER="${CB_MYSQL_CONTAINER:-carbonboo-mysql}"
BACKUP_DIR="${CB_BACKUP_DIR:-/opt/carbonboo/backups}"
KEEP_DAYS="${1:-14}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "STOP: 找不到 ${ENV_FILE}" >&2
  exit 2
fi

# 只取需要的键，不 source（避免执行任意 shell）
env_value() {
  local key="$1"
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "${ENV_FILE}" | tail -n1 | sed 's/[[:space:]]*$//'
}

DB_NAME="$(env_value MYSQL_DB)"; DB_NAME="${DB_NAME:-carbonboo}"
ROOT_PW="$(env_value MYSQL_ROOT_PASSWORD)"
if [[ -z "${ROOT_PW}" ]]; then
  echo "STOP: .env 里没有 MYSQL_ROOT_PASSWORD" >&2
  exit 2
fi

mkdir -p "${BACKUP_DIR}"
STAMP="$(date +%Y%m%d-%H%M)"
TARGET="${BACKUP_DIR}/carbonboo-${STAMP}.sql.gz"
TMP="${TARGET}.part"

# 口令经容器内的环境变量传给 mysqldump，不出现在宿主机进程列表与 shell 历史里
docker exec -e MYSQL_PWD="${ROOT_PW}" "${CONTAINER}" \
  mysqldump --single-transaction --quick --skip-lock-tables \
  -uroot "${DB_NAME}" | gzip -9 > "${TMP}"

if [[ ! -s "${TMP}" ]]; then
  echo "STOP: 备份为空，放弃落盘（保留 ${TMP} 供排查）" >&2
  exit 1
fi
mv "${TMP}" "${TARGET}"

# gzip 完整性自检
gzip -t "${TARGET}"

echo "[$(date '+%F %T')] 备份完成：${TARGET}（$(du -h "${TARGET}" | cut -f1)）"

# 清理过期备份
find "${BACKUP_DIR}" -maxdepth 1 -name 'carbonboo-*.sql.gz' -mtime "+${KEEP_DAYS}" -print -delete \
  | sed 's/^/  清理过期：/'

echo "[$(date '+%F %T')] 现有备份 $(find "${BACKUP_DIR}" -maxdepth 1 -name 'carbonboo-*.sql.gz' | wc -l) 份（保留 ${KEEP_DAYS} 天）"
