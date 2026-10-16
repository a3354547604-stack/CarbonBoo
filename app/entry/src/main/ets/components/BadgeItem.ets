/**
 * BadgeItem —— 徽章格（附录 C §4 / §14）：图标 + 名称 +（未解锁时）条件与进度条。
 */
import { BadgeProgress } from '../model/BadgeTypes';
import { AppTheme } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { ProgressBarView } from './ProgressBarView';

export function emptyBadgeProgress(): BadgeProgress {
  const b: BadgeProgress = {
    badgeId: '', name: '', description: '', icon: '', unlocked: false, progress: 0, threshold: 0, percent: 0
  };
  return b;
}

@Component
export struct BadgeItem {
  @Prop badge: BadgeProgress = emptyBadgeProgress();
  @Prop condition: string = '';

  build() {
    Column({ space: 6 }) {
      Text(this.badge.icon.length > 0 ? this.badge.icon : '🏅')
        .fontSize(AppTheme.ICON_LG)
        .opacity(this.badge.unlocked ? 1 : 0.35)
      Text(this.badge.name)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(this.badge.unlocked ? AppTheme.COLOR_TEXT_PRIMARY : AppTheme.COLOR_TEXT_HINT)
        .maxLines(1)
      if (!this.badge.unlocked) {
        Text(this.condition.length > 0 ? this.condition : this.badge.description)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        ProgressBarView({ percent: this.badge.percent })
        Text(`${Formatter.number(this.badge.progress, 'factor')}/${Formatter.number(this.badge.threshold, 'factor')}`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
      } else {
        Text($r('app.string.badge_honor_only'))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
          .maxLines(1)
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }
}
