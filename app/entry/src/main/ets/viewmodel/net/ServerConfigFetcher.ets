/**
 * ServerConfigFetcher —— 后台系统配置的**唯一网络入口**（附录 B §5.5，铁律 1 的例外之外）。
 *
 * 职责（只有这一件事）：
 *  ① `GET /api/v1/config`（**无 token** —— 附录 B §5.5 明文「鉴权：无」，
 *     与 §5.4 的 `GET /api/v1/shop/items` 同组；**未登录也要能读到**）；
 *  ② **整份校验**：`data` 必须是
 *     `{ version: 非空字符串, pointsDailyCap: 非负整数, badgesEnabled: boolean,
 *        goalRewards?: [{ goalId: 非空字符串, reward: 非负整数 }], serverTime: 整数 }`。
 *     **任何一处不合法 → 整份丢弃**（不做部分应用、不写一个字节）；
 *  ③ 校验通过才把**整份 JSON** 写入 `app_config['server_config']`
 *     （`version` 与内容同存一处，避免"版本与内容分居两键"的不一致窗口 ——
 *      与 `ShopPriceFetcher` 对 `shop_items` 的处理完全一致）；
 *  ④ `version` 与上一份**相同** → 跳过写入（附录 B §5.5 客户端口径第 5 条）。
 *
 * 为什么"整份"是硬要求（附录 B §5.5 客户端校验与落地口径第 1/2/6 条）：
 * 「任一字段非法 → 整份丢弃：不写 `app_config['server_config']`，沿用上一份有效值；
 *  从未成功拉到过 → 用 App 内置 `rawfile` 种子（`rawfile/goals/goal-defs.json` + 内置封顶 200 + 徽章启用）。」
 * 半份配置比没有配置更糟：封顶值被改了、目标奖励没改（或反之），
 * 用户看到的额度与后台对不上且无法解释。
 *
 * 三条使用侧铁律（本类只负责"搬运"，不参与任何计算）：
 *  - **铁律 1**：服务端配置只是**下行默认值**，本机 `app_config` 仍是唯一真相源；
 *    读取侧一律"取不到 → 回落内置常量"（`PointService.dailyCap()` 等）。
 *  - **铁律 3/4**：本类**只写** `app_config['server_config']` 一个键 ——
 *    不碰历史碳记录、不碰积分流水、不碰已发徽章。
 *  - 失败（无网络 / 超时 / 500 / 未登录 / JSON 非法）**从不抛错**给调用方，
 *    调用方（`EntryAbility` → `ServiceHub.fetchServerConfig`）只记一行日志。
 *
 * 为什么读取侧（`effective`）也是**静态**方法：它只需要一个 `StorePort`，
 * 而 `PointService` / `RewardService` 的构造签名里都没有 `AppConfig`
 * —— 用静态读法可以做到"零接线改动"，同时保证「写入侧与读取侧共用同一套校验」。
 */
import { HttpPort, HttpResponse, HTTP_TIMEOUT_MS } from './HttpPort';
import { AppConfig, ConfigKeys } from '../AppConfig';
import { AppResult, fail, ok } from '../../model/Result';
import { JsonArray, JsonObject, asArray, asObject, must, optNum, optStr, str } from '../../util/JsonUtil';
import { StorePort, firstOf, textOf } from '../store/StorePort';

/** 一条目标奖励的下行值（`goalId` 必须能在内置种子里找到，否则整条忽略）。 */
export interface GoalRewardEntry {
  goalId: string;
  reward: number;
}

/** 一份**已通过整份校验**的服务端配置（`app_config['server_config']` 的内存形态）。 */
export interface ServerConfig {
  /** 本份配置的版本号（非空；客户端只比较"与上一份是否相同"）。 */
  version: string;
  /** 记录类积分每日封顶（非负整数）。 */
  pointsDailyCap: number;
  /** 徽章开关（**布尔**，不是 0/1 整数）。 */
  badgesEnabled: boolean;
  /** 目标奖励覆盖（空数组 = 用内置种子；**未知 `goalId` 已在写入侧被剔除**）。 */
  goalRewards: GoalRewardEntry[];
  /** 服务端时钟（毫秒）。 */
  serverTime: number;
}

/** 一次配置拉取的结果（供启动日志与用例断言）。 */
export interface ServerConfigOutcome {
  /** true = 已按本份配置生效；false = 整份丢弃或与上一份同版本（跳过写入）。 */
  applied: boolean;
  /** 本份配置版本号（失败时为空串）。 */
  version: string;
  /** 生效的目标奖励条数（未知 `goalId` 已剔除）。 */
  goalRewardCount: number;
  /** 生效的每日封顶值（失败时为内置常量）。 */
  pointsDailyCap: number;
  /** 生效的徽章开关（失败时为内置默认 `true`）。 */
  badgesEnabled: boolean;
  /** 未生效原因（生效时为空串）。 */
  reason: string;
}

export class ServerConfigFetcher {
  private readonly http: HttpPort;
  private readonly cfg: AppConfig;
  private readonly store: StorePort;

  /**
   * @param http 网络端口（测试可注入 `FakeHttpClient`）
   * @param cfg `app_config` 门面（读写 `server_config` 键）
   * @param store 数据端口（只用来现读 `goal_def` 的已登记目标 id）
   */
  constructor(http: HttpPort, cfg: AppConfig, store: StorePort) {
    this.http = http;
    this.cfg = cfg;
    this.store = store;
  }

  /** 配置端点（**无 token**）。 */
  private url(): string {
    return `${this.http.baseUrl()}/api/v1/config`;
  }

  /**
   * 拉取并**整份覆盖** `app_config['server_config']`。**从不抛错**（铁律 1）。
   *
   * 成功条件全部满足才写库：HTTP 200 + `ok !== false` + `data` 整份通过校验。
   * @returns 结果摘要；`applied=false` 时 `reason` 说明为何未生效
   */
  async fetchAndStore(): Promise<AppResult<ServerConfigOutcome>> {
    let res: HttpResponse;
    try {
      res = await this.http.request({
        method: 'GET',
        url: this.url(),
        body: '',
        timeoutMs: HTTP_TIMEOUT_MS,
      });
    } catch (e) {
      return fail<ServerConfigOutcome>('CONFIG_FETCH_THREW', `配置拉取请求异常，整份丢弃：${ServerConfigFetcher.messageOf(e)}`);
    }
    if (res.status !== 200) {
      return fail<ServerConfigOutcome>('CONFIG_FETCH_HTTP', `配置拉取失败（HTTP ${res.status}），整份丢弃，保留上一份配置`);
    }
    let parsed: ServerConfig;
    try {
      // 已知目标 id 从**本地种子表** `goal_def` 现读（11 条，由 rawfile 播种）——
      // 不在客户端硬编码一份目标 id 清单，避免它与 `rawfile/goals/goal-defs.json` 漂移。
      const known: string[] = await ServerConfigFetcher.knownGoalIds(this.store);
      parsed = await ServerConfigFetcher.parse(res.body, true, known);
    } catch (e) {
      return fail<ServerConfigOutcome>('CONFIG_FETCH_INVALID', `配置数据非法，整份丢弃，保留上一份配置：${ServerConfigFetcher.messageOf(e)}`);
    }
    // 同版本且已有一份有效配置 → 跳过写入（附录 B §5.5 口径第 5 条）。
    // 注意：比较的必须是**读得回来**的那一份，否则会把"上一份已损坏"误判成"无需重写"。
    const current: ServerConfig | undefined = await ServerConfigFetcher.effective(this.cfg);
    if (current !== undefined && current.version === parsed.version) {
      return ok<ServerConfigOutcome>(ServerConfigFetcher.outcome(parsed, false, '与上一份同版本，跳过写入'));
    }
    try {
      await this.cfg.set(ConfigKeys.SERVER_CONFIG, JSON.stringify(parsed));
    } catch (e) {
      return fail<ServerConfigOutcome>('CONFIG_STORE_FAILED', `配置写入失败：${ServerConfigFetcher.messageOf(e)}`);
    }
    return ok<ServerConfigOutcome>(ServerConfigFetcher.outcome(parsed, true, ''));
  }

  /**
   * 当前生效的服务端配置（读 `app_config['server_config']` 并**再用同一套校验**过一次）。
   *
   * 为什么要重校验而不是直接 `JSON.parse`：读取侧同样要守住「要么整份可信、要么当没有」
   * —— 库里的值可能来自更早的版本（或被人为改坏），此时回落到内置值比拿半份配置去计算安全。
   * @param cfg `app_config` 门面
   * @returns 有效配置；键缺失/为空/解析失败/整份校验不过 → `undefined`
   */
  static async effective(cfg: AppConfig): Promise<ServerConfig | undefined> {
    const raw: string | undefined = await cfg.get(ConfigKeys.SERVER_CONFIG);
    if (raw === undefined || raw.length === 0) {
      return undefined;
    }
    try {
      // 库里这一份是写入侧校验后才落的：未知 goalId 当时已被剔除，故这里传空清单。
      return ServerConfigFetcher.parse(raw, false, []);
    } catch (e) {
      return undefined;
    }
  }

  /**
   * `StorePort` 版的 `effective()`：供没有 `AppConfig` 依赖的层（`PointService` / `RewardService`）读取。
   * 两者读的是**同一个键、同一套校验**，只是入口不同。
   * @param store 数据端口
   */
  static async effectiveFrom(store: StorePort): Promise<ServerConfig | undefined> {
    const rows = await store.query('SELECT value FROM app_config WHERE id = ?', [ConfigKeys.SERVER_CONFIG]);
    const row = firstOf(rows);
    const raw: string = row === undefined ? '' : textOf(row, 'value');
    if (raw.length === 0) {
      return undefined;
    }
    try {
      return await ServerConfigFetcher.parse(raw, false, []);
    } catch (e) {
      return undefined;
    }
  }

  /**
   * 本地已登记的目标 id（`goal_def` 全表）—— 用来判定下行的 `goalId` 是否已知。
   * 表读不到（异常）时返回空清单：此时**所有**下行条目都会被当作未知整条忽略，
   * 效果是"用内置种子"，与"从未拉到过"同一条降级路径（铁律 1）。
   * @param store 数据端口
   */
  private static async knownGoalIds(store: StorePort): Promise<string[]> {
    const rows = await store.query('SELECT id FROM goal_def', []);
    const out: string[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(textOf(rows[i], 'id'));
      i = i + 1;
    }
    return out;
  }

  /**
   * 解析 + **整份校验**（写入侧与读取侧共用，保证两侧判据逐字一致）。
   * @param raw 响应正文或库里的 JSON 文本
   * @param envelope true = `raw` 是**响应信封**（含 `ok` / `data`）；false = 直接的配置对象
   * @param knownGoalIds 已登记的目标 id（未知者整条忽略）
   * @throws 任一处不合法即抛错，由调用方整份丢弃
   */
  private static async parse(raw: string, envelope: boolean, knownGoalIds: string[]): Promise<ServerConfig> {
    const root: JsonObject = asObject(JSON.parse(raw), 'config');
    let data: JsonObject = root;
    if (envelope) {
      if (root['ok'] === false) {
        throw new Error('服务端 ok=false');
      }
      data = asObject(must(root, 'data'), 'config.data');
    }
    const version: string = str(data, 'version', 'config.data');
    if (version.length === 0) {
      // 空版本号无法判断"内容是否变了"，D10-5 的"改了能读到"就退化成碰运气 → 整份丢弃
      throw new Error('config.data.version 为空');
    }
    const capRaw: number = ServerConfigFetcher.requiredInt(data, 'pointsDailyCap');
    if (capRaw < 0) {
      throw new Error(`config.data.pointsDailyCap 非法：${capRaw}（要求非负整数）`);
    }
    const badgesRaw: Object | undefined = data['badgesEnabled'];
    if (typeof badgesRaw !== 'boolean') {
      // 必须是 JSON 布尔：回 0/1 整数即视为非法（附录 B §5.5 的 ⚠️ 条款）
      throw new Error(`config.data.badgesEnabled 期望 boolean，实际 ${typeof badgesRaw}`);
    }
    const rewards: GoalRewardEntry[] = ServerConfigFetcher.rewardsOf(data, knownGoalIds);
    const serverTimeRaw: number = ServerConfigFetcher.requiredInt(data, 'serverTime');
    return {
      version,
      pointsDailyCap: capRaw,
      badgesEnabled: badgesRaw,
      goalRewards: rewards,
      serverTime: serverTimeRaw,
    };
  }

  /** 必填整数（缺字段 / 非整数 / 非有限数都抛错）。 */
  private static requiredInt(o: JsonObject, key: string): number {
    const v: number | undefined = optNum(o, key);
    if (v === undefined) {
      throw new Error(`config.data.${key} 缺失或非数字`);
    }
    if (!Number.isInteger(v)) {
      throw new Error(`config.data.${key} 非整数：${v}`);
    }
    return v;
  }

  /**
   * `goalRewards` 解析（附录 B §5.5 客户端口径第 3 条）：
   *  - **缺省或空数组** → `[]`，语义 = 用 App 内置 `rawfile` 种子；
   *  - 出现时必须是数组，每项 `{ goalId: 非空字符串, reward: 非负整数 }`，任一不合法的**整份丢弃**；
   *  - `goalId` 必须是**已登记**的目标（`goal_def` 里查得到，即 `rawfile/goals/goal-defs.json`
   *    播种的 11 条）——**未知 `goalId` 整条忽略**（其余条目照常生效，且不报错）。
   *    刻意不硬编码这 11 个 id：种子清单的唯一真相源是 rawfile，硬编码会随它漂移。
   * @param data 配置对象
   * @param knownGoalIds 本地已登记的目标 id（空清单 = 全部视为未知，等价于用内置种子）
   */
  private static rewardsOf(data: JsonObject, knownGoalIds: string[]): GoalRewardEntry[] {
    const v: Object | undefined = data['goalRewards'];
    if (v === undefined) {
      return [];
    }
    const arr: JsonArray = asArray(v, 'config.data.goalRewards');
    const out: GoalRewardEntry[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const o: JsonObject = asObject(arr[i], `config.data.goalRewards[${i}]`);
      const goalId: string = str(o, 'goalId', `config.data.goalRewards[${i}]`);
      if (goalId.length === 0) {
        throw new Error(`config.data.goalRewards[${i}].goalId 为空`);
      }
      const reward: number = ServerConfigFetcher.requiredInt(o, 'reward');
      if (reward < 0) {
        throw new Error(`config.data.goalRewards[${i}].reward 非法：${reward}（要求非负整数）`);
      }
      // 未登记的内置目标 → 整条忽略（不报错、不写库、不新增目标）。其余条目照常生效。
      if (knownGoalIds.indexOf(goalId) >= 0) {
        out.push({ goalId, reward });
      }
      i = i + 1;
    }
    return out;
  }

  private static outcome(cfg: ServerConfig, applied: boolean, reason: string): ServerConfigOutcome {
    return {
      applied,
      version: cfg.version,
      goalRewardCount: cfg.goalRewards.length,
      pointsDailyCap: cfg.pointsDailyCap,
      badgesEnabled: cfg.badgesEnabled,
      reason,
    };
  }

  private static messageOf(e: Object): string {
    return e instanceof Error ? e.message : `${e}`;
  }
}
