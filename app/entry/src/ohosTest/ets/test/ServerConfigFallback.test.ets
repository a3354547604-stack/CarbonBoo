/**
 * ServerConfigFallback —— L1 单测：后台系统配置的「整份生效 / 整份丢弃」与三项下行值的真实生效
 * （附录 B §5.5，验收 D10-5）。
 *
 * 被测对象是**真实实现**（没有为可测性改被测代码）：
 *  ① `viewmodel/net/ServerConfigFetcher.ets`：`fetchAndStore()` / `effective()` / `effectiveFrom()`；
 *  ② `viewmodel/ServiceHub.ets`：`fetchServerConfig()` 与「下行封顶值装进 `CarbonCalc` 镜像」的接线；
 *  ③ `viewmodel/RewardService.ets`：`goalRewards` 按 `goalId` 覆盖、`badgesEnabled` 总开关；
 *  ④ `service/CarbonCalc.ets`：`actualPointOf` / `effectiveDailyCap`（缺省封顶取下行值）。
 * 网络用既有的 `FakeHttpClient`（窄端口 `HttpPort` 的用例实现）注入，
 * `app_config` / `goal_def` / `user_badge` 全部走真实 `RdbStore`。
 *
 * 覆盖的契约原文（附录 B §5.5）：
 * 「启动时拉一次 `GET /api/v1/config`（**鉴权：无**）；`version` / `pointsDailyCap` /
 *  `badgesEnabled` / `goalRewards` / `serverTime` 任一字段非法 → **整份丢弃**，沿用上一份有效值；
 *  从未成功拉到过 → 用 App 内置 rawfile 种子（封顶 200 + 徽章启用 + `goal-defs.json` 的 reward）；
 *  `version` 与上一份相同 → 跳过写入；桥接到本地只用 `app_config` 一个键。」
 *
 * ⚠️ **本机未运行**（如实声明，绝不声称用例通过）：hypium 需由 SDK 的 Previewer / 真机 / 模拟器
 * 进程驱动，本机无真机、无模拟器（SDK 预览器二进制与本机 glibc 不兼容）。
 * 本文件的证据只有：① 随 `ohosTest` 目标编译通过
 * （`hvigorw --no-daemon --mode module -p module=entry@ohosTest -p buildMode=test assembleHap`）；
 * ② 人工代码审查。
 */
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { FakeHttpClient, HttpPort, HttpRequest, HttpResponse } from '../../../main/ets/viewmodel/net/HttpPort';
import { ServerConfigFetcher, ServerConfig, ServerConfigOutcome } from '../../../main/ets/viewmodel/net/ServerConfigFetcher';
import { MemoryFiles } from '../../../main/ets/viewmodel/store/FilesPort';
import { ServiceHub } from '../../../main/ets/viewmodel/ServiceHub';
import { AppConfig, ConfigKeys } from '../../../main/ets/viewmodel/AppConfig';
import { AppResult } from '../../../main/ets/model/Result';
import { CarbonCalc, CalcEvaluation, FactorSnapshot } from '../../../main/ets/service/CarbonCalc';
import { AppConstants } from '../../../main/ets/util/AppConstants';
import { GoalCard } from '../../../main/ets/viewmodel/domain/RewardEngine';
import { BadgeDef } from '../../../main/ets/model/BadgeTypes';
import { RowShape, firstOf, numOf } from '../../../main/ets/viewmodel/store/StorePort';

/** 端点（与生产同一拼法：`http.baseUrl() + '/api/v1/config'`）。 */
const PATH: string = '/api/v1/config';

/** 服务端时钟（固定值，只用来断言"整份"里带上了它）。 */
const SERVER_TIME: number = 1762396800000;

/** 一份**合法**的配置响应（结构照抄附录 B §5.5 的 jsonc 示例）。 */
function okBody(version: string, cap: number, badgesEnabled: boolean, goalRewards: string): string {
  return `{"ok":true,"data":{"version":"${version}","pointsDailyCap":${cap},` +
    `"badgesEnabled":${badgesEnabled ? 'true' : 'false'},"goalRewards":${goalRewards},` +
    `"serverTime":${SERVER_TIME}}}`;
}

/** 组装夹具（真实服务栈 + 可控 HTTP；`app_config` 走真实库）。 */
class Fixture {
  readonly hub: ServiceHub;
  readonly fake: FakeHttpClient;
  readonly cfg: AppConfig;

  constructor(hub: ServiceHub, fake: FakeHttpClient, cfg: AppConfig) {
    this.hub = hub;
    this.fake = fake;
    this.cfg = cfg;
  }
}

async function setup(): Promise<Fixture> {
  const context: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
  const now: number = Date.now();
  const fake: FakeHttpClient = new FakeHttpClient();
  const hub: ServiceHub = await ServiceHub.init(context, now, { http: fake, files: new MemoryFiles() });
  return new Fixture(hub, fake, hub.cfg);
}

/** 网络层直接抛错的端口：验证 `fetchAndStore()` **从不把异常抛给调用方**。 */
class BoomHttp implements HttpPort {
  baseUrl(): string {
    return 'http://127.0.0.1:8000';
  }

  async request(req: HttpRequest): Promise<HttpResponse> {
    throw new Error(`boom: ${req.url}`);
  }
}

/** `app_config['server_config']` 原文（断言"整份丢弃"就是断言它没变）。 */
async function storedConfig(cfg: AppConfig): Promise<string | undefined> {
  return cfg.get(ConfigKeys.SERVER_CONFIG);
}

/** 从 `GoalCard[]` 里取某个目标的奖励分（取不到返回 -1）。 */
function rewardOfCard(cards: GoalCard[], goalId: string): number {
  let i: number = 0;
  while (i < cards.length) {
    if (cards[i].goalId === goalId) {
      return cards[i].reward;
    }
    i = i + 1;
  }
  return -1;
}

export default function serverConfigFallbackTest(): void {
  describe('ServerConfigFallback', () => {
    it('① 成功 → 整份覆盖 app_config[server_config]（五项字段齐全、免 token、封顶真实生效）', 0, async () => {
      const fx: Fixture = await setup();
      fx.fake.stub('GET', `${fx.fake.baseUrl()}${PATH}`, 200,
        okBody('2026.11.06-1', 120, true, '[{"goalId":"S1","reward":999}]'));

      const res: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(res.ok).assertTrue();
      expect(res.data === undefined ? false : res.data.applied).assertTrue();
      expect(res.data === undefined ? '' : res.data.version).assertEqual('2026.11.06-1');
      expect(res.data === undefined ? -1 : res.data.pointsDailyCap).assertEqual(120);
      expect(res.data === undefined ? -1 : res.data.goalRewardCount).assertEqual(1);
      // 鉴权：无（附录 B §5.5 明文）—— 唯一与取价同组的免 token 端点
      expect(fx.fake.countWithAuth()).assertEqual(0);
      expect(fx.fake.count()).assertEqual(1);

      const raw: string | undefined = await storedConfig(fx.cfg);
      expect(raw !== undefined).assertTrue();
      const text: string = raw === undefined ? '' : raw;
      expect(text.indexOf('"version":"2026.11.06-1"') >= 0).assertTrue();
      expect(text.indexOf('"pointsDailyCap":120') >= 0).assertTrue();
      expect(text.indexOf('"badgesEnabled":true') >= 0).assertTrue();
      expect(text.indexOf('"goalRewards"') >= 0).assertTrue();
      expect(text.indexOf('"serverTime"') >= 0).assertTrue();
      // 版本号可读回（读取侧与写入侧共用同一套整份校验）
      const eff: ServerConfig | undefined = await ServerConfigFetcher.effective(fx.cfg);
      expect(eff === undefined ? '' : eff.version).assertEqual('2026.11.06-1');
      expect(eff === undefined ? -1 : eff.pointsDailyCap).assertEqual(120);

      // **封顶值真实生效**：调用点（RecordService.doSave → CarbonService.calculate）只传
      // todayRecordPoint，cap 缺省 → 必须取到下行值 120（若恒取内置 200，这里会是 100）
      expect(CarbonCalc.effectiveDailyCap()).assertEqual(120);
      expect(CarbonCalc.actualPointOf(200, 100)).assertEqual(20);
    });

    it('② 封顶值：未下发 → 内置 200；不传参与显式传参两条用例', 0, async () => {
      const fx: Fixture = await setup();
      // 复位镜像（用例之间互不影响）：没有下行值 = 内置 200
      CarbonCalc.installDailyCap(undefined);
      expect(CarbonCalc.effectiveDailyCap()).assertEqual(AppConstants.DAILY_RECORD_CAP);
      // 不传参 → 内置 200（`tests/cases/carbon-calc.json` 的封顶样例语义一字不变）
      expect(CarbonCalc.actualPointOf(200, 0)).assertEqual(200);
      expect(CarbonCalc.actualPointOf(200, 150)).assertEqual(50);

      // 下发 120 之后
      fx.fake.stub('GET', `${fx.fake.baseUrl()}${PATH}`, 200, okBody('v-cap-120', 120, true, '[]'));
      const res: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(res.ok).assertTrue();
      expect(CarbonCalc.effectiveDailyCap()).assertEqual(120);
      // 不传参 → 用下行值
      expect(CarbonCalc.actualPointOf(200, 100)).assertEqual(20);
      expect(CarbonCalc.actualPointOf(200, 120)).assertEqual(0);
      // 显式传参 → 传参优先（离线复算脚本与用例完全可控）
      expect(CarbonCalc.actualPointOf(200, 100, 200)).assertEqual(100);
      expect(CarbonCalc.actualPointOf(200, 150, 200)).assertEqual(50);
      expect(CarbonCalc.actualPointOf(300, 250, 200)).assertEqual(0);

      // 整条评估链（`evaluate` 的 cap 缺省路径）同样按下行值封顶
      const snap: FactorSnapshot = {
        factorValue: 0.05, factorVersion: 'CF-2026.2', factorSource: 'SRC-DERIVED', confidence: 'provisional',
      };
      const ev: CalcEvaluation = CarbonCalc.evaluate('travel', 'metro', 10, snap, { todayRecordPoint: 100 });
      expect(ev.reductionKg).assertEqual(0.5);
      expect(ev.expectedPoint).assertEqual(50);
      expect(ev.actualPoint).assertEqual(20); // min(50, 120 − 100)
      expect(ev.capped).assertTrue();
      // 同一条输入下，内置 200 口径的结果（证明差异确实来自下行值）
      const base: CalcEvaluation = CarbonCalc.evaluate('travel', 'metro', 10, snap, { todayRecordPoint: 100, dailyCap: 200 });
      expect(base.actualPoint).assertEqual(50);
      CarbonCalc.installDailyCap(undefined);
    });

    it('③ 任一字段非法 → 整份丢弃，上一份有效配置一字不变', 0, async () => {
      const fx: Fixture = await setup();
      // 先建立"上一份"
      fx.fake.stub('GET', `${fx.fake.baseUrl()}${PATH}`, 200,
        okBody('v-good', 120, true, '[{"goalId":"S1","reward":999}]'));
      const first: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(first.ok).assertTrue();
      const kept: string | undefined = await storedConfig(fx.cfg);
      expect(kept !== undefined).assertTrue();

      const url: string = `${fx.fake.baseUrl()}${PATH}`;
      const bad: string[] = [
        // a) version 空串（无法判断内容是否变了 → D10-5 会退化成碰运气）
        '{"ok":true,"data":{"version":"","pointsDailyCap":120,"badgesEnabled":true,"goalRewards":[],"serverTime":1}}',
        // b) 封顶值为负
        '{"ok":true,"data":{"version":"v-bad","pointsDailyCap":-1,"badgesEnabled":true,"goalRewards":[],"serverTime":1}}',
        // c) 封顶值非整数
        '{"ok":true,"data":{"version":"v-bad","pointsDailyCap":1.5,"badgesEnabled":true,"goalRewards":[],"serverTime":1}}',
        // d) 封顶值是字符串
        '{"ok":true,"data":{"version":"v-bad","pointsDailyCap":"120","badgesEnabled":true,"goalRewards":[],"serverTime":1}}',
        // e) 徽章开关用 0/1 整数（必须是 JSON 布尔）
        '{"ok":true,"data":{"version":"v-bad","pointsDailyCap":120,"badgesEnabled":1,"goalRewards":[],"serverTime":1}}',
        // f) goalRewards 不是数组
        '{"ok":true,"data":{"version":"v-bad","pointsDailyCap":120,"badgesEnabled":true,"goalRewards":{},"serverTime":1}}',
        // g) goalRewards 元素缺 reward
        '{"ok":true,"data":{"version":"v-bad","pointsDailyCap":120,"badgesEnabled":true,"goalRewards":[{"goalId":"S1"}],"serverTime":1}}',
        // h) goalRewards 元素 reward 为负
        '{"ok":true,"data":{"version":"v-bad","pointsDailyCap":120,"badgesEnabled":true,"goalRewards":[{"goalId":"S1","reward":-2}],"serverTime":1}}',
        // i) goalRewards 元素 goalId 为空串
        '{"ok":true,"data":{"version":"v-bad","pointsDailyCap":120,"badgesEnabled":true,"goalRewards":[{"goalId":"","reward":1}],"serverTime":1}}',
        // j) 缺 serverTime
        '{"ok":true,"data":{"version":"v-bad","pointsDailyCap":120,"badgesEnabled":true,"goalRewards":[]}}',
        // k) 信封 ok=false
        '{"ok":false,"data":{"version":"v-bad","pointsDailyCap":120,"badgesEnabled":true,"goalRewards":[],"serverTime":1}}',
      ];
      let k: number = 0;
      while (k < bad.length) {
        fx.fake.stub('GET', url, 200, bad[k]);
        const r: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
        expect(r.ok).assertFalse();
        // 每一次非法都不许改动已存的上一份（"整份丢弃、不写一个字节"）
        expect(await storedConfig(fx.cfg)).assertEqual(kept === undefined ? '' : kept);
        k = k + 1;
      }
      // 封顶镜像也仍然跟着上一份有效值（失败不把封顶值改坏）
      expect(CarbonCalc.effectiveDailyCap()).assertEqual(120);
      const eff: ServerConfig | undefined = await ServerConfigFetcher.effective(fx.cfg);
      expect(eff === undefined ? '' : eff.version).assertEqual('v-good');
    });

    it('④ goalRewards：未知 goalId 整条忽略、已知 goalId 覆盖内置 reward 且真实生效', 0, async () => {
      const fx: Fixture = await setup();
      const now: number = Date.now();
      const userId: string = `t-server-config-${now}`;
      await fx.hub.auth.logout(now);
      await fx.hub.state.ensureUser(userId, now);

      fx.fake.stub('GET', `${fx.fake.baseUrl()}${PATH}`, 200,
        okBody('2026.11.06-2', 200, true, '[{"goalId":"S1","reward":7777},{"goalId":"NOT_A_GOAL","reward":5}]'));
      const res: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(res.ok).assertTrue();
      // 未知 goalId 被整条剔除（不报错、不写库）
      expect(res.data === undefined ? -1 : res.data.goalRewardCount).assertEqual(1);
      const raw: string | undefined = await storedConfig(fx.cfg);
      const text: string = raw === undefined ? '' : raw;
      expect(text.indexOf('"S1"') >= 0).assertTrue();
      expect(text.indexOf('NOT_A_GOAL') < 0).assertTrue();

      // 覆盖真实生效：目标页展示行的 reward 变成下行值
      const cards: GoalCard[] = await fx.hub.reward.refreshProgress(userId, now);
      expect(cards.length).assertEqual(11); // 未知 goalId 不新增目标（内置 11 条）
      expect(rewardOfCard(cards, 'S1')).assertEqual(7777);
      expect(rewardOfCard(cards, 'S2')).assertEqual(20); // 未下发的目标保持内置值

      // 铁律 3：内置定义表 `goal_def` **一行不改**（覆盖只发生在内存里的展示/结算口径）
      const defRows: RowShape[] = await fx.hub.store.query("SELECT reward FROM goal_def WHERE id = 'S1'", []);
      const defRow: RowShape | undefined = firstOf(defRows);
      expect(numOf(defRow === undefined ? {} : defRow, 'reward')).assertEqual(20);

      // 结算口径与展示口径同源：该用户当日无记录 → S1 进度 0 → 不得产生任何结算指令
      const settled = await fx.hub.reward.settle(userId, now);
      expect(settled.length).assertEqual(0);
    });

    it('⑤ 与上一份同 version → 跳过写入（内容与封顶值都不变）', 0, async () => {
      const fx: Fixture = await setup();
      const url: string = `${fx.fake.baseUrl()}${PATH}`;
      fx.fake.stub('GET', url, 200, okBody('v-same', 120, true, '[{"goalId":"S1","reward":999}]'));
      const first: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(first.ok).assertTrue();
      const kept: string | undefined = await storedConfig(fx.cfg);
      expect(kept !== undefined).assertTrue();

      // 同版本号、但内容不同（封顶 999、徽章关闭、奖励不同）→ 必须整份跳过
      fx.fake.stub('GET', url, 200, okBody('v-same', 999, false, '[{"goalId":"S2","reward":1}]'));
      const second: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(second.ok).assertTrue();
      expect(second.data === undefined ? true : second.data.applied).assertFalse();
      expect((second.data === undefined ? '' : second.data.reason).indexOf('同版本') >= 0).assertTrue();
      expect(await storedConfig(fx.cfg)).assertEqual(kept === undefined ? '' : kept);
      expect(CarbonCalc.effectiveDailyCap()).assertEqual(120);
      CarbonCalc.installDailyCap(undefined);
    });

    it('⑥ HTTP 500 / 破损 JSON / 空 data / 网络抛错 → 静默降级为内置值，从不抛错', 0, async () => {
      const fx: Fixture = await setup();
      CarbonCalc.installDailyCap(undefined);
      const url: string = `${fx.fake.baseUrl()}${PATH}`;
      // 未拉到过：键不存在、封顶 = 内置 200
      expect(await storedConfig(fx.cfg) === undefined).assertTrue();
      expect(CarbonCalc.effectiveDailyCap()).assertEqual(AppConstants.DAILY_RECORD_CAP);

      fx.fake.stub('GET', url, 500, '{"ok":false}');
      const http500: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(http500.ok).assertFalse();
      expect((http500.code === undefined ? '' : http500.code).indexOf('THREW') < 0).assertTrue();

      fx.fake.stub('GET', url, 200, 'not-json');
      const broken: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(broken.ok).assertFalse();

      fx.fake.stub('GET', url, 200, '{"ok":true,"data":{}}');
      const empty: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(empty.ok).assertFalse();

      // 三种失败都没写库、也没把封顶值改坏
      expect(await storedConfig(fx.cfg) === undefined).assertTrue();
      expect(CarbonCalc.effectiveDailyCap()).assertEqual(AppConstants.DAILY_RECORD_CAP);

      // 网络层直接抛错：`fetchAndStore()` 必须把它转成 AppResult，而不是抛给调用方
      const boom: BoomHttp = new BoomHttp();
      const fetcher: ServerConfigFetcher = new ServerConfigFetcher(boom, fx.cfg, fx.hub.store);
      const thrown: AppResult<ServerConfigOutcome> = await fetcher.fetchAndStore();
      expect(thrown.ok).assertFalse();
      expect(thrown.code === undefined ? '' : thrown.code).assertEqual('CONFIG_FETCH_THREW');
      expect(await storedConfig(fx.cfg) === undefined).assertTrue();
    });

    it('⑦ badgesEnabled=false → 不发新徽章、已有徽章行一字不动；打开后照常写入', 0, async () => {
      const fx: Fixture = await setup();
      const now: number = Date.now();
      const userId: string = `t-badges-${now}`;
      await fx.hub.auth.logout(now);
      await fx.hub.state.ensureUser(userId, now);
      // 先造一条"历史已解锁"的徽章行（模拟登录前/开关打开时已发的徽章）
      await fx.hub.store.exec(
        'INSERT INTO user_badge (id, user_id, badge_id, unlocked, unlocked_at, progress, created_at, updated_at, is_deleted, device_id, sync_state) ' +
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)',
        ['t-badge-row-1', userId, 'B_FIRST', 1, now, 1, now, now, fx.hub.state.deviceId(), fx.hub.state.syncState()]
      );

      const url: string = `${fx.fake.baseUrl()}${PATH}`;
      fx.fake.stub('GET', url, 200, okBody('v-off', 200, false, '[]'));
      const off: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(off.ok).assertTrue();
      expect(off.data === undefined ? true : off.data.badgesEnabled).assertFalse();

      const newly: BadgeDef[] = await fx.hub.reward.unlockBadges(userId, now + 1000);
      expect(newly.length).assertEqual(0);
      const rows: RowShape[] = await fx.hub.store.query(
        'SELECT badge_id, unlocked, progress, updated_at FROM user_badge WHERE user_id = ?', [userId]);
      // 不新建、不删除、已解锁的**一行不动**（连 progress / updated_at 都不许被刷）
      expect(rows.length).assertEqual(1);
      const row0: RowShape | undefined = firstOf(rows);
      expect(row0 === undefined ? '' : `${row0['badge_id']}`).assertEqual('B_FIRST');
      expect(numOf(row0 === undefined ? {} : row0, 'unlocked')).assertEqual(1);
      expect(numOf(row0 === undefined ? {} : row0, 'progress')).assertEqual(1);
      expect(numOf(row0 === undefined ? {} : row0, 'updated_at')).assertEqual(now);

      // 反向对照：打开开关 → 同一方法会照常写库（证明上面"什么都没发生"确实是开关造成的）
      fx.fake.stub('GET', url, 200, okBody('v-on', 200, true, '[]'));
      const on: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(on.ok).assertTrue();
      await fx.hub.reward.unlockBadges(userId, now + 2000);
      const rows2: RowShape[] = await fx.hub.store.query(
        'SELECT badge_id FROM user_badge WHERE user_id = ? AND is_deleted = 0', [userId]);
      expect(rows2.length > 1).assertTrue(); // 8 枚徽章行被写入
    });

    it('⑧ goalRewards 缺省 / 空数组 → 字段缺省回落：用内置种子，不覆盖也不新增目标', 0, async () => {
      const fx: Fixture = await setup();
      const now: number = Date.now();
      const userId: string = `t-config-default-${now}`;
      await fx.hub.auth.logout(now);
      await fx.hub.state.ensureUser(userId, now);
      const url: string = `${fx.fake.baseUrl()}${PATH}`;
      CarbonCalc.installDailyCap(undefined);

      // a) **整个字段缺省**：合法（附录 B §5.5「缺省 → 用 App 内置种子」）
      fx.fake.stub('GET', url, 200,
        `{"ok":true,"data":{"version":"v-no-rewards","pointsDailyCap":150,` +
        `"badgesEnabled":true,"serverTime":${SERVER_TIME}}}`);
      const res: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(res.ok).assertTrue();
      expect(res.data === undefined ? -1 : res.data.goalRewardCount).assertEqual(0);
      // 同一份里的封顶值照常生效（缺省只影响 goalRewards 一项）
      expect(CarbonCalc.effectiveDailyCap()).assertEqual(150);
      const cards: GoalCard[] = await fx.hub.reward.refreshProgress(userId, now);
      expect(cards.length).assertEqual(11);
      expect(rewardOfCard(cards, 'S1')).assertEqual(20);   // rawfile/goals/goal-defs.json 内置值
      expect(rewardOfCard(cards, 'L1')).assertEqual(1000);

      // b) 空数组：与"缺省"同义（不覆盖、不新增）
      fx.fake.stub('GET', url, 200, okBody('v-empty-rewards', 150, true, '[]'));
      const res2: AppResult<ServerConfigOutcome> = await fx.hub.fetchServerConfig();
      expect(res2.ok).assertTrue();
      expect(res2.data === undefined ? -1 : res2.data.goalRewardCount).assertEqual(0);
      const cards2: GoalCard[] = await fx.hub.reward.refreshProgress(userId, now);
      expect(cards2.length).assertEqual(11);
      expect(rewardOfCard(cards2, 'S1')).assertEqual(20);
      CarbonCalc.installDailyCap(undefined);
    });
  });
}
