/**
 * NotLoggedIn —— L1 单测：未登录 = 纯单机（ADR-0001 / 铁律 1）。
 *
 * 职责：用**注入的假 HttpClient** 计数，证明未登录态下：
 *  ① `SyncService.sync / fullUpload / fullRestore` 一律不调用网络（请求计数 = 0）；
 *  ② 本地记录、备份、导出等单机功能照常可用（网络例外只有登录/同步/取价/备份）；
 *  ③ 同步返回的失败码是 `NOT_LOGGED_IN`，不是「网络错误」——即根本没有发出请求。
 *
 * **本机未运行**（如实声明）：hypium 需要 SDK Previewer 进程驱动，该二进制与本机 glibc 不兼容
 * （`pthread_mutex_lock` 断言崩溃 / `hvigorw test` 卡在 GenerateUnitTestResult 超时，EXIT=124），
 * 因此本文件的断言**在本机从未被真实执行过**；本地证据只到「随 ohosTest 目标编译通过」为止。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { FakeHttpClient } from '../../../main/ets/viewmodel/net/HttpPort';
import { MemoryFiles } from '../../../main/ets/viewmodel/store/FilesPort';
import { ServiceHub } from '../../../main/ets/viewmodel/ServiceHub';
import { AppResult } from '../../../main/ets/model/Result';
import { SaveOutcome } from '../../../main/ets/viewmodel/RecordService';
import { CategoryKey } from '../../../main/ets/model/CarbonTypes';
import { SyncOutcome } from '../../../main/ets/viewmodel/net/SyncService';

export default function notLoggedInTest(): void {
  describe('NotLoggedIn', () => {
    it('未登录：同步/全量上传/全量恢复都不发请求，单机功能照常可用', 0, async () => {
      const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const http: FakeHttpClient = new FakeHttpClient();
      const now: number = Date.now();
      const hub: ServiceHub = await ServiceHub.init(context, now, { http: http, files: new MemoryFiles() });
      await hub.setBreakSave(false, now);
      await hub.auth.logout(now);
      const userId: string = `t-nologin-${now}`;
      await hub.state.ensureUser(userId, now);

      // 未登录态：同步三件套一件都不许发请求
      expect(hub.state.isLoggedIn()).assertFalse();
      const syncResult: AppResult<SyncOutcome> = await hub.sync.sync(userId, now);
      expect(syncResult.ok).assertFalse();
      expect(syncResult.code).assertEqual('NOT_LOGGED_IN');
      const upload: AppResult<number> = await hub.sync.fullUpload(userId, now);
      expect(upload.ok).assertFalse();
      expect(upload.code).assertEqual('NOT_LOGGED_IN');
      const restore: AppResult<number> = await hub.sync.fullRestore(userId, now);
      expect(restore.ok).assertFalse();
      expect(restore.code).assertEqual('NOT_LOGGED_IN');
      expect(http.count()).assertEqual(0);

      // 单机功能不受影响：记录照常落库、备份照常生成，且都不碰网络
      const category: CategoryKey = 'travel';
      const saved: AppResult<SaveOutcome> = await hub.records.save(userId, {
        category: category,
        subType: 'bicycle',
        amount: 5,
        occurredAt: now,
        note: '未登录仍可本地记录',
      }, now);
      expect(saved.ok).assertTrue();
      const backup = await hub.backup.create(now);
      expect(backup.ok).assertTrue();
      expect(http.count()).assertEqual(0);

      // 状态查询也只读本机：待同步数 = 参与同步 9 表 pending 行数
      const status = await hub.sync.status(userId);
      expect(status.loggedIn).assertFalse();
      expect(status.pending >= 0).assertTrue();
    });
  });
}
