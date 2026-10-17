/**
 * calc_samples.mjs —— 用**仓库真实** `CarbonCalc` 实现逐样例复算基准（L1 纯逻辑 · 离线）。
 *
 * 本文件**不含任何算法**：它只把 `tests/cases/carbon-calc.json` 的输入喂给
 * esbuild 转译出来的 `CarbonCalc`（源文件是 `app/entry/src/main/ets/service/CarbonCalc.ets`
 * 及其依赖 `DecimalUtil` / `AppConstants` / `CarbonTypes`），再把返回值与基准期望逐条比对。
 *
 * 用法：node calc_samples.mjs <carboncalc.cjs> <tests/cases/carbon-calc.json>
 * 退出码：0 = 全部一致；1 = 有 FAIL（**不改基准去迁就，失败就是发现**）。
 *
 * 覆盖（共 55 项断言）：
 *  ① 18 组正向样例 × (减排量, 应得 C)                      = 36
 *  ② 5 组封顶样例 × (实入 A, capped 标记)                  = 10
 *     其中 `noPointRow: true`（cap-5）追加 1 项「不生成积分流水」判定 = 1
 *  ③ 2 组换算规则（少开一天车 / 回收按件）                  = 2
 *  ④ 边界样例 21 / 22（0.0049 vs 0.005 的分界）            = 4
 *  ⑤ 边界样例 20（骑行 300 km 超限提示但不阻断）            = 2
 *
 * 关于 ② 的一条关键口径（否则会**假失败 1 条**）：
 *   `capSamples` 里 `countsTowardCap === false` 的样例（cap-4「完成目标 S1（+20）」）
 *   走的是**目标奖励路径** —— 目标奖励不封顶、也不计入今日已得记录分 D。
 *   因此对它调用 `actualPointOf(C, D)` 是错误的（会算出 0 而不是 20）；
 *   正确做法是直接取 `A = C`。参见 `AGENTS.md` §2 铁律 4 与附录 B §5.4 封顶口径。
 */

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const [cjsPath, benchPath] = process.argv.slice(2);
if (!cjsPath || !benchPath) {
  console.error('用法: node calc_samples.mjs <carboncalc.cjs> <tests/cases/carbon-calc.json>');
  process.exit(2);
}

const require = createRequire(import.meta.url);
const { CarbonCalc } = require(cjsPath);
const J = JSON.parse(readFileSync(benchPath, 'utf8'));

const factorVersion = (J.meta && J.meta.factorVersion) ? String(J.meta.factorVersion) : '';

/** 因子快照（铁律 3 的落库四字段）；只影响 `evaluate` 的入参，不参与数值计算。 */
function snapshotOf(f) {
  return {
    factorValue: Number(f.value),
    factorVersion,
    factorSource: f.source === undefined ? '' : String(f.source),
    confidence: f.confidence === undefined ? '' : String(f.confidence),
  };
}

const factorByKey = new Map();
for (const f of J.factors) factorByKey.set(f.key, f);

const groups = new Map();
let pass = 0;
let fail = 0;
const fails = [];

function chk(group, name, got, want) {
  const g = groups.get(group) || { pass: 0, fail: 0 };
  if (String(got) === String(want)) {
    g.pass += 1;
    pass += 1;
  } else {
    g.fail += 1;
    fail += 1;
    fails.push(`[${group}] ${name}: got ${got}, want ${want}`);
  }
  groups.set(group, g);
}

function expected(group) {
  const g = groups.get(group);
  return g ? `(预期 ${g.pass + g.fail})` : '';
}

console.log(`消费真实实现 : ${cjsPath}`);
console.log(`基准         : ${benchPath}`);
console.log(`因子版本     : ${factorVersion}`);

// ---------------- ① 18 组正向样例 ----------------
let i = 0;
while (i < J.samples.length) {
  const s = J.samples[i];
  const f = factorByKey.get(s.factorKey);
  if (f === undefined) {
    chk('samples', `#${s.id}.factorKey`, `missing:${s.factorKey}`, 'in baseline factors');
  } else {
    const ev = CarbonCalc.evaluate(f.category, f.subType, Number(s.amount), snapshotOf(f));
    chk('samples', `#${s.id}.reductionKg`, ev.reductionKg.toFixed(4), s.expectedReductionKg);
    chk('samples', `#${s.id}.expectedPointC`, ev.expectedPoint, s.expectedPointC);
  }
  i += 1;
}
console.log(`samples(18×2)        PASS=${groups.get('samples').pass} FAIL=${groups.get('samples').fail}`);

// ---------------- ② 5 组封顶样例 ----------------
let j = 0;
while (j < J.capSamples.length) {
  const c = J.capSamples[j];
  const C = Number(c.expectedC);
  const D = Number(c.todayEarnedD);
  // countsTowardCap === false ⇒ 目标奖励路径：不封顶、不计入 D，直接 A = C
  const A = c.countsTowardCap === false ? C : CarbonCalc.actualPointOf(C, D);
  chk('capSamples', `${c.id}.actualPointA`, A, c.expectedActualA);
  chk('capSamples', `${c.id}.capped`, A < C ? 1 : 0, c.capped);
  if (c.noPointRow === true) {
    // 应得 0 分（减排量 < 0.005 kg）：碳记录可存、**不生成积分流水**。
    // 用基准 `meta.minReductionForPoint`（阈值）自证：阈值以下必不要求流水。
    const min = Number(J.meta.minReductionForPoint);
    chk('capSamples', `${c.id}.pointRequired(阈值以下)`, CarbonCalc.isPointRequired(min - 0.0001), false);
  }
  j += 1;
}
console.log(`capSamples(5×2+1)    PASS=${groups.get('capSamples').pass} FAIL=${groups.get('capSamples').fail}`);

// ---------------- ③ 2 组换算规则 ----------------
let k = 0;
while (k < J.conversions.length) {
  const cv = J.conversions[k];
  let got;
  if (cv.id === 'car-free-days') {
    got = CarbonCalc.amountOfCarFreeDays(Number(cv.input.days), Number(cv.input.kmPerDay));
  } else if (cv.id === 'recycle-by-piece') {
    got = CarbonCalc.amountOfRecyclePieces(Number(cv.input.pieces), Number(cv.input.kgPerPiece));
  } else {
    chk('conversions', `${cv.id}`, 'unknown conversion id', 'car-free-days | recycle-by-piece');
    k += 1;
    continue;
  }
  chk('conversions', `${cv.id}.amount`, got.toFixed(4), Number(cv.expect.amount).toFixed(4));
  k += 1;
}
console.log(`conversions(2)       PASS=${groups.get('conversions').pass} FAIL=${groups.get('conversions').fail}`);

// ---------------- ④⑤ 边界样例 20 / 21 / 22 ----------------
const byId = new Map();
for (const b of J.boundarySamples) byId.set(b.id, b);
const b21 = byId.get(21);
const b22 = byId.get(22);
const b20 = byId.get(20);
if (b21 !== undefined) {
  const r = Number(b21.reductionKg);
  chk('boundary', 'bnd21.expectedPointC', CarbonCalc.expectedPointOf(r), b21.expectedPointC);
  chk('boundary', 'bnd21.pointRequired', CarbonCalc.isPointRequired(r), b21.noPointRow === true ? false : true);
}
if (b22 !== undefined) {
  const r = Number(b22.reductionKg);
  chk('boundary', 'bnd22.expectedPointC', CarbonCalc.expectedPointOf(r), b22.expectedPointC);
  chk('boundary', 'bnd22.pointRequired', CarbonCalc.isPointRequired(r), b22.noPointRow === true ? false : true);
}
if (b20 !== undefined) {
  chk('boundary', 'bnd20.abnormal(骑行300km)', CarbonCalc.isAbnormalInput('travel', 'bicycle', 300), true);
  chk('boundary', 'bnd20.notAbnormal(骑行50km)', CarbonCalc.isAbnormalInput('travel', 'bicycle', 50), false);
}
const bg = groups.get('boundary') || { pass: 0, fail: 0 };
console.log(`boundary 20/21/22(6) PASS=${bg.pass} FAIL=${bg.fail}`);

console.log('');
console.log(`RESULT: PASS=${pass} FAIL=${fail}`);
if (fails.length > 0) {
  for (const x of fails) console.log(`   FAIL ${x}`);
}
process.exit(fail === 0 ? 0 : 1);
