/**
 * L1 测试套件汇总入口。
 *
 * 职责：把 `ets/test/` 下的各个测试套件登记到 hypium，供 `OpenHarmonyTestRunner` 一次性执行。
 * 新增测试文件时必须在这里 import + 调用，否则用例不会被收集。
 */
import calcSamples from './CalcSamples.test';
import notLoggedIn from './NotLoggedIn.test';
import goalIdempotent from './GoalIdempotent.test';
import badgeIdempotent from './BadgeIdempotent.test';
import shopPurchase from './ShopPurchase.test';
import backupRoundTrip from './BackupRoundTrip.test';
import csvExport from './CsvExport.test';
import lwwMerge from './LwwMerge.test';

export default function testsuite(): void {
  calcSamples();
  notLoggedIn();
  goalIdempotent();
  badgeIdempotent();
  shopPurchase();
  backupRoundTrip();
  csvExport();
  lwwMerge();
}
