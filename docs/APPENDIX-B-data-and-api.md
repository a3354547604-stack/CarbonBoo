# 附录 B · 数据模型与接口契约

> **配套文档**：[PLAN.md](./PLAN.md) §8 数据设计总览、§12 多设备协同、§13 后台管理端
> **版本**：v4.0（客户端 19 张表 + 服务端 21 张表）
> **读者**：AI 编码代理。本附录是**数据层与网络层的唯一实现依据**——建表 SQL、模型定义、接口契约**照抄进代码**。

---

## 1. 表清单与通用约定

### 1.1 客户端 19 张表

| # | 表名 | 中文名 | 参与分布式同步 |
|:--:|---|---|:--:|
| 1 | `carbon_record` | 碳记录 | ✅ |
| 2 | `carbon_factor_meta` | 因子元信息 | ❌ |
| 3 | `point_record` | 积分流水 | ✅ |
| 4 | `point_daily_stat` | 每日积分缓存 | ❌ |
| 5 | `goal_def` | 目标定义 | ❌ |
| 6 | `user_goal` | 用户目标进度 | ✅ |
| 7 | `badge_def` | 徽章定义 | ❌ |
| 8 | `user_badge` | 用户徽章 | ✅ |
| 9 | `shop_item` | 商品 | ❌ |
| 10 | `user_purchase` | 购买记录 | ✅ |
| 11 | `user_appearance` | 外观设置 | ✅ |
| 12 | `science_article` | 科普索引 | ❌ |
| 13 | `science_progress` | 科普进度 | ✅ |
| 14 | `carbon_include` | 碳普惠兑换记录 | ✅ |
| 15 | `share_record` | 分享记录 | ❌ |
| 16 | `sync_log` | 协同日志 | ❌ |
| 17 | `user_profile` | 用户档案 | ✅ |
| 18 | `device_info` | 设备信息 | ❌ |
| 19 | `app_config` | 应用配置 | ❌ |

**参与同步 = 9 张**：1、3、6、8、10、11、13、14、17。
**不参与 = 10 张**，分三类：本机专属 4（`share_record`、`sync_log`、`device_info`、`app_config`）＋ 静态字典 5（`carbon_factor_meta`、`goal_def`、`badge_def`、`shop_item`、`science_article`）＋ 派生缓存 1（`point_daily_stat`）。

### 1.2 服务端 21 张表

- **18 张同名同构**：19 张客户端表里，`science_article` 与服务端无关（内容内置在 App），**服务端不建该表**，故 19 − 1 = 18。
- **3 张管理表**：`server_user`、`admin_user`、`admin_op_log`。
- 合计 **18 + 3 = 21 张**。

**类型映射**

| 客户端 SQLite | 服务端 MySQL |
|---|---|
| `TEXT` | `VARCHAR(n)` / `TEXT` |
| `INTEGER` | `BIGINT` / `INT` / `TINYINT` |
| `REAL` | `DOUBLE` |

### 1.3 通用字段约定

| 字段 | 客户端类型 | 服务端类型 | 说明 |
|---|---|---|---|
| `id` | `TEXT PRIMARY KEY` | `VARCHAR(36) PRIMARY KEY` | **UUID v4**，客户端生成（保证多设备不冲突） |
| `user_id` | `TEXT NOT NULL` | `VARCHAR(36) NOT NULL` | 本机档案 id；游客态 `local-guest`，演示 `demo-user` |
| `created_at` | `INTEGER NOT NULL` | `BIGINT NOT NULL` | 毫秒时间戳 |
| `updated_at` | `INTEGER NOT NULL` | `BIGINT NOT NULL` | **LWW 依据**，任何字段修改都必须更新它 |
| `is_deleted` | `INTEGER DEFAULT 0` | `TINYINT DEFAULT 0` | 软删除标记 |
| `device_id` | `TEXT` | `VARCHAR(64)` | 产生该条数据的设备 |
| `sync_state` | `TEXT DEFAULT 'local'` | — | `local` / `synced` / `pending`（仅客户端） |

**四条铁约定**
1. 所有时间戳**一律毫秒整数**，禁止字符串日期入库。
2. 日期维度（`day_key` / `period_key`）另存字符串，方便按日聚合与做幂等键。
3. 任何 `UPDATE` 必须同时改 `updated_at = Date.now()`，否则同步会漏。
4. 软删除 = `is_deleted = 1` + 更新 `updated_at`，**不物理删除**，否则删除无法传播。

---

## 2. 建表 SQL（客户端 19 张）

> 落盘路径：`app/entry/src/main/ets/data/schema/ClientSchema.ets`（SQL 字符串常量数组）

```sql
-- ========== 1. 碳记录 ==========
CREATE TABLE IF NOT EXISTS carbon_record (
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
  is_abnormal     INTEGER NOT NULL DEFAULT 0,-- 1 = 数值超出合理范围
  note            TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  is_deleted      INTEGER NOT NULL DEFAULT 0,
  device_id       TEXT,
  sync_state      TEXT    NOT NULL DEFAULT 'local'
);
CREATE INDEX IF NOT EXISTS idx_cr_user_time ON carbon_record(user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_cr_user_cat  ON carbon_record(user_id, category, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_cr_updated   ON carbon_record(updated_at);

-- ========== 2. 因子元信息（静态字典） ==========
CREATE TABLE IF NOT EXISTS carbon_factor_meta (
  id             TEXT PRIMARY KEY,
  version        TEXT NOT NULL,              -- CF-2026.2
  source_updated TEXT,
  note           TEXT,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);

-- ========== 3. 积分流水（只增） ==========
CREATE TABLE IF NOT EXISTS point_record (
  id           TEXT PRIMARY KEY,
  user_id      TEXT    NOT NULL,
  type         TEXT    NOT NULL,   -- record | record_capped | goal | purchase | carbon_include | reverse
  points       INTEGER NOT NULL,   -- 正 = 收入，负 = 支出
  source_type  TEXT    NOT NULL,   -- carbon_record | goal | shop_item | carbon_include | adjust
  source_id    TEXT    NOT NULL,   -- 关联业务主键
  title        TEXT    NOT NULL,   -- 展示用标题
  remark       TEXT,
  occurred_at  INTEGER NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  is_deleted   INTEGER NOT NULL DEFAULT 0,
  device_id    TEXT,
  sync_state   TEXT    NOT NULL DEFAULT 'local'
);
-- 幂等约束：同一条记录 / 同一目标周期 / 同一商品，绝不重复发分
CREATE UNIQUE INDEX IF NOT EXISTS uq_pr_source ON point_record(source_type, source_id, type);
CREATE INDEX IF NOT EXISTS idx_pr_user_time ON point_record(user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_pr_cap       ON point_record(user_id, occurred_at, source_type, is_deleted);
CREATE INDEX IF NOT EXISTS idx_pr_updated   ON point_record(updated_at);

-- ========== 4. 每日积分缓存（派生，可重建；不参与判定、不参与同步） ==========
CREATE TABLE IF NOT EXISTS point_daily_stat (
  day_key        TEXT PRIMARY KEY,            -- YYYY-MM-DD
  user_id        TEXT    NOT NULL,
  record_points  INTEGER NOT NULL DEFAULT 0,  -- 仅 record + record_capped
  goal_points    INTEGER NOT NULL DEFAULT 0,
  spent_points   INTEGER NOT NULL DEFAULT 0,  -- 正数存储，表示支出绝对值
  record_count   INTEGER NOT NULL DEFAULT 0,
  rebuilt_at     INTEGER,
  updated_at     INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pds_user ON point_daily_stat(user_id, day_key DESC);

-- ========== 5. 目标定义（静态字典） ==========
CREATE TABLE IF NOT EXISTS goal_def (
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
);

-- ========== 6. 用户目标进度 ==========
CREATE TABLE IF NOT EXISTS user_goal (
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
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ug ON user_goal(user_id, goal_id, period_key);
CREATE INDEX IF NOT EXISTS idx_ug_updated ON user_goal(updated_at);

-- ========== 7. 徽章定义（静态字典） ==========
CREATE TABLE IF NOT EXISTS badge_def (
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
);

-- ========== 8. 用户徽章 ==========
CREATE TABLE IF NOT EXISTS user_badge (
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
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ub ON user_badge(user_id, badge_id);
CREATE INDEX IF NOT EXISTS idx_ub_updated ON user_badge(updated_at);

-- ========== 9. 商品（价格可由后台下发） ==========
CREATE TABLE IF NOT EXISTS shop_item (
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
);

-- ========== 10. 购买记录 ==========
CREATE TABLE IF NOT EXISTS user_purchase (
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
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_up ON user_purchase(user_id, item_id);
CREATE INDEX IF NOT EXISTS idx_up_updated ON user_purchase(updated_at);

-- ========== 11. 外观设置 ==========
CREATE TABLE IF NOT EXISTS user_appearance (
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
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ua ON user_appearance(user_id);
CREATE INDEX IF NOT EXISTS idx_ua_updated ON user_appearance(updated_at);

-- ========== 12. 科普索引（静态字典，正文在 rawfile） ==========
CREATE TABLE IF NOT EXISTS science_article (
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
);

-- ========== 13. 科普阅读进度 ==========
CREATE TABLE IF NOT EXISTS science_progress (
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
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sp ON science_progress(user_id, article_id);
CREATE INDEX IF NOT EXISTS idx_sp_updated ON science_progress(updated_at);

-- ========== 14. 碳普惠兑换记录（模拟演示） ==========
CREATE TABLE IF NOT EXISTS carbon_include (
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
);
CREATE INDEX IF NOT EXISTS idx_ci_user_time ON carbon_include(user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_ci_updated   ON carbon_include(updated_at);

-- ========== 15. 分享记录（本机专属） ==========
CREATE TABLE IF NOT EXISTS share_record (
  id           TEXT PRIMARY KEY,
  user_id      TEXT    NOT NULL,
  card_size    TEXT    NOT NULL,      -- 1080x1440 | 1080x1080
  reduction_kg REAL    NOT NULL,      -- 生成时的累计减排量
  badge_count  INTEGER NOT NULL,      -- 卡片上的徽章数
  saved_path   TEXT,                  -- 保存到相册 / 文件后的路径
  shared_to    TEXT,                  -- 分享目标描述（不接第三方 SDK）
  created_at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sr_user_time ON share_record(user_id, created_at DESC);

-- ========== 16. 协同日志（本机专属） ==========
CREATE TABLE IF NOT EXISTS sync_log (
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
);
CREATE INDEX IF NOT EXISTS idx_sl_user_time ON sync_log(user_id, created_at DESC);

-- ========== 17. 用户档案（参与同步） ==========
CREATE TABLE IF NOT EXISTS user_profile (
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
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_uprofile ON user_profile(user_id);
CREATE INDEX IF NOT EXISTS idx_uprofile_updated ON user_profile(updated_at);

-- ========== 18. 设备信息（本机专属） ==========
CREATE TABLE IF NOT EXISTS device_info (
  id             TEXT PRIMARY KEY,
  device_id      TEXT    NOT NULL,
  device_name    TEXT,
  device_model   TEXT,
  is_self        INTEGER NOT NULL DEFAULT 1,
  last_sync_at   INTEGER,
  paired_devices TEXT,                -- JSON 数组：已配对设备快照
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);

-- ========== 19. 应用配置（本机专属；含后台下发的商品价格） ==========
CREATE TABLE IF NOT EXISTS app_config (
  id         TEXT PRIMARY KEY,        -- config key
  value      TEXT NOT NULL,           -- JSON 字符串
  version    TEXT,
  fetched_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
```

---

## 3. 建表 SQL（服务端 3 张管理表）

> 落盘路径：`server/sql/schema.sql`（其余 18 张同名表按 §1.2 类型映射生成）

```sql
CREATE TABLE IF NOT EXISTS server_user (
  id            VARCHAR(36)  PRIMARY KEY,
  user_id       VARCHAR(36)  NOT NULL,       -- 与客户端 user_id 对应
  username      VARCHAR(64)  NOT NULL,
  password_hash VARCHAR(100) NOT NULL,       -- bcrypt
  created_at    BIGINT       NOT NULL,
  last_login_at BIGINT,
  is_active     TINYINT      NOT NULL DEFAULT 1,
  UNIQUE KEY uq_su_username (username),
  UNIQUE KEY uq_su_userid   (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS admin_user (
  id            VARCHAR(36)  PRIMARY KEY,
  username      VARCHAR(64)  NOT NULL,
  password_hash VARCHAR(100) NOT NULL,
  created_at    BIGINT       NOT NULL,
  last_login_at BIGINT,
  UNIQUE KEY uq_au_username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS admin_op_log (
  id          VARCHAR(36) PRIMARY KEY,
  admin_id    VARCHAR(36) NOT NULL,
  action      VARCHAR(64) NOT NULL,          -- login | change_price | toggle_shelf | update_config ...
  target_type VARCHAR(32),
  target_id   VARCHAR(64),
  detail      TEXT,                          -- JSON：改前 / 改后
  ip          VARCHAR(64),
  created_at  BIGINT      NOT NULL,
  KEY idx_aol_admin (admin_id, created_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## 4. TypeScript 模型（客户端）

> 落盘路径：`app/entry/src/main/ets/model/`

```ts
// ---------- model/CarbonTypes.ets ----------
export type CategoryKey = 'travel' | 'utility' | 'recycle' | 'plate';
export type Confidence  = 'verified' | 'provisional';
export type SyncState   = 'local' | 'synced' | 'pending';

export interface BaseRow {
  id: string;
  userId: string;
  createdAt: number;
  updatedAt: number;
  isDeleted: number;
  deviceId?: string;
  syncState: SyncState;
}

export interface FactorItem {
  category: CategoryKey;
  subType: string;
  name: string;
  unit: string;
  value: number;
  source: string;
  confidence: Confidence;
  recording: boolean;        // 是否进录入表单
}

export interface CarbonRecord extends BaseRow {
  category: CategoryKey;
  subType: string;
  amount: number;
  unit: string;
  occurredAt: number;
  reductionKg: number;
  factorValue: number;
  factorVersion: string;
  factorSource: string;
  confidence: Confidence;
  pointAwarded: number;      // 实入
  pointCapped: number;
  isAbnormal: number;
  note?: string;
}

export interface CalculateInput {
  category: CategoryKey;
  subType: string;
  amount: number;
  occurredAt: number;
}

export interface CalculatePreview {
  reductionKg: number;
  estimatedPoint: number;    // 应得 C
  todayEarned: number;       // 今日已得 D
  willBeCapped: boolean;
  actualPoint: number;       // 实入 A
}

export interface SaveRecordResult {
  record: CarbonRecord;
  reductionKg: number;
  pointExpected: number;     // 应得
  pointAwarded: number;      // 实入
  capped: boolean;
  newGoals: string[];        // 本次结算的目标编码
  newBadges: string[];       // 本次解锁的徽章编码
}

// ---------- model/PointTypes.ets ----------
export type PointType =
  | 'record' | 'record_capped' | 'goal'
  | 'purchase' | 'carbon_include' | 'reverse';

export type PointSourceType =
  | 'carbon_record' | 'goal' | 'shop_item' | 'carbon_include' | 'adjust';

export interface PointRecord extends BaseRow {
  type: PointType;
  points: number;            // 正 = 收入，负 = 支出
  sourceType: PointSourceType;
  sourceId: string;
  title: string;
  remark?: string;
  occurredAt: number;
}

export interface PointBalance {
  balance: number;           // 收入 − 支出
  totalIncome: number;
  totalSpent: number;
  todayEarned: number;       // 记录分 + 目标分
  todayRecordPoint: number;  // 仅记录分，用于封顶进度条
  cap: number;               // 200
  carbonCoin: number;        // floor(balance / 100)
}

// ---------- model/GoalTypes.ets ----------
export type GoalTier   = 'short' | 'mid' | 'long';
export type GoalPeriod = 'day' | 'week' | 'month' | 'quarter' | 'year' | 'hundred_days';
export type GoalMetric = 'count' | 'sum_amount' | 'sum_reduction' | 'distinct_days';

export interface GoalDef {
  id: string;
  name: string;
  tier: GoalTier;
  period: GoalPeriod;
  metric: GoalMetric;
  category?: CategoryKey;
  subTypes?: string[];
  unit?: string;
  threshold: number;
  reward: number;
  icon: string;
  order: number;
}

export interface GoalProgress {
  goalId: string;
  name: string;
  tier: GoalTier;
  periodKey: string;
  progress: number;
  threshold: number;
  reward: number;
  settled: boolean;
  percent: number;           // 0~100
}

// ---------- model/BadgeTypes.ets ----------
export type BadgeMetric =
  | 'first_record' | 'streak' | 'total_reduction'
  | 'travel_count' | 'recycle_kg' | 'frame_count';

export interface BadgeDef {
  id: string;
  name: string;
  description: string;
  tier: 'bronze' | 'silver' | 'gold';
  icon: string;
  metric: BadgeMetric;
  threshold: number;
  order: number;
}

export interface BadgeProgress {
  badgeId: string;
  name: string;
  description: string;
  icon: string;
  unlocked: boolean;
  unlockedAt?: number;
  progress: number;
  threshold: number;
  percent: number;
}

// ---------- model/ShopTypes.ets ----------
export interface ShopItem {
  id: string;
  section: 'frame' | 'theme';
  name: string;
  description?: string;
  price: number;
  icon: string;
  order: number;
  onShelf: number;
  isDefaultFree: number;
}

export interface Appearance {
  avatarId: string;
  frameId?: string;
  themeId: string;
  nickname?: string;
}

// ---------- model/ScienceTypes.ets ----------
export type ScienceCategory = 'policy' | 'tips' | 'knowledge';

export interface ScienceArticleMeta {
  id: string;
  title: string;
  category: ScienceCategory;
  summary?: string;
  cover?: string;
  readMinutes: number;
  tags: string[];
  order: number;
}

export interface ScienceProgress {
  articleId: string;
  progress: number;
  isFavorite: number;
  lastReadAt?: number;
}

// ---------- model/IncludeTypes.ets ----------
export interface CarbonCoin {
  balance: number;           // 可用碳币
  totalExchanged: number;    // 历史累计兑换
  totalSpent: number;        // 历史累计消耗
  exchangeable: number;      // floor(积分余额 / 100)
}

export interface IncludeBenefit {
  id: string;
  name: string;
  description: string;
  coinCost: number;
  icon: string;
}

export interface CarbonIncludeRecord extends BaseRow {
  action: 'exchange' | 'redeem';
  pointsSpent: number;
  coinAmount: number;
  benefitId?: string;
  benefitName?: string;
  occurredAt: number;
}

// ---------- model/SyncTypes.ets ----------
export interface DevicePeer {
  deviceId: string;
  deviceName: string;
  deviceModel?: string;
  networkId: string;
  online: boolean;
  lastSeenAt?: number;
}

export interface SyncSessionState {
  phase: 'idle' | 'discovering' | 'merging' | 'writingBack' | 'done' | 'failed';
  progress: number;
  pulledCount: number;
  pushedCount: number;
  conflictCount: number;
  peerDevice?: string;
  startedAt?: number;
  finishedAt?: number;
  errorMsg?: string;
}

// ---------- model/AiTypes.ets ----------
export interface AiCandidate {
  category: CategoryKey;
  subType: string;
  confidence: number;
}

export interface AiRecognizeResult {
  recognized: boolean;
  category?: CategoryKey;
  subType?: string;
  confidence?: number;
  candidates?: AiCandidate[];
  engine: string;            // 'mock' | 'napi-model'
}

// ---------- model/Result.ets ----------
export interface AppResult<T> {
  ok: boolean;
  data?: T;
  code?: string;
  message?: string;
}
```

---

## 5. REST 契约

> **基础路径**：`/api/v1`；**管理接口**：`/admin/*` 用独立的 `adminToken`
> 客户端接口的 `Authorization: Bearer <userToken>` 仅用于云备份演示，**取价接口无需 token**

### 5.1 health

| 方法 | 路径 | 说明 | 响应示例 |
|---|---|---|---|
| GET | `/api/v1/health` | 存活检查 | `{ "ok": true, "version": "1.0.0", "time": 1762300000000 }` |

### 5.2 auth

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/v1/auth/register` | 注册（用户名 + 密码） |
| POST | `/api/v1/auth/login` | 登录，返回 JWT |
| GET | `/api/v1/auth/me` | 当前用户信息 |
| POST | `/api/v1/auth/logout` | 登出（服务端无状态，客户端清 token） |
| DELETE | `/api/v1/auth/account` | 注销账号（二次确认后调用） |

```jsonc
// POST /api/v1/auth/register
// req
{ "username": "harry_01", "password": "abc12345", "deviceId": "d-8f3a21" }
// res 201
{ "ok": true, "data": { "userToken": "eyJ...", "userId": "u-...", "username": "harry_01" } }
// res 409
{ "ok": false, "code": "USERNAME_TAKEN", "message": "用户名已被占用" }
```

**错误码表**

| code | HTTP | 含义 |
|---|:--:|---|
| `USERNAME_TAKEN` | 409 | 用户名已存在 |
| `USERNAME_INVALID` | 400 | 用户名不符合 4–20 位字母数字下划线 |
| `PASSWORD_INVALID` | 400 | 密码不符合 6–32 位 |
| `CREDENTIAL_INVALID` | 401 | 用户名或密码错误 |
| `TOKEN_EXPIRED` | 401 | token 过期 |
| `TOKEN_INVALID` | 401 | token 非法 |
| `FORBIDDEN` | 403 | 客户端 token 访问 `/admin` |
| `NOT_FOUND` | 404 | 资源不存在 |
| `RATE_LIMITED` | 429 | 触发限流 |
| `SERVER_ERROR` | 500 | 服务端异常 |

### 5.3 sync（**可选演示件**：云端备份 / 恢复）

> 多设备协同由**鸿蒙分布式数据服务**承担（见 §6）。本组接口只服务"云端备份"演示。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/sync/pull?since={ms}` | 拉取增量（`updated_at > since`） |
| POST | `/api/v1/sync/push` | 推送增量 |
| GET | `/api/v1/sync/status` | 云端统计（各表条数、最后时间） |

```jsonc
// POST /api/v1/sync/push
{
  "userId": "u-...", "deviceId": "d-8f3a21", "lastSyncAt": 1762290000000,
  "tables": { "carbon_record": [ /* CarbonRecord[] */ ], "point_record": [ /* ... */ ] }
}
// res 200
{
  "ok": true,
  "data": {
    "accepted": 42, "skipped": 3, "conflicts": 1, "serverTime": 1762300000000,
    "merged": { "carbon_record": [ /* 服务端更新后需回写的行 */ ] }
  }
}
```

### 5.4 shop + admin

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| GET | `/api/v1/shop/items` | 无 | 商品目录与价格（客户端启动拉取一次） |
| GET | `/admin/login` | 无 | 后台登录页 |
| POST | `/admin/login` | 无 | 管理员登录 → `adminToken` |
| POST | `/admin/password` | adminToken | 修改管理员密码 |
| GET | `/admin/items` | adminToken | 商品列表 |
| POST | `/admin/items` | adminToken | 新增商品 |
| PATCH | `/admin/items/{id}` | adminToken | 改价 / 改描述 / 排序 / 上下架 |
| POST | `/admin/items/{id}/icon` | adminToken | 上传图标 |
| GET | `/admin/users` | adminToken | 用户 / 设备列表 |
| GET | `/admin/overview` | adminToken | 数据总览 |
| GET | `/admin/orders` | adminToken | 订单记录 |
| GET | `/admin/config` | adminToken | 系统配置（目标奖励、封顶值、徽章开关） |
| PUT | `/admin/config` | adminToken | 修改系统配置 |
| GET | `/admin/logs` | adminToken | 操作日志 |

```jsonc
// GET /api/v1/shop/items
{
  "ok": true,
  "data": {
    "version": "2026.02.01-1",
    "items": [
      { "id": "frame_01", "section": "frame", "name": "嫩芽", "price": 1500,
        "icon": "res://frame_01", "order": 1, "onShelf": 1, "isDefaultFree": 0 },
      { "id": "theme_default", "section": "theme", "name": "默认主题（免费）",
        "price": 0, "icon": "res://theme_default", "order": 1, "onShelf": 1, "isDefaultFree": 1 }
    ]
  }
}
```

**客户端取价规则**：启动时有网 → 拉取并整份覆盖 `app_config['shop_items']`；失败或数据非法 → **整份丢弃**，继续用上一份有效配置；从未拉到过 → 用 `rawfile/shop/shop-items.json` 内置默认价。后台改价**下次启动生效**。

---

## 6. 鸿蒙分布式协同协议（创新项 Ⅰ）

### 6.1 使用的 API

| API | 用途 |
|---|---|
| `@ohos.distributedDeviceManager` | 设备发现、配对、在线状态查询 |
| `@ohos.distributedDataObject` | 会话级跨设备数据对象（`sessionId = userId`） |
| `@ohos.distributedKVStore` | 跨设备 KV 落盘与合并 |
| `@ohos.data.relationalStore` | **本机唯一真相源**（铁律 1） |

### 6.2 同步状态机

```
idle
 └─(用户点「立即同步」 / 距上次 > 5min 且对端在线 / 配对成功)
    ↓
discovering   —— 列出已配对设备；无在线对端 → failed（提示「未发现已配对设备」）
    ↓
merging       —— 逐表双向增量合并（LWW）
    ↓
writingBack   —— 合并结果写回本机 SQLite；更新 sync_state
    ↓
done          —— 写 sync_log(success)；更新 device_info.last_sync_at
```

任一阶段失败 → 直接跳 `failed`：写 `sync_log(failed, error_msg)`，**不更新 `last_sync_at`**。

### 6.3 LWW 合并伪码

```ts
async function mergeTable<T extends BaseRow>(
  table: string, local: T[], remote: T[], offsetMs: number
): Promise<{ merged: T[]; conflicts: number }> {
  const merged: T[] = [];
  let conflicts = 0;
  const map = new Map<string, T>();
  for (const row of local) map.set(row.id, row);

  for (const r of remote) {
    const l = map.get(r.id);
    if (!l) { merged.push(r); continue; }        // 本机没有 → 直接接纳
    const rUpdated = r.updatedAt + offsetMs;     // 时钟偏移校正
    if (rUpdated > l.updatedAt) {                // 对端更新 → 覆盖
      merged.push(r); conflicts++;
    } else if (rUpdated === l.updatedAt) {
      // 时间戳相等 → 以 deviceId 字典序大者胜，保证确定性
      if ((r.deviceId ?? '') > (l.deviceId ?? '')) { merged.push(r); conflicts++; }
    }
    // 否则保留本机版本
  }
  return { merged, conflicts };
}
```

### 6.4 六条硬约束

1. **本机优先**：合并期间任何失败都必须保持本机数据可用（用事务或"先备份后合并"）。
2. **删除也要传播**：比较 `is_deleted`；软删除行的 `updated_at` 更新后同样按 LWW 取胜。
3. **`id` 幂等**：UUID 主键，重复合并不产生重复行；**同一条 `carbon_record` 不重复发分**（`uq_pr_source` 兜底）。
4. **封顶口径（决策「甲2」）**：以**本机已知流水**判定封顶；合并后若某天记录分总量超 200，**不追回**已发分，只在 `sync_log.conflict_count` 里 +1。
5. **静态字典不参与合并**：`goal_def` / `badge_def` / `shop_item` / `science_article` / `carbon_factor_meta` 随 App 版本走。
6. **时钟偏移校正**：合并前握手估算 `offsetMs`，容差 **±5 分钟**；超容差时记 `sync_log.error_msg` 但仍按本机时间继续。

### 6.5 表分组与合并策略

| 组 | 表 | 策略 |
|---|---|---|
| 只增 | `point_record`、`carbon_include` | 按 `id` 去重后并集；不做覆盖 |
| 可改可删 | `carbon_record`、`user_goal`、`user_badge`、`user_purchase`、`user_appearance`、`science_progress` | 完整 LWW |
| 单例行 | `user_profile` | 按 `updated_at` 取新 |

---

## 7. Dao 接口清单（12 个）

> 落盘路径：`app/entry/src/main/ets/data/dao/`；**事务边界全在 Service 层**，Dao 只接受已开启的事务对象或使用默认连接。

| Dao | 关键方法 |
|---|---|
| `CarbonRecordDao` | `insert` / `update` / `softDelete` / `getById` / `listByRange` / `listByCategory` / `search` / `page` / `sumReduction` / `countTravel` / `sumRecycleKg` / `distinctDays` |
| `PointRecordDao` | `insert` / `listByRange` / `sumAll` / `sumTodayRecord` / `existsBySource` / `page` |
| `PointDailyStatDao` | `upsertIncrement` / `getByDay` / `listByRange` / `clearUser` / `bulkInsert`（重建用） |
| `GoalDao` | `listDefs` / `getDef` / `upsertUserGoal` / `getProgress` / `listProgress` / `markSettled` |
| `BadgeDao` | `listDefs` / `getDef` / `upsertUserBadge` / `listProgress` / `countUnlocked` |
| `ShopDao` | `replaceCatalog`（整份覆盖） / `listItems` / `getItem` / `upsertPurchase` / `hasPurchased` / `countFrames` / `listPurchases` |
| `AppearanceDao` | `getAppearance` / `upsertAppearance` / `clearUser` |
| `ScienceDao` | `listArticles` / `listByCategory` / `search` / `upsertProgress` / `listFavorites` |
| `IncludeDao` | `insertRecord` / `listRecords` / `sumPointsSpent` / `sumCoins` |
| `ShareDao` | `insertRecord` / `listRecords` / `clearUser` |
| `SyncLogDao` | `insert` / `updateFinish` / `listRecent` |
| `ConfigDao` | `getValue` / `setValue` / `getShopCatalog` / `saveShopCatalog` / `getJson` |

---

## 8. 种子数据

> 落盘路径：`app/entry/src/main/resources/rawfile/`

### 8.1 目标定义 `rawfile/goals/goal-defs.json`（11 条）

```json
[
  { "id": "S1", "name": "零碳出行",       "tier": "short", "period": "day",          "metric": "count",         "category": "travel",  "subTypes": ["walk","bicycle","ebike","bus","metro","carpool"], "unit": "条", "threshold": 1,   "reward": 20,   "icon": "ic_goal_s1", "order": 1 },
  { "id": "S2", "name": "省电小标兵",     "tier": "short", "period": "day",          "metric": "sum_amount",    "category": "utility", "subTypes": ["elec_grid"], "unit": "kWh", "threshold": 5,   "reward": 20,   "icon": "ic_goal_s2", "order": 2 },
  { "id": "S3", "name": "光盘卫士",       "tier": "short", "period": "day",          "metric": "count",         "category": "plate",   "subTypes": ["meal"], "unit": "条", "threshold": 1,   "reward": 15,   "icon": "ic_goal_s3", "order": 3 },
  { "id": "S4", "name": "回收一袋",       "tier": "short", "period": "week",         "metric": "count",         "category": "recycle", "unit": "条", "threshold": 3,   "reward": 40,   "icon": "ic_goal_s4", "order": 4 },
  { "id": "S5", "name": "记录不间断",     "tier": "short", "period": "week",         "metric": "distinct_days", "unit": "天", "threshold": 5,   "reward": 60,   "icon": "ic_goal_s5", "order": 5 },
  { "id": "M1", "name": "百公里绿色出行", "tier": "mid",   "period": "month",        "metric": "sum_amount",    "category": "travel",  "subTypes": ["walk","bicycle","ebike","bus","metro","carpool"], "unit": "km", "threshold": 100, "reward": 200,  "icon": "ic_goal_m1", "order": 6 },
  { "id": "M2", "name": "减碳吨目标",     "tier": "mid",   "period": "quarter",      "metric": "sum_reduction", "unit": "kg", "threshold": 50,  "reward": 300,  "icon": "ic_goal_m2", "order": 7 },
  { "id": "M3", "name": "回收百千克",     "tier": "mid",   "period": "quarter",      "metric": "sum_amount",    "category": "recycle", "unit": "kg", "threshold": 20,  "reward": 200,  "icon": "ic_goal_m3", "order": 8 },
  { "id": "M4", "name": "光盘习惯养成",   "tier": "mid",   "period": "month",        "metric": "count",         "category": "plate",   "subTypes": ["meal"], "unit": "条", "threshold": 20,  "reward": 150,  "icon": "ic_goal_m4", "order": 9 },
  { "id": "M5", "name": "减碳达人",       "tier": "mid",   "period": "year",         "metric": "sum_reduction", "unit": "kg", "threshold": 200, "reward": 500,  "icon": "ic_goal_m5", "order": 10 },
  { "id": "L1", "name": "种树百天计划",   "tier": "long",  "period": "hundred_days", "metric": "distinct_days", "unit": "天", "threshold": 80,  "reward": 1000, "icon": "ic_goal_l1", "order": 11 }
]
```

> `period_key` 生成规则：`day` → `D:YYYY-MM-DD`；`week` → `W:YYYY-Www`（ISO 周，**周一 00:00 起**）；`month` → `M:YYYY-MM`；`quarter` → `Q:YYYY-Qn`；`year` → `Y:YYYY`；`hundred_days` → `L:YYYY-MM-DD`（注册日；窗口 = 注册日起 100 天）。

### 8.2 徽章定义 `rawfile/badges/badge-defs.json`（8 条）

```json
[
  { "id": "B_FIRST",      "name": "初次碳迹",  "description": "完成第 1 条低碳行为记录",          "tier": "bronze", "icon": "ic_badge_first",    "metric": "first_record",    "threshold": 1,   "order": 1 },
  { "id": "B_STREAK_7",   "name": "七日不辍",  "description": "连续 7 个自然日每天至少 1 条记录",  "tier": "bronze", "icon": "ic_badge_streak7",  "metric": "streak",          "threshold": 7,   "order": 2 },
  { "id": "B_STREAK_30",  "name": "月度坚持",  "description": "连续 30 个自然日每天至少 1 条记录", "tier": "silver", "icon": "ic_badge_streak30", "metric": "streak",          "threshold": 30,  "order": 3 },
  { "id": "B_TOTAL_10",   "name": "减排十千克","description": "累计减排量达到 10 kgCO₂e",        "tier": "bronze", "icon": "ic_badge_total10",  "metric": "total_reduction", "threshold": 10,  "order": 4 },
  { "id": "B_TOTAL_100",  "name": "减排百千克","description": "累计减排量达到 100 kgCO₂e",       "tier": "gold",   "icon": "ic_badge_total100", "metric": "total_reduction", "threshold": 100, "order": 5 },
  { "id": "B_GREEN_TRIP", "name": "绿色骑士",  "description": "出行类低碳记录累计 50 条",         "tier": "silver", "icon": "ic_badge_green",    "metric": "travel_count",    "threshold": 50,  "order": 6 },
  { "id": "B_RECYCLER",   "name": "循环使者",  "description": "回收类累计 20 kg",                "tier": "silver", "icon": "ic_badge_recycler", "metric": "recycle_kg",      "threshold": 20,  "order": 7 },
  { "id": "B_TREE",       "name": "种树人",    "description": "集齐全部 8 个头像框",              "tier": "gold",   "icon": "ic_badge_tree",     "metric": "frame_count",     "threshold": 8,   "order": 8 }
]
```

> **徽章一律不发积分**；未解锁也显示条件与进度条；解锁后**永久保留**（删记录不撤销）。

### 8.3 商品 `rawfile/shop/shop-items.json`（9 条）

```json
[
  { "id": "frame_01", "section": "frame", "name": "嫩芽", "description": "初生的绿色", "price": 1500,  "icon": "res://frame_01", "order": 1, "onShelf": 1, "isDefaultFree": 0 },
  { "id": "frame_02", "section": "frame", "name": "藤蔓", "description": "向上生长",   "price": 2500,  "icon": "res://frame_02", "order": 2, "onShelf": 1, "isDefaultFree": 0 },
  { "id": "frame_03", "section": "frame", "name": "风车", "description": "清洁能源",   "price": 3500,  "icon": "res://frame_03", "order": 3, "onShelf": 1, "isDefaultFree": 0 },
  { "id": "frame_04", "section": "frame", "name": "星河", "description": "夜空中的光", "price": 4500,  "icon": "res://frame_04", "order": 4, "onShelf": 1, "isDefaultFree": 0 },
  { "id": "frame_05", "section": "frame", "name": "极光", "description": "极地之美",   "price": 6000,  "icon": "res://frame_05", "order": 5, "onShelf": 1, "isDefaultFree": 0 },
  { "id": "frame_06", "section": "frame", "name": "墨竹", "description": "坚韧挺拔",   "price": 8000,  "icon": "res://frame_06", "order": 6, "onShelf": 1, "isDefaultFree": 0 },
  { "id": "frame_07", "section": "frame", "name": "鎏金", "description": "岁月沉淀",   "price": 10000, "icon": "res://frame_07", "order": 7, "onShelf": 1, "isDefaultFree": 0 },
  { "id": "frame_08", "section": "frame", "name": "年轮", "description": "时间的礼物", "price": 15000, "icon": "res://frame_08", "order": 8, "onShelf": 1, "isDefaultFree": 0 },
  { "id": "theme_default", "section": "theme", "name": "默认主题（免费）", "description": "绿色系默认外观", "price": 0, "icon": "res://theme_default", "order": 1, "onShelf": 1, "isDefaultFree": 1 }
]
```

> **8 个头像框总价 = 51,000 分**（1500+2500+3500+4500+6000+8000+10000+15000），集齐解锁 `B_TREE`「种树人」。
> **主题只做 1 套免费默认套装**：商品位与接入规范由本计划书定义，视觉稿由用户方另做。
> 购买规则：永久拥有、不可重复购买、不允许透支、不退款。

### 8.4 头像 `rawfile/appearance/avatars.json`（8 个，全部免费）

```json
[
  { "id": "avatar_leaf",    "name": "绿叶",     "icon": "res://avatar_leaf",    "default": true  },
  { "id": "avatar_drop",    "name": "水滴",     "icon": "res://avatar_drop",    "default": false },
  { "id": "avatar_bike",    "name": "单车",     "icon": "res://avatar_bike",    "default": false },
  { "id": "avatar_bulb",    "name": "灯泡",     "icon": "res://avatar_bulb",    "default": false },
  { "id": "avatar_recycle", "name": "回收标志", "icon": "res://avatar_recycle", "default": false },
  { "id": "avatar_plate",   "name": "餐盘",     "icon": "res://avatar_plate",   "default": false },
  { "id": "avatar_sprout",  "name": "树苗",     "icon": "res://avatar_sprout",  "default": false },
  { "id": "avatar_earth",   "name": "地球",     "icon": "res://avatar_earth",   "default": false }
]
```

> **8 个头像全部免费、默认投放、任选切换、不支持上传、不构成"收集"**。

### 8.5 碳普惠模拟权益 `rawfile/include/benefits.json`（5 条）

```json
[
  { "id": "ben_tree_1",   "name": "模拟认养一棵树",    "description": "模拟认养一棵树苗（不可提现）", "coinCost": 5,  "icon": "res://ben_tree"   },
  { "id": "ben_green_1",  "name": "模拟捐赠 1 kWh 绿电","description": "模拟支持绿电 1 kWh",          "coinCost": 2,  "icon": "res://ben_green"  },
  { "id": "ben_cert_1",   "name": "模拟低碳证书",      "description": "生成一张模拟电子证书",        "coinCost": 10, "icon": "res://ben_cert"   },
  { "id": "ben_public_1", "name": "模拟公益助力",      "description": "模拟助力一次环保公益",        "coinCost": 20, "icon": "res://ben_public" },
  { "id": "ben_badge_1",  "name": "模拟碳普惠勋章",    "description": "模拟获得一枚碳普惠勋章",      "coinCost": 30, "icon": "res://ben_badge"  }
]
```

> 汇率固定 **100 积分 = 1 碳币**；**全部权益均为模拟演示**，不做真实对接、不可提现、不可退，界面强制标注「模拟演示」。

### 8.6 科普索引 `rawfile/science/index.json`（12 篇）

正文为 Markdown，落 `rawfile/science/sci-01.md` … `sci-12.md`，分类 `policy`（政策 4 篇）/ `tips`（技巧 5 篇）/ `knowledge`（知识 3 篇）。

---

## 9. 迁移策略

| 场景 | 做法 |
|---|---|
| 首次安装 | 建 19 张表 → 写入静态字典（目标 / 徽章 / 商品 / 头像 / 权益 / 科普索引）→ 写 `user_profile`（`user_id = 'local-guest'`） |
| 版本升级 | `schemaVersion` 存 `app_config['schema_version']`；升版时**只做加表与加列**，不做破坏性改动 |
| 加列 | `ALTER TABLE ... ADD COLUMN` 必须带默认值 |
| 删列 / 改名 | **禁止**；改为新增列 + 数据迁移 + 旧列置空 |
| 因子库升级 | 提升 `factor_version`（当前 `CF-2026.2`）；**旧记录不改**（铁律 3） |
| 备份 / 恢复 | 见 PLAN §7.8：`schemaVersion` 不匹配 → 拒绝恢复并提示 |
| 演示数据 | `user_id = 'demo-user'`；关闭演示模式时按该 id 级联清理 19 张表 |

---

## 10. v4.0 相对 v3 的变更摘要

| 变更 | 说明 |
|---|---|
| 表数 21 → **19** | 删除 `demo_marker`；新增 `carbon_include`、`share_record` |
| 新增 `carbon_include` | 碳普惠模拟兑换（创新项 Ⅲ） |
| 新增 `share_record` | 分享卡片记录（创新项 Ⅳ） |
| 同步机制替换 | 云账号 pull / push → **鸿蒙分布式数据服务**（§6 全新） |
| 参与同步 7 → **9 张** | 新增 `carbon_include`、`user_profile` |
| 封顶判定换源 | 改为 `point_record` 实时聚合；`point_daily_stat` 降级为可重建的展示缓存 |
| 流水类型扩充 | 新增 `carbon_include` |
| `point_record` 幂等键 | `UNIQUE(source_type, source_id, type)` |
| 服务端定位 | 由"必需"降为**可选演示件**（18 张同名表 + 3 张管理表 = 21 张） |
| 后台规格并入 | 原附录 G 内容并入本附录 §5.4 与 PLAN 第 13 章，附录索引收敛为 A–F |
