/**
 * 首页（S1 构建占位 · 同时承担「业务代码编译图接入点」职责）。
 *
 * ⚠️ 两张身份，都必须明白：
 *
 * ① **这是占位页，不是 S1 的交付界面**。`module.json5` 的 `pages` 与
 *    `EntryAbility.loadContent('pages/Index')` 都要求它存在，否则 HAP 构建失败。
 *    真正的首页由 t4 按 `APPENDIX-C-ui-screens.md` §4 重写（首页建议、今日额度、快捷入口等）。
 *
 * ② **它同时是「编译图接入点」**——这是本文件当前更重要的职责：
 *    ArkTS 编译器**只编译从 entry 模块可达的模块**。S1 新增的 `service/` / `data/` /
 *    `model/` / `util/` 若没有任何入口 import 它们，就**根本不会进入编译图**，
 *    此时 `assembleHap` 的 BUILD SUCCESSFUL 是假象——往里注入语法错误也照样通过。
 *
 *    **本切片实测记录（三次对照，可复现）**：
 *    | 场景 | 结果 |
 *    |---|---|
 *    | 占位页不 import 业务模块 + `CarbonService.ets` 注入 `THIS_IS_UNDEFINED_ABC` | BUILD **SUCCESSFUL**（假象：没编译） |
 *    | 本页 import 后 + `CarbonService.ets` 注入同样错误 | BUILD **FAILED**（`Cannot find name 'THIS_IS_UNDEFINED_ABC'`） |
 *    | 本页 import 后 + `data/schema/ClientSchema.ets` 注入错误 | BUILD **FAILED**（同一类报错，两条同时报出） |
 *    → 故下面的 import 列表**就是**让 S1 业务代码真正被编译的机制，不是装饰。
 *
 * 约束（AGENTS.md §7.1，本页严格遵守）：
 *  - 页面层**禁止业务计算与数据库读写**。本页除 `hilog` 一条日志外**没有任何逻辑**：
 *    下面 24 条 import 只建立模块可达性，**不调用、不实例化、不读库、不乘因子**。
 *  - 「未使用的 import」是**刻意保留**的：ArkTS 的编译范围由 import 声明决定，
 *    删掉它们等于关掉 S1 业务代码的编译门禁。t4 重写首页时应改为**真实使用**
 *    这些模块（经 ViewModel），届时本注释与这批 import 一并重写。
 *  - 数据地基的真正启动在 `EntryAbility.bootstrapDataFoundation()`（开 19 张表 + 写种子）；
 *    界面数据一律经 ViewModel，本页不碰。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

// ---- service/：计算入口与数据地基启动链路 ----
import { CarbonService } from '../service/CarbonService';
import { CarbonCalc } from '../service/CarbonCalc';
import { FactorLibrary } from '../service/FactorLibrary';
import { FactorRepository } from '../service/FactorRepository';
import { SeedRepository, SeedReport } from '../service/SeedRepository';
// ---- data/：建表 DDL 与 Dao ----
import { ClientSchema } from '../data/schema/ClientSchema';
import { RdbHelper } from '../data/dao/RdbHelper';
import { CarbonRecordDao } from '../data/dao/CarbonRecordDao';
import { ResultSetMapper } from '../data/dao/ResultSetMapper';
// ---- model/：领域类型 ----
import { CarbonRecord, CalculatePreview, FactorItem } from '../model/CarbonTypes';
import { PointBalance, PointRecord } from '../model/PointTypes';
import { GoalDef, GoalProgress } from '../model/GoalTypes';
import { BadgeDef, BadgeProgress } from '../model/BadgeTypes';
import { ShopItem, Appearance } from '../model/ShopTypes';
import { ScienceArticleMeta, ScienceProgress } from '../model/ScienceTypes';
import { CarbonCoin, IncludeBenefit, CarbonIncludeRecord } from '../model/IncludeTypes';
import { DevicePeer, SyncSessionState } from '../model/SyncTypes';
import { AiRecognizeResult } from '../model/AiTypes';
import { AppResult } from '../model/Result';
// ---- util/：常量与纯函数工具 ----
import { AppConstants } from '../util/AppConstants';
import { DateUtil } from '../util/DateUtil';
import { Dec } from '../util/DecimalUtil';

@Entry
@Component
struct Index {
  build() {
    Column({ space: 12 }) {
      Text($r('app.string.placeholder_index_title'))
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
      Text($r('app.string.placeholder_index_note'))
        .fontSize(14)
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onAppear(() => {
      hilog.info(0x0001, 'CarbonBoo', 'placeholder Index appeared');
    })
  }
}
