/**
 * 近场协同真机适配器（DistributedKitAdapter）
 *
 * 职责：**唯一**接触 `@ohos.distributedDeviceManager` 与 `@ohos.data.distributedKVStore` 的文件，
 *      把「分布式设备发现 + 分布式 KV 收发」翻译成 `DistributedPort` 的五个方法。
 *
 * 为什么必须独立成文件且只能由 `entryability` 注入：
 *  离线 L1 执行器（`tests/tools/l1_offline/runners/offline_run.mjs`）会把未登记的 `@ohos.*`
 *  别名到 `platform/unavailable.cjs`，而它是 `new Proxy({}, { get(){ throw } })` —— 只要有人在
 *  离线用例里 require 到本文件，**一碰属性就抛错**。所以 `ServiceHub` 只 import `DistributedPort`
 *  接口，本文件由 `EntryAbility` 在真机上 `new` 出来注入。
 *
 * 三条健壮性约定（近场是"演示层"，绝不能拖垮主体）：
 *  ① 每个方法内部全 `try/catch`，异常一律折算成"不可用 / 空结果"，**永不向上抛**；
 *  ② 设备发现用同步列表轮询（`getAvailableDeviceListSync`），不注册常驻监听——
 *     少一个 `off()` 就少一处泄漏，且面板本来就是按需刷新；
 *  ③ KV 同步是异步的，`sync()` 只发起不等待，因此收数据用**有界轮询**（拿到对端条目即返回，
 *     或超时返回空），不用固定 sleep，避免慢网把界面卡住。
 */
import distributedDeviceManager from '@ohos.distributedDeviceManager';
import distributedKVStore from '@ohos.data.distributedKVStore';
import { common } from '@kit.AbilityKit';
import { DeviceContribution, DistributedPort, NearbyDevice } from './DistributedPort';
import { parseContribution, serializeContribution } from '../domain/NearbyMerge';

/** 家庭协同使用的 KV 库名（同一 bundle 下唯一）。 */
const STORE_ID: string = 'carbonboo_family';

/** 贡献条目的键前缀（对端只认这个前缀，避免误读其他库数据）。 */
const KEY_PREFIX: string = 'contrib:';

/** 收数据的有界轮询：总时长与单次间隔。 */
const SYNC_WAIT_TOTAL_MS: number = 2000;
const SYNC_POLL_STEP_MS: number = 250;

/** `sync()` 的延迟投递参数（传给系统，非本地 sleep）。 */
const SYNC_DELAY_MS: number = 0;

export class DistributedKitAdapter implements DistributedPort {
  private readonly context: common.Context;
  private readonly bundleName: string;
  private manager: distributedDeviceManager.DeviceManager | undefined = undefined;
  private kvManager: distributedKVStore.KVManager | undefined = undefined;
  private store: distributedKVStore.SingleKVStore | undefined = undefined;

  constructor(context: common.Context, bundleName: string) {
    this.context = context;
    this.bundleName = bundleName;
  }

  /** 懒建 `DeviceManager`；建不出来（无权限 / 能力缺失）返回 undefined。 */
  private ensureManager(): distributedDeviceManager.DeviceManager | undefined {
    if (this.manager !== undefined) {
      return this.manager;
    }
    try {
      this.manager = distributedDeviceManager.createDeviceManager(this.bundleName);
    } catch (e) {
      this.manager = undefined;
    }
    return this.manager;
  }

  /** 懒建 `SingleKVStore`；建不出来返回 undefined。 */
  private async ensureStore(): Promise<distributedKVStore.SingleKVStore | undefined> {
    if (this.store !== undefined) {
      return this.store;
    }
    try {
      if (this.kvManager === undefined) {
        const cfg: distributedKVStore.KVManagerConfig = {
          bundleName: this.bundleName,
          context: this.context
        };
        this.kvManager = distributedKVStore.createKVManager(cfg);
      }
      const options: distributedKVStore.Options = {
        createIfMissing: true,
        encrypt: false,
        backup: false,
        autoSync: false,
        kvStoreType: distributedKVStore.KVStoreType.DEVICE_COLLABORATION,
        securityLevel: distributedKVStore.SecurityLevel.S1
      };
      this.store = await this.kvManager.getKVStore<distributedKVStore.SingleKVStore>(STORE_ID, options);
    } catch (e) {
      this.store = undefined;
    }
    return this.store;
  }

  async available(): Promise<boolean> {
    const manager: distributedDeviceManager.DeviceManager | undefined = this.ensureManager();
    if (manager === undefined) {
      return false;
    }
    try {
      // 能列设备即视为可用；空列表是"可用但附近没设备"，不是不可用。
      manager.getAvailableDeviceListSync();
      return true;
    } catch (e) {
      return false;
    }
  }

  async localNetworkId(): Promise<string> {
    const manager: distributedDeviceManager.DeviceManager | undefined = this.ensureManager();
    if (manager === undefined) {
      return '';
    }
    try {
      return manager.getLocalDeviceNetworkId();
    } catch (e) {
      return '';
    }
  }

  async discover(): Promise<NearbyDevice[]> {
    const manager: distributedDeviceManager.DeviceManager | undefined = this.ensureManager();
    if (manager === undefined) {
      return [];
    }
    const out: NearbyDevice[] = [];
    try {
      const list: distributedDeviceManager.DeviceBasicInfo[] = manager.getAvailableDeviceListSync();
      const now: number = Date.now();
      let localId: string = '';
      try {
        localId = manager.getLocalDeviceNetworkId();
      } catch (e) {
        localId = '';
      }
      for (let i = 0; i < list.length; i++) {
        const dev: distributedDeviceManager.DeviceBasicInfo = list[i];
        if (dev.deviceId === localId) {
          continue;
        }
        const peer: NearbyDevice = {
          deviceId: dev.deviceId,
          deviceName: dev.deviceName,
          deviceModel: dev.deviceType,
          online: true,
          lastSeenAt: now
        };
        out.push(peer);
      }
    } catch (e) {
      return [];
    }
    return out;
  }

  async exchange(local: DeviceContribution, deviceIds: string[]): Promise<DeviceContribution[]> {
    const store: distributedKVStore.SingleKVStore | undefined = await this.ensureStore();
    if (store === undefined) {
      return [];
    }
    const localKey: string = `${KEY_PREFIX}${local.deviceId}`;
    try {
      await store.put(localKey, serializeContribution(local));
    } catch (e) {
      // 连自己的快照都写不进去，本次协同直接放弃（不抛错）。
      return [];
    }
    try {
      store.sync(deviceIds, distributedKVStore.SyncMode.PUSH_PULL, SYNC_DELAY_MS);
    } catch (e) {
      // 同步发起失败：仍尝试读一次本地已有条目（可能上次已同步到位）。
    }
    return await this.collect(store, localKey);
  }

  /**
   * 有界轮询收对端条目：每 `SYNC_POLL_STEP_MS` 读一次，读到至少一条对端贡献即提前返回，
   * 或超过 `SYNC_WAIT_TOTAL_MS` 返回已读到的部分（可能为空）。
   */
  private async collect(store: distributedKVStore.SingleKVStore, localKey: string): Promise<DeviceContribution[]> {
    const deadline: number = Date.now() + SYNC_WAIT_TOTAL_MS;
    let latest: DeviceContribution[] = [];
    while (true) {
      const got: DeviceContribution[] = await this.readEntries(store, localKey);
      if (got.length > 0) {
        return got;
      }
      latest = got;
      if (Date.now() >= deadline) {
        return latest;
      }
      await this.sleep(SYNC_POLL_STEP_MS);
    }
  }

  /** 读取 `KEY_PREFIX` 下的全部条目并解析（跳过本机那一份与解析失败的脏条目）。 */
  private async readEntries(store: distributedKVStore.SingleKVStore, localKey: string): Promise<DeviceContribution[]> {
    const out: DeviceContribution[] = [];
    let entries: distributedKVStore.Entry[] = [];
    try {
      entries = await store.getEntries(KEY_PREFIX);
    } catch (e) {
      return out;
    }
    for (let i = 0; i < entries.length; i++) {
      const entry: distributedKVStore.Entry = entries[i];
      if (entry.key === localKey) {
        continue;
      }
      const text: string = DistributedKitAdapter.valueToText(entry.value);
      if (text.length === 0) {
        continue;
      }
      const parsed: DeviceContribution | undefined = parseContribution(text);
      if (parsed !== undefined) {
        out.push(parsed);
      }
    }
    return out;
  }

  /** 把 KV 的 `Value` 收敛成字符串；非字符串类型一律当脏数据丢弃。 */
  private static valueToText(value: distributedKVStore.Value): string {
    const raw: Uint8Array | string | number | boolean = value.value;
    if (typeof raw === 'string') {
      return raw;
    }
    return '';
  }

  /** 短等待（原生 setTimeout 包一层 Promise；不引任何第三方库）。 */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  async release(): Promise<void> {
    try {
      if (this.kvManager !== undefined && this.store !== undefined) {
        await this.kvManager.closeKVStore(this.bundleName, STORE_ID);
      }
    } catch (e) {
      // 关闭失败不影响业务。
    }
    this.store = undefined;
    this.kvManager = undefined;
    this.manager = undefined;
  }
}
