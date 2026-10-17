#!/usr/bin/env bash
#
# l1_offline/run.sh —— L1 纯逻辑的「离线执行真实 ArkTS 实现」执行器。
#
# 本机跑不了 hypium（无真机 / 无模拟器 / Previewer 与 glibc 2.43 不兼容），
# 但纯逻辑模块（CarbonCalc / DecimalUtil / AppConstants / CarbonService /
# CalcBaselineValidator / CalcTestTypes / JsonUtil / StringUtil / CarbonTypes）
# 不 import 任何 ArkTS 运行时 API，因此可以被 esbuild 转译成 CJS 后在 Node 里
# **用仓库里那一份真实实现**执行 `tests/cases/carbon-calc.json` 基准。
#
# 本脚本只做三件事，**不含任何算法实现**：
#   ① 把仓库真实 .ets 源**原样复制**到临时目录（`cmp` 逐字节校验），
#      仅对 ohosTest 侧两个文件的相对 import 前缀做机械改写（`../../../main/ets/` → `../main/ets/`），
#      并断言 diff 的每一行都只涉及该前缀；
#   ② 用 esbuild 把两个入口 bundle 成 CJS（`--metafile` 记录实际吃进去的输入文件），
#      再由 Node 断言「输入文件集合 = 期望的仓库源文件集合」；
#   ③ 用 Node 跑两个 runner，把基准逐条复算在真实实现上。
#
# 用法：
#   bash tests/tools/l1_offline/run.sh
#
# 可用环境变量：
#   ESBUILD / NODE        指定工具路径（缺省走 ~/harmony-toolchain）
#   L1_OFFLINE_BUILD      指定中间产物目录（缺省 mktemp -d，退出时删除）
#   L1_OFFLINE_KEEP=1     保留中间产物（打印目录路径）
#
# 退出码：0 = 两部分全部 PASS；非 0 = 任一 FAIL（详见输出）。
#
# 边界：本脚本**不是** hypium 的替代品。它不覆盖 UI / 数据库 / 网络 / 生命周期，
# 只证明「纯逻辑模块的真实实现与基准一致」。hypium 的 36 个 it() 仍然未运行。
# 详见同目录 README.md。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

# ---------------- 工具定位 ----------------
ESBUILD="${ESBUILD:-$HOME/harmony-toolchain/esbuild/bin/esbuild}"
if [ ! -x "$ESBUILD" ]; then
  ESBUILD="$(command -v esbuild 2>/dev/null || true)"
fi

NODE="${NODE:-$HOME/harmony-toolchain/clt/command-line-tools/tool/node/bin/node}"
if [ ! -x "$NODE" ]; then
  NODE="$(command -v node 2>/dev/null || true)"
fi

if [ ! -x "$ESBUILD" ]; then
  echo "FAIL: 找不到 esbuild（试过 \$ESBUILD、~/harmony-toolchain/esbuild/bin/esbuild、PATH）" >&2
  exit 2
fi
if [ ! -x "$NODE" ]; then
  echo "FAIL: 找不到 node（试过 \$NODE、~/harmony-toolchain/clt/command-line-tools/tool/node/bin/node、PATH）" >&2
  exit 2
fi

# ---------------- 要被消费的仓库真实源文件（**不在本目录里重写**） ----------------
MAIN_ETS="$REPO_ROOT/app/entry/src/main/ets"
TEST_ETS="$REPO_ROOT/app/entry/src/ohosTest/ets/test"
BENCH="$REPO_ROOT/tests/cases/carbon-calc.json"
APP_FACTORS="$REPO_ROOT/app/entry/src/main/resources/rawfile/factors/carbon-factors.json"

# main 侧：保持目录结构，便于相对 import 原样成立
MAIN_SRC=(
  util/DecimalUtil
  util/AppConstants
  util/JsonUtil
  util/StringUtil
  model/CarbonTypes
  service/CarbonCalc
  service/CarbonService
)
# ohosTest 侧：扁平放置，需要把 `../../../main/ets/` 前缀改写为 `../main/ets/`
TEST_SRC=(CalcTestTypes CalcBaselineValidator)

for f in "${MAIN_SRC[@]}"; do
  [ -f "$MAIN_ETS/$f.ets" ] || { echo "FAIL: 缺少源文件 $MAIN_ETS/$f.ets" >&2; exit 2; }
done
for f in "${TEST_SRC[@]}"; do
  [ -f "$TEST_ETS/$f.ets" ] || { echo "FAIL: 缺少源文件 $TEST_ETS/$f.ets" >&2; exit 2; }
done
[ -f "$BENCH" ] || { echo "FAIL: 缺少基准 $BENCH" >&2; exit 2; }
[ -f "$APP_FACTORS" ] || { echo "FAIL: 缺少因子库 $APP_FACTORS" >&2; exit 2; }

# ---------------- 中间产物目录（仓库外，缺省即用即删） ----------------
if [ -n "${L1_OFFLINE_BUILD:-}" ]; then
  BUILD_DIR="$L1_OFFLINE_BUILD"
  mkdir -p "$BUILD_DIR"
else
  BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cbl1-offline-XXXXXX")"
fi

cleanup() {
  if [ "${L1_OFFLINE_KEEP:-0}" = "1" ]; then
    echo "[keep] 中间产物保留在 $BUILD_DIR"
  else
    rm -rf "$BUILD_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR/main/ets" "$BUILD_DIR/test" "$BUILD_DIR/out"
while IFS= read -r d; do mkdir -p "$BUILD_DIR/main/ets/$d"; done < <(printf '%s\n' "${MAIN_SRC[@]}" | xargs -n1 dirname | sort -u)

echo "== l1_offline：离线执行仓库真实 ArkTS 实现 =="
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  echo "仓库 HEAD   : $(git -C "$REPO_ROOT" rev-parse HEAD)"
fi
echo "仓库根      : $REPO_ROOT"
echo "esbuild     : $ESBUILD"
echo "node        : $NODE ($("$NODE" --version))"
echo "中间产物目录: $BUILD_DIR"

# ---------------- ① 复制 + 字节校验 + 机械改写 import 前缀 ----------------
echo
echo "-- ① 消费仓库真实源文件（原样复制，逐字节 cmp） --"
for f in "${MAIN_SRC[@]}"; do
  cp "$MAIN_ETS/$f.ets" "$BUILD_DIR/main/ets/$f.ts"
  cmp -s "$MAIN_ETS/$f.ets" "$BUILD_DIR/main/ets/$f.ts" || { echo "FAIL: 复制不一致 $f" >&2; exit 3; }
  echo "   ok(未改写)  app/entry/src/main/ets/$f.ets  ->  main/ets/$f.ts"
done
for f in "${TEST_SRC[@]}"; do
  cp "$TEST_ETS/$f.ets" "$BUILD_DIR/test/$f.ts"
  cmp -s "$TEST_ETS/$f.ets" "$BUILD_DIR/test/$f.ts" || { echo "FAIL: 复制不一致 $f" >&2; exit 3; }
  # 唯一允许的改写：`../../../main/ets/` -> `../main/ets/`（目录结构变了，import 前缀必须跟着变）
  sed -i "s#'\.\./\.\./\.\./main/ets/#'../main/ets/#g" "$BUILD_DIR/test/$f.ts"
  # 断言：改写后与原文的**每一行差异**都只涉及该前缀，别的一字未动
  stray="$(diff "$TEST_ETS/$f.ets" "$BUILD_DIR/test/$f.ts" | grep -E '^[<>]' | grep -v 'main/ets/' || true)"
  if [ -n "$stray" ]; then
    echo "FAIL: $f 的改写越界（出现了与 import 前缀无关的差异）：" >&2
    echo "$stray" >&2
    exit 3
  fi
  echo "   ok(仅改 import 前缀 app/entry/src/ohosTest/ets/test/$f.ets -> test/$f.ts)"
done

echo
echo "-- ② 被消费源文件的 sha256（留档用；数值/逻辑改动会让它变化） --"
(
  cd "$REPO_ROOT"
  sha256sum \
    $(for f in "${MAIN_SRC[@]}"; do printf 'app/entry/src/main/ets/%s.ets ' "$f"; done) \
    $(for f in "${TEST_SRC[@]}"; do printf 'app/entry/src/ohosTest/ets/test/%s.ets ' "$f"; done)
) | sed 's/^/   /'

# ---------------- ③ esbuild 转译（--bundle / CJS / node） ----------------
echo
echo "-- ③ esbuild 转译成 CJS（--bundle，入口就是仓库源文件转出来的副本） --"
(
  cd "$BUILD_DIR"
  "$ESBUILD" main/ets/service/CarbonCalc.ts \
    --bundle --platform=node --format=cjs --target=node18 --log-level=warning \
    --outfile=out/carboncalc.cjs --metafile=out/carboncalc.meta.json
  "$ESBUILD" test/CalcBaselineValidator.ts \
    --bundle --platform=node --format=cjs --target=node18 --log-level=warning \
    --outfile=out/validator.cjs --metafile=out/validator.meta.json
  "$ESBUILD" test/CalcTestTypes.ts \
    --bundle --platform=node --format=cjs --target=node18 --log-level=warning \
    --outfile=out/types.cjs --metafile=out/types.meta.json
)
echo "   out/carboncalc.cjs out/validator.cjs out/types.cjs"

# ---------------- ④ 断言 bundle 的输入 = 期望的仓库源文件 ----------------
echo
echo "-- ④ bundle 输入文件断言（esbuild metafile：吃进去的就是上面那 9 个仓库源） --"
"$NODE" -e '
const fs = require("fs");
const path = require("path");
const [buildDir] = process.argv.slice(1);
// 期望被消费的仓库源（全部由 ① 逐字节复制而来）
const expected = [
  "main/ets/util/DecimalUtil.ts", "main/ets/util/AppConstants.ts", "main/ets/util/JsonUtil.ts",
  "main/ets/util/StringUtil.ts", "main/ets/model/CarbonTypes.ts",
  "main/ets/service/CarbonCalc.ts", "main/ets/service/CarbonService.ts",
  "test/CalcTestTypes.ts", "test/CalcBaselineValidator.ts",
];
// `model/CarbonTypes.ets` 只含 `type` / `interface`（纯类型），会被 TS 擦除，故不会成为 bundle 输入；
// 它仍然在 ① 里被逐字节复制并被 esbuild 解析（类型解析期消费）。其余 8 个必须真出现在输入里。
const typeOnly = new Set(["main/ets/model/CarbonTypes.ts"]);
const allowed = new Set(expected);
const required = expected.filter((f) => !typeOnly.has(f));
const seen = new Set();
for (const name of ["carboncalc", "validator", "types"]) {
  const meta = JSON.parse(fs.readFileSync(path.join(buildDir, "out", name + ".meta.json"), "utf8"));
  for (const input of Object.keys(meta.inputs)) {
    const abs = path.resolve(buildDir, input);
    if (!abs.startsWith(path.resolve(buildDir) + path.sep)) {
      console.error("FAIL: bundle 输入越出中间目录：" + input);
      process.exit(1);
    }
    seen.add(input);
  }
}
const missing = required.filter((f) => !seen.has(f));
const extra = [...seen].filter((f) => !allowed.has(f));
console.log("   实际输入(" + seen.size + "): " + [...seen].sort().join(", "));
if (missing.length || extra.length) {
  console.error("FAIL: 输入集合与期望不符 missing=" + JSON.stringify(missing) + " extra=" + JSON.stringify(extra));
  process.exit(1);
}
console.log("   ok: 8/8 运行期输入 + 1 个纯类型文件（合计 9/9）全部来自仓库真实源文件");
console.log("   ok: tests/tools/ 里没有一行算法 —— 转译产物完全由 app/ 下那 9 份 .ets 决定");
' "$BUILD_DIR"

# ---------------- ⑤ 执行（两部分任一 FAIL 即非零退出） ----------------
echo
echo "-- ⑤ 用真实实现复算基准 --"
STATUS=0
"$NODE" "$HERE/runners/calc_samples.mjs" "$BUILD_DIR/out/carboncalc.cjs" "$BENCH" || STATUS=1
echo
"$NODE" "$HERE/runners/baseline_validator.mjs" "$BUILD_DIR/out/validator.cjs" "$BUILD_DIR/out/types.cjs" "$BENCH" "$APP_FACTORS" || STATUS=1

echo
if [ "$STATUS" -eq 0 ]; then
  echo "RUN.SH: 全部 PASS（离线纯逻辑部分）"
else
  echo "RUN.SH: 存在 FAIL —— 见上面输出；这是发现，不要改基准去迁就"
fi
exit "$STATUS"
