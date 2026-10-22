/**
 * 家庭碳积分合并服务（DistributedService）
 *
 * 职责：编排一次「近场协同」——问端口可不可用 → 扫设备 → 生成本机贡献 → 与对端交换快照
 *      → 交给 `NearbyMerge` 清洗求和 → 产出可展示的家庭合并视图与一次同步会话状态。
 *
 * 边界（三条，与铁律 1 / 4 直接相关）：
 *  ① **只读视图**：本服务不写碳记录、不写积分流水、不动 `app_config`。合并结果只活在内存里，
 *     供界面展示。因此它不可能破坏「积分单向可追溯」——协同永远不产生积分。
 *  ② **不可用即降级**：端口缺失（`NullDistributedPort`）、未组网、无对端在线，一律返回
 *     `fail(...)` 或 `available=false`，绝不抛错、绝不阻塞任何单机功能。
 *  ③ **不碰 `@ohos.*`**：分布式 API 全部藏在 `DistributedPort` 实现里。本文件只 import 接口，
 *     否则离线 L1 用例一 require 就会撞上 `platform/unavailable.cjs` 的抛错代理。
 */
import { AppResult, fail, ok } from '../model/Result';
import { SyncSessionState } from '../model/SyncTypes';
import { PointBalance } from '../model/PointTypes';
import { AppState } from './AppState';
import { PointService } from './PointService';
import { StatsService } from './StatsService';
import { DeviceContribution, DistributedPort, NearbyDevice } from './distributed/DistributedPort';
import { emptySummary, FamilySummary, mergeReport, MergeReport } from './domain/NearbyMerge';

/** 近场面板要展示的全部内容（一次取齐，避免页面自己拼装业务口径）。 */
export interface NearbyView {
  /** 分布式能力是否可用。`false` 时界面显示「未组网」，其余字段仍可用。 */
  available: boolean;
  /** 附近设备（含离线项，界面用 `online` 区分）。 */
  devices: NearbyDevice[];
  /** 本机贡献（未组网时也一定有值）。 */
  local: DeviceContribution;
  /** 合并明细（含汇总、非法条数、重复条数）。 */
  report: MergeReport;
  /** 给用户看的一句话说明（降级原因 / 合并结果）。 */
  message: string;
}

/** 同一次协同会话的进度分段（与附录 C §18.3 的三段进度条 ①②③ 对应）。 */
const PROGRESS_DISCOVERING: number = 10;
const PROGRESS_MERGING: number = 50;
const PROGRESS_WRITING_BACK: number = 80;
const PROGRESS_DONE: number = 100;

export class DistributedService {
  private readonly stats: StatsService;
  private readonly points: PointService;
  private readonly state: AppState;
  private readonly port: DistributedPort;
  /** 最近一次成功合并的结果（供页面 onAppear 秒开，避免每次进来都闪一下空面板）。 */
  private lastReport: MergeReport | undefined = undefined;

  constructor(stats: StatsService, points: PointService, state: AppState, port: DistributedPort) {
    this.stats = stats;
    this.points = points;
    this.state = state;
    this.port = port;
  }

  /** 本机对家庭合并视图的贡献（条数、减排量、积分净额）。 */
  async localContribution(now: number): Promise<DeviceContribution> {
    const userId: string = this.state.userId();
    const recordCount: number = await this.stats.countRecords(userId, 'all');
    const reductionKg: number = await this.stats.totalReduction(userId);
    const balance: PointBalance = await this.points.balance(userId, now);
    const out: DeviceContribution = {
      deviceId: this.state.deviceId(),
      deviceName: this.state.displayName(),
      recordCount: recordCount,
      reductionKg: reductionKg,
      points: balance.balance,
      updatedAt: now
    };
    return out;
  }

  /**
   * 组装近场面板数据：可用性 + 附近设备 + 本机贡献 + 当前家族汇总。
   *
   * 未组网时 `report` 只含本机一份（`devices === 1`），界面显示「仅本机」而不是空白。
   * 本方法**永不抛错**：端口异常一律当作「不可用」。
   * @param now 当前时刻（毫秒）
   */
  async view(now: number): Promise<NearbyView> {
    let available: boolean = false;
    let devices: NearbyDevice[] = [];
    try {
      available = await this.port.available();
      if (available) {
        devices = await this.port.discover();
      }
    } catch (e) {
      available = false;
      devices = [];
    }
    let local: DeviceContribution;
    try {
      local = await this.localContribution(now);
    } catch (e) {
      // 本机统计读不到（库未就绪）也不该让面板崩掉：给一份零值快照并标注。
      local = {
        deviceId: this.state.deviceId(),
        deviceName: this.state.displayName(),
        recordCount: 0,
        reductionKg: 0,
        points: 0,
        updatedAt: now
      };
    }
    // 已在合并过（lastReport 存在）时直接用它：view 只做「展示最近一次结果」，
    // 不要再拿 contributions 二次 mergeReport —— 那会把 invalidCount / duplicateCount
    // 重算成 0（重复行与非法行在第一次合并时已被剔除），面板就再也看不到丢弃诊断了。
    const report: MergeReport = this.lastReport !== undefined
      ? this.lastReport
      : mergeReport(local, []);
    const out: NearbyView = {
      available: available,
      devices: devices,
      local: local,
      report: report,
      message: this.describe(available, report)
    };
    return out;
  }

  /**
   * 执行一次近场协同：扫描 → 交换 → 合并。
   *
   * 返回值用 `AppResult` 表达失败（不抛异常，符合本仓库统一约定）：
   *  - `NEARBY_UNAVAILABLE`：分布式能力不可用（端口缺失 / 未组网）；
   *  - `NEARBY_NO_PEER`：可用但附近没有在线设备；
   *  - `NEARBY_FAILED`：端口在交换阶段抛错（适配器已兜底，这里是第二道防御）。
   * @param now 当前时刻（毫秒）
   */
  async exchange(now: number): Promise<AppResult<SyncSessionState>> {
    let available: boolean = false;
    try {
      available = await this.port.available();
    } catch (e) {
      available = false;
    }
    if (!available) {
      return fail<SyncSessionState>('NEARBY_UNAVAILABLE', '本机未开启协同或附近无可用组网');
    }

    let devices: NearbyDevice[] = [];
    try {
      devices = await this.port.discover();
    } catch (e) {
      devices = [];
    }
    const onlineIds: string[] = [];
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].online) {
        onlineIds.push(devices[i].deviceId);
      }
    }
    if (onlineIds.length === 0) {
      return fail<SyncSessionState>('NEARBY_NO_PEER', '附近没有已配对且在线的设备');
    }

    const session: SyncSessionState = {
      phase: 'discovering',
      progress: PROGRESS_DISCOVERING,
      pulledCount: 0,
      pushedCount: 0,
      conflictCount: 0,
      startedAt: now
    };
    try {
      const local: DeviceContribution = await this.localContribution(now);
      session.phase = 'merging';
      session.progress = PROGRESS_MERGING;
      const peers: DeviceContribution[] = await this.port.exchange(local, onlineIds);
      session.phase = 'writingBack';
      session.progress = PROGRESS_WRITING_BACK;
      const report: MergeReport = mergeReport(local, peers);
      this.lastReport = report;
      session.phase = 'done';
      session.progress = PROGRESS_DONE;
      session.finishedAt = Date.now();
      session.pulledCount = peers.length;
      session.pushedCount = 1;
      session.conflictCount = report.invalidCount + report.duplicateCount;
      return ok<SyncSessionState>(session);
    } catch (e) {
      session.phase = 'failed';
      session.progress = PROGRESS_DONE;
      session.finishedAt = Date.now();
      session.errorMsg = e instanceof Error ? e.message : `${e}`;
      return fail<SyncSessionState>('NEARBY_FAILED', session.errorMsg);
    }
  }

  /** 最近一次合并的汇总（未合并过则给空汇总，调用方无需判空）。 */
  lastSummary(): FamilySummary {
    const report: MergeReport | undefined = this.lastReport;
    if (report === undefined) {
      return emptySummary();
    }
    return report.summary;
  }

  /** 释放端口资源（页面 `aboutToDisappear` 调用；重复调用安全）。 */
  async release(): Promise<void> {
    try {
      await this.port.release();
    } catch (e) {
      // 释放失败不影响任何业务：忽略。
    }
  }

  /** 生成给用户看的一句话（降级原因 / 合并结果）。 */
  private describe(available: boolean, report: MergeReport): string {
    if (!available) {
      return '未组网：开启"多设备协同"并把两台设备接入同一局域网即可合并家庭数据';
    }
    if (report.summary.devices <= 1) {
      return '已就绪，等待另一台设备加入';
    }
    const parts: string[] = [];
    parts.push(`已合并 ${report.summary.devices} 台设备`);
    if (report.invalidCount > 0) {
      parts.push(`丢弃无效数据 ${report.invalidCount} 条`);
    }
    if (report.duplicateCount > 0) {
      parts.push(`以最新覆盖重复 ${report.duplicateCount} 条`);
    }
    return parts.join('，');
  }
}
