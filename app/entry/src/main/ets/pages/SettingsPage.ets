/**
 * SettingsPage —— 设置（附录 C §21）二级页。
 *
 * 五段：通用 / 提醒 / 数据 / 云端备份（需登录）/ 关于。
 * 全部开关落 `app_config`（`AppState.set*`）；数据操作一律走 `ServiceHub`，
 * 备份提示必须同时给出**路径与文件大小**（验收 D5-1），备份记录每条含**时间 + 大小**（D5-10）。
 */
import { NavParams, RouteName } from '../viewmodel/RouteName';
import { ServiceHub } from '../viewmodel/ServiceHub';
import { BackupOutcome, BackupItem } from '../viewmodel/BackupService';
import { AppResult } from '../model/Result';
import { FileEntry } from '../viewmodel/store/FilesPort';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { PageHeader } from '../components/PageHeader';
import { SectionCard } from '../components/SectionCard';
import { BackupListSheet } from '../components/BackupListSheet';
import { LoginDialog } from '../components/LoginDialog';

@Component
export struct SettingsPage {
  @State demoMode: boolean = false;
  @State aiEnabled: boolean = true;
  @State remindDaily: boolean = false;
  @State remindTime: string = '20:00';
  @State remindGoal: boolean = true;
  @State loggedIn: boolean = false;
  @State loginName: string = '';
  @State busy: boolean = false;
  @State showBackups: boolean = false;
  @State showLogin: boolean = false;
  @State showClear: boolean = false;
  @State clearText: string = '';
  @State loginPending: boolean = false;
  @State loginMessage: string = '';
  @State backups: FileEntry[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.demoMode = hub.state.isDemo();
    this.aiEnabled = hub.state.isAiEnabled();
    this.remindDaily = hub.state.isRemindDaily();
    this.remindTime = hub.state.remindTimeValue();
    this.remindGoal = hub.state.isRemindGoal();
    this.loggedIn = hub.state.isLoggedIn();
    this.loginName = hub.state.loginName();
    this.backups = await hub.backup.list();
  }

  private toast(msg: string | Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });
  }

  private async toggleDemo(on: boolean): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    await hub.state.setDemoMode(on, Date.now());
    this.demoMode = on;
  }

  private async toggleAi(on: boolean): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    await hub.state.setAiEnabled(on);
    this.aiEnabled = on;
  }

  private async toggleRemindDaily(on: boolean): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    await hub.state.setRemindDaily(on);
    this.remindDaily = on;
    this.toast(on ? $r('app.string.set_remind_on') : $r('app.string.set_remind_off'));
  }

  private async toggleRemindGoal(on: boolean): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    await hub.state.setRemindGoal(on);
    this.remindGoal = on;
  }

  private pickTime(): void {
    const parts: string[] = this.remindTime.split(':');
    const hour: number = parts.length === 2 ? Number.parseInt(parts[0], 10) : 20;
    const minute: number = parts.length === 2 ? Number.parseInt(parts[1], 10) : 0;
    const selected: Date = new Date();
    selected.setHours(hour);
    selected.setMinutes(minute);
    TimePickerDialog.show({
      selected: selected,
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        const h: number = value.hour;
        const m: number = value.minute;
        const text: string = `${h < 10 ? '0' : ''}${h}:${m < 10 ? '0' : ''}${m}`;
        this.remindTime = text;
        ServiceHub.get().state.setRemindTime(text);
      }
    });
  }

  private async doBackup(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.busy = true;
    const res: AppResult<BackupOutcome> = await hub.backup.create(Date.now());
    this.busy = false;
    if (res.ok && res.data !== undefined) {
      this.toast($r('app.string.backup_done_note', res.data.path, Formatter.fileSize(res.data.size)));
    } else {
      this.toast(res.message !== undefined ? res.message : '备份失败');
    }
    this.backups = await hub.backup.list();
  }

  private async doRestoreLatest(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const latest: BackupItem | undefined = await hub.backup.latest();
    if (latest === undefined) {
      this.toast($r('app.string.set_restore_none'));
      return;
    }
    this.busy = true;
    const res = await hub.backup.restore(latest.path, true);
    this.busy = false;
    this.toast(res.ok ? $r('app.string.set_restore_ok') : (res.message !== undefined ? res.message : '恢复失败'));
  }

  private async doExport(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.busy = true;
    const res = await hub.exportCsv.export(hub.state.userId(), Date.now());
    this.busy = false;
    if (res.ok && res.data !== undefined) {
      this.toast($r('app.string.set_export_ok', res.data.rowCount));
    } else {
      this.toast(res.message !== undefined ? res.message : '导出失败');
    }
  }

  private async doClearAll(): Promise<void> {
    if (this.clearText !== LiteralConstants.CLEAR_CONFIRM_WORD) {
      this.toast($r('app.string.set_clear_wrong'));
      return;
    }
    const hub: ServiceHub = ServiceHub.get();
    this.busy = true;
    const removed: number = await hub.backup.clearAll(hub.state.userId());
    this.busy = false;
    this.showClear = false;
    this.clearText = '';
    this.toast($r('app.string.set_clear_ok', removed));
  }

  private async doCheckText(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const hits: string[] = await hub.share.violations(hub.state.userId(), Date.now());
    if (hits.length === 0) {
      this.toast($r('app.string.set_text_ok'));
    } else {
      this.toast($r('app.string.set_text_bad', hits.join('、')));
    }
  }

  private async doUpload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.busy = true;
    const res = await hub.sync.fullUpload(hub.state.userId(), Date.now());
    this.busy = false;
    this.toast(res.ok ? $r('app.string.set_upload_ok') : (res.message !== undefined ? res.message : '上传失败'));
  }

  private async doCloudRestore(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.busy = true;
    const res = await hub.sync.fullRestore(hub.state.userId(), Date.now());
    this.busy = false;
    this.toast(res.ok ? $r('app.string.set_cloud_restore_ok') : (res.message !== undefined ? res.message : '恢复失败'));
  }

  private async doLogout(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    await hub.auth.logout(Date.now());
    await hub.state.setAuth({ accountUserId: '', loginName: '', loggedIn: false }, Date.now());
    this.loggedIn = false;
    this.loginName = '';
    this.toast($r('app.string.sync_logout_done'));
  }

  @Builder
  rowLink(label: Resource, value: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
        .layoutWeight(1)
      if (value.length > 0) {
        Text(value)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
      }
      Text('›')
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_HINT)
    }
    .width('100%')
    .height(AppTheme.BTN_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .onClick(action)
  }

  @Builder
  rowToggle(label: Resource, checked: boolean, onChange: (on: boolean) => void) {
    Row() {
      Text(label)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor(AppTheme.COLOR_PRIMARY)
        .onChange((on: boolean) => onChange(on))
    }
    .width('100%')
    .height(AppTheme.BTN_HEIGHT)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      PageHeader({ title: $r('app.string.set_title'), onBack: (): void => {
        NavParams.pop();
      } })
      Scroll() {
        Column({ space: AppTheme.CARD_GAP }) {
          SectionCard({ title: $r('app.string.set_group_general') }) {
            Column() {
              this.rowToggle($r('app.string.set_demo_mode'), this.demoMode, (on: boolean) => { this.toggleDemo(on); })
              this.rowToggle($r('app.string.set_ai_enabled'), this.aiEnabled, (on: boolean) => { this.toggleAi(on); })
            }
            .width('100%')
          }

          SectionCard({ title: $r('app.string.set_group_remind') }) {
            Column() {
              this.rowToggle($r('app.string.set_remind_daily'), this.remindDaily, (on: boolean) => { this.toggleRemindDaily(on); })
              this.rowLink($r('app.string.set_remind_time'), this.remindTime, () => this.pickTime())
              this.rowToggle($r('app.string.set_remind_goal'), this.remindGoal, (on: boolean) => { this.toggleRemindGoal(on); })
            }
            .width('100%')
          }

          SectionCard({ title: $r('app.string.set_group_data') }) {
            Column() {
              this.rowLink($r('app.string.set_backup_local'), this.busy ? '…' : '', () => this.doBackup())
              this.rowLink($r('app.string.set_backup_list'), `${this.backups.length}`, () => { this.showBackups = true; })
              this.rowLink($r('app.string.set_restore_local'), '', () => this.doRestoreLatest())
              this.rowLink($r('app.string.set_export_csv'), '', () => this.doExport())
              this.rowLink($r('app.string.set_clear_all'), '', () => { this.showClear = true; })
            }
            .width('100%')
          }

          SectionCard({ title: $r('app.string.set_group_cloud') }) {
            Column({ space: 4 }) {
              if (this.loggedIn) {
                Row({ space: 2 }) {
                  Text($r('app.string.set_cloud_account'))
                    .fontSize(AppTheme.FONT_CAPTION)
                    .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                  Text(this.loginName)
                    .fontSize(AppTheme.FONT_CAPTION)
                    .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                this.rowLink($r('app.string.set_cloud_upload'), '', () => this.doUpload())
                this.rowLink($r('app.string.set_cloud_restore'), '', () => this.doCloudRestore())
                this.rowLink($r('app.string.set_logout'), '', () => this.doLogout())
                this.rowLink($r('app.string.set_delete_account'), '', () => { this.showLogin = true; })
              } else {
                Row() {
                  Text($r('app.string.set_cloud_need_login'))
                    .fontSize(AppTheme.FONT_CAPTION)
                    .fontColor(AppTheme.COLOR_TEXT_HINT)
                    .layoutWeight(1)
                  Button($r('app.string.login_action'))
                    .height(AppTheme.BTN_HEIGHT)
                    .fontSize(AppTheme.FONT_CAPTION)
                    .backgroundColor(AppTheme.COLOR_PRIMARY)
                    .fontColor(AppTheme.COLOR_SURFACE)
                    .borderRadius(AppTheme.BTN_RADIUS)
                    .onClick(() => { this.showLogin = true; })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
              }
              Text($r('app.string.set_cloud_note'))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_HINT)
            }
            .width('100%')
          }

          SectionCard({ title: $r('app.string.set_group_about') }) {
            Column() {
              this.rowLink($r('app.string.set_about_link'), '', (): void => {
                NavParams.push(RouteName.ABOUT);
              })
              this.rowLink($r('app.string.set_text_check'), '', () => this.doCheckText())
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
    .bindSheet($$this.showBackups, this.backupSheet(), {
      detents: [SheetSize.MEDIUM],
      backgroundColor: AppTheme.COLOR_SURFACE,
      onDisappear: () => { this.showBackups = false; }
    })
    .bindSheet($$this.showLogin, this.loginSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      backgroundColor: AppTheme.COLOR_SURFACE,
      onDisappear: () => { this.showLogin = false; }
    })
    .bindSheet($$this.showClear, this.clearSheet(), {
      detents: [SheetSize.MEDIUM],
      backgroundColor: AppTheme.COLOR_SURFACE,
      onDisappear: () => { this.showClear = false; }
    })
  }

  @Builder
  backupSheet() {
    Column() {
      BackupListSheet({
        entries: this.backups,
        pending: this.busy,
        onDelete: (path: string) => {
          this.doRemoveBackup(path);
        },
        onCleanup: () => {
          this.doCleanup();
        },
        onClose: () => { this.showBackups = false; }
      })
    }
    .padding(AppTheme.PAGE_PADDING)
  }

  @Builder
  loginSheet() {
    Column() {
      LoginDialog({
        loggedIn: this.loggedIn,
        loginName: this.loginName,
        pending: this.loginPending,
        message: this.loginMessage,
        onLogin: (username: string, password: string) => { this.doLogin(username, password); },
        onRegister: (username: string, password: string) => { this.doRegister(username, password); },
        onLogout: () => { this.showLogin = false; this.doLogout(); },
        onDeleteAccount: (password: string) => { this.doDeleteAccount(password); },
        onClose: () => { this.showLogin = false; }
      })
    }
    .padding(AppTheme.PAGE_PADDING)
  }

  @Builder
  clearSheet() {
    Column({ space: AppTheme.CARD_GAP }) {
      Text($r('app.string.set_clear_title'))
        .fontSize(AppTheme.FONT_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
      Text($r('app.string.set_clear_note'))
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_DANGER)
      TextInput({ text: this.clearText, placeholder: $r('app.string.set_clear_placeholder') })
        .height(AppTheme.BTN_HEIGHT)
        .fontSize(AppTheme.FONT_BODY)
        .backgroundColor(AppTheme.COLOR_BG)
        .borderRadius(AppTheme.BTN_RADIUS)
        .onChange((v: string) => { this.clearText = v; })
      Row({ space: AppTheme.CARD_GAP }) {
        Button($r('app.string.common_cancel'))
          .layoutWeight(1)
          .height(AppTheme.BTN_HEIGHT)
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => { this.showClear = false; this.clearText = ''; })
        Button($r('app.string.set_clear_confirm'))
          .layoutWeight(1)
          .height(AppTheme.BTN_HEIGHT)
          .backgroundColor(AppTheme.COLOR_DANGER)
          .fontColor(AppTheme.COLOR_SURFACE)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => this.doClearAll())
      }
      .width('100%')
    }
    .padding(AppTheme.PAGE_PADDING)
    .alignItems(HorizontalAlign.Start)
  }

  private async doRemoveBackup(path: string): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    await hub.backup.remove(path);
    this.backups = await hub.backup.list();
  }

  private async doCleanup(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const removed: number = await hub.backup.cleanOld();
    this.toast($r('app.string.backup_clean_note', removed));
    this.backups = await hub.backup.list();
  }

  private async doLogin(username: string, password: string): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.loginPending = true;
    this.loginMessage = '';
    const res = await hub.auth.login(username, password, Date.now());
    this.loginPending = false;
    if (res.ok && res.data !== undefined) {
      if (res.data.migrated > 0) {
        this.toast($r('app.string.login_merge_note', res.data.migrated));
      }
      this.showLogin = false;
      await this.reload();
    } else {
      this.loginMessage = res.message !== undefined ? res.message : '登录失败';
    }
  }

  private async doRegister(username: string, password: string): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.loginPending = true;
    this.loginMessage = '';
    const res = await hub.auth.register(username, password, Date.now());
    this.loginPending = false;
    if (res.ok) {
      this.toast($r('app.string.login_register_ok'));
      this.showLogin = false;
      await this.reload();
    } else {
      this.loginMessage = res.message !== undefined ? res.message : '注册失败';
    }
  }

  private async doDeleteAccount(password: string): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.loginPending = true;
    const res = await hub.auth.deleteAccount(password);
    this.loginPending = false;
    if (res.ok) {
      this.showLogin = false;
      this.toast($r('app.string.login_delete_ok'));
      await this.reload();
    } else {
      this.loginMessage = res.message !== undefined ? res.message : '注销失败';
    }
  }
}
