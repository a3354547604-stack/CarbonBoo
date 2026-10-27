/**
 * Index —— 唯一的 @Entry 页面：导航壳 + 5 个 Tab（附录 C §2）。
 *
 * 结构：Navigation(NavPathStack) → Tabs(barPosition: End)
 *   · 5 个 Tab 页（首页/看板/记录/科普/我的）常驻，切换保留各自状态；
 *   · 13 个二级页是 `@Component`，由 `pageMap` 按路由名装配成 NavDestination 压栈；
 *   · 页面参数走 `NavParams`（类型化单例），因此 pageMap 不需要 `as` 强转即可分派
 *     —— ArkTS 禁 `as`，navDestination 的 param 是 Object，直接读字段必被禁。
 *
 * 这里同时是该模块的编译图入口：所有页面、组件、ViewModel、数据层都由本文件可达
 * （t2 实测证明：ArkTS 只编译 entry 可达模块，未 import 的业务代码不参与编译）。
 *
 * ⚠️ 末尾两条 **S1 表 Dao 的 import 是刻意的编译图锚点**（`CarbonRecordDao` / `ResultSetMapper`）：
 *   t4 重写本页时它们一度不在编译图里（`docs/VERIFICATION.md` 的 F2 实测：向这两个文件注入未定义引用，
 *   build 仍 SUCCESS），于是 t2 自述的「缺陷 A（`ResultSet.getColumnName(0)`）修复」**从未被编译器校验过**。
 *   t21 按验收要求把它们显式接入本页（附录 B §7 的 12 个表 Dao 里目前落地的就是这两者），
 *   并**用注入探针复验**：向 `CarbonRecordDao.ets` 注入未定义常量 → BUILD FAILED；
 *   撤回 → BUILD SUCCESSFUL。锚点因此不是"顺手留的 import"，而是有门禁背书的可达性约束。
 *   业务路径上它们仍**不作为**数据通道使用（t4 起数据层是 `viewmodel/store/*`），
 *   删除它们等于让 §7 的表 Dao 契约在代码侧归零，故保留而非删除。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { ServiceHub } from '../viewmodel/ServiceHub';
import { NavParams, RouteName } from '../viewmodel/RouteName';
import { AppTheme } from '../util/AppTheme';
import { HomePage } from './HomePage';
import { DashboardPage } from './DashboardPage';
import { RecordPage } from './RecordPage';
import { SciencePage } from './SciencePage';
import { MinePage } from './MinePage';
import { RecordEditPage } from './RecordEditPage';
import { RecordDetailPage } from './RecordDetailPage';
import { RecordSearchPage } from './RecordSearchPage';
import { GoalPage } from './GoalPage';
import { BadgePage } from './BadgePage';
import { ShopPage } from './ShopPage';
import { PointLogPage } from './PointLogPage';
import { ScienceDetailPage } from './ScienceDetailPage';
import { SyncPage } from './SyncPage';
import { IncludePage } from './IncludePage';
import { AppearancePage } from './AppearancePage';
import { SettingsPage } from './SettingsPage';
import { AboutPage } from './AboutPage';
// 编译图锚点（见文件头 ⚠️）：S1 表 Dao —— 仅 import、不经业务路径调用，防止其再次掉出编译图。
import { CarbonRecordDao } from '../data/dao/CarbonRecordDao';
import { ResultSetMapper } from '../data/dao/ResultSetMapper';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarbonBoo';

@Entry
@Component
struct Index {
  @State tabKey: number = 0;
  @State tick: number = 0;
  @State booting: boolean = true;
  @State bootError: string = '';
  @Provide('navStack') navStack: NavPathStack = new NavPathStack();
  private tabsController: TabsController = new TabsController();
  private recordScroller: Scroller = new Scroller();

  async aboutToAppear(): Promise<void> {
    await this.boot();
  }

  /** 打开数据库、装好服务、刷新一次数据。 */
  private async boot(): Promise<void> {
    try {
      const host: common.Context | undefined = this.getUIContext().getHostContext();
      if (host === undefined) {
        throw new Error('拿不到 Ability 上下文');
      }
      await ServiceHub.init(host, Date.now());
      NavParams.attach(this.navStack);
      await ServiceHub.get().state.touch(Date.now());
      this.booting = false;
      this.tick = this.tick + 1;
      hilog.info(DOMAIN, TAG, 'ServiceHub 初始化完成');
    } catch (err) {
      this.booting = false;
      this.bootError = `初始化失败：${err instanceof Error ? err.message : String(err)}`;
      hilog.error(DOMAIN, TAG, 'ServiceHub 初始化失败 %{public}s', this.bootError);
    }
  }

  /**
   * 二级页装配表：名字 → 组件（参数由 NavParams 提供）。
   *
   * ⚠️ `navDestination` 的 builder **必须**返回一个 `NavDestination` 容器节点，
   * 只返回裸的自定义组件时 ArkUI 会报
   * `js_navigation_stack.cpp(515): router map is invalid, child size is not one`
   * 并在压栈时让 JS 引擎崩溃（0xc0000005）。此前 13 个页面都是裸组件，
   * 预览器里点任何二级页入口必崩；因此这里统一包一层 NavDestination。
   * 标题栏由各页自己的 `PageHeader` 画，所以 `hideTitleBar(true)`。
   */
  @Builder
  pageMap(name: string) {
    NavDestination() {
      if (name === RouteName.RECORD_EDIT) {
        RecordEditPage()
      } else if (name === RouteName.RECORD_DETAIL) {
        RecordDetailPage()
      } else if (name === RouteName.RECORD_SEARCH) {
        RecordSearchPage()
      } else if (name === RouteName.GOAL) {
        GoalPage()
      } else if (name === RouteName.BADGE) {
        BadgePage()
      } else if (name === RouteName.SHOP) {
        ShopPage()
      } else if (name === RouteName.POINT_LOG) {
        PointLogPage()
      } else if (name === RouteName.SCIENCE_DETAIL) {
        ScienceDetailPage()
      } else if (name === RouteName.SYNC) {
        SyncPage()
      } else if (name === RouteName.INCLUDE) {
        IncludePage()
      } else if (name === RouteName.APPEARANCE) {
        AppearancePage()
      } else if (name === RouteName.SETTINGS) {
        SettingsPage()
      } else if (name === RouteName.ABOUT) {
        AboutPage()
      }
    }
    .hideTitleBar(true)
  }

  @Builder
  tabBar(index: number, label: ResourceStr, icon: string) {
    Column({ space: 2 }) {
      Text(icon).fontSize(AppTheme.ICON_SM)
      Text(label)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(this.tabKey === index ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_HINT)
    }
    .width('100%')
    .height(AppTheme.TAB_HEIGHT)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Navigation(this.navStack) {
      if (this.booting) {
        Column({ space: 8 }) {
          LoadingProgress().width(AppTheme.ICON_LG).height(AppTheme.ICON_LG).color(AppTheme.COLOR_PRIMARY)
          Text('正在准备本地账本…').fontSize(AppTheme.FONT_BODY).fontColor(AppTheme.COLOR_TEXT_SECONDARY)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.bootError.length > 0) {
        Column({ space: 8 }) {
          Text('😕').fontSize(AppTheme.ICON_LG)
          Text(this.bootError)
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(AppTheme.COLOR_DANGER)
            .textAlign(TextAlign.Center)
          Text('重试')
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(AppTheme.COLOR_SURFACE)
            .height(AppTheme.BTN_HEIGHT)
            .padding({ left: 24, right: 24 })
            .backgroundColor(AppTheme.COLOR_PRIMARY)
            .borderRadius(AppTheme.BTN_RADIUS)
            .onClick(() => {
              this.booting = true;
              this.bootError = '';
              this.boot();
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Tabs({ barPosition: BarPosition.End, index: this.tabKey, controller: this.tabsController }) {
          TabContent() {
            HomePage({ tick: this.tick })
          }.tabBar(this.tabBar(0, $r('app.string.tab_home'), '🏠'))

          TabContent() {
            DashboardPage({ tick: this.tick })
          }.tabBar(this.tabBar(1, $r('app.string.tab_dashboard'), '📊'))

          TabContent() {
            RecordPage({ tick: this.tick, scroller: this.recordScroller })
          }.tabBar(this.tabBar(2, $r('app.string.tab_record'), '🧾'))

          TabContent() {
            SciencePage({ tick: this.tick })
          }.tabBar(this.tabBar(3, $r('app.string.tab_science'), '📚'))

          TabContent() {
            MinePage({ tick: this.tick })
          }.tabBar(this.tabBar(4, $r('app.string.tab_mine'), '👤'))
        }
        .barHeight(AppTheme.TAB_HEIGHT)
        .barMode(BarMode.Fixed)
        .backgroundColor(AppTheme.COLOR_BG)
        .onChange((index: number) => {
          this.tabKey = index;
          this.tick = this.tick + 1;
        })
      }
    }
    .navDestination(this.pageMap)
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .backgroundColor(AppTheme.COLOR_BG)
  }
}
