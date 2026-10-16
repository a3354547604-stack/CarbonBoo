/**
 * LoginDialog —— 登录 / 注册半模态（附录 C §23.3，ADR-0001）。
 *
 * 边界：对话框只收集输入、把结果交给页面；**token 只经 AuthService→AuthProvider 落 preferences**，
 * 这里不碰 token，也不自己做任何网络调用。不接验证码、不做华为账号。
 * 已登录态展示「已登录：xxx」+ 退出登录 + 注销账号（二次确认 + 输入密码）。
 */
import { AppTheme } from '../util/AppTheme';

@Component
export struct LoginDialog {
  @Prop loggedIn: boolean = false;
  @Prop loginName: string = '';
  @Prop pending: boolean = false;
  @Prop message: string = '';
  @State tab: string = 'login';
  @State username: string = '';
  @State password: string = '';
  @State password2: string = '';
  @State deletePassword: string = '';
  @State showDelete: boolean = false;
  onLogin: (username: string, password: string) => void = () => {};
  onRegister: (username: string, password: string) => void = () => {};
  onLogout: () => void = () => {};
  onDeleteAccount: (password: string) => void = () => {};
  onClose: () => void = () => {};

  private usernameValid(): boolean {
    const u: string = this.username.trim();
    if (u.length < 4 || u.length > 20) {
      return false;
    }
    for (let i = 0; i < u.length; i++) {
      const c: string = u.charAt(i);
      const ok: boolean = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c === '_';
      if (!ok) {
        return false;
      }
    }
    return true;
  }

  private passwordValid(): boolean {
    return this.password.length >= 6 && this.password.length <= 32;
  }

  private canSubmit(): boolean {
    if (this.pending) {
      return false;
    }
    if (!this.usernameValid() || !this.passwordValid()) {
      return false;
    }
    if (this.tab === 'register' && this.password !== this.password2) {
      return false;
    }
    return true;
  }

  @Builder
  tabButton(key: string, label: ResourceStr) {
    Text(label)
      .fontSize(AppTheme.FONT_BODY)
      .fontColor(this.tab === key ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_SECONDARY)
      .layoutWeight(1)
      .height(AppTheme.BTN_HEIGHT)
      .textAlign(TextAlign.Center)
      .border({ width: { bottom: this.tab === key ? 2 : 0 }, color: AppTheme.COLOR_PRIMARY })
      .onClick(() => {
        this.tab = key;
      })
  }

  build() {
    Column({ space: AppTheme.CARD_GAP }) {
      Row() {
        Text($r('app.string.auth_login'))
          .fontSize(AppTheme.FONT_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .layoutWeight(1)
        Text($r('app.string.common_close'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .onClick(() => this.onClose())
      }
      .width('100%')

      if (this.loggedIn) {
        Text(`已登录：${this.loginName}`)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .width('100%')
        Text($r('app.string.auth_logout_hint'))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
          .width('100%')
        Text($r('app.string.auth_logout'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_SURFACE)
          .width('100%')
          .height(AppTheme.BTN_HEIGHT)
          .textAlign(TextAlign.Center)
          .backgroundColor(AppTheme.COLOR_PRIMARY)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => this.onLogout())
        Text($r('app.string.auth_delete_account'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_DANGER)
          .width('100%')
          .height(AppTheme.BTN_HEIGHT)
          .textAlign(TextAlign.Center)
          .backgroundColor(AppTheme.COLOR_DISABLED_BG)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => {
            this.showDelete = !this.showDelete;
          })
        if (this.showDelete) {
          Text($r('app.string.auth_delete_confirm'))
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_DANGER)
            .width('100%')
          TextInput({ placeholder: $r('app.string.auth_password'), text: this.deletePassword })
            .type(InputType.Password)
            .height(AppTheme.BTN_HEIGHT)
            .width('100%')
            .onChange((v: string) => {
              this.deletePassword = v;
            })
          Text($r('app.string.auth_delete_submit'))
            .fontSize(AppTheme.FONT_BODY)
            .fontColor(AppTheme.COLOR_SURFACE)
            .width('100%')
            .height(AppTheme.BTN_HEIGHT)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.deletePassword.length > 0 ? AppTheme.COLOR_DANGER : AppTheme.COLOR_TEXT_HINT)
            .borderRadius(AppTheme.BTN_RADIUS)
            .onClick(() => {
              if (this.deletePassword.length > 0) {
                this.onDeleteAccount(this.deletePassword);
              }
            })
        }
      } else {
        Row() {
          this.tabButton('login', $r('app.string.auth_login'))
          this.tabButton('register', $r('app.string.auth_register'))
        }
        .width('100%')

        TextInput({ placeholder: $r('app.string.auth_username_rule'), text: this.username })
          .height(AppTheme.BTN_HEIGHT)
          .width('100%')
          .onChange((v: string) => {
            this.username = v;
          })
        TextInput({ placeholder: $r('app.string.auth_password_rule'), text: this.password })
          .type(InputType.Password)
          .height(AppTheme.BTN_HEIGHT)
          .width('100%')
          .onChange((v: string) => {
            this.password = v;
          })
        if (this.tab === 'register') {
          TextInput({ placeholder: $r('app.string.auth_password2'), text: this.password2 })
            .type(InputType.Password)
            .height(AppTheme.BTN_HEIGHT)
            .width('100%')
            .onChange((v: string) => {
              this.password2 = v;
            })
        }
        if (this.message.length > 0) {
          Text(this.message).fontSize(AppTheme.FONT_CAPTION).fontColor(AppTheme.COLOR_DANGER).width('100%')
        }
        Text(this.tab === 'register' ? $r('app.string.auth_register') : $r('app.string.auth_login'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_SURFACE)
          .width('100%')
          .height(AppTheme.BTN_HEIGHT)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.canSubmit() ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_HINT)
          .borderRadius(AppTheme.BTN_RADIUS)
          .onClick(() => {
            if (!this.canSubmit()) {
              return;
            }
            if (this.tab === 'register') {
              this.onRegister(this.username.trim(), this.password);
            } else {
              this.onLogin(this.username.trim(), this.password);
            }
          })
      }
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
    .alignItems(HorizontalAlign.Start)
  }
}
