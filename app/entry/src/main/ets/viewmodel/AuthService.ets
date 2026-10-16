/**
 * AuthService —— 账号（注册 / 登录 / 登出 / 注销）与「首次登录并入本机数据」。
 *
 * 职责：
 *  ① 把账号体系藏在 **`AuthProvider` 抽象**后面（ADR-0001）：`ServerAuthProvider` 走
 *     `/api/v1/auth/*`，`LocalAuthProvider` 是单机占位（不联网），预留给未来的 `huaweiId`；
 *     上层（页面/其它 Service）只拿 `AuthService`，不直接依赖任何具体 provider；
 *  ② token 只由本文件写进 `preferences`（`ConfigKeys.AUTH_TOKEN`）——页面与其它 ViewModel 不得触碰；
 *  ③ **`AccountMigrator`**（ADR-0001 决策 ①）：登录成功后把本机 `local-guest` 的历史数据
 *     全部改挂账号 `userId` 并置 `sync_state = 'pending'`，随后由同步链路全量上传；
 *     登出/注销**不回滚**这一步（本机数据仍属该账号，只是停止同步）；
 *  ④ 登出：只清 token + 回未登录态，**本机业务数据一条不删**；
 *  ⑤ 注销：`DELETE /api/v1/auth/account` 校验密码后云端软删保留 30 天，本机数据一条不删。
 *
 * 校验口径（附录 B §5.2 错误码表）：用户名 4–20 位字母数字下划线；密码 6–32 位。
 */
import { StorePort, RowShape, firstOf, numOf } from './store/StorePort';
import { ClientSchema } from '../data/schema/ClientSchema';
import { AppConfig, ConfigKeys } from './AppConfig';
import { AppState, AuthInfo } from './AppState';
import { HttpPort, HttpResponse, HTTP_TIMEOUT_MS } from './net/HttpPort';
import { JsonObject, asObject, optNum, optStr } from '../util/JsonUtil';
import { AppResult, fail, ok } from '../model/Result';

/** 一次登录/注册成功后的结果。 */
export interface AuthOutcome {
  userId: string;
  username: string;
  token: string;
  /** 并入账号的本机行数（ADR-0001 决策 ①）。 */
  migrated: number;
}

/** 账号能力（provider 抽象）。 */
export interface AuthProvider {
  /** provider 名（`local` / `server` / 预留 `huaweiId`）。 */
  name(): string;
  register(username: string, password: string): Promise<AppResult<AuthOutcome>>;
  login(username: string, password: string): Promise<AppResult<AuthOutcome>>;
  logout(token: string): Promise<AppResult<boolean>>;
  /** 注销（服务端软删保留 30 天），返回 `purgeAfter`。 */
  deleteAccount(password: string, token: string): Promise<AppResult<number>>;
}

/** 服务端实现（`/api/v1/auth/*`，附录 B §5.2）。 */
export class ServerAuthProvider implements AuthProvider {
  private readonly http: HttpPort;

  constructor(http: HttpPort) {
    this.http = http;
  }

  name(): string {
    return 'server';
  }

  async register(username: string, password: string): Promise<AppResult<AuthOutcome>> {
    return this.post('register', username, password);
  }

  async login(username: string, password: string): Promise<AppResult<AuthOutcome>> {
    return this.post('login', username, password);
  }

  async logout(token: string): Promise<AppResult<boolean>> {
    const res: HttpResponse = await this.http.request({
      method: 'POST',
      url: `${this.http.baseUrl()}/api/v1/auth/logout`,
      body: JSON.stringify({ token }),
      timeoutMs: HTTP_TIMEOUT_MS,
    });
    if (res.status === 200) {
      return ok<boolean>(true);
    }
    return fail<boolean>('LOGOUT_FAILED', ServerAuthProvider.messageOf(res));
  }

  async deleteAccount(password: string, token: string): Promise<AppResult<number>> {
    const res: HttpResponse = await this.http.request({
      method: 'DELETE',
      url: `${this.http.baseUrl()}/api/v1/auth/account`,
      body: JSON.stringify({ password, token }),
      timeoutMs: HTTP_TIMEOUT_MS,
    });
    if (res.status !== 200) {
      return fail<number>('DELETE_ACCOUNT_FAILED', ServerAuthProvider.messageOf(res));
    }
    const data: JsonObject = ServerAuthProvider.dataOf(res.body);
    const purgeAfter: number | undefined = optNum(data, 'purgeAfter');
    return ok<number>(purgeAfter === undefined ? 0 : purgeAfter);
  }

  private async post(action: string, username: string, password: string): Promise<AppResult<AuthOutcome>> {
    const res: HttpResponse = await this.http.request({
      method: 'POST',
      url: `${this.http.baseUrl()}/api/v1/auth/${action}`,
      body: JSON.stringify({ username, password }),
      timeoutMs: HTTP_TIMEOUT_MS,
    });
    if (res.status !== 200 && res.status !== 201) {
      return fail<AuthOutcome>('AUTH_FAILED', ServerAuthProvider.messageOf(res));
    }
    const data: JsonObject = ServerAuthProvider.dataOf(res.body);
    const userId: string | undefined = optStr(data, 'userId');
    const name: string | undefined = optStr(data, 'username');
    const token: string | undefined = optStr(data, 'userToken');
    if (userId === undefined || token === undefined) {
      return fail<AuthOutcome>('AUTH_BAD_RESPONSE', '服务端返回不完整');
    }
    return ok<AuthOutcome>({ userId, username: name === undefined ? username : name, token, migrated: 0 });
  }

  private static dataOf(body: string): JsonObject {
    try {
      const root: JsonObject = asObject(JSON.parse(body), 'auth');
      const data: Object | undefined = root['data'];
      return data === undefined ? root : asObject(data, 'auth.data');
    } catch (e) {
      return {};
    }
  }

  private static messageOf(res: HttpResponse): string {
    try {
      const root: JsonObject = asObject(JSON.parse(res.body), 'auth');
      const message: string | undefined = optStr(root, 'message');
      const code: string | undefined = optStr(root, 'code');
      if (message !== undefined) {
        return message;
      }
      if (code !== undefined) {
        return code;
      }
    } catch (e) {
      // 落到下面的通用文案
    }
    if (res.error !== undefined && res.error.length > 0) {
      return res.error;
    }
    return `HTTP ${res.status}`;
  }
}

/**
 * 单机占位 provider：**不联网**，只用于「未登录也能开发调试」的场景，
 * 不产生任何 token（返回失败），从根上保证不会有人误以为它等价于真账号。
 */
export class LocalAuthProvider implements AuthProvider {
  name(): string {
    return 'local';
  }

  register(username: string, password: string): Promise<AppResult<AuthOutcome>> {
    return Promise.resolve(fail<AuthOutcome>('LOCAL_ONLY', '未配置服务端地址，当前是纯单机模式'));
  }

  login(username: string, password: string): Promise<AppResult<AuthOutcome>> {
    return Promise.resolve(fail<AuthOutcome>('LOCAL_ONLY', '未配置服务端地址，当前是纯单机模式'));
  }

  logout(token: string): Promise<AppResult<boolean>> {
    return Promise.resolve(ok<boolean>(true));
  }

  deleteAccount(password: string, token: string): Promise<AppResult<number>> {
    return Promise.resolve(fail<number>('LOCAL_ONLY', '未登录，无法注销账号'));
  }
}

/** 「首次登录并入本机数据」（ADR-0001 决策 ①）。 */
export class AccountMigrator {
  /**
   * 把 `fromUserId` 的行全部改挂 `toUserId` 并置 `sync_state = 'pending'`。
   * @returns 迁移的行数（9 张参与同步的表之和）
   */
  static async migrate(store: StorePort, fromUserId: string, toUserId: string): Promise<number> {
    if (fromUserId === toUserId) {
      return 0;
    }
    let moved: number = 0;
    let i: number = 0;
    while (i < ClientSchema.SYNCED_TABLES.length) {
      const table: string = ClientSchema.SYNCED_TABLES[i];
      const before: RowShape[] = await store.query(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`, [fromUserId]);
      const row: RowShape | undefined = firstOf(before);
      if (row !== undefined) {
        moved = moved + numOf(row, 'n');
      }
      await store.exec(`UPDATE ${table} SET user_id = ?, sync_state = 'pending' WHERE user_id = ?`, [toUserId, fromUserId]);
      i = i + 1;
    }
    return moved;
  }
}

export class AuthService {
  private readonly store: StorePort;
  private readonly state: AppState;
  private readonly cfg: AppConfig;
  private readonly provider: AuthProvider;

  constructor(store: StorePort, state: AppState, cfg: AppConfig, provider: AuthProvider) {
    this.store = store;
    this.state = state;
    this.cfg = cfg;
    this.provider = provider;
  }

  /** 当前 provider 名（设置页可展示，便于排查）。 */
  providerName(): string {
    return this.provider.name();
  }

  /** 登录（成功后并入本机数据）。 */
  async login(username: string, password: string, now: number): Promise<AppResult<AuthOutcome>> {
    const bad: string = AuthService.validate(username, password);
    if (bad.length > 0) {
      return fail<AuthOutcome>('INPUT_INVALID', bad);
    }
    const res: AppResult<AuthOutcome> = await this.provider.login(username, password);
    if (!res.ok || res.data === undefined) {
      return res;
    }
    return this.finishAuth(res.data, now);
  }

  /** 注册（成功后同样并入本机数据，与登录一致）。 */
  async register(username: string, password: string, now: number): Promise<AppResult<AuthOutcome>> {
    const bad: string = AuthService.validate(username, password);
    if (bad.length > 0) {
      return fail<AuthOutcome>('INPUT_INVALID', bad);
    }
    const res: AppResult<AuthOutcome> = await this.provider.register(username, password);
    if (!res.ok || res.data === undefined) {
      return res;
    }
    return this.finishAuth(res.data, now);
  }

  /** 登出：只清 token，本机数据一条不删。 */
  async logout(now: number): Promise<void> {
    const token: string = await this.token();
    if (token.length > 0) {
      await this.provider.logout(token);
    }
    await this.cfg.remove(ConfigKeys.AUTH_TOKEN);
    await this.cfg.remove(ConfigKeys.AUTH_USER_ID);
    await this.state.setAuth({ accountUserId: '', loginName: '', loggedIn: false }, now);
  }

  /** 注销账号（云端软删保留 30 天；本机数据一条不删）。 */
  async deleteAccount(password: string): Promise<AppResult<number>> {
    const token: string = await this.token();
    if (token.length === 0) {
      return fail<number>('NOT_LOGGED_IN', '当前未登录');
    }
    const res: AppResult<number> = await this.provider.deleteAccount(password, token);
    if (res.ok) {
      await this.cfg.remove(ConfigKeys.AUTH_TOKEN);
      await this.cfg.remove(ConfigKeys.AUTH_USER_ID);
      await this.state.setAuth({ accountUserId: '', loginName: '', loggedIn: false }, Date.now());
    }
    return res;
  }

  /** 已登录账号（`app_config` 里的持久化视图）。 */
  async account(): Promise<AuthInfo> {
    const user: string = await AuthService.text(this.cfg, ConfigKeys.AUTH_USER);
    const id: string = await AuthService.text(this.cfg, ConfigKeys.AUTH_USER_ID);
    return { accountUserId: id, loginName: user, loggedIn: user.length > 0 && id.length > 0 };
  }

  /** token（**只有本类读它**；页面与其它 ViewModel 不得调用）。 */
  private async token(): Promise<string> {
    return AuthService.text(this.cfg, ConfigKeys.AUTH_TOKEN);
  }

  private static async text(cfg: AppConfig, key: string): Promise<string> {
    const v: string | undefined = await cfg.get(key);
    return v === undefined ? '' : v;
  }

  /** 落 token + 迁移本机数据 + 切登录态。 */
  private async finishAuth(outcome: AuthOutcome, now: number): Promise<AppResult<AuthOutcome>> {
    const migrated: number = await AccountMigrator.migrate(this.store, this.state.userId(), outcome.userId);
    await this.cfg.set(ConfigKeys.AUTH_TOKEN, outcome.token);
    await this.cfg.set(ConfigKeys.AUTH_USER, outcome.username);
    await this.cfg.set(ConfigKeys.AUTH_USER_ID, outcome.userId);
    await this.state.setAuth({ accountUserId: outcome.userId, loginName: outcome.username, loggedIn: true }, now);
    return ok<AuthOutcome>({ userId: outcome.userId, username: outcome.username, token: outcome.token, migrated });
  }

  /** 用户名/密码本地预校验（与附录 B §5.2 错误码口径一致）。 */
  static validate(username: string, password: string): string {
    if (username.length < 4 || username.length > 20) {
      return '用户名需 4–20 位';
    }
    let i: number = 0;
    while (i < username.length) {
      const c: string = username.charAt(i);
      const isDigit: boolean = c >= '0' && c <= '9';
      const isUpper: boolean = c >= 'A' && c <= 'Z';
      const isLower: boolean = c >= 'a' && c <= 'z';
      if (!isDigit && !isUpper && !isLower && c !== '_') {
        return '用户名只能用字母、数字、下划线';
      }
      i = i + 1;
    }
    if (password.length < 6 || password.length > 32) {
      return '密码需 6–32 位';
    }
    return '';
  }

  /** 账号用户名是否已被占用（本机无法判断，交服务端；此处保留扩展点）。 */
  static takenCode(): string {
    return 'USERNAME_TAKEN';
  }

  /** 便于页面展示的账号 id 前缀（服务端形如 `u-...`）。 */
  static isAccountId(value: string): boolean {
    return value.startsWith('u-');
  }
}
