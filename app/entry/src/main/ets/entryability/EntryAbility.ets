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
   * 数据地基启动：`RdbHelper.open`（建 19 张表）→ `SeedRepository.seedStatic`（写种子）。
   * 两步都幂等，重复冷启动不会重复建表或产生重复种子行。
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
