/**
 * AppearancePage —— 外观（附录 C §20，二级页 `appearance`）。
 *
 * 8 个头像全部免费任选；头像框只有已购买的可用（未拥有置灰 + 🔒）；
 * 昵称选填（≤12 字，留空显示「碳小布用户」）。保存写 `user_appearance`。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { Appearance } from '../model/ShopTypes';
import { AvatarOption } from '../viewmodel/AppearanceService';
import { ShopItem } from '../model/ShopTypes';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { AppConstants } from '../util/AppConstants';
import { PageHeader } from '../components/PageHeader';
import { SectionCard } from '../components/SectionCard';
import { LoadingOverlay } from '../components/LoadingOverlay';

@Component
export struct AppearancePage {
  @Consume('navStack') stack: NavPathStack;
  @State avatars: AvatarOption[] = [];
  @State frames: ShopItem[] = [];
  @State owned: string[] = [];
  @State avatarId: string = 'avatar_leaf';
  @State frameId: string = '';
  @State themeId: string = 'theme_default';
  @State nickname: string = '';
  @State saving: boolean = false;
  @State ready: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    const current: Appearance = await hub.appearance.current(userId);
    this.avatars = await hub.appearance.avatars();
    this.frames = await hub.shop.items('frame');
    this.owned = await hub.shop.ownedIds(userId);
    this.avatarId = current.avatarId;
    this.frameId = current.frameId === undefined ? '' : current.frameId;
    this.themeId = current.themeId;
    this.nickname = current.nickname === undefined ? '' : current.nickname;
    this.ready = true;
  }

  private avatarIcon(id: string): string {
    const ids: string[] = ['avatar_leaf', 'avatar_drop', 'avatar_bike', 'avatar_bulb', 'avatar_recycle',
      'avatar_plate', 'avatar_sprout', 'avatar_earth'];
    const icons: string[] = ['🌿', '💧', '🚲', '💡', '♻️', '🍽️', '🌱', '🌏'];
    const index: number = ids.indexOf(id);
    return index < 0 ? '🌿' : icons[index];
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    const hub: ServiceHub = ServiceHub.get();
    const nickname: string = this.nickname.length > LiteralConstants.NICKNAME_MAX
      ? this.nickname.substring(0, LiteralConstants.NICKNAME_MAX) : this.nickname;
    const result = await hub.appearance.save(hub.state.userId(), this.avatarId, this.frameId, this.themeId, nickname);
    this.saving = false;
    if (result.ok) {
      this.getUIContext().getPromptAction().showToast({ message: '外观已保存' });
      await hub.state.refreshDisplayName();
      this.stack.pop();
    } else {
      this.getUIContext().getPromptAction().showToast({
        message: result.message === undefined ? '保存失败' : result.message
      });
    }
  }

  @Builder
  avatarCell(option: AvatarOption) {
    Column({ space: 4 }) {
      Text(this.avatarIcon(option.id))
        .fontSize(AppTheme.ICON_MD)
        .width(AppTheme.AVATAR_SIZE * 0.72)
        .height(AppTheme.AVATAR_SIZE * 0.72)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.avatarId === option.id ? AppTheme.COLOR_DISABLED_BG : AppTheme.COLOR_BG)
        .borderRadius(AppTheme.AVATAR_SIZE)
        .borderWidth(this.avatarId === option.id ? 2 : 0)
        .borderColor(AppTheme.COLOR_PRIMARY)
      Text(option.name)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(this.avatarId === option.id ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_HINT)
    }
    .onClick(() => {
      this.avatarId = option.id;
    })
  }

  @Builder
  frameCell(id: string, name: ResourceStr) {
    Column({ space: 4 }) {
      Text(this.owned.indexOf(id) >= 0 ? '🖼️' : '🔒')
        .fontSize(AppTheme.ICON_MD)
        .opacity(this.owned.indexOf(id) >= 0 ? 1 : 0.35)
      Text(name)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(this.frameId === id ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_HINT)
    }
    .onClick(() => {
      if (this.owned.indexOf(id) < 0) {
        this.getUIContext().getPromptAction().showToast({ message: '请先到碳小铺兑换' });
        return;
      }
      this.frameId = this.frameId === id ? '' : id;
    })
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.appearance_title'),
        onBack: () => this.stack.pop()
      })

      if (!this.ready) {
        LoadingOverlay({ visible: true, text: '' })
      } else {
        Scroll() {
          Column({ space: AppTheme.CARD_GAP }) {
            SectionCard({ showTitle: false }) {
              Row({ space: AppTheme.CARD_GAP }) {
                Text(this.avatarIcon(this.avatarId))
                  .fontSize(AppTheme.ICON_LG)
                  .width(AppTheme.AVATAR_SIZE)
                  .height(AppTheme.AVATAR_SIZE)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(AppTheme.COLOR_DISABLED_BG)
                  .borderRadius(AppTheme.AVATAR_SIZE)
                Column({ space: 6 }) {
                  Text(this.nickname.length > 0 ? this.nickname : AppConstants.DEFAULT_DISPLAY_NAME)
                    .fontSize(AppTheme.FONT_SECTION)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                  TextInput({ placeholder: $r('app.string.appearance_nickname_hint'), text: this.nickname })
                    .height(AppTheme.BTN_HEIGHT * 0.8)
                    .fontSize(AppTheme.FONT_CAPTION)
                    .backgroundColor(AppTheme.COLOR_BG)
                    .maxLength(LiteralConstants.NICKNAME_MAX)
                    .onChange((value: string) => {
                      this.nickname = value;
                    })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
            }

            SectionCard({ title: $r('app.string.appearance_avatars'), showTitle: true }) {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                ForEach(this.avatars, (option: AvatarOption) => {
                  Column() {
                    this.avatarCell(option)
                  }
                  .width('24%')
                  .padding({ top: 6, bottom: 6 })
                }, (option: AvatarOption) => option.id)
              }
              .width('100%')
            }

            SectionCard({ title: $r('app.string.appearance_frames'), showTitle: true }) {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                Column() {
                  this.frameCell('', $r('app.string.appearance_frame_none'))
                }
                .width('24%')
                .padding({ top: 6, bottom: 6 })
                ForEach(this.frames, (frame: ShopItem) => {
                  Column() {
                    this.frameCell(frame.id, frame.name)
                  }
                  .width('24%')
                  .padding({ top: 6, bottom: 6 })
                }, (frame: ShopItem) => frame.id)
              }
              .width('100%')
            }

            SectionCard({ title: $r('app.string.appearance_theme'), showTitle: true }) {
              Row() {
                Text($r('app.string.appearance_theme_default'))
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                  .layoutWeight(1)
                Text($r('app.string.shop_in_use'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_PRIMARY)
              }
              .width('100%')
            }

            Button($r('app.string.common_save'))
              .width('100%')
              .height(AppTheme.BTN_HEIGHT)
              .backgroundColor(AppTheme.COLOR_PRIMARY)
              .fontColor(AppTheme.COLOR_SURFACE)
              .enabled(!this.saving)
              .onClick(() => this.save())
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
