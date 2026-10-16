/**
 * CsvExport —— L1 单测：CSV 报表编码（验收 D5-8 / 附录 D §10）。
 *
 * 职责：① 三份文件（碳记录 / 积分流水 / 汇总）齐备；
 *  ② 编码口径：UTF-8 **带 BOM** + **CRLF** 行尾（没有裸 `\n`）；
 *  ③ 列序与附录 D §10.1 一致（记录 ID / 发生时间 / 大类 / 类型 / 数量 / 单位 /
 *     减排量 / 因子值 / 因子库版本 / 备注 / 异常标记）；
 *  ④ 含逗号与双引号的备注按 RFC4180 转义（引号包裹 + 内部引号双写）；
 *  ⑤ 每行列数与表头一致。
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
import { CsvBundle, ExportOutcome } from '../../../main/ets/viewmodel/ExportService';
import { CsvFile } from '../../../main/ets/viewmodel/domain/CsvRenderer';
import { AppResult } from '../../../main/ets/model/Result';

const RECORD_HEADER: string =
  '记录ID,发生时间,大类,类型,数量,单位,减排量(kgCO₂e),因子值,因子库版本,备注,异常标记';

/** 去掉 BOM 后按 CRLF 切行。 */
function linesOf(content: string): string[] {
  const body: string = content.startsWith('\uFEFF') ? content.substring(1) : content;
  return body.split('\r\n');
}

export default function csvExportTest(): void {
  describe('CsvExport', () => {
    it('三份 CSV：BOM + CRLF + 列序 + RFC4180 转义', 0, async () => {
      const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const now: number = Date.now();
      const files: MemoryFiles = new MemoryFiles();
      const hub: ServiceHub = await ServiceHub.init(context, now,
        { http: new FakeHttpClient(), files: files });
      await hub.setBreakSave(false, now);
      await hub.auth.logout(now);
      const userId: string = `t-csv-${now}`;
      await hub.state.ensureUser(userId, now);

      // 备注里塞进逗号与引号，专门验证转义
      await hub.records.save(userId, {
        category: 'travel',
        subType: 'bicycle',
        amount: 5,
        occurredAt: now,
        note: '测试,含"引号"',
      }, now);
      await hub.records.save(userId, {
        category: 'utility', subType: 'elec_grid', amount: 3, occurredAt: now - 60000,
      }, now);

      const bundle: CsvBundle = await hub.exportCsv.bundle(userId, now);
      const rec: CsvFile = bundle.records;
      const pts: CsvFile = bundle.points;
      const sum: CsvFile = bundle.summary;

      // 编码：BOM + CRLF，且没有裸 \n
      expect(rec.content.startsWith('\uFEFF')).assertTrue();
      expect(pts.content.startsWith('\uFEFF')).assertTrue();
      expect(sum.content.startsWith('\uFEFF')).assertTrue();
      expect(rec.content.includes('\r\n')).assertTrue();
      expect(rec.content.replace(/\r\n/g, '').includes('\n')).assertFalse();

      // 列序（附录 D §10.1）
      const rows: string[] = linesOf(rec.content);
      expect(rows[0]).assertEqual(RECORD_HEADER);
      expect(rows[0].split(',').length).assertEqual(11);

      // RFC4180：含逗号与引号的备注必须被引号包裹、内部引号双写
      expect(rec.content.includes('"测试,含""引号"""')).assertTrue();

      // 每行字段数与表头一致（用简易状态机按逗号切，识别引号内的逗号）
      let i: number = 1;
      while (i < rows.length) {
        if (rows[i].length > 0) {
          let fields: number = 1;
          let inQuote: boolean = false;
          let j: number = 0;
          while (j < rows[i].length) {
            const ch: string = rows[i].substring(j, j + 1);
            if (ch === '"') {
              inQuote = !inQuote;
            } else if (ch === ',' && !inQuote) {
              fields = fields + 1;
            }
            j = j + 1;
          }
          expect(fields).assertEqual(11);
        }
        i = i + 1;
      }

      // 积分流水与汇总也各有表头
      const pointRows: string[] = linesOf(pts.content);
      expect(pointRows[0].length > 0).assertTrue();
      const sumRows: string[] = linesOf(sum.content);
      expect(sumRows[0].length > 0).assertTrue();

      // 落盘：三份文件都写进 filesDir/export
      const outcome: AppResult<ExportOutcome> = await hub.exportCsv.export(userId, now);
      expect(outcome.ok).assertTrue();
      const written = await hub.exportCsv.list();
      expect(written.length).assertEqual(3);
    });
  });
}
