/**
 * baseline_validator.mjs —— 用**仓库真实**的测试支撑代码离线跑基准复算（L1 纯逻辑 · 离线）。
 *
 * 本文件**不含任何算法、也不含任何断言口径**：断言口径全部来自仓库里那份真实实现
 * `app/entry/src/ohosTest/ets/test/CalcBaselineValidator.ets`（连同它依赖的
 * `CalcTestTypes.ets` 的 `parseBenchmark` / `parseFactors`），本文件只负责
 * 「读文件 → 调它 → 打印它给出的结论」。
 *
 * 这条链路的价值：`CalcBaselineValidator` 本来只在真机 hypium 里被调用；
 * 本机无真机/模拟器时，它是**唯一**能让「仓库实现 vs 数值唯一真相源」变成可执行证据的途径。
 *
 * 用法：node baseline_validator.mjs <validator.cjs> <types.cjs> \
 *            <tests/cases/carbon-calc.json> <app/.../factors/carbon-factors.json>
 * 退出码：0 = `report.passed() === true`；1 = 有不一致项（**不改基准迁就，失败就是发现**）。
 */

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const [validatorPath, typesPath, benchPath, factorsPath] = process.argv.slice(2);
if (!validatorPath || !typesPath || !benchPath || !factorsPath) {
  console.error('用法: node baseline_validator.mjs <validator.cjs> <types.cjs> <carbon-calc.json> <carbon-factors.json>');
  process.exit(2);
}

const require = createRequire(import.meta.url);
const { CalcBaselineValidator } = require(validatorPath);
const { parseBenchmark, parseFactors } = require(typesPath);

const benchText = readFileSync(benchPath, 'utf8');
const factorsText = readFileSync(factorsPath, 'utf8');

console.log(`消费真实实现 : ${validatorPath}`);
console.log(`解析器来源   : ${typesPath}（parseBenchmark / parseFactors）`);
console.log(`基准         : ${benchPath}`);
console.log(`因子库       : ${factorsPath}`);

const bench = parseBenchmark(benchText);
const factors = parseFactors(factorsText);

const report = CalcBaselineValidator.run(bench, factors);

console.log(`checked = ${report.checked}`);
console.log(`passed  = ${report.passed()}`);
console.log(`summary = ${report.summary()}`);

const mismatches = report.mismatches === undefined ? [] : report.mismatches;
if (mismatches.length > 0) {
  for (const m of mismatches) {
    console.log(`   MISMATCH ${JSON.stringify(m)}`);
  }
}
console.log(`RESULT: checked=${report.checked} passed=${report.passed()} mismatches=${mismatches.length}`);

process.exit(report.passed() ? 0 : 1);
