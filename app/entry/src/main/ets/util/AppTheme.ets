/**
 * AppTheme —— 设计令牌的**唯一字面量来源**（`docs/APPENDIX-C-ui-screens.md` §3）。
 *
 * 职责：
 *  ① 颜色（§3.1）、尺寸（§3.2）、字体（§3.3）三类令牌的 ArkTS 常量；
 *  ② `LiteralConstants`：**其它**允许存在的字面量（Canvas 几何、隐私黑名单词、
 *     演示数据条数等）集中在此，页面/组件里不得再出现任何一个裸字面量
 *     （附录 C §25 自检第 2 条：「所有色值、尺寸取自 AppTheme，页面内无字面量」）。
 *
 * 为什么颜色是字符串而不是 `$r('app.color.*')`：
 *  Canvas 自绘（折线/柱/饼/分享卡片）的 `fillStyle` 只吃字符串；为了让
 *  「声明式 UI」与「Canvas」用**同一份**色值，这里给出的十六进制字符串与
 *  `resources/base/element/color.json` 逐条同值（改动必须两处同改，见文件尾注释）。
 *
 * 路径说明：附录 C §3 写的是 `common/AppTheme.ets`，本实现落在 `util/AppTheme.ets`，
 * 以任务契约（inScope）为准；两者差异已在交付报告中登记。
 */
import { CategoryKey } from '../model/CarbonTypes';

export class AppTheme {
  // ---------------------------------------------------------------- §3.1 颜色
  static readonly COLOR_PRIMARY: string = '#2E7D5B';
  static readonly COLOR_PRIMARY_PRESS: string = '#256449';
  static readonly COLOR_ACCENT: string = '#8BC34A';
  static readonly COLOR_BG: string = '#F5F7F6';
  static readonly COLOR_SURFACE: string = '#FFFFFF';
  static readonly COLOR_TEXT_PRIMARY: string = '#1F2A24';
  static readonly COLOR_TEXT_SECONDARY: string = '#6B7A72';
  static readonly COLOR_TEXT_HINT: string = '#9AA8A1';
  static readonly COLOR_DIVIDER: string = '#E4E9E6';
  static readonly COLOR_DANGER: string = '#D9534F';
  static readonly COLOR_WARNING: string = '#E6A23C';
  static readonly CAT_TRAVEL: string = '#4A90D9';
  static readonly CAT_UTILITY: string = '#E6A23C';
  static readonly CAT_RECYCLE: string = '#7FB069';
  static readonly CAT_PLATE: string = '#D98C6A';
  /** 演示模式/模拟提示条的底色（黄色系，与 `color_warning` 同族但更浅）。 */
  static readonly COLOR_WARNING_BG: string = '#FDF6EC';
  /** 未解锁徽章与置灰按钮的底色。 */
  static readonly COLOR_DISABLED_BG: string = '#EDF1EF';

  // ---------------------------------------------------------------- §3.2 尺寸
  static readonly PAGE_PADDING: number = 16;
  /** 平板断点（§3.3 适配：平板 page_padding 提到 24vp）。 */
  static readonly PAGE_PADDING_TABLET: number = 24;
  static readonly CARD_RADIUS: number = 12;
  static readonly CARD_PADDING: number = 16;
  static readonly CARD_GAP: number = 12;
  static readonly BTN_HEIGHT: number = 44;
  static readonly BTN_RADIUS: number = 8;
  static readonly ICON_SM: number = 20;
  static readonly ICON_MD: number = 28;
  static readonly ICON_LG: number = 44;
  static readonly AVATAR_SIZE: number = 64;
  static readonly TAB_HEIGHT: number = 56;
  static readonly FAB_SIZE: number = 52;
  static readonly HEADER_HEIGHT: number = 48;

  // ---------------------------------------------------------------- §3.3 字体
  static readonly FONT_TITLE: number = 20;
  static readonly FONT_SECTION: number = 17;
  static readonly FONT_BODY: number = 15;
  static readonly FONT_CAPTION: number = 13;
  static readonly FONT_NUMBER_LG: number = 28;
  static readonly FONT_NUMBER_MD: number = 20;

  /**
   * 分类色（§3.1 的 `cat_*`）。
   * @param category 行为大类
   */
  static categoryColor(category: CategoryKey): string {
    if (category === 'travel') {
      return AppTheme.CAT_TRAVEL;
    }
    if (category === 'utility') {
      return AppTheme.CAT_UTILITY;
    }
    if (category === 'recycle') {
      return AppTheme.CAT_RECYCLE;
    }
    return AppTheme.CAT_PLATE;
  }

  /** 分类中文名（唯一口径，页面禁止自造）。 */
  static categoryName(category: CategoryKey): string {
    if (category === 'travel') {
      return '出行';
    }
    if (category === 'utility') {
      return '水电';
    }
    if (category === 'recycle') {
      return '回收';
    }
    return '光盘';
  }
}

/**
 * LiteralConstants —— 允许存在的其它字面量（集中一处，附理由）。
 *
 * 收录门槛：不是颜色/尺寸/字号，但确实需要写死的量；每条都必须注明理由。
 */
export class LiteralConstants {
  /** 分享卡片两种尺寸（附录 C §23.2）。 */
  static readonly CARD_VERTICAL: string = '1080x1440';
  static readonly CARD_SQUARE: string = '1080x1080';
  static readonly CARD_W: number = 1080;
  static readonly CARD_H_VERTICAL: number = 1440;
  static readonly CARD_H_SQUARE: number = 1080;

  /** 隐私黑名单（附录 C §23.2 规则 2：默认不含姓名/学校/队名/指导教师）。 */
  static readonly PRIVACY_FORBIDDEN: string[] = ['姓名', '学校', '队名', '指导教师', '战队', '选手'];

  /** 折线图最多 31 个点（附录 C §6 规则 1）。 */
  static readonly CHART_MAX_POINTS: number = 31;
  /** 饼图分类固定 4 类。 */
  static readonly PIE_CATEGORIES: number = 4;
  /** Canvas 自绘的分辨率倍数（vp → 绘制坐标的最小刻度）。 */
  static readonly CHART_TICK: number = 4;

  /** 列表一页 20 条（附录 C §7 / §16）。 */
  static readonly PAGE_SIZE: number = 20;
  /** 协同页冲突记录展示最近 20 条（附录 C §18 规则）。 */
  static readonly SYNC_LOG_LIMIT: number = 20;
  /** 备份保留最近 3 份（附录 C §21）。 */
  static readonly BACKUP_KEEP: number = 3;
  /** 已读判定：滚动 ≥80% 且停留 ≥3 秒（B18）。 */
  static readonly READ_THRESHOLD: number = 0.8;
  static readonly READ_DWELL_MS: number = 3000;
  /** 识图半模态超时 3 秒（附录 C §23.1 规则 2）。 */
  static readonly AI_TIMEOUT_MS: number = 3000;
  /** 识图候选最多 3 个（列位置有限，超出的丢弃）。 */
  static readonly AI_MAX_CANDIDATES: number = 3;
  /** 解锁庆祝弹窗最多连续 3 个（附录 C §23.5）。 */
  static readonly CELEBRATION_MAX: number = 3;
  /** 补记窗口 30 天（附录 C §10 规则 8）。 */
  static readonly BACKDATE_DAYS: number = 30;
  /** 昵称最长 12 字（附录 C §20）。 */
  static readonly NICKNAME_MAX: number = 12;
  /** 输入节流 200ms（附录 C §10 规则 1）。 */
  static readonly PREVIEW_THROTTLE_MS: number = 200;
  /** 开发者选项触发：连点版本号 7 次（附录 C §23.6）。 */
  static readonly DEV_TAP_COUNT: number = 7;
  /** 每周首日（自然周，周一 00:00 起）。 */
  static readonly WEEK_START_LABEL: string = '周一 00:00 起算';
  /** 演示数据默认解锁徽章 6 枚（附录 C §14 + 附录 D §9 同源）。 */
  /** 「清空所有数据」的确认词（附录 C §21 / §24）。 */
  static readonly CLEAR_CONFIRM_WORD: string = '删除';
  static readonly DEMO_BADGES: number = 6;
  /** 徽章总数 8 枚。 */
  static readonly BADGE_TOTAL: number = 8;
  /** 头像框总数 8 个（集齐解锁「种树人」）。 */
  static readonly FRAME_TOTAL: number = 8;
  /** 等效换算兜底（因子库未加载时用；正常一律读 `FactorRepository`）。 */
  static readonly TREE_ABSORB_KG_PER_YEAR: number = 18.3;
  static readonly CAR_KM_PER_KG: number = 5.21;
  /** 演示数据：记录条数（附录 D §9「260 条」的简化实现口径）。 */
  static readonly DEMO_RECORD_COUNT: number = 24;
  /** 演示数据：累计分与余额展示值（与 §9 展示数字同源）。 */
  static readonly DEMO_POINT_BALANCE: number = 4820;
}

/**
 * ⚠️ 数值同步约束：`resources/base/element/color.json` 是本表的镜像，
 * 改动任一色值必须两处同改（Canvas 用本表字符串，声明式 UI 用资源）；
 * `python3 tests/tools/check_l0.py --strict` 不检查这层对应关系。
 */
export const THEME_COLOR_MIRROR_NOTE: string = 'color.json 与 AppTheme 色值同值';
