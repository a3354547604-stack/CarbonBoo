/**
 * RecordService —— S2 记录闭环的**唯一保存链路**（录入 → 事务落库 → 目标/徽章结算）。
 *
 * 职责：
 *  ① 预览：`preview()` 只算不写，返回录入页要展示的五个数字 + 封顶/异常两条提示；
 *  ② 保存：`save()` 在**一个事务**里完成「碳记录 + 积分流水 + 目标进度与结算 + 徽章解锁」，
 *     任何一步抛错（含开发者选项的「保存强制抛错」）都整笔回滚（验收 C4）；
 *  ③ 编辑：`edit()` 不覆盖旧流水，而是「冲正旧 revision + 写新 revision 的 primary」
 *     （幂等键 `<记录ID>#<revision>`，B3 修复后的口径）；
 *  ④ 删除：软删除 + 冲正，当日封顶额度即刻释放（B2）。
 *
 * 铁律 2 的落点：减排量只能来自 `CarbonService.calculate`。本文件里没有第二处乘法。
 * 页面不得直接调本层——它们经 `RecordEditVM` / `RecordVM` 等 ViewModel 进来。
 */
import { AppResult, fail, ok } from '../model/Result';
import { CarbonRecord, CategoryKey, FactorItem } from '../model/CarbonTypes';
import { CarbonCalculation, CarbonService } from '../service/CarbonService';
import { CarbonCalc, FactorSnapshot } from '../service/CarbonCalc';
import { FactorLibrary } from '../service/FactorLibrary';
import { FactorRepository } from '../service/FactorRepository';
import { BadgeDef } from '../model/BadgeTypes';
import { AppConstants } from '../util/AppConstants';
import { StorePort, firstOf, numOf } from './store/StorePort';
import { RowMapper } from './store/RowMapper';
import { PointService } from './PointService';
import { RewardService } from './RewardService';
import { AppState } from './AppState';
import { IdUtil } from './domain/IdUtil';

/** 因子来源端口（默认走 app-core 的 `FactorRepository`，测试可替换）。 */
export interface FactorSource {
  library(): FactorLibrary | undefined;
}

/** 生产实现：进程内缓存的因子库。 */
export class CachedFactors implements FactorSource {
  library(): FactorLibrary | undefined {
    return FactorRepository.peek();
  }
}

/** 录入 / 编辑的输入。 */
export interface SaveRecordInput {
  category: CategoryKey;
  subType: string;
  amount: number;
  occurredAt: number;
  note?: string;
}

/** 录入页预览（只算不写）。 */
export interface RecordPreview {
  reductionKg: number;
  unit: string;
  factorValue: number;
  factorVersion: string;
  factorSource: string;
  confidence: string;
  factorName: string;
  /** 应得 C。 */
  expectedPoint: number;
  /** 今日已得 D。 */
  todayEarned: number;
  /** 实入 A。 */
  actualPoint: number;
  capped: boolean;
  isAbnormal: boolean;
  cap: number;
  /** 因子缺失（识图/自定义子类越界时）。 */
  factorMissing: boolean;
}

/** 搜索结果（行 + 合计，两处口径一致）。 */
export interface SearchResult {
  records: CarbonRecord[];
  /** 减排合计（kgCO₂e，4 位小数）。 */
  total: number;
  /** 命中总数（可能大于返回行数）。 */
  count: number;
}

/** 保存选项。 */
export interface SaveRecordOptions {
  /**
   * 是否在保存事务内结算目标/徽章（默认 true）。
   * `false` 只用于**演示数据播种**：90 天历史逐日结算会把演示积分推离
   * 附录 D §9 的目标区间（积分余额 4000–6000），而历史目标进度并不需要在播种时逐日重放。
   */
  settleRewards?: boolean;
}

/** 保存结果（页面据此排队弹庆祝半模态）。 */
export interface SaveOutcome {
  recordId: string;
  reductionKg: number;
  pointExpected: number;
  pointAwarded: number;
  capped: boolean;
  isAbnormal: boolean;
  newGoals: string[];
  newBadges: string[];
  goalPoints: number;
}

export class RecordService {
  private readonly store: StorePort;
  private readonly state: AppState;
  private readonly points: PointService;
  private readonly reward: RewardService;
  private readonly factors: FactorSource;

  constructor(store: StorePort, state: AppState, points: PointService, reward: RewardService, factors: FactorSource) {
    this.store = store;
    this.state = state;
    this.points = points;
    this.reward = reward;
    this.factors = factors;
  }

  /**
   * 预览（不写库）。时间或活动量变化时由页面调（节流 200ms 在 ViewModel 里做）。
   * @param userId 用户
   * @param input 录入输入
   * @param now 当前时刻
   */
  async preview(userId: string, input: SaveRecordInput, now: number): Promise<RecordPreview> {
    const item: FactorItem | undefined = this.factorItemOf(input.subType);
    const todayD: number = await this.points.todayRecordPoint(userId, now);
    if (item === undefined) {
      return {
        reductionKg: 0,
        unit: '',
        factorValue: 0,
        factorVersion: '',
        factorSource: '',
        confidence: '',
        factorName: input.subType,
        expectedPoint: 0,
        todayEarned: todayD,
        actualPoint: 0,
        capped: false,
        isAbnormal: false,
        cap: AppConstants.DAILY_RECORD_CAP,
        factorMissing: true,
      };
    }
    const lib: FactorLibrary | undefined = this.factors.library();
    const version: string = lib === undefined ? '' : lib.version();
    const snapshot: FactorSnapshot = CarbonService.snapshotOf(item.value, version, item.source, item.confidence);
    const activity = CarbonService.activityOf({ category: input.category, subType: input.subType, amount: input.amount, occurredAt: input.occurredAt });
    const calc: CarbonCalculation = CarbonService.calculate(activity, snapshot, { todayRecordPoint: todayD });
    return {
      reductionKg: calc.reductionKg,
      unit: item.unit,
      factorValue: item.value,
      factorVersion: version,
      factorSource: item.source,
      confidence: item.confidence,
      factorName: item.name,
      expectedPoint: calc.expectedPoint,
      todayEarned: todayD,
      actualPoint: calc.actualPoint,
      capped: calc.capped,
      isAbnormal: CarbonCalc.isAbnormalInput(input.category, input.subType, input.amount),
      cap: AppConstants.DAILY_RECORD_CAP,
      factorMissing: false,
    };
  }

  /**
   * 保存一条新记录（事务：碳记录 + 积分 + 目标 + 徽章）。
   * @param userId 用户
   * @param input 录入输入
   * @param now 当前时刻
   */
  async save(userId: string, input: SaveRecordInput, now: number, options?: SaveRecordOptions): Promise<AppResult<SaveOutcome>> {
    const guard: AppResult<boolean> | undefined = this.validate(input);
    if (guard !== undefined) {
      return fail<SaveOutcome>(guard.code === undefined ? 'INVALID' : guard.code, guard.message === undefined ? '输入不合法' : guard.message);
    }
    try {
      return await this.store.transaction<AppResult<SaveOutcome>>(async () => this.doSave(userId, input, now, options));
    } catch (e) {
      return fail<SaveOutcome>('SAVE_FAILED', `保存失败：${RecordService.messageOf(e)}`);
    }
  }

  /**
   * 编辑一条记录（冲正旧 revision + 写新 revision）。
   * @param userId 用户
   * @param recordId 记录 id
   * @param input 新输入（发生时间不可改到未来，见页面校验）
   * @param now 当前时刻
   */
  async edit(userId: string, recordId: string, input: SaveRecordInput, now: number): Promise<AppResult<SaveOutcome>> {
    const guard: AppResult<boolean> | undefined = this.validate(input);
    if (guard !== undefined) {
      return fail<SaveOutcome>(guard.code === undefined ? 'INVALID' : guard.code, guard.message === undefined ? '输入不合法' : guard.message);
    }
    try {
      return await this.store.transaction<AppResult<SaveOutcome>>(async () => this.doEdit(userId, recordId, input, now));
    } catch (e) {
      return fail<SaveOutcome>('SAVE_FAILED', `保存失败：${RecordService.messageOf(e)}`);
    }
  }

  /**
   * 删除一条记录（软删除 + 冲正；当日记分额度释放）。
   * @param userId 用户
   * @param recordId 记录 id
   * @param now 当前时刻
   */
  async remove(userId: string, recordId: string, now: number): Promise<AppResult<boolean>> {
    try {
      return await this.store.transaction<AppResult<boolean>>(async () => {
        const record: CarbonRecord | undefined = await this.readRecord(userId, recordId);
        if (record === undefined) {
          return fail<boolean>('NOT_FOUND', '记录不存在或已删除');
        }
        await this.store.exec('UPDATE carbon_record SET is_deleted = 1, updated_at = ?, sync_state = ? WHERE id = ?',
          [now, this.state.syncState(), recordId]);
        await this.reverseOf(userId, record, now);
        return ok(true);
      });
    } catch (e) {
      return fail<boolean>('DELETE_FAILED', `删除失败：${RecordService.messageOf(e)}`);
    }
  }

  /** 单条明细。 */
  async detail(userId: string, recordId: string): Promise<CarbonRecord | undefined> {
    return this.readRecord(userId, recordId);
  }

  /** 记录页分页（可按分类）。 */
  async page(userId: string, category: CategoryKey | 'all', offset: number, size: number): Promise<CarbonRecord[]> {
    const cond: string = category === 'all' ? '' : ' AND category = ?';
    const args: (string | number | null)[] = category === 'all'
      ? [userId, size, offset]
      : [userId, category, size, offset];
    const rows = await this.store.query(
      `SELECT * FROM carbon_record WHERE user_id = ? AND is_deleted = 0${cond} ORDER BY occurred_at DESC, created_at DESC LIMIT ? OFFSET ?`,
      args
    );
    return RowMapper.carbonRecords(rows);
  }

  /**
   * 记录搜索（备注 + 子类；**本地查询，不联网**）。
   * 结果行与合计用**同一组 WHERE 条件**，避免「结果 12 条 · 减排合计 x」两个数对不上。
   * @param userId 用户
   * @param keyword 关键词（备注 / 子类名）
   * @param category 分类（`all` = 全部）
   * @param fromMs 起始（含）
   * @param toMs 结束（不含）
   * @param limit 返回行数上限
   */
  async search(userId: string, keyword: string, category: CategoryKey | 'all', fromMs: number, toMs: number, limit: number): Promise<SearchResult> {
    const like: string = `%${keyword}%`;
    const cond: string = category === 'all' ? '' : ' AND category = ?';
    const base: (string | number | null)[] = category === 'all'
      ? [userId, like, like, fromMs, toMs]
      : [userId, like, like, category, fromMs, toMs];
    const where: string = `WHERE user_id = ? AND is_deleted = 0 AND (note LIKE ? OR sub_type LIKE ?)${cond} AND occurred_at >= ? AND occurred_at < ?`;
    const rows = await this.store.query(`SELECT * FROM carbon_record ${where} ORDER BY occurred_at DESC LIMIT ?`, base.concat([limit]));
    const sumRows = await this.store.query(`SELECT COUNT(*) AS n, COALESCE(SUM(reduction_kg), 0) AS red FROM carbon_record ${where}`, base);
    const srow = firstOf(sumRows);
    return {
      records: RowMapper.carbonRecords(rows),
      total: srow === undefined ? 0 : Math.round(numOf(srow, 'red') * 10000) / 10000,
      count: srow === undefined ? 0 : numOf(srow, 'n'),
    };
  }

  /** 某子类的因子（缺失返回 `undefined`，由页面提示「识图不可用，请手动选择」）。 */
  /**
   * 应得 C（由**已存的减排量**重算，页面不得自己乘 100）。
   * 历史记录只落 `point_awarded`（实入 A），应得 C 由 `reduction_kg` 唯一决定。
   */
  pointExpectedOf(record: CarbonRecord): number {
    return CarbonCalc.expectedPointOf(record.reductionKg);
  }

  factorItemOf(subType: string): FactorItem | undefined {
    const lib: FactorLibrary | undefined = this.factors.library();
    if (lib === undefined) {
      return undefined;
    }
    return lib.factorOf(subType);
  }

  /** 因子库版本（明细页展示因子快照时用）。 */
  factorVersion(): string {
    const lib: FactorLibrary | undefined = this.factors.library();
    return lib === undefined ? '' : lib.version();
  }

  // ---------------------------------------------------------------- 事务体

  private async doSave(userId: string, input: SaveRecordInput, now: number, options?: SaveRecordOptions): Promise<AppResult<SaveOutcome>> {
    const item: FactorItem | undefined = this.factorItemOf(input.subType);
    if (item === undefined) {
      return fail<SaveOutcome>('FACTOR_MISSING', '未找到该行为的因子，请重新选择');
    }
    const lib: FactorLibrary | undefined = this.factors.library();
    const snapshot: FactorSnapshot = CarbonService.snapshotOf(
      item.value,
      lib === undefined ? '' : lib.version(),
      item.source,
      item.confidence,
    );
    const activity = CarbonService.activityOf({
      category: input.category,
      subType: input.subType,
      amount: input.amount,
      occurredAt: input.occurredAt,
    });
    const todayD: number = await this.points.todayRecordPoint(userId, now);
    const calc: CarbonCalculation = CarbonService.calculate(activity, snapshot, { todayRecordPoint: todayD });
    const isAbnormal: number = CarbonCalc.isAbnormalInput(input.category, input.subType, input.amount) ? 1 : 0;
    const id: string = IdUtil.uuid();
    const record: CarbonRecord = CarbonService.buildRecord(
      id, activity, snapshot, calc, item.unit, isAbnormal, input.note, userId, now, this.state.deviceId(),
    );
    await this.insertRecord(record, this.state.syncState(), now);
    await this.writePrimary(userId, record, now);
    RecordService.breakIfDev(this.state);
    if (options !== undefined && options.settleRewards === false) {
      return ok<SaveOutcome>({
        recordId: id,
        reductionKg: record.reductionKg,
        pointExpected: calc.expectedPoint,
        pointAwarded: calc.actualPoint,
        capped: calc.capped,
        isAbnormal: isAbnormal === 1,
        newGoals: [],
        newBadges: [],
        goalPoints: 0,
      });
    }
    const refreshed = await this.reward.refresh(userId, now);
    return ok<SaveOutcome>({
      recordId: id,
      reductionKg: record.reductionKg,
      pointExpected: calc.expectedPoint,
      pointAwarded: calc.actualPoint,
      capped: calc.capped,
      isAbnormal: isAbnormal === 1,
      newGoals: refreshed.newGoals,
      newBadges: RecordService.badgeNames(refreshed.newBadges),
      goalPoints: refreshed.goalPoints,
    });
  }

  private async doEdit(userId: string, recordId: string, input: SaveRecordInput, now: number): Promise<AppResult<SaveOutcome>> {
    const old: CarbonRecord | undefined = await this.readRecord(userId, recordId);
    if (old === undefined) {
      return fail<SaveOutcome>('NOT_FOUND', '记录不存在或已删除');
    }
    // 先冲正旧 revision 的入账（旧流水一条不改）
    await this.reverseOf(userId, old, now);
    const item: FactorItem | undefined = this.factorItemOf(input.subType);
    if (item === undefined) {
      return fail<SaveOutcome>('FACTOR_MISSING', '未找到该行为的因子，请重新选择');
    }
    const lib: FactorLibrary | undefined = this.factors.library();
    const snapshot: FactorSnapshot = CarbonService.snapshotOf(
      item.value, lib === undefined ? '' : lib.version(), item.source, item.confidence,
    );
    const activity = CarbonService.activityOf({
      category: input.category, subType: input.subType, amount: input.amount, occurredAt: input.occurredAt,
    });
    // 冲正已把旧额度退回，故此处重新取当日已得
    const todayD: number = await this.points.todayRecordPoint(userId, now);
    const calc: CarbonCalculation = CarbonService.calculate(activity, snapshot, { todayRecordPoint: todayD });
    const revision: number = old.revision + 1;
    const isAbnormal: number = CarbonCalc.isAbnormalInput(input.category, input.subType, input.amount) ? 1 : 0;
    await this.store.exec(
      'UPDATE carbon_record SET category = ?, sub_type = ?, amount = ?, unit = ?, occurred_at = ?, reduction_kg = ?, ' +
      'factor_value = ?, factor_version = ?, factor_source = ?, confidence = ?, point_awarded = ?, point_capped = ?, ' +
      'revision = ?, is_abnormal = ?, note = ?, updated_at = ?, sync_state = ? WHERE id = ?',
      [
        input.category, input.subType, input.amount, item.unit, input.occurredAt, calc.reductionKg,
        item.value, lib === undefined ? '' : lib.version(), item.source, item.confidence,
        calc.actualPoint, calc.capped ? 1 : 0, revision, isAbnormal,
        input.note === undefined ? null : input.note, now, this.state.syncState(), recordId,
      ]
    );
    const edited: CarbonRecord = {
      id: recordId, userId, category: input.category, subType: input.subType, amount: input.amount, unit: item.unit,
      occurredAt: input.occurredAt, reductionKg: calc.reductionKg, factorValue: item.value,
      factorVersion: lib === undefined ? '' : lib.version(), factorSource: item.source,
      confidence: CarbonService.toConfidence(item.confidence), pointAwarded: calc.actualPoint, revision,
      pointCapped: calc.capped ? 1 : 0, isAbnormal, createdAt: old.createdAt, updatedAt: now, isDeleted: 0,
      deviceId: this.state.deviceId(), syncState: old.syncState,
    };
    if (input.note !== undefined) {
      edited.note = input.note;
    }
    await this.writePrimary(userId, edited, now);
    RecordService.breakIfDev(this.state);
    const refreshed = await this.reward.refresh(userId, now);
    return ok<SaveOutcome>({
      recordId,
      reductionKg: calc.reductionKg,
      pointExpected: calc.expectedPoint,
      pointAwarded: calc.actualPoint,
      capped: calc.capped,
      isAbnormal: isAbnormal === 1,
      newGoals: refreshed.newGoals,
      newBadges: RecordService.badgeNames(refreshed.newBadges),
      goalPoints: refreshed.goalPoints,
    });
  }

  // ---------------------------------------------------------------- 内部

  /** 写一条记录类 primary 流水（幂等键 `<id>#<revision>`）。 */
  private async writePrimary(userId: string, record: CarbonRecord, now: number): Promise<void> {
    const shouldWrite: boolean = record.pointAwarded > 0 || (record.pointCapped === 1 && record.reductionKg > 0);
    if (!shouldWrite) {
      return;
    }
    const capped: boolean = record.pointCapped === 1;
    await this.points.append(userId, {
      type: capped ? 'record_capped' : 'record',
      points: record.pointAwarded,
      sourceType: 'carbon_record',
      sourceId: IdUtil.recordSourceId(record.id, record.revision),
      title: CarbonService.titleOf(record.category, record.subType, record.amount, record.unit),
      remark: capped ? `本笔受每日记录上限影响，实入 ${record.pointAwarded} 分` : undefined,
      occurredAt: record.occurredAt,
    });
  }

  /** 冲正一条记录的入账（按 revision 找到对应 primary 的金额）。 */
  private async reverseOf(userId: string, record: CarbonRecord, now: number): Promise<void> {
    await this.points.reverse(
      userId,
      record.pointCapped === 1 ? 'record_capped' : 'record',
      record.pointAwarded,
      IdUtil.recordSourceId(record.id, record.revision),
      CarbonService.titleOf(record.category, record.subType, record.amount, record.unit),
      record.occurredAt,
    );
  }

  /** 插入碳记录（22 列全写：因子快照四字段一个不少，铁律 3）。 */
  private async insertRecord(record: CarbonRecord, syncState: string, now: number): Promise<void> {
    await this.store.exec(
      'INSERT OR IGNORE INTO carbon_record (id, user_id, category, sub_type, amount, unit, occurred_at, reduction_kg, ' +
      'factor_value, factor_version, factor_source, confidence, point_awarded, point_capped, revision, is_abnormal, note, ' +
      'created_at, updated_at, is_deleted, device_id, sync_state) ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)',
      [
        record.id, record.userId, record.category, record.subType, record.amount, record.unit, record.occurredAt,
        record.reductionKg, record.factorValue, record.factorVersion, record.factorSource, record.confidence,
        record.pointAwarded, record.pointCapped, record.revision, record.isAbnormal,
        record.note === undefined ? null : record.note, now, now, this.state.deviceId(), syncState,
      ]
    );
  }

  private async readRecord(userId: string, recordId: string): Promise<CarbonRecord | undefined> {
    const rows = await this.store.query('SELECT * FROM carbon_record WHERE id = ? AND user_id = ? AND is_deleted = 0', [recordId, userId]);
    const row = firstOf(rows);
    return row === undefined ? undefined : RowMapper.carbonRecord(row);
  }

  /** 输入校验（前端先拦，Service 再拦一次）。 */
  private validate(input: SaveRecordInput): AppResult<boolean> | undefined {
    if (!Number.isFinite(input.amount) || input.amount <= 0) {
      return fail<boolean>('INVALID_AMOUNT', '活动量必须大于 0');
    }
    if (input.amount > 1000000) {
      return fail<boolean>('INVALID_AMOUNT', '活动量超出可记录范围');
    }
    if (input.subType.length === 0) {
      return fail<boolean>('INVALID_SUBTYPE', '请选择低碳行为');
    }
    return undefined;
  }

  /** 开发者选项：在事务内主动抛错（验收 C4/C5 的取证开关）。 */
  private static breakIfDev(state: AppState): void {
    if (state.dev().breakSave) {
      throw new Error('开发者选项：保存强制抛错（用于验收 C4/C5）');
    }
  }

  private static badgeNames(badges: BadgeDef[]): string[] {
    const out: string[] = [];
    let i: number = 0;
    while (i < badges.length) {
      out.push(badges[i].name);
      i = i + 1;
    }
    return out;
  }

  private static messageOf(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return `${e}`;
  }
}
