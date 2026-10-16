/**
 * RecordItem —— 记录行内容（附录 C §4 / §7）：图标 + 子类名 + 活动量 + 减排量 + 积分 + 时间。
 * 左滑动作由页面用 ListItem.swipeAction 提供（组件只管内容，不管手势）。
 * 子类显示名由页面从 ViewModel 传入（因子库的 `name`），组件不查库、不自算。
 */
import { CarbonRecord, CategoryKey } from '../model/CarbonTypes';
import { AppTheme } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';

/** 空记录（@Prop 需要一个本地初值；真实数据永远由页面传入）。 */
export function emptyRecord(): CarbonRecord {
  const blank: CarbonRecord = {
    id: '', userId: '', createdAt: 0, updatedAt: 0, isDeleted: 0, syncState: 'local',
    category: 'travel', subType: 'walk', amount: 0, unit: 'km', occurredAt: 0,
    reductionKg: 0, factorValue: 0, factorVersion: '', factorSource: '',
    confidence: 'provisional', pointAwarded: 0, revision: 0, pointCapped: 0, isAbnormal: 0
  };
  return blank;
}

/** 分类图标（emoji 自绘，仓库内没有图标媒体资源）。 */
export function categoryIcon(category: CategoryKey): string {
  if (category === 'travel') {
    return '🚲';
  }
  if (category === 'utility') {
    return '💡';
  }
  if (category === 'recycle') {
    return '♻️';
  }
  return '🍽️';
}

@Component
export struct RecordItem {
  @Prop record: CarbonRecord = emptyRecord();
  @Prop name: string = '';
  @Prop showTime: boolean = true;

  build() {
    Row({ space: AppTheme.CARD_GAP }) {
      Text(categoryIcon(this.record.category))
        .fontSize(AppTheme.ICON_MD)
        .width(AppTheme.ICON_LG)
        .textAlign(TextAlign.Center)
      Column({ space: 2 }) {
        Text(this.name.length > 0 ? this.name : this.record.subType)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 8 }) {
          Text(`${Formatter.number(this.record.amount, 'factor')} ${this.record.unit}`)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          Text(`减排 ${Formatter.reduction(this.record.reductionKg)}`)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          if (this.record.pointCapped === 1) {
            Text('⚠️上限').fontSize(AppTheme.FONT_CAPTION).fontColor(AppTheme.COLOR_WARNING)
          }
          if (this.showTime) {
            Text(Formatter.timeOfDay(this.record.occurredAt))
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppTheme.COLOR_TEXT_HINT)
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(`+${Formatter.points(this.record.pointAwarded)}`)
        .fontSize(AppTheme.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.COLOR_PRIMARY)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }
}
