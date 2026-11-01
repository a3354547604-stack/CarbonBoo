/**
 * MinePage —— 我的（附录 C §9，Tab4）。
 *
 * 三列数据概览 + 七个入口，全部数字与首页/看板/分享卡片同源（4 位小数、积分千分位）。
 * 碳普惠行尾必须带「模拟演示」小黄标（附录 C §9、§19）。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RouteName, RouteParam, NavParams } from '../viewmodel/RouteName';
import { OverviewStats } from '../viewmodel/StatsService';
import { CarbonCoin } from '../model/IncludeTypes';
import { SyncService, SyncStatus } from '../viewmodel/net/SyncService';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { DemoModeBanner } from '../components/DemoModeBanner';
import { StatCard } from '../components/StatCard';
import { ShareSheet } from '../components/ShareSheet';
import { ShareCardData } from '../util/CardRenderer';
import { emptyOverview } from './HomePage';
import { BadgeProgress } from '../model/BadgeTypes';
import { AvatarWithFrame } from '../components/AvatarWithFrame';

@Component
export struct MinePage {
  @Prop @Watch('onTick') tick: number = 0;
  @Consume('navStack') stack: NavPathStack;
  @State stats: OverviewStats = emptyOverview();
  @State coin: number = 0;
  @State frameCount: number = 0;
  @State sync: SyncStatus = SyncService.emptyStatus('');
  @State nickname: string = '';
  @State avatarId: string = 'avatar_leaf';
  /** 已佩戴的头像框（空串=不戴；由 `appearance.current()` 读回）。 */
  @State frameId: string = '';
  @State badgeUnlocked: number = 0;
  @State isDemo: boolean = false;
  @State ready: boolean = false;
  @State showShare: boolean = false;
  @State shareData: ShareCardData = new ShareCardData();
  @State shareMessage: string = '';
  @State sharing: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    const now: number = Date.now();
    const stats: OverviewStats = await hub.stats.overview(userId, now);
    const coin: CarbonCoin = await hub.include.coin(userId, now);
    const frames: number = await hub.shop.ownedFrameCount(userId);
    const sync: SyncStatus = await hub.sync.status(userId);
    const appearance = await hub.appearance.current(userId);
    // 「我的」页的徽章数与徽章墙必须同源：徽章墙按 `badgeRows` 现场判定，
    // 而 `stats.badgeUnlocked` 数的是 `user_badge` 里已落库的行——
    // 两者不一致时用户会看到「我的 0/8、徽章墙 5/8」。这里统一取现场判定。
    const badgeRows: BadgeProgress[] = await hub.reward.badgeRows(userId, now);
    let unlockedCount: number = 0;
    let bi: number = 0;
    while (bi < badgeRows.length) {
      if (badgeRows[bi].unlocked) {
        unlockedCount = unlockedCount + 1;
      }
      bi = bi + 1;
    }
    this.badgeUnlocked = unlockedCount;
    this.stats = stats;
    this.coin = coin.balance;
    this.frameCount = frames;
    this.sync = sync;
    this.nickname = hub.appearance.nicknameOf(appearance);
    this.avatarId = appearance.avatarId;
    // frameId 之前漏了赋值 → 「我的」页头像永远不戴框（用户会说「买了没生效」）
    this.frameId = appearance.frameId === undefined ? '' : appearance.frameId;
    this.isDemo = await hub.state.demoFlag();
    this.shareData = await hub.share.cardData(userId, now);
    this.ready = true;
  }

  /** 切换到某个 Tab。由 Index 注入；默认空实现，便于单独渲染本页。 */
  goTab: (index: number) => void = (index: number): void => {};

  /**
   * 与 `rowItem` 相同，但右侧文案由**闭包**现算。
   *
   * 为什么需要它：`@Builder` 的参数是按值传入的，若把 `${this.badgeUnlocked}/8 已解锁` 算好后当参数传进去，
   * 这个字符串就被钉在首帧（实测：`reload()` 已算出 5，界面仍显示 0）。改成渲染时调闭包即可拿到最新值。
   */
  @Builder
  rowItemDynamic(icon: string, label: ResourceStr, valueOf: () => string, badge: string, onTap: () => void) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(AppTheme.ICON_MD)
      Text(label)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
        .layoutWeight(1)
      if (badge.length > 0) {
        Text(badge)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_WARNING)
          .backgroundColor(AppTheme.COLOR_WARNING_BG)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
      }
      Text(valueOf())
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_HINT)
    }
    .width('100%')
    .height(AppTheme.BTN_HEIGHT)
    .onClick(() => onTap())
  }

  private push(name: string, param?: RouteParam): void {
    NavParams.set(param);
    this.stack.pushPath({ name: name });
  }

  private syncLabel(): string {
    if (!this.sync.loggedIn) {
      return '未登录';
    }
    if (this.sync.pending > 0) {
      return `已登录 · 待同步 ${this.sync.pending}`;
    }
    return '已登录 · 已同步';
  }

  private avatarIcon(): string {
    const icons: string[] = ['👤', '🌿', '💧', '🚲', '💡', '♻️', '🍽️', '🌱', '🌏'];
    const ids: string[] = ['avatar_leaf', 'avatar_drop', 'avatar_bike', 'avatar_bulb', 'avatar_recycle',
      'avatar_plate', 'avatar_sprout', 'avatar_earth'];
    const index: number = ids.indexOf(this.avatarId);
    return index < 0 ? icons[0] : icons[index + 1];
  }

  @Builder
  rowItem(icon: string, label: ResourceStr, value: string, badge: string, onTap: () => void) {
    Row({ space: AppTheme.CARD_GAP }) {
      Text(icon).fontSize(AppTheme.ICON_MD)
      Text(label)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
        .layoutWeight(1)
      if (badge.length > 0) {
        Text(badge)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_WARNING)
          .backgroundColor(AppTheme.COLOR_WARNING_BG)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
      }
      Text(value)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_HINT)
      Text('›')
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_HINT)
    }
    .width('100%')
    .height(AppTheme.BTN_HEIGHT)
    .onClick(onTap)
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Scroll() {
        Column({ space: AppTheme.CARD_GAP }) {
          if (this.isDemo) {
            DemoModeBanner()
          }

          Row({ space: AppTheme.CARD_GAP }) {
            AvatarWithFrame({ avatarId: this.avatarId, frameId: this.frameId, diameter: AppTheme.AVATAR_SIZE })
            Column({ space: 4 }) {
              Text(this.nickname)
                .fontSize(AppTheme.FONT_SECTION)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
              Text($r('app.string.mine_change_appearance'))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_PRIMARY)
                .onClick(() => this.push(RouteName.APPEARANCE))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: AppTheme.CARD_GAP }) {
            StatCard({
              label: $r('app.string.mine_total_reduction'),
              value: `${Formatter.reduction(this.stats.totalReduction)} kg`,
              onTap: () => this.goTab(1)
            })
            StatCard({
              label: $r('app.string.mine_point_balance'),
              value: `${Formatter.points(this.stats.balance)} 分`,
              onTap: () => this.push(RouteName.POINT_LOG)
            })
            StatCard({
              label: $r('app.string.mine_coin_balance'),
              value: `${Formatter.coin(this.coin)} 碳币`,
              onTap: () => this.push(RouteName.INCLUDE)
            })
          }
          .width('100%')

          Column() {
            this.rowItemDynamic('🎯', $r('app.string.mine_goal_badge'),
              (): string => `${this.badgeUnlocked}/${LiteralConstants.BADGE_TOTAL} 已解锁 ›`, '',
              () => this.push(RouteName.GOAL))
            this.rowItemDynamic('🏪', $r('app.string.mine_shop'),
              (): string => `${this.frameCount} 个头像框 ›`, '',
              () => this.push(RouteName.SHOP))
            this.rowItem('🧾', $r('app.string.mine_point_log'), '›', '',
              () => this.push(RouteName.POINT_LOG))
            this.rowItem('🌿', $r('app.string.mine_include'),
              `${Formatter.coin(this.coin)} 碳币 ›`, '模拟演示', () => this.push(RouteName.INCLUDE))
            this.rowItem('📱', $r('app.string.mine_sync'), `${this.syncLabel()} ›`, '',
              () => this.push(RouteName.SYNC))
          }
          .width('100%')
          .padding({ left: AppTheme.CARD_PADDING, right: AppTheme.CARD_PADDING })
          .backgroundColor(AppTheme.COLOR_SURFACE)
          .borderRadius(AppTheme.CARD_RADIUS)

          Column() {
            this.rowItem('📤', $r('app.string.share_title'), '›', '', () => {
              this.showShare = true;
            })
            this.rowItem('⚙️', $r('app.string.mine_settings'), '›', '',
              () => this.push(RouteName.SETTINGS))
          }
          .width('100%')
          .padding({ left: AppTheme.CARD_PADDING, right: AppTheme.CARD_PADDING })
          .backgroundColor(AppTheme.COLOR_SURFACE)
          .borderRadius(AppTheme.CARD_RADIUS)
        }
        .width('100%')
        .padding(AppTheme.PAGE_PADDING)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .bindSheet($$this.showShare, this.shareSheetBuilder(), {
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        dragBar: true,
        title: { title: $r('app.string.share_title') }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.COLOR_BG)
  }

  @Builder
  shareSheetBuilder() {
    ShareSheet({
      data: this.shareData,
      pending: this.sharing,
      message: this.shareMessage,
      onSave: (size: string) => this.saveCard(size),
      onShare: (size: string) => this.saveCard(size),
      onClose: () => {
        this.showShare = false;
      }
    })
  }

  private async saveCard(size: string): Promise<void> {
    this.sharing = true;
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    const result = await hub.share.saveCard(userId, size, this.shareData, Date.now());
    this.sharing = false;
    if (result.ok) {
      this.shareMessage = '卡片已保存到相册';
      await hub.share.markShared(userId, size, this.shareData, Date.now());
    } else {
      this.shareMessage = result.message === undefined ? '保存失败' : result.message;
    }
  }
}
