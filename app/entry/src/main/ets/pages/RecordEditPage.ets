/**
 * RecordEditPage —— 记一笔 / 编辑记录（附录 C §10，二级页 `recordEdit`）。
 *
 * 页面只做三件事：把用户输入交给 `RecordService.preview()` 拿预览、
 * 把确认后的输入交给 `RecordService.save()/edit()` 落库、把结果渲染出来。
 * 页面自己**不乘任何因子**（铁律 2），预览与账本同源。
 */
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { ServiceHub } from '../viewmodel/ServiceHub';
import { RouteParam, NavParams } from '../viewmodel/RouteName';
import { CarbonRecord, CategoryKey } from '../model/CarbonTypes';
import { AiRecognizeResult } from '../model/AiTypes';
import { RecordPreview, SaveOutcome, SaveRecordInput } from '../viewmodel/RecordService';
import { GoalDef } from '../model/GoalTypes';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { DateUtil } from '../util/DateUtil';
import { PageHeader } from '../components/PageHeader';
import { SectionCard } from '../components/SectionCard';
import { AiRecognizeSheet } from '../components/AiRecognizeSheet';
import { UnlockCelebrationDialog } from '../components/UnlockCelebrationDialog';
import { emptyAiResult } from '../components/AiRecognizeSheet';
import { categoryIcon } from '../components/RecordItem';

/** 图标网格的一项（附录 C §10 的 9 个入口）。 */
export class BehaviourOption {
  icon: string = '';
  label: string = '';
  category: CategoryKey = 'travel';
  subType: string = '';
  unit: string = '';

  static of(icon: string, label: string, category: CategoryKey, subType: string, unit: string): BehaviourOption {
    const o: BehaviourOption = new BehaviourOption();
    o.icon = icon;
    o.label = label;
    o.category = category;
    o.subType = subType;
    o.unit = unit;
    return o;
  }
}

/** 9 个网格入口（与 `carbon-factors.json` 的 subType 一一对应）。 */
export const BEHAVIOURS: BehaviourOption[] = [
  BehaviourOption.of('🚶', '步行', 'travel', 'walk', 'km'),
  BehaviourOption.of('🚲', '骑行', 'travel', 'bicycle', 'km'),
  BehaviourOption.of('🚌', '公交', 'travel', 'bus', 'km'),
  BehaviourOption.of('🚇', '地铁', 'travel', 'metro', 'km'),
  BehaviourOption.of('🚗', '拼车', 'travel', 'carpool', 'km'),
  BehaviourOption.of('💡', '节电', 'utility', 'elec_grid', 'kWh'),
  BehaviourOption.of('💧', '节水', 'utility', 'water', 'L'),
  BehaviourOption.of('♻️', '回收', 'recycle', 'paper', 'kg'),
  BehaviourOption.of('🍽️', '光盘', 'plate', 'meal', '次')
];

/** 庆祝弹窗队列的一项（目标奖励 / 徽章荣誉）。 */
class CelebrationItem {
  icon: string = '🎁';
  name: string = '';
  points: number = 0;
  badge: boolean = false;

  static goal(name: string, points: number): CelebrationItem {
    const c: CelebrationItem = new CelebrationItem();
    c.icon = '🎯';
    c.name = name;
    c.points = points;
    c.badge = false;
    return c;
  }

  static ofBadge(name: string): CelebrationItem {
    const c: CelebrationItem = new CelebrationItem();
    c.icon = '🏅';
    c.name = name;
    c.points = 0;
    c.badge = true;
    return c;
  }
}

@Component
export struct RecordEditPage {
  @Consume('navStack') stack: NavPathStack;
  @State category: CategoryKey = 'travel';
  @State subType: string = '';
  @State categoryName: string = '';
  @State unit: string = '';
  @State amountText: string = '';
  @State note: string = '';
  @State occurredAt: number = 0;
  @State preview: RecordPreview | undefined = undefined;
  @State amountError: string = '';
  @State saving: boolean = false;
  @State editing: boolean = false;
  @State recordId: string = '';
  @State showAi: boolean = false;
  @State aiResult: AiRecognizeResult = emptyAiResult();
  @State aiUri: string = '';
  @State aiPending: boolean = false;
  @State aiMessage: string = '';
  @State showCelebration: boolean = false;
  @State celebration: CelebrationItem = new CelebrationItem();
  @State formError: string = '';
  @State ready: boolean = false;
  private timer: number = -1;
  private queue: CelebrationItem[] = [];
  private queueIndex: number = 0;
  private skipped: number = 0;
  private now: number = 0;

  aboutToAppear(): void {
    const param: RouteParam = NavParams.take();
    const recordId: string | undefined = param.recordId;
    const category: CategoryKey | undefined = param.category;
    this.now = Date.now();
    this.occurredAt = this.now;
    if (recordId !== undefined) {
      this.editing = true;
      this.recordId = recordId;
      this.loadRecord(recordId);
    } else {
      this.subType = 'bicycle';
      this.category = 'travel';
      this.categoryName = '骑行';
      this.unit = 'km';
      this.ready = true;
    }
    if (category !== undefined && recordId === undefined) {
      this.pickCategoryOnly(category);
    }
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private async loadRecord(recordId: string): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const record: CarbonRecord | undefined = await hub.records.detail(hub.state.userId(), recordId);
    if (record !== undefined) {
      this.category = record.category;
      this.subType = record.subType;
      this.unit = record.unit;
      this.amountText = `${record.amount}`;
      this.note = record.note === undefined ? '' : record.note;
      this.occurredAt = record.occurredAt;
      this.categoryName = hub.records.factorItemOf(record.subType) === undefined
        ? record.subType : this.nameOf(record.subType);
    }
    this.ready = true;
    this.schedulePreview();
  }

  private nameOf(subType: string): string {
    let i: number = 0;
    while (i < BEHAVIOURS.length) {
      if (BEHAVIOURS[i].subType === subType) {
        return BEHAVIOURS[i].label;
      }
      i = i + 1;
    }
    const item = ServiceHub.get().records.factorItemOf(subType);
    return item === undefined ? subType : item.name;
  }

  private pickCategoryOnly(category: CategoryKey): void {
    let i: number = 0;
    while (i < BEHAVIOURS.length) {
      if (BEHAVIOURS[i].category === category) {
        this.pick(BEHAVIOURS[i]);
        return;
      }
      i = i + 1;
    }
  }

  private pick(option: BehaviourOption): void {
    this.category = option.category;
    this.subType = option.subType;
    this.categoryName = option.label;
    this.unit = option.unit;
    this.schedulePreview();
  }

  /** 输入变化后 200ms 才重算预览（附录 C §10 规则 1：节流 200ms）。 */
  private schedulePreview(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.recompute();
    }, LiteralConstants.PREVIEW_THROTTLE_MS);
  }

  private amount(): number {
    if (this.amountText.length === 0) {
      return 0;
    }
    const value: number = Number.parseFloat(this.amountText);
    if (Number.isNaN(value)) {
      return 0;
    }
    return value;
  }

  private async recompute(): Promise<void> {
    const value: number = this.amount();
    if (value <= 0) {
      this.preview = undefined;
      this.amountError = value < 0 ? '活动量必须大于 0' : '';
      return;
    }
    if (this.subType.length === 0) {
      this.preview = undefined;
      return;
    }
    const hub: ServiceHub = ServiceHub.get();
    const decimals: number = Math.round((value - Math.floor(value)) * 100);
    if (decimals !== (value - Math.floor(value)) * 100) {
      this.amountError = '活动量最多两位小数';
    } else {
      this.amountError = '';
    }
    const p: RecordPreview = await hub.records.preview(hub.state.userId(), {
      category: this.category, subType: this.subType, amount: value,
      occurredAt: this.occurredAt, note: this.note
    }, Date.now());
    this.preview = p;
  }

  private async pickImage(): Promise<void> {
    this.aiMessage = '';
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const selected: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (selected.photoUris.length === 0) {
        return;
      }
      const uri: string = selected.photoUris[0];
      this.aiUri = uri;
      this.aiPending = true;
      const hub: ServiceHub = ServiceHub.get();
      const result: AiRecognizeResult = await hub.ai.recognize(uri, hub.state.isAiEnabled());
      this.aiPending = false;
      if (!result.recognized) {
        this.showAi = false;
        this.formError = '识图不可用，请手动选择';
        return;
      }
      this.aiResult = result;
      this.showAi = true;
    } catch (err) {
      this.aiPending = false;
      this.formError = '识图不可用，请手动选择';
    }
  }

  private onAiConfirm(category: CategoryKey, subType: string, amount: number): void {
    this.showAi = false;
    this.category = category;
    this.subType = subType;
    this.categoryName = this.nameOf(subType);
    const item = ServiceHub.get().records.factorItemOf(subType);
    if (item !== undefined) {
      this.unit = item.unit;
    }
    if (amount > 0) {
      this.amountText = `${amount}`;
    }
    this.schedulePreview();
  }

  private async save(): Promise<void> {
    const value: number = this.amount();
    if (value <= 0 || this.saving) {
      this.formError = '活动量必须大于 0';
      return;
    }
    this.saving = true;
    this.formError = '';
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    const input: SaveRecordInput = {
      category: this.category, subType: this.subType, amount: value,
      occurredAt: this.occurredAt, note: this.note
    };
    const result = this.editing
      ? await hub.records.edit(userId, this.recordId, input, Date.now())
      : await hub.records.save(userId, input, Date.now());
    this.saving = false;
    if (!result.ok) {
      this.formError = result.message === undefined ? '保存失败' : result.message;
      return;
    }
    const outcome: SaveOutcome | undefined = result.data;
    if (outcome === undefined || !this.editing) {
      this.finish(outcome);
    } else {
      this.stack.pop();
    }
  }

  /** 保存成功后按 `newGoals` / `newBadges` 排队弹庆祝（最多连续 3 个）。 */
  private async finish(outcome: SaveOutcome | undefined): Promise<void> {
    this.queue = [];
    if (outcome === undefined) {
      this.stack.pop();
      return;
    }
    const hub: ServiceHub = ServiceHub.get();
    if (outcome.newGoals.length > 0) {
      const defs: GoalDef[] = await hub.reward.goalDefs();
      let i: number = 0;
      while (i < outcome.newGoals.length) {
        let k: number = 0;
        while (k < defs.length) {
          if (defs[k].id === outcome.newGoals[i]) {
            this.queue.push(CelebrationItem.goal(defs[k].name, defs[k].reward));
          }
          k = k + 1;
        }
        i = i + 1;
      }
    }
    let b: number = 0;
    while (b < outcome.newBadges.length) {
      this.queue.push(CelebrationItem.ofBadge(outcome.newBadges[b]));
      b = b + 1;
    }
    if (this.queue.length === 0) {
      this.stack.pop();
      return;
    }
    this.queueIndex = 0;
    this.skipped = this.queue.length > LiteralConstants.CELEBRATION_MAX
      ? this.queue.length - LiteralConstants.CELEBRATION_MAX : 0;
    this.celebration = this.queue[0];
    this.showCelebration = true;
  }

  private nextCelebration(): void {
    this.queueIndex = this.queueIndex + 1;
    if (this.queueIndex >= this.queue.length || this.queueIndex >= LiteralConstants.CELEBRATION_MAX) {
      this.showCelebration = false;
      if (this.skipped > 0) {
        this.getUIContext().getPromptAction().showToast({ message: `还有 ${this.skipped} 项奖励已发放` });
      }
      this.stack.pop();
      return;
    }
    this.celebration = this.queue[this.queueIndex];
  }

  private pickDate(): void {
    const from: number = DateUtil.addDays(this.now, -LiteralConstants.BACKDATE_DAYS);
    DatePickerDialog.show({
      start: new Date(from),
      end: new Date(this.now),
      selected: new Date(this.occurredAt),
      onDateAccept: (value: Date) => {
        const day: number = value.getTime();
        const base: Date = new Date(this.occurredAt);
        const picked: Date = new Date(day);
        picked.setHours(base.getHours(), base.getMinutes(), 0, 0);
        this.occurredAt = picked.getTime();
        this.schedulePreview();
      }
    });
  }

  @Builder
  gridItem(option: BehaviourOption) {
    Column({ space: 4 }) {
      Text(option.icon).fontSize(AppTheme.ICON_MD)
      Text(option.label)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(this.subType === option.subType ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_SECONDARY)
    }
    .width('100%')
    .height(AppTheme.BTN_HEIGHT + AppTheme.ICON_SM)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.subType === option.subType ? AppTheme.COLOR_DISABLED_BG : AppTheme.COLOR_SURFACE)
    .borderRadius(AppTheme.BTN_RADIUS)
    .onClick(() => this.pick(option))
  }

  @Builder
  previewRow(label: ResourceStr, value: string, highlight: boolean) {
    Row() {
      Text(label)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
        .layoutWeight(1)
      Text(value)
        .fontSize(AppTheme.FONT_BODY)
        .fontWeight(highlight ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(highlight ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_PRIMARY)
    }
    .width('100%')
  }

  build() {
    Column() {
      PageHeader({
        title: this.editing ? $r('app.string.record_edit_title_edit') : $r('app.string.record_edit_title_new'),
        onBack: () => this.stack.pop()
      })

      Scroll() {
        Column({ space: AppTheme.CARD_GAP }) {
          SectionCard({ title: $r('app.string.ai_entry'), showTitle: true }) {
            Row({ space: AppTheme.CARD_GAP }) {
              Text($r('app.string.ai_hint'))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                .layoutWeight(1)
              Button($r('app.string.ai_pick_image'))
                .height(AppTheme.BTN_HEIGHT)
                .backgroundColor(AppTheme.COLOR_PRIMARY)
                .fontColor(AppTheme.COLOR_SURFACE)
                .fontSize(AppTheme.FONT_BODY)
                .onClick(() => this.pickImage())
            }
            .width('100%')
          }

          SectionCard({ title: $r('app.string.record_pick_one'), showTitle: true }) {
            Grid() {
              ForEach(BEHAVIOURS, (option: BehaviourOption) => {
                GridItem() {
                  this.gridItem(option)
                }
              }, (option: BehaviourOption) => option.subType)
            }
            .columnsTemplate('1fr 1fr 1fr')
            .rowsGap(AppTheme.CARD_GAP)
            .columnsGap(AppTheme.CARD_GAP)
            .height((AppTheme.BTN_HEIGHT + AppTheme.ICON_SM) * 3 + AppTheme.CARD_GAP * 2)

            Text(`已选：${categoryIcon(this.category)} ${this.categoryName}`)
              .fontSize(AppTheme.FONT_BODY)
              .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
              .width('100%')
          }

          SectionCard({ showTitle: false }) {
            Row({ space: AppTheme.CARD_GAP }) {
              TextInput({ placeholder: $r('app.string.record_amount_hint'), text: this.amountText })
                .type(InputType.NUMBER_DECIMAL)
                .layoutWeight(1)
                .height(AppTheme.BTN_HEIGHT)
                .fontSize(AppTheme.FONT_BODY)
                .backgroundColor(AppTheme.COLOR_BG)
                .onChange((value: string) => {
                  this.amountText = value;
                  this.schedulePreview();
                })
              Text(this.unit)
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                .width(AppTheme.ICON_LG)
                .textAlign(TextAlign.Center)
            }
            .width('100%')

            Row() {
              Text($r('app.string.record_occurred_at'))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                .layoutWeight(1)
              Text(Formatter.dateTime(this.occurredAt))
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(AppTheme.COLOR_PRIMARY)
                .onClick(() => this.pickDate())
            }
            .width('100%')
            .height(AppTheme.BTN_HEIGHT)

            TextInput({ placeholder: $r('app.string.record_note_hint'), text: this.note })
              .height(AppTheme.BTN_HEIGHT)
              .fontSize(AppTheme.FONT_BODY)
              .backgroundColor(AppTheme.COLOR_BG)
              .onChange((value: string) => {
                this.note = value;
              })

            if (this.amountError.length > 0) {
              Text(this.amountError)
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_DANGER)
                .width('100%')
            }
          }

          if (this.preview !== undefined) {
            Column({ space: AppTheme.CARD_GAP }) {
              if (this.preview.capped && this.preview.actualPoint === 0) {
                Text($r('app.string.record_point_capped_full'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_WARNING)
                  .backgroundColor(AppTheme.COLOR_WARNING_BG)
                  .padding(8)
                  .borderRadius(AppTheme.BTN_RADIUS)
                  .width('100%')
              } else if (this.preview.capped) {
                Text($r('app.string.record_point_capped_hint', this.preview.actualPoint, this.preview.expectedPoint))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_WARNING)
                  .backgroundColor(AppTheme.COLOR_WARNING_BG)
                  .padding(8)
                  .borderRadius(AppTheme.BTN_RADIUS)
                  .width('100%')
              }
              if (this.preview.isAbnormal) {
                Text($r('app.string.record_abnormal_hint'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_WARNING)
                  .backgroundColor(AppTheme.COLOR_WARNING_BG)
                  .padding(8)
                  .borderRadius(AppTheme.BTN_RADIUS)
                  .width('100%')
              }
              SectionCard({ title: $r('app.string.record_preview'), showTitle: true }) {
                this.previewRow($r('app.string.record_preview_reduction'),
                  `${Formatter.reduction(this.preview.reductionKg)} kgCO₂e`, true)
                this.previewRow($r('app.string.record_preview_factor'),
                  `${Formatter.number(this.preview.factorValue, 'factor')} kg/${this.preview.unit}`, false)
                this.previewRow($r('app.string.record_preview_expected'),
                  `${Formatter.points(this.preview.expectedPoint)} 分`, false)
                this.previewRow($r('app.string.record_preview_today'),
                  `${Formatter.points(this.preview.todayEarned)} / ${Formatter.points(this.preview.cap)} 分`, false)
                this.previewRow($r('app.string.record_preview_actual'),
                  `${Formatter.points(this.preview.actualPoint)} 分`, true)
                Text($r('app.string.record_goal_not_capped'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_TEXT_HINT)
                  .width('100%')
              }
            }
          }

          if (this.formError.length > 0) {
            Text(this.formError)
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppTheme.COLOR_DANGER)
              .width('100%')
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Button(this.editing ? $r('app.string.common_save') : $r('app.string.common_save'))
        .width('100%')
        .height(AppTheme.BTN_HEIGHT)
        .margin({ bottom: AppTheme.CARD_GAP })
        .backgroundColor(this.amount() > 0 && !this.saving ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_HINT)
        .fontColor(AppTheme.COLOR_SURFACE)
        .enabled(this.amount() > 0 && !this.saving)
        .onClick(() => this.save())
    }
    .width('100%')
    .height('100%')
    .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
    .backgroundColor(AppTheme.COLOR_BG)
    .bindSheet($$this.showAi, this.aiSheetBuilder(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
      title: { title: $r('app.string.ai_title') }
    })
    .bindSheet($$this.showCelebration, this.celebrationBuilder(), {
      detents: [SheetSize.MEDIUM],
      dragBar: false,
      title: { title: $r('app.string.common_got_it') }
    })
  }

  @Builder
  aiSheetBuilder() {
    Column({ space: AppTheme.CARD_GAP }) {
      if (this.aiPending) {
        Text($r('app.string.ai_title'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
      } else {
        AiRecognizeSheet({
          result: this.aiResult,
          imageUri: this.aiUri,
          amount: this.amount(),
          unit: this.unit,
          pending: this.aiPending,
          onRequestImage: () => this.pickImage(),
          onConfirm: (category: CategoryKey, subType: string, amount: number) => {
            this.onAiConfirm(category, subType, amount);
          },
          onCancel: () => {
            this.showAi = false;
          }
        })
      }
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
  }

  @Builder
  celebrationBuilder() {
    Column({ space: AppTheme.CARD_GAP }) {
      UnlockCelebrationDialog({
        icon: this.celebration.icon,
        name: this.celebration.name,
        points: this.celebration.points,
        badge: this.celebration.badge,
        onClose: () => this.nextCelebration()
      })
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
  }
}
