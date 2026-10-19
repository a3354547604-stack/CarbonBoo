#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tests/tools/l2_sync/run.sh —— 「L2 双设备协同」的**协议级**端到端验证（本机真跑）
#
# 职责：把 docs/VERIFICATION.md 里长期未运行的「L2 双设备协同」中**可本机复现的那一半**跑成证据：
#       两个独立客户端库（node:sqlite 真 SQLite 引擎）+ 真实 FastAPI 服务端 + 真实 HTTP，
#       逐条证明：① 基线往返 ② LWW 收敛 ③ 平局按 deviceId ④ 时钟偏移取反 ⑤ 幂等
#                 ⑥ 软删除传播 ⑦ ignored 不计入 conflicts ⑧ 反证不是假绿
#
# 边界（重要）：这里验的是**协议级两端收敛**，**不能替代真机 L2**。
#       不覆盖：UI、Ability 生命周期、端侧权限、鸿蒙近场/分布式通路、真机进程被杀/后台恢复。
#
# 退出码：0 = 八项全过 + 两条反证成立
#         1 = 有断言失败（含变异自证未变红、还原后未变绿）
#         2 = 环境不可达（缺 node:sqlite / esbuild / 容器 / venv / 服务端起不来）
#
# 硬边界：一行 app/** 生产代码都不改（变异只改**构建目录里的副本**，且用 git show 还原）；
#         垫片只读 tests/tools/l1_offline/platform/；服务端缺陷只报告不改（inScope 不含 server/）。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$HERE/lib"

DB_NAME="${L2_DB:-carbonboo_l2_e2e}"
CONTAINER="${L2_MYSQL_CONTAINER:-carbonboo-mysql}"
USERNAME="${L2_USERNAME:-l2dev_$(date +%s)}"
PASSWORD="${L2_PASSWORD:-l2-pass-123}"
# 行时间戳取"未来 7 天"基准：保证恒 > lastSyncAt 锚点，push 的 `updated_at > since` 与 pull 的 `raw > since` 都覆盖到
TIME_BASE=$(( ($(date +%s) + 604800) * 1000 ))

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cbl2-XXXXXX")"
UVICORN_PID=""
PORT=""

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
fail_env() { printf '\n环境不可达：%s\n' "$*" >&2; exit 2; }

cleanup() {
  local code=$?
  printf '\n== 收工清理 ==\n'
  if [ -n "$UVICORN_PID" ] && kill -0 "$UVICORN_PID" 2>/dev/null; then
    kill "$UVICORN_PID" 2>/dev/null
    for _ in $(seq 1 20); do
      kill -0 "$UVICORN_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -0 "$UVICORN_PID" 2>/dev/null && kill -9 "$UVICORN_PID" 2>/dev/null
    info "已停 uvicorn（pid=$UVICORN_PID）"
  fi
  # 兜底：按命令行特征再扫一遍，避免有残留把端口占死
  if [ -n "$PORT" ]; then
    pkill -f "uvicorn app.main:app --host 127.0.0.1 --port $PORT" 2>/dev/null && info "已清理残留 uvicorn 进程"
  fi
  if [ -n "${ADMIN_USER:-}" ] && [ -n "${ADMIN_PW:-}" ]; then
    docker exec "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PW" \
      -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" >/dev/null 2>&1 && info "已删除任务专用库 $DB_NAME"
  fi
  if [ -n "${L2_KEEP_OUT:-}" ]; then
    mkdir -p "$L2_KEEP_OUT"
    cp -a "$TMP"/out-*.txt "$TMP"/wire-*.log "$TMP"/uvicorn.log "$L2_KEEP_OUT"/ 2>/dev/null
    info "原始输出已留档到 $L2_KEEP_OUT（排障/写报告用；默认不留）"
  fi
  rm -rf "$TMP"
  info "已删除临时目录 $TMP"
  info "退出码=$code"
}
trap cleanup EXIT

# ── 1. 环境检查（任一缺失 ⇒ 退出码 2） ───────────────────────────────────────
say "1. 环境检查"
NODE_BIN=""
for cand in "$(command -v node || true)" /usr/bin/node /usr/local/bin/node \
            "$HOME/harmony-toolchain/clt/command-line-tools/tool/node/bin/node"; do
  if [ -n "$cand" ] && [ -x "$cand" ] && "$cand" -e "require('node:sqlite')" >/dev/null 2>&1; then
    NODE_BIN="$cand"; break
  fi
done
[ -n "$NODE_BIN" ] || fail_env "找不到带 node:sqlite 的 Node（需 ≥ 22.5；本机 /usr/bin/node 是 22.22.1）"
info "Node: $NODE_BIN（$("$NODE_BIN" -v)）"

ESBUILD="${ESBUILD:-$HOME/harmony-toolchain/esbuild/bin/esbuild}"
[ -x "$ESBUILD" ] || ESBUILD="$(command -v esbuild || true)"
[ -n "$ESBUILD" ] && [ -x "$ESBUILD" ] || fail_env "找不到 esbuild（本机在 ~/harmony-toolchain/esbuild/bin/esbuild；禁止 npm install）"
info "esbuild: $ESBUILD（$("$ESBUILD" --version)）"

command -v docker >/dev/null 2>&1 || fail_env "找不到 docker（需要它连接项目 MySQL 容器 $CONTAINER）"
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || fail_env "容器 $CONTAINER 不在运行（项目 MySQL：127.0.0.1:13307）"
info "容器: $CONTAINER 在线"

UVICORN="$REPO_ROOT/server/.venv/bin/uvicorn"
[ -x "$UVICORN" ] || fail_env "找不到 $UVICORN"
info "uvicorn: $UVICORN"

[ -f "$REPO_ROOT/server/.env" ] || fail_env "缺少 server/.env（JWT 密钥/MySQL 口令都从它来）"
ADMIN_USER="$(grep -E '^MYSQL_ADMIN_USER=' "$REPO_ROOT/server/.env" | cut -d= -f2- | tr -d '\r')"
ADMIN_PW="$(grep -E '^MYSQL_ADMIN_PASSWORD=' "$REPO_ROOT/server/.env" | cut -d= -f2- | tr -d '\r')"
[ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PW" ] || fail_env "server/.env 里没有 MYSQL_ADMIN_USER / MYSQL_ADMIN_PASSWORD"

if [ -z "${L2_PORT:-}" ]; then
  PORT="$("$NODE_BIN" -e 'const n=require("node:net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{process.stdout.write(String(s.address().port));s.close();});')"
else
  PORT="$L2_PORT"
fi
info "任务专用库: $DB_NAME（不动共享库 carbonboo/$CONTAINER）"
info "服务端端口: 127.0.0.1:$PORT"

export L2_REPO="$REPO_ROOT"
export L2_ROOTS="$TMP/roots"
export L2_BASE_URL="http://127.0.0.1:$PORT"
export L2_USERNAME="$USERNAME" L2_PASSWORD="$PASSWORD" L2_TIME_BASE="$TIME_BASE"
export L2_MYSQL_DB="$DB_NAME" L2_MYSQL_CONTAINER="$CONTAINER"
export L2_MYSQL_USER="$ADMIN_USER" L2_MYSQL_PASSWORD="$ADMIN_PW"

# ── 2. 任务专用库：建库 + 灌 schema/seed ─────────────────────────────────────
# 注意：仓库的 schema.sql/seed.sql 里写死了 `carbonboo`，必须**按名字替换**成任务专属库，
# 否则会打到共享库上（同机的其它 agent 正在用）。--database= 挡不住文件自带的 USE。
reset_db() {
  sed -E 's/(CREATE DATABASE IF NOT EXISTS )`carbonboo`/\1`'"$DB_NAME"'`/; s/^USE `carbonboo`;/USE `'"$DB_NAME"'`;/' \
    "$REPO_ROOT/server/sql/schema.sql" > "$TMP/schema.sql"
  sed -E 's/^USE carbonboo;/USE '"$DB_NAME"';/' "$REPO_ROOT/server/sql/seed.sql" > "$TMP/seed.sql"
  docker exec "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PW" -e \
    "DROP DATABASE IF EXISTS \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci; GRANT ALL ON \`$DB_NAME\`.* TO 'carbonboo'@'%'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
    || fail_env "建库失败（检查容器 $CONTAINER 与 server/.env 的管理员口令）"
  docker exec -i "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PW" --default-character-set=utf8mb4 "$DB_NAME" < "$TMP/schema.sql" >/dev/null 2>&1 \
    || fail_env "灌 server/sql/schema.sql 失败"
  docker exec -i "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PW" --default-character-set=utf8mb4 "$DB_NAME" < "$TMP/seed.sql" >/dev/null 2>&1 \
    || fail_env "灌 server/sql/seed.sql 失败"
  local tables
  tables="$(docker exec "$CONTAINER" mysql -u"$ADMIN_USER" -p"$ADMIN_PW" -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null)"
  info "库 $DB_NAME 就绪：$tables 张表"
}

say "2. 建任务专用库并灌 schema/seed"
reset_db

# ── 3. 起真服务端（真 FastAPI + 真 MySQL） ───────────────────────────────────
start_server() {
  ( cd "$REPO_ROOT/server" && MYSQL_DB="$DB_NAME" LOGIN_RATE_LIMIT_PER_MINUTE=0 \
      exec "$UVICORN" app.main:app --host 127.0.0.1 --port "$PORT" ) >"$TMP/uvicorn.log" 2>&1 &
  UVICORN_PID=$!
  local i
  for i in $(seq 1 60); do
    if "$NODE_BIN" -e 'fetch(`http://127.0.0.1:${process.argv[1]}/api/v1/config`).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' "$PORT" >/dev/null 2>&1; then
      info "服务端就绪：GET /api/v1/config → 200（pid=$UVICORN_PID，日志 $TMP/uvicorn.log）"
      return 0
    fi
    kill -0 "$UVICORN_PID" 2>/dev/null || break
    sleep 0.5
  done
  printf '\n--- uvicorn 日志（末 30 行）---\n' >&2
  tail -30 "$TMP/uvicorn.log" >&2
  fail_env "uvicorn 起不来或健康检查不通过（见上面日志）"
}
say "3. 启动真服务端"
start_server

# ── 4. 构建：把真实 .ets 原样复制到构建目录再转译（绝不重写实现） ──────────────
build() { # $1 = 目标目录，$2.. = 额外参数
  local dir="$1"; shift
  say "4. 构建（复制真实源文件 → esbuild 转译）$dir $*"
  "$NODE_BIN" "$LIB/build.mjs" "$REPO_ROOT" "$dir" "$@" | tee "$TMP/build-$(basename "$dir").log" \
    || fail_env "构建失败（见上面的构建日志）"
}
CODE_SUM_BEFORE="$(find "$REPO_ROOT/app/entry/src/main/ets" -name '*.ets' -exec sha256sum {} \; | sort | sha256sum | cut -d' ' -f1)"
info "构建前 app/**/*.ets 全量 sha256 指纹 = $CODE_SUM_BEFORE"

BUILD_MAIN="$TMP/build-main"
build "$BUILD_MAIN"

# ── 5. 主用例：八项全跑 ─────────────────────────────────────────────────────
run_suite() { # $1 = 构建目录，$2 = L2_ONLY，$3 = 输出前缀
  local build_dir="$1" only="$2" tag="$3"
  : > "$TMP/roots-$tag.flag"
  export L2_BUILD="$build_dir" L2_ONLY="$only" L2_WIRE_LOG="$TMP/wire-$tag.log"
  export L1_ALLOW_NETWORK=1
  rm -rf "$TMP/roots-$tag"; mkdir -p "$TMP/roots-$tag"
  export L2_ROOTS="$TMP/roots-$tag"
  "$NODE_BIN" "$LIB/l2_run.mjs" >"$TMP/out-$tag.txt" 2>&1
  echo $? > "$TMP/exit-$tag.txt"
  return 0
}
say "5. 主用例：八项断言（真 HTTP + 真服务端 + 两个独立客户端库）"
run_suite "$BUILD_MAIN" "all" "main"
MAIN_EXIT="$(cat "$TMP/exit-main.txt")"
grep -E '^\[(PASS|FAIL)\]|^RESULT|^失败项' "$TMP/out-main.txt" || true
info "主用例退出码 = $MAIN_EXIT（原始输出：$TMP 已随收工删除，完整逐条证据见 REPORT.md）"

# ── 6. 变异自证：改一处真实比较规则 ⇒ 必红；git show 还原 ⇒ 必绿 ─────────────
say "6. 反证不是假绿（8.2 变异自证：平局判据方向反转）"
SYNC_REL="app/entry/src/main/ets/viewmodel/net/SyncService.ets"
BUILD_MUT="$TMP/build-mut"
build "$BUILD_MUT" "--mutate=tie-flip"
MUT_SHA="$(sha256sum "$BUILD_MUT/src/main/ets/viewmodel/net/SyncService.ets" | cut -d' ' -f1)"
REPO_SHA="$(sha256sum "$REPO_ROOT/$SYNC_REL" | cut -d' ' -f1)"
info "变异副本 sha256 = $MUT_SHA"
info "仓库原件 sha256 = $REPO_SHA"

reset_db
run_suite "$BUILD_MUT" "tie" "mut"
MUT_EXIT="$(cat "$TMP/exit-mut.txt")"
grep -E '^\[(FAIL)\]|^RESULT|^失败项' "$TMP/out-mut.txt" || true
info "变异后退出码 = $MUT_EXIT（必须非 0）"

# 还原：**用 git show**（禁止 cp 备份还原 —— 历史备份会被 shell 重放污染）
git -C "$REPO_ROOT" show "HEAD:$SYNC_REL" > "$TMP/build-mut/src/main/ets/viewmodel/net/SyncService.ets"
if cmp -s "$REPO_ROOT/$SYNC_REL" "$TMP/build-mut/src/main/ets/viewmodel/net/SyncService.ets"; then
  info "git show 还原后与仓库原件逐字节一致（cmp 通过）"
  RESTORED_OK=1
else
  info "git show 还原后与仓库原件不一致 —— cmp 失败"
  RESTORED_OK=0
fi
RESTORED_SHA="$(sha256sum "$TMP/build-mut/src/main/ets/viewmodel/net/SyncService.ets" | cut -d' ' -f1)"
info "还原后 sha256 = $RESTORED_SHA"

# 关键：还原后**在同一个构建目录里原处重转译**（--skip-copy），这样第三趟跑的确实是"被 git show 还原过的那份源文件"，
# 而不是"另起一个干净目录重新复制一遍"——否则"还原 ⇒ 变绿"这条链条就不闭合。
build "$BUILD_MUT" "--skip-copy"
reset_db
run_suite "$BUILD_MUT" "tie" "restored"
RESTORED_EXIT="$(cat "$TMP/exit-restored.txt")"
grep -E '^\[(PASS|FAIL)\]|^RESULT' "$TMP/out-restored.txt" || true
info "还原后退出码 = $RESTORED_EXIT（必须 0）"

# ── 6b. 反证 C（t68）：给客户端**落库换算**注入 1000ms 偏差 ⇒ 严格基准断言必红；还原必绿 ────────
# 为什么单开一条腿：t68 把"两端 updated_at 逐字节相同"这类断言换成了严格基准等价式
#（`端上值 + offsetMs === 服务端值`）。3s 容差会把 1000ms 级的符号/倍率错误吃成绿，
# 所以必须证明这条严格断言对 1000ms 的偏差会立刻变红、并对还原后的实现变绿。
say "6b. 反证 C（t68 严格基准断言）：客户端落库换算多 1000ms ⇒ 必红；git show 还原 ⇒ 必绿"
STRICT_GROUPS="baseline,lww,delete,clock"
BUILD_MUT2="$TMP/build-mut2"
build "$BUILD_MUT2" "--mutate=offset-1000"
MUT2_SHA="$(sha256sum "$BUILD_MUT2/src/main/ets/viewmodel/net/SyncService.ets" | cut -d' ' -f1)"
info "第二个变异副本 sha256 = $MUT2_SHA（仓库原件 $REPO_SHA）"
reset_db
run_suite "$BUILD_MUT2" "$STRICT_GROUPS" "mut2"
MUT2_EXIT="$(cat "$TMP/exit-mut2.txt")"
grep -E '^\[(FAIL)\]|^RESULT|^失败项' "$TMP/out-mut2.txt" || true
info "严格基准变异后退出码 = $MUT2_EXIT（必须非 0）"

git -C "$REPO_ROOT" show "HEAD:$SYNC_REL" > "$BUILD_MUT2/src/main/ets/viewmodel/net/SyncService.ets"
if cmp -s "$REPO_ROOT/$SYNC_REL" "$BUILD_MUT2/src/main/ets/viewmodel/net/SyncService.ets"; then
  info "第二个变异副本 git show 还原后与仓库原件逐字节一致（cmp 通过）"
  RESTORED2_OK=1
else
  info "第二个变异副本还原后与仓库原件不一致 —— cmp 失败"
  RESTORED2_OK=0
fi
build "$BUILD_MUT2" "--skip-copy"
reset_db
run_suite "$BUILD_MUT2" "$STRICT_GROUPS" "mut2-restored"
RESTORED2_EXIT="$(cat "$TMP/exit-mut2-restored.txt")"
grep -E '^\[(PASS|FAIL)\]|^RESULT' "$TMP/out-mut2-restored.txt" || true
info "严格基准变异还原后退出码 = $RESTORED2_EXIT（必须 0）"

# ── 7. 零改动核对 + 汇总 ───────────────────────────────────────────────────
say "7. 零改动核对（app/ tests/cases/ tests/tools/l1_offline/；server/ docs/ 并行 agent 的改动单列）"
STRICT="$(git -C "$REPO_ROOT" status --short -- app/ tests/cases/ tests/tools/l1_offline/ 2>/dev/null)"
OTHER="$(git -C "$REPO_ROOT" status --short -- server/ docs/ 2>/dev/null)"
if [ -z "$STRICT" ]; then
  info "干净：app/、tests/cases/、tests/tools/l1_offline/ 零改动（这三处是本任务最该证明没碰的）"
  ZERO_DIFF=1
else
  info "注意：以下路径有改动 ——"
  printf '%s\n' "$STRICT" | sed 's/^/     /'
  ZERO_DIFF=0
fi
if [ -n "$OTHER" ]; then
  info "server/、docs/ 存在改动（并行 agent 的产物，非本任务所为，本任务只读这两处）："
  printf '%s\n' "$OTHER" | sed 's/^/     /'
fi
info "本任务自身产物（未提交则显示为 ??）：$(git -C "$REPO_ROOT" status --short -- tests/tools/l2_sync/ | tr '\n' ' ')"
CODE_SUM_AFTER="$(find "$REPO_ROOT/app/entry/src/main/ets" -name '*.ets' -exec sha256sum {} \; | sort | sha256sum | cut -d' ' -f1)"
info "跑完后 app/**/*.ets 全量 sha256 指纹 = $CODE_SUM_AFTER"
[ "$CODE_SUM_BEFORE" = "$CODE_SUM_AFTER" ] && info "指纹一致 ⇒ 全程未碰 app/**" || info "指纹不一致 ⇒ 有进程改过 app/**（本脚本不会）"

say "8. 汇总"
printf '   %-34s %s\n' "主用例（八项全跑）" "退出码 $MAIN_EXIT（0=全过）"
printf '   %-34s %s\n' "变异（平局判据反转）" "退出码 $MUT_EXIT（须非 0）"
printf '   %-34s %s\n' "git show 还原后复跑" "退出码 $RESTORED_EXIT（须 0）"
printf '   %-34s %s\n' "变异（落库换算多 1000ms）" "退出码 $MUT2_EXIT（须非 0）"
printf '   %-34s %s\n' "严格基准还原后复跑" "退出码 $RESTORED2_EXIT（须 0）"
printf '   %-34s %s\n' "app/ tests/cases/ l1_offline 零改动" "$([ "$ZERO_DIFF" = 1 ] && echo 是 || echo 否)"
printf '   %-34s %s\n' "app/**/*.ets 指纹" "$([ "$CODE_SUM_BEFORE" = "$CODE_SUM_AFTER" ] && echo 未变 || echo 变了)"

FAILED=""
[ "$MAIN_EXIT" = "0" ] || FAILED="$FAILED 主用例"
[ "$MUT_EXIT" != "0" ] || FAILED="$FAILED 变异未变红"
[ "$RESTORED_EXIT" = "0" ] || FAILED="$FAILED 还原后未变绿"
[ "$RESTORED_OK" = "1" ] || FAILED="$FAILED 还原不一致"
[ "$MUT2_EXIT" != "0" ] || FAILED="$FAILED 严格基准变异未变红"
[ "$RESTORED2_EXIT" = "0" ] || FAILED="$FAILED 严格基准还原后未变绿"
[ "$RESTORED2_OK" = "1" ] || FAILED="$FAILED 严格基准还原不一致"
if [ -z "$FAILED" ]; then
  printf '\nRESULT: 全部通过（八项断言 + 三条反证）\n'
  exit 0
fi
printf '\nRESULT: 失败项 ——%s\n' "$FAILED"
exit 1
