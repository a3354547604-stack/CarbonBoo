/**
 * HomePage —— 首页（附录 C §5，Tab0）。
 *
 * 页面层只做三件事：调 ViewModel 取数、渲染、把点击变成路由或 ViewModel 调用。
 * 所有数字来自 `StatsService` / `PointService` / `RewardService` / `SuggestionEngine`，
 * 页面自己不做任何乘法（铁律 2）。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { RouteName, RouteParam, NavParams } from '../viewmodel/RouteName';
import { OverviewStats } from '../viewmodel/StatsService';
import { GoalCard } from '../viewmodel/domain/RewardEngine';
import { ChartBucket, ChartModel } from '../viewmodel/domain/ChartModel';
import { Suggestion, SuggestionContext, SuggestionEngine } from '../viewmodel/domain/SuggestionEngine';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { AppConstants } from '../util/AppConstants';
import { Formatter } from '../util/Formatter';
import { DateUtil } from '../util/DateUtil';
import { DemoModeBanner } from '../components/DemoModeBanner';
import { SectionCard } from '../components/SectionCard';
import { StatCard } from '../components/StatCard';
import { GoalItem } from '../components/GoalItem';
import { ChartCanvas } from '../components/ChartCanvas';
import { ShareSheet } from '../components/ShareSheet';
import { ShareCardData } from '../util/CardRenderer';

@Component
export struct HomePage {
  @Prop @Watch('onTick') tick: number = 0;
  @Consume('navStack') stack: NavPathStack;
  @State stats: OverviewStats = emptyOverview();
  @State goals: GoalCard[] = [];
  @State week: ChartBucket[] = [];
  @State suggestionText: string = '';
  @State suggestionOffset: number = 0;
  @State isDemo: boolean = false;
  @State ready: boolean = false;
  @State showShare: boolean = false;
  @State shareData: ShareCardData = new ShareCardData();
  @State shareMessage: string = '';
  @State sharing: boolean = false;
  private suggestionList: Suggestion[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  /** 取首页需要的全部数据（一次总览 + 目标 + 近 7 天 + 建议）。 */
  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    const now: number = Date.now();
    const stats: OverviewStats = await hub.stats.overview(userId, now);
    const goals: GoalCard[] = await hub.reward.goalCards(userId, now);
    const from: number = DateUtil.addDays(now, -6);
    const records = await hub.stats.recordsInRange(userId, from, now);
    const line: ChartBucket[] = ChartModel.build(records, 'day', 'all', now).line;
    const week: ChartBucket[] = line.length > 7 ? line.slice(line.length - 7) : line;
    this.stats = stats;
    this.goals = goals;
    this.week = week;
    this.isDemo = await hub.state.demoFlag();
    this.suggestionList = SuggestionEngine.list(this.contextOf(stats));
    this.suggestionText = SuggestionEngine.pick(this.suggestionList, this.suggestionOffset).text;
    this.shareData = await hub.share.cardData(userId, now);
    this.ready = true;
  }

  private contextOf(stats: OverviewStats): SuggestionContext {
    const ctx: SuggestionContext = {
      recordCount: stats.recordCount, todayCount: stats.todayCount, streak: stats.streak,
      travelCount: stats.travelCount, recycleCount: stats.recycleKg > 0 ? 1 : 0,
      totalReduction: stats.totalReduction, todayEarned: stats.todayEarned,
      daysSinceLast: stats.hasRecord ? 0 : -1, badgeCount: stats.badgeUnlocked
    };
    return ctx;
  }

  private push(name: string, param?: RouteParam): void {
    NavParams.set(param);
    this.stack.pushPath({ name: name });
  }

  private cappedText(): string {
    if (this.stats.todayEarned >= AppConstants.DAILY_RECORD_CAP) {
      return '今日上限 200 已达';
    }
    return `今日上限 ${AppConstants.DAILY_RECORD_CAP} - 已得 ${Formatter.points(this.stats.todayEarned)}`;
  }

  @Builder
  todayGoalRows() {
    if (this.goals.length === 0) {
      Text('今天还没有目标进度，记一笔就会更新')
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_HINT)
    } else {
      ForEach(this.goals.slice(0, 3), (card: GoalCard) => {
        GoalItem({ card: card })
      }, (card: GoalCard) => card.goalId + card.periodKey)
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Scroll() {
        Column({ space: AppTheme.CARD_GAP }) {
          if (this.isDemo) {
            DemoModeBanner()
          }

          Row({ space: AppTheme.CARD_GAP }) {
            Text('🧑‍🌾')
              .fontSize(AppTheme.ICON_LG)
              .width(AppTheme.AVATAR_SIZE)
              .height(AppTheme.AVATAR_SIZE)
              .textAlign(TextAlign.Center)
              .backgroundColor(AppTheme.COLOR_DISABLED_BG)
              .borderRadius(AppTheme.AVATAR_SIZE)
            Column({ space: 2 }) {
              Text($r('app.string.home_greeting'))
                .fontSize(AppTheme.FONT_SECTION)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
              Text(ServiceHub.get().state.displayName())
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_HINT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text('📤')
              .fontSize(AppTheme.ICON_MD)
              .onClick(() => {
                this.showShare = true;
              })
            Text('🔔')
              .fontSize(AppTheme.ICON_MD)
              .onClick(() => this.push(RouteName.BADGE))
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Column({ space: 4 }) {
            Text($r('app.string.home_total_reduction'))
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
            Text(`${Formatter.reduction(this.stats.totalReduction)} kgCO₂e`)
              .fontSize(AppTheme.FONT_NUMBER_LG)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.COLOR_PRIMARY)
            Text(this.stats.hasRecord
              ? `≈ ${Formatter.number(this.stats.treeEquivalent, 'factor')} 棵树一年的吸收量`
              : '记录第一笔，开始你的碳足迹')
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppTheme.COLOR_TEXT_HINT)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(AppTheme.CARD_PADDING)
          .backgroundColor(AppTheme.COLOR_SURFACE)
          .borderRadius(AppTheme.CARD_RADIUS)
          .onClick(() => this.push(RouteName.DASHBOARD))

          Row({ space: AppTheme.CARD_GAP }) {
            StatCard({
              label: $r('app.string.home_point_card'), value: Formatter.points(this.stats.balance),
              sub: `余额 · ≈ ${this.stats.carbonCoin} 碳币`,
              onTap: () => this.push(RouteName.POINT_LOG)
            })
            StatCard({
              label: $r('app.string.home_today_record'),
              value: `${this.stats.todayCount} 条 · +${Formatter.points(this.stats.todayEarned)} 分`,
              sub: this.cappedText(), onTap: () => this.push(RouteName.RECORD)
            })
          }
          .width('100%')

          SectionCard({ title: $r('app.string.home_today_goal'), showTitle: true }) {
            this.todayGoalRows()
          }

          SectionCard({ title: $r('app.string.home_week_reduction'), showTitle: true }) {
            ChartCanvas({ kind: 'bar', buckets: this.week, chartHeight: 120 })
            Text($r('app.string.home_go_dashboard'))
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppTheme.COLOR_PRIMARY)
              .onClick(() => this.push(RouteName.DASHBOARD))
          }

          SectionCard({ title: $r('app.string.home_suggestion'), showTitle: true }) {
            Row({ space: AppTheme.CARD_GAP }) {
              Text('💡').fontSize(AppTheme.FONT_BODY)
              Text(this.suggestionText.length > 0 ? this.suggestionText : '今天也记一笔低碳行为吧')
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                .layoutWeight(1)
              Text($r('app.string.home_another'))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_PRIMARY)
                .onClick(() => {
                  this.suggestionOffset = this.suggestionOffset + 1;
                  this.suggestionText = SuggestionEngine.pick(this.suggestionList, this.suggestionOffset).text;
                })
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding(AppTheme.PAGE_PADDING)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)

      Text($r('app.string.fab_record'))
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_SURFACE)
        .height(AppTheme.FAB_SIZE)
        .padding({ left: AppTheme.CARD_PADDING, right: AppTheme.CARD_PADDING })
        .textAlign(TextAlign.Center)
        .backgroundColor(AppTheme.COLOR_PRIMARY)
        .borderRadius(AppTheme.FAB_SIZE / 2)
        .margin({ right: AppTheme.PAGE_PADDING, bottom: AppTheme.PAGE_PADDING + AppTheme.TAB_HEIGHT })
        .onClick(() => this.push(RouteName.RECORD_EDIT))
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.COLOR_BG)
    .bindSheet($$this.showShare, this.shareSheetBuilder(), {
      height: 560,
      onDisappear: () => {
        this.shareMessage = '';
      }
    })
  }

  @Builder
  shareSheetBuilder() {
    ShareSheet({
      data: this.shareData, pending: this.sharing, message: this.shareMessage,
      onSave: (size: string) => {
        this.saveCard(size);
      },
      onShare: (size: string) => {
        this.shareCard(size);
      },
      onClose: () => {
        this.showShare = false;
      }
    })
  }

  private async saveCard(size: string): Promise<void> {
    this.sharing = true;
    const result = await ServiceHub.get().share.saveCard(ServiceHub.get().state.userId(), size, this.shareData, Date.now());
    this.sharing = false;
    this.shareMessage = result.ok ? `已保存到相册（${size}）` : (result.message !== undefined ? result.message : '保存失败');
    this.getUIContext().getPromptAction().showToast({ message: this.shareMessage });
  }

  private async shareCard(size: string): Promise<void> {
    await ServiceHub.get().share.markShared(ServiceHub.get().state.userId(), size, this.shareData, Date.now());
    this.getUIContext().getPromptAction().showToast({ message: '已记录分享（系统分享面板由系统提供）' });
  }
}

/** 首页初始状态（避免首帧出现 NaN/undefined）。 */
export function emptyOverview(): OverviewStats {
  const stats: OverviewStats = {
    totalReduction: 0, recordCount: 0, balance: 0, totalIncome: 0, carbonCoin: 0, todayCount: 0,
    todayReduction: 0, todayEarned: 0, travelCount: 0, recycleKg: 0, streak: 0, frameCount: 0,
    badgeUnlocked: 0, badgeTotal: LiteralConstants.BADGE_TOTAL, treeEquivalent: 0, carKmEquivalent: 0, hasRecord: false
  };
  return stats;
}
