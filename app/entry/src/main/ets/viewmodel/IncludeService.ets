/**
 * IncludeService —— 碳普惠（**模拟演示**，S7）：积分 → 碳币、碳币 → 权益。
 *
 * 职责：
 *  ① 碳币余额 = `SUM(exchange.coin_amount) − SUM(redeem.coin_amount)`（从 `carbon_include` 现算）；
 *  ② 可兑碳币 = `floor(积分余额 / 100)`（汇率 `AppConstants.CARBON_COIN_RATE`）；
 *  ③ 兑换（积分 → 碳币）：一个事务写 `point_record(carbon_include, −n)` + `carbon_include(exchange)`；
 *  ④ 权益兑换（碳币 → 权益）：一个事务写 `carbon_include(redeem)`；
 *     这是**单表写入**，不产生积分流水（碳币不是积分，铁律 4 只管积分）。
 *  ⑤ 权益清单来自 `app_config['benefits']`（app-core 从 `rawfile/include/benefits.json` 播种）。
 *
 * 合规（附录 C §19 规则 6 / 验收 D7）：所有权益名自带「模拟」前缀，
 * 页面顶部常驻提示条由 `SimulationBanner` 承担，本层不生成任何「可提现」表述。
 * 单向不可逆：本层**没有**碳币回兑积分的路径。
 */
import { CarbonCoin, CarbonIncludeRecord, IncludeBenefit } from '../model/IncludeTypes';
import { StorePort, firstOf, numOf, textOf } from './store/StorePort';
import { RowMapper } from './store/RowMapper';
import { PointService } from './PointService';
import { AppState } from './AppState';
import { IdUtil } from './domain/IdUtil';
import { AppConstants } from '../util/AppConstants';
import { JsonArray, asArray, asObject, optNum, optStr } from '../util/JsonUtil';
import { AppResult, fail, ok } from '../model/Result';

/** 一次兑换的结果。 */
export interface ExchangeOutcome {
  pointsSpent: number;
  coinGained: number;
  coinBalance: number;
}

/** 一次权益兑换的结果。 */
export interface RedeemOutcome {
  benefitId: string;
  benefitName: string;
  coinSpent: number;
  coinBalance: number;
}

export class IncludeService {
  private readonly store: StorePort;
  private readonly state: AppState;
  private readonly points: PointService;

  constructor(store: StorePort, state: AppState, points: PointService) {
    this.store = store;
    this.state = state;
    this.points = points;
  }

  /** 碳币总览（碳普惠页顶部卡）。 */
  async coin(userId: string, now: number): Promise<CarbonCoin> {
    const rows = await this.store.query(
      "SELECT COALESCE(SUM(CASE WHEN action = 'exchange' THEN coin_amount ELSE 0 END), 0) AS ex, " +
      "COALESCE(SUM(CASE WHEN action = 'redeem' THEN coin_amount ELSE 0 END), 0) AS rd " +
      'FROM carbon_include WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    const row = firstOf(rows);
    const exchanged: number = row === undefined ? 0 : numOf(row, 'ex');
    const spent: number = row === undefined ? 0 : numOf(row, 'rd');
    const balance = await this.points.balance(userId, now);
    return {
      balance: exchanged - spent,
      totalExchanged: exchanged,
      totalSpent: spent,
      exchangeable: Math.floor(balance.balance / AppConstants.CARBON_COIN_RATE),
    };
  }

  /** 可兑换权益（`app_config['benefits']`；顺序即字典顺序）。 */
  async benefits(): Promise<IncludeBenefit[]> {
    const rows = await this.store.query("SELECT value FROM app_config WHERE id = 'benefits'", []);
    const row = firstOf(rows);
    if (row === undefined) {
      return [];
    }
    const text: string = textOf(row, 'value');
    if (text.length === 0) {
      return [];
    }
    try {
      const arr: JsonArray = asArray(JSON.parse(text), 'benefits');
      const out: IncludeBenefit[] = [];
      let i: number = 0;
      while (i < arr.length) {
        const o = asObject(arr[i], `benefits[${i}]`);
        const id: string | undefined = optStr(o, 'id');
        const name: string | undefined = optStr(o, 'name');
        const desc: string | undefined = optStr(o, 'description');
        const cost: number | undefined = optNum(o, 'coinCost');
        const icon: string | undefined = optStr(o, 'icon');
        if (id !== undefined && name !== undefined) {
          out.push({
            id,
            name,
            description: desc === undefined ? '' : desc,
            coinCost: cost === undefined ? 0 : cost,
            icon: icon === undefined ? '' : icon,
          });
        }
        i = i + 1;
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /**
   * 积分 → 碳币（正整数、余额足够；事务写流水 + 兑换记录）。
   * @param userId 用户
   * @param coinCount 兑换碳币数
   */
  async exchange(userId: string, coinCount: number): Promise<AppResult<ExchangeOutcome>> {
    if (!Number.isInteger(coinCount) || coinCount <= 0) {
      return fail<ExchangeOutcome>('INVALID_COUNT', '兑换数量必须是正整数');
    }
    const cost: number = coinCount * AppConstants.CARBON_COIN_RATE;
    const now: number = Date.now();
    const balance = await this.points.balance(userId, now);
    if (balance.balance < cost) {
      return fail<ExchangeOutcome>('NOT_ENOUGH_POINTS', `积分不足，还差 ${cost - balance.balance} 分`);
    }
    try {
      return await this.store.transaction<AppResult<ExchangeOutcome>>(async () => {
        const recordId: string = IdUtil.uuid();
        const written: string = await this.points.append(userId, {
          type: 'carbon_include',
          points: -cost,
          sourceType: 'carbon_include',
          sourceId: recordId,
          title: `兑换 ${coinCount} 碳币（模拟）`,
          remark: '碳普惠模拟演示，不对接真实平台',
          occurredAt: now,
        });
        if (written.length === 0) {
          throw new Error('兑换流水未写入');
        }
        await this.store.exec(
          'INSERT INTO carbon_include (id, user_id, action, points_spent, coin_amount, benefit_id, benefit_name, occurred_at, created_at, updated_at, is_deleted, device_id, sync_state) ' +
          "VALUES (?, ?, 'exchange', ?, ?, NULL, NULL, ?, ?, ?, 0, ?, ?)",
          [recordId, userId, cost, coinCount, now, now, now, this.state.deviceId(), this.state.syncState()]
        );
        const after = await this.coin(userId, now);
        return ok<ExchangeOutcome>({ pointsSpent: cost, coinGained: coinCount, coinBalance: after.balance });
      });
    } catch (e) {
      return fail<ExchangeOutcome>('EXCHANGE_FAILED', `兑换失败：${IncludeService.messageOf(e)}`);
    }
  }

  /**
   * 碳币 → 权益（模拟）。
   * @param userId 用户
   * @param benefitId 权益 id
   */
  async redeem(userId: string, benefitId: string): Promise<AppResult<RedeemOutcome>> {
    const all: IncludeBenefit[] = await this.benefits();
    let target: IncludeBenefit | undefined = undefined;
    let i: number = 0;
    while (i < all.length) {
      if (all[i].id === benefitId) {
        target = all[i];
        break;
      }
      i = i + 1;
    }
    if (target === undefined) {
      return fail<RedeemOutcome>('BENEFIT_MISSING', '权益不存在');
    }
    const now: number = Date.now();
    const coin: CarbonCoin = await this.coin(userId, now);
    if (coin.balance < target.coinCost) {
      return fail<RedeemOutcome>('NOT_ENOUGH_COIN', `碳币不足，还差 ${target.coinCost - coin.balance} 碳币`);
    }
    const name: string = target.name;
    const cost: number = target.coinCost;
    try {
      return await this.store.transaction<AppResult<RedeemOutcome>>(async () => {
        await this.store.exec(
          'INSERT INTO carbon_include (id, user_id, action, points_spent, coin_amount, benefit_id, benefit_name, occurred_at, created_at, updated_at, is_deleted, device_id, sync_state) ' +
          "VALUES (?, ?, 'redeem', 0, ?, ?, ?, ?, ?, ?, 0, ?, ?)",
          [IdUtil.uuid(), userId, cost, benefitId, name, now, now, now, this.state.deviceId(), this.state.syncState()]
        );
        const after: CarbonCoin = await this.coin(userId, now);
        return ok<RedeemOutcome>({ benefitId, benefitName: name, coinSpent: cost, coinBalance: after.balance });
      });
    } catch (e) {
      return fail<RedeemOutcome>('REDEEM_FAILED', `兑换失败：${IncludeService.messageOf(e)}`);
    }
  }

  /** 兑换记录（时间倒序）。 */
  async records(userId: string, limit: number): Promise<CarbonIncludeRecord[]> {
    const rows = await this.store.query(
      'SELECT * FROM carbon_include WHERE user_id = ? AND is_deleted = 0 ORDER BY occurred_at DESC LIMIT ?',
      [userId, limit]
    );
    return RowMapper.includeRecords(rows);
  }

  /** 某权益是否已兑换过（用于展示「已兑换」）。 */
  async hasRedeemed(userId: string, benefitId: string): Promise<boolean> {
    const rows = await this.store.query(
      "SELECT COUNT(*) AS n FROM carbon_include WHERE user_id = ? AND benefit_id = ? AND action = 'redeem' AND is_deleted = 0",
      [userId, benefitId]
    );
    const row = firstOf(rows);
    return row !== undefined && numOf(row, 'n') > 0;
  }

  private static messageOf(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return `${e}`;
  }
}
