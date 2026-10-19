/**
 * SyncService —— 账号与云端同步 / 云端备份 / 家庭合并 / 近场演示层（S6 的客户端一侧）。
 *
 * 职责：
 *  ① **待同步数**：参与同步的 9 张表（`ClientSchema.SYNCED_TABLES`）里 `sync_state='pending'` 的行数之和
 *     （附录 C §18.1、验收 D6-6 的唯一口径）；
 *  ② **增量同步**：`POST /api/v1/sync/push` 推送增量 → `GET /api/v1/sync/pull?since=` 拉取增量 →
 *     按附录 B §6 的 LWW 应用：`updated_at` 大者胜；**相等时按 `deviceId` 字典序大者胜**
 *     （`deviceId` 也相同 = 同一版本，保留本机）；对端时间戳先按 `offsetMs` 换算到本机基准；
 *     「真冲突」仅当两端自上次同步后都改过这一行（§6.3）；
 *     合并前先**认领本机行**（`RowClaim`）：单例表按 `user_id`、有业务键的表按 `(user_id, 业务键)`、
 *     其余按 `id`（与服务端 `_find_business_key_row` 同规则，t62 的 F1 修复）；覆盖时删的是
 *     **本机那一行的 `id`**；`INSERT OR IGNORE` 兜底，被丢弃的计 `skipped`（不计 `written`/`conflicts`）；
 *     `append_only` 表（`point_record`/`carbon_include`）**只去重、永不 UPDATE**（`SYNC_MODES`，
 *     与服务端 `_merge_append_only` 同规则，t62 的 F3 修复）；
 *     时钟偏移取自 **push 响应**（§5.3:855：pull 不带 `offsetMs`），取反后用于本次合并（t62 的 F2 修复）；
 *  ③ **未登录时一行都不发**：`sync()`/`fullUpload()`/`fullRestore()` 第一件事就是判登录态，
 *     未登录直接返回失败，**不会**创建任何 HTTP 请求（验收 D6 的「未登录态不发起任何上传请求」
 *     靠 `FakeHttpClient.count()` 断言）；
 *  ④ **云端备份 / 恢复 = 独立三端点**（附录 B §5.3:807/817-819）：`POST /sync/backup` 上传快照、
 *     `GET /sync/backup` 下载快照、`POST /sync/backup/restore` **覆盖式**恢复。
 *     只存快照，**不做 LWW 比较、不算冲突、不用 `lastSyncAt`**；恢复前把响应 `preRestore`
 *     （+ `preRestoreAt`）落盘（服务端不建表，由调用方保存，见 PLAN §7.8）。
 *     ⚠️ 这两条链路**语义不同、不可互相替代**：备份是"快照/覆盖"，增量同步是"合并"。
 *  ⑤ **家庭合并（只读）**：按 `device_id` 分组求和，口径「同一账号下多设备只读汇总，不合并账本、不改写流水」；
 *     两条 SQL 一律 `SUM(points)`（**不再**按 `flow_kind` 二次取负）—— `point_record.points` 本身
 *     已是带符号的（`PointService.reverse()` 落库即负额，见附录 B §2 与 PLAN §9.5），再取一次负会把
 *     冲正行翻正、让合计虚高 `2 × Σ|reverse|`（round 1 验证 F1：primary 200 + reverse 30 实测 230，应为 170）；
 *  ⑥ **近场演示层**：同一 Wi-Fi 的双机演示（创新项 Ⅰ），**不承担跨设备一致性**；
 *     本机没有分布式数据服务栈时给出空态「未发现已配对设备」，不编造设备；
 *  ⑦ 每次操作写一行 `sync_log`（成功/失败、拉取数、上传数、冲突数、错误原因）；
 *     增量同步失败时**不更新** `last_sync_at`（附录 C §18.1 规则），备份路径则从不读写它。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DevicePeer, SyncSessionState } from '../../model/SyncTypes';
import { ClientSchema } from '../../data/schema/ClientSchema';
import { StorePort, RowShape, SqlValue, firstOf, numOf, textOf } from '../store/StorePort';
import { RowMapper, SyncLogRow } from '../store/RowMapper';
import { AppConfig, ConfigKeys } from '../AppConfig';
import { AppState } from '../AppState';
import { HttpMethod, HttpPort, HttpResponse, HTTP_TIMEOUT_MS } from './HttpPort';
import { IdUtil } from '../domain/IdUtil';
import { JsonArray, JsonObject, asArray, asObject, num, optNum, optStr } from '../../util/JsonUtil';
import { AppResult, fail, ok } from '../../model/Result';

/** 协同页顶部卡片的数据（附录 C §18.1）。 */
export interface SyncStatus {
  loggedIn: boolean;
  /** 展示用账号名（未登录为空串）。 */
  userLabel: string;
  /** 待同步条数（9 张表 `pending` 之和）。 */
  pending: number;
  /** 最后同步时间（毫秒；0 = 从未同步）。 */
  lastSyncAt: number;
  /** 最近一次同步的冲突数。 */
  conflictCount: number;
  /** 本机设备 id。 */
  deviceId: string;
  /** 已知的其他设备数（`device_info` 里 `is_self = 0` 的行数）。 */
  peerCount: number;
}

/** 家庭成员（一台设备）的只读汇总。 */
export interface FamilyMember {
  deviceId: string;
  label: string;
  reductionKg: number;
  points: number;
}

/** 家庭碳积分合并视图（只读）。 */
export interface FamilySummary {
  members: FamilyMember[];
  totalReductionKg: number;
  totalPoints: number;
}

/** 一次同步的结果。 */
export interface SyncOutcome {
  accepted: number;
  skipped: number;
  conflicts: number;
  pulled: number;
  serverTime: number;
}

/**
 * 一次 LWW 裁决的结果（替代原来的 `1/0/-1` 三态数字）。
 *
 * 为什么要换成显式类型：原来的返回值把**两件独立的事**混在一起 ——
 * 「动作」（写入 / 保留本机）与「是否真冲突」。于是 `applyPull` 只能用
 * `outcome === 0` 当冲突计数，导致：
 *   · 平局跳过（动作=跳过）被当成"冲突"；
 *   · 对端更新后写入（动作=写入）反而不计冲突；
 *   · `since` 形参被完全忽略 → `conflicts` 事实上恒为 0。
 * 按 §6.3「真冲突 = 两端自上次同步后都改过这一行」拆开后，两者可独立判定。
 */
export class LwwDecision {
  /** `written` = 写了远端；`kept` = 保留本机；`skipped` = 未处理（如缺 id）。 */
  readonly action: string;
  /** 是否满足 §6.3 的「真冲突」条件（与动作无关）。 */
  readonly conflict: boolean;

  constructor(action: string, conflict: boolean) {
    this.action = action;
    this.conflict = conflict;
  }
}

/** 日志域与 TAG（`hilog` 需要）。 */
const DOMAIN: number = 0x0001;
const TAG: string = 'CarbonBooSync';

/**
 * `app_config` 里存"恢复前云端原状"的键（`preRestore` + `preRestoreAt` 的 JSON）。
 *
 * 为什么不加进 `AppConfig.ConfigKeys`：本任务的 inScope 只含本文件与一个测试文件
 * （`AppConfig.ets` 不在写入范围）。它属**本 Service 私有**的实现细节 ——
 * 只有本文件写、也只有本文件（及其用例）读，不进公共键表反而更内聚。
 * 依据：附录 B §5.3:819「覆盖前原状随响应 `preRestore`（+ `preRestoreAt`）返回」，
 * 且「服务端**不新建表**、由调用方保存」（PLAN §7.8）。
 */
const KEY_PRE_RESTORE: string = 'cloud_pre_restore';

/**
 * 合并模式（`SYNC_MODES` 的取值）。
 *
 * 与服务端 `server/app/services/sync_service.py:54-55` 同名同值 ——
 * 「两端用同一规则，结论一致」（附录 B §6.4-6）要求模式表逐字对应，不许各自发明。
 */
export const MODE_APPEND_ONLY: string = 'append_only';
export const MODE_LWW: string = 'lww';

/**
 * 表 → 合并模式（**逐字对应** `server/app/services/sync_service.py:58-70`，键名与顺序一致）。
 *
 *  - `append_only`（只增账本 `point_record` / `carbon_include`）：同 id 或同业务唯一键即**去重丢弃**，
 *    **永不 UPDATE**（铁律 4「流水只增不删」）—— 对应服务端 `_merge_append_only`；
 *  - `lww`：完整 LWW（`updated_at` 大者胜，平局按 `deviceId`，见 `applyRow`）。
 *
 * 为什么必须显式登记：客户端原来的合并路径**对 9 张表一视同仁**地走 LWW，于是
 * `point_record` 这种只增表在「两端各自真实编辑过同一记录」时会被 UPDATE（或重复插入），
 * 与服务端口径分叉 —— t62 修复的 F3 即此。
 */
export const SYNC_MODES: Record<string, string> = {
  'point_record': MODE_APPEND_ONLY,
  'carbon_include': MODE_APPEND_ONLY,
  'carbon_record': MODE_LWW,
  'user_goal': MODE_LWW,
  'user_badge': MODE_LWW,
  'user_purchase': MODE_LWW,
  'user_appearance': MODE_LWW,
  'science_progress': MODE_LWW,
  'user_profile': MODE_LWW,
};

/**
 * 业务唯一键（**不含** `user_id`；判定时一律与 `user_id` 组合）。
 * **逐字对应** `server/app/services/sync_service.py:74-84`（键名与顺序一致）。
 *
 * 空数组 = 该表除主键 `id` 外没有业务唯一键；键值缺任意一个即**不判重、退回按 `id`**
 * （服务端 `_find_business_key_row:237-240` 同规则）。
 */
export const BUSINESS_KEYS: Record<string, string[]> = {
  'point_record': ['source_type', 'source_id', 'flow_kind'],
  'user_goal': ['goal_id', 'period_key'],
  'user_badge': ['badge_id'],
  'user_purchase': ['item_id'],
  'science_progress': ['article_id'],
  'carbon_record': [],
  'carbon_include': [],
  'user_appearance': [],
  'user_profile': [],
};

/** 每个 `user_id` 恒一行的单例表（`uq_ua` / `uq_uprofile`）—— 逐字对应服务端 `:87`。 */
export const SINGLETON_TABLES: string[] = ['user_appearance', 'user_profile'];

/**
 * 认领「本机已有行」的唯一键（附录 B §6.3：先认领本机行，再按 LWW 裁决要不要覆盖它）。
 *
 * 为什么不能只按 `id` 认领（t62 的 F1，blocker）：两台设备各自全新安装时，
 * `AppState.ensureUser()` 会给**同一个 `user_id`** 各生成一行 `user_profile` /
 * `user_appearance`，两行的 `id` 是**不同**的 UUID（B35 契约）。只按 `id` 认领时，
 * 第二台设备 pull 到的单例行在本地「查不到」→ 裸 INSERT → 撞 `uq_uprofile`/`uq_ua`
 * **抛错**，「两台设备首次协同」直接失败。故必须与服务端同规则按业务键认领。
 *
 * 认领顺序（与服务端 `sync_service.py:223-243` 逐字同规则）：
 *  ① 单例表（`user_appearance` / `user_profile`）→ `user_id`；
 *  ② 有业务唯一键的表且**键值齐全** → `(user_id, 业务键…)`；
 *  ③ 其余（无业务键、或业务键值缺失、或缺 `user_id` 的畸形行）→ `id`。
 *
 * `SELECT` 的列固定为 `id, updated_at, device_id`：`updated_at`/`device_id` 供 LWW 与
 * 平局裁决使用，`id` 是覆盖时 `DELETE` 的**依据**（认领到的本机行 id 可能与远端 id 不同）。
 */
export class RowClaim {
  readonly sql: string;
  readonly args: SqlValue[];

  constructor(sql: string, args: SqlValue[]) {
    this.sql = sql;
    this.args = args;
  }

  static of(table: string, row: RowShape): RowClaim {
    const userId: string = textOf(row, 'user_id');
    if (userId.length > 0 && SINGLETON_TABLES.indexOf(table) >= 0) {
      return new RowClaim(`SELECT id, updated_at, device_id FROM ${table} WHERE user_id = ?`, [userId]);
    }
    const keys: string[] | undefined = userId.length > 0 ? BUSINESS_KEYS[table] : undefined;
    if (keys !== undefined && keys.length > 0) {
      const args: SqlValue[] = [userId];
      const conds: string[] = [];
      let missing: boolean = false;
      let i: number = 0;
      while (i < keys.length) {
        const v: SqlValue | undefined = row[keys[i]];
        if (v === undefined || v === null) {
          missing = true;                      // 缺键值就不判重（服务端 :237-240 同规则）
        }
        conds.push(`${keys[i]} = ?`);
        args.push(v === undefined ? null : v);
        i = i + 1;
      }
      if (!missing) {
        return new RowClaim(
          `SELECT id, updated_at, device_id FROM ${table} WHERE user_id = ? AND ${conds.join(' AND ')}`, args);
      }
    }
    return new RowClaim(`SELECT id, updated_at, device_id FROM ${table} WHERE id = ?`, [textOf(row, 'id')]);
  }
}

export class SyncService {
  private readonly store: StorePort;
  private readonly state: AppState;
  private readonly http: HttpPort;
  private readonly cfg: AppConfig;

  constructor(store: StorePort, state: AppState, http: HttpPort, cfg: AppConfig) {
    this.store = store;
    this.state = state;
    this.http = http;
    this.cfg = cfg;
  }

  /** 待同步条数（附录 C §18.1 / 验收 D6-6）。 */
  async pendingCount(userId: string): Promise<number> {
    let total: number = 0;
    let i: number = 0;
    while (i < ClientSchema.SYNCED_TABLES.length) {
      const table: string = ClientSchema.SYNCED_TABLES[i];
      const rows: RowShape[] = await this.store.query(
        `SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ? AND sync_state = 'pending'`,
        [userId]
      );
      const row: RowShape | undefined = firstOf(rows);
      if (row !== undefined) {
        total = total + numOf(row, 'n');
      }
      i = i + 1;
    }
    return total;
  }

  /** 协同页卡片数据。 */
  async status(userId: string): Promise<SyncStatus> {
    const pending: number = await this.pendingCount(userId);
    const lastSyncAt: number = await this.cfg.stamp(ConfigKeys.LAST_SYNC_AT);
    const logs: SyncLogRow[] = await this.logs(userId, 1);
    const conflictCount: number = logs.length === 0 ? 0 : logs[0].conflictCount;
    const peers: RowShape[] = await this.store.query('SELECT COUNT(*) AS n FROM device_info WHERE is_self = 0', []);
    const peerRow: RowShape | undefined = firstOf(peers);
    return {
      loggedIn: this.state.isLoggedIn(),
      userLabel: this.state.loginName(),
      pending,
      lastSyncAt,
      conflictCount,
      deviceId: this.state.deviceId(),
      peerCount: peerRow === undefined ? 0 : numOf(peerRow, 'n'),
    };
  }

  /**
   * 立即同步（云端主通路）。
   * **未登录直接返回失败，且不发起任何请求**（铁律 1）。
   */
  async sync(userId: string, now: number): Promise<AppResult<SyncOutcome>> {
    if (!this.state.isLoggedIn()) {
      return fail<SyncOutcome>('NOT_LOGGED_IN', '未登录，未发起任何上传（本机数据不受影响）');
    }
    const t0: number = now;
    const since: number = await this.cfg.stamp(ConfigKeys.LAST_SYNC_AT);
    const token: string = await this.authToken();
    const payload: string = await this.pushBody(userId, since);
    const pushUrl: string = `${this.http.baseUrl()}/api/v1/sync/push`;
    const pushRes: HttpResponse = await this.http.request({
      method: 'POST', url: pushUrl, body: payload, timeoutMs: HTTP_TIMEOUT_MS, token,
    });
    if (pushRes.status !== 200) {
      await this.writeLog(userId, 'push', 'failed', 0, 0, 0, SyncService.errorOf(pushRes), t0, Date.now());
      return fail<SyncOutcome>('SYNC_FAILED', `同步失败：${SyncService.errorOf(pushRes)}（未更新最后同步时间）`);
    }
    const pushed: number = await this.markSynced(userId, since);
    const pullUrl: string = `${this.http.baseUrl()}/api/v1/sync/pull?since=${since}`;
    const pullRes: HttpResponse = await this.http.request({
      method: 'GET', url: pullUrl, body: '', timeoutMs: HTTP_TIMEOUT_MS, token,
    });
    if (pullRes.status !== 200) {
      await this.writeLog(userId, 'pull', 'failed', 0, pushed, 0, SyncService.errorOf(pullRes), t0, Date.now());
      return fail<SyncOutcome>('SYNC_FAILED', `同步失败：${SyncService.errorOf(pullRes)}（未更新最后同步时间）`);
    }
    // 时钟偏移的**唯一来源是 push 握手腿**：附录 B §5.3:855 明确 `offsetMs` 只在
    // `POST /sync/push` 响应里回带，`pull` 只回 `serverTime`/`since`/`tables`。
    // （t62 修复的 F2：原来只把 pull 响应体喂给 `applyPull` ⇒ `offsetMsClient` 恒为 0，
    //  §6.4-6 的时钟校正等于没生效。）此处取反后传给 `applyPull`，pull 体里若有仍作兜底。
    const handshakeOffsetMs: number = SyncService.handshakeOffsetOf(pushRes.body);
    const pushWarning: string = SyncService.clockWarningOf(pushRes.body);
    if (pushWarning.length > 0) {
      hilog.warn(DOMAIN, TAG, '同步时钟告警（push 握手）：%{public}s（已按 clientOffsetMs=%{public}d 换算后继续合并）',
        pushWarning, handshakeOffsetMs);
    }
    const applied: SyncOutcome = await this.applyPull(pullRes.body, since, handshakeOffsetMs);
    const serverTime: number = applied.serverTime > 0 ? applied.serverTime : Date.now();
    await this.cfg.set(ConfigKeys.LAST_SYNC_AT, `${serverTime}`);
    await this.writeLog(userId, 'both', 'success', applied.pulled, pushed, applied.conflicts, '', t0, Date.now());
    return ok<SyncOutcome>({
      accepted: pushed,
      skipped: applied.skipped,
      conflicts: applied.conflicts,
      pulled: applied.pulled,
      serverTime,
    });
  }

  /**
   * **云端备份上传**：`POST /api/v1/sync/backup`（附录 B §5.3:817）。
   *
   * ⚠️ 这里是**快照备份**，不是"一次增量同步"：文档 §5.3:807 明确
   * 「云端备份 = 独立三端点：只存快照，**不做 LWW 比较、不算冲突、不用 `lastSyncAt`**；
   * **不是**『备份复用 `push`/`pull` 的 `since=0`』——那条路径会走 §6.3 的 LWW 合并。」
   * 因此本方法刻意：
   *  - **不调用** `applyPull()`/`applyRow()`（那两个是 LWW 合并路径）；
   *  - **不产生** `conflicts`（快照无"冲突"概念，撞 id 由服务端按"同 id 覆盖"处理）；
   *  - **不读写** `ConfigKeys.LAST_SYNC_AT`（`lastSyncAt` 是增量同步的锚点，备份不能污染它）。
   * @param userId 服务端账号 id（仅用于服务端对账；身份一律取自令牌）
   * @param now 本次操作起始时间（写 `sync_log` 用）
   * @returns 服务端确认写入的快照行数（`data.stored`）
   */
  async fullUpload(userId: string, now: number): Promise<AppResult<number>> {
    if (!this.state.isLoggedIn()) {
      return fail<number>('NOT_LOGGED_IN', '未登录，未发起任何上传');
    }
    const snapshot: string = await this.snapshotTables();
    const body: string =
      `{"userId":${JSON.stringify(userId)},"deviceId":${JSON.stringify(this.state.deviceId())},` +
      `"clientNow":${Date.now()},"tables":{${snapshot}}}`;
    const res: HttpResponse = await this.http.request({
      method: 'POST',
      url: SyncService.backupUrl(this.http.baseUrl()),
      body,
      timeoutMs: HTTP_TIMEOUT_MS,
      token: await this.authToken(),
    });
    if (res.status !== 200) {
      await this.writeLog(userId, 'backup_up', 'failed', 0, 0, 0, SyncService.errorOf(res), now, Date.now());
      return fail<number>('CLOUD_BACKUP_FAILED', `云端备份失败：${SyncService.errorOf(res)}`);
    }
    let stored: number = 0;
    try {
      const data: JsonObject = SyncService.dataOf(res.body);
      const v: number | undefined = optNum(data, 'stored');
      stored = v === undefined ? 0 : v;
    } catch (e) {
      return fail<number>('CLOUD_BACKUP_BAD_RESPONSE', '云端备份响应不完整');
    }
    // 上传成功 = 本机这份就是云端快照，故可把它们标 `synced`（快照是权威，不涉及合并判定）。
    await this.markSynced(userId, 0);
    // 记一行 pull=0 的日志：备份**不产生 conflicts**，第三个计数位恒为 0。
    await this.writeLog(userId, 'backup_up', 'success', 0, stored, 0, '', now, Date.now());
    return ok<number>(stored);
  }

  /**
   * **云端备份恢复（覆盖式）**：先 `GET /api/v1/sync/backup` 取快照，
   * 再 `POST /api/v1/sync/backup/restore` 让服务端按快照整体对齐（附录 B §5.3:818-819）。
   *
   * ⚠️ 语义是**覆盖**，不是合并（文档 §5.3:807「恢复**即覆盖**」）：
   *  - **不调用** `applyPull()`/`applyRow()`，**不产生** `conflicts`，**不动** `lastSyncAt`；
   *  - 覆盖**之前**先把服务端回带的 `preRestore`（云端原状）+ `preRestoreAt` 落盘
   *    （文档 §5.3:819「覆盖前原状随响应 `preRestore`（+ `preRestoreAt`）返回」；
   *     服务端**不新建表**、由调用方负责保存，见 PLAN §7.8）；
   *  - 只增账本表（`point_record`/`carbon_include`）在服务端**只补不删**（铁律 4），
   *    本方法不参与该判断——那是服务端 `restore` 的职责（§5.3:819）。
   * @param userId 服务端账号 id
   * @param now 本次操作起始时间
   * @returns 本次覆盖恢复影响的行数（`restored + removed`）
   */
  async fullRestore(userId: string, now: number): Promise<AppResult<number>> {
    if (!this.state.isLoggedIn()) {
      return fail<number>('NOT_LOGGED_IN', '未登录，未发起任何请求');
    }
    const token: string = await this.authToken();
    // ① 取快照（覆盖的数据源）
    const snapRes: HttpResponse = await this.http.request({
      method: 'GET',
      url: SyncService.backupUrl(this.http.baseUrl()),
      body: '',
      timeoutMs: HTTP_TIMEOUT_MS,
      token,
    });
    if (snapRes.status !== 200) {
      await this.writeLog(userId, 'backup_down', 'failed', 0, 0, 0, SyncService.errorOf(snapRes), now, Date.now());
      return fail<number>('CLOUD_RESTORE_FAILED', `云端快照下载失败：${SyncService.errorOf(snapRes)}`);
    }
    let tables: string = '';
    try {
      const data: JsonObject = SyncService.dataOf(snapRes.body);
      tables = SyncService.tablesJson(SyncService.objField(data, 'tables'));
    } catch (e) {
      await this.writeLog(userId, 'backup_down', 'failed', 0, 0, 0, SyncService.messageOf(e), now, Date.now());
      return fail<number>('CLOUD_RESTORE_BAD_SNAPSHOT', '云端快照结构非法，已放弃恢复（本机未改动）');
    }
    // ② 覆盖式恢复
    const restoreBody: string =
      `{"userId":${JSON.stringify(userId)},"deviceId":${JSON.stringify(this.state.deviceId())},` +
      `"clientNow":${Date.now()},"tables":${tables}}`;
    const res: HttpResponse = await this.http.request({
      method: 'POST',
      url: `${SyncService.backupUrl(this.http.baseUrl())}/restore`,
      body: restoreBody,
      timeoutMs: HTTP_TIMEOUT_MS,
      token,
    });
    if (res.status !== 200) {
      await this.writeLog(userId, 'backup_restore', 'failed', 0, 0, 0, SyncService.errorOf(res), now, Date.now());
      return fail<number>('CLOUD_RESTORE_FAILED', `云端恢复失败：${SyncService.errorOf(res)}`);
    }
    let restored: number = 0;
    let removed: number = 0;
    try {
      const data: JsonObject = SyncService.dataOf(res.body);
      const r: number | undefined = optNum(data, 'restored');
      const d: number | undefined = optNum(data, 'removed');
      restored = r === undefined ? 0 : r;
      removed = d === undefined ? 0 : d;
      // ③ 覆盖**之前**的云端原状落盘（调用方负责，服务端不建表）
      const pre: Object | undefined = data['preRestore'];
      if (pre !== undefined) {
        const at: number | undefined = optNum(data, 'preRestoreAt');
        await this.savePreRestore(pre, at === undefined ? 0 : at);
      }
    } catch (e) {
      // 写库失败或响应不完整：恢复**已在云端生效**，故不谎报失败，但如实记录
      await this.writeLog(userId, 'backup_restore', 'partial', 0, 0, 0, SyncService.messageOf(e), now, Date.now());
      return ok<number>(restored + removed);
    }
    // 恢复是覆盖：本机应重新拉一次增量即可与云端一致，但**不动** lastSyncAt，故只记日志。
    await this.writeLog(userId, 'backup_restore', 'success', 0, restored + removed, 0, '', now, Date.now());
    return ok<number>(restored + removed);
  }

  /**
   * 家庭碳积分（只读合并；单设备时返回空 members，页面显示空态）。
   *
   * **积分口径（t21 勘误）**：家庭成员与合计两处都用 `SUM(points)` —— `point_record.points`
   * **本身已带符号**（`PointService.append` 写的 primary 是正额、`reverse()` 写的 reverse 是负额），
   * 故净额 = 直接相加，与 `PointService.balance()` 的 `SUM(points)` 口径**逐字一致**。
   * 此前合计写的是 `CASE WHEN flow_kind = 'primary' THEN points ELSE -points END`，会把 reverse 行
   * **翻回正数**（本机 −96 记成 +96），导致协同页「家庭积分合计」与「我的」页余额对不上；成员口径此前
   * 又只算 primary 行，同一条 reverse 会让成员之和 ≠ 合计。两处一并按净额修正（§18.2「只读求和」）。
   */
  async family(userId: string): Promise<FamilySummary> {
    const rows: RowShape[] = await this.store.query(
      'SELECT device_id AS did, COUNT(*) AS n, COALESCE(SUM(reduction_kg), 0) AS kg FROM carbon_record ' +
      'WHERE user_id = ? AND is_deleted = 0 GROUP BY device_id ORDER BY kg DESC',
      [userId]
    );
    const members: FamilyMember[] = [];
    let totalKg: number = 0;
    let i: number = 0;
    while (i < rows.length) {
      const did: string = textOf(rows[i], 'did');
      const kg: number = numOf(rows[i], 'kg');
      const earned: RowShape[] = await this.store.query(
        "SELECT COALESCE(SUM(points), 0) AS p FROM point_record WHERE user_id = ? AND is_deleted = 0 AND COALESCE(device_id, '') = ?",
        [userId, did]
      );
      const earnedRow: RowShape | undefined = firstOf(earned);
      const points: number = earnedRow === undefined ? 0 : numOf(earnedRow, 'p');
      members.push({
        deviceId: did.length === 0 ? 'unknown' : did,
        label: did === this.state.deviceId() ? `${this.state.deviceId()}（本机）` : did,
        reductionKg: kg,
        points,
      });
      totalKg = totalKg + kg;
      i = i + 1;
    }
    const totalPointsRows: RowShape[] = await this.store.query(
      "SELECT COALESCE(SUM(points), 0) AS p FROM point_record WHERE user_id = ? AND is_deleted = 0",
      [userId]
    );
    const tp: RowShape | undefined = firstOf(totalPointsRows);
    return { members, totalReductionKg: totalKg, totalPoints: tp === undefined ? 0 : numOf(tp, 'p') };
  }

  /** 同步日志（最近 `limit` 条）。 */
  async logs(userId: string, limit: number): Promise<SyncLogRow[]> {
    const rows: RowShape[] = await this.store.query(
      'SELECT * FROM sync_log WHERE user_id = ? ORDER BY started_at DESC LIMIT ?',
      [userId, limit]
    );
    return RowMapper.syncLogs(rows);
  }

  /** 已配对设备（近场演示层：没有配对记录就是空列表）。 */
  async peers(): Promise<DevicePeer[]> {
    const raw: string | undefined = await this.cfg.get(ConfigKeys.SYNC_PEER);
    if (raw === undefined || raw.length === 0) {
      return [];
    }
    try {
      const arr: JsonArray = asArray(JSON.parse(raw), 'sync_peer');
      const out: DevicePeer[] = [];
      let i: number = 0;
      while (i < arr.length) {
        const o: JsonObject = asObject(arr[i], `sync_peer[${i}]`);
        const deviceId: string | undefined = optStr(o, 'deviceId');
        const deviceName: string | undefined = optStr(o, 'deviceName');
        const networkId: string | undefined = optStr(o, 'networkId');
        if (deviceId !== undefined && deviceName !== undefined) {
          out.push({
            deviceId,
            deviceName,
            networkId: networkId === undefined ? '' : networkId,
            online: false,
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
   * 近场发现（创新项 Ⅰ / 附录 C §18.3）。
   * 本机未启用分布式数据服务栈时返回空数组，页面据此显示「未发现已配对设备」——
   * **不编造设备**，也不把空数组当成功同步。
   */
  async discover(): Promise<DevicePeer[]> {
    return this.peers();
  }

  /** 近场演示状态机的初始态（页面据此渲染 ①发现设备 ②合并数据 ③写回本机）。 */
  /** 未登录/首帧的初始状态（避免页面出现 undefined 或 NaN）。 */
  /**
   * 近场演示同步（附录 C §18.3，降级层）。
   *
   * 本机没有可用对端时 `discover()` 返回空数组；只有当 `app_config['sync_peer']`
   * 里注入了演示对端（路演脚本会注入）才会走到这里。**不编造条数**：真实传输层
   * 不在本期范围，所以拉取/上传/冲突一律记 0，只写一条 `sync_log` 并返回三段进度态。
   */
  async nearFieldSync(peer: DevicePeer, now: number): Promise<AppResult<SyncSessionState>> {
    if (peer.deviceId.length === 0) {
      return fail<SyncSessionState>('PEER_INVALID', '设备标识为空');
    }
    const started: number = now;
    await this.writeLog(peer.deviceId, 'both', 'success', 0, 0, 0, '', started, Date.now());
    const st: SyncSessionState = {
      phase: 'done', progress: 100, pulledCount: 0, pushedCount: 0, conflictCount: 0,
      peerDevice: peer.deviceName, startedAt: started, finishedAt: Date.now()
    };
    return ok<SyncSessionState>(st);
  }

  static emptyStatus(deviceId: string): SyncStatus {
    const st: SyncStatus = {
      loggedIn: false, userLabel: '', pending: 0, lastSyncAt: 0, conflictCount: 0,
      deviceId: deviceId, peerCount: 0
    };
    return st;
  }

  /** 家庭合并视图的空态（单机或未登录）。 */
  static emptyFamily(): FamilySummary {
    const fam: FamilySummary = { members: [], totalReductionKg: 0, totalPoints: 0 };
    return fam;
  }

  static idleState(): SyncSessionState {
    return {
      phase: 'idle',
      progress: 0,
      pulledCount: 0,
      pushedCount: 0,
      conflictCount: 0,
    };
  }

  /**
   * 读取登录令牌（`ConfigKeys.AUTH_TOKEN`），填进 `HttpRequest.token`。
   *
   * 为什么由本层读、而不是让 `HttpClient` 自己去查：
   *  - `HttpClient` 是**纯网络适配器**（`baseUrl` + `request`），constructor 只有 baseUrl，
   *    不持有 `AppConfig`；给它注入配置会把一个窄端口变成有状态的业务组件，
   *    也会让 `FakeHttpClient` 的用例装配复杂化；
   *  - 本层已经有 `cfg`，且**只在已登录分支才走到这里**（`sync`/`fullUpload`/`fullRestore`
   *    开头都判过 `state.isLoggedIn()`），读到的必然是有效令牌。
   * 头部的实际拼装仍然只在 `HttpClient.request` 一处（`Bearer <token>`）。
   *
   * ⚠️ 只**读**该 key：按 AGENTS/`ConfigKeys` 约定，`AUTH_TOKEN` 的写方只有 `AuthService`。
   */
  private async authToken(): Promise<string> {
    const token: string | undefined = await this.cfg.get(ConfigKeys.AUTH_TOKEN);
    return token === undefined ? '' : token;
  }

  /** 推送体（`since = 0` 时是全量快照）。 */
  private async pushBody(userId: string, since: number): Promise<string> {
    const tables: string[] = [];
    let i: number = 0;
    while (i < ClientSchema.SYNCED_TABLES.length) {
      const name: string = ClientSchema.SYNCED_TABLES[i];
      const rows: RowShape[] = await this.store.query(
        `SELECT * FROM ${name} WHERE user_id = ? AND updated_at > ?`,
        [userId, since]
      );
      tables.push(`${JSON.stringify(name)}:[${SyncService.rowsJson(rows)}]`);
      i = i + 1;
    }
    // `clientNow`（附录 B §5.3:825）：客户端当前时钟（毫秒），服务端据此测时钟偏移并回带 `offsetMs`；
    // 缺失 = 服务端按"无偏移"处理（不猜值）。
    return `{"userId":${JSON.stringify(userId)},"deviceId":${JSON.stringify(this.state.deviceId())},` +
      `"lastSyncAt":${since},"clientNow":${Date.now()},"tables":{${tables.join(',')}}}`;
  }

  /** 行数组 → JSON 片段。 */
  private static rowsJson(rows: RowShape[]): string {
    const parts: string[] = [];
    let i: number = 0;
    while (i < rows.length) {
      parts.push(JSON.stringify(rows[i]));
      i = i + 1;
    }
    return parts.join(',');
  }

  /** 标记已推送行为 `synced`，返回条数。 */
  private async markSynced(userId: string, since: number): Promise<number> {
    let n: number = 0;
    let i: number = 0;
    while (i < ClientSchema.SYNCED_TABLES.length) {
      const name: string = ClientSchema.SYNCED_TABLES[i];
      const before: RowShape[] = await this.store.query(
        `SELECT COUNT(*) AS n FROM ${name} WHERE user_id = ? AND updated_at > ?`,
        [userId, since]
      );
      const row: RowShape | undefined = firstOf(before);
      if (row !== undefined) {
        n = n + numOf(row, 'n');
      }
      await this.store.exec(`UPDATE ${name} SET "sync_state" = 'synced' WHERE user_id = ? AND updated_at > ?`, [userId, since]);
      i = i + 1;
    }
    return n;
  }

  /**
   * 应用拉取结果（LWW：`updated_at` 大者胜；相等跳过；本地较新记冲突并保留本地）。
   * 服务端若返回 `data.merged`（附录 B §5.3），同样按 LWW 应用。
   */
  private async applyPull(body: string, since: number, handshakeOffsetMs: number): Promise<SyncOutcome> {
    let pulled: number = 0;
    let conflicts: number = 0;
    let skipped: number = 0;
    let serverTime: number = 0;
    if (body.length === 0) {
      return { accepted: 0, skipped, conflicts, pulled, serverTime };
    }
    let root: JsonObject;
    try {
      root = asObject(JSON.parse(body), 'sync');
    } catch (e) {
      return { accepted: 0, skipped, conflicts, pulled, serverTime };
    }
    const dataNode: Object | undefined = root['data'];
    if (dataNode === undefined) {
      return { accepted: 0, skipped, conflicts, pulled, serverTime };
    }
    const data: JsonObject = asObject(dataNode, 'sync.data');
    const st: number | undefined = optNum(data, 'serverTime');
    serverTime = st === undefined ? 0 : st;
    // 时钟偏移（附录 B §5.3:838-841）：响应字段 `offsetMs` 的定义是「**服务端时钟 − 客户端时钟**」，
    // 即**服务端视角**的"本机 − 对端"；而 §6.3 伪码 `r.updatedAt + offsetMs` 里的 offsetMs 是
    // **客户端视角**的"本机 − 对端" —— 二者**互为相反数**（§6.4-6 原话）。故此处取反：
    //   offsetMsClient = -respOffsetMs
    // 判据：respOffsetMs = +60000（服务端快 60 秒）→ offsetMsClient = -60000
    //      → 同一条服务端时间戳相对本机**显得更旧**，绝不能显得更新。
    //
    // 取值优先级（t62 的 F2 修复）：
    //  ① pull 响应体里的 `offsetMs`（若服务端给了，仍按原口径取反）—— 兜底；
    //  ② 否则用 **push 握手腿**测得的 `handshakeOffsetMs`（`sync()` 已取反传入）。
    //     附录 B §5.3:855 写死 pull 不带该字段 ⇒ 正常增量同步路径走的就是 ②，
    //     校正因此**真正生效**；只走 pull（不经 `sync()`）的调用方按 0（＝不校正）。
    const respOffset: number | undefined = optNum(data, 'offsetMs');
    const offsetMsClient: number = respOffset === undefined ? handshakeOffsetMs : -respOffset;
    const warning: string | undefined = optStr(data, 'clockWarning');
    if (warning !== undefined && warning.length > 0) {
      // 超 ±5 分钟容差：服务端已给提示，**仍继续合并**（§6.4-6），只在本地留一行告警日志。
      hilog.warn(DOMAIN, TAG, '同步时钟告警：%{public}s（已按 offsetMs=%{public}d 换算后继续合并）',
        warning, offsetMsClient);
    }
    const tablesNode: Object | undefined = data['tables'];
    if (tablesNode === undefined) {
      return { accepted: 0, skipped, conflicts, pulled, serverTime };
    }
    const tables: JsonObject = asObject(tablesNode, 'sync.data.tables');
    const names: string[] = Object.keys(tables);
    let i: number = 0;
    while (i < names.length) {
      const name: string = names[i];
      if (SyncService.isSyncedTable(name)) {
        const rows: JsonArray = asArray(tables[name], `sync.data.tables.${name}`);
        let k: number = 0;
        while (k < rows.length) {
          const row: RowShape = SyncService.rowOf(asObject(rows[k], `${name}[${k}]`));
          const decision: LwwDecision = await this.applyRow(name, row, since, offsetMsClient);
          if (decision.action === 'written') {
            pulled = pulled + 1;
          } else if (decision.action === 'kept') {
            skipped = skipped + 1;
          } else {
            // `insertRow` 的 `INSERT OR IGNORE` 被丢弃（撞唯一索引 / NOT NULL 兜底）
            // → 按 §6.4-3 计 **ignored/skipped**：既不算 `written`（没写进去），
            //   也不算 `conflicts`（去重丢弃与"两端都改过"无关）。
            skipped = skipped + 1;
          }
          // ⚠️ 冲突只按 §6.3 的「真冲突」条件计数（`l.updatedAt > since && r.updatedAt > since`），
          //    **与写入/保留无关**：既不是"写入了才算冲突"，也不是"跳过就是冲突"（§6.4-3：
          //    去重丢弃的行只计 ignored/skipped，不得计入 conflicts）。
          if (decision.conflict) {
            conflicts = conflicts + 1;
          }
          k = k + 1;
        }
      }
      i = i + 1;
    }
    return { accepted: 0, skipped, conflicts, pulled, serverTime };
  }

  /**
   * 应用一行远端数据（附录 B §6.3 的 LWW 裁决）。
   *
   * 裁决顺序（与服务端 `sync_service.py:471-484` **逐字同规则**，§6.4-6「两端用同一规则，结论一致」）：
   *  1. `rUpdated > lUpdated` → 写远端（`written`）；
   *  2. `rUpdated === lUpdated` → **平局按 `deviceId` 字典序大者胜**（远端更大则写远端，
   *     否则保留本机）；**两端 `deviceId` 相同视为同一版本 → 保留本机**；
   *  3. `rUpdated < lUpdated` → 保留本机（`kept`）。
   *
   * `rUpdated` 是**换算后**的对端时间戳（`r.updatedAt + offsetMs`，`offsetMs` 为客户端视角）；
   * 真冲突计数用的却是**原始** `r.updatedAt`（见下），换算只服务于大小比较。
   *
   * @param table 表名
   * @param row 远端行（原始字段，含原始 `updated_at` 与 `device_id`）
   * @param since 上次成功同步时间（`lastSyncAt`），用于判定「真冲突」
   * @param offsetMs **客户端视角**偏移（本机 − 对端）；0 = 未校正
   */
  private async applyRow(table: string, row: RowShape, since: number, offsetMs: number): Promise<LwwDecision> {
    const id: string = textOf(row, 'id');
    if (id.length === 0) {
      return new LwwDecision('skipped', false);
    }
    // 认领本机已有行：按业务唯一键（单例表按 `user_id`），不是只按 `id`（见 `RowClaim` 注释）。
    const claim: RowClaim = RowClaim.of(table, row);
    const local: RowShape[] = await this.store.query(claim.sql, claim.args);
    const remoteRaw: number = numOf(row, 'updated_at');
    // 对端时间戳 → 本机基准（§6.4-6）。offsetMs 已由 applyPull 取反，这里用加号与 §6.3 伪码一致。
    const remoteUpdated: number = remoteRaw + offsetMs;
    // 落库基准（§5.3:1097「本机业务行的 `updated_at` = 客户端基准」）：写进本机库**之前**就把对端
    // 时间戳换算到本机基准。否则本机库里会混两种基准——自己写的行是客户端基准、拉回来的行是服务端
    // 基准——下一次比较就变成「服务端基准的 `localUpdated`」对「换算后的 `remoteUpdated`」，
    // 偏差 = |offsetMs|（t68：客户端落库基准一致性）。
    const stored: RowShape = SyncService.rowOnClientBasis(row, remoteUpdated);
    if (local.length > 0) {
      // 只增表（`point_record` / `carbon_include`）：本机已有同 id / 同业务键的行即**去重丢弃**，
      // 永不 UPDATE（铁律 4；与服务端 `_merge_append_only` 同规则）。计 skipped，不计 conflicts
      //（§6.4-3：去重丢弃不算冲突）。
      if (SYNC_MODES[table] === MODE_APPEND_ONLY) {
        return new LwwDecision('skipped', false);
      }
      const localUpdated: number = numOf(local[0], 'updated_at');
      // 「真冲突」= 两端自上次同步后**都改过这一行**（§6.3:959/966；§5.3:1095 客户端行）。
      // 本机行是**客户端**基准，而锚点 `since`（= `lastSyncAt` / 响应 `serverTime`）是**服务端**基准
      //（§5.3:1089：`lastSyncAt` 单一口径选服务端基准），所以锚点也要换算到本机一侧：
      // `lastSyncAtLocal = since + clientOffsetMs`（= `since − respOffsetMs`）。对端行保持原值比较。
      const sinceLocal: number = since + offsetMs;
      const trueConflict: boolean = localUpdated > sinceLocal && remoteRaw > since;
      if (localUpdated > remoteUpdated) {
        return new LwwDecision('kept', trueConflict);
      }
      if (localUpdated === remoteUpdated) {
        // 平局：deviceId 字典序大者胜（与 §6.3:960-967 / 服务端 :471-484 同规则）
        const remoteDevice: string = textOf(row, 'device_id');
        const localDevice: string = textOf(local[0], 'device_id');
        if (remoteDevice > localDevice) {
          // 远端胜出 → 走下面的写回
          await this.deleteLocal(table, local[0]);
          return this.insertRow(table, stored, trueConflict);
        }
        // 远端 deviceId 更小、或两端相同（同一版本）→ 保留本机
        return new LwwDecision('kept', trueConflict);
      }
      // 对端更新 → 覆盖本机
      await this.deleteLocal(table, local[0]);
      return this.insertRow(table, stored, trueConflict);
    }
    // 本机没有该行 → 直接接纳（本机没有的行走不到"真冲突"条件，恒为 false）
    return this.insertRow(table, stored, false);
  }

  /**
   * 删掉**被认领的那一行本机数据**（覆盖写回的前半段）。
   *
   * ⚠️ `DELETE` 必须用**本机那一行的 `id`**，不能用远端 `id`：认领可能是按 `user_id`（单例表）
   * 或业务唯一键命中的，此时本机行的 `id` 与远端行的 `id` **不同**（如两台设备各自的
   * `user_profile` UUID）。用远端 id 删会删不到东西 → 残留本机行 → 紧随的 INSERT 撞唯一索引。
   */
  private async deleteLocal(table: string, localRow: RowShape): Promise<void> {
    await this.store.exec(`DELETE FROM ${table} WHERE id = ?`, [textOf(localRow, 'id')]);
  }

  /** 落一行（`applyRow` 的写回半段）：列集合取自远端行；**被 `OR IGNORE` 丢弃时返回 `skipped`**。
   *
   * 列名/表名一律经 `quoted` / `quotedAll` 加引号 —— 列名来自远端 JSON 键，裸拼遇保留字即语法错（见 `quoted` 注释）。
   *
   * `INSERT OR IGNORE`（B41 第二道兜底）：业务键/单例唯一索引一旦仍被撞上（例如远端行本身
   * 畸形、或缺列触发 NOT NULL），**静默丢弃并计 skipped**，绝不让一次同步整批抛错。
   * 判定方式：插完回读该 `id` —— 在表里 = 确实写进去了（`written`）；不在 = 被 IGNORE 丢弃（`skipped`）。
   */
  private async insertRow(table: string, row: RowShape, conflict: boolean): Promise<LwwDecision> {
    const columns: string[] = Object.keys(row);
    if (columns.length === 0) {
      return new LwwDecision('skipped', conflict);
    }
    const args: SqlValue[] = [];
    let k: number = 0;
    while (k < columns.length) {
      const v: string | number | null | undefined = row[columns[k]];
      args.push(v === undefined ? null : v);
      k = k + 1;
    }
    const marks: string[] = [];
    let m: number = 0;
    while (m < columns.length) {
      marks.push('?');
      m = m + 1;
    }
    await this.store.exec(
      `INSERT OR IGNORE INTO ${table} (${SyncService.quotedAll(columns).join(', ')}) VALUES (${marks.join(', ')})`,
      args
    );
    const back: RowShape[] = await this.store.query(`SELECT id FROM ${table} WHERE id = ?`, [textOf(row, 'id')]);
    if (back.length === 0) {
      return new LwwDecision('skipped', conflict);
    }
    return new LwwDecision('written', conflict);
  }

  // ---------------------------------------------------------------- 备份三端点辅助

  /** 备份组端点基址（附录 B §5.3:817-819 两条 `/sync/backup` + 一条 `/sync/backup/restore`）。 */
  private static backupUrl(base: string): string {
    return `${base}/api/v1/sync/backup`;
  }

  /**
   * 取响应信封的 `data` 对象（备份三端点与增量端点同用 `{ok, data}`）。
   * `ok=false` 或 `data` 缺失一律抛错 —— 调用方据此判"响应不完整"，不猜值。
   */
  private static dataOf(body: string): JsonObject {
    const root: JsonObject = asObject(JSON.parse(body), 'sync');
    if (root['ok'] === false) {
      throw new Error('服务端 ok=false');
    }
    return SyncService.objField(root, 'data');
  }

  /** 取必填子对象（缺失即抛错）。 */
  private static objField(o: JsonObject, key: string): JsonObject {
    const v: Object | undefined = o[key];
    if (v === undefined) {
      throw new Error(`响应缺少字段 ${key}`);
    }
    return asObject(v, key);
  }

  /**
   * 9 张参与同步表的**全量本机行** → JSON 片段（备份上传的 `tables`）。
   *
   * 与 `pushBody` 的区别：不按 `updated_at > since` 过滤、不带 `lastSyncAt`
   * —— 备份要的是**整份快照**，不是增量（附录 B §5.3:807/817）。
   */
  private async snapshotTables(): Promise<string> {
    const parts: string[] = [];
    let i: number = 0;
    while (i < ClientSchema.SYNCED_TABLES.length) {
      const name: string = ClientSchema.SYNCED_TABLES[i];
      const rows: RowShape[] = await this.store.query(`SELECT * FROM ${name}`, []);
      parts.push(`${JSON.stringify(name)}:[${SyncService.rowsJson(rows)}]`);
      i = i + 1;
    }
    return parts.join(',');
  }

  /**
   * 把已解析的 `tables` 对象**原样重序列化**为 JSON 片段（快照下载 → 恢复上传）。
   *
   * 为什么重序列化而不是把原始文本切出来：`tables` 嵌在 `data` 里，
   * 直接切字符串要重新实现一遍 JSON 扫描、易错；`JSON.stringify` 对已解析对象
   * 是等价的（同一份数据、同一套字段），且天然丢弃服务端可能多给的 `serverTime` 等字段。
   */
  private static tablesJson(tables: JsonObject): string {
    return JSON.stringify(tables);
  }

  /** 把 `preRestore` 连同 `preRestoreAt` 包成落盘形态（服务端不建表，由调用方保存）。 */
  private static wrapPreRestore(pre: Object, at: number): string {
    return JSON.stringify({ preRestoreAt: at, preRestore: pre });
  }

  /**
   * 落盘"恢复前的云端原状"（覆盖式恢复的后悔药，附录 B §5.3:819 / PLAN §7.8）。
   *
   * 直接经 `app_config` 做 UPSERT（与 `AppConfig.set` 同一句式），键为本文件的私有
   * `KEY_PRE_RESTORE`。写入失败**不阻断**恢复流程 —— 恢复已在云端生效，
   * 此时把"落盘失败"当致命错误只会让状态更难解释（调用方已按 partial 记录）。
   */
  private async savePreRestore(pre: Object, at: number): Promise<void> {
    const now: number = Date.now();
    await this.store.exec(
      'INSERT INTO app_config ("id", "value", "version", "fetched_at", "created_at", "updated_at") VALUES (?, ?, NULL, NULL, ?, ?) ' +
      'ON CONFLICT("id") DO UPDATE SET "value" = excluded."value", "updated_at" = excluded."updated_at"',
      [KEY_PRE_RESTORE, SyncService.wrapPreRestore(pre, at), now, now]
    );
  }

  private static messageOf(e: Object): string {
    return e instanceof Error ? e.message : `${e}`;
  }

  private static rowOf(o: JsonObject): RowShape {
    const keys: string[] = Object.keys(o);
    const out: RowShape = {};
    let i: number = 0;
    while (i < keys.length) {
      const v: Object = o[keys[i]];
      if (typeof v === 'string' || typeof v === 'number') {
        out[keys[i]] = v;
      } else if (typeof v === 'boolean') {
        out[keys[i]] = v ? 1 : 0;
      } else {
        out[keys[i]] = null;
      }
      i = i + 1;
    }
    return out;
  }

  /**
   * 列名加引号：本文件拼 `INSERT` / `UPDATE` 时，**列名一律经此**进语句。
   *
   * 起因（t49，与 t46 在 `BackupService.ets:307` 修掉的是**同一个模式**）：拼 `INSERT` /
   * `UPDATE` 时把标识符裸拼进语句，遇到保留字就炸。t46 的实例是 `ClientSchema.ets` 里那张
   * 含列 `order` 的表 —— 裸 `order` 让 SQLite 报 `near "order": syntax error`，
   * **任何备份都无法恢复**（真机同一条代码路径、同错）。
   *
   * 本文件的暴露面比备份更宽一层：`insertRow` 的列集合来自**远端行**的
   * `Object.keys(row)`（拉取结果里的 JSON 键，见 `rowOf`）。远端给一个保留字列名
   * （`order` / `key` / `group` …）或畸形键，整条同步就会在运行期以语法错误失败。
   * 逐列加引号后，列名只被当作标识符（含挡掉标识符注入面）—— 不是给 `order` 打特例补丁。
   *
   * 范围界定（t49）：**表名保持裸写**。本文件所有表名都来自 `ClientSchema` 的静态白名单
   * （`SYNCED_TABLES` / `TABLES`，远端表名先过 `isSyncedTable`），不随远端数据变化；
   * 且 `LwwMerge.test.ets:450/:453/:599` 的 SQL 轨迹断言按字面量
   * `` `INSERT INTO ${TABLE}` `` / `` `DELETE FROM ${TABLE}` `` 匹配，表名加引号会让这三处
   * 断言失配 —— 断言按 t49 契约不得改动。统一的列名加引号已消除 t46 那一类（列）风险；
   * 表名侧若将来真出现保留字表名，属 schema 层命名约束，需连同那三处轨迹断言一并处理。
   */
  private static quoted(name: string): string {
    return '"' + name + '"';
  }

  private static quotedAll(names: string[]): string[] {
    const out: string[] = [];
    let i: number = 0;
    while (i < names.length) {
      out.push(SyncService.quoted(names[i]));
      i = i + 1;
    }
    return out;
  }

  /**
   * 把对端行复制一份，并把 `updated_at` 换成**本机（客户端）基准**的值（§5.3:1097）。
   *
   * 只改这一列：其余列逐列原样拷贝（含 `device_id` —— 平局/归属判断依赖它保持对端的值）。
   * 不在这里做任何业务计算，只为「本机库里只有一种时间基准」这一条不变量服务。
   */
  private static rowOnClientBasis(row: RowShape, updatedAt: number): RowShape {
    const out: RowShape = {};
    const keys: string[] = Object.keys(row);
    let i: number = 0;
    while (i < keys.length) {
      out[keys[i]] = row[keys[i]];
      i = i + 1;
    }
    out['updated_at'] = updatedAt;
    return out;
  }

  private static isSyncedTable(name: string): boolean {
    let i: number = 0;
    while (i < ClientSchema.SYNCED_TABLES.length) {
      if (ClientSchema.SYNCED_TABLES[i] === name) {
        return true;
      }
      i = i + 1;
    }
    return false;
  }

  private async writeLog(
    userId: string, direction: string, status: string, pulled: number, pushed: number,
    conflicts: number, errorMsg: string, startedAt: number, finishedAt: number
  ): Promise<void> {
    await this.store.exec(
      'INSERT INTO sync_log ("id", "user_id", "peer_device", "direction", "status", "pulled_count", "pushed_count", "conflict_count", "error_msg", "started_at", "finished_at", "created_at") ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        IdUtil.uuid(), userId, this.state.deviceId(), direction, status,
        pulled, pushed, conflicts, errorMsg.length === 0 ? null : errorMsg, startedAt, finishedAt, startedAt,
      ]
    );
  }

  private static errorOf(res: HttpResponse): string {
    if (res.error !== undefined && res.error.length > 0) {
      return res.error;
    }
    return `HTTP ${res.status}`;
  }

  /**
   * 解析 `{ok, data:{…}}` 信封的 `data`；体为空 / 不是 JSON / 无 `data` 一律返回 `undefined`
   * （时钟信息是**可选**的，绝不能因为它缺失或畸形就让整次同步失败）。
   */
  private static envelopeOf(body: string): JsonObject | undefined {
    if (body.length === 0) {
      return undefined;
    }
    try {
      const root: JsonObject = asObject(JSON.parse(body), 'sync');
      const dataNode: Object | undefined = root['data'];
      return dataNode === undefined ? undefined : asObject(dataNode, 'sync.data');
    } catch (e) {
      return undefined;
    }
  }

  /**
   * 从 **push 响应**里取「客户端视角」的时钟偏移（`clientOffsetMs = -offsetMs`）。
   *
   * 为什么必须由客户端在这一腿取：附录 B §5.3:855 写死 `offsetMs` 只在 `POST /sync/push`
   * 响应里回带（`pull` 只回 `serverTime`/`since`/`tables`），而 §6.3 伪码需要的却是
   * **客户端视角**的偏移 ⇒ 客户端必须自己取反并在本次 pull 合并时使用（t62 的 F2）。
   * 缺失即 0（＝不校正），与服务端「客户端未提供 `clientNow` 时为 0」同一口径。
   */
  private static handshakeOffsetOf(body: string): number {
    const data: JsonObject | undefined = SyncService.envelopeOf(body);
    if (data === undefined) {
      return 0;
    }
    const respOffset: number | undefined = optNum(data, 'offsetMs');
    return respOffset === undefined ? 0 : -respOffset;
  }

  /** 取 push 响应里的 `clockWarning`（超 ±5 分钟容差时的提示；无则空串）。 */
  private static clockWarningOf(body: string): string {
    const data: JsonObject | undefined = SyncService.envelopeOf(body);
    if (data === undefined) {
      return '';
    }
    const warning: string | undefined = optStr(data, 'clockWarning');
    return warning === undefined ? '' : warning;
  }
}
