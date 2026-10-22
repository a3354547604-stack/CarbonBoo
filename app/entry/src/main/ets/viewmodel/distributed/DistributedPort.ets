/**
 * 近场协同端口（DistributedPort）
 *
 * 职责：把「鸿蒙分布式软总线 + 分布式 KV」收敛成一个**可替换的抽象**，让编排层
 *      （`DistributedService`）与合并算法（`NearbyMerge`）都不直接依赖 `@ohos.*` 分布式模块。
 *
 * 为什么要切成端口（三条硬约束，缺一条就会炸）：
 *  ① 离线 L1 执行器（`tests/tools/l1_offline/runners/offline_run.mjs`）把未登记的 `@ohos.*`
 *     一律别名到 `platform/unavailable.cjs`，而它是 `new Proxy({}, { get(){ throw } })`
 *     —— **任何属性访问即抛错**。所以 `ServiceHub` 绝不能静态 import 真机适配器，
 *     只能 import 本文件的接口，由 `entryability` 层把适配器注入进来。
 *  ② 协同是 ADR-0001 决策②的「近场演示层」：**可整体关闭**。未注入端口时一律用
 *     `NullDistributedPort`（`available()` 恒 `false`），其余功能不受任何影响（铁律 1）。
 *  ③ 真机适配器里的一切调用都可能抛（未组网 / 无权限 / 设备不支持），而这些异常必须在
 *     适配器内部被吃掉，只以「不可用」的形式回到编排层——端口方法**永不抛错**。
 *
 * 只读约定：本层只传递**统计快照**（`DeviceContribution`），不传原始碳记录与积分流水。
 * 家庭合并统计只需要「几台设备、共多少条记录、共减排多少、共多少分」，传明细既无必要，
 * 又会把对端的隐私数据落到本机（附录 F §5 不做清单第 9 条）。
 */

/** 近场可见设备（只用于界面展示，不参与合并计算）。 */
export interface NearbyDevice {
  /** 分布式设备标识（`DeviceBasicInfo.deviceId`）。 */
  deviceId: string;
  /** 设备名（本机为 `getLocalDeviceName()`，对端取自 `DeviceBasicInfo.deviceName`）。 */
  deviceName: string;
  /** 设备类型（`DeviceBasicInfo.deviceType`，仅展示）。 */
  deviceModel: string;
  /** 是否在线（`deviceStateChange` 维护）。 */
  online: boolean;
  /** 最近一次看到该设备的时刻（毫秒）。 */
  lastSeenAt: number;
}

/**
 * 单台设备对「家庭碳积分合并视图」的贡献（只读快照）。
 *
 * 字段口径（与附录 B §6.5 一致，不得擅自增删）：
 *  - `recordCount`：该设备上**未删除**的碳记录条数；
 *  - `reductionKg`：该设备上碳记录减排量之和（kgCO₂e，4 位小数）；
 *  - `points`：该设备积分流水的**净额**（收入 − 支出，整数，可为负）；
 *  - `updatedAt`：快照生成时刻（毫秒），同一 `deviceId` 出现多份时按它取最新（LWW）。
 */
export interface DeviceContribution {
  deviceId: string;
  deviceName: string;
  recordCount: number;
  reductionKg: number;
  points: number;
  updatedAt: number;
}

/**
 * 近场协同端口。
 *
 * 生命周期：`prepare()` → 若干轮 `discover()` / `exchange()` → `release()`。
 * 每个方法都**不得抛错**；失败用返回值表达（空数组 / `false`）。
 */
export interface DistributedPort {
  /**
   * 分布式能力是否可用。
   * 返回 `false` 时编排层直接进入「未组网」降级态，不再调用其余方法。
   */
  available(): Promise<boolean>;

  /** 本机网络标识（`getLocalDeviceNetworkId()`）；不可用时返回空串。 */
  localNetworkId(): Promise<string>;

  /** 扫描附近可信设备；不可用 / 无设备返回空数组。 */
  discover(): Promise<NearbyDevice[]>;

  /**
   * 发布本机贡献，并与给定设备做一次双向同步（`SyncMode.PUSH_PULL`），
   * 返回**对端**贡献列表（不含本机自己那一份）。
   * @param local 本机贡献快照
   * @param deviceIds 参与同步的设备标识（来自 `discover()` 且 `online === true`）
   */
  exchange(local: DeviceContribution, deviceIds: string[]): Promise<DeviceContribution[]>;

  /** 释放监听与 KV 资源；重复调用必须安全。 */
  release(): Promise<void>;
}

/**
 * 空端口：没有真机适配器时使用。
 *
 * 语义是「协同不可用」而不是「协同失败」——界面上显示「未组网」，
 * 用户仍可正常使用全部单机功能（铁律 1）。
 */
export class NullDistributedPort implements DistributedPort {
  async available(): Promise<boolean> {
    return false;
  }

  async localNetworkId(): Promise<string> {
    return '';
  }

  async discover(): Promise<NearbyDevice[]> {
    return [];
  }

  async exchange(local: DeviceContribution, deviceIds: string[]): Promise<DeviceContribution[]> {
    // 显式消费入参：空端口不做任何事，但不给「参数没用上」留隐患。
    const ignored: number = local.recordCount + deviceIds.length + local.points + local.reductionKg;
    return ignored >= 0 ? [] : [];
  }

  async release(): Promise<void> {
    return;
  }
}
