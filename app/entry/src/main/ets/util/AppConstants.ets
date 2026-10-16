/**
 * AppConstants —— 全应用**唯一**的字面量集中地（AGENTS.md §7.1 例外条款）。
 *
 * 职责：
 *  ① 落库口径常量：库名、库版本、schema 版本键、游客与演示用户 id；
 *  ② 业务口径常量：积分换算率、每日封顶、最小可积分减排量、碳币汇率（与
 *     `tests/cases/carbon-calc.json → meta` / 附录 A §7 `points` 同源）;
 *  ③ 输入合理范围上限（附录 A §7 `limits`，超限**提示但不阻断**）。
 *
 * 依据：`tests/cases/carbon-calc.json`（唯一真相源）+ AGENTS.md §3。
 * 约定：本文件只放**数字与短标识**；颜色、文案走 `resources/` 与 `AppTheme`。
 */
export class AppConstants {
  // ---------- 落库口径 ----------
  /** 本机数据库文件名（`relationalStore` 的 name）。 */
  static readonly DB_NAME: string = 'carbonboo.db';
  /** 库版本号；升版只允许加表/加列（附录 B §9）。 */
  static readonly DB_VERSION: number = 1;
  /** schema 版本存 `app_config['schema_version']`。 */
  static readonly CONFIG_KEY_SCHEMA_VERSION: string = 'schema_version';

  // ---------- 用户身份口径（附录 B §1.3） ----------
  /** 未登录 = 纯单机；本机档案的 user_id。 */
  static readonly GUEST_USER_ID: string = 'local-guest';
  /** 演示模式的 user_id；关闭演示模式时按该 id 级联清理 19 张表。 */
  static readonly DEMO_USER_ID: string = 'demo-user';
  /** 档案默认展示名。 */
  static readonly DEFAULT_DISPLAY_NAME: string = '碳小布用户';

  // ---------- 积分与封顶（PLAN §9.2） ----------
  /** 1 kgCO₂e 折 100 积分。 */
  static readonly POINTS_PER_KG: number = 100;
  /** 每日**记录分**上限 200；目标分不封顶、不计入 D。 */
  static readonly DAILY_RECORD_CAP: number = 200;
  /** 减排量小于该值不产生积分流水（0.005 kg）。 */
  static readonly MIN_REDUCTION_FOR_POINT: number = 0.005;
  /** 100 积分 = 1 碳币。 */
  static readonly CARBON_COIN_RATE: number = 100;

  // ---------- 数值精度（附录 A §3.4） ----------
  /** 减排量小数位：4 位。 */
  static readonly REDUCTION_DECIMALS: number = 4;
  /** 因子值小数位：6 位。 */
  static readonly FACTOR_DECIMALS: number = 6;

  // ---------- 输入合理范围（超限提示但不阻断） ----------
  static readonly LIMIT_TRAVEL_KM: number = 200;
  static readonly LIMIT_ELEC_KWH: number = 200;
  static readonly LIMIT_WATER_L: number = 2000;
  static readonly LIMIT_GAS_M3: number = 100;
  static readonly LIMIT_RECYCLE_KG: number = 500;
  static readonly LIMIT_PLATE_TIMES: number = 20;
}
