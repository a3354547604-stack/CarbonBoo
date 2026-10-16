/**
 * ClientSchema —— 客户端 19 张表的建表 DDL（**唯一来源**）。
 *
 * 职责：把 `docs/APPENDIX-B-data-and-api.md` §2「建表 SQL（客户端 19 张）」照抄为
 * SQL 字符串常量数组，供 `RdbHelper` 在首次打开数据库时逐条执行。
 *
 * 依据与对齐方式：
 *  - 表清单与"是否参与同步"以附录 B §1.1 为准（19 张；参与同步 9 张：1/3/6/8/10/11/13/14/17）；
 *  - 列名、类型、约束、默认值、索引**逐列照抄**附录 B §2；刻意保留原文的注释与
 *    `"order"` 这种需要加引号的保留字写法，方便与文档做逐行 diff；
 *  - 通用列（`id` / `user_id` / `created_at` / `updated_at` / `is_deleted` /
 *    `device_id` / `sync_state`）的口径见附录 B §1.3。
 *
 * 约束（附录 B §1.3 四条铁约定）：
 *  1. 所有时间戳一律毫秒整数，禁止字符串日期入库；
 *  2. 日期维度另存字符串（`day_key` / `period_key`），便于按日聚合与做幂等键；
 *  3. 任何 UPDATE 必须同时改 `updated_at`；
 *  4. 软删除 = `is_deleted = 1` + 更新 `updated_at`，不物理删除。
 *
 * 迁移（附录 B §9）：升版只允许「加表 / 加列」，加列必须带默认值；禁止删列与改名。
 */
export class ClientSchema {
  /** 表清单（附录 B §1.1 顺序；`RdbHelper` 用它对账"是否 19 张都建了"）。 */
  static readonly TABLES: string[] = [
    'carbon_record',
    'carbon_factor_meta',
    'point_record',
    'point_daily_stat',
    'goal_def',
    'user_goal',
    'badge_def',
    'user_badge',
    'shop_item',
    'user_purchase',
    'user_appearance',
    'science_article',
    'science_progress',
    'carbon_include',
    'share_record',
    'sync_log',
    'user_profile',
    'device_info',
    'app_config',
  ];

  /** 参与云端 + 近场同步的 9 张表（附录 B §1.1）。 */
  static readonly SYNCED_TABLES: string[] = [
    'carbon_record',
    'point_record',
    'user_goal',
    'user_badge',
    'user_purchase',
    'user_appearance',
    'science_progress',
    'carbon_include',
    'user_profile',
  ];

  /**
   * 建表与建索引语句，**按执行顺序**排列。
   * 顺序敏感点：`point_record` 的唯一索引依赖同表列，必须紧跟其建表语句。
   */
  /**
   * 建表与建索引语句（**43 条** = 19 CREATE TABLE + 24 CREATE INDEX），按执行顺序排列。
   *
   * ⚠️ 这些字符串与 `docs/APPENDIX-B-data-and-api.md` §2 的语句体**逐字等值**
   *（只去掉文档里的行尾分号），改动任意一个字符都会破坏该等值关系；
   * 可执行性核对脚本会逐条比对原文。
   *
   * 顺序敏感点：`point_record` 的唯一索引依赖同表列，必须紧跟其建表语句。
   * 文档中夹在语句之间的说明性注释（「取值口径」等）不在本数组里——
   * 它们不是可执行 SQL，见下方 `SOURCE_NOTES`。
   */
  static readonly DDL: string[] = [
    // ========== 1. 碳记录 ==========
    `CREATE TABLE IF NOT EXISTS carbon_record (
  id              TEXT PRIMARY KEY,
  user_id         TEXT    NOT NULL,
  category        TEXT    NOT NULL,          -- travel | utility | recycle | plate
  sub_type        TEXT    NOT NULL,          -- 因子 subType
  amount          REAL    NOT NULL,          -- 活动量
  unit            TEXT    NOT NULL,          -- km | kWh | L | m³ | kg | 次
  occurred_at     INTEGER NOT NULL,          -- 行为发生时间（可补记往日）
  reduction_kg    REAL    NOT NULL,          -- 减排量，4 位小数
  factor_value    REAL    NOT NULL,          -- 因子快照（铁律 3）
  factor_version  TEXT    NOT NULL,
  factor_source   TEXT    NOT NULL,
  confidence      TEXT    NOT NULL,          -- verified | provisional
  point_awarded   INTEGER NOT NULL DEFAULT 0,-- 实入积分
  point_capped    INTEGER NOT NULL DEFAULT 0,-- 1 = 本笔被削减
  revision        INTEGER NOT NULL DEFAULT 0,-- 编辑次数；记录类流水幂等键 = <id>#<revision>
  is_abnormal     INTEGER NOT NULL DEFAULT 0,-- 1 = 数值超出合理范围
  note            TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  is_deleted      INTEGER NOT NULL DEFAULT 0,
  device_id       TEXT,
  sync_state      TEXT    NOT NULL DEFAULT 'local'
)`,
    `CREATE INDEX IF NOT EXISTS idx_cr_user_time ON carbon_record(user_id, occurred_at DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_cr_user_cat  ON carbon_record(user_id, category, occurred_at DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_cr_updated   ON carbon_record(updated_at)`,
    // ========== 2. 因子元信息（静态字典） ==========
    `CREATE TABLE IF NOT EXISTS carbon_factor_meta (
  id             TEXT PRIMARY KEY,
  version        TEXT NOT NULL,              -- CF-2026.2
  source_updated TEXT,
  note           TEXT,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
)`,
    // ========== 3. 积分流水（只增） ==========
    `CREATE TABLE IF NOT EXISTS point_record (
  id           TEXT PRIMARY KEY,
  user_id      TEXT    NOT NULL,
  type         TEXT    NOT NULL,   -- record | record_capped | goal | purchase | carbon_include | reverse
  flow_kind    TEXT    NOT NULL,   -- primary | reverse（B30/B31 修复：同一业务事实只允许一条 primary）
  points       INTEGER NOT NULL,   -- 正 = 收入，负 = 支出
  source_type  TEXT    NOT NULL,   -- carbon_record | goal | shop_item | carbon_include（无 'adjust'：无产生方，见 §7.1）
  source_id    TEXT    NOT NULL,   -- 关联业务主键；取值口径见下方注释
  title        TEXT    NOT NULL,   -- 展示用标题
  remark       TEXT,
  occurred_at  INTEGER NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  is_deleted   INTEGER NOT NULL DEFAULT 0,
  device_id    TEXT,
  sync_state   TEXT    NOT NULL DEFAULT 'local'
)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_pr_source ON point_record(source_type, source_id, flow_kind)`,
    `CREATE INDEX IF NOT EXISTS idx_pr_user_time ON point_record(user_id, occurred_at DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_pr_cap       ON point_record(user_id, occurred_at, source_type, is_deleted)`,
    `CREATE INDEX IF NOT EXISTS idx_pr_updated   ON point_record(updated_at)`,
    // ========== 4. 每日积分缓存（派生，可重建；不参与判定、不参与同步） ==========
    `CREATE TABLE IF NOT EXISTS point_daily_stat (
  user_id        TEXT    NOT NULL,
  day_key        TEXT    NOT NULL,            -- YYYY-MM-DD
  record_points  INTEGER NOT NULL DEFAULT 0,  -- 记录类净额（record + record_capped + reverse）
  goal_points    INTEGER NOT NULL DEFAULT 0,
  spent_points   INTEGER NOT NULL DEFAULT 0,  -- 正数存储，表示支出绝对值
  record_count   INTEGER NOT NULL DEFAULT 0,
  rebuilt_at     INTEGER,
  updated_at     INTEGER NOT NULL,
  PRIMARY KEY (user_id, day_key)              -- 主键必须含 user_id：demo-user 与 local-guest 同日并存
)`,
    `CREATE INDEX IF NOT EXISTS idx_pds_day ON point_daily_stat(day_key DESC)`,
    // ========== 5. 目标定义（静态字典） ==========
    `CREATE TABLE IF NOT EXISTS goal_def (
  id          TEXT PRIMARY KEY,       -- S1..S5, M1..M5, L1
  name        TEXT NOT NULL,
  tier        TEXT NOT NULL,          -- short | mid | long
  period      TEXT NOT NULL,          -- day | week | month | quarter | year | hundred_days
  metric      TEXT NOT NULL,          -- count | sum_amount | sum_reduction | distinct_days
  category    TEXT,                   -- 限定的行为大类（NULL = 不限）
  sub_types   TEXT,                   -- JSON 数组字符串（NULL = 不限）
  unit        TEXT,                   -- km | kWh | kg | 条 | 天
  threshold   REAL NOT NULL,
  reward      INTEGER NOT NULL,
  icon        TEXT NOT NULL,
  "order"     INTEGER NOT NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
)`,
    // ========== 6. 用户目标进度 ==========
    `CREATE TABLE IF NOT EXISTS user_goal (
  id          TEXT PRIMARY KEY,
  user_id     TEXT    NOT NULL,
  goal_id     TEXT    NOT NULL,
  period_key  TEXT    NOT NULL,       -- D:2026-11-06 / W:2026-W45 / M:2026-11 / Q:2026-Q4 / Y:2026 / L:2026-06-01
  progress    REAL    NOT NULL DEFAULT 0,
  threshold   REAL    NOT NULL,
  settled     INTEGER NOT NULL DEFAULT 0,   -- 1 = 已发分（周期内只结算一次）
  settled_at  INTEGER,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  is_deleted  INTEGER NOT NULL DEFAULT 0,
  device_id   TEXT,
  sync_state  TEXT    NOT NULL DEFAULT 'local'
)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_ug ON user_goal(user_id, goal_id, period_key)`,
    `CREATE INDEX IF NOT EXISTS idx_ug_updated ON user_goal(updated_at)`,
    // ========== 7. 徽章定义（静态字典） ==========
    `CREATE TABLE IF NOT EXISTS badge_def (
  id          TEXT PRIMARY KEY,       -- B_FIRST ...
  name        TEXT NOT NULL,
  description TEXT NOT NULL,
  tier        TEXT NOT NULL,          -- bronze | silver | gold
  icon        TEXT NOT NULL,
  metric      TEXT NOT NULL,          -- first_record | streak | total_reduction | travel_count | recycle_kg | frame_count
  threshold   REAL NOT NULL,
  "order"     INTEGER NOT NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
)`,
    // ========== 8. 用户徽章 ==========
    `CREATE TABLE IF NOT EXISTS user_badge (
  id          TEXT PRIMARY KEY,
  user_id     TEXT    NOT NULL,
  badge_id    TEXT    NOT NULL,
  unlocked    INTEGER NOT NULL DEFAULT 0,
  unlocked_at INTEGER,
  progress    REAL    NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  is_deleted  INTEGER NOT NULL DEFAULT 0,
  device_id   TEXT,
  sync_state  TEXT    NOT NULL DEFAULT 'local'
)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_ub ON user_badge(user_id, badge_id)`,
    `CREATE INDEX IF NOT EXISTS idx_ub_updated ON user_badge(updated_at)`,
    // ========== 9. 商品（价格可由后台下发） ==========
    `CREATE TABLE IF NOT EXISTS shop_item (
  id              TEXT PRIMARY KEY,   -- frame_01..frame_08 / theme_default
  section         TEXT    NOT NULL,   -- frame | theme
  name            TEXT    NOT NULL,
  description     TEXT,
  price           INTEGER NOT NULL,
  icon            TEXT    NOT NULL,
  "order"         INTEGER NOT NULL DEFAULT 0,
  on_shelf        INTEGER NOT NULL DEFAULT 1,
  is_default_free INTEGER NOT NULL DEFAULT 0,  -- 默认免费主题 = 1
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
)`,
    // ========== 10. 购买记录 ==========
    `CREATE TABLE IF NOT EXISTS user_purchase (
  id           TEXT PRIMARY KEY,
  user_id      TEXT    NOT NULL,
  item_id      TEXT    NOT NULL,
  price_paid   INTEGER NOT NULL,
  purchased_at INTEGER NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  is_deleted   INTEGER NOT NULL DEFAULT 0,
  device_id    TEXT,
  sync_state   TEXT    NOT NULL DEFAULT 'local'
)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_up ON user_purchase(user_id, item_id)`,
    `CREATE INDEX IF NOT EXISTS idx_up_updated ON user_purchase(updated_at)`,
    // ========== 11. 外观设置 ==========
    `CREATE TABLE IF NOT EXISTS user_appearance (
  id         TEXT PRIMARY KEY,
  user_id    TEXT    NOT NULL,
  avatar_id  TEXT    NOT NULL,        -- avatar_leaf ...（8 个内置，全部免费）
  frame_id   TEXT,                    -- frame_01..frame_08（NULL = 不佩戴）
  theme_id   TEXT    NOT NULL,        -- theme_default
  nickname   TEXT,                    -- 选填，分享卡片用；留空显示「碳小布用户」
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  device_id  TEXT,
  sync_state TEXT    NOT NULL DEFAULT 'local'
)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_ua ON user_appearance(user_id)`,
    `CREATE INDEX IF NOT EXISTS idx_ua_updated ON user_appearance(updated_at)`,
    // ========== 12. 科普索引（静态字典，正文在 rawfile） ==========
    `CREATE TABLE IF NOT EXISTS science_article (
  id           TEXT PRIMARY KEY,      -- sci-01..sci-12
  title        TEXT    NOT NULL,
  category     TEXT    NOT NULL,      -- policy | tips | knowledge
  summary      TEXT,
  cover        TEXT,
  read_minutes INTEGER NOT NULL DEFAULT 3,
  tags         TEXT,                  -- JSON 数组字符串
  "order"      INTEGER NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
)`,
    // ========== 13. 科普阅读进度 ==========
    `CREATE TABLE IF NOT EXISTS science_progress (
  id           TEXT PRIMARY KEY,
  user_id      TEXT    NOT NULL,
  article_id   TEXT    NOT NULL,
  progress     REAL    NOT NULL DEFAULT 0,   -- 0~1
  is_favorite  INTEGER NOT NULL DEFAULT 0,
  last_read_at INTEGER,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  is_deleted   INTEGER NOT NULL DEFAULT 0,
  device_id    TEXT,
  sync_state   TEXT    NOT NULL DEFAULT 'local'
)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_sp ON science_progress(user_id, article_id)`,
    `CREATE INDEX IF NOT EXISTS idx_sp_updated ON science_progress(updated_at)`,
    // ========== 14. 碳普惠兑换记录（模拟演示） ==========
    `CREATE TABLE IF NOT EXISTS carbon_include (
  id           TEXT PRIMARY KEY,
  user_id      TEXT    NOT NULL,
  action       TEXT    NOT NULL,      -- exchange（积分→碳币） | redeem（碳币→权益）
  points_spent INTEGER NOT NULL,      -- 消耗积分（正数存储）
  coin_amount  INTEGER NOT NULL,      -- 获得 / 消耗碳币数
  benefit_id   TEXT,                  -- 权益编码（redeem 时有值）
  benefit_name TEXT,
  occurred_at  INTEGER NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  is_deleted   INTEGER NOT NULL DEFAULT 0,
  device_id    TEXT,
  sync_state   TEXT    NOT NULL DEFAULT 'local'
)`,
    `CREATE INDEX IF NOT EXISTS idx_ci_user_time ON carbon_include(user_id, occurred_at DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_ci_updated   ON carbon_include(updated_at)`,
    // ========== 15. 分享记录（本机专属） ==========
    `CREATE TABLE IF NOT EXISTS share_record (
  id           TEXT PRIMARY KEY,
  user_id      TEXT    NOT NULL,
  card_size    TEXT    NOT NULL,      -- 1080x1440 | 1080x1080
  reduction_kg REAL    NOT NULL,      -- 生成时的累计减排量
  badge_count  INTEGER NOT NULL,      -- 卡片上的徽章数
  saved_path   TEXT,                  -- 保存到相册 / 文件后的路径
  shared_to    TEXT,                  -- 分享目标描述（不接第三方 SDK）
  created_at   INTEGER NOT NULL
)`,
    `CREATE INDEX IF NOT EXISTS idx_sr_user_time ON share_record(user_id, created_at DESC)`,
    // ========== 16. 协同日志（本机专属） ==========
    `CREATE TABLE IF NOT EXISTS sync_log (
  id             TEXT PRIMARY KEY,
  user_id        TEXT    NOT NULL,
  peer_device    TEXT,                -- 对端设备标识（后 6 位）
  direction      TEXT    NOT NULL,    -- pull | push | both
  status         TEXT    NOT NULL,    -- success | failed | partial
  pulled_count   INTEGER NOT NULL DEFAULT 0,
  pushed_count   INTEGER NOT NULL DEFAULT 0,
  conflict_count INTEGER NOT NULL DEFAULT 0, -- 含「封顶超额不追回」计数
  error_msg      TEXT,
  started_at     INTEGER NOT NULL,
  finished_at    INTEGER,
  created_at     INTEGER NOT NULL
)`,
    `CREATE INDEX IF NOT EXISTS idx_sl_user_time ON sync_log(user_id, created_at DESC)`,
    // ========== 17. 用户档案（参与同步） ==========
    `CREATE TABLE IF NOT EXISTS user_profile (
  id             TEXT PRIMARY KEY,
  user_id        TEXT    NOT NULL,
  display_name   TEXT    NOT NULL DEFAULT '碳小布用户',
  register_day   TEXT    NOT NULL,    -- YYYY-MM-DD，L1「种树百天计划」的起点
  onboarded      INTEGER NOT NULL DEFAULT 0,
  last_active_at INTEGER,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  is_deleted     INTEGER NOT NULL DEFAULT 0,
  device_id      TEXT,
  sync_state     TEXT    NOT NULL DEFAULT 'local'
)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_uprofile ON user_profile(user_id)`,
    `CREATE INDEX IF NOT EXISTS idx_uprofile_updated ON user_profile(updated_at)`,
    // ========== 18. 设备信息（本机专属） ==========
    `CREATE TABLE IF NOT EXISTS device_info (
  id             TEXT PRIMARY KEY,
  device_id      TEXT    NOT NULL,
  device_name    TEXT,
  device_model   TEXT,
  is_self        INTEGER NOT NULL DEFAULT 1,
  last_sync_at   INTEGER,
  paired_devices TEXT,                -- JSON 数组：已配对设备快照
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
)`,
    // ========== 19. 应用配置（本机专属；含后台下发的商品价格） ==========
    `CREATE TABLE IF NOT EXISTS app_config (
  id         TEXT PRIMARY KEY,        -- config key
  value      TEXT NOT NULL,           -- JSON 字符串
  version    TEXT,
  fetched_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)`,
  ];

  /**
   * 附录 B §2 中夹在语句之间的**说明性注释**（非可执行 SQL，故不进 `DDL`）。
   * 原文逐字留存，便于与文档 diff；`PointService` 写流水时按这里的口径生成 `source_id`。
   */
  static readonly SOURCE_NOTES: string[] = [
    '幂等约束（v4.1）：`source_id` 取值口径**必须写死**（`PointService` 是唯一产生方）：',
    "  carbon_record  → '<carbon_record.id>#<revision>'   入账与冲正取同一值，靠 flow_kind 区分",
    "  goal           → '<goalId>:<periodKey>'            如 'S1:D:2026-02-01'",
    "  shop_item      → '<shop_item.id>'                   商品编码，如 'frame_01'",
    "  carbon_include → '<carbon_include.id>'              兑换记录主键",
    '唯一性：同一 source_type+source_id+flow_kind 只能有一条 → 同 revision 的 record / record_capped',
    "  不可能并存（它们都是 flow_kind='primary'），而 reverse 可与 primary 并存（冲正必进 D，见 PLAN §9.2）。",
    '  目标按 goalId:periodKey、商品按 item_id、记录按 <id>#<revision> 去重，跨设备重复发放只入账一次。',
  ];
}
