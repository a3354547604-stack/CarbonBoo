/**
 * IncludePage —— 碳普惠（模拟）（附录 C §19，二级页 `include`）。
 *
 * 顶部「模拟演示」提示条**常驻**（任何滚动位置都不得被遮挡）；
 * 所有权益名自带「模拟」前缀，碳币单向不可逆（本页没有回兑积分的入口）。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { CarbonCoin, CarbonIncludeRecord, IncludeBenefit } from '../model/IncludeTypes';
import { PointBalance } from '../model/PointTypes';
import { ExchangeOutcome, RedeemOutcome } from '../viewmodel/IncludeService';
import { AppTheme } from '../util/AppTheme';
import { AppConstants } from '../util/AppConstants';
import { Formatter } from '../util/Formatter';
import { PageHeader } from '../components/PageHeader';
import { SectionCard } from '../components/SectionCard';
import { SimulationBanner } from '../components/SimulationBanner';
import { RedeemConfirmDialog } from '../components/RedeemConfirmDialog';
import { LoadingOverlay } from '../components/LoadingOverlay';

@Component
export struct IncludePage {
  @Consume('navStack') stack: NavPathStack;
  @State coin: CarbonCoin | undefined = undefined;
  @State balance: PointBalance | undefined = undefined;
  @State benefits: IncludeBenefit[] = [];
  @State records: CarbonIncludeRecord[] = [];
  @State count: number = 1;
  @State showExchange: boolean = false;
  @State pendingBenefit: IncludeBenefit | undefined = undefined;
  @State showRedeem: boolean = false;
  @State pending: boolean = false;
  @State ready: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    const now: number = Date.now();
    this.coin = await hub.include.coin(userId, now);
    this.balance = await hub.points.balance(userId, now);
    this.benefits = await hub.include.benefits();
    this.records = await hub.include.records(userId, 20);
    this.ready = true;
  }

  private exchangeable(): number {
    return this.coin === undefined ? 0 : this.coin.exchangeable;
  }

  private coinBalance(): number {
    return this.coin === undefined ? 0 : this.coin.balance;
  }

  private points(): number {
    return this.balance === undefined ? 0 : this.balance.balance;
  }

  private cost(): number {
    return this.count * AppConstants.CARBON_COIN_RATE;
  }

  private less(): void {
    if (this.count > 1) {
      this.count = this.count - 1;
    }
  }

  private more(): void {
    if (this.count < this.exchangeable()) {
      this.count = this.count + 1;
    }
  }

  private async confirmExchange(): Promise<void> {
    if (this.pending) {
      return;
    }
    this.pending = true;
    const hub: ServiceHub = ServiceHub.get();
    const result = await hub.include.exchange(hub.state.userId(), this.count);
    this.pending = false;
    this.showExchange = false;
    if (!result.ok) {
      this.getUIContext().getPromptAction().showToast({
        message: result.message === undefined ? '兑换失败' : result.message
      });
      return;
    }
    const outcome: ExchangeOutcome | undefined = result.data;
    if (outcome !== undefined) {
      this.getUIContext().getPromptAction().showToast({
        message: `已兑换 ${outcome.coinGained} 碳币（模拟）`
      });
    }
    await this.reload();
  }

  private async confirmRedeem(): Promise<void> {
    if (this.pending || this.pendingBenefit === undefined) {
      return;
    }
    this.pending = true;
    const benefit: IncludeBenefit = this.pendingBenefit;
    const hub: ServiceHub = ServiceHub.get();
    const result = await hub.include.redeem(hub.state.userId(), benefit.id);
    this.pending = false;
    this.showRedeem = false;
    if (!result.ok) {
      this.getUIContext().getPromptAction().showToast({
        message: result.message === undefined ? '兑换失败' : result.message
      });
      return;
    }
    const outcome: RedeemOutcome | undefined = result.data;
    if (outcome !== undefined) {
      this.getUIContext().getPromptAction().showToast({ message: `已兑换「${outcome.benefitName}」` });
    }
    await this.reload();
  }

  @Builder
  recordRow(row: CarbonIncludeRecord) {
    Row() {
      Text(row.action === 'exchange'
        ? `积分 → 碳币：−${Formatter.points(row.pointsSpent)} 分 +${row.coinAmount} 碳币`
        : `${row.benefitName === undefined ? '模拟权益' : row.benefitName}：−${row.coinAmount} 碳币`)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
        .layoutWeight(1)
      Text(Formatter.monthDay(row.occurredAt))
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_HINT)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.include_title'),
        onBack: () => this.stack.pop()
      })

      SimulationBanner({ mode: 'include' })

      if (!this.ready) {
        LoadingOverlay({ visible: true, text: '' })
      } else {
        Scroll() {
          Column({ space: AppTheme.CARD_GAP }) {
            SectionCard({ showTitle: false }) {
              Text(`${Formatter.coin(this.coinBalance())} 碳币`)
                .fontSize(AppTheme.FONT_NUMBER_LG)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppTheme.COLOR_PRIMARY)
                .width('100%')
              Text(`可用积分 ${Formatter.points(this.points())} → 可兑 ${this.exchangeable()} 碳币`)
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                .width('100%')
              Text('汇率：100 积分 = 1 碳币')
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_HINT)
                .width('100%')
            }

            SectionCard({ title: $r('app.string.include_exchange'), showTitle: true }) {
              Row({ space: AppTheme.CARD_GAP }) {
                Text('−')
                  .fontSize(AppTheme.FONT_NUMBER_MD)
                  .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                  .width(AppTheme.BTN_HEIGHT)
                  .height(AppTheme.BTN_HEIGHT)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(AppTheme.COLOR_DISABLED_BG)
                  .borderRadius(AppTheme.BTN_RADIUS)
                  .onClick(() => this.less())
                Text(`${this.count}`)
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                Text('＋')
                  .fontSize(AppTheme.FONT_NUMBER_MD)
                  .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                  .width(AppTheme.BTN_HEIGHT)
                  .height(AppTheme.BTN_HEIGHT)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(AppTheme.COLOR_DISABLED_BG)
                  .borderRadius(AppTheme.BTN_RADIUS)
                  .onClick(() => this.more())
                Button($r('app.string.include_exchange_now'))
                  .height(AppTheme.BTN_HEIGHT)
                  .backgroundColor(this.count >= 1 && this.exchangeable() >= this.count
                    ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_HINT)
                  .fontColor(AppTheme.COLOR_SURFACE)
                  .fontSize(AppTheme.FONT_BODY)
                  .enabled(this.exchangeable() >= this.count)
                  .onClick(() => {
                    this.showExchange = true;
                  })
              }
              .width('100%')
            }

            SectionCard({ title: $r('app.string.include_benefits'), showTitle: true }) {
              ForEach(this.benefits, (benefit: IncludeBenefit) => {
                Row({ space: AppTheme.CARD_GAP }) {
                  Text('🎁').fontSize(AppTheme.ICON_MD)
                  Column({ space: 2 }) {
                    Text(benefit.name)
                      .fontSize(AppTheme.FONT_BODY)
                      .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                    Text(benefit.description)
                      .fontSize(AppTheme.FONT_CAPTION)
                      .fontColor(AppTheme.COLOR_TEXT_HINT)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Text(`${benefit.coinCost} 碳币`)
                    .fontSize(AppTheme.FONT_CAPTION)
                    .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                  Button($r('app.string.common_confirm'))
                    .height(AppTheme.BTN_HEIGHT * 0.7)
                    .fontSize(AppTheme.FONT_CAPTION)
                    .backgroundColor(this.coinBalance() >= benefit.coinCost
                      ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_HINT)
                    .fontColor(AppTheme.COLOR_SURFACE)
                    .enabled(this.coinBalance() >= benefit.coinCost)
                    .onClick(() => {
                      this.pendingBenefit = benefit;
                      this.showRedeem = true;
                    })
                }
                .width('100%')
                .padding({ top: 6, bottom: 6 })
              }, (benefit: IncludeBenefit) => benefit.id)
            }

            SectionCard({ title: $r('app.string.include_records'), showTitle: true }) {
              if (this.records.length === 0) {
                Text('还没有兑换记录')
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_TEXT_HINT)
                  .width('100%')
              } else {
                ForEach(this.records, (row: CarbonIncludeRecord) => {
                  this.recordRow(row)
                }, (row: CarbonIncludeRecord) => row.id)
              }
            }
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
    .bindSheet($$this.showExchange, this.exchangeBuilder(), {
      detents: [SheetSize.MEDIUM],
      dragBar: true,
      title: { title: $r('app.string.include_exchange') }
    })
    .bindSheet($$this.showRedeem, this.redeemBuilder(), {
      detents: [SheetSize.MEDIUM],
      dragBar: true,
      title: { title: $r('app.string.include_benefits') }
    })
  }

  @Builder
  exchangeBuilder() {
    Column({ space: AppTheme.CARD_GAP }) {
      RedeemConfirmDialog({
        title: `兑换 ${this.count} 碳币（模拟）`,
        priceText: `${Formatter.points(this.cost())} 分`,
        balanceText: `${Formatter.points(this.points())} 分`,
        afterText: `${Formatter.points(this.points() - this.cost())} 分`,
        pending: this.pending,
        onConfirm: () => this.confirmExchange(),
        onCancel: () => {
          this.showExchange = false;
        }
      })
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
  }

  @Builder
  redeemBuilder() {
    Column({ space: AppTheme.CARD_GAP }) {
      RedeemConfirmDialog({
        title: this.pendingBenefit === undefined ? '' : this.pendingBenefit.name,
        priceText: this.pendingBenefit === undefined ? '' : `${this.pendingBenefit.coinCost} 碳币`,
        balanceText: `${this.coinBalance()} 碳币`,
        afterText: `${this.coinBalance() - (this.pendingBenefit === undefined ? 0 : this.pendingBenefit.coinCost)} 碳币`,
        pending: this.pending,
        onConfirm: () => this.confirmRedeem(),
        onCancel: () => {
          this.showRedeem = false;
        }
      })
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
  }
}
