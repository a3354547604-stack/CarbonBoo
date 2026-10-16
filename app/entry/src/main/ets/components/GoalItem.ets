/**
 * GoalItem —— 目标行（附录 C §4 / §13）：名称 + 周期标签 + 奖励分 + 进度条 + 数字 + 状态。
 */
import { GoalCard } from '../viewmodel/domain/RewardEngine';
import { AppTheme } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { ProgressBarView } from './ProgressBarView';

export function emptyGoalCard(): GoalCard {
  const card: GoalCard = {
    goalId: '', name: '', tier: 'short', periodKey: '', progress: 0, threshold: 0, reward: 0,
    settled: false, percent: 0, periodLabel: '', unit: '', remainLabel: ''
  };
  return card;
}

@Component
export struct GoalItem {
  @Prop card: GoalCard = emptyGoalCard();

  build() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(this.card.name)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .layoutWeight(1)
        Text(this.card.periodLabel)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
        Text(`+${Formatter.points(this.card.reward)} 分`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_PRIMARY)
      }
      .width('100%')
      ProgressBarView({ percent: this.card.percent, color: this.card.settled ? AppTheme.COLOR_ACCENT : AppTheme.COLOR_PRIMARY })
      Row({ space: 8 }) {
        Text(`${Formatter.number(this.card.progress, 'factor')}/${Formatter.number(this.card.threshold, 'factor')} ${this.card.unit}`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .layoutWeight(1)
        Text(this.card.settled ? $r('app.string.goal_settled') : this.card.remainLabel)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.card.settled ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_HINT)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
  }
}
