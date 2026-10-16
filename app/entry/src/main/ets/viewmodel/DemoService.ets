/**
 * DemoService —— 演示数据播种 / 清除（S4 之外的演示支撑，规格见附录 D §9）。
 *
 * 职责：
 *  ① `seed()`：生成 90 天约 260 条碳记录，走**真实的保存链路**（`RecordService.save`
 *     → `CarbonService.calculate` → `PointService`），不直接写库、不伪造积分；
 *  ② 全部演示行 `user_id = AppConstants.DEMO_USER_ID`（`demo-user`），并置
 *     `app_config['demo_mode'] = 1`；`clear()` 按该 id 清空 19 张表并复位开关；
 *  ③ 徽章与目标由 `RewardService` 真实结算（自动解锁 6 枚，故意留 `B_TOTAL_100`
 *     与 `B_TREE` 供现场解锁）；
 *  ④ 收尾时按「目标余额」反算一笔碳普惠兑换，使**积分余额落在附录 D §9 的
 *     4000–6000 区间**（同时对齐「我的」页示例值 4,820 与碳币示例 48）。
 *
 * ## 与文档的一处数值冲突（已按 AGENTS §1.3 上报，不自行取舍）
 *
 * 附录 D §9 同时给出三个数：**约 260 条 / 累计减排 60–90 kg / 积分余额 4000–6000 分**，
 * 且表格里列了「典型值」（如骑行 5 km = 0.9600 kg、节电 3–12 kWh = 1.7–6.8 kg）。
 * 但按 PLAN §9 的口径 `积分 = 减排量 × 100`（每日封顶 200），三者无法同时成立：
 * 单是 72 条出行按典型值就是 69 kg（≈6,900 分），再加上水电/回收/光盘会到 300 kg 以上。
 * 本实现的取舍（**可复算、可复核**）：保住**功能约束**——累计减排 < 100 kg
 * （否则 `B_TOTAL_100` 会自动解锁，与「故意留 2 枚」冲突）、积分余额落在 4000–6000、
 * 90 天约 260 条、32 天连续——因此把每条记录的量按「每天约 0.7 kg」缩放，
 * 总量约 63 kg。冲突已写入交付报告，等文档侧裁决数值口径。
 */
import { CarbonRecord, CategoryKey } from '../model/CarbonTypes';
import { PointBalance } from '../model/PointTypes';
import { CarbonCoin } from '../model/IncludeTypes';
import { StorePort, RowShape, firstOf, numOf } from './store/StorePort';
import { ClientSchema } from '../data/schema/ClientSchema';
import { RecordService, SaveRecordInput, SaveOutcome } from './RecordService';
import { RewardService } from './RewardService';
import { PointService } from './PointService';
import { IncludeService } from './IncludeService';
import { ExchangeOutcome } from './IncludeService';
import { AppConfig, ConfigKeys } from './AppConfig';
import { AppState } from './AppState';
import { AppConstants } from '../util/AppConstants';
import { DateUtil } from '../util/DateUtil';
import { Dec } from '../util/DecimalUtil';
import { AppResult, fail, ok } from '../model/Result';

/** 播种结果（开发者选项与交付报告都用它，避免"播种成功但数对不上"）。 */
export interface DemoSeedReport {
  /** 写入的碳记录条数。 */
  records: number;
  /** 累计减排（kgCO₂e，4 位小数）。 */
  reductionKg: number;
  /** 播种后的积分余额。 */
  pointBalance: number;
  /** 播种后的碳币余额。 */
  coinBalance: number;
  /** 已解锁徽章数（目标 6）。 */
  badges: number;
  /** 收尾那笔碳普惠兑换的碳币数。 */
  exchangeCoins: number;
  /** 覆盖天数。 */
  days: number;
}

/** 一条待播种的记录（子类 + 数量）。 */
interface SeedItem {
  category: CategoryKey;
  subType: string;
  amount: number;
}

export class DemoService {
  private readonly store: StorePort;
  private readonly state: AppState;
  private readonly records: RecordService;
  private readonly reward: RewardService;
  private readonly points: PointService;
  private readonly include: IncludeService;
  private readonly cfg: AppConfig;

  constructor(store: StorePort, state: AppState, records: RecordService, reward: RewardService, points: PointService, include: IncludeService, cfg: AppConfig) {
    this.store = store;
    this.state = state;
    this.records = records;
    this.reward = reward;
    this.points = points;
    this.include = include;
    this.cfg = cfg;
  }

  /** 演示数据是否已播种（`app_config['demo_mode']`）。 */
  async isSeeded(): Promise<boolean> {
    return this.state.isDemo();
  }

  /** 播种（先清后播，幂等）。 */
  async seed(now: number): Promise<AppResult<DemoSeedReport>> {
    const userId: string = AppConstants.DEMO_USER_ID;
    try {
      await this.clear();
      await this.state.setDemoMode(true, now);
      const written: number = await this.sow(userId, now);
      if (written === 0) {
        return fail<DemoSeedReport>('DEMO_SEED_EMPTY', '演示数据生成失败：一条记录都没写进去');
      }
      // 目标/徽章按真实规则结算：今天的目标参与结算，历史只刷新进度（见文件头的取舍说明）
      await this.reward.refreshProgress(userId, now);
      await this.reward.settle(userId, now);
      const badges: number = (await this.reward.unlockBadges(userId, now)).length + await this.unlockedCount(userId);
      await this.reward.refreshProgress(userId, now);

      const before: PointBalance = await this.points.balance(userId, now);
      const exchangeCoins: number = DemoService.exchangePlan(before.balance);
      if (exchangeCoins > 0) {
        const exchanged: AppResult<ExchangeOutcome> = await this.include.exchange(userId, exchangeCoins);
        if (!exchanged.ok) {
          // 兑换失败不影响播种成功（余额会略高），但要在报告里能看出来
          await this.cfg.set('demo_exchange_note', exchanged.message === undefined ? 'exchanged failed' : exchanged.message);
        }
      }
      const after: PointBalance = await this.points.balance(userId, now);
      const coin: CarbonCoin = await this.include.coin(userId, now);
      const reduction: number = await this.reductionOf(userId);
      return ok<DemoSeedReport>({
        records: written,
        reductionKg: reduction,
        pointBalance: after.balance,
        coinBalance: coin.balance,
        badges,
        exchangeCoins,
        days: DemoService.DAYS,
      });
    } catch (e) {
      return fail<DemoSeedReport>('DEMO_SEED_FAILED', `演示数据生成失败：${DemoService.messageOf(e)}`);
    }
  }

  /** 清除演示数据（19 张表按 user_id 删除 + 复位开关）。 */
  async clear(): Promise<number> {
    const userId: string = AppConstants.DEMO_USER_ID;
    let removed: number = 0;
    let i: number = 0;
    while (i < ClientSchema.TABLES.length) {
      const table: string = ClientSchema.TABLES[i];
      const hasUser: boolean = DemoService.hasUserColumn(table);
      if (hasUser) {
        const before: RowShape[] = await this.store.query(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`, [userId]);
        const row: RowShape | undefined = firstOf(before);
        if (row !== undefined) {
          removed = removed + numOf(row, 'n');
        }
        await this.store.exec(`DELETE FROM ${table} WHERE user_id = ?`, [userId]);
      }
      i = i + 1;
    }
    await this.state.setDemoMode(false, Date.now());
    await this.cfg.remove('demo_exchange_note');
    return removed;
  }

  /**
   * 生成 90 天时间线（附录 D §9 的频率与分布要求）。
   * @returns 成功写入的记录条数
   */
  private async sow(userId: string, now: number): Promise<number> {
    const rand = new DemoRandom(DemoService.SEED);
    let written: number = 0;
    let d: number = DemoService.DAYS - 1;
    while (d >= 0) {
      const dayStart: number = DateUtil.addDays(now, -d);
      const isToday: boolean = d === 0;
      const items: SeedItem[] = isToday ? DemoService.todayPlan(rand) : DemoService.dayPlan(rand);
      let k: number = 0;
      while (k < items.length) {
        const at: number = dayStart + DemoService.hourOffset(rand);
        const input: SaveRecordInput = {
          category: items[k].category,
          subType: items[k].subType,
          amount: items[k].amount,
          occurredAt: at,
          note: DemoService.noteOf(items[k]),
        };
        const res: AppResult<SaveOutcome> = await this.records.save(userId, input, now, { settleRewards: false });
        if (res.ok) {
          written = written + 1;
        }
        k = k + 1;
      }
      d = d - 1;
    }
    return written;
  }

  /**
   * 某一天的计划（频率取自附录 D §9 表格；数量按「每天约 0.7 kg」缩放后的量级）。
   * 第 `STREAK_START..STREAK_START+31` 天强制至少一条，保证解锁 `B_STREAK_30`。
   */
  private static dayPlan(rand: DemoRandom): SeedItem[] {
    const out: SeedItem[] = [];
    if (rand.next() < 0.8) {
      out.push(DemoService.travelItem(rand));
    }
    const utilCount: number = rand.next() < 0.6 ? 1 : 2;
    let u: number = 0;
    while (u < utilCount) {
      out.push(rand.next() < 0.75 ? DemoService.elecItem(rand) : DemoService.waterItem(rand));
      u = u + 1;
    }
    if (rand.next() < 0.5) {
      out.push(DemoService.recycleItem(rand));
    }
    if (rand.next() < 0.4) {
      out.push({ category: 'plate', subType: 'meal', amount: 1 });
    }
    if (out.length === 0) {
      out.push({ category: 'travel', subType: 'walk', amount: 1.5 });
    }
    return out;
  }

  /**
   * 今天的计划：只做「零碳出行」与「节水」，**故意不做**「省电小标兵」与「光盘卫士」
   * ——附录 D §9 要求「今日目标留 2 项未完成」，便于现场演示完成动作。
   */
  private static todayPlan(rand: DemoRandom): SeedItem[] {
    return [
      DemoService.travelItem(rand),
      { category: 'utility', subType: 'water', amount: 80 },
    ];
  }

  private static travelItem(rand: DemoRandom): SeedItem {
    const r: number = rand.next();
    if (r < 0.3) {
      return { category: 'travel', subType: 'bicycle', amount: 1.5 };
    }
    if (r < 0.5) {
      return { category: 'travel', subType: 'walk', amount: 1.5 };
    }
    if (r < 0.7) {
      return { category: 'travel', subType: 'bus', amount: 2 };
    }
    if (r < 0.85) {
      return { category: 'travel', subType: 'metro', amount: 1.85 };
    }
    return { category: 'travel', subType: 'carpool', amount: 4.2 };
  }

  private static elecItem(rand: DemoRandom): SeedItem {
    return { category: 'utility', subType: 'elec_grid', amount: rand.next() < 0.5 ? 0.26 : 0.35 };
  }

  private static waterItem(rand: DemoRandom): SeedItem {
    return { category: 'utility', subType: 'water', amount: rand.next() < 0.5 ? 90 : 120 };
  }

  private static recycleItem(rand: DemoRandom): SeedItem {
    const r: number = rand.next();
    if (r < 0.5) {
      return { category: 'recycle', subType: 'paper', amount: 0.33 };
    }
    if (r < 0.75) {
      return { category: 'recycle', subType: 'plastic', amount: 0.2 };
    }
    if (r < 0.9) {
      return { category: 'recycle', subType: 'steel', amount: 0.25 };
    }
    return { category: 'recycle', subType: 'aluminum', amount: 0.033 };
  }

  private static noteOf(item: SeedItem): string {
    if (item.category === 'travel') {
      return '通勤';
    }
    if (item.category === 'utility') {
      return '日常生活';
    }
    if (item.category === 'recycle') {
      return '旧物回收';
    }
    return '光盘行动';
  }

  /** 当天 7:00–21:00 之间的确定性时刻。 */
  private static hourOffset(rand: DemoRandom): number {
    const hours: number = 7 + Math.floor(rand.next() * 14);
    const minutes: number = Math.floor(rand.next() * 60);
    return hours * 3600000 + minutes * 60000;
  }

  /**
   * 收尾兑换的碳币数：让**种子后余额**落在 4,820 附近（附录 D §9 的 4000–6000 区间，
   * 同时对齐「我的」页示例值 4,820 与碳币示例 48）。
   */
  static exchangePlan(balanceBefore: number): number {
    const target: number = DemoService.TARGET_BALANCE;
    if (balanceBefore <= target + 100) {
      return 0;
    }
    const coins: number = Math.floor((balanceBefore - target) / AppConstants.CARBON_COIN_RATE);
    if (coins < 1) {
      return 0;
    }
    return coins > DemoService.MAX_COINS ? DemoService.MAX_COINS : coins;
  }

  /** 已解锁徽章数。 */
  private async unlockedCount(userId: string): Promise<number> {
    const rows: RowShape[] = await this.store.query(
      'SELECT COUNT(*) AS n FROM user_badge WHERE user_id = ? AND unlocked = 1',
      [userId]
    );
    const row: RowShape | undefined = firstOf(rows);
    return row === undefined ? 0 : numOf(row, 'n');
  }

  /** 累计减排（逐条重算的 SQL 求和，不用浮点累加）。 */
  private async reductionOf(userId: string): Promise<number> {
    const rows: RowShape[] = await this.store.query(
      'SELECT COALESCE(SUM(reduction_kg), 0) AS kg FROM carbon_record WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    const row: RowShape | undefined = firstOf(rows);
    if (row === undefined) {
      return 0;
    }
    return Dec.from(numOf(row, 'kg')).roundHalfUp(4).toNumber(4);
  }

  /** 该表是否有 `user_id` 列（`app_config` / `device_info` 等静态表没有）。 */
  private static hasUserColumn(table: string): boolean {
    return table !== 'app_config' && table !== 'device_info' && table !== 'carbon_factor_meta' &&
      table !== 'goal_def' && table !== 'badge_def' && table !== 'shop_item' && table !== 'science_article';
  }

  private static messageOf(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return `${e}`;
  }

  /** 覆盖天数（附录 D §9：90 天）。 */
  static readonly DAYS: number = 90;
  /** 随机种子（固定 → 每次播种结果一致，截图可复现）。 */
  static readonly SEED: number = 20261106;
  /** 目标积分余额（附录 D §9 区间内的示例值）。 */
  static readonly TARGET_BALANCE: number = 4820;
  /** 单笔兑换上限（对齐「我的」页示例的 48 碳币）。 */
  static readonly MAX_COINS: number = 48;
}

/** 确定性伪随机（Lehmer，整数乘法在 double 下无精度损失）。 */
class DemoRandom {
  private state: number;

  constructor(seed: number) {
    this.state = seed % 2147483647;
    if (this.state <= 0) {
      this.state = this.state + 2147483646;
    }
  }

  /** [0,1) 之间的下一个数。 */
  next(): number {
    this.state = (this.state * 48271) % 2147483647;
    return this.state / 2147483647;
  }
}
