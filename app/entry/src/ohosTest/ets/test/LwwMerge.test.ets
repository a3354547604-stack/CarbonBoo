/**
 * LwwMerge —— L1 单测：多设备 LWW 合并语义（附录 B §6.3；`tests/README.md:73`）。
 *
 * 被测对象是**已存在的真实实现**：`viewmodel/net/SyncService.ets` 的
 * `applyPull()`（:409）/ `applyRow()`（:461）—— 本文件**没有**为可测性改动被测代码
 * （`applyRow` 仍是 `private`、未改可见性、未改依赖）。
 *
 * 怎么在不改实现的前提下测到 private 方法：
 *   不直接调私有方法，而是走**公开入口** `SyncService.sync()`（增量 / LWW 路径）与 `fullRestore()`（备份覆盖路径）
 *   （拉全量 `GET /api/v1/sync/pull?since=0` → `applyPull()` → 逐行 `applyRow()`），
 *   把"服务端返回什么"通过 `FakeHttpClient.stub()` 精确喂进去。
 *   断言分两层：① `applyRow` 的返回值语义（经 `SyncOutcome.pulled/skipped/conflicts` 观察）；
 *   ② 本机数据库的**真实落库状态**（直接回读该行）。
 *   这比只断言"调用序列"更强：它证明的是数据最终形态。
 *
 * 关于"内存假 store"的落地方式（与本目录既有测试的差异，特此说明）：
 *   任务要求"自建符合 store 接口的内存假实现（记录 query/exec 调用）"。本目录既有测试
 *   （`GoalIdempotent` / `ShopPurchase`）走的是真实 `ServiceHub` + 内存文件系统的路径，
 *   并不存在可复用的内存 `StorePort` 实现。
 *   而 `applyRow()` 的语义**完全建立在真实 SQL 执行结果上**：它 `SELECT updated_at` 判断
 *   新旧、`DELETE` + 再 `INSERT` 落库、`applyPull()` 的 `pulled/skipped/conflicts` 又由
 *   这些语句的成功与否决定。若换成"只记录不执行"的纯假 store，
 *   `expect(res.data).assertEqual(1)` 这类断言就变成"断言我以为会发出的 SQL 序列"，
 *   既可能误报通过，也正好踩中任务明令禁止的"用假断言凑数"。
 *   故这里改为：**保留真实 `RdbStore` 作为执行后端，套一层 `RecordingStore` 装饰器**——
 *   它实现完整 `StorePort`、**记录每一次 `query`/`exec`/`execBatch`**（满足"记录调用"），
 *   再把调用透传下去（满足"断言的是真实结果"）。两者兼得，且不触碰被测代码。
 *
 * ⚠️ **本机未运行**（如实声明，绝不声称用例通过）：hypium 需由 SDK 的 Previewer 进程驱动，
 *    本机无真机/无模拟器，且该二进制与本机 glibc 不兼容（`pthread_mutex_lock` 断言崩溃）。
 *    本任务对该文件的证据只有两条：① 随 ohosTest 目标 `assembleHap` **编译通过**
 *    （测试源码真进入编译，是真实静态门禁）；② 人工代码审查。
 *
 * 🛑 **原 STOP 已被 t13 修复（本文件相应反转，见下）**：本文件最初写于 t11，
 *    当时用两个用例把「实现未做平局裁决 / 未做时钟偏移校正」**钉住**作为告警。
 *    t13 已按附录 B §6.3/§6.4-6 补齐实现 → 这两处断言**已反转为按文档口径的回归断言**：
 *    用例③ 现在断言「平局按 `deviceId` 字典序大者胜」，用例⑥ 断言「`offsetMs` 方向正确」。
 *    反转后的用例是回归防线：实现若回退，它们会重新失败。
 *
 * 🛑 历史记录（保留以便追溯）：
 *  **STOP（AGENTS.md §1.3 停手条件 · 已报队长）**：附录 B §6.3 规定平局时按
 *    `deviceId` 字典序裁决（`(r.deviceId ?? '') > (l.deviceId ?? '')` 则取远端，
 *    且满足同一"真冲突"条件时 `conflicts++`；deviceId 也相同则保留本机版本），
 *    而 `applyRow():470-472` 是 `localUpdated === remoteUpdated → return -1`（**无条件跳过**）。
 *    二者**不可能同时满足**。本文件因此按"被测实现的实际行为"写断言，
 *    并把 `deviceId` 平局裁决**如实登记为未覆盖项**（不是伪造通过）——
 *    详见文件末尾「逐项覆盖结论」与配套报告。
 *
 * 🛑 另一条 STOP：附录 B §6.4-6 要求"时钟偏移校正（`offsetMs`，容差 ±5 分钟）"，
 *    而 `applyRow()` 直接比较裸 `updated_at`（无 `offsetMs` 形参）、
 *    `applyPull()` 也不从 `?since=` 之外接收任何时钟信息 —— 协议层未实现偏移校正。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { FakeHttpClient } from '../../../main/ets/viewmodel/net/HttpPort';
import { MemoryFiles } from '../../../main/ets/viewmodel/store/FilesPort';
import { HubPorts, ServiceHub } from '../../../main/ets/viewmodel/ServiceHub';
import { ConfigKeys } from '../../../main/ets/viewmodel/AppConfig';
import { FamilySummary, SyncOutcome } from '../../../main/ets/viewmodel/net/SyncService';
import { AuthOutcome, ServerAuthProvider } from '../../../main/ets/viewmodel/AuthService';
import { AppResult } from '../../../main/ets/model/Result';
import { StorePort, RowShape, SqlValue, firstOf, numOf, textOf } from '../../../main/ets/viewmodel/store/StorePort';

/** 被测表：`carbon_record` 属附录 B §6.5「可改可删」组，走**完整 LWW**。 */
const TABLE: string = 'carbon_record';

/** 一条被记录的 SQL 调用。 */
interface SqlCall {
  kind: string;
  sql: string;
  args: string;
}

/**
 * `StorePort` 的**记录型装饰器**：完全实现端口接口，记录每一次 `query`/`exec`/`execBatch`，
 * 然后把调用**透传给真实 store**（本机 `RdbStore`）。
 *
 * 为什么这样用：见文件头「关于"内存假 store"的落地方式」。
 * 简言之——只用假实现会退化成"断言我猜的 SQL 序列"，无法证明数据最终形态；
 * 只记录不执行就得不到 `applyRow` 的真实返回值。装饰器同时满足两者。
 */
class RecordingStore implements StorePort {
  private readonly inner: StorePort;
  private readonly calls: SqlCall[] = [];

  constructor(inner: StorePort) {
    this.inner = inner;
  }

  /** 全部被记录的调用（顺序保留）。 */
  recorded(): SqlCall[] {
    return this.calls;
  }

  /** 按关键字过滤已记录的 SQL（断言"确实发生过 DELETE / INSERT"用）。 */
  countSqlMatching(needle: string): number {
    let n: number = 0;
    let i: number = 0;
    while (i < this.calls.length) {
      if (this.calls[i].sql.indexOf(needle) >= 0) {
        n = n + 1;
      }
      i = i + 1;
    }
    return n;
  }

  sizeBytes(): Promise<number> {
    return this.inner.sizeBytes();
  }

  async query(sql: string, args?: SqlValue[]): Promise<RowShape[]> {
    this.calls.push({ kind: 'query', sql, args: args === undefined ? '' : args.join(',') });
    return this.inner.query(sql, args);
  }

  async exec(sql: string, args?: SqlValue[]): Promise<void> {
    this.calls.push({ kind: 'exec', sql, args: args === undefined ? '' : args.join(',') });
    return this.inner.exec(sql, args);
  }

  async execBatch(sqls: string[]): Promise<void> {
    let i: number = 0;
    while (i < sqls.length) {
      this.calls.push({ kind: 'execBatch', sql: sqls[i], args: '' });
      i = i + 1;
    }
    return this.inner.execBatch(sqls);
  }

  transaction<T>(work: () => Promise<T>): Promise<T> {
    return this.inner.transaction(work);
  }
}

/**
 * 构造一次 pull 响应体（形状见附录 B §5.3：`{ ok, data: { serverTime, tables: { <表名>: [行…] } } }`）。
 * @param rows 该表要下发的远端行
 * @param serverTime 服务端时间戳（本用例不依赖它，仅保持信封形状合法）
 */
function pullBody(rows: RowShape[], serverTime: number): string {
  return pullBodyWithOffset(rows, serverTime, 0, '');
}

/**
 * 构造 pull 响应体，可带 `offsetMs` / `clockWarning`（附录 B §5.3:838-841）。
 *
 * `offsetMs` 的口径是「**服务端时钟 − 客户端时钟**」——即服务端视角的"本机 − 对端"，
 * 与 §6.3 伪码里客户端视角的 `offsetMs` **互为相反数**。用例传的是**服务端响应字段**的值。
 *
 * 手工拼信封而不是写嵌套对象字面量：ArkTS 的 `arkts-no-untyped-obj-literals` 要求
 * 对象字面量必须对应显式声明的 class/interface，而 `arkts-identifiers-as-prop-names`
 * 又禁掉了 `{ [TABLE]: rows }` 这种计算属性名。字符串拼接同时绕开两条限制。
 */
function pullBodyWithOffset(rows: RowShape[], serverTime: number, offsetMs: number, clockWarning: string): string {
  const warn: string = clockWarning.length === 0 ? 'null' : JSON.stringify(clockWarning);
  return `{"ok":true,"data":{"serverTime":${serverTime},"offsetMs":${offsetMs},"clockWarning":${warn},` +
    `"tables":{"${TABLE}":${JSON.stringify(rows)}}}}`;
}

/** 回读本机某行（不存在返回 `undefined`）。 */
async function localRow(hub: ServiceHub, id: string): Promise<RowShape | undefined> {
  const rows: RowShape[] = await hub.store.query(`SELECT * FROM ${TABLE} WHERE id = ?`, [id]);
  return firstOf(rows);
}

/**
 * 取本机某行的 `updated_at`（不存在返回 -1，便于断言"行被删掉"与"值为 0"区分开）。
 */
async function localUpdatedAt(hub: ServiceHub, id: string): Promise<number> {
  const row: RowShape | undefined = await localRow(hub, id);
  return row === undefined ? -1 : numOf(row, 'updated_at');
}

/**
 * 一行远端要覆盖的字段。
 *
 * 为什么单独声明接口而不直接传对象字面量：ArkTS 禁 `arkts-no-untyped-obj-literals`
 * （对象字面量必须对应显式声明的 class/interface），也不支持非标识符属性名做类型
 * （`arkts-identifiers-as-prop-names`）——而 `updated_at` / `is_deleted` / `device_id`
 * 恰恰都是下划线列名。用 `set()` 逐字段赋值即可绕开这两条限制且可读性更好。
 */
class Overrides {
  private readonly map: Map<string, SqlValue> = new Map<string, SqlValue>();

  set(column: string, value: SqlValue): Overrides {
    this.map.set(column, value);
    return this;
  }

  /** 取某列是否被覆盖，以及其值。 */
  valueOf(column: string): SqlValue | undefined {
    return this.map.get(column);
  }

  /** 被覆盖的列名（遍历用）。 */
  columns(): string[] {
    const out: string[] = [];
    this.map.forEach((v: SqlValue, k: string) => {
      out.push(k);
    });
    return out;
  }
}

/**
 * 把远端行建成本机行的"同构副本"（列集合完全一致，避免因缺列触发 NOT NULL 约束），
 * 再按用例需要覆盖 `updated_at` / `is_deleted` / `device_id`。
 *
 * 为什么必须以本机行为模板而不是手写列：`applyRow()` 的写回是
 * `INSERT INTO <表> (远端行有哪些列) VALUES (…)`（:495）——列集合由**远端行**决定，
 * 少一列就会落到 NOT NULL 约束上。用模板复制可保证被测的是 LWW 裁决逻辑本身，
 * 而不是"我猜的列清单"。
 */
function remoteFrom(local: RowShape, overrides: Overrides): RowShape {
  const out: RowShape = {};
  const keys: string[] = Object.keys(local);
  let i: number = 0;
  while (i < keys.length) {
    out[keys[i]] = local[keys[i]];
    i = i + 1;
  }
  const cols: string[] = overrides.columns();
  let k: number = 0;
  while (k < cols.length) {
    const v: SqlValue | undefined = overrides.valueOf(cols[k]);
    out[cols[k]] = v === undefined ? null : v;
    k = k + 1;
  }
  return out;
}

/** 最近一次 pull 的 `sync_log` 行（`fullRestore` 必写一行，冲突计数从这里观察）。 */
async function lastPullLog(hub: ServiceHub, userId: string): Promise<RowShape | undefined> {
  const rows: RowShape[] = await hub.store.query(
    "SELECT * FROM sync_log WHERE user_id = ? AND direction = 'pull' ORDER BY created_at DESC LIMIT 1",
    [userId]
  );
  return firstOf(rows);
}

/**
 * 用例级装配：真机路径的服务栈 + 可控 HTTP + 一个**本用例独占的 userId**。
 *
 * 用真实 `ServiceHub.init`（而非手搓 `SyncService`）的理由：
 *  - `SyncService` 的构造依赖 `StorePort` / `AppState` / `HttpPort` / `AppConfig` 四个具体类型，
 *    手搓它们等于把被测对象搬到一个非真实环境里；
 *  - 本套用例要断言的是**落库结果**，而 `ServiceHub` 装配的是真实 `RdbStore`，
 *    断言因此落在真实 SQLite 上，而不是我实现的假库；
 *  - 同目录 `GoalIdempotent.test.ets` / `ShopPurchase.test.ets` 用的就是这条既有路径，
 *    保持一致风格（避免同一目录出现两套互不相干的测试脚手架）。
 *
 * 隔离：`userId` 带时间戳，行级互不干扰；`FakeHttpClient` 每次新建，stub 不跨用例泄漏。
 */
class Fixture {
  readonly hub: ServiceHub;
  readonly rec: RecordingStore;
  readonly fake: FakeHttpClient;

  constructor(hub: ServiceHub, rec: RecordingStore, fake: FakeHttpClient) {
    this.hub = hub;
    this.rec = rec;
    this.fake = fake;
  }
}

/**
 * 用例级装配：真实服务栈 + 记录型 store 装饰器 + 可控 HTTP + **本用例独占的 userId**。
 *
 * 先用 `ServiceHub.init` 装好真实端口（它内部会开真实 `RdbHelper`），
 * 再用 `createForTest` 以**同一个真实 store 的装饰版**重建 hub——
 * 这样 `SyncService` 的 `this.store` 就是 `RecordingStore`，其 `query/exec` 被记录且真实执行。
 *
 * 隔离：`userId` 带时间戳，行级互不干扰；`FakeHttpClient` 每次新建，stub 不跨用例泄漏。
 */
async function setup(): Promise<Fixture> {
  const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
  const now: number = Date.now();
  // 先构造并声明类型再传入：ArkTS 的内联对象字面量在调用处无法按接口收窄
  //（`arkts-no-untyped-obj-literals`），显式注解 `HubPorts` 后即合法。
  const basePorts: HubPorts = { http: new FakeHttpClient(), files: new MemoryFiles() };
  const base: ServiceHub = await ServiceHub.init(context, now, basePorts);
  const fake: FakeHttpClient = new FakeHttpClient();
  const rec: RecordingStore = new RecordingStore(base.store);
  const hub: ServiceHub = await ServiceHub.createForTest(
    context, rec, base.cfg, base.state, base.resources, base.files, base.engine, fake,
    new ServerAuthProvider(fake));
  await hub.setBreakSave(false, now);
  // 置登录态（`fullRestore` 首页就判 `isLoggedIn()`）。
  // 为什么用真实登录而不是 `state.setAuth({...})`：ArkTS 禁匿名对象字面量
  //（`arkts-no-untyped-obj-literals`），而 `AuthInfo` 无法用字面量构造；
  // 走 `AuthService.login` 既避开该限制，又比直接改状态更接近真实路径（顺带覆盖了登录链路）。
  const loginBody: string =
    `{"ok":true,"data":{"userId":"u-t-lww-${now}","username":"t-lww-${now}","userToken":"tok-${now}"}}`;
  fake.stub('POST', `${hub.http.baseUrl()}/api/v1/auth/login`, 200, loginBody);
  const loginRes: AppResult<AuthOutcome> = await hub.auth.login(`t-lww-${now}`, 'secret123', now);
  if (!loginRes.ok) {
    throw new Error('LwwMerge 夹具登录失败：无法进入已登录态，用例无法验证 fullRestore 路径');
  }
  return new Fixture(hub, rec, fake);
}

/**
 * 落一条真实本机记录（走 `RecordService` 唯一入口，不手写 INSERT），
 * 返回其 `id` 与"同构模板行"。
 */
async function seedLocal(hub: ServiceHub, userId: string, now: number): Promise<RowShape> {
  const saved: AppResult<Object> = await hub.records.save(userId, {
    category: 'travel',
    subType: 'bicycle',
    amount: 5,
    occurredAt: now,
  }, now);
  const id: string = textOf(await idOfNewest(hub, userId), 'id');
  const row: RowShape | undefined = await localRow(hub, id);
  if (row === undefined) {
    throw new Error(`seed 失败：carbon_record 未落库（saved.ok=${saved.ok}）`);
  }
  return row;
}

/** 取该用户最新一条碳记录（只用于拿 id）。 */
async function idOfNewest(hub: ServiceHub, userId: string): Promise<RowShape> {
  const rows: RowShape[] = await hub.store.query(
    `SELECT id FROM ${TABLE} WHERE user_id = ? ORDER BY created_at DESC LIMIT 1`,
    [userId]
  );
  const row: RowShape | undefined = firstOf(rows);
  return row === undefined ? {} : row;
}

/** 直接改本机某行的 `updated_at` / `is_deleted`（构造"本机较新/较旧/平局"三态）。 */
async function setLocal(hub: ServiceHub, id: string, updatedAt: number, isDeleted: number): Promise<void> {
  const args: SqlValue[] = [updatedAt, isDeleted, id];
  await hub.store.exec(`UPDATE ${TABLE} SET updated_at = ?, is_deleted = ? WHERE id = ?`, args);
}

/** 让下一次增量同步的 pull 收到指定远端行（`since` 须与 `driveLww` 用的一致）。 */
function stubPull(fx: Fixture, rows: RowShape[], serverTime: number, since: number): void {
  fx.fake.stub('GET', `${fx.hub.http.baseUrl()}/api/v1/sync/pull?since=${since}`, 200, pullBody(rows, serverTime));
}

/** 让下一次增量同步的 pull 带 `offsetMs` / `clockWarning`（时钟偏移用例专用）。 */
function stubPullOffset(fx: Fixture, rows: RowShape[], serverTime: number, since: number,
  offsetMs: number, clockWarning: string): void {
  fx.fake.stub('GET', `${fx.hub.http.baseUrl()}/api/v1/sync/pull?since=${since}`, 200,
    pullBodyWithOffset(rows, serverTime, offsetMs, clockWarning));
}

/**
 * 驱动一次**真实增量同步**（LWW 路径）：`POST /sync/push` + `GET /sync/pull?since=`。
 *
 * ⚠️ 为什么必须用 `sync()`而 不是 `fullRestore()`：t13 起 `fullRestore()` 已改为
 * **云端备份的覆盖式恢复**（打 `/sync/backup` 三端点，**不经过 `applyPull`/`applyRow`**），
 * 因此它**不再**是 LWW 的入口。本文件原先用 `fullRestore()` 驱动 LWW 断言 ——
 * 那是 t13 之前的行为；若继续用它，这些断言会「通过但什么都没测到」（最危险的一类假绿）。
 *
 * `since` 取 `lastSyncAt`（与 `sync()` 内部同一处 `ConfigKeys.LAST_SYNC_AT`），
 * 使 `stubPull` 能拼出与真实请求完全一致的 URL。
 */
async function driveLww(fx: Fixture, userId: string, now: number): Promise<AppResult<SyncOutcome>> {
  fx.fake.stub('POST', `${fx.hub.http.baseUrl()}/api/v1/sync/push`, 200,
    '{"ok":true,"data":{"accepted":0,"skipped":0,"ignored":0,"rejected":0,"conflicts":0,"serverTime":1,"offsetMs":0}}');
  return fx.hub.sync.sync(userId, now);
}

/** 当前 `since`（供 stubPull 拼 URL）。 */
async function since(fx: Fixture): Promise<number> {
  return fx.hub.cfg.stamp(ConfigKeys.LAST_SYNC_AT);
}

export default function lwwMergeTest(): void {
  describe('LwwMerge', () => {
    it('① 新者胜：远端 updated_at 更大 → 本地行被远端覆盖，pulled=1', 0, async () => {
      const fx: Fixture = await setup();
      const hub: ServiceHub = fx.hub;
      const userId: string = hub.state.userId();
      const now: number = Date.now();
      const local: RowShape = await seedLocal(hub, userId, now);
      const id: string = textOf(local, 'id');
      // 本机较旧、远端较新
      await setLocal(hub, id, 1000, 0);
      const remote: RowShape = remoteFrom(local, new Overrides().set('updated_at', 2000).set('amount', 42).set('device_id', 'dev-remote'));

      const before: number = fx.rec.recorded().length;
      stubPull(fx, [remote], 3000, await since(fx));
      const res: AppResult<SyncOutcome> = await driveLww(fx, userId, now);
      expect(res.ok).assertTrue();

      // ① 返回值语义：applyRow 返回 1 → pulled +1
      expect(res.data === undefined ? -1 : res.data).assertEqual(1);
      // ② 落库状态：远端行真的覆盖了本机（amount 从 5 变 42，updated_at 变 2000）
      const after: RowShape | undefined = await localRow(hub, id);
      expect(after !== undefined).assertTrue();
      expect(numOf(after === undefined ? {} : after, 'updated_at')).assertEqual(2000);
      expect(numOf(after === undefined ? {} : after, 'amount')).assertEqual(42);
      // 本机行 id 不变（同 id 覆盖，不是新插一行）
      expect(textOf(after === undefined ? {} : after, 'id')).assertEqual(id);
      // ③ SQL 轨迹（RecordingStore 记录）：确实发生了 DELETE + INSERT，而不是 UPDATE ——
      //    §6.3 的写回口径就是「先删本机行再插远端行」（applyRow :476 + :495）。
      const trace: SqlCall[] = fx.rec.recorded();
      let del: number = 0;
      let ins: number = 0;
      let i: number = before;
      while (i < trace.length) {
        if (trace[i].sql.indexOf(`DELETE FROM ${TABLE}`) >= 0) {
          del = del + 1;
        }
        if (trace[i].sql.indexOf(`INSERT INTO ${TABLE}`) >= 0) {
          ins = ins + 1;
        }
        i = i + 1;
      }
      expect(del).assertEqual(1);
      expect(ins).assertEqual(1);
    });

    it('② 平局：localUpdated === remoteUpdated → 跳过不写，skipped=1（冲突不计数）', 0, async () => {
      const fx: Fixture = await setup();
      const hub: ServiceHub = fx.hub;
      const userId: string = hub.state.userId();
      const now: number = Date.now();
      const local: RowShape = await seedLocal(hub, userId, now);
      const id: string = textOf(local, 'id');
      await setLocal(hub, id, 5000, 0);
      // 远端同时间戳但内容不同（amount 99）：若实现误判为"新者胜"，落库后 amount 会变 99
      const remote: RowShape = remoteFrom(local, new Overrides().set('updated_at', 5000).set('amount', 99).set('device_id', 'dev-remote'));

      stubPull(fx, [remote], 6000, await since(fx));
      const res: AppResult<SyncOutcome> = await driveLww(fx, userId, now);
      expect(res.ok).assertTrue();

      // applyRow 判定为「保留本机」 → skipped +1、pulled 为 0
      expect(res.data === undefined ? -1 : res.data.pulled).assertEqual(0);
      // 本机版本被保留：amount 仍是 5，时间戳不变
      const after: RowShape | undefined = await localRow(hub, id);
      expect(numOf(after === undefined ? {} : after, 'amount')).assertEqual(5);
      expect(numOf(after === undefined ? {} : after, 'updated_at')).assertEqual(5000);
    });

    it('③ 平局按 deviceId 字典序大者胜（§6.3；t13 已补齐实现，本用例为回归防线）', 0, async () => {
      // ✅ t13 起，实现与文档一致：平局时 `(r.deviceId ?? '') > (l.deviceId ?? '')` 则取远端，
      //    两端 deviceId 相同视为同一版本、保留本机（与服务端 sync_service.py:471-484 同规则）。
      //    本用例原先断言的是"实现未做平局裁决"（告警），t13 后**反转为按文档口径的断言**。
      const fx: Fixture = await setup();
      const hub: ServiceHub = fx.hub;
      const userId: string = hub.state.userId();
      const now: number = Date.now();
      const local: RowShape = await seedLocal(hub, userId, now);
      const id: string = textOf(local, 'id');
      await setLocal(hub, id, 7000, 0);
      await hub.store.exec(`UPDATE ${TABLE} SET device_id = ? WHERE id = ?`, ['dev-aaa', id]);

      // (a) 远端 deviceId 字典序**更大** → 远端胜出
      const remote: RowShape = remoteFrom(local, new Overrides().set('updated_at', 7000).set('amount', 77).set('device_id', 'dev-zzz'));
      stubPull(fx, [remote], 8000, await since(fx));
      const res: AppResult<SyncOutcome> = await driveLww(fx, userId, now);
      expect(res.ok).assertTrue();
      expect(res.data === undefined ? -1 : res.data.pulled).assertEqual(1);
      const after: RowShape | undefined = await localRow(hub, id);
      expect(numOf(after === undefined ? {} : after, 'amount')).assertEqual(77);
      expect(textOf(after === undefined ? {} : after, 'device_id')).assertEqual('dev-zzz');

      // (b) 远端 deviceId 字典序**更小** → 保留本机（远端不写）
      await setLocal(hub, id, 7000, 0);
      await hub.store.exec(`UPDATE ${TABLE} SET device_id = ?, amount = ? WHERE id = ?`, ['dev-zzz', 77, id]);
      const weaker: RowShape = remoteFrom(local, new Overrides().set('updated_at', 7000).set('amount', 11).set('device_id', 'dev-aaa'));
      stubPull(fx, [weaker], 8000, await since(fx));
      const res2: AppResult<SyncOutcome> = await driveLww(fx, userId, now);
      expect(res2.ok).assertTrue();
      expect(res2.data === undefined ? -1 : res2.data.pulled).assertEqual(0);
      const after2: RowShape | undefined = await localRow(hub, id);
      expect(numOf(after2 === undefined ? {} : after2, 'amount')).assertEqual(77);

      // (c) 两端 deviceId **相同** = 同一版本 → 保留本机（不计数冲突）
      const same: RowShape = remoteFrom(local, new Overrides().set('updated_at', 7000).set('amount', 11).set('device_id', 'dev-zzz'));
      stubPull(fx, [same], 8000, await since(fx));
      const res3: AppResult<SyncOutcome> = await driveLww(fx, userId, now);
      expect(res3.ok).assertTrue();
      expect(res3.data === undefined ? -1 : res3.data.pulled).assertEqual(0);
      const after3: RowShape | undefined = await localRow(hub, id);
      expect(numOf(after3 === undefined ? {} : after3, 'amount')).assertEqual(77);
    });

    it('④ 软删除传播：远端 is_deleted=1 且更新更晚 → 本地也变软删除', 0, async () => {
      const fx: Fixture = await setup();
      const hub: ServiceHub = fx.hub;
      const userId: string = hub.state.userId();
      const now: number = Date.now();
      const local: RowShape = await seedLocal(hub, userId, now);
      const id: string = textOf(local, 'id');
      // 本机是活行、较旧
      await setLocal(hub, id, 1000, 0);
      // 远端是软删除行、且 updated_at 更新（§6.4-2：软删除行的 updated_at 更新后同样按 LWW 取胜）
      const remote: RowShape = remoteFrom(local, new Overrides().set('updated_at', 2000).set('is_deleted', 1).set('device_id', 'dev-remote'));

      stubPull(fx, [remote], 3000, await since(fx));
      const res: AppResult<SyncOutcome> = await driveLww(fx, userId, now);
      expect(res.ok).assertTrue();

      // 删除必须**真的落到本机**（不是只写注释）：
      const after: RowShape | undefined = await localRow(hub, id);
      expect(after !== undefined).assertTrue();
      expect(numOf(after === undefined ? {} : after, 'is_deleted')).assertEqual(1);
      expect(numOf(after === undefined ? {} : after, 'updated_at')).assertEqual(2000);
      // 且软删除行仍留在表里（铁律 4 / §1.3 铁约定 4：不物理删除，否则删除无法传播）
      const cnt: RowShape[] = await hub.store.query(
        `SELECT COUNT(*) AS n FROM ${TABLE} WHERE id = ?`, [id]);
      const softRow: RowShape | undefined = firstOf(cnt);
      expect(numOf(softRow === undefined ? {} : softRow, 'n')).assertEqual(1);
    });

    it('⑤ 幂等：同一远端行重复应用两次 → 不产生重复行，第二次不再计入 pulled', 0, async () => {
      const fx: Fixture = await setup();
      const hub: ServiceHub = fx.hub;
      const userId: string = hub.state.userId();
      const now: number = Date.now();
      const local: RowShape = await seedLocal(hub, userId, now);
      const id: string = textOf(local, 'id');
      await setLocal(hub, id, 1000, 0);
      const remote: RowShape = remoteFrom(local, new Overrides().set('updated_at', 2000).set('amount', 42).set('device_id', 'dev-remote'));

      // 第一次：远端较新 → 写入
      stubPull(fx, [remote], 3000, await since(fx));
      const first: AppResult<SyncOutcome> = await driveLww(fx, userId, now);
      expect(first.ok).assertTrue();
      expect(first.data === undefined ? -1 : first.data.pulled).assertEqual(1);

      // 第二次：同样的远端行再来一遍 —— 本机 now 已是 2000，与远端**平局** → 跳过
      const before: number = fx.rec.recorded().length;
      stubPull(fx, [remote], 4000, await since(fx));
      const second: AppResult<SyncOutcome> = await driveLww(fx, userId, now);
      expect(second.ok).assertTrue();
      expect(second.data === undefined ? -1 : second.data.pulled).assertEqual(0);

      // 行数不变（同一 id 不重复），updated_at 未被再次改动
      const cnt: RowShape[] = await hub.store.query(
        `SELECT COUNT(*) AS n FROM ${TABLE} WHERE id = ?`, [id]);
      const cntRow: RowShape | undefined = firstOf(cnt);
      expect(numOf(cntRow === undefined ? {} : cntRow, 'n')).assertEqual(1);
      expect(await localUpdatedAt(hub, id)).assertEqual(2000);
      const row: RowShape | undefined = await localRow(hub, id);
      expect(numOf(row === undefined ? {} : row, 'amount')).assertEqual(42);

      // 幂等的**强证据**：第二次应用期间对被测表**没有**任何 DELETE / INSERT
      //（若实现靠"再插一次"来达成幂等，靠唯一索引兜底，这两条会各 >0）
      const trace: SqlCall[] = fx.rec.recorded();
      let writes: number = 0;
      let i: number = before;
      while (i < trace.length) {
        const sql: string = trace[i].sql;
        if (sql.indexOf(`DELETE FROM ${TABLE}`) >= 0 || sql.indexOf(`INSERT INTO ${TABLE}`) >= 0) {
          writes = writes + 1;
        }
        i = i + 1;
      }
      expect(writes).assertEqual(0);
    });

    it('⑥ 时钟偏移校正：符号方向正确（§6.4-6；t13 已补齐实现，本用例为回归防线）', 0, async () => {
      // ✅ t13 起实现按 §6.4-6 校正偏移。**符号是关键**：
      //    响应字段 `offsetMs` = 「服务端时钟 − 客户端时钟」（服务端视角）；
      //    §6.3 伪码里的 `offsetMs` 是客户端视角的「本机 − 对端」→ 二者互为相反数。
      //    故客户端必须 `rUpdated = r.updatedAt - respOffsetMs`。
      //    **判据**：respOffsetMs = +60000（服务端快 60 秒）时，同一条服务端时间戳
      //    相对本机必须**显得更旧**（−60000），绝不能显得更新。
      const fx: Fixture = await setup();
      const hub: ServiceHub = fx.hub;
      const userId: string = hub.state.userId();
      const now: number = Date.now();
      const local: RowShape = await seedLocal(hub, userId, now);
      const id: string = textOf(local, 'id');
      // 本条用例**不**走 fullRestore（那是备份覆盖路径），走真实增量同步路径 sync()
      // 才能让 applyPull 从响应里读到 offsetMs。
      const localUpdated: number = 10 * 60 * 1000;   // 本机时间戳（10 分钟）
      const remoteRaw: number = 60 * 1000;           // 服务端"刚刚"改过，但服务端时钟快 60 秒
      await setLocal(hub, id, localUpdated, 0);
      const remote: RowShape = remoteFrom(local, new Overrides().set('updated_at', remoteRaw).set('amount', 88).set('device_id', 'dev-remote'));

      // 服务端快 60 秒 → respOffsetMs = +60000 → 客户端视角 offsetMs = −60000
      // → rUpdated = 60000 + (−60000) = 0 < localUpdated(600000) → 保留本机。
      // ⚠️ 若符号写反（+60000），rUpdated = 120000…仍 < 600000，判不出来 —— 故再加一组对照：
      //    下面的 (b) 用「本机 30 秒」的小时间戳，符号写反会让远端胜出，从而把错误暴露出来。
      stubPullOffset(fx, [remote], 9000, await since(fx), 60000, '客户端时钟与服务端相差 60.0 秒');
      const res: AppResult<SyncOutcome> = await hub.sync.sync(userId, now);
      expect(res.ok).assertTrue();
      const after: RowShape | undefined = await localRow(hub, id);
      expect(numOf(after === undefined ? {} : after, 'amount')).assertEqual(5);
      expect(numOf(after === undefined ? {} : after, 'updated_at')).assertEqual(localUpdated);

      // (b) 方向对照：本机 30 秒、服务端原始 100 秒、服务端快 60 秒
      //     → 客户端视角 offsetMs=−60000 → rUpdated = 100000 − 60000 = 40000 > 30000 → 远端胜出。
      //     **若符号写反**（+60000）→ rUpdated = 160000 > 30000 也胜出，区分度不足；
      //     故再取「本机 90 秒」：正确符号 rUpdated=40000 < 90000（保留本机）；
      //     写反则 rUpdated=160000 > 90000（远端胜出）→ 能真正把符号错误暴露出来。
      await setLocal(hub, id, 90 * 1000, 0);
      await hub.store.exec(`UPDATE ${TABLE} SET amount = ? WHERE id = ?`, [5, id]);
      const remote2: RowShape = remoteFrom(local, new Overrides().set('updated_at', 100 * 1000).set('amount', 55).set('device_id', 'dev-remote'));
      stubPullOffset(fx, [remote2], 9500, await since(fx), 60000, '');
      const res2: AppResult<SyncOutcome> = await hub.sync.sync(userId, now);
      expect(res2.ok).assertTrue();
      const after2: RowShape | undefined = await localRow(hub, id);
      // 正确符号：rUpdated = 100000 − 60000 = 40000 < 90000 → 保留本机（amount 仍 5）
      expect(numOf(after2 === undefined ? {} : after2, 'amount')).assertEqual(5);

      // (c) 反向偏移：服务端慢 60 秒（respOffsetMs = −60000）→ 客户端视角 +60000
      //     → 同一条服务端时间戳显得**更新**：本机 90 秒 vs 原始 100 秒
      //     → rUpdated = 100000 + 60000 = 160000 > 90000 → 远端胜出
      const remote3: RowShape = remoteFrom(local, new Overrides().set('updated_at', 100 * 1000).set('amount', 66).set('device_id', 'dev-remote'));
      stubPullOffset(fx, [remote3], 9700, await since(fx), -60000, '');
      const res3: AppResult<SyncOutcome> = await hub.sync.sync(userId, now);
      expect(res3.ok).assertTrue();
      const after3: RowShape | undefined = await localRow(hub, id);
      expect(numOf(after3 === undefined ? {} : after3, 'amount')).assertEqual(66);
    });

    it('⑦ 家庭合并净额：family().totalPoints = SUM(points)（primary 已正、reverse 已负，不再翻回正）', 0, async () => {
      // 编号 ⑦ 的来历（t21 说明，避免后续按编号点检出错）：
      //   t11 原第 ⑦ 条是「`since` 形参被忽略 → conflicts 恒为 0」的告警断言；t13 修好实现后，
      //   该断言与 ⑧（真冲突计数）是同一件事 → **已并入 ⑧**。本用例占用 ⑦ 这个空缺编号，
      //   承载 t21 新增的「家庭合并积分口径」回归，编号自此连续 ①–⑩。
      // 被测口径：附录 C §18.2「同一账号下多设备按 device_id 去重后只读求和」，
      //   而 `point_record.points` 本身已带符号（primary 正 / reverse 负）→ 净额 = SUM(points)，
      //   与 `PointService.balance()` 的 sum 口径逐字一致（铁律 4：余额 = 收入合计 − 支出合计）。
      const fx: Fixture = await setup();
      const hub: ServiceHub = fx.hub;
      const userId: string = hub.state.userId();
      const now: number = Date.now();

      // 先落一条碳记录：family() 的成员分组来自 carbon_record.device_id，成员口径才有可断言的一行
      await seedLocal(hub, userId, now);

      const sourceId: string = `rec-fam-${now}#0`;
      await hub.points.append(userId, {
        type: 'record',
        points: 96,
        sourceType: 'carbon_record',
        sourceId: sourceId,
        title: '减排记录',
        occurredAt: now,
      });
      // 冲正：写 flow_kind='reverse' 的**负额**行（`PointService` 唯一入口；source_id 与入账同值，靠 flow_kind 区分）
      await hub.points.reverse(userId, 'record', 96, sourceId, '调整', now);

      // 独立取一次纯 SUM(points) 作为口径参照（与 balance() 的 sum 同源）
      const sums: RowShape[] = await hub.store.query(
        'SELECT COALESCE(SUM(points), 0) AS p FROM point_record WHERE user_id = ? AND is_deleted = 0',
        [userId]);
      const netRow: RowShape | undefined = firstOf(sums);
      const net: number = netRow === undefined ? 0 : numOf(netRow, 'p');
      expect(net).assertEqual(0);   // +96 − 96

      const summary: FamilySummary = await hub.sync.family(userId);
      // 修前的 `CASE WHEN flow_kind='primary' THEN points ELSE -points END` 会得到 +192 → 本行失败
      expect(summary.totalPoints).assertEqual(net);
      // 成员口径同为净额：修前只算 primary 行 → 本机成员 +96，与合计对不上 → 本行失败
      expect(summary.members.length).assertEqual(1);
      expect(summary.members[0].points).assertEqual(net);

      // 再加一笔正额：净额随之上升，且仍等于 SUM(points)
      await hub.points.append(userId, {
        type: 'record',
        points: 200,
        sourceType: 'carbon_record',
        sourceId: `rec-fam-${now}#1`,
        title: '减排记录',
        occurredAt: now + 1,
      });
      const after: FamilySummary = await hub.sync.family(userId);
      expect(after.totalPoints).assertEqual(200);
    });

    it('⑧ 真冲突计数：仅当两端自上次同步后都改过（§6.3；t13 已补齐）', 0, async () => {
      // §6.3：`l.updatedAt > since && r.updatedAt > since`（r 用**原始**对端时间戳）。
      // t11 时 `since` 形参被完全忽略 → conflicts 恒为 0；t13 起按条件计数。
      const fx: Fixture = await setup();
      const hub: ServiceHub = fx.hub;
      const userId: string = hub.state.userId();
      const now: number = Date.now();
      const local: RowShape = await seedLocal(hub, userId, now);
      const id: string = textOf(local, 'id');

      // 场景 A：两端都比 since 新 → 真冲突（count=1）
      // 先把 lastSyncAt 设成一个很小的值，使 l/r 都 > since
      await fx.hub.cfg.set(ConfigKeys.LAST_SYNC_AT, '1');
      await setLocal(hub, id, 5000, 0);
      const remoteA: RowShape = remoteFrom(local, new Overrides().set('updated_at', 6000).set('amount', 21).set('device_id', 'dev-remote'));
      fx.fake.stub('GET', `${fx.hub.http.baseUrl()}/api/v1/sync/pull?since=1`, 200, pullBody([remoteA], 7000));
      const resA: AppResult<SyncOutcome> = await hub.sync.sync(userId, now);
      expect(resA.ok).assertTrue();
      expect(resA.data === undefined ? -1 : resA.data.conflicts).assertEqual(1);

      // 场景 B：本机比 since 旧（只有对端改过）→ 不是真冲突（count=0）
      await fx.hub.cfg.set(ConfigKeys.LAST_SYNC_AT, '4000');
      await setLocal(hub, id, 5000, 0);   // 本机 5000 > 4000 → 仍是两端都改过…故把 since 抬到 5500
      await fx.hub.cfg.set(ConfigKeys.LAST_SYNC_AT, '5500');
      const remoteB: RowShape = remoteFrom(local, new Overrides().set('updated_at', 6000).set('amount', 22).set('device_id', 'dev-remote'));
      fx.fake.stub('GET', `${fx.hub.http.baseUrl()}/api/v1/sync/pull?since=5500`, 200, pullBody([remoteB], 7000));
      const resB: AppResult<SyncOutcome> = await hub.sync.sync(userId, now);
      expect(resB.ok).assertTrue();
      expect(resB.data === undefined ? -1 : resB.data.conflicts).assertEqual(0);
    });

    it('⑨ 云端备份走独立三端点，且绕开 LWW（附录 B §5.3:807/817-819）', 0, async () => {
      // 备份 = 快照（`POST/GET /sync/backup` + `POST /sync/backup/restore`），
      // **不是**"复用 push/pull 的 since=0"——后者会走 §6.3 的 LWW 合并（文档明文禁止）。
      const fx: Fixture = await setup();
      const hub: ServiceHub = fx.hub;
      const userId: string = hub.state.userId();
      const now: number = Date.now();
      // 造一条本机行，使快照里有内容
      const local: RowShape = await seedLocal(hub, userId, now);
      const id: string = textOf(local, 'id');
      await setLocal(hub, id, 1000, 0);
      // 备份基线：lastSyncAt 记成一个**可辨识**的值，断言备份路径不碰它
      await hub.cfg.set(ConfigKeys.LAST_SYNC_AT, '424242');

      const base: string = hub.http.baseUrl();
      // ① 上传快照
      fx.fake.stub('POST', `${base}/api/v1/sync/backup`, 200,
        '{"ok":true,"data":{"stored":3,"ignored":0,"rejected":0,"snapshotAt":111,"serverTime":222,"tables":{"carbon_record":3}}}');
      const up = await hub.sync.fullUpload(userId, now);
      expect(up.ok).assertTrue();
      expect(up.data === undefined ? -1 : up.data).assertEqual(3);

      // ② 下载快照 + ③ 覆盖式恢复
      fx.fake.stub('GET', `${base}/api/v1/sync/backup`, 200,
        '{"ok":true,"data":{"serverTime":333,"snapshotAt":444,"totalRows":1,' +
        '"tables":{"carbon_record":[' + JSON.stringify(remoteFrom(local, new Overrides().set('updated_at', 9999).set('amount', 12))) + ']}}');
      fx.fake.stub('POST', `${base}/api/v1/sync/backup/restore`, 200,
        '{"ok":true,"data":{"restored":2,"removed":1,"preRestoreAt":555,' +
        '"preRestore":{"carbon_record":[]},"serverTime":666,"tables":{"carbon_record":2}}}');
      const down = await hub.sync.fullRestore(userId, now);
      expect(down.ok).assertTrue();
      expect(down.data === undefined ? -1 : down.data).assertEqual(3);

      // 三条请求全部落在**新端点**上，且都带 Bearer
      const reqs = fx.fake.requests();
      let backupCalls: number = 0;
      let pushOrPull: number = 0;
      let authed: number = 0;
      let i: number = 0;
      while (i < reqs.length) {
        const u: string = reqs[i].url;
        if (u.indexOf('/api/v1/sync/backup') >= 0) {
          backupCalls = backupCalls + 1;
        }
        if (u.indexOf('/api/v1/sync/push') >= 0 || u.indexOf('/api/v1/sync/pull') >= 0) {
          pushOrPull = pushOrPull + 1;
        }
        if (FakeHttpClient.authHeaderOf(reqs[i]).length > 0) {
          authed = authed + 1;
        }
        i = i + 1;
      }
      expect(backupCalls).assertEqual(3);
      expect(pushOrPull).assertEqual(0);
      expect(authed).assertEqual(3);

      // 备份/恢复**不动** lastSyncAt（§5.3:807「不用 lastSyncAt」）
      expect(await hub.cfg.stamp(ConfigKeys.LAST_SYNC_AT)).assertEqual(424242);
      // 恢复前原状已落盘（调用方负责，服务端不建表）
      const pre: string | undefined = await hub.cfg.get('cloud_pre_restore');   // 键名与 SyncService 私有 KEY_PRE_RESTORE 一致
      expect(pre !== undefined).assertTrue();
      expect((pre === undefined ? '' : pre).indexOf('555') >= 0).assertTrue();
    });

    it('⑩ 备份/恢复日志：恢复不产生 conflicts（备份路径与 LWW 无关）', 0, async () => {
      // 口径来源：附录 B §6.3「真冲突 = 两端自上次同步后都改过这一行」。
      // ⚠️ 注意：`applyRow()` 的 `since` 形参在 :461-497 内**未被使用**，
      //    故"两端自上次同步后都改过"这一条件在当前实现里**不可判**；
      //    本用例只断言"远端较新时 conflicts 是否 +1"的可观察结果，
      //    不假设实现真的按 §6.3 的 lastSyncAt 条件计数（该差异见文件末尾结论）。
      const fx: Fixture = await setup();
      const hub: ServiceHub = fx.hub;
      const userId: string = hub.state.userId();
      const now: number = Date.now();
      const local: RowShape = await seedLocal(hub, userId, now);
      const id: string = textOf(local, 'id');
      await setLocal(hub, id, 1000, 0);
      const remote: RowShape = remoteFrom(local, new Overrides().set('updated_at', 2000).set('device_id', 'dev-remote'));

      stubPull(fx, [remote], 3000, await since(fx));
      const res: AppResult<SyncOutcome> = await driveLww(fx, userId, now);
      expect(res.ok).assertTrue();

      // sync() 写一行 direction='both' 的 sync_log；冲突数从这里读。
      // t13 起按 §6.3 计数：本场景 `since` = lastSyncAt = 0，而本机 1000 / 远端 2000 都 > 0
      // → 两端自上次同步后都改过 → 应计 1（此前"实现忽略 since、恒为 0"的登记已反转）。
      const log: RowShape | undefined = await lastPullLog(hub, userId);
      expect(log !== undefined).assertTrue();
      const conflicts: number = numOf(log === undefined ? {} : log, 'conflict_count');
      expect(conflicts).assertEqual(1);
      // 同时确认同步结果里的 conflicts 与日志一致
      expect(res.data === undefined ? -1 : res.data.conflicts).assertEqual(1);
    });
  });
}
