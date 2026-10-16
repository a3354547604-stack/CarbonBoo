/**
 * L1 测试套件汇总入口。
 *
 * 职责：把 `ets/test/` 下的各个测试套件登记到 hypium，供 `OpenHarmonyTestRunner` 一次性执行。
 * 新增测试文件时必须在这里 import + 调用，否则用例不会被收集。
 */
import calcSamples from './CalcSamples.test';

export default function testsuite(): void {
  calcSamples();
}
