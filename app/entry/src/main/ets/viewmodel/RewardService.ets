/**
 * RewardService —— 目标进度与徽章解锁的**唯一结算入口**（S3 激励闭环）。
 *
 * 职责：
 *  ① 进度：按 `goal_def.period` 取周期窗口，用窗口内记录算进度，UPSERT 到 `user_goal`
 *     （唯一键 `uq_ug(user_id, goal_id, period_key)`，**progress 可覆盖、settled 永不回退**）；
 *  ② 结算：`settled = 0 且 progress >= threshold` 时发分；
 *     发分 = 写 `point_record(type='goal', source_id='<goalId>:<periodKey>')`，
 *     **以写入是否真的发生为闸门**（`INSERT OR IGNORE` + `uq_pr_source`），成功后才把 `settled` 置 1
 *     —— 这样「一个周期只结算一次」是**数据库层面**的保证，不依赖调用顺序；
 *  ③ 徽章：8 枚按 `badge_def.metric` 判定，UPSERT 到 `user_badge`
 *     （唯一键 `uq_ub(user_id, badge_id)`，`unlocked` 只从 0 → 1，删除记录不撤销）；
 *     徽章**不发分**（附录 C §14 归属声明）。
 *
 * 为什么不把这两种写入合进 RecordService：目标周期跨天跨月，结算时机与「保存一条记录」并不相同
 *（例如首页「换一条」后也可能想刷新进度）；把它们放在 RewardService 里，
 * 记录保存链路只负责「在同一个事务里调它」。
 */
import { GoalDef } from '../model/GoalTypes';
import { BadgeDef, BadgeProgress } from '../model/BadgeTypes';
import { CarbonRecord } from '../model/CarbonTypes';
import { BadgeEngine, BadgeStats } from './domain/BadgeEngine';
import { GoalCard, GoalRowInput, RewardEngine, SettleDecision } from './domain/RewardEngine';
import { PeriodSpan, PeriodWindow } from './domain/PeriodWindow';
import { StorePort, firstOf, numOf, optNumOf, textOf } from './store/StorePort';
import { RowMapper } from './store/RowMapper';
import { PointService } from './PointService';
import { ServerConfig, ServerConfigFetcher } from './net/ServerConfigFetcher';
import { StatsService } from './StatsService';
import { AppState } from './AppState';
import { IdUtil } from './domain/IdUtil';

/** 结算与刷新结果（保存记录后据此排队弹庆祝半模态）。 */
export interface RewardRefresh {
  goals: GoalCard[];
  /** 本次新达成的目标（已发分）。 */
  newGoals: string[];
  badges: BadgeProgress[];
  /** 本次新解锁的徽章。 */
  newBadges: BadgeDef[];
  /** 本次目标奖励分合计。 */
  goalPoints: number;
}

export class RewardService {
  private readonly store: StorePort;
  private readonly points: PointService;
  private readonly stats: StatsService;
  private readonly state: AppState;

  constructor(store: StorePort, points: PointService, stats: StatsService, state: AppState) {
    this.store = store;
    this.points = points;
    this.stats = stats;
    this.state = state;
  }

  /** 目标定义（按 `order`；静态字典由 app-core 播种）。 */
  async goalDefs(): Promise<GoalDef[]> {
    const rows = await this.store.query('SELECT * FROM goal_def ORDER BY "order" ASC', []);
    return RowMapper.goalDefs(rows);
  }

  /** 徽章定义（按 `order`）。 */
  async badgeDefs(): Promise<BadgeDef[]> {
    const rows = await this.store.query('SELECT * FROM badge_def ORDER BY "order" ASC', []);
    return RowMapper.badgeDefs(rows);
  }

  /**
   * 当前生效的后台系统配置（附录 B §5.5 的下行值）。
   *
   * 只影响三个**下行默认值**，不改任何本地真相源（铁律 1）：
   *  ① `badgesEnabled`：自动发徽章的总开关（`false` = 不发**新**徽章）；
   *  ② `goalRewards`：按 `goalId` 覆盖内置 `rawfile/goals/goal-defs.json` 的 reward；
   *  ③ `pointsDailyCap`：每日记录分封顶（由 `PointService.dailyCap()` 消费）。
   * 取不到 / 配置损坏 → `undefined`，各调用点回落到内置语义。
   */
  private async serverConfig(): Promise<ServerConfig | undefined> {
    return ServerConfigFetcher.effectiveFrom(this.store);
  }

  /**
   * 把下行的目标奖励**按 `goalId` 覆盖**到内置定义上（附录 B §5.5 客户端口径第 3 条）。
   *
   * 只改 `reward` 一项：`name` / `threshold` / `period` / `metric` 都是本地口径，服务端不下发、也不许改。
   * 未知 `goalId` 在**写入侧**（`ServerConfigFetcher` 整份校验时）就已被整条剔除，
   * 此处再判一次 `def` 是否存在，做到"未知 id 静默忽略、其余条目照常生效"。
   * @param defs 内置目标定义
   * @param cfg 下行配置（`undefined` = 无覆盖）
   */
  private static withRewardOverride(defs: GoalDef[], cfg: ServerConfig | undefined): GoalDef[] {
    if (cfg === undefined || cfg.goalRewards.length === 0) {
      return defs;
    }
    const rewardOf = new Map<string, number>();
    let k: number = 0;
    while (k < cfg.goalRewards.length) {
      rewardOf.set(cfg.goalRewards[k].goalId, cfg.goalRewards[k].reward);
      k = k + 1;
    }
    const out: GoalDef[] = [];
    let i: number = 0;
    while (i < defs.length) {
      const def: GoalDef = defs[i];
      const reward: number | undefined = rewardOf.get(def.id);
      if (reward === undefined) {
        out.push(def);
      } else {
        // 复制一份再改：`defs` 是每次现读库得到的数组，但仍避免就地改共享引用
        out.push({
          id: def.id,
          name: def.name,
          tier: def.tier,
          period: def.period,
          metric: def.metric,
          category: def.category,
          subTypes: def.subTypes,
          unit: def.unit,
          threshold: def.threshold,
          reward,
          icon: def.icon,
          order: def.order,
        });
      }
      i = i + 1;
    }
    return out;
  }

  /**
   * 重建目标进度（只写 `user_goal`，不结算）。
   * @param userId 用户
   * @param now 当前时刻
   */
  async refreshProgress(userId: string, now: number): Promise<GoalCard[]> {
    const cfg: ServerConfig | undefined = await this.serverConfig();
    const defs: GoalDef[] = RewardService.withRewardOverride(await this.goalDefs(), cfg);
    const registerDayMs: number = await this.state.registerDayMs(userId, now);
    const records: CarbonRecord[] = await this.stats.allRecords(userId);
    const progressMap = new Map<string, number>();
    const settledMap = new Map<string, boolean>();
    let i: number = 0;
    while (i < defs.length) {
      const def: GoalDef = defs[i];
      const span: PeriodSpan = PeriodWindow.of(def.period, now, registerDayMs);
      const scoped: CarbonRecord[] = RewardService.recordsIn(records, span.startMs, span.endMs);
      const progress: number = RewardEngine.progressOf(def, scoped);
      progressMap.set(def.id, progress);
      await this.upsertGoal(userId, def, span.key, progress, now);
      i = i + 1;
    }
    const rows = await this.store.query(
      'SELECT goal_id, period_key, settled FROM user_goal WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    let k: number = 0;
    while (k < rows.length) {
      settledMap.set(`${textOf(rows[k], 'goal_id')}:${textOf(rows[k], 'period_key')}`, numOf(rows[k], 'settled') === 1);
      k = k + 1;
    }
    const spanOf = (def: GoalDef): PeriodSpan => PeriodWindow.of(def.period, now, registerDayMs);
    return RewardEngine.progressRows(defs, progressMap, settledMap, spanOf, now);
  }

  /**
   * 结算当前周期内已达标但未发分的目标（幂等）。
   * @param userId 用户
   * @param now 当前时刻
   */
  async settle(userId: string, now: number): Promise<SettleDecision[]> {
    const cfg: ServerConfig | undefined = await this.serverConfig();
    const defs: GoalDef[] = RewardService.withRewardOverride(await this.goalDefs(), cfg);
    const registerDayMs: number = await this.state.registerDayMs(userId, now);
    const rewardOf = new Map<string, string>();
    const nameOf = new Map<string, string>();
    let i: number = 0;
    while (i < defs.length) {
      rewardOf.set(defs[i].id, `${defs[i].reward}`);
      nameOf.set(defs[i].id, defs[i].name);
      i = i + 1;
    }
    const rows = await this.store.query(
      'SELECT goal_id, period_key, progress, threshold, settled FROM user_goal WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    const inputs: GoalRowInput[] = [];
    let k: number = 0;
    while (k < rows.length) {
      const goalId: string = textOf(rows[k], 'goal_id');
      const rwText: string | undefined = rewardOf.get(goalId);
      inputs.push({
        goalId,
        periodKey: textOf(rows[k], 'period_key'),
        progress: numOf(rows[k], 'progress'),
        threshold: numOf(rows[k], 'threshold'),
        reward: Number.parseInt(rwText === undefined ? '0' : rwText, 10),
        settled: numOf(rows[k], 'settled') === 1,
      });
      k = k + 1;
    }
    // 说明：这里刻意对**所有**未结算行结算（含上期遗留），因为「周期内达标但当时没打开应用」
    // 不应导致奖励丢失；重复结算由 uq_pr_source(source_type,source_id,flow_kind) 挡住。
    const decisions: SettleDecision[] = RewardEngine.decide(inputs);
    const applied: SettleDecision[] = [];
    let d: number = 0;
    while (d < decisions.length) {
      const decision: SettleDecision = decisions[d];
      const nm: string | undefined = nameOf.get(decision.goalId);
      const name: string = nm === undefined ? decision.goalId : nm;
      const written: string = await this.points.append(userId, {
        type: 'goal',
        points: decision.reward,
        sourceType: 'goal',
        sourceId: IdUtil.goalSourceId(decision.goalId, decision.periodKey),
        title: `达成目标「${name}」`,
        remark: '目标奖励不受每日记录上限影响',
        occurredAt: now,
      });
      if (written.length > 0) {
        await this.store.exec(
          'UPDATE user_goal SET settled = 1, settled_at = ?, updated_at = ? WHERE user_id = ? AND goal_id = ? AND period_key = ?',
          [now, now, userId, decision.goalId, decision.periodKey]
        );
        applied.push(decision);
      }
      d = d + 1;
    }
    // 结算写入了 goal 流水，重建当日缓存（与重建共用同一条聚合 SQL，口径天然一致）
    if (applied.length > 0) {
      await this.points.rebuildDailyStat(userId, now);
    }
    return applied;
  }

  /**
   * 刷新徽章进度并解锁达标徽章（幂等；不发分）。
   *
   * `badgesEnabled = false`（后台下发）时**提前返回、什么都不写**：不再自动发放**新**徽章。
   * 按铁律 3/4 与验收 D10-5 的口径，关开关**只影响今后**：
   *  ① 已解锁的 `user_badge` 行一行不动（不删除、不改 `unlocked`/`unlocked_at`）；
   *  ② 不写任何补偿流水、不回写历史 `point_record`；
   *  ③ 只是连"进度推进"也一并停下——因为进度列属于同一张 `user_badge` 表，
   *     若继续 UPDATE 就构成对已有徽章行的写入，与"关闭即冻结"的语义冲突。
   * 徽章墙展示（`badgeRows`）不经过本方法，照旧显示已解锁徽章，所以关开关不会让页面变空。
   * @param userId 用户
   * @param now 当前时刻
   * @returns 本次新解锁的徽章定义；开关关闭时恒为空数组
   */
  async unlockBadges(userId: string, now: number): Promise<BadgeDef[]> {
    const cfg: ServerConfig | undefined = await this.serverConfig();
    if (cfg !== undefined && !cfg.badgesEnabled) {
      return [];
    }
    const defs: BadgeDef[] = await this.badgeDefs();
    const stats: BadgeStats = await this.stats.badgeStats(userId, now);
    const rows = await this.store.query(
      'SELECT badge_id, unlocked, unlocked_at, progress FROM user_badge WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    const unlockedIds: string[] = [];
    const atMap = new Map<string, number>();
    let i: number = 0;
    while (i < rows.length) {
      const id: string = textOf(rows[i], 'badge_id');
      if (numOf(rows[i], 'unlocked') === 1) {
        unlockedIds.push(id);
        const at: number | undefined = optNumOf(rows[i], 'unlocked_at');
        if (at !== undefined) {
          atMap.set(id, at);
        }
      }
      i = i + 1;
    }
    // 本次新达标的徽章必须**同时**进写入判据：`progressRows` 用 `unlockedIds` 决定行的 `unlocked`，
    // 若只传写入前读出的那一份，刚达标的徽章会算出 `unlocked=false` → UPSERT 的
    // `unlocked = MAX(user_badge.unlocked, excluded.unlocked)` 永远是 0（t43 实测：永不落库、
    // 且 `newly` 只被 return 不落盘，于是每次调用都重复报同一枚"新解锁"）。
    const newly: BadgeDef[] = BadgeEngine.evaluate(defs, stats, unlockedIds);
    const nowUnlocked: string[] = unlockedIds.slice();
    let n: number = 0;
    while (n < newly.length) {
      const id: string = newly[n].id;
      nowUnlocked.push(id);
      if (!atMap.has(id)) {
        atMap.set(id, now);
      }
      n = n + 1;
    }
    const progress: BadgeProgress[] = BadgeEngine.progressRows(defs, stats, nowUnlocked, atMap);
    let k: number = 0;
    while (k < progress.length) {
      const p: BadgeProgress = progress[k];
      await this.store.exec(
        'INSERT INTO user_badge (id, user_id, badge_id, unlocked, unlocked_at, progress, created_at, updated_at, is_deleted, device_id, sync_state) ' +
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?) ' +
        'ON CONFLICT(user_id, badge_id) DO UPDATE SET ' +
        'progress = excluded.progress, ' +
        'unlocked = MAX(user_badge.unlocked, excluded.unlocked), ' +
        'unlocked_at = COALESCE(user_badge.unlocked_at, excluded.unlocked_at), ' +
        'updated_at = excluded.updated_at, is_deleted = 0',
        [
          IdUtil.uuid(), userId, p.badgeId, p.unlocked ? 1 : 0, p.unlocked ? now : null, p.progress,
          now, now, this.state.deviceId(), this.state.syncState(),
        ]
      );
      k = k + 1;
    }
    return newly;
  }

  /** 徽章墙展示行（不写库）。 */
  async badgeRows(userId: string, now: number): Promise<BadgeProgress[]> {
    const defs: BadgeDef[] = await this.badgeDefs();
    const stats: BadgeStats = await this.stats.badgeStats(userId, now);
    const rows = await this.store.query(
      'SELECT badge_id, unlocked, unlocked_at FROM user_badge WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    const unlockedIds: string[] = [];
    const atMap = new Map<string, number>();
    let i: number = 0;
    while (i < rows.length) {
      const id: string = textOf(rows[i], 'badge_id');
      if (numOf(rows[i], 'unlocked') === 1) {
        unlockedIds.push(id);
        const at: number | undefined = optNumOf(rows[i], 'unlocked_at');
        if (at !== undefined) {
          atMap.set(id, at);
        }
      }
      i = i + 1;
    }
    return BadgeEngine.progressRows(defs, stats, unlockedIds, atMap);
  }

  /**
   * 保存一条记录之后的一次完整刷新（进度 → 结算 → 徽章），**在保存事务内调用**。
   * @param userId 用户
   * @param now 当前时刻
   */
  async refresh(userId: string, now: number): Promise<RewardRefresh> {
    const goals: GoalCard[] = await this.refreshProgress(userId, now);
    const decisions: SettleDecision[] = await this.settle(userId, now);
    const newGoalIds: string[] = [];
    let goalPoints: number = 0;
    let i: number = 0;
    while (i < decisions.length) {
      newGoalIds.push(decisions[i].goalId);
      goalPoints = goalPoints + decisions[i].reward;
      i = i + 1;
    }
    const after: GoalCard[] = await this.refreshProgress(userId, now);
    const newBadges: BadgeDef[] = await this.unlockBadges(userId, now);
    const badges: BadgeProgress[] = await this.badgeRows(userId, now);
    return { goals: after.length > 0 ? after : goals, newGoals: newGoalIds, badges, newBadges, goalPoints };
  }

  /** 目标页展示行（进页面时把进度重算一遍，保证与账本自洽）。 */
  async goalCards(userId: string, now: number): Promise<GoalCard[]> {
    return this.refreshProgress(userId, now);
  }

  /** UPSERT 一条目标进度（progress 覆盖，settled 保留）。 */
  private async upsertGoal(userId: string, def: GoalDef, periodKey: string, progress: number, now: number): Promise<void> {
    await this.store.exec(
      'INSERT INTO user_goal (id, user_id, goal_id, period_key, progress, threshold, settled, settled_at, created_at, updated_at, is_deleted, device_id, sync_state) ' +
      'VALUES (?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, 0, ?, ?) ' +
      'ON CONFLICT(user_id, goal_id, period_key) DO UPDATE SET ' +
      'progress = excluded.progress, threshold = excluded.threshold, updated_at = excluded.updated_at, is_deleted = 0',
      [IdUtil.uuid(), userId, def.id, periodKey, progress, def.threshold, now, now, this.state.deviceId(), this.state.syncState()]
    );
  }

  private static recordsIn(records: CarbonRecord[], fromMs: number, toMs: number): CarbonRecord[] {
    const out: CarbonRecord[] = [];
    let i: number = 0;
    while (i < records.length) {
      if (records[i].occurredAt >= fromMs && records[i].occurredAt < toMs) {
        out.push(records[i]);
      }
      i = i + 1;
    }
    return out;
  }
}
