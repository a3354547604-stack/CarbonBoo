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

  /** 进度数字走统一口径（最多 2 位、裁掉末尾 0）：徽章格很窄，四位小数会撑破卡片。 */
  private short(v: number): string {
    return Formatter.progress(v);
  }

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
        Text(`${this.short(this.badge.progress)}/${this.short(this.badge.threshold)}`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        // 已解锁不再重复「纯荣誉」说明：页脚已统一说明一次，格子内只留达成时间占位
        Text('已解锁')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_PRIMARY)
          .maxLines(1)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
