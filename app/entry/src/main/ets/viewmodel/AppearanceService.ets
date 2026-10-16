/**
 * AppearanceService —— 外观（S4）：头像、头像框、主题、昵称。
 *
 * 职责：
 *  ① 头像清单来自 `app_config['avatars']`（8 个，全部免费，app-core 从 rawfile 播种）；
 *  ② 头像框可用性 = 已购买（`user_purchase`）+ 默认免费项，判定复用 `ShopRules.ownedIds`；
 *  ③ 保存 → UPSERT `user_appearance`（唯一约束 `uq_ua(user_id)`），昵称 ≤12 字，
 *     留空回落 `AppConstants.DEFAULT_DISPLAY_NAME`（「碳小布用户」）；
 *  ④ 主题：本期只有一套免费默认主题（`theme_default`），其余主题位预留（附录 C §20）。
 *
 * 为什么头像字典放 `app_config` 而不是新建表：它是**静态字典**（随版本变化、不随用户变化），
 * 进 `user_appearance` 只会重复 8 行常量；备份也因此更小。
 */
import { Appearance } from '../model/ShopTypes';
import { StorePort, firstOf, textOf } from './store/StorePort';
import { RowMapper } from './store/RowMapper';
import { ShopRules } from './domain/ShopRules';
import { AppState } from './AppState';
import { IdUtil } from './domain/IdUtil';
import { AppConstants } from '../util/AppConstants';
import { JsonArray, asArray, asObject, optBool, optStr } from '../util/JsonUtil';
import { AppResult, fail, ok } from '../model/Result';

/** 一个可选头像。 */
export interface AvatarOption {
  id: string;
  name: string;
  icon: string;
  /** 是否默认选中（新人首次进入）。 */
  isDefault: boolean;
}

/** 一次保存的结果（页面据此刷新首页/我的页头像）。 */
export interface AppearanceOutcome {
  appearance: Appearance;
  nickname: string;
}

export class AppearanceService {
  private readonly store: StorePort;
  private readonly state: AppState;

  constructor(store: StorePort, state: AppState) {
    this.store = store;
    this.state = state;
  }

  /** 8 个头像（全部免费）。 */
  async avatars(): Promise<AvatarOption[]> {
    const rows = await this.store.query("SELECT value FROM app_config WHERE id = 'avatars'", []);
    const row = firstOf(rows);
    if (row === undefined) {
      return [];
    }
    const text: string = textOf(row, 'value');
    if (text.length === 0) {
      return [];
    }
    try {
      const arr: JsonArray = asArray(JSON.parse(text), 'avatars');
      const out: AvatarOption[] = [];
      let i: number = 0;
      while (i < arr.length) {
        const o = asObject(arr[i], `avatars[${i}]`);
        const id: string | undefined = optStr(o, 'id');
        const name: string | undefined = optStr(o, 'name');
        const icon: string | undefined = optStr(o, 'icon');
        const isDefault: boolean | undefined = optBool(o, 'default');
        if (id !== undefined && name !== undefined) {
          out.push({
            id,
            name,
            icon: icon === undefined ? '' : icon,
            isDefault: isDefault === undefined ? false : isDefault,
          });
        }
        i = i + 1;
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 当前外观（未保存过时返回默认值，不写库）。 */
  async current(userId: string): Promise<Appearance> {
    const rows = await this.store.query('SELECT * FROM user_appearance WHERE user_id = ? AND is_deleted = 0', [userId]);
    const row = firstOf(rows);
    if (row === undefined) {
      return { avatarId: this.defaultAvatarId(), themeId: AppearanceService.DEFAULT_THEME };
    }
    return RowMapper.appearance(row);
  }

  /** 昵称（未设置时回落默认名）。 */
  nicknameOf(appearance: Appearance): string {
    const nick: string | undefined = appearance.nickname;
    if (nick === undefined || nick.trim().length === 0) {
      return AppConstants.DEFAULT_DISPLAY_NAME;
    }
    return nick.trim();
  }

  /** 免费头像的默认 id（`default:true`，缺省取第一个）。 */
  private defaultAvatarId(): string {
    return AppearanceService.FALLBACK_AVATAR;
  }

  /** 保存外观。 */
  async save(userId: string, avatarId: string, frameId: string, themeId: string, nickname: string): Promise<AppResult<AppearanceOutcome>> {
    if (avatarId.length === 0) {
      return fail<AppearanceOutcome>('AVATAR_REQUIRED', '请选择一个头像');
    }
    const trimmed: string = nickname.trim();
    if (trimmed.length > AppearanceService.NICKNAME_MAX) {
      return fail<AppearanceOutcome>('NICKNAME_TOO_LONG', `昵称最多 ${AppearanceService.NICKNAME_MAX} 个字`);
    }
    const now: number = Date.now();
    const finalNick: string = trimmed.length === 0 ? AppConstants.DEFAULT_DISPLAY_NAME : trimmed;
    try {
      await this.store.exec(
        'INSERT INTO user_appearance (id, user_id, avatar_id, frame_id, theme_id, nickname, created_at, updated_at, is_deleted, device_id, sync_state) ' +
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?) ' +
        'ON CONFLICT(user_id) DO UPDATE SET avatar_id = excluded.avatar_id, frame_id = excluded.frame_id, ' +
        'theme_id = excluded.theme_id, nickname = excluded.nickname, updated_at = excluded.updated_at, is_deleted = 0',
        [
          IdUtil.uuid(), userId, avatarId,
          frameId.length === 0 ? null : frameId,
          themeId.length === 0 ? AppearanceService.DEFAULT_THEME : themeId,
          finalNick, now, now, this.state.deviceId(), this.state.syncState(),
        ]
      );
      return ok<AppearanceOutcome>({ appearance: { avatarId, frameId, themeId, nickname: finalNick }, nickname: finalNick });
    } catch (e) {
      return fail<AppearanceOutcome>('APPEARANCE_SAVE_FAILED', `保存失败：${AppearanceService.messageOf(e)}`);
    }
  }

  /** 界面可用的头像框（`[无]` + 已购买；未购买的置灰带 🔒，由页面渲染）。 */
  async availableFrames(purchasedIds: string[]): Promise<string[]> {
    return ShopRules.ownedIds(purchasedIds);
  }

  private static messageOf(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return `${e}`;
  }

  /** 默认主题 id（附录 C §20：本期只投放一套免费默认主题）。 */
  static readonly DEFAULT_THEME: string = 'theme_default';
  /** 昵称长度上限（附录 C §20 规则 3）。 */
  static readonly NICKNAME_MAX: number = 12;
  /** 头像缺失时的回落 id（`rawfile/appearance/avatars.json` 里的默认项）。 */
  static readonly FALLBACK_AVATAR: string = 'avatar_leaf';
}
