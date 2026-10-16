/**
 * AboutPage —— 关于与合规（附录 C §22）二级页。
 *
 * 七段**必须齐全**且不得删减：一、数据说明；二、碳因子来源；三、模拟功能声明；
 * 四、隐私政策；五、用户协议；六、开源与致谢；七、免责声明。
 * 正文全部来自 string 资源（内置静态文案，不联网）。
 *
 * 隐藏入口：连续点击版本号 7 次打开 `DevOptionsSheet`（附录 C §23.6，验收 C4/C5）。
 */
import { RouteName } from '../viewmodel/RouteName';
import { ServiceHub, DevStats } from '../viewmodel/ServiceHub';
import { NavParams } from '../viewmodel/RouteName';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { PageHeader } from '../components/PageHeader';
import { SectionCard } from '../components/SectionCard';
import { DevOptionsSheet } from '../components/DevOptionsSheet';

@Component
export struct AboutPage {
  @State tapCount: number = 0;
  @State showDev: boolean = false;
  @State breakSave: boolean = false;
  @State busy: boolean = false;
  @State lastMessage: ResourceStr = '';
  @State stats: DevStats = { dbSizeBytes: 0, recordCount: 0, pointBalance: 0 };

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.breakSave = hub.state.dev().breakSave;
    this.stats = await hub.devStats(hub.state.userId(), Date.now());
  }

  private toast(msg: string | Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });
  }

  private onVersionTap(): void {
    this.tapCount = this.tapCount + 1;
    if (this.tapCount >= LiteralConstants.DEV_TAP_COUNT) {
      this.tapCount = 0;
      this.showDev = true;
      this.reload();
    } else if (this.tapCount >= LiteralConstants.DEV_TAP_COUNT - 3) {
      this.toast($r('app.string.about_dev_hint', LiteralConstants.DEV_TAP_COUNT - this.tapCount));
    }
  }

  @Builder
  paragraph(title: Resource, body: Resource) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(AppTheme.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
      Text(body)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
        .lineHeight(22)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      PageHeader({ title: $r('app.string.about_title'), onBack: (): void => {
        NavParams.pop();
      } })
      Scroll() {
        Column({ space: AppTheme.CARD_GAP }) {
          SectionCard({ title: $r('app.string.about_app_name') }) {
            Column({ space: 6 }) {
              Row({ space: AppTheme.CARD_GAP }) {
                Text('🌱').fontSize(AppTheme.ICON_LG)
                Column({ space: 2 }) {
                  Text($r('app.string.app_display_name'))
                    .fontSize(AppTheme.FONT_TITLE)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                  Text($r('app.string.about_version_line'))
                    .fontSize(AppTheme.FONT_CAPTION)
                    .fontColor(AppTheme.COLOR_TEXT_HINT)
                    .onClick(() => this.onVersionTap())
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              Text($r('app.string.about_platform_line'))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          SectionCard({ title: $r('app.string.about_group_policy') }) {
            Column({ space: AppTheme.CARD_GAP }) {
              this.paragraph($r('app.string.about_sec_data_title'), $r('app.string.about_sec_data_body'))
              this.paragraph($r('app.string.about_sec_factor_title'), $r('app.string.about_sec_factor_body'))
              this.paragraph($r('app.string.about_sec_mock_title'), $r('app.string.about_sec_mock_body'))
            }
            .width('100%')
          }

          SectionCard({ title: $r('app.string.about_sec_privacy_title') }) {
            Column({ space: AppTheme.CARD_GAP }) {
              Text($r('app.string.about_sec_privacy_body'))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                .lineHeight(22)
              Text($r('app.string.about_sec_terms_title'))
                .fontSize(AppTheme.FONT_BODY)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
              Text($r('app.string.about_sec_terms_body'))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                .lineHeight(22)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          SectionCard({ title: $r('app.string.about_group_more') }) {
            Column({ space: AppTheme.CARD_GAP }) {
              this.paragraph($r('app.string.about_sec_oss_title'), $r('app.string.about_sec_oss_body'))
              this.paragraph($r('app.string.about_sec_disclaimer_title'), $r('app.string.about_sec_disclaimer_body'))
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding(AppTheme.PAGE_PADDING)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.COLOR_BG)
    .bindSheet($$this.showDev, this.devSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      backgroundColor: AppTheme.COLOR_SURFACE,
      onDisappear: () => { this.showDev = false; }
    })
  }

  @Builder
  devSheet() {
    Column() {
      DevOptionsSheet({
        breakSave: this.breakSave,
        dbSizeBytes: this.stats.dbSizeBytes,
        recordCount: this.stats.recordCount,
        pointBalance: this.stats.pointBalance,
        busy: this.busy,
        lastMessage: this.lastMessage,
        onToggleBreakSave: (on: boolean) => {
          this.doToggleBreakSave(on);
        },
        onRebuildDailyStat: () => {
          this.doRebuild();
        },
        onSeedDemo: () => {
          this.doSeed();
        },
        onClearDemo: () => {
          this.doClearDemo();
        },
        onClose: () => { this.showDev = false; }
      })
    }
    .padding(AppTheme.PAGE_PADDING)
  }

  private async doToggleBreakSave(on: boolean): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    await hub.setBreakSave(on, Date.now());
    this.breakSave = on;
    this.lastMessage = on ? $r('app.string.dev_break_on') : $r('app.string.dev_break_off');
  }

  private async doRebuild(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.busy = true;
    const rebuilt: number = await hub.points.rebuildDailyStat(hub.state.userId(), Date.now());
    this.busy = false;
    this.lastMessage = `point_daily_stat 已重建 ${rebuilt} 天`;
    await this.reload();
  }

  private async doSeed(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.busy = true;
    const res = await hub.demo.seed(Date.now());
    this.busy = false;
    if (res.ok && res.data !== undefined) {
      this.lastMessage = `演示数据已播种：${res.data.records} 条 · ${Formatter.reduction(res.data.reductionKg)} kg · ${Formatter.points(res.data.pointBalance)} 分`;
    } else {
      this.lastMessage = res.message !== undefined ? res.message : '播种失败';
    }
    await this.reload();
  }

  private async doClearDemo(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.busy = true;
    const removed: number = await hub.demo.clear();
    this.busy = false;
    this.lastMessage = `已清除演示数据 ${removed} 行`;
    await this.reload();
  }
}
