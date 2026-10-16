/**
 * ShopPage —— 碳小铺（附录 C §15，二级页 `shop`，参数 `section?`）。
 *
 * 购买判定全部来自 `ShopRules.check()`（可购/已拥有/还差 n 分），
 * 页面只负责把结果画出来；确认购买走 `RedeemConfirmDialog` → `ShopService.purchase()`。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { RouteParam, NavParams, RouteName } from '../viewmodel/RouteName';
import { ShopItem } from '../model/ShopTypes';
import { PointBalance } from '../model/PointTypes';
import { PurchaseOutcome } from '../viewmodel/ShopService';
import { PurchaseCheck, ShopRules } from '../viewmodel/domain/ShopRules';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { PageHeader } from '../components/PageHeader';
import { SegmentedBar, Segments } from '../components/SegmentedBar';
import { ShopItemCard } from '../components/ShopItemCard';
import { RedeemConfirmDialog } from '../components/RedeemConfirmDialog';
import { LoadingOverlay } from '../components/LoadingOverlay';

@Component
export struct ShopPage {
  @Consume('navStack') stack: NavPathStack;
  @State section: string = 'frame';
  @State items: ShopItem[] = [];
  @State owned: string[] = [];
  @State balance: PointBalance | undefined = undefined;
  @State frameCount: number = 0;
  @State inUseFrame: string = '';
  @State pendingItem: ShopItem | undefined = undefined;
  @State showConfirm: boolean = false;
  @State pending: boolean = false;
  @State ready: boolean = false;

  aboutToAppear(): void {
    const param: RouteParam = NavParams.take();
    const section: string | undefined = param.section;
    if (section !== undefined) {
      this.section = section;
    }
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    this.items = await hub.shop.items(this.section === 'theme' ? 'theme' : 'frame');
    this.owned = await hub.shop.ownedIds(userId);
    this.balance = await hub.points.balance(userId, Date.now());
    this.frameCount = await hub.shop.ownedFrameCount(userId);
    const appearance = await hub.appearance.current(userId);
    this.inUseFrame = appearance.frameId === undefined ? '' : appearance.frameId;
    this.ready = true;
  }

  private balanceValue(): number {
    return this.balance === undefined ? 0 : this.balance.balance;
  }

  private askBuy(item: ShopItem): void {
    const check: PurchaseCheck = ShopRules.check(item, this.balanceValue(), this.owned.indexOf(item.id) >= 0);
    if (!check.allowed) {
      this.getUIContext().getPromptAction().showToast({
        message: check.message.length === 0 ? '当前不可兑换' : check.message
      });
      return;
    }
    this.pendingItem = item;
    this.showConfirm = true;
  }

  private async confirmBuy(): Promise<void> {
    if (this.pendingItem === undefined || this.pending) {
      return;
    }
    this.pending = true;
    const item: ShopItem = this.pendingItem;
    const hub: ServiceHub = ServiceHub.get();
    const result = await hub.shop.purchase(hub.state.userId(), item.id);
    this.pending = false;
    this.showConfirm = false;
    if (!result.ok) {
      this.getUIContext().getPromptAction().showToast({
        message: result.message === undefined ? '兑换失败' : result.message
      });
      return;
    }
    const outcome: PurchaseOutcome | undefined = result.data;
    if (outcome !== undefined && outcome.treeReady) {
      this.getUIContext().getPromptAction().showToast({ message: '集齐全部 8 个头像框，解锁「种树人」' });
    }
    await this.reload();
  }

  private priceText(): string {
    if (this.pendingItem === undefined) {
      return '';
    }
    return `${Formatter.points(this.pendingItem.price)} 分`;
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.shop_title'),
        onBack: () => this.stack.pop()
      }) {
        Text(`余额 ${Formatter.points(this.balanceValue())} 分`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .height(AppTheme.HEADER_HEIGHT)
      }

      Column({ space: AppTheme.CARD_GAP }) {
        SegmentedBar({
          options: Segments.SHOP,
          selected: this.section,
          onSelect: (key: string) => {
            this.section = key;
            this.reload();
          }
        })

        if (!this.ready) {
          LoadingOverlay({ visible: true, text: '' })
        } else {
          Grid() {
            ForEach(this.items, (item: ShopItem) => {
              GridItem() {
                ShopItemCard({
                  item: item,
                  owned: this.owned.indexOf(item.id) >= 0,
                  affordable: this.balanceValue() >= item.price,
                  shortfall: ShopRules.shortfall(this.balanceValue(), item.price),
                  inUse: this.inUseFrame === item.id,
                  onBuy: () => this.askBuy(item)
                })
              }
            }, (item: ShopItem) => item.id)
          }
          .columnsTemplate('1fr 1fr')
          .rowsGap(AppTheme.CARD_GAP)
          .columnsGap(AppTheme.CARD_GAP)
          .layoutWeight(1)

          Text(`已拥有 ${this.frameCount}/${LiteralConstants.FRAME_TOTAL} 个头像框 · 集齐全部 8 个解锁「种树人」`)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_HINT)
            .width('100%')
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
    .bindSheet($$this.showConfirm, this.confirmBuilder(), {
      detents: [SheetSize.MEDIUM],
      dragBar: true,
      title: { title: $r('app.string.shop_title') }
    })
  }

  @Builder
  confirmBuilder() {
    Column({ space: AppTheme.CARD_GAP }) {
      RedeemConfirmDialog({
        title: this.pendingItem === undefined ? '' : this.pendingItem.name,
        priceText: this.priceText(),
        balanceText: `${Formatter.points(this.balanceValue())} 分`,
        afterText: `${Formatter.points(ShopRules.balanceAfter(this.balanceValue(), this.pendingItem === undefined ? 0 : this.pendingItem.price))} 分`,
        pending: this.pending,
        onConfirm: () => this.confirmBuy(),
        onCancel: () => {
          this.showConfirm = false;
        }
      })
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
  }
}
