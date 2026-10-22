/**
 * NearbyMerge —— L1 单测：鸿蒙近场协同的纯逻辑 + 降级语义（ADR-0001 决策②）。
 *
 * 职责（**不碰真机**，全部用端口替身跑）：
 *  ① `NearbyMerge` 纯函数：非法行剔除、按 `deviceId` LWW 去重、定点累加、防御式解析；
 *  ② `DistributedService` 降级：端口不可用 / 无对端时返回稳定错误码，**绝不抛错**；
 *  ③ 正常合并：本机 + 对端若干台 → 设备数/记录数/减排/积分四项正确。
 *
 * 为什么能在没有真机的机器上跑：`DistributedService` 只依赖 `DistributedPort` 接口，
 * 真机适配器（`DistributedKitAdapter`）是唯一 import `@ohos.distributedDeviceManager` /
 * `@ohos.data.distributedKVStore` 的文件，而它只由 `entryability/` 注入。
 * 所以本文件在 `tests/tools/l1_offline` 的 esbuild + node 垫片里可以完整执行。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { FakeHttpClient } from '../../../main/ets/viewmodel/net/HttpPort';
import { MemoryFiles } from '../../../main/ets/viewmodel/store/FilesPort';
import { ServiceHub } from '../../../main/ets/viewmodel/ServiceHub';
import { AppResult } from '../../../main/ets/model/Result';
import { SyncSessionState } from '../../../main/ets/model/SyncTypes';
import {
  DeviceContribution,
  DistributedPort,
  NearbyDevice,
  NullDistributedPort
} from '../../../main/ets/viewmodel/distributed/DistributedPort';
import { DistributedService, NearbyView } from '../../../main/ets/viewmodel/DistributedService';
import {
  MAX_CONTRIBUTION_JSON_LENGTH,
  MAX_CONTRIBUTIONS,
  MergeReport,
  isValidContribution,
  mergeReport,
  normalize,
  parseContribution,
  serializeContribution,
  summarize
} from '../../../main/ets/viewmodel/domain/NearbyMerge';

/** 造一条合法贡献。 */
function contribution(
  deviceId: string, name: string, records: number, reduction: number, points: number, updatedAt: number
): DeviceContribution {
  const c: DeviceContribution = {
    deviceId: deviceId,
    deviceName: name,
    recordCount: records,
    reductionKg: reduction,
    points: points,
    updatedAt: updatedAt
  };
  return c;
}

/** 近场端口替身：可指定「是否可用」「发现到哪些设备」「交换回哪几条贡献」。 */
class FakeNearbyPort implements DistributedPort {
  private readonly usable: boolean;
  private readonly devices: NearbyDevice[];
  private readonly peers: DeviceContribution[];
  private exchanged: number = 0;

  constructor(usable: boolean, devices: NearbyDevice[], peers: DeviceContribution[]) {
    this.usable = usable;
    this.devices = devices;
    this.peers = peers;
  }

  /** 交换次数（断言"调没调"用）。 */
  count(): number {
    return this.exchanged;
  }

  async available(): Promise<boolean> {
    return this.usable;
  }

  async localNetworkId(): Promise<string> {
    return 'net-local';
  }

  async discover(): Promise<NearbyDevice[]> {
    return this.devices;
  }

  async exchange(local: DeviceContribution, deviceIds: string[]): Promise<DeviceContribution[]> {
    this.exchanged++;
    return this.peers;
  }

  async release(): Promise<void> {
    return;
  }
}

export default function nearbyMergeTest(): void {
  describe('NearbyMerge', () => {
    it('纯函数：非法贡献一律丢弃，不修正不猜测', 0, () => {
      // 合法基准
      expect(isValidContribution(contribution('dev-a', '手机', 10, 1.5, 150, 1000))).assertTrue();
      // 设备 id 为空 / 超长
      expect(isValidContribution(contribution('', '手机', 10, 1.5, 150, 1000))).assertFalse();
      expect(isValidContribution(contribution('d'.repeat(65), '手机', 10, 1.5, 150, 1000))).assertFalse();
      // 设备名为空
      expect(isValidContribution(contribution('dev-a', '', 10, 1.5, 150, 1000))).assertFalse();
      // 记录数为负 / 非整数
      expect(isValidContribution(contribution('dev-a', '手机', -1, 1.5, 150, 1000))).assertFalse();
      expect(isValidContribution(contribution('dev-a', '手机', 1.5, 1.5, 150, 1000))).assertFalse();
      // 减排量为负 / 非有限
      expect(isValidContribution(contribution('dev-a', '手机', 10, -0.1, 150, 1000))).assertFalse();
      expect(isValidContribution(contribution('dev-a', '手机', 10, Number.NaN, 150, 1000))).assertFalse();
      // updatedAt 必须为正整数
      expect(isValidContribution(contribution('dev-a', '手机', 10, 1.5, 150, 0))).assertFalse();
    });

    it('纯函数：同一 deviceId 按 updatedAt 做 LWW 去重，并按 id 升序', 0, () => {
      const old: DeviceContribution = contribution('dev-b', '旧手机', 5, 1.0, 100, 1000);
      const fresh: DeviceContribution = contribution('dev-b', '新手机', 8, 2.0, 200, 2000);
      const other: DeviceContribution = contribution('dev-a', '平板', 3, 0.5, 50, 1500);
      const list: DeviceContribution[] = [old, fresh, other];
      const picked: DeviceContribution[] = normalize(list);
      expect(picked.length).assertEqual(2);
      // 升序：dev-a 在前
      expect(picked[0].deviceId).assertEqual('dev-a');
      // dev-b 取 updatedAt 更大的那条
      expect(picked[1].deviceId).assertEqual('dev-b');
      expect(picked[1].recordCount).assertEqual(8);
      expect(picked[1].deviceName).assertEqual('新手机');
      // 输入不被就地改写（纯函数）
      expect(list[0].recordCount).assertEqual(5);
    });

    it('纯函数：超过上限时截断到 MAX_CONTRIBUTIONS', 0, () => {
      const many: DeviceContribution[] = [];
      for (let i = 0; i < MAX_CONTRIBUTIONS + 5; i++) {
        const id: string = `dev-${i < 10 ? '0' : ''}${i}`;
        many.push(contribution(id, `设备${i}`, 1, 0.1, 10, 1000 + i));
      }
      const picked: DeviceContribution[] = normalize(many);
      expect(picked.length).assertEqual(MAX_CONTRIBUTIONS);
    });

    it('纯函数：汇总用定点累加，记录数/积分/减排三项都对得上', 0, () => {
      const list: DeviceContribution[] = [
        contribution('dev-a', '手机', 10, 1.5000, 150, 1000),
        contribution('dev-b', '平板', 4, 0.2500, 25, 2000)
      ];
      const sum = summarize(list);
      expect(sum.devices).assertEqual(2);
      expect(sum.recordCount).assertEqual(14);
      expect(sum.points).assertEqual(175);
      expect(sum.reductionKg).assertEqual(1.75);
    });

    it('纯函数：线上格式可往返，脏数据与超长输入一律丢弃', 0, () => {
      const c: DeviceContribution = contribution('dev-a', '手机', 10, 1.23456, 123, 1000);
      const wire: string = serializeContribution(c);
      const back: DeviceContribution | undefined = parseContribution(wire);
      expect(back !== undefined).assertTrue();
      if (back !== undefined) {
        expect(back.deviceId).assertEqual('dev-a');
        // 序列化时就已按 4 位小数收敛
        expect(back.reductionKg).assertEqual(1.2346);
      }
      // 非法 JSON
      expect(parseContribution('{oops')).assertUndefined();
      expect(parseContribution('')).assertUndefined();
      // 缺字段
      expect(parseContribution('{"deviceId":"dev-a"}')).assertUndefined();
      // 超长（防内存放大）
      const huge: string = `{"pad":"${'x'.repeat(MAX_CONTRIBUTION_JSON_LENGTH)}"}`;
      expect(parseContribution(huge)).assertUndefined();
      // 字段类型不对（对端不可信）
      expect(parseContribution('{"deviceId":1,"deviceName":"a","recordCount":1,"reductionKg":1,"points":1,"updatedAt":1}'))
        .assertUndefined();
    });

    it('服务：端口不可用时降级为「仅本机」，且不抛错', 0, async () => {
      const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const now: number = Date.now();
      const hub: ServiceHub = await ServiceHub.init(context, now, {
        http: new FakeHttpClient(),
        files: new MemoryFiles(),
        distributed: new NullDistributedPort()
      });
      const userId: string = `t-nearby-${now}`;
      await hub.state.ensureUser(userId, now);

      const svc: DistributedService = new DistributedService(
        hub.stats, hub.points, hub.state, new NullDistributedPort()
      );
      const view: NearbyView = await svc.view(now);
      expect(view.available).assertFalse();
      expect(view.devices.length).assertEqual(0);
      // 未组网也要有本机那一份，界面才不会空白
      expect(view.report.summary.devices).assertEqual(1);
      expect(view.message.length > 0).assertTrue();

      const res: AppResult<SyncSessionState> = await svc.exchange(now);
      expect(res.ok).assertFalse();
      expect(res.code).assertEqual('NEARBY_UNAVAILABLE');
    });

    it('服务：有对端时合并本机与对端，冲突数 = 无效行 + 被覆盖的重复行', 0, async () => {
      const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const now: number = Date.now();
      const port: FakeNearbyPort = new FakeNearbyPort(true, [
        { deviceId: 'net-peer-1', deviceName: '客厅平板', deviceModel: 'tablet', online: true, lastSeenAt: now }
      ], [
        contribution('dev-peer', '对端手机', 6, 0.7500, 75, now + 10),
        // 同一个 deviceId 再出现一次（应被 LWW 覆盖 → duplicateCount +1）
        contribution('dev-peer', '对端手机', 9, 0.9000, 90, now + 20),
        // 一条非法（recordCount 为负 → invalidCount +1）
        contribution('dev-bad', '坏设备', -3, 1.0, 10, now + 30)
      ]);
      const hub: ServiceHub = await ServiceHub.init(context, now, {
        http: new FakeHttpClient(),
        files: new MemoryFiles(),
        distributed: port
      });
      const userId: string = `t-nearby2-${now}`;
      await hub.state.ensureUser(userId, now);

      const svc: DistributedService = new DistributedService(hub.stats, hub.points, hub.state, port);
      const res: AppResult<SyncSessionState> = await svc.exchange(now);
      expect(res.ok).assertTrue();
      expect(port.count()).assertEqual(1);
      const summary = svc.lastSummary();
      // 本机 1 台 + 对端 1 台（重复的被合并掉、非法被丢弃）
      expect(summary.devices).assertEqual(2);

      const report: MergeReport = (await svc.view(now)).report;
      expect(report.invalidCount).assertEqual(1);
      expect(report.duplicateCount).assertEqual(1);
      // LWW 保留 updatedAt 更大的那条
      let peerRecords: number = -1;
      for (let i = 0; i < report.contributions.length; i++) {
        if (report.contributions[i].deviceId === 'dev-peer') {
          peerRecords = report.contributions[i].recordCount;
        }
      }
      expect(peerRecords).assertEqual(9);
    });
  });
}
