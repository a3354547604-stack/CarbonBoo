/**
 * SegmentedBar —— 分段切换控件（附录 C §6/§13/§15/§16 的 [日][周][月][年] 等）。
 * 自绘而不引 Advanced 组件：颜色走 AppTheme，选中态是主色底 + 白字。
 */
import { AppTheme } from '../util/AppTheme';

export class SegmentOption {
  key: string = '';
  label: string = '';

  static of(key: string, label: string): SegmentOption {
    const o: SegmentOption = new SegmentOption();
    o.key = key;
    o.label = label;
    return o;
  }
}

@Component
export struct SegmentedBar {
  @Prop options: SegmentOption[] = [];
  @Prop selected: string = '';
  onSelect: (key: string) => void = () => {};

  build() {
    Row() {
      ForEach(this.options, (opt: SegmentOption) => {
        Text(opt.label)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.selected === opt.key ? AppTheme.COLOR_SURFACE : AppTheme.COLOR_TEXT_SECONDARY)
          .backgroundColor(this.selected === opt.key ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_SURFACE)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(AppTheme.BTN_HEIGHT * 0.7)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => this.onSelect(opt.key))
      }, (opt: SegmentOption) => opt.key)
    }
    .width('100%')
    .padding(2)
    .backgroundColor(AppTheme.COLOR_SURFACE)
    .borderRadius(AppTheme.BTN_RADIUS)
  }
}

/** 常用分段集合。 */
export class Segments {
  static readonly GRAIN: SegmentOption[] = [
    SegmentOption.of('day', '日'), SegmentOption.of('week', '周'),
    SegmentOption.of('month', '月'), SegmentOption.of('year', '年')
  ];
  static readonly GOAL_TIER: SegmentOption[] = [
    SegmentOption.of('short', '短期'), SegmentOption.of('mid', '中长期'), SegmentOption.of('long', '长期')
  ];
  static readonly FLOW: SegmentOption[] = [
    SegmentOption.of('all', '全部'), SegmentOption.of('income', '收入'), SegmentOption.of('spend', '支出')
  ];
  static readonly SHOP: SegmentOption[] = [
    SegmentOption.of('frame', '头像框'), SegmentOption.of('theme', '主题')
  ];
  static readonly CATEGORY: SegmentOption[] = [
    SegmentOption.of('all', '全部'), SegmentOption.of('travel', '出行'), SegmentOption.of('utility', '水电'),
    SegmentOption.of('recycle', '回收'), SegmentOption.of('plate', '光盘')
  ];
  static readonly SCIENCE: SegmentOption[] = [
    SegmentOption.of('all', '全部'), SegmentOption.of('policy', '政策'), SegmentOption.of('tips', '低碳技巧'),
    SegmentOption.of('knowledge', '知识')
  ];
}
