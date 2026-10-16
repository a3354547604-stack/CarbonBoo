#!/usr/bin/env bash
# ============================================================================
# CarbonBoo · 增量迁移执行器（server/deploy/migrate.sh）
#
#   bash deploy/migrate.sh <库名> [--dry-run]
#
# 职责：把 server/sql/migrations/*.sql 按序号顺序执行一遍。
#   * 脚本自身要求**幂等**（见 sql/migrations/README.md），因此重复执行安全；
#   * 安全阀：库名含 test 时拒绝执行（与 tests/conftest.py 的护栏一致），
#     避免误把 L3 测试库当成正式库折腾；
#   * 凭据只从 server/.env（600）或环境变量读，**不接受命令行口令**（会进 shell 历史）；
#   * --dry-run 只列出将执行的语句数，不连库（本地无 mysql 客户端时也能自检）。
#
# 说明：正式环境用系统 mysql 客户端；本机（WSL）没有 mysql 客户端时，请改用
#   tests/conftest.py 里同一套执行器（.venv/bin/python -m pytest tests/test_sync.py -k migration）。
# ============================================================================
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="${SERVER_DIR}/sql/migrations"
ENV_FILE="${SERVER_DIR}/.env"

DB_NAME="${1:-}"
DRY_RUN="false"
[[ "${2:-}" == "--dry-run" || "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

if [[ -z "${DB_NAME}" || "${DB_NAME}" == "--dry-run" ]]; then
  DB_NAME="${MYSQL_DB:-carbonboo}"
  echo "未指定库名，使用默认：${DB_NAME}"
fi

if [[ "${DB_NAME}" == *test* ]]; then
  echo "STOP: 库名 '${DB_NAME}' 含 test，拒绝执行迁移（测试库由 tests/conftest.py 自己管）。" >&2
  exit 2
fi

if [[ ! -d "${MIGRATIONS_DIR}" ]]; then
  echo "没有 ${MIGRATIONS_DIR}，无需迁移。"
  exit 0
fi

# .env（600）里只取需要的键；不 source（避免执行任意 shell）
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
MYSQL_USER="$(env_value MYSQL_USER carbonboo)"
MYSQL_PASSWORD="$(env_value MYSQL_PASSWORD)"
# 迁移要改结构，通常需要管理员账号（应用账号一般只有单库 DML 权限）
MYSQL_ADMIN_USER="$(env_value MYSQL_ADMIN_USER "${MYSQL_USER}")"
MYSQL_ADMIN_PASSWORD="$(env_value MYSQL_ADMIN_PASSWORD "${MYSQL_PASSWORD}")"

shopt -s nullglob
FILES=("${MIGRATIONS_DIR}"/*.sql)
shopt -u nullglob

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "没有迁移脚本（${MIGRATIONS_DIR}/*.sql）。"
  exit 0
fi

IFS=$'\n' FILES=($(printf '%s\n' "${FILES[@]}" | sort))
echo "目标库：${DB_NAME}@${MYSQL_HOST}:${MYSQL_PORT}（迁移脚本 ${#FILES[@]} 个）"

if [[ "${DRY_RUN}" == "true" ]]; then
  for f in "${FILES[@]}"; do
    echo "[dry-run] $(basename "${f}")：$(grep -c ';' "${f}") 条语句待执行"
  done
  echo "[dry-run] 未连接数据库。"
  exit 0
fi

if ! command -v mysql >/dev/null 2>&1; then
  echo "STOP: 本机没有 mysql 客户端，无法执行迁移。" >&2
  echo "建议: 在目标机安装 mysql-client；或改用 .venv/bin/python 走 tests/conftest.py 的同一套执行器。" >&2
  exit 3
fi

for f in "${FILES[@]}"; do
  echo "→ 执行 $(basename "${f}")"
  MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" mysql \
    --host="${MYSQL_HOST}" --port="${MYSQL_PORT}" --user="${MYSQL_ADMIN_USER}" \
    --protocol=TCP "${DB_NAME}" < "${f}"
done

echo "迁移完成。校验（应为 user_id,source_type,source_id,flow_kind）："
MYSQL_PWD="${MYSQL_ADMIN_PASSWORD}" mysql --host="${MYSQL_HOST}" --port="${MYSQL_PORT}" \
  --user="${MYSQL_ADMIN_USER}" --protocol=TCP --batch --skip-column-names -e "
    SELECT GROUP_CONCAT(column_name ORDER BY seq_in_index)
      FROM information_schema.statistics
     WHERE table_schema = '${DB_NAME}' AND table_name = 'point_record' AND index_name = 'uq_pr_source';"
