/**
 * SyncPage —— 设备协同（附录 C §18）二级页。
 *
 * 三层内容（附录 C §18.1–§18.3）：
 *  ① 账号与云端同步：账号卡 + 云端同步卡（待同步 / 最后同步 / 冲突记录 / 本机与其他设备）；
 *  ② 家庭碳积分（只读，登录后可见）：按 `device_id` 去重后只读求和，**不合并账本、不改写流水**；
 *  ③ 近场演示：设备列表 + 发现设备 + 三段进度（无对端时显「未发现已配对设备」）。
 *
 * 分层：本页不写 SQL、不算任何碳数值，全部经 `ServiceHub.sync` 取数；
 * 字段口径由 `SyncService` 承担（待同步 = 参与同步 9 表 `sync_state='pending'` 行数之和）。
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { RouteName } from '../viewmodel/RouteName';
import { ServiceHub } from '../viewmodel/ServiceHub';
import { NavParams } from '../viewmodel/RouteName';
import { DevicePeer, SyncSessionState } from '../model/SyncTypes';
import { FamilyMember, FamilySummary, SyncService, SyncStatus } from '../viewmodel/net/SyncService';
import { SyncLogRow } from '../viewmodel/store/RowMapper';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { PageHeader } from '../components/PageHeader';
import { SectionCard } from '../components/SectionCard';
import { EmptyView } from '../components/EmptyView';
import { LoginDialog } from '../components/LoginDialog';

@Component
export struct SyncPage {
  @State status: SyncStatus = SyncService.emptyStatus('');
  @State family: FamilySummary = SyncService.emptyFamily();
  @State peers: DevicePeer[] = [];
  @State logs: SyncLogRow[] = [];
  @State showLogs: boolean = false;
  @State showLogin: boolean = false;
  @State syncing: boolean = false;
  @State errorMsg: string = '';
  @State progressText: ResourceStr = '';
  @State pulledCount: number = -1;
  @State pushedCount: number = -1;
  @State loginPending: boolean = false;
  @State loginMessage: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  private userId(): string {
    return ServiceHub.get().state.userId();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const uid: string = this.userId();
    const now: number = Date.now();
    const st: SyncStatus = await hub.sync.status(uid);
    this.status = st;
    this.family = await hub.sync.family(uid);
    this.peers = await hub.sync.discover();
    this.logs = await hub.sync.logs(uid, LiteralConstants.SYNC_LOG_LIMIT);
  }

  private toast(msg: string | Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private deviceText(): string {
    const id: string = this.status.deviceId;
    return id.length > 0 ? id : '—';
  }

  private async doSync(): Promise<void> {
    if (this.syncing) {
      return;
    }
    const hub: ServiceHub = ServiceHub.get();
    this.syncing = true;
    this.errorMsg = '';
    this.progressText = $r('app.string.sync_step_merging');
    const res = await hub.sync.sync(this.userId(), Date.now());
    this.syncing = false;
    this.progressText = '';
    if (res.ok && res.data !== undefined) {
      this.toast($r('app.string.sync_done_note', res.data.accepted, res.data.conflicts));
    } else {
      this.errorMsg = res.message !== undefined ? res.message : '同步失败';
    }
    await this.reload();
  }

  private async doNearField(peer: DevicePeer): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.progressText = $r('app.string.sync_step_discovering');
    const res = await hub.sync.nearFieldSync(peer, Date.now());
    this.progressText = $r('app.string.sync_step_writing');
    const state: SyncSessionState | undefined = res.data;
    if (state !== undefined) {
      this.pulledCount = state.pulledCount;
      this.pushedCount = state.pushedCount;
    }
    setTimeout(() => {
      this.progressText = '';
      this.pulledCount = -1;
      this.pushedCount = -1;
    }, 1200);
    await this.reload();
  }

  private async doDiscover(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.peers = await hub.sync.discover();
    if (this.peers.length === 0) {
      this.toast($r('app.string.sync_no_peer'));
    }
  }

  private async doLogout(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    await hub.auth.logout(Date.now());
    await hub.state.setAuth({ accountUserId: '', loginName: '', loggedIn: false }, Date.now());
    this.toast($r('app.string.sync_logout_done'));
    await this.reload();
  }

  @Builder
  statRow(label: ResourceStr, value: ResourceStr) {
    Row() {
      Text(label)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
        .layoutWeight(1)
      Text(value)
        .fontSize(AppTheme.FONT_BODY)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  memberRow(member: FamilyMember) {
    Row() {
      Text(member.label)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
        .layoutWeight(2)
      Text(`${Formatter.reduction(member.reductionKg)} kg`)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
        .layoutWeight(2)
      Text(`${Formatter.points(member.points)}`)
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: 1 }, color: AppTheme.COLOR_DIVIDER })
  }

  build() {
    Column() {
      PageHeader({ title: $r('app.string.sync_title'), onBack: (): void => {
        NavParams.pop();
      } })
      Scroll() {
        Column({ space: AppTheme.CARD_GAP }) {
          // ── 18.1 账号与云端同步 ───────────────────────────────────────────
          SectionCard({ title: $r('app.string.sync_account_section') }) {
            Column({ space: AppTheme.CARD_GAP }) {
              Row() {
                Text('👤').fontSize(AppTheme.ICON_MD)
                if (this.status.loggedIn) {
                  Row({ space: 2 }) {
                    Text($r('app.string.sync_logged_in'))
                      .fontSize(AppTheme.FONT_BODY)
                      .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                    Text(this.status.userLabel)
                      .fontSize(AppTheme.FONT_BODY)
                      .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                      .fontWeight(FontWeight.Medium)
                  }
                  .layoutWeight(1)
                  .margin({ left: AppTheme.CARD_GAP })
                } else {
                  Text($r('app.string.sync_not_logged_in'))
                    .fontSize(AppTheme.FONT_BODY)
                    .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                    .layoutWeight(1)
                    .margin({ left: AppTheme.CARD_GAP })
                }
                Button(this.status.loggedIn ? $r('app.string.sync_logout') : $r('app.string.login_action'))
                  .height(AppTheme.BTN_HEIGHT)
                  .fontSize(AppTheme.FONT_CAPTION)
                  .backgroundColor(this.status.loggedIn ? AppTheme.COLOR_SURFACE : AppTheme.COLOR_PRIMARY)
                  .fontColor(this.status.loggedIn ? AppTheme.COLOR_TEXT_SECONDARY : AppTheme.COLOR_SURFACE)
                  .borderRadius(AppTheme.BTN_RADIUS)
                  .onClick(() => {
                    if (this.status.loggedIn) {
                      this.doLogout();
                    } else {
                      this.showLogin = true;
                    }
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              this.statRow($r('app.string.sync_pending'), `${this.status.pending}`)
              this.statRow($r('app.string.sync_last_time'),
                this.status.lastSyncAt > 0 ? Formatter.dateTime(this.status.lastSyncAt) : $r('app.string.sync_never'))
              this.statRow($r('app.string.sync_conflicts'),
                `${this.status.conflictCount}`)
              Row() {
                Text($r('app.string.sync_devices'))
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                  .layoutWeight(1)
                Text($r('app.string.sync_this_device'))
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                Text(this.deviceText())
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                Text(' · ')
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppTheme.COLOR_TEXT_HINT)
                Text($r('app.string.sync_other_devices'))
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                Text(`${this.status.peerCount}`)
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                Text($r('app.string.sync_device_unit'))
                  .fontSize(AppTheme.FONT_BODY)
                  .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
              }
              .width('100%')
              .padding({ top: 6, bottom: 6 })

              Button(this.syncing ? $r('app.string.sync_running') : $r('app.string.sync_now'))
                .width('100%')
                .height(AppTheme.BTN_HEIGHT)
                .backgroundColor(AppTheme.COLOR_PRIMARY)
                .fontColor(AppTheme.COLOR_SURFACE)
                .borderRadius(AppTheme.BTN_RADIUS)
                .enabled(this.status.loggedIn && !this.syncing)
                .onClick(() => this.doSync())

              if (!this.status.loggedIn) {
                Text($r('app.string.sync_need_login'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_TEXT_HINT)
              }
              if (this.errorMsg.length > 0) {
                Text(this.errorMsg)
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_DANGER)
                  .width('100%')
              }
              if (this.progressText !== '') {
                Text(this.progressText)
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
              }
              if (this.pulledCount >= 0) {
                this.statRow($r('app.string.sync_pulled'), `${this.pulledCount}`)
                this.statRow($r('app.string.sync_pushed'), `${this.pushedCount}`)
              }
              if (this.logs.length > 0) {
                Text(this.showLogs ? $r('app.string.sync_logs_hide') : $r('app.string.sync_logs_show'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_PRIMARY)
                  .onClick(() => { this.showLogs = !this.showLogs; })
                if (this.showLogs) {
                  ForEach(this.logs, (row: SyncLogRow) => {
                    Row() {
                      Text(Formatter.dateTime(row.startedAt))
                        .fontSize(AppTheme.FONT_CAPTION)
                        .fontColor(AppTheme.COLOR_TEXT_HINT)
                        .layoutWeight(1)
                      Text(`${row.status} · ${row.pulledCount}/${row.pushedCount} · ⚠️${row.conflictCount}`)
                        .fontSize(AppTheme.FONT_CAPTION)
                        .fontColor(row.status === 'success' ? AppTheme.COLOR_TEXT_SECONDARY : AppTheme.COLOR_DANGER)
                    }
                    .width('100%')
                    .padding({ top: 4, bottom: 4 })
                  }, (row: SyncLogRow) => row.id)
                }
              }
            }
            .width('100%')
          }

          // ── 18.2 家庭碳积分（只读） ───────────────────────────────────────
          SectionCard({ title: $r('app.string.sync_family_section') }) {
            Column({ space: AppTheme.CARD_GAP }) {
              if (!this.status.loggedIn) {
                Text($r('app.string.sync_family_need_login'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_TEXT_HINT)
              } else if (this.family.members.length < 2) {
                EmptyView({ icon: '👨‍👩‍👧', text: $r('app.string.sync_family_empty') })
              } else {
                Row() {
                  Column({ space: 2 }) {
                    Text($r('app.string.sync_family_reduction'))
                      .fontSize(AppTheme.FONT_CAPTION)
                      .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                    Text(`${Formatter.reduction(this.family.totalReductionKg)} kg`)
                      .fontSize(AppTheme.FONT_NUMBER_MD)
                      .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                  }
                  .layoutWeight(1)
                  Column({ space: 2 }) {
                    Text($r('app.string.sync_family_points'))
                      .fontSize(AppTheme.FONT_CAPTION)
                      .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                    Text(`${Formatter.points(this.family.totalPoints)}`)
                      .fontSize(AppTheme.FONT_NUMBER_MD)
                      .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                  }
                  .layoutWeight(1)
                }
                .width('100%')
                this.memberRow2()
                ForEach(this.family.members, (m: FamilyMember) => {
                  this.memberRow(m)
                }, (m: FamilyMember) => m.deviceId)
                Text($r('app.string.sync_family_note'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_TEXT_HINT)
              }
            }
            .width('100%')
          }

          // ── 18.3 近场演示 ─────────────────────────────────────────────────
          SectionCard({ title: $r('app.string.sync_near_section') }) {
            Column({ space: AppTheme.CARD_GAP }) {
              if (this.peers.length === 0) {
                EmptyView({ icon: '📱', text: $r('app.string.sync_no_peer') })
              } else {
                ForEach(this.peers, (peer: DevicePeer) => {
                  Row({ space: AppTheme.CARD_GAP }) {
                    Text(peer.online ? '●' : '○')
                      .fontSize(AppTheme.FONT_CAPTION)
                      .fontColor(peer.online ? AppTheme.COLOR_ACCENT : AppTheme.COLOR_TEXT_HINT)
                    Column({ space: 2 }) {
                      Text(peer.deviceName)
                        .fontSize(AppTheme.FONT_BODY)
                        .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                      if (peer.lastSeenAt !== undefined) {
                        Row({ space: 2 }) {
                          Text($r('app.string.sync_last_seen'))
                            .fontSize(AppTheme.FONT_CAPTION)
                            .fontColor(AppTheme.COLOR_TEXT_HINT)
                          Text(Formatter.timeOfDay(peer.lastSeenAt))
                            .fontSize(AppTheme.FONT_CAPTION)
                            .fontColor(AppTheme.COLOR_TEXT_HINT)
                        }
                      } else {
                        Text(peer.networkId)
                          .fontSize(AppTheme.FONT_CAPTION)
                          .fontColor(AppTheme.COLOR_TEXT_HINT)
                      }
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Button($r('app.string.sync_near_action'))
                      .height(AppTheme.BTN_HEIGHT)
                      .fontSize(AppTheme.FONT_CAPTION)
                      .backgroundColor(AppTheme.COLOR_PRIMARY)
                      .fontColor(AppTheme.COLOR_SURFACE)
                      .borderRadius(AppTheme.BTN_RADIUS)
                      .onClick(() => this.doNearField(peer))
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                }, (peer: DevicePeer) => peer.deviceId)
              }
              Button($r('app.string.sync_discover'))
                .width('100%')
                .height(AppTheme.BTN_HEIGHT)
                .backgroundColor(AppTheme.COLOR_DISABLED_BG)
                .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                .borderRadius(AppTheme.BTN_RADIUS)
                .onClick(() => this.doDiscover())
              this.statRow($r('app.string.sync_step_discovering'), '①')
              this.statRow($r('app.string.sync_step_merging'), '②')
              this.statRow($r('app.string.sync_step_writing'), '③')
              Text($r('app.string.sync_near_note'))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_HINT)
              Text($r('app.string.sync_over_cap_note'))
                .fontSize(AppTheme.FONT_CAPTION)
                .fontColor(AppTheme.COLOR_TEXT_HINT)
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
    .bindSheet($$this.showLogin, this.loginSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      backgroundColor: AppTheme.COLOR_SURFACE,
      onDisappear: () => { this.showLogin = false; }
    })
  }

  @Builder
  memberRow2() {
    Row() {
      Text($r('app.string.sync_family_member'))
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_HINT)
        .layoutWeight(2)
      Text($r('app.string.sync_family_reduction'))
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_HINT)
        .layoutWeight(2)
      Text($r('app.string.sync_family_points'))
        .fontSize(AppTheme.FONT_CAPTION)
        .fontColor(AppTheme.COLOR_TEXT_HINT)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ bottom: 4 })
  }

  @Builder
  loginSheet() {
    Column() {
      LoginDialog({
        loggedIn: this.status.loggedIn,
        loginName: this.status.userLabel,
        pending: this.loginPending,
        message: this.loginMessage,
        onLogin: (username: string, password: string) => {
          this.doLogin(username, password);
        },
        onRegister: (username: string, password: string) => {
          this.doRegister(username, password);
        },
        onLogout: () => {
          this.showLogin = false;
          this.doLogout();
        },
        onDeleteAccount: (password: string) => {
          this.doDeleteAccount(password);
        },
        onClose: () => { this.showLogin = false; }
      })
    }
    .padding(AppTheme.PAGE_PADDING)
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
