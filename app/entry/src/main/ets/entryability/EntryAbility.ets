/**
 * EntryAbility —— 应用唯一入口 Ability。
 *
 * 职责（只有三件事，不承载任何业务逻辑）：
 *  ① 生命周期回调转发：onCreate / onWindowStageCreate / onForeground / onBackground / onDestroy；
 *  ② 在 onWindowStageCreate 里加载首页（`pages/Index`）；
 *  ③ 提供 `context` 给上层取 `relationalStore` 与 `rawfile`（本切片尚未接入，留给 S2 的记录闭环）。
 *
 * 禁止事项（AGENTS.md §2 铁律 1、铁律 2）：
 *  - 本文件**不出现任何碳计算、不出现任何 SQL**；
 *  - 业务计算一律走 `CarbonService.calculate()`，数据读写一律走 Dao。
 */
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@ohos.base';
import { RdbHelper, SchemaReport } from '../data/dao/RdbHelper';
import { SeedRepository, SeedReport } from '../service/SeedRepository';
import { FactorRepository } from '../service/FactorRepository';
import { AppConstants } from '../util/AppConstants';
import { ServiceHub } from '../viewmodel/ServiceHub';
import { ShopPriceOutcome } from '../viewmodel/net/ShopPriceFetcher';
import { ServerConfigOutcome } from '../viewmodel/net/ServerConfigFetcher';
import { AppResult } from '../model/Result';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarbonBoo';

export default class EntryAbility extends UIAbility {
  /**
   * Ability 创建：此处只记录日志与预留冷启动参数处理。
   * @param want 启动参数（深链 / 分享进入时使用，S7 才接入）
   * @param launchParam 启动原因与上次异常退出信息
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate, launchReason=%{public}s', String(launchParam.launchReason));
    // 冷启动即启动数据地基：打开 19 张表 + 幂等写入静态字典种子。
    // 刻意 **不 await**：Ability 生命周期回调必须立刻返回，否则系统会判定启动超时。
    // 失败只记日志——页面读取时若库仍不可用，会由后续切片的 ViewModel 再报错给用户。
    this.bootstrapDataFoundation();
  }

  /**
   * 数据地基启动：`RdbHelper.open`（建 19 张表）→ `SeedRepository.seedStatic`（写种子）
   * → **冷启动取价**（`ServiceHub.fetchShopPrices`，附录 B §5.4）
   * → **冷启动配置下发**（`ServiceHub.fetchServerConfig`，附录 B §5.5）。
   * 各步都幂等，重复冷启动不会重复建表或产生重复种子行；取价/配置失败只记日志，绝不中断启动。
   */
  private bootstrapDataFoundation(): void {
    RdbHelper.get()
      .open(this.context)
      .then(async (store) => {
        const schema: SchemaReport = await RdbHelper.applySchema(store);
        const seeded: SeedReport = await SeedRepository.seedStatic(RdbHelper.get(), this.context);
        await FactorRepository.load(this.context);
        hilog.info(
          DOMAIN,
          TAG,
          'schema ok: %{public}d/%{public}d tables, %{public}d statements; seeds: goals=%{public}d badges=%{public}d shop=%{public}d science=%{public}d; factors=%{public}s',
          schema.tables.length,
          schema.expected,
          schema.statements,
          seeded.goals,
          seeded.badges,
          seeded.shopItems,
          seeded.articles,
          seeded.factorVersion
        );
        // 取价必须在**种子之后**：商品基线要先由 rawfile 播种进 `shop_item`，
        // 后台目录只是对同 id 商品的价格/文案叠加（"从未拉到过 → 用内置默认价"由此成立）。
        await this.bootstrapShopPrices();
        // 配置下发同样在种子之后：`goalRewards` 的"未知 goalId 整条忽略"要靠 `goal_def`
        // 里已播种的 11 条目标来判定（见 `ServerConfigFetcher.knownGoalIds`）。
        await this.bootstrapServerConfig();
      })
      .catch((err: BusinessError) => {
        hilog.error(
          DOMAIN,
          TAG,
          '数据地基启动失败（%{public}s）：%{public}s',
          `${err.code}`,
          err.message === undefined ? 'unknown' : err.message
        );
      });
  }

  /**
   * 冷启动取价（附录 B §5.4，铁律 1 的例外之一）。
   *
   * 契约：「启动时有网 → 拉取并整份覆盖 `app_config['shop_items']`；失败或数据非法 →
   * **整份丢弃**，继续用上一份有效配置；从未拉到过 → 用 `rawfile/shop/shop-items.json` 内置默认价。
   * 后台改价**下次启动生效**。」
   *
   * 本方法**永不抛错**（`ServiceHub.fetchShopPrices` 内部已兜住所有异常）：
   * 取价失败绝不阻塞启动，也绝不打断已完成的建表/播种。全程只记一行日志。
   * 刻意 **不 await 到阻塞 UI**：`ServiceHub.init` 只打开数据库与端口（毫秒级），
   * 取价本身带 3s 超时且失败即丢弃，不影响任何本地功能。
   */
  private async bootstrapShopPrices(): Promise<void> {
    try {
      const hub: ServiceHub = await ServiceHub.init(this.context, Date.now());
      const res: AppResult<ShopPriceOutcome> = await hub.fetchShopPrices();
      if (res.ok && res.data !== undefined && res.data.applied) {
        hilog.info(DOMAIN, TAG, '商品取价成功：整份覆盖 app_config[shop_items]（version=%{public}s，%{public}d 条）',
          res.data.version, res.data.count);
      } else {
        hilog.warn(DOMAIN, TAG, '商品取价未生效，保留本地价目表：%{public}s', res.message === undefined ? 'unknown' : res.message);
      }
    } catch (e) {
      // 兜底：连 Hub 初始化都失败也不能影响启动（页面会走单机路径）
      const msg: string = e instanceof Error ? e.message : `${e}`;
      hilog.warn(DOMAIN, TAG, '商品取价链路异常已吞掉（不影响本地功能）：%{public}s', msg);
    }
  }

  /**
   * 冷启动拉取后台系统配置（附录 B §5.5，验收 D10-5；`GET /api/v1/config` **免 token**）。
   *
   * 契约：「启动时拉一次；`version` / `pointsDailyCap` / `badgesEnabled` / `goalRewards` /
   * `serverTime` 五项任一非法 → **整份丢弃**，保留上一份有效配置；从未拉到过 → 用 App 内置
   * `rawfile` 种子（内置封顶 200 + 徽章启用 + `goal-defs.json` 的 reward）。」
   *
   * 三层兜底（与取价同款）：① `ServerConfigFetcher` 内部从不抛错；
   * ② `ServiceHub.fetchServerConfig` 再包一层 try/catch；③ 本方法第三层兜底，
   * 连 `ServiceHub.init` 失败也只是少一次下发 —— **绝不阻塞启动**，全程只记一行日志。
   * `ServiceHub.init` 已在冷启动时把上一次的下行封顶值装进 `CarbonCalc` 的内存镜像，
   * 所以"离线冷启动"同样按上一份有效配置封顶。
   */
  private async bootstrapServerConfig(): Promise<void> {
    try {
      const hub: ServiceHub = await ServiceHub.init(this.context, Date.now());
      const res: AppResult<ServerConfigOutcome> = await hub.fetchServerConfig();
      if (res.ok && res.data !== undefined && res.data.applied) {
        hilog.info(DOMAIN, TAG, '后台配置下发成功：整份覆盖 app_config[server_config]（version=%{public}s，封顶=%{public}d，徽章=%{public}s，目标奖励覆盖=%{public}d 条）',
          res.data.version, res.data.pointsDailyCap, `${res.data.badgesEnabled}`, res.data.goalRewardCount);
      } else {
        hilog.warn(DOMAIN, TAG, '后台配置未生效，沿用上一份/内置默认值：%{public}s', res.message === undefined ? 'unknown' : res.message);
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : `${e}`;
      hilog.warn(DOMAIN, TAG, '配置下发链路异常已吞掉（不影响本地功能）：%{public}s', msg);
    }
  }

  /**
   * 窗口舞台就绪：加载首页。
   * @param windowStage 当前 Ability 的窗口舞台
   */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
    });
  }

  /** 窗口舞台销毁：释放窗口相关资源（当前无持有）。 */
  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  /** 进入前台：S2 起在此触发「补同步 / 刷新今日额度」。 */
  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onForeground');
  }

  /** 进入后台：S2 起在此落 `last_active_at`。 */
  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onBackground');
  }

  /** Ability 销毁：关闭数据库连接（连接由 `RdbHelper` 单例管理）。 */
  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
    RdbHelper.get()
      .close()
      .then(() => {
        hilog.info(DOMAIN, TAG, 'rdb closed');
      })
      .catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, '关闭数据库失败（%{public}s）', `${err.code}`);
      });
  }
}
