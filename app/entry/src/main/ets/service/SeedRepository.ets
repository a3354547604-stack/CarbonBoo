/**
 * SeedRepository —— 静态字典种子的 **rawfile 加载 + 落库**（唯一入口）。
 *
 * 职责：
 *  ① 读 7 份 rawfile 种子（**完全离线**，不出网）：
 *     `factors/carbon-factors.json`（因子库，按附录 A §7 全文）、
 *     `goals/goal-defs.json`（11 条）、`badges/badge-defs.json`（8 条）、
 *     `shop/shop-items.json`（9 条）、`appearance/avatars.json`（8 个）、
 *     `include/benefits.json`（5 条）、`science/science-index.json`（12 篇）；
 *  ② 首次安装时把它们写进对应的静态字典表（附录 B §9「首次安装」迁移路径）；
 *  ③ 幂等：写库一律 `ON_CONFLICT_REPLACE` 按主键覆盖，重复启动不会产生重复行。
 *
 * 对应表（附录 B §1.1 的 5 张静态字典 + 配置）：
 *   `goal_def` / `badge_def` / `shop_item` / `science_article` / `carbon_factor_meta`，
 *   外加把头像与权益写进 `app_config`（二者没有独立表，见附录 B §2 无
 *   `avatar_def` / `benefit_def` 表这一事实——它们是纯展示数据，随外观/碳普惠模块读取）。
 *
 * 事务：整个种子写入包在**一个事务**里（`RdbHelper.runInTransaction`），
 * 中途任何一份 JSON 解析失败 → 整体回滚，不会留下"目标写进去了但徽章没写"的半库。
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import * as J from '../util/JsonUtil';
import { JsonArray, JsonObject } from '../util/JsonUtil';
import { AppConstants } from '../util/AppConstants';
import { RdbHelper } from '../data/dao/RdbHelper';
import { AvatarSeedRow, BadgeSeedRow, BenefitSeedRow, GoalSeedRow, ScienceSeedRow, ShopSeedRow } from '../model/SeedTypes';
import { FactorLibrary } from './FactorLibrary';

/** rawfile 路径常量（与附录 B §8 / 附录 A §7 的"落盘路径"逐字一致）。 */
const RAW_GOALS: string = 'goals/goal-defs.json';
const RAW_BADGES: string = 'badges/badge-defs.json';
const RAW_SHOP: string = 'shop/shop-items.json';
const RAW_AVATARS: string = 'appearance/avatars.json';
const RAW_BENEFITS: string = 'include/benefits.json';
const RAW_SCIENCE: string = 'science/science-index.json';
const RAW_FACTORS: string = 'factors/carbon-factors.json';

/** 种子写入结果（供启动自检与测试断言）。 */
export class SeedReport {
  readonly goals: number;
  readonly badges: number;
  readonly shopItems: number;
  readonly articles: number;
  readonly avatars: number;
  readonly benefits: number;
  readonly factorVersion: string;

  constructor(
    goals: number,
    badges: number,
    shopItems: number,
    articles: number,
    avatars: number,
    benefits: number,
    factorVersion: string
  ) {
    this.goals = goals;
    this.badges = badges;
    this.shopItems = shopItems;
    this.articles = articles;
    this.avatars = avatars;
    this.benefits = benefits;
    this.factorVersion = factorVersion;
  }
}

export class SeedRepository {
  /**
   * 读取并写入全部静态字典（幂等）。
   * @param helper RdbHelper（用它的 `runInTransaction` 保证原子性）
   * @param context Ability 的 context（取 `resourceManager` 用）
   */
  static async seedStatic(helper: RdbHelper, context: common.Context): Promise<SeedReport> {
    const goals: GoalSeedRow[] = SeedRepository.readGoals(await SeedRepository.readRaw(context, RAW_GOALS));
    const badges: BadgeSeedRow[] = SeedRepository.readBadges(await SeedRepository.readRaw(context, RAW_BADGES));
    const shop: ShopSeedRow[] = SeedRepository.readShop(await SeedRepository.readRaw(context, RAW_SHOP));
    const avatars: AvatarSeedRow[] = SeedRepository.readAvatars(await SeedRepository.readRaw(context, RAW_AVATARS));
    const benefits: BenefitSeedRow[] = SeedRepository.readBenefits(await SeedRepository.readRaw(context, RAW_BENEFITS));
    const science: ScienceSeedRow[] = SeedRepository.readScience(await SeedRepository.readRaw(context, RAW_SCIENCE));
    const factors: FactorLibrary = FactorLibrary.parse(await SeedRepository.readRaw(context, RAW_FACTORS));

    const now: number = Date.now();
    await helper.runInTransaction(async () => {
      await SeedRepository.writeGoals(helper.store(), goals, now);
      await SeedRepository.writeBadges(helper.store(), badges, now);
      await SeedRepository.writeShop(helper.store(), shop, now);
      await SeedRepository.writeScience(helper.store(), science, now);
      await SeedRepository.writeFactorMeta(helper.store(), factors, now);
      // 头像与权益没有独立表：作为展示字典存进 app_config（id 即字典键）。
      await SeedRepository.putConfig(helper.store(), 'avatars', SeedRepository.toJson(avatars), factors.version(), now);
      await SeedRepository.putConfig(helper.store(), 'benefits', SeedRepository.toJson(benefits), factors.version(), now);
    });

    return new SeedReport(
      goals.length,
      badges.length,
      shop.length,
      science.length,
      avatars.length,
      benefits.length,
      factors.version()
    );
  }

  // ---------------------------------------------------------------- rawfile
  /** 读 rawfile 全文（UTF-8）。 */
  static async readRaw(context: common.Context, path: string): Promise<string> {
    const bytes: Uint8Array = await context.resourceManager.getRawFileContent(path);
    return new util.TextDecoder().decodeToString(bytes);
  }

  // ---------------------------------------------------------------- 解析
  /** `goal-defs.json` → 强类型（11 条）。 */
  static readGoals(json: string): GoalSeedRow[] {
    const arr: JsonArray = J.asArray(JSON.parse(json), 'goal-defs');
    const out: GoalSeedRow[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const o: JsonObject = J.asObject(arr[i], `goal-defs[${i}]`);
      const tier: string = J.str(o, 'tier', 'goal');
      const period: string = J.str(o, 'period', 'goal');
      const metric: string = J.str(o, 'metric', 'goal');
      const category: string | undefined = J.optStr(o, 'category');
      out.push({
        id: J.str(o, 'id', 'goal'),
        name: J.str(o, 'name', 'goal'),
        tier: SeedRepository.toGoalTier(tier),
        period: SeedRepository.toGoalPeriod(period),
        metric: SeedRepository.toGoalMetric(metric),
        category: category === undefined ? undefined : SeedRepository.toCategory(category),
        subTypes: J.optStrArray(o, 'subTypes', 'goal'),
        unit: J.optStr(o, 'unit'),
        threshold: J.num(o, 'threshold', 'goal'),
        reward: J.num(o, 'reward', 'goal'),
        icon: J.str(o, 'icon', 'goal'),
        order: J.num(o, 'order', 'goal'),
      });
      i = i + 1;
    }
    return out;
  }

  /** `badge-defs.json` → 强类型（8 条）。 */
  static readBadges(json: string): BadgeSeedRow[] {
    const arr: JsonArray = J.asArray(JSON.parse(json), 'badge-defs');
    const out: BadgeSeedRow[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const o: JsonObject = J.asObject(arr[i], `badge-defs[${i}]`);
      out.push({
        id: J.str(o, 'id', 'badge'),
        name: J.str(o, 'name', 'badge'),
        description: J.str(o, 'description', 'badge'),
        tier: SeedRepository.toBadgeTier(J.str(o, 'tier', 'badge')),
        icon: J.str(o, 'icon', 'badge'),
        metric: SeedRepository.toBadgeMetric(J.str(o, 'metric', 'badge')),
        threshold: J.num(o, 'threshold', 'badge'),
        order: J.num(o, 'order', 'badge'),
      });
      i = i + 1;
    }
    return out;
  }

  /** `shop-items.json` → 强类型（9 条）。 */
  static readShop(json: string): ShopSeedRow[] {
    const arr: JsonArray = J.asArray(JSON.parse(json), 'shop-items');
    const out: ShopSeedRow[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const o: JsonObject = J.asObject(arr[i], `shop-items[${i}]`);
      out.push({
        id: J.str(o, 'id', 'shop'),
        section: SeedRepository.toSection(J.str(o, 'section', 'shop')),
        name: J.str(o, 'name', 'shop'),
        description: J.optStr(o, 'description'),
        price: J.num(o, 'price', 'shop'),
        icon: J.str(o, 'icon', 'shop'),
        order: J.num(o, 'order', 'shop'),
        onShelf: J.num(o, 'onShelf', 'shop'),
        isDefaultFree: J.num(o, 'isDefaultFree', 'shop'),
      });
      i = i + 1;
    }
    return out;
  }

  /** `avatars.json` → 强类型（8 个，全部免费）。 */
  static readAvatars(json: string): AvatarSeedRow[] {
    const arr: JsonArray = J.asArray(JSON.parse(json), 'avatars');
    const out: AvatarSeedRow[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const o: JsonObject = J.asObject(arr[i], `avatars[${i}]`);
      out.push({
        id: J.str(o, 'id', 'avatar'),
        name: J.str(o, 'name', 'avatar'),
        icon: J.str(o, 'icon', 'avatar'),
        default: J.bool(o, 'default', 'avatar'),
      });
      i = i + 1;
    }
    return out;
  }

  /** `benefits.json` → 强类型（5 条模拟权益）。 */
  static readBenefits(json: string): BenefitSeedRow[] {
    const arr: JsonArray = J.asArray(JSON.parse(json), 'benefits');
    const out: BenefitSeedRow[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const o: JsonObject = J.asObject(arr[i], `benefits[${i}]`);
      out.push({
        id: J.str(o, 'id', 'benefit'),
        name: J.str(o, 'name', 'benefit'),
        description: J.str(o, 'description', 'benefit'),
        coinCost: J.num(o, 'coinCost', 'benefit'),
        icon: J.str(o, 'icon', 'benefit'),
      });
      i = i + 1;
    }
    return out;
  }

  /** `science-index.json` → 强类型（12 篇；政策 4 / 技巧 4 / 知识 4）。 */
  static readScience(json: string): ScienceSeedRow[] {
    const arr: JsonArray = J.asArray(JSON.parse(json), 'science-index');
    const out: ScienceSeedRow[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const o: JsonObject = J.asObject(arr[i], `science-index[${i}]`);
      const tags: string[] | undefined = J.optStrArray(o, 'tags', 'science');
      out.push({
        id: J.str(o, 'id', 'science'),
        title: J.str(o, 'title', 'science'),
        category: SeedRepository.toScienceCategory(J.str(o, 'category', 'science')),
        summary: J.str(o, 'summary', 'science'),
        cover: J.str(o, 'cover', 'science'),
        readMinutes: J.num(o, 'readMinutes', 'science'),
        tags: tags === undefined ? [] : tags,
        order: J.num(o, 'order', 'science'),
      });
      i = i + 1;
    }
    return out;
  }

  // ---------------------------------------------------------------- 落库
  private static async writeGoals(store: relationalStore.RdbStore, rows: GoalSeedRow[], now: number): Promise<void> {
    let i: number = 0;
    while (i < rows.length) {
      const r: GoalSeedRow = rows[i];
      const values: relationalStore.ValuesBucket = {
        id: r.id,
        name: r.name,
        tier: r.tier,
        period: r.period,
        metric: r.metric,
        category: r.category === undefined ? null : r.category,
        // `sub_types` 列是"JSON 数组字符串"（附录 B §2 goal_def 注释）
        sub_types: r.subTypes === undefined ? null : JSON.stringify(r.subTypes),
        unit: r.unit === undefined ? null : r.unit,
        threshold: r.threshold,
        reward: r.reward,
        icon: r.icon,
        order: r.order,
        created_at: now,
        updated_at: now,
      };
      await store.insert('goal_def', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      i = i + 1;
    }
  }

  private static async writeBadges(store: relationalStore.RdbStore, rows: BadgeSeedRow[], now: number): Promise<void> {
    let i: number = 0;
    while (i < rows.length) {
      const r: BadgeSeedRow = rows[i];
      const values: relationalStore.ValuesBucket = {
        id: r.id,
        name: r.name,
        description: r.description,
        tier: r.tier,
        icon: r.icon,
        metric: r.metric,
        threshold: r.threshold,
        order: r.order,
        created_at: now,
        updated_at: now,
      };
      await store.insert('badge_def', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      i = i + 1;
    }
  }

  private static async writeShop(store: relationalStore.RdbStore, rows: ShopSeedRow[], now: number): Promise<void> {
    let i: number = 0;
    while (i < rows.length) {
      const r: ShopSeedRow = rows[i];
      const values: relationalStore.ValuesBucket = {
        id: r.id,
        section: r.section,
        name: r.name,
        description: r.description === undefined ? null : r.description,
        price: r.price,
        icon: r.icon,
        order: r.order,
        on_shelf: r.onShelf,
        is_default_free: r.isDefaultFree,
        created_at: now,
        updated_at: now,
      };
      await store.insert('shop_item', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      i = i + 1;
    }
  }

  private static async writeScience(store: relationalStore.RdbStore, rows: ScienceSeedRow[], now: number): Promise<void> {
    let i: number = 0;
    while (i < rows.length) {
      const r: ScienceSeedRow = rows[i];
      const values: relationalStore.ValuesBucket = {
        id: r.id,
        title: r.title,
        category: r.category,
        summary: r.summary,
        cover: r.cover,
        read_minutes: r.readMinutes,
        tags: JSON.stringify(r.tags),
        order: r.order,
        created_at: now,
        updated_at: now,
      };
      await store.insert('science_article', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      i = i + 1;
    }
  }

  /** 因子元信息只有一行：主键固定 `factors`，版本号即因子库版本。 */
  private static async writeFactorMeta(
    store: relationalStore.RdbStore,
    lib: FactorLibrary,
    now: number
  ): Promise<void> {
    const values: relationalStore.ValuesBucket = {
      id: 'factors',
      version: lib.version(),
      source_updated: lib.meta().updatedAt,
      note: lib.meta().note,
      created_at: now,
      updated_at: now,
    };
    await store.insert('carbon_factor_meta', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  private static async putConfig(
    store: relationalStore.RdbStore,
    key: string,
    json: string,
    version: string,
    now: number
  ): Promise<void> {
    const values: relationalStore.ValuesBucket = {
      id: key,
      value: json,
      version,
      fetched_at: now,
      created_at: now,
      updated_at: now,
    };
    await store.insert('app_config', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  private static toJson(rows: Object[]): string {
    return JSON.stringify(rows);
  }

  // ---------------------------------------------------------------- 枚举窄化
  private static toCategory(v: string): 'travel' | 'utility' | 'recycle' | 'plate' {
    if (v === 'travel' || v === 'utility' || v === 'recycle' || v === 'plate') {
      return v;
    }
    throw new Error(`目标定义 category 非法枚举值：${v}`);
  }

  private static toGoalTier(v: string): 'short' | 'mid' | 'long' {
    if (v === 'short' || v === 'mid' || v === 'long') {
      return v;
    }
    throw new Error(`目标定义 tier 非法枚举值：${v}`);
  }

  private static toGoalPeriod(v: string): 'day' | 'week' | 'month' | 'quarter' | 'year' | 'hundred_days' {
    if (
      v === 'day' || v === 'week' || v === 'month' || v === 'quarter' || v === 'year' || v === 'hundred_days'
    ) {
      return v;
    }
    throw new Error(`目标定义 period 非法枚举值：${v}`);
  }

  private static toGoalMetric(v: string): 'count' | 'sum_amount' | 'sum_reduction' | 'distinct_days' {
    if (v === 'count' || v === 'sum_amount' || v === 'sum_reduction' || v === 'distinct_days') {
      return v;
    }
    throw new Error(`目标定义 metric 非法枚举值：${v}`);
  }

  private static toBadgeTier(v: string): 'bronze' | 'silver' | 'gold' {
    if (v === 'bronze' || v === 'silver' || v === 'gold') {
      return v;
    }
    throw new Error(`徽章定义 tier 非法枚举值：${v}`);
  }

  private static toBadgeMetric(
    v: string
  ): 'first_record' | 'streak' | 'total_reduction' | 'travel_count' | 'recycle_kg' | 'frame_count' {
    if (
      v === 'first_record' || v === 'streak' || v === 'total_reduction' ||
      v === 'travel_count' || v === 'recycle_kg' || v === 'frame_count'
    ) {
      return v;
    }
    throw new Error(`徽章定义 metric 非法枚举值：${v}`);
  }

  private static toSection(v: string): 'frame' | 'theme' {
    if (v === 'frame' || v === 'theme') {
      return v;
    }
    throw new Error(`商品 section 非法枚举值：${v}`);
  }

  private static toScienceCategory(v: string): 'policy' | 'tips' | 'knowledge' {
    if (v === 'policy' || v === 'tips' || v === 'knowledge') {
      return v;
    }
    throw new Error(`科普 category 非法枚举值：${v}`);
  }
}
