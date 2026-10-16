/**
 * GoalPage —— 目标（附录 C §13，二级页 `goal`）。
 *
 * 11 条目标的进度与结算全部由 `RewardService` 产出（进度覆盖、settled 永不回退），
 * 页面只按 tier 分组渲染，不做任何阈值比较。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { RouteName, NavParams } from '../viewmodel/RouteName';
import { GoalCard } from '../viewmodel/domain/RewardEngine';
import { AppTheme } from '../util/AppTheme';
import { PageHeader } from '../components/PageHeader';
import { SegmentedBar, Segments } from '../components/SegmentedBar';
import { GoalItem } from '../components/GoalItem';
import { EmptyView } from '../components/EmptyView';
import { LoadingOverlay } from '../components/LoadingOverlay';

@Component
export struct GoalPage {
  @Consume('navStack') stack: NavPathStack;
  @State cards: GoalCard[] = [];
  @State tier: string = 'short';
  @State ready: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.cards = await hub.reward.goalCards(hub.state.userId(), Date.now());
    this.ready = true;
  }

  private ofTier(tier: string): GoalCard[] {
    const out: GoalCard[] = [];
    let i: number = 0;
    while (i < this.cards.length) {
      if (this.cards[i].tier === tier) {
        out.push(this.cards[i]);
      }
      i = i + 1;
    }
    return out;
  }

  private groupTitle(): string {
    if (this.tier === 'short') {
      return '短期目标（每日 / 每周）';
    }
    if (this.tier === 'mid') {
      return '中长期目标（月 / 季 / 年）';
    }
    return '长期目标 · 种树百天计划';
  }

  private weekHint(): string {
    return this.tier === 'short' ? '周目标按自然周计算，周一 00:00 起算' : '';
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.goal_title'),
        onBack: () => this.stack.pop()
      }) {
        Text($r('app.string.badge_title'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_PRIMARY)
          .height(AppTheme.HEADER_HEIGHT)
          .onClick(() => {
            NavParams.set(undefined);
            this.stack.pushPath({ name: RouteName.BADGE });
          })
      }

      Column({ space: AppTheme.CARD_GAP }) {
        SegmentedBar({
          options: Segments.GOAL_TIER,
          selected: this.tier,
          onSelect: (key: string) => {
            this.tier = key;
          }
        })

        Text(this.groupTitle())
          .fontSize(AppTheme.FONT_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .width('100%')

        if (this.weekHint().length > 0) {
          Text(this.weekHint())
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_HINT)
            .width('100%')
        }

        if (!this.ready) {
          LoadingOverlay({ visible: true, text: '' })
        } else if (this.ofTier(this.tier).length === 0) {
          EmptyView({ text: '这个分组还没有目标', hint: '' })
        } else {
          Scroll() {
            Column({ space: AppTheme.CARD_GAP }) {
              ForEach(this.ofTier(this.tier), (card: GoalCard) => {
                Column() {
                  GoalItem({ card: card })
                }
                .width('100%')
                .padding(AppTheme.CARD_PADDING)
                .backgroundColor(AppTheme.COLOR_SURFACE)
                .borderRadius(AppTheme.CARD_RADIUS)
              }, (card: GoalCard) => card.goalId + card.periodKey)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ top: AppTheme.CARD_GAP })
    }
    .width('100%')
    .height('100%')
    .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
    .backgroundColor(AppTheme.COLOR_BG)
  }
}
