# 附录 B · 数据模型与接口契约

> **配套文档**：[PLAN.md](./PLAN.md) §8 数据设计总览、§12 多设备协同、§13 后台管理端
> **版本**：v4.0（客户端 19 张表 + 服务端 21 张表）
> **读者**：AI 编码代理。本附录是**数据层与网络层的唯一实现依据**——建表 SQL、模型定义、接口契约**照抄进代码**。

---

## 1. 表清单与通用约定

### 1.1 客户端 19 张表

| # | 表名 | 中文名 | 参与同步（云端 + 近场） |
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
  revision        INTEGER NOT NULL DEFAULT 0,-- 编辑次数；记录类流水幂等键 = <id>#<revision>
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
);
-- 幂等约束（v4.2）：唯一键**必须含 `user_id`**。理由：`source_id` 的取值口径（下面四行）**不含账号维度**，
--   而本机库同时有 `local-guest` / `demo-user` / 账号 `userId`，服务端更是多账号共库 —— 唯一键缺 `user_id` 时，
--   两个账号同一天达成同名目标会得到**同一组键值**，后入账者被唯一索引挡下 → **合法积分流水丢失**。
-- `source_id` 取值口径**必须写死**（`PointService` 是唯一产生方）：
--   carbon_record  → '<carbon_record.id>#<revision>'   入账与冲正取同一值，靠 flow_kind 区分
--   goal           → '<goalId>:<periodKey>'            如 'S1:D:2026-02-01'
--   shop_item      → '<shop_item.id>'                   商品编码，如 'frame_01'
--   carbon_include → '<carbon_include.id>'              兑换记录主键
-- 唯一性：同一 user_id+source_type+source_id+flow_kind 只能有一条 → 同 revision 的 record / record_capped
--   不可能并存（它们都是 flow_kind='primary'），而 reverse 可与 primary 并存（冲正必进 D，见 PLAN §9.2）。
--   目标按 user_id+goalId:periodKey、商品按 user_id+item_id、记录按 user_id+<id>#<revision> 去重：
--   跨设备重复发放只入账一次，**跨账号互不影响**（同步写入的业务唯一键判定也一律按 (user_id, 业务键) 组合，见 §6.3/§6.5）。
-- [v4.2 文档对齐] 服务端 `server/sql/schema.sql`（老库走 `sql/migrations/001_uq_pr_source_user_id.sql`）与客户端
--   `ClientSchema`（`app/entry/src/main/ets/data/schema/ClientSchema.ets`）**都已按含 `user_id` 的口径实现**；
--   本条修正的是文档：v4.1 冻结的 `(source_type, source_id, flow_kind)` 少一个 `user_id`。
CREATE UNIQUE INDEX IF NOT EXISTS uq_pr_source ON point_record(user_id, source_type, source_id, flow_kind);
CREATE INDEX IF NOT EXISTS idx_pr_user_time ON point_record(user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_pr_cap       ON point_record(user_id, occurred_at, source_type, is_deleted);
CREATE INDEX IF NOT EXISTS idx_pr_updated   ON point_record(updated_at);

-- ========== 4. 每日积分缓存（派生，可重建；不参与判定、不参与同步） ==========
CREATE TABLE IF NOT EXISTS point_daily_stat (
  user_id        TEXT    NOT NULL,
  day_key        TEXT    NOT NULL,            -- YYYY-MM-DD
  record_points  INTEGER NOT NULL DEFAULT 0,  -- 记录类净额（record + record_capped + reverse）
  goal_points    INTEGER NOT NULL DEFAULT 0,
  spent_points   INTEGER NOT NULL DEFAULT 0,  -- 正数存储，表示支出绝对值
  record_count   INTEGER NOT NULL DEFAULT 0,
  rebuilt_at     INTEGER,
  updated_at     INTEGER NOT NULL,
  PRIMARY KEY (user_id, day_key)              -- 主键必须含 user_id：demo-user 与 local-guest 同日并存
);
CREATE INDEX IF NOT EXISTS idx_pds_day ON point_daily_stat(day_key DESC);

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

> **账号与设备的关系（B31 修复）**：`server_user` **不存 `device_id`**——设备粒度不落账号表。
> 客户端 `deviceId` 只出现在 §5.3 的同步请求体与各业务行的 `device_id` 列里；
> 后台 `/admin/users` 的「设备列表」口径 = 该用户已同步行按 `device_id` 去重 + 各自最后一次同步时间。
> 因此 §5.2 的注册/登录请求体**不接收 `deviceId`**（设备标识只在同步时上行）。

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
  revision: number;          // 编辑次数；记录类流水幂等键 = <id>#<revision>
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

export type FlowKind = 'primary' | 'reverse';

export type PointSourceType =
  | 'carbon_record' | 'goal' | 'shop_item' | 'carbon_include';

export interface PointRecord extends BaseRow {
  type: PointType;
  flowKind: FlowKind;        // primary | reverse；与 type 的派生关系见 §7.1
  points: number;            // 正 = 收入，负 = 支出
  sourceType: PointSourceType;
  sourceId: string;          // 取值口径见 §2 建表 SQL 注释
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

> **基础路径**：`/api/v1`；**管理接口**：`/admin/*` 用独立的 `adminToken`（两套独立 JWT 密钥，**客户端 token 访问 `/admin/*` 必须 403**）
> 客户端接口的 `Authorization: Bearer <userToken>` 用于**账号（§5.2）与同步（§5.3）**——这是 ADR-0001 的主通路；
> **只有取价接口 `/api/v1/shop/items` 无需 token**（未登录也能取价，失败即整份丢弃用内置默认价）。
> **未登录时客户端不调用除取价外的任何接口**（铁律 1）。

### 5.1 health

| 方法 | 路径 | 说明 | 响应示例 |
|---|---|---|---|
| GET | `/api/v1/health` | 存活检查 | `{ "ok": true, "version": "1.0.0", "time": 1762300000000 }` |

### 5.2 auth

> 鉴权口径：`register` / `login` **无需令牌**（它们就是拿令牌的地方）；`me` / `logout` / `account` **均需**
> `Authorization: Bearer <userToken>`，缺失/非法/过期 → 401，**账号已注销**（软删除保留期内旧令牌不可用）→ 401。

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| POST | `/api/v1/auth/register` | 无 | 注册（用户名 + 密码） |
| POST | `/api/v1/auth/login` | 无 | 登录，返回 JWT |
| GET | `/api/v1/auth/me` | Bearer | 当前用户信息 |
| POST | `/api/v1/auth/logout` | Bearer | 登出：服务端无状态（只记 `last_login_at`），客户端清 token 并回未登录态；**本机业务数据一条不删** |
| DELETE | `/api/v1/auth/account` | Bearer | 注销账号（ADR-0001 决策 ③）：校验密码后把该账号云端数据**软删除并保留 30 天**，期间同一用户名+密码再次登录可恢复；**本机业务数据一条不删**，客户端回未登录态 |

```jsonc
// POST /api/v1/auth/register
// req
{ "username": "harry_01", "password": "abc12345" }
// res 201
{ "ok": true, "data": { "userToken": "eyJ...", "userId": "u-...", "username": "harry_01" } }
// res 409
{ "ok": false, "code": "USERNAME_TAKEN", "message": "用户名已被占用" }

// POST /api/v1/auth/login   req 与上同（不含 deviceId）
// GET  /api/v1/auth/me      res { "ok": true, "data": { "userId": "u-...", "username": "harry_01" } }
// DELETE /api/v1/auth/account
// req
{ "password": "abc12345" }          // 服务端校验密码后才执行注销
// res 200
{ "ok": true, "data": { "purgeAfter": 1764892000000 } }   // 软删除保留 30 天，到点物理清除
```

> **首次登录的本机数据归属（ADR-0001 决策 ①）**：登录成功后由 `AuthService` 内的 `AccountMigrator`
> 把本机 `user_id = 'local-guest'` 的历史数据**全部改挂账号 `userId`** 并置 `sync_state = 'pending'`，
> 随后由 `CloudSyncService` 全量上传并入账号——即「首次登录时本机历史数据全部上传并入账号」，
> **不是**"上传到云端另存一份"。注销/登出**不回滚**这一步（本机数据仍属该账号，只是停止同步）。

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

### 5.3 sync（**必做**：多设备增量同步 + 云端备份 / 恢复）

> **鉴权（本组全部端点，一个不漏）**：`GET /sync/pull`、`POST /sync/push`、`GET /sync/status`、
> `POST /sync/backup`、`GET /sync/backup`、`POST /sync/backup/restore` **均需**
> `Authorization: Bearer <userToken>`。身份一律取自**令牌**；请求体里的 `userId` 只用于**对账**——
> 与令牌账号不一致时整批 403（一行都不写）。令牌缺失/非法/过期，或**账号已注销**（软删除保留期内的旧令牌不可用）
> → **401**。未登录时客户端不调用本组任何端点。
> 这组接口是 **ADR-0001 里跨设备一致性的唯一真通路**：登录后由 `CloudSyncService` 按 §6 的 LWW 算法交换增量。
> **鸿蒙分布式数据服务是近场演示层**（§6.6），只做同一 Wi-Fi 下的双机演示，**不承担跨设备一致性**。
> **未登录时不调用本组接口**，客户端全部功能照常可用（铁律 1 的例外集只含登录/注册、多设备同步、商品取价、云端备份）。
> **云端备份 = 独立三端点**（下表的 `/sync/backup` 两条 + `/sync/backup/restore`）：只存快照，
> **不做 LWW 比较、不算冲突、不用 `lastSyncAt`**；恢复**即覆盖**，并且覆盖**之前**先把云端原状随响应 `preRestore`
> 返回给调用方落盘（见 PLAN §7.8）。**不是**"备份复用 `push`/`pull` 的 `since=0`"——那条路径会走 §6.3 的 LWW 合并，
> 语义是"合并"而不是"快照 / 覆盖"，两者不可互相替代。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/sync/pull?since={ms}` | 拉取增量（`updated_at > since`，含软删除行）；`since=0` = 全量拉取 |
| POST | `/api/v1/sync/push` | 推送增量（按 §6.3 合并，响应 `merged` 回带需回写的行） |
| GET | `/api/v1/sync/status` | 云端统计（各表条数 / 软删除数 / 最后更新时间 / 出现过的 `device_id` / 最近一次同步日志） |
| POST | `/api/v1/sync/backup` | **上传云端备份快照**：同 `id` 覆盖、新 `id` 插入；不做 LWW、不算冲突、不用 `lastSyncAt`；业务唯一键撞车计 `ignored`（不做自动合并）。响应 `stored` / `ignored` / `rejected` / `snapshotAt` / `tables` |
| GET | `/api/v1/sync/backup` | **下载云端快照**（"恢复即覆盖"的数据源）：整份返回 9 张参与同步表的云端行（含软删除行）+ 快照时间。响应 `snapshotAt` / `totalRows` / `tables` |
| POST | `/api/v1/sync/backup/restore` | **覆盖式恢复**：payload 里出现的表整体对齐快照（LWW 表按快照删 / 写；只增账本 `point_record` / `carbon_include` **只补不删**，铁律 4）；覆盖前原状随响应 `preRestore`（+ `preRestoreAt`）返回。响应 `restored` / `removed` / `tables` |

```jsonc
// POST /api/v1/sync/push                                  // 请求头：Authorization: Bearer <userToken>
{
  "userId": "u-...", "deviceId": "d-8f3a21", "lastSyncAt": 1762290000000,
  "clientNow": 1762299999999,   // 可选：客户端当前时钟（毫秒），服务端据此测时钟偏移；**缺失 = 按"无偏移"处理**
  "tables": { "carbon_record": [ /* CarbonRecord[] */ ], "point_record": [ /* ... */ ] }
}
// res 200
{
  "ok": true,
  "data": {
    "accepted": 42, "skipped": 3, "ignored": 3, "rejected": 0, "conflicts": 1,
    "serverTime": 1762300000000, "offsetMs": 1, "clockWarning": null,
    "merged": { "carbon_record": [ /* 服务端更新后需回写的行 */ ] }
  }
}
```

> **响应字段口径**：`skipped = ignored + rejected`（`skipped` 是本节原有的字段名，`ignored` 是 §6.4-3 的计数器名，
> 两者是同一个数，两个名字都回带，避免下游各按一种名字对接）；`ignored` = 跨设备重复已去重（`id` 或业务唯一键命中已有行），
> **不计入 `conflicts`**；`rejected` = 未采纳且保留服务端版本的行（已随 `merged` 回写，含非法行 / 越权行）；
> `conflicts` = 真冲突（定义见 §6.3 / §6.4-3）。
> `offsetMs = 服务端时钟 − 客户端时钟`（即服务端视角的"本机 − 对端"，见 §6.4-6）；`clientNow` 缺失时为 `0`（未校正，不猜值）；
> 超 ±5 分钟容差时 `clockWarning` 给出提示但**继续合并**。

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

## 6. 多设备同步协议与鸿蒙近场协同（创新项 Ⅰ）

> **本节是 LWW 合并算法与同步状态机的唯一实现依据**（`PLAN.md` §12 只是设计摘要，两者不一致时以本节为准）。
> 同一套算法被两条通路复用：
> - **云端同步（必做，ADR-0001 主通路）**：经 §5.3 的 `/sync/pull|push`，是跨设备一致性的唯一真通路；
> - **鸿蒙近场协同（近场演示层，创新项 Ⅰ）**：同一 Wi-Fi 下的双机演示，走 §6.6 的分布式 API。

### 6.1 使用的 API

| API | 用途 |
|---|---|
| `@ohos.net.http` | **云端同步**：调 §5.3 的 `pull` / `push`（登录后走 HTTPS） |
| `@ohos.distributedDeviceManager` | 近场演示：设备发现、配对、在线状态查询 |
| `@ohos.distributedDataObject` | 近场演示：会话级跨设备数据对象（`sessionId = userId`） |
| `@ohos.distributedKVStore` | 近场演示：跨设备 KV 落盘与合并 |
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
// lastSyncAt：上次成功同步的时间（device_info.last_sync_at），用于区分「真冲突」与「普通覆盖」
// mode：'lww'（可改可删）| 'appendOnly'（账本表：同 id **或**同业务唯一键已存在即跳过）
// businessKeyOf(row)：业务唯一键（§6.5 的 (user_id, 业务键) 组合）；
//   账本表 = uq_pr_source 的 (user_id, source_type, source_id, flow_kind)；
//   没有业务键的表（carbon_record / carbon_include / user_appearance / user_profile 除主键外）返回 null
async function mergeTable<T extends BaseRow>(
  table: string, local: T[], remote: T[],
  offsetMs: number, lastSyncAt: number, mode: 'lww' | 'appendOnly'
): Promise<{ toApply: T[]; conflicts: number; ignored: number }> {
  const toApply: T[] = [];
  let conflicts = 0, ignored = 0;
  const map = new Map<string, T>();       // id → 本机行
  const keys = new Set<string>();         // 业务唯一键（含 user_id）→ 本机已有
  for (const row of local) {
    map.set(row.id, row);
    const k = businessKeyOf(row);
    if (k !== null) keys.add(k);
  }

  for (const r of remote) {
    const l = map.get(r.id);
    if (mode === 'appendOnly') {
      // 账本表（point_record / carbon_include）**只增不删**（铁律 4）：
      // 同 id 已存在 → 跳过；id 不同但**业务唯一键已存在** → 同样是跨设备重复发放，一并跳过。
      // 两者都只计 ignored（面板「跨设备重复已去重」），**不计 conflicts**。
      const k = businessKeyOf(r);
      if (l !== undefined || (k !== null && keys.has(k))) { ignored++; continue; }
      toApply.push(r);
      if (k !== null) keys.add(k);
      continue;
    }
    if (!l) { toApply.push(r); continue; }         // 本机没有 → 直接接纳

    const rUpdated = r.updatedAt + offsetMs;       // 对端时间 → 本机时间基准
    if (rUpdated > l.updatedAt) {
      toApply.push(r);
      // 真冲突 = 两端自上次同步后都改过这一行
      if (l.updatedAt > lastSyncAt && r.updatedAt > lastSyncAt) conflicts++;
    } else if (rUpdated === l.updatedAt) {
      // 平局：deviceId 字典序大者胜；两端用同一规则，结论一致
      if ((r.deviceId ?? '') > (l.deviceId ?? '')) {
        toApply.push(r);
        // 与上面的「真冲突」定义保持同一条件：两端自上次同步后都改过才计数；
        // deviceId 也相同的行视为同一版本，保留本机版本（不计数）
        if (l.updatedAt > lastSyncAt && r.updatedAt > lastSyncAt) conflicts++;
      }
    }
    // 否则保留本机版本
  }
  return { toApply, conflicts, ignored };
}

// 写回（mergeTable 的两种 mode 都用同一句 SQL；它是上面"提前跳过"的**第二道**兜底，不是唯一一道）：
//   INSERT OR IGNORE INTO <table> (cols...) VALUES (...)
//   ├ 主键冲突（同 id）                 → 该行被忽略，ignored++，accepted 不加
//   ├ 业务唯一键冲突（uq_pr_source / uq_up / uq_uprofile / …）→ 该行被忽略，ignored++，面板计「跨设备重复已去重」
//   └ 插入成功                          → accepted++
// ⚠️ 账本表（point_record / carbon_include）**只增不删**（铁律 4）：只允许 INSERT OR IGNORE，
//    不允许用 UPDATE 补救；user_purchase 属「有唯一键的 LWW」（§6.5），LWW 胜出的行同样走这句兜底。
// 说明：`id` 与业务键**两道判重都在这里**——appendOnly 分支提前跳过（上面的 `keys` 集合），
//    写回时再由 `INSERT OR IGNORE` 兜底；缺任何一个都会跨设备重复发放（这就是 §6.4-3 的「双重幂等」）。
//    只按 `id` 去重的实现是**错的**：跨设备各自离线达成同一目标时 id 不同、业务键相同。
```

### 6.4 六条硬约束

1. **本机优先**：合并期间任何失败都必须保持本机数据可用（用事务或"先备份后合并"）。
2. **删除也要传播**：比较 `is_deleted`；软删除行的 `updated_at` 更新后同样按 LWW 取胜。
3. **`id` 与业务键双重幂等**：`id`（UUID）主键保证同一行不重复；业务唯一键（`uq_pr_source` / `uq_up` / `uq_uprofile`）保证跨设备重复发放**只入账一次**——账本表写入用 `INSERT OR IGNORE`，被忽略的行计入 `ignored`（§5.3 里同义的字段名是 `skipped`）。
   **`ignored` 不计入 `conflicts`**：`conflicts` 只按 §6.3 的「真冲突」条件计数（`l.updatedAt > lastSyncAt && r.updatedAt > lastSyncAt`，即"两端自上次同步后都改过这一行"）；去重丢弃的行是"同一事实的重复"，**不是冲突**，页面口径是「跨设备重复已去重」。
4. **封顶与重复发放（决策「甲2」）**：记录分以**本机已知流水**判定封顶，合并后若某天总量超 200，**不追回**已发分，只计冲突 +1；而**目标奖励与商品购买属「同一事实」**，跨设备重复发放 / 重复扣费**只入账一次**（业务唯一键 + `INSERT OR IGNORE`），两端收敛到同一账本。
5. **静态字典不参与合并**：`goal_def` / `badge_def` / `shop_item` / `science_article` / `carbon_factor_meta` 随 App 版本走。
6. **时钟偏移校正**：握手时测得 `offsetMs = 本机时钟 − 对端时钟`（两端互为相反数）：**客户端侧**取 `客户端时钟 − 服务端时钟`，**服务端侧**取 `服务端时钟 − 客户端时钟`（§5.3 请求体里可选的 `clientNow` 就是给服务端测这个用的；`clientNow` 缺失时 `offsetMs = 0`，按"无偏移"处理，不猜值）。比较前统一把对端时间戳换算到本机基准；容差 ±5 分钟，超容差记 `sync_log.error_msg`（响应里的 `clockWarning`）但仍继续。

### 6.5 表分组与合并策略

| 组 | 表 | 策略 |
|---|---|---|
| 只增（账本） | `point_record`、`carbon_include` | 按 `id` **与业务唯一键**双重去重后并集；写入统一 `INSERT OR IGNORE`——跨设备重复发放只入账一次（判定一律按 `(user_id, 业务键)` 组合，见 §2 的 `uq_pr_source`） |
| 可改可删 | `carbon_record`、`user_goal`、`user_badge`、`user_appearance`、`science_progress` | 完整 LWW |
| 有唯一键的 LWW | `user_purchase` | 完整 LWW；写回时 `UNIQUE(user_id, item_id)` 兜底，重复购买那条被忽略——记账上等价于**没有多扣一次分**（本项目不做退款流水，所以不是"退回多扣的分"）。**服务端忽略远端购买行时不产生任何流水**：不产生 `reverse`、也没有 `adjust` 这种 `source_type`（枚举里不存在，见 §2/§7.1），只是把该行计进 `ignored` |
| 单例行 | `user_profile` | **合并时按 `user_id` 收敛到一行，`id` 取胜者的**：同一 `user_id` 在两端各有一行（`id` 不同）时，只保留一行，落后的一方按响应 `merged` 把本机那行对齐到取胜行的 `id`；同 `id` 的两行仍按 `updated_at` 取新。每个 `user_id` 恒一行由 `uq_uprofile(user_id)` 保证 |

### 6.6 近场演示层（鸿蒙分布式）

| 项 | 口径 |
|---|---|
| 定位 | **演示层**：同一 Wi-Fi 下两台真机演示"数据互见"，不承担跨设备一致性 |
| 前置 | 未登录也可用（`sessionId = userId`，未登录时取 `local-guest`）；需两机已配对 |
| 范围 | 只同步 §6.5 的「可改可删」5 张 + 只增账本 2 张；`user_id` 不同的数据**绝不合并** |
| 失败降级 | 无在线对端 / 未授权分布式权限 → 提示「未发现已配对设备」+ 写 `sync_log(failed)`，**不影响任何本地功能** |
| 与云端的关系 | 云端同步是必做主通路；近场演示层可整体关闭（摘掉 `DistributedService` 后其余功能不受影响） |
| 验收 | 只进 `APPENDIX-D` 的创新项演示条目，**不作为任何必做验收的前置** |

---

## 7. Dao 接口清单（12 个 · 表 Dao）

> 落盘路径：`app/entry/src/main/ets/data/dao/`；**事务边界全在 Service 层**，Dao 只接受已开启的事务对象或使用默认连接。
> 本清单只含**表 Dao**；账号态的持久化在 §7.1（走 `preferences`，不建表），故不计入这 12 个。

| Dao | 关键方法 |
|---|---|
| `CarbonRecordDao` | `insert` / `update`（同时 `bumpRevision`）/ `softDelete` / `getById` / `listByRange` / `listByCategory` / `search` / `page` / `sumReduction` / `countTravel` / `sumRecycleKg` / `distinctDays` |
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

### 7.1 账号抽象层 `AuthProvider`（ADR-0001 要求，唯一登录入口）

> 落盘路径：`app/entry/src/main/ets/infra/auth/AuthProvider.ets`（接口 + 两个实现 + 选择器）
> **上层（页面 / ViewModel / `AuthService` / `CloudSyncService`）只允许依赖本接口**：禁止直接调 `HttpClient`、禁止直接读写 token。
> 本层**不是表 Dao**，故不计入上表 12 个；会话只落 `preferences`，**不建表**。

```ts
export type AuthProviderId = 'local' | 'server' | 'huaweiId';   // huaweiId 仅预留，v4.1 不实现

export interface AuthSession {
  userId: string;        // 账号态 = 服务端 userId；未登录 = 'local-guest'
  token: string;         // JWT；local 实现恒为 ''
  providerId: AuthProviderId;
  username?: string;
  expiresAt?: number;
}

export interface AuthProvider {
  readonly id: AuthProviderId;
  isAvailable(): Promise<boolean>;                      // server：/health 探活，3s 超时
  register(username: string, password: string): Promise<AuthSession>;
  login(username: string, password: string): Promise<AuthSession>;
  logout(): Promise<void>;                              // 调 §5.2 logout 后清本机会话
  currentSession(): Promise<AuthSession | null>;         // 只读 preferences，不发网络请求
  deleteAccount(password: string): Promise<void>;         // 注销：云端软删除保留 30 天
}
```

| 实现 | 行为 |
|---|---|
| `LocalAuthProvider`（默认） | 恒返回 `{ userId: 'local-guest', token: '', providerId: 'local' }`；**未登录 / 服务端不可达时的唯一态** |
| `ServerAuthProvider` | 调 §5.2 的 `/auth/*`；token 与 userId 只经 `AuthDao` 存进 `preferences['auth.session']` |
| `HuaweiAuthProvider` | **不实现**（API 12 无 Account Kit，ADR-0001 明确"不做华为账号"），仅保留枚举位 |

- **会话持久化**：`AuthDao`（`infra/auth/AuthDao.ets`，走 `preferences`，不入任何业务表）：`saveSession` / `getSession` / `clearSession`。
- **账号态不入表**：业务表只用 `user_id` 列表达归属；`userId` 与 `token` 一律不落 SQLite，唯一载体是 `preferences`。
- **登录副作用**：只有 `AuthService` 能在登录成功后调 `AccountMigrator`（把 `user_id='local-guest'` 的历史数据改挂账号并置 `pending`，见 §5.2）；登出/注销**不改动**业务表的 `user_id`。
- **`flow_kind` 派生规则（唯一定义）**：`PointService` 写流水时 `flow_kind = (type === 'reverse' ? 'reverse' : 'primary')`；`source_id` 取值见 §2 建表 SQL 注释。

---

## 8. 种子数据

> 落盘路径：`app/entry/src/main/resources/rawfile/`

### 8.1 目标定义 `rawfile/goals/goal-defs.json`（11 条）

> 数值（阈值 / 奖励 / 判定口径）的**唯一来源是 `PLAN.md` §10.1**；本文件只是它的落盘形态，改数值必须三处同改（PLAN §10.1 / 本文件 / `tests/cases/carbon-calc.json`）。

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

### 8.6 科普索引 `rawfile/science/science-index.json`（12 篇）

正文为 Markdown，落 `rawfile/science/sci-01.md` … `sci-12.md`，分类 `policy`（政策 4 篇）/ `tips`（技巧 4 篇）/ `knowledge`（知识 4 篇）。

---

## 9. 迁移策略

| 场景 | 做法 |
|---|---|
| 首次安装 | 建 19 张表 → 写入静态字典（目标 / 徽章 / 商品 / 头像 / 权益 / 科普索引）→ 写 `user_profile`（`id` = 新生成 UUID v4，`user_id = 'local-guest'`，`register_day` = 当天；**每个 `user_id` 恒一行**，由 `uq_uprofile` 保证——不是"主键填 user_id"） |
| 首次登录 | 本机 `user_id = 'local-guest'` 的历史数据**全部改挂账号 userId** 并置 `sync_state='pending'`，随后由 `CloudSyncService` 全量上传并入账号（ADR-0001 决策 ①，见 §5.2） |
| 注销账号 | 服务端把该账号云端数据软删除并**保留 30 天**（期间可恢复）；客户端清 token 回未登录态，**本机数据一条不删**（ADR-0001 决策 ③） |
| 版本升级 | `schemaVersion` 存 `app_config['schema_version']`；升版时**只做加表与加列**，不做破坏性改动 |
| 加列 | `ALTER TABLE ... ADD COLUMN` 必须带默认值 |
| 删列 / 改名 | **禁止**；改为新增列 + 数据迁移 + 旧列置空 |
| 因子库升级 | 提升 `factor_version`（当前 `CF-2026.2`）；**旧记录不改**（铁律 3） |
| 备份 / 恢复 | 见 PLAN §7.8：`schemaVersion` 不匹配 → 拒绝恢复并提示 |
| 演示数据 | `user_id = 'demo-user'`；关闭演示模式时按该 id 级联清理 19 张表 |

---

## 10. 变更记录

> 本节全文（含"v4.0 相对 v3 的变更摘要"）已收敛到 **[CHANGELOG.md](./CHANGELOG.md)**——全仓库唯一的变更记录来源。
> 数据层相关的 v4.0 变更在此只留索引：表数 21 → 19（删 `demo_marker`，新增 `carbon_include`、`share_record`）；
> 参与同步 7 → 9 张；封顶判定改为 `point_record` 实时聚合（`point_daily_stat` 降为可重建缓存）；
> `point_record` 幂等键 `UNIQUE(source_type, source_id, type)` → **`(source_type, source_id, flow_kind)`**（v4.1 修）→ **`(user_id, source_type, source_id, flow_kind)`**（v4.2 修，多账号共库必须隔离，见 §2）；
> **服务端为必做件（账号 + 同步 + 取价 + 备份），唯一可选件是 Web 后台管理端**（v4.1 修，ADR-0001）；
> 同步机制 = 服务端云端同步（主通路）+ 鸿蒙近场演示层（§6）；本轮 v4.1 全部改动见 `CHANGELOG.md`。
