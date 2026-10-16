#!/usr/bin/env bash
# ============================================================================
# CarbonBoo · MySQL 定时全库备份（server/deploy/backup-mysql.sh）
#
#   bash deploy/backup-mysql.sh [保留天数，默认 14]
#
# 口径（AGENTS §7.2）：部署脚本含 `mysqldump` 定时备份；备份文件权限 600，只落本机磁盘。
# cron 建议：17 3 * * *  cd /opt/carbonboo/server && bash deploy/backup-mysql.sh >> /var/log/carbonboo-backup.log 2>&1
# ============================================================================
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SERVER_DIR}/.env"
KEEP_DAYS="${1:-14}"
BACKUP_DIR="${CARBONBOO_BACKUP_DIR:-/var/backups/carbonboo}"

env_value() {
  local key="$1" default="${2:-}"
  if [[ -f "${ENV_FILE}" ]]; then
    local line
    line="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 || true)"
    if [[ -n "${line}" ]]; then
      printf '%s' "${line#*=}" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
      return
    fi
  fi
  printf '%s' "${default}"
}

MYSQL_HOST="$(env_value MYSQL_HOST 127.0.0.1)"
MYSQL_PORT="$(env_value MYSQL_PORT 3306)"
MYSQL_DB="$(env_value MYSQL_DB carbonboo)"
MYSQL_USER="$(env_value MYSQL_ADMIN_USER "$(env_value MYSQL_USER carbonboo)")"
MYSQL_PASSWORD="$(env_value MYSQL_ADMIN_PASSWORD "$(env_value MYSQL_PASSWORD)")"

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

STAMP="$(date +%Y%m%d-%H%M)"
TARGET="${BACKUP_DIR}/carbonboo-${STAMP}.sql.gz"

echo "[$(date -Is)] 备份 ${MYSQL_DB} → ${TARGET}"
MYSQL_PWD="${MYSQL_PASSWORD}" mysqldump \
  --host="${MYSQL_HOST}" --port="${MYSQL_PORT}" --user="${MYSQL_USER}" --protocol=TCP \
  --single-transaction --routines --triggers --default-character-set=utf8mb4 \
  "${MYSQL_DB}" | gzip > "${TARGET}"

chmod 600 "${TARGET}"
echo "[$(date -Is)] 完成：$(du -h "${TARGET}" | cut -f1)"

# 清理旧备份（默认保留 14 天）
find "${BACKUP_DIR}" -name 'carbonboo-*.sql.gz' -type f -mtime "+${KEEP_DAYS}" -print -delete
echo "[$(date -Is)] 已清理超过 ${KEEP_DAYS} 天的备份"
