/**
 * 首页（构建占位）。
 *
 * ⚠️ 这是一张**占位页**，不是本切片（S1 数据地基）的交付物：
 *    `module.json5` 的 `pages` 与 `EntryAbility.loadContent('pages/Index')` 都要求
 *    `pages/Index.ets` 存在，否则 HAP 构建失败。真正的首页由后续切片按
 *    `APPENDIX-C-ui-screens.md` §4 重写（含首页建议、今日额度、快捷入口）。
 *
 * 约束（AGENTS.md §7.1）：页面层禁止业务计算与数据库读写——本页只有静态文案。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

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
