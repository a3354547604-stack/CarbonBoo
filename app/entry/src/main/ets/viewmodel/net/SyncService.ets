/**
 * SyncService —— 账号与云端同步 / 家庭合并 / 近场演示层（S6 的客户端一侧）。
 *
 * 职责：
 *  ① **待同步数**：参与同步的 9 张表（`ClientSchema.SYNCED_TABLES`）里 `sync_state='pending'` 的行数之和
 *     （附录 C §18.1、验收 D6-6 的唯一口径）；
 *  ② **同步**：`POST /api/v1/sync/push` 推送增量 → `GET /api/v1/sync/pull?since=` 拉取增量 →
 *     按附录 B §6 的 LWW 应用（`updated_at` 大者胜；相等不冲突；本地较新记一次冲突并保留本地）；
 *  ③ **未登录时一行都不发**：`sync()` 第一件事就是判登录态，未登录直接返回失败，
 *     **不会**创建任何 HTTP 请求（验收 D6 的「未登录态不发起任何上传请求」靠 `FakeHttpClient.count()` 断言）；
 *  ④ **家庭合并（只读）**：按 `device_id` 分组求和，口径「同一账号下多设备只读汇总，不合并账本、不改写流水」；
 *  ⑤ **近场演示层**：同一 Wi-Fi 的双机演示（创新项 Ⅰ），**不承担跨设备一致性**；
 *     本机没有分布式数据服务栈时给出空态「未发现已配对设备」，不编造设备；
 *  ⑥ 每次同步写一行 `sync_log`（成功/失败、拉取数、上传数、冲突数、错误原因）；
 *     失败时**不更新** `last_sync_at`（附录 C §18.1 规则）。
 *
 * 云端备份用**契约里已有的** `/sync/pull|push` 实现（`since=0` 即全量快照），
 * 不发明新路径——附录 B §5.3 没有独立的「云端备份」端点，复用增量接口是唯一不越界的做法。
 */
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
    const applied: SyncOutcome = await this.applyPull(pullRes.body, since);
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

  /** 云端全量上传（备份）：`since = 0` 把全部行推上去。 */
  async fullUpload(userId: string, now: number): Promise<AppResult<number>> {
    if (!this.state.isLoggedIn()) {
      return fail<number>('NOT_LOGGED_IN', '未登录，未发起任何上传');
    }
    const body: string = await this.pushBody(userId, 0);
    const res: HttpResponse = await this.http.request({
      method: 'POST',
      url: `${this.http.baseUrl()}/api/v1/sync/push`,
      body,
      timeoutMs: HTTP_TIMEOUT_MS,
      token: await this.authToken(),
    });
    if (res.status !== 200) {
      await this.writeLog(userId, 'push', 'failed', 0, 0, 0, SyncService.errorOf(res), now, Date.now());
      return fail<number>('CLOUD_BACKUP_FAILED', `云端备份失败：${SyncService.errorOf(res)}`);
    }
    const count: number = await this.markSynced(userId, 0);
    await this.writeLog(userId, 'push', 'success', 0, count, 0, '', now, Date.now());
    return ok<number>(count);
  }

  /** 云端恢复（覆盖式）：拉全量后按 LWW 写回本机。 */
  async fullRestore(userId: string, now: number): Promise<AppResult<number>> {
    if (!this.state.isLoggedIn()) {
      return fail<number>('NOT_LOGGED_IN', '未登录，未发起任何请求');
    }
    const res: HttpResponse = await this.http.request({
      method: 'GET',
      url: `${this.http.baseUrl()}/api/v1/sync/pull?since=0`,
      body: '',
      timeoutMs: HTTP_TIMEOUT_MS,
      token: await this.authToken(),
    });
    if (res.status !== 200) {
      await this.writeLog(userId, 'pull', 'failed', 0, 0, 0, SyncService.errorOf(res), now, Date.now());
      return fail<number>('CLOUD_RESTORE_FAILED', `云端恢复失败：${SyncService.errorOf(res)}`);
    }
    const applied: SyncOutcome = await this.applyPull(res.body, 0);
    await this.writeLog(userId, 'pull', 'success', applied.pulled, 0, applied.conflicts, '', now, Date.now());
    return ok<number>(applied.pulled);
  }

  /** 家庭碳积分（只读合并；单设备时返回空 members，页面显示空态）。 */
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
        "SELECT COALESCE(SUM(points), 0) AS p FROM point_record WHERE user_id = ? AND is_deleted = 0 AND flow_kind = 'primary' AND COALESCE(device_id, '') = ?",
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
      "SELECT COALESCE(SUM(CASE WHEN flow_kind = 'primary' THEN points ELSE -points END), 0) AS p FROM point_record WHERE user_id = ? AND is_deleted = 0",
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
    return `{"userId":${JSON.stringify(userId)},"deviceId":${JSON.stringify(this.state.deviceId())},` +
      `"lastSyncAt":${since},"tables":{${tables.join(',')}}}`;
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
      await this.store.exec(`UPDATE ${name} SET sync_state = 'synced' WHERE user_id = ? AND updated_at > ?`, [userId, since]);
      i = i + 1;
    }
    return n;
  }

  /**
   * 应用拉取结果（LWW：`updated_at` 大者胜；相等跳过；本地较新记冲突并保留本地）。
   * 服务端若返回 `data.merged`（附录 B §5.3），同样按 LWW 应用。
   */
  private async applyPull(body: string, since: number): Promise<SyncOutcome> {
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
          const outcome: number = await this.applyRow(name, row, since);
          if (outcome === 1) {
            pulled = pulled + 1;
          } else if (outcome === 0) {
            conflicts = conflicts + 1;
          } else {
            skipped = skipped + 1;
          }
          k = k + 1;
        }
      }
      i = i + 1;
    }
    return { accepted: 0, skipped, conflicts, pulled, serverTime };
  }

  /** 1 = 写入；0 = 冲突（保留本地）；-1 = 跳过。 */
  private async applyRow(table: string, row: RowShape, since: number): Promise<number> {
    const id: string = textOf(row, 'id');
    if (id.length === 0) {
      return -1;
    }
    const local: RowShape[] = await this.store.query(`SELECT updated_at FROM ${table} WHERE id = ?`, [id]);
    const remoteUpdated: number = numOf(row, 'updated_at');
    if (local.length > 0) {
      const localUpdated: number = numOf(local[0], 'updated_at');
      if (localUpdated === remoteUpdated) {
        return -1;
      }
      if (localUpdated > remoteUpdated) {
        return 0;
      }
      await this.store.exec(`DELETE FROM ${table} WHERE id = ?`, [id]);
    }
    const columns: string[] = Object.keys(row);
    if (columns.length === 0) {
      return -1;
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
    await this.store.exec(`INSERT INTO ${table} (${columns.join(', ')}) VALUES (${marks.join(', ')})`, args);
    return 1;
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
      'INSERT INTO sync_log (id, user_id, peer_device, direction, status, pulled_count, pushed_count, conflict_count, error_msg, started_at, finished_at, created_at) ' +
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
}
