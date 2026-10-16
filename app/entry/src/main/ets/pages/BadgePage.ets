/**
 * BadgePage —— 徽章墙（附录 C §14，二级页 `badge`）。
 *
 * 8 枚徽章按 `badge_def."order"` 排列；未解锁也**必须**显示条件与进度条；
 * 徽章是纯荣誉体系，不发积分、不可消费（`UnlockCelebrationDialog` 同口径）。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { BadgeDef, BadgeProgress } from '../model/BadgeTypes';
import { BadgeEngine } from '../viewmodel/domain/BadgeEngine';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { PageHeader } from '../components/PageHeader';
import { BadgeItem } from '../components/BadgeItem';
import { LoadingOverlay } from '../components/LoadingOverlay';

@Component
export struct BadgePage {
  @Consume('navStack') stack: NavPathStack;
  @State badges: BadgeProgress[] = [];
  @State conditions: Map<string, string> = new Map();
  @State unlocked: number = 0;
  @State ready: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    const now: number = Date.now();
    const badges: BadgeProgress[] = await hub.reward.badgeRows(userId, now);
    const defs: BadgeDef[] = await hub.reward.badgeDefs();
    const conditions: Map<string, string> = new Map();
    let i: number = 0;
    let count: number = 0;
    while (i < defs.length) {
      conditions.set(defs[i].id, BadgeEngine.conditionOf(defs[i]));
      i = i + 1;
    }
    i = 0;
    while (i < badges.length) {
      if (badges[i].unlocked) {
        count = count + 1;
      }
      i = i + 1;
    }
    this.badges = badges;
    this.conditions = conditions;
    this.unlocked = count;
    this.ready = true;
  }

  private ofUnlocked(flag: boolean): BadgeProgress[] {
    const out: BadgeProgress[] = [];
    let i: number = 0;
    while (i < this.badges.length) {
      if (this.badges[i].unlocked === flag) {
        out.push(this.badges[i]);
      }
      i = i + 1;
    }
    return out;
  }

  private conditionOf(id: string): string {
    const text: string | undefined = this.conditions.get(id);
    return text === undefined ? '' : text;
  }

  @Builder
  badgeGrid(list: BadgeProgress[]) {
    Grid() {
      ForEach(list, (badge: BadgeProgress) => {
        GridItem() {
          Column() {
            BadgeItem({ badge: badge, condition: this.conditionOf(badge.badgeId) })
          }
          .width('100%')
          .padding(AppTheme.CARD_GAP)
          .backgroundColor(AppTheme.COLOR_SURFACE)
          .borderRadius(AppTheme.CARD_RADIUS)
        }
      }, (badge: BadgeProgress) => badge.badgeId)
    }
    .columnsTemplate('1fr 1fr 1fr')
    .rowsGap(AppTheme.CARD_GAP)
    .columnsGap(AppTheme.CARD_GAP)
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.badge_title'),
        onBack: () => this.stack.pop()
      }) {
        Text(`${this.unlocked}/${LiteralConstants.BADGE_TOTAL} 已解锁`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .height(AppTheme.HEADER_HEIGHT)
      }

      if (!this.ready) {
        LoadingOverlay({ visible: true, text: '' })
      } else {
        Scroll() {
          Column({ space: AppTheme.CARD_GAP }) {
            Text($r('app.string.badge_unlocked'))
              .fontSize(AppTheme.FONT_SECTION)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
              .width('100%')
            this.badgeGrid(this.ofUnlocked(true))

            Text($r('app.string.badge_lockd'))
              .fontSize(AppTheme.FONT_SECTION)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
              .width('100%')
            this.badgeGrid(this.ofUnlocked(false))

            Text($r('app.string.badge_honor_only'))
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppTheme.COLOR_TEXT_HINT)
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
    .backgroundColor(AppTheme.COLOR_BG)
  }
}
