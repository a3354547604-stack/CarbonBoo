/**
 * ServiceHub —— 应用里**唯一**的装配点（谁 new 谁、谁依赖谁，只在这里出现）。
 *
 * 为什么要有它：
 *  ① 页面层只允许调 ViewModel，且**不得自己 new Service**（否则一个页面一个 RdbStore、
 *     一次进入页面一次事务嵌套，铁律 1「本机库是唯一真相源」就守不住）；
 *  ② 依赖是显式的：每个 Service 的构造参数都是它真正用到的东西（`StorePort` / `AppState` /
 *     `ResourcePort` …），因此离线复算与用例可以把 `RdbStore` 换成内存实现而不改业务代码；
 *  ③ 端口是**可注入**的：`HttpPort` / `ResourcePort` / `FilesPort` / `AiEngine` / `AuthProvider`
 *     五条副作用边界在 `init()` 的参数里就能替换（「未登录上传数=0」靠注入 `FakeHttpClient` 完成）。
 *
 * 生命周期：`EntryAbility.onCreate` 之后由首页调用一次 `ServiceHub.init(context, now)`，
 * 之后全局 `ServiceHub.get()`。换服务端地址只重建 HTTP 端口，其余端口原样复用。
 */
import { common } from '@kit.AbilityKit';
import { AppResult, fail } from '../model/Result';
import { RdbHelper } from '../data/dao/RdbHelper';
import { PointBalance } from '../model/PointTypes';
import { StorePort } from './store/StorePort';
import { RdbStore } from './store/RdbStore';
import { ResourcePort, ContextResources } from './store/ResourcePort';
import { FilesPort, ContextFiles } from './store/FilesPort';
import { AppConfig, ConfigKeys } from './AppConfig';
import { AppState } from './AppState';
import { PointService } from './PointService';
import { StatsService } from './StatsService';
import { RewardService } from './RewardService';
import { RecordService, CachedFactors, FactorSource } from './RecordService';
import { ShopService } from './ShopService';
import { ScienceService } from './ScienceService';
import { IncludeService } from './IncludeService';
import { AppearanceService } from './AppearanceService';
import { BackupService } from './BackupService';
import { ExportService } from './ExportService';
import { SyncService } from './net/SyncService';
import { AuthService, AuthProvider, LocalAuthProvider, ServerAuthProvider } from './AuthService';
import { AiAssistService, AiEngine, MockAiEngine } from './AiAssistService';
import { DemoService } from './DemoService';
import { ShareService } from './ShareService';
import { HttpClient, HttpPort } from './net/HttpPort';
import { ShopPriceFetcher, ShopPriceOutcome } from './net/ShopPriceFetcher';

/** 可注入的端口（用例替换副作用边界）。 */
export interface HubPorts {
  http?: HttpPort;
  resources?: ResourcePort;
  files?: FilesPort;
  engine?: AiEngine;
  provider?: AuthProvider;
}

/** 服务端地址缺省值（设置页可改；取价/登录失败都按铁律 1 降级，不影响单机功能）。 */
const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8000';

/** 开发者选项页面要展示的三个数（附录 C §23.6）。 */
export interface DevStats {
  dbSizeBytes: number;
  recordCount: number;
  pointBalance: number;
}

export class ServiceHub {
  private static instance: ServiceHub | undefined = undefined;

  readonly context: common.Context;
  readonly store: StorePort;
  readonly state: AppState;
  readonly cfg: AppConfig;
  readonly resources: ResourcePort;
  readonly files: FilesPort;
  readonly engine: AiEngine;
  readonly http: HttpPort;
  readonly points: PointService;
  readonly stats: StatsService;
  readonly reward: RewardService;
  readonly records: RecordService;
  readonly shop: ShopService;
  /** 商品取价（冷启动拉一次并整份覆盖目录；铁律 1 的例外之一）。 */
  readonly shopPrices: ShopPriceFetcher;
  readonly science: ScienceService;
  readonly include: IncludeService;
  readonly appearance: AppearanceService;
  readonly backup: BackupService;
  readonly exportCsv: ExportService;
  readonly sync: SyncService;
  readonly auth: AuthService;
  readonly ai: AiAssistService;
  readonly demo: DemoService;
  readonly share: ShareService;

  private constructor(
    context: common.Context, store: StorePort, state: AppState, cfg: AppConfig, http: HttpPort,
    resources: ResourcePort, files: FilesPort, engine: AiEngine, provider: AuthProvider
  ) {
    this.context = context;
    this.store = store;
    this.state = state;
    this.cfg = cfg;
    this.resources = resources;
    this.files = files;
    this.engine = engine;
    this.http = http;
    this.points = new PointService(store, state);
    this.stats = new StatsService(store, this.points);
    this.reward = new RewardService(store, this.points, this.stats, state);
    const factors: FactorSource = new CachedFactors();
    this.records = new RecordService(store, state, this.points, this.reward, factors);
    this.shop = new ShopService(store, state, this.points, cfg);
    this.shopPrices = new ShopPriceFetcher(http, cfg);
    this.science = new ScienceService(store, state, resources);
    this.include = new IncludeService(store, state, this.points);
    this.appearance = new AppearanceService(store, state);
    this.backup = new BackupService(store, state, files);
    this.exportCsv = new ExportService(store, state, files, this.stats, this.points, this.reward);
    this.sync = new SyncService(store, state, http, cfg);
    this.auth = new AuthService(store, state, cfg, provider);
    this.ai = new AiAssistService(resources, engine);
    this.demo = new DemoService(store, state, this.records, this.reward, this.points, this.include, cfg);
    this.share = new ShareService(context, store, state);
  }

  /**
   * 打开数据库、装好端口、返回全局单例。
   * @param context Ability 上下文（rawfile / filesDir / relationalStore 都要它）
   * @param now 当前时刻
   * @param ports 可替换端口（用例注入；不传则用生产实现）
   */
  static async init(context: common.Context, now: number, ports?: HubPorts): Promise<ServiceHub> {
    await RdbHelper.get().open(context);
    const store: StorePort = new RdbStore(`${context.databaseDir}/rdb`);
    const cfg: AppConfig = new AppConfig(store);
    const state: AppState = await AppState.create(store, cfg, now);
    const resources: ResourcePort = ports !== undefined && ports.resources !== undefined ? ports.resources : new ContextResources(context);
    const files: FilesPort = ports !== undefined && ports.files !== undefined ? ports.files : new ContextFiles(context);
    const engine: AiEngine = ports !== undefined && ports.engine !== undefined ? ports.engine : new MockAiEngine();
    let http: HttpPort | undefined = ports === undefined ? undefined : ports.http;
    if (http === undefined) {
      const configured: string | undefined = await cfg.get(ConfigKeys.SERVER_BASE_URL);
      http = new HttpClient(configured === undefined || configured.length === 0 ? DEFAULT_BASE_URL : configured);
    }
    const provider: AuthProvider = ports !== undefined && ports.provider !== undefined
      ? ports.provider
      : new ServerAuthProvider(http);
    const hub: ServiceHub = new ServiceHub(context, store, state, cfg, http, resources, files, engine, provider);
    ServiceHub.instance = hub;
    return hub;
  }

  /** 已初始化的 Hub（未初始化直接抛错，避免页面静默拿到半成品）。 */
  static get(): ServiceHub {
    const hub: ServiceHub | undefined = ServiceHub.instance;
    if (hub === undefined) {
      throw new Error('ServiceHub 尚未初始化：请先 await ServiceHub.init(context, Date.now())');
    }
    return hub;
  }

  static ready(): boolean {
    return ServiceHub.instance !== undefined;
  }

  /** 用例用：换掉单例（注入内存 store / FakeHttpClient）。 */
  static install(hub: ServiceHub): void {
    ServiceHub.instance = hub;
  }

  /**
   * 开发者选项需要的实时统计（附录 C §23.6）：数据库体积 / 记录数 / 积分余额。
   * 体积取不到时返回 0（页面显示「—」），不编造。
   */
  async devStats(userId: string, now: number): Promise<DevStats> {
    let size: number = 0;
    size = await this.store.sizeBytes();
    const records: number = await this.stats.countRecords(userId, 'all');
    const pbal: PointBalance = await this.points.balance(userId, now);
    const out: DevStats = { dbSizeBytes: size, recordCount: records, pointBalance: pbal.balance };
    return out;
  }

  /**
   * 冷启动取价（附录 B §5.4）：拉一次 `GET /api/v1/shop/items`，成功则**整份覆盖**
   * `app_config['shop_items']`，失败/非法/超时则**整份丢弃**、保留上一份有效目录。
   *
   * 为什么放在 Hub 上而不是直接调 `ShopPriceFetcher`：启动链路需要一个**永不抛错**的入口，
   * 且日志要有一处统一的落点。本方法刻意再包一层 try/catch —— 即使 `ShopPriceFetcher`
   * 将来引入了未捕获异常，也**绝不能**中断冷启动（铁律 1：取价失败不阻塞任何本地功能）。
   * @returns 取价结果摘要；永不抛错
   */
  async fetchShopPrices(): Promise<AppResult<ShopPriceOutcome>> {
    try {
      return await this.shopPrices.fetchAndStore();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : `${e}`;
      return fail<ShopPriceOutcome>('SHOP_FETCH_THREW', `取价异常已吞掉（不影响本地功能）：${msg}`);
    }
  }

  /** 「保存强制抛错」开关（验收 C4/C5）；落 `app_config`，重启后保留但默认关。 */
  async setBreakSave(on: boolean, now: number): Promise<void> {
    this.state.dev().breakSave = on;
    await this.cfg.setFlag(ConfigKeys.DEV_BREAK_SAVE, on);
  }

  static async createForTest(
    context: common.Context, store: StorePort, cfg: AppConfig, state: AppState, resources: ResourcePort,
    files: FilesPort, engine: AiEngine, http: HttpPort, provider: AuthProvider
  ): Promise<ServiceHub> {
    return new ServiceHub(context, store, state, cfg, http, resources, files, engine, provider);
  }

  /**
   * 设置页改了服务端地址后重建 HTTP 端口（其余端口保持同一个实例，不重开数据库）。
   */
  async rebuildHttp(baseUrl: string): Promise<void> {
    await this.cfg.set(ConfigKeys.SERVER_BASE_URL, baseUrl);
    const http: HttpPort = new HttpClient(baseUrl);
    ServiceHub.instance = new ServiceHub(
      this.context, this.store, this.state, this.cfg, http, this.resources, this.files, this.engine,
      new ServerAuthProvider(http)
    );
  }

  /** 纯单机模式（未配置服务端）：provider 换成不联网的占位实现。 */
  useLocalProvider(): void {
    ServiceHub.instance = new ServiceHub(
      this.context, this.store, this.state, this.cfg, this.http, this.resources, this.files, this.engine,
      new LocalAuthProvider()
    );
  }
}
