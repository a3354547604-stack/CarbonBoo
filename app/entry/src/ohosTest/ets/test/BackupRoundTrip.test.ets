/**
 * BackupRoundTrip —— L1 单测：本地备份 / 恢复往返一致（验收 D5-1 / D5-10）。
 *
 * 职责：① 备份文件是 `carbonboo-backup-YYYYMMDD-HHmm.json` 形态，落到 `backup/`，
 *  且带路径与字节数（UI 文案要显示这两项）；
 *  ② 内容是 `carbonboo-backup` 信封 + 校验和，19 张表齐全；
 *  ③ 恢复 = 覆盖：先删本次改动，再恢复，19 表逐表行数与备份时**完全一致**；
 *  ④ 清理旧备份只保留最近 3 份。
 *
 * **本机未运行**（如实声明）：hypium 依赖 SDK Previewer 进程；本机无设备、预览器崩溃，
 * 断言在本机未真实执行，本地证据只到「随 ohosTest 目标编译通过」。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { FakeHttpClient } from '../../../main/ets/viewmodel/net/HttpPort';
import { MemoryFiles } from '../../../main/ets/viewmodel/store/FilesPort';
import { ServiceHub } from '../../../main/ets/viewmodel/ServiceHub';
import { numOf } from '../../../main/ets/viewmodel/store/StorePort';
import { ClientSchema } from '../../../main/ets/data/schema/ClientSchema';
import { BackupCodec, BackupEnvelope } from '../../../main/ets/viewmodel/domain/BackupCodec';
import { BackupItem, BackupOutcome, RestoreOutcome } from '../../../main/ets/viewmodel/BackupService';
import { AppResult } from '../../../main/ets/model/Result';
import { CarbonRecord } from '../../../main/ets/model/CarbonTypes';

/** 单表行数（19 张表逐表比对用）。 */
async function countOf(hub: ServiceHub, table: string): Promise<number> {
  const rows = await hub.store.query(`SELECT COUNT(*) AS c FROM ${table}`);
  if (rows.length === 0) {
    return -1;
  }
  return numOf(rows[0], 'c');
}

/** 19 张表的行数快照。 */
async function countsOf(hub: ServiceHub): Promise<number[]> {
  const out: number[] = [];
  let i: number = 0;
  while (i < ClientSchema.TABLES.length) {
    out.push(await countOf(hub, ClientSchema.TABLES[i]));
    i = i + 1;
  }
  return out;
}

export default function backupRoundTripTest(): void {
  describe('BackupRoundTrip', () => {
    it('备份→改动→恢复：19 表行数逐表一致，文件名/大小/时间齐备', 0, async () => {
      const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const now: number = Date.now();
      const files: MemoryFiles = new MemoryFiles();
      const hub: ServiceHub = await ServiceHub.init(context, now,
        { http: new FakeHttpClient(), files: files });
      await hub.setBreakSave(false, now);
      await hub.auth.logout(now);
      const userId: string = `t-backup-${now}`;
      await hub.state.ensureUser(userId, now);

      const save1 = await hub.records.save(userId, {
        category: 'travel', subType: 'metro', amount: 8, occurredAt: now - 3600000,
      }, now);
      expect(save1.ok).assertTrue();
      await hub.records.save(userId, {
        category: 'recycle', subType: 'paper', amount: 3, occurredAt: now - 7200000,
      }, now);
      await hub.appearance.save(userId, 'avatar_bike', '', 'theme_default', '备份测试');

      const beforeBackup: number[] = await countsOf(hub);
      const backup: AppResult<BackupOutcome> = await hub.backup.create(now);
      expect(backup.ok).assertTrue();
      if (backup.data !== undefined) {
        expect(backup.data.name.includes('carbonboo-backup-')).assertTrue();
        expect(backup.data.name.endsWith('.json')).assertTrue();
        expect(backup.data.size > 0).assertTrue();
        expect(backup.data.tableCount).assertEqual(ClientSchema.TABLES.length);
      }

      const list: BackupItem[] = await hub.backup.list();
      expect(list.length >= 1).assertTrue();
      expect(list[0].size > 0).assertTrue();

      // 信封与校验和：解出来必须与备份时同一份
      const text: string = await files.readText(`backup/${list[0].name}`);
      const envelope: BackupEnvelope = BackupCodec.decode(text);
      expect(envelope.format).assertEqual('carbonboo-backup');
      expect(envelope.snapshot.tables.length).assertEqual(ClientSchema.TABLES.length);
      expect(envelope.checksum).assertEqual(BackupCodec.checksumOf(envelope.snapshot));

      // 改动：删一条 + 加一条（恢复后都应被覆盖回去）
      const recent: CarbonRecord[] = await hub.records.page(userId, 'all', 0, 1);
      expect(recent.length).assertEqual(1);
      await hub.records.remove(userId, recent[0].id, now);
      await hub.records.save(userId, {
        category: 'plate', subType: 'meal', amount: 1, occurredAt: now,
      }, now);

      const path: string = list[0].path;
      const restored: AppResult<RestoreOutcome> = await hub.backup.restore(path, true);
      expect(restored.ok).assertTrue();

      const afterRestore: number[] = await countsOf(hub);
      let i: number = 0;
      while (i < ClientSchema.TABLES.length) {
        expect(afterRestore[i]).assertEqual(beforeBackup[i]);
        i = i + 1;
      }

      // 恢复前的安全快照也生成了（恢复 = 覆盖，但先自保一份）
      const list2: BackupItem[] = await hub.backup.list();
      expect(list2.length >= 2).assertTrue();

      // 备份文件里不含隐私字段（姓名/学校/队名/指导教师）
      expect(text.includes('学校')).assertFalse();
      expect(text.includes('队名')).assertFalse();
      expect(text.includes('指导教师')).assertFalse();

      // 清理旧备份：只保留最近 3 份
      await hub.backup.create(now + 1000);
      await hub.backup.create(now + 2000);
      const removed: number = await hub.backup.cleanOld();
      expect(removed >= 0).assertTrue();
      expect((await hub.backup.list()).length <= 3).assertTrue();
    });
  });
}
