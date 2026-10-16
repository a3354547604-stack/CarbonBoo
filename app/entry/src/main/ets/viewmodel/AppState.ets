/**
 * AppState —— 会话态与应用级设置的**单一持有者**（当前用户、设备、登录、演示模式、开发者选项）。
 *
 * 职责：
 *  ① 解析「当前 user_id」：演示模式 → `demo-user`；已登录 → 账号 id；否则 → `local-guest`
 *     （铁律 1 的落点：未登录即纯单机，所有读写都带这个 id）；
 *  ② 首次运行补齐本机档案：`device_info`（本机一行）+ `user_profile`（register_day 是
 *     L1「种树百天计划」的起点）+ `user_appearance`（默认头像/主题）；
 *  ③ 开发者选项（DevOptionsSheet）的三个开关，**重启后自动复位为关**（只在内存里）。
 *
 * 为什么把 user_id 收敛到这里：19 张业务表全带 user_id，如果各页各自拼 id，
 * 迟早会出现"演示模式写进了游客账本"这类串账。全应用只有这一处决定 id。
 */
import { AppConfig, ConfigKeys } from './AppConfig';
import { StorePort, firstOf, flagOf, optTextOf, textOf } from './store/StorePort';
import { IdUtil } from './domain/IdUtil';
import { DateUtil } from '../util/DateUtil';
import { AppConstants } from '../util/AppConstants';

/** 登录态。 */
export interface AuthInfo {
  /** 账号 id（`u:<loginName>`）；未登录为空串。 */
  accountUserId: string;
  /** 登录名。 */
  loginName: string;
  loggedIn: boolean;
}

/** 开发者选项（非交付功能，见附录 C §23.6）。 */
export class DevFlags {
  /** 保存事务内强制抛错（验收 C4/C5 用）。 */
  breakSave: boolean = false;
  /** 跳过庆祝半模态。 */
  skipCelebration: boolean = false;
  /** 展示设置页/我的页的内部信息。 */
  verbose: boolean = false;

  static of(row: Record<string, boolean>): DevFlags {
    const f = new DevFlags();
    f.breakSave = row['breakSave'] === true;
    f.skipCelebration = row['skipCelebration'] === true;
    f.verbose = row['verbose'] === true;
    return f;
  }
}

export class AppState {
  private static singleton: AppState | undefined = undefined;

  private readonly store: StorePort;
  private readonly cfg: AppConfig;
  private authValue: AuthInfo;
  private demoMode: boolean;
  private aiEnabled: boolean;
  private remindDaily: boolean;
  private remindTime: string;
  private remindGoal: boolean;
  private deviceIdValue: string;
  private displayNameValue: string;
  private readonly devFlags: DevFlags;

  private constructor(
    store: StorePort,
    cfg: AppConfig,
    auth: AuthInfo,
    demoMode: boolean,
    aiEnabled: boolean,
    remindDaily: boolean,
    remindTime: string,
    remindGoal: boolean,
    deviceId: string
  ) {
    this.store = store;
    this.cfg = cfg;
    this.authValue = auth;
    this.demoMode = demoMode;
    this.aiEnabled = aiEnabled;
    this.remindDaily = remindDaily;
    this.remindTime = remindTime;
    this.remindGoal = remindGoal;
    this.deviceIdValue = deviceId;
    this.displayNameValue = AppConstants.DEFAULT_DISPLAY_NAME;
    this.devFlags = new DevFlags();
  }

  /**
   * 建立会话态（首次运行会补齐 `device_info` 与当前用户的档案行）。
   * @param store 数据端口
   * @param cfg 配置门面
   * @param now 当前时刻
   */
  static async create(store: StorePort, cfg: AppConfig, now: number): Promise<AppState> {
    const demoMode: boolean = await cfg.flag(ConfigKeys.DEMO_MODE, false);
    const aiEnabled: boolean = await cfg.flag(ConfigKeys.AI_ENABLED, true);
    const remindDaily: boolean = await cfg.flag(ConfigKeys.REMIND_DAILY, true);
    const rawRemindTime: string | undefined = await cfg.get(ConfigKeys.REMIND_TIME);
    const remindTime: string = rawRemindTime === undefined ? '20:00' : rawRemindTime;
    const remindGoal: boolean = await cfg.flag(ConfigKeys.REMIND_GOAL, true);
    const auth: AuthInfo = AppState.parseAuth(await cfg.get(ConfigKeys.AUTH_USER));
    const deviceId: string = await AppState.ensureDevice(store, cfg, now);
    const state = new AppState(store, cfg, auth, demoMode, aiEnabled, remindDaily, remindTime, remindGoal, deviceId);
    await state.ensureUser(state.userId(), now);
    state.displayNameValue = await state.displayNameOf(state.userId());
    AppState.singleton = state;
    return state;
  }

  /** 注册为全局单例（由 `ServiceHub` 调用）。 */
  static attach(state: AppState): void {
    AppState.singleton = state;
  }

  /** 取全局单例（未初始化抛错，避免静默拿到半个应用）。 */
  static current(): AppState {
    if (AppState.singleton === undefined) {
      throw new Error('AppState 尚未初始化（请先经 ServiceHub.init 进入应用）');
    }
    return AppState.singleton;
  }

  /** 是否已初始化。 */
  static ready(): boolean {
    return AppState.singleton !== undefined;
  }

  // ------------------------------------------------------------ 身份

  /** 当前 user_id（所有业务读写都用它）。 */
  userId(): string {
    if (this.demoMode) {
      return AppConstants.DEMO_USER_ID;
    }
    if (this.authValue.loggedIn) {
      return this.authValue.accountUserId;
    }
    return AppConstants.GUEST_USER_ID;
  }

  /** 本机设备标识。 */
  deviceId(): string {
    return this.deviceIdValue;
  }

  /** 本机档案显示名。 */
  displayName(): string {
    return this.displayNameValue;
  }

  /** 同步状态标记：未登录一律 `local`（不上传），登录后写 `pending`。 */
  syncState(): string {
    return this.authValue.loggedIn && !this.demoMode ? 'pending' : 'local';
  }

  isLoggedIn(): boolean {
    return this.authValue.loggedIn;
  }

  loginName(): string {
    return this.authValue.loginName;
  }

  accountUserId(): string {
    return this.authValue.accountUserId;
  }

  isDemo(): boolean {
    return this.demoMode;
  }

  isAiEnabled(): boolean {
    return this.aiEnabled;
  }

  isRemindDaily(): boolean {
    return this.remindDaily;
  }

  remindTimeValue(): string {
    return this.remindTime;
  }

  isRemindGoal(): boolean {
    return this.remindGoal;
  }

  dev(): DevFlags {
    return this.devFlags;
  }

  // ------------------------------------------------------------ 状态变更

  /** 切登录态（登录/退出/注销都用它，写 `auth_user`）。 */
  async setAuth(auth: AuthInfo, now: number): Promise<void> {
    this.authValue = auth;
    if (auth.loggedIn) {
      await this.cfg.set(ConfigKeys.AUTH_USER, `${auth.accountUserId}\n${auth.loginName}`);
    } else {
      await this.cfg.remove(ConfigKeys.AUTH_USER);
    }
    // 首次进入某账号：补齐档案与外观行（D6-11「本机数据并入账号」由 AuthService 负责搬运）
    await this.ensureUser(this.userId(), now);
    this.displayNameValue = await this.displayNameOf(this.userId());
  }

  /** 切演示模式（写 `demo_mode`；数据按 `demo-user` 隔离）。 */
  async setDemoMode(on: boolean, now: number): Promise<void> {
    this.demoMode = on;
    await this.cfg.setFlag(ConfigKeys.DEMO_MODE, on);
    await this.ensureUser(this.userId(), now);
    this.displayNameValue = await this.displayNameOf(this.userId());
  }

  async setAiEnabled(on: boolean): Promise<void> {
    this.aiEnabled = on;
    await this.cfg.setFlag(ConfigKeys.AI_ENABLED, on);
  }

  async setRemindDaily(on: boolean): Promise<void> {
    this.remindDaily = on;
    await this.cfg.setFlag(ConfigKeys.REMIND_DAILY, on);
  }

  async setRemindTime(value: string): Promise<void> {
    this.remindTime = value;
    await this.cfg.set(ConfigKeys.REMIND_TIME, value);
  }

  async setRemindGoal(on: boolean): Promise<void> {
    this.remindGoal = on;
    await this.cfg.setFlag(ConfigKeys.REMIND_GOAL, on);
  }

  /** 刷新显示名（外观页改名后调用）。 */
  async refreshDisplayName(): Promise<void> {
    this.displayNameValue = await this.displayNameOf(this.userId());
  }

  // ------------------------------------------------------------ 档案

  /** 注册日（毫秒，本地 00:00）；缺档案时按今天建。 */
  async registerDayMs(userId: string, now: number): Promise<number> {
    await this.ensureUser(userId, now);
    const rows = await this.store.query('SELECT register_day FROM user_profile WHERE user_id = ?', [userId]);
    const row = firstOf(rows);
    if (row === undefined) {
      return DateUtil.addDays(now, 0);
    }
    return AppState.parseDay(textOf(row, 'register_day'), now);
  }

  /** 组织/删除档案行（幂等：`INSERT OR IGNORE`）。 */
  async ensureUser(userId: string, now: number): Promise<void> {
    const ids = await this.store.query('SELECT id FROM user_profile WHERE user_id = ?', [userId]);
    if (ids.length === 0) {
      await this.store.exec(
        'INSERT OR IGNORE INTO user_profile (id, user_id, display_name, register_day, onboarded, last_active_at, created_at, updated_at, is_deleted, device_id, sync_state) ' +
        'VALUES (?, ?, ?, ?, 0, ?, ?, ?, 0, ?, ?)',
        [IdUtil.uuid(), userId, AppConstants.DEFAULT_DISPLAY_NAME, DateUtil.dayKeyOfMs(now), now, now, now, this.deviceIdValue, this.syncState()]
      );
    }
    const ap = await this.store.query('SELECT id FROM user_appearance WHERE user_id = ?', [userId]);
    if (ap.length === 0) {
      await this.store.exec(
        'INSERT OR IGNORE INTO user_appearance (id, user_id, avatar_id, frame_id, theme_id, nickname, created_at, updated_at, is_deleted, device_id, sync_state) ' +
        'VALUES (?, ?, ?, NULL, ?, NULL, ?, ?, 0, ?, ?)',
        [IdUtil.uuid(), userId, 'avatar_leaf', 'theme_default', now, now, this.deviceIdValue, this.syncState()]
      );
    }
  }

  /** 触摸活跃时间。 */
  async touch(now: number): Promise<void> {
    await this.store.exec('UPDATE user_profile SET last_active_at = ?, updated_at = ? WHERE user_id = ?', [now, now, this.userId()]);
  }

  private async displayNameOf(userId: string): Promise<string> {
    const rows = await this.store.query(
      'SELECT COALESCE(a.nickname, p.display_name) AS name FROM user_profile p ' +
      'LEFT JOIN user_appearance a ON a.user_id = p.user_id WHERE p.user_id = ?',
      [userId]
    );
    const row = firstOf(rows);
    if (row === undefined) {
      return AppConstants.DEFAULT_DISPLAY_NAME;
    }
    const name: string | undefined = optTextOf(row, 'name');
    return name === undefined || name.length === 0 ? AppConstants.DEFAULT_DISPLAY_NAME : name;
  }

  // ------------------------------------------------------------ 内部

  /** 解析 `auth_user`（`userId\nloginName`）。 */
  private static parseAuth(raw: string | undefined): AuthInfo {
    if (raw === undefined || raw.length === 0) {
      return { accountUserId: '', loginName: '', loggedIn: false };
    }
    const parts: string[] = raw.split('\n');
    if (parts.length < 2) {
      return { accountUserId: '', loginName: '', loggedIn: false };
    }
    return { accountUserId: parts[0], loginName: parts[1], loggedIn: true };
  }

  /** 首次运行生成本机标识并落 `device_info`。 */
  private static async ensureDevice(store: StorePort, cfg: AppConfig, now: number): Promise<string> {
    const existing: string | undefined = await cfg.get(ConfigKeys.DEVICE_ID);
    if (existing !== undefined && existing.length > 0) {
      return existing;
    }
    const id: string = IdUtil.deviceId();
    await cfg.set(ConfigKeys.DEVICE_ID, id);
    await store.exec(
      'INSERT OR IGNORE INTO device_info (id, device_id, device_name, device_model, is_self, last_sync_at, paired_devices, created_at, updated_at) ' +
      'VALUES (?, ?, ?, ?, 1, NULL, ?, ?, ?)',
      ['self', id, '本机', 'OpenHarmony 设备', '[]', now, now]
    );
    return id;
  }

  /** `YYYY-MM-DD` → 本地 00:00 毫秒。 */
  private static parseDay(day: string, fallback: number): number {
    const parts: string[] = day.split('-');
    if (parts.length !== 3) {
      return DateUtil.addDays(fallback, 0);
    }
    const y: number = Number.parseInt(parts[0], 10);
    const m: number = Number.parseInt(parts[1], 10);
    const d: number = Number.parseInt(parts[2], 10);
    if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d)) {
      return DateUtil.addDays(fallback, 0);
    }
    return new Date(y, m - 1, d, 0, 0, 0, 0).getTime();
  }

  /** 本机是否已有该用户的自建档案（调试信息用）。 */
  async hasProfile(userId: string): Promise<boolean> {
    const rows = await this.store.query('SELECT id FROM user_profile WHERE user_id = ?', [userId]);
    return rows.length > 0;
  }

  /** `app_config` 中是否已开启演示模式（供 `DemoService` 参考）。 */
  async demoFlag(): Promise<boolean> {
    return this.cfg.flag(ConfigKeys.DEMO_MODE, false);
  }
}
