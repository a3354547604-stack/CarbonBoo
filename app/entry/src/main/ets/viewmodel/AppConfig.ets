/**
 * AppConfig —— `app_config` 键值表的读写封装（本机专属，**不参与同步**）。
 *
 * 职责：把「开关 / 时间 / 最近账号 / 设备标识」这类应用级设置收敛成一个 KV 门面，
 * 供 `AppState`（会话态）与 `SettingsPage`（设置页）共用。
 *
 * 存储口径：`value` 一律是字符串（`'1'` / `'0'` / `'20:00'` / JSON 文本）。
 * 为什么不直接塞进 `AppConstants`：那些是**编译期常量**（口径，不可变），
 * 这里是**运行期设置**（用户可改、要落库、要跨重启保留），两者混在一起会导致
 * 「设置项改了但口径也跟着变」这类事故。
 */
import { StorePort, firstOf, optTextOf, textOf } from './store/StorePort';
import { ResourcePort } from './store/ResourcePort';

/** `app_config` 的键（唯一集中地）。 */
export class ConfigKeys {
  /** schema 版本（app-core 写入，本层只读）。 */
  static readonly SCHEMA_VERSION: string = 'schema_version';
  /** 头像种子 JSON（app-core 写入）。 */
  static readonly AVATARS: string = 'avatars';
  /** 权益种子 JSON（app-core 写入）。 */
  static readonly BENEFITS: string = 'benefits';
  /** 演示模式开关（`1` = 开）。 */
  static readonly DEMO_MODE: string = 'demo_mode';
  /** 端侧识图开关。 */
  static readonly AI_ENABLED: string = 'ai_enabled';
  /** 每日记录提醒开关。 */
  static readonly REMIND_DAILY: string = 'remind_daily';
  /** 提醒时间（`HH:mm`，默认 `20:00`）。 */
  static readonly REMIND_TIME: string = 'remind_time';
  /** 目标达成提醒开关。 */
  static readonly REMIND_GOAL: string = 'remind_goal';
  /** 最近登录账号（`userId\nloginName`，未登录为空）。 */
  static readonly AUTH_USER: string = 'auth_user';
  /** 本机设备标识（首次运行生成一次）。 */
  static readonly DEVICE_ID: string = 'device_id';
  /** 开发者选项：保存时强制抛错（C4）。 */
  static readonly DEV_BREAK_SAVE: string = 'dev_break_save';
  /** 开发者选项：跳过半模态。 */
  static readonly DEV_SKIP_SHEET: string = 'dev_skip_sheet';
  /** 开发者选项：时间偏移天数（模拟补记窗口）。 */
  static readonly DEV_SHIFT_DAYS: string = 'dev_shift_days';
  /** 近场协同最近一次对端（`deviceId|deviceName`）。 */
  static readonly SYNC_PEER: string = 'sync_peer';
  /** 最近一次云端同步时间（毫秒字符串）。 */
  static readonly LAST_SYNC_AT: string = 'last_sync_at';
  /** 服务端根地址（**不硬编码**，设置页可改；附录 C §21 / AGENTS §6）。 */
  static readonly SERVER_BASE_URL: string = 'server_base_url';
  /** 登录令牌（只经 `AuthProvider` 读写，页面与 ViewModel 不得直接碰它）。 */
  static readonly AUTH_TOKEN: string = 'auth_token';
  /** 账号 id（服务端返回的 `userId`，形如 `u-...`）。 */
  static readonly AUTH_USER_ID: string = 'auth_user_id';
  /** 上次同步下来的商品目录版本（取价整份覆盖用）。 */
  static readonly SHOP_ITEMS: string = 'shop_items';
  /**
   * 后台下发的系统配置（`server_config`）——整份 JSON 同存一处
   * （`version` + `pointsDailyCap` + `badgesEnabled` + `goalRewards` + `serverTime`）。
   *
   * 与 `SHOP_ITEMS` 同款理由：把"版本号"与"内容"存进同一个键，避免出现
   * "版本已更新、内容还是旧的"这种不一致窗口（附录 B §5.5 客户端落地口径第 4 条）。
   * **本键只由 `ServerConfigFetcher` 写入**；消费方（`PointService` / `RewardService`）
   * 一律经 `ServerConfigFetcher.effectiveFrom(store)` 读取，取不到即回落内置常量（铁律 1）。
   */
  static readonly SERVER_CONFIG: string = 'server_config';
  /**
   * 云端恢复**前**的云端原状快照（`preRestore` + `preRestoreAt` 的 JSON）。
   *
   * 为什么由客户端落盘：附录 B §5.3:819 规定覆盖前原状随响应 `preRestore` 返回，
   * 「服务端**不新建表**、由调用方保存」（PLAN §7.8）。本机存一份即可满足"覆盖前可回看"。
   */
  static readonly CLOUD_PRE_RESTORE: string = 'cloud_pre_restore';
}

export class AppConfig {
  private readonly store: StorePort;

  constructor(store: StorePort) {
    this.store = store;
  }

  /** 读字符串（不存在返回 `undefined`）。 */
  async get(key: string): Promise<string | undefined> {
    const rows = await this.store.query('SELECT value FROM app_config WHERE id = ?', [key]);
    const row = firstOf(rows);
    if (row === undefined) {
      return undefined;
    }
    return optTextOf(row, 'value');
  }

  /** 写字符串（UPSERT）。 */
  async set(key: string, value: string): Promise<void> {
    const now: number = Date.now();
    await this.store.exec(
      'INSERT INTO app_config (id, value, version, fetched_at, created_at, updated_at) VALUES (?, ?, NULL, NULL, ?, ?) ' +
      'ON CONFLICT(id) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at',
      [key, value, now, now]
    );
  }

  /** 读布尔（缺省 `fallback`）。 */
  async flag(key: string, fallback: boolean): Promise<boolean> {
    const v: string | undefined = await this.get(key);
    if (v === undefined) {
      return fallback;
    }
    return v === '1' || v === 'true';
  }

  /** 写布尔。 */
  async setFlag(key: string, value: boolean): Promise<void> {
    await this.set(key, value ? '1' : '0');
  }

  /** 读整数（缺省 `fallback`）。 */
  async integer(key: string, fallback: number): Promise<number> {
    const v: string | undefined = await this.get(key);
    if (v === undefined) {
      return fallback;
    }
    const n: number = Number.parseInt(v, 10);
    return Number.isFinite(n) ? n : fallback;
  }

  /** 读整数时间戳（缺省 0）。 */
  async stamp(key: string): Promise<number> {
    return this.integer(key, 0);
  }

  /** 删除键。 */
  async remove(key: string): Promise<void> {
    await this.store.exec('DELETE FROM app_config WHERE id = ?', [key]);
  }

  /** 读种子 JSON（头像 / 权益由 app-core 写在这里）。 */
  async json(key: string): Promise<string> {
    const rows = await this.store.query('SELECT value FROM app_config WHERE id = ?', [key]);
    const row = firstOf(rows);
    return row === undefined ? '' : textOf(row, 'value');
  }

  /** 读 rawfile 文本（转发给 `ResourcePort`，便于测试替换）。 */
  static async rawText(res: ResourcePort, path: string): Promise<string> {
    return res.readRawText(path);
  }
}
