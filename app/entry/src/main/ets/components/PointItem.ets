/**
 * PointItem —— 积分流水行（附录 C §4 / §16）：标题 + 时间 + 带符号分值。
 * 收入绿色、支出橙色；被封顶的流水带 ⚠️ 与「(应得 n)」括注（remark 由 ViewModel 组装）。
 */
import { PointRecord, PointType } from '../model/PointTypes';
import { AppTheme } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';

export function emptyPointRecord(): PointRecord {
  const p: PointRecord = {
    id: '', userId: '', createdAt: 0, updatedAt: 0, isDeleted: 0, syncState: 'local',
    type: 'record', flowKind: 'primary', points: 0, sourceType: 'carbon_record',
    sourceId: '', title: '', occurredAt: 0
  };
  return p;
}

/** 积分类型的中文名（附录 C §16）。 */
export function pointTypeName(type: PointType): string {
  if (type === 'record') {
    return '减排记录';
  }
  if (type === 'record_capped') {
    return '减排记录（受限）';
  }
  if (type === 'goal') {
    return '目标';
  }
  if (type === 'purchase') {
    return '碳小铺';
  }
  if (type === 'carbon_include') {
    return '碳普惠';
  }
  return '调整';
}

@Component
export struct PointItem {
  @Prop record: PointRecord = emptyPointRecord();

  build() {
    Row({ space: AppTheme.CARD_GAP }) {
      Column({ space: 2 }) {
        Text(this.record.title)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 6 }) {
          Text(Formatter.dateTime(this.record.occurredAt))
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_HINT)
          if (this.record.type === 'record_capped') {
            Text('⚠️').fontSize(AppTheme.FONT_CAPTION)
          }
          if (this.record.remark !== undefined && this.record.remark.length > 0) {
            Text(this.record.remark)
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppTheme.COLOR_WARNING)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(Formatter.pointsSigned(this.record.points))
        .fontSize(AppTheme.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.record.points < 0 ? AppTheme.COLOR_WARNING : AppTheme.COLOR_PRIMARY)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }
}
