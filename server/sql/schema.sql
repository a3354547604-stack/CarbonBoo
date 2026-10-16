-- ============================================================================
-- CarbonBoo 服务端建表脚本  server/sql/schema.sql
--
-- 唯一依据：docs/APPENDIX-B-data-and-api.md §1.2（服务端 21 张表）/ §1.3（通用字段约定）/ §3（3 张管理表）
--   * 18 张同名表 = 客户端 19 张表去掉 science_article（正文内置在 App，服务端不建），
--     按 §1.2「类型映射」+ §1.3「通用字段约定」生成：
--       TEXT → VARCHAR(n)/TEXT   INTEGER → BIGINT/INT/TINYINT   REAL → DOUBLE
--       `id` → VARCHAR(36) PRIMARY KEY；`user_id` → VARCHAR(36)；`device_id` → VARCHAR(64)
--       布尔标记 → TINYINT；`*_at` 毫秒时间戳 → BIGINT；其余整数 → INT
--       **服务端不建 `sync_state` 列**（§1.3：该列仅客户端）
--   * 3 张管理表 server_user / admin_user / admin_op_log 逐字取自 §3 原文。
--   * 客户端 CREATE INDEX 折进建表语句的 KEY 子句：MySQL 8 没有 CREATE INDEX IF NOT EXISTS，
--     折进去才能保证本脚本可重复执行（幂等）。
--   * 执行：mysql -h127.0.0.1 -uroot -p < sql/schema.sql
--   * **一处有意偏离附录 B 原文**：point_record 的 uq_pr_source 加了 user_id
--     （原文 §2:142 是 (source_type, source_id, flow_kind)）—— 服务端多账号共库，
--     少 user_id 会让两个账号的同名目标互相顶掉；增量迁移见 sql/migrations/001_*.sql，
--     文档侧待修正项见 server/README.md「附录 B 需同步修正的行号清单」。
-- ============================================================================

SET NAMES utf8mb4;

CREATE DATABASE IF NOT EXISTS `carbonboo`
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE `carbonboo`;


-- ========== 1. carbon_record（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `carbon_record` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  category         VARCHAR(32)  NOT NULL,
  sub_type         VARCHAR(64)  NOT NULL,
  amount           DOUBLE       NOT NULL,
  unit             VARCHAR(16)  NOT NULL,
  occurred_at      BIGINT       NOT NULL,
  reduction_kg     DOUBLE       NOT NULL,
  factor_value     DOUBLE       NOT NULL,
  factor_version   VARCHAR(32)  NOT NULL,
  factor_source    VARCHAR(64)  NOT NULL,
  confidence       VARCHAR(16)  NOT NULL,
  point_awarded    INT          NOT NULL DEFAULT 0,
  point_capped     TINYINT      NOT NULL DEFAULT 0,
  revision         INT          NOT NULL DEFAULT 0,
  is_abnormal      TINYINT      NOT NULL DEFAULT 0,
  note             TEXT,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL,
  is_deleted       TINYINT      NOT NULL DEFAULT 0,
  device_id        VARCHAR(64),
  KEY idx_cr_user_time (user_id, occurred_at DESC),
  KEY idx_cr_user_cat (user_id, category, occurred_at DESC),
  KEY idx_cr_updated (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 2. carbon_factor_meta（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `carbon_factor_meta` (
  id               VARCHAR(36)  PRIMARY KEY,
  version          VARCHAR(32)  NOT NULL,
  source_updated   VARCHAR(64),
  note             TEXT,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 3. point_record（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `point_record` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  type             VARCHAR(32)  NOT NULL,
  flow_kind        VARCHAR(16)  NOT NULL,
  points           INT          NOT NULL,
  source_type      VARCHAR(32)  NOT NULL,
  source_id        VARCHAR(128) NOT NULL,
  title            VARCHAR(128) NOT NULL,
  remark           TEXT,
  occurred_at      BIGINT       NOT NULL,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL,
  is_deleted       TINYINT      NOT NULL DEFAULT 0,
  device_id        VARCHAR(64),
  -- B35 契约的 uq_pr_source **加入 user_id**（服务端多账号共库的唯一正确形态）：
  --   附录 B §2:142 现文是 (source_type, source_id, flow_kind)，但 source_id 取值口径（§2:135-138）
  --   不含账号维度，两个账号同一天达成同名目标会得到同一组键值 → 后入账者被索引挡下（丢积分）。
  --   见 sql/migrations/001_uq_pr_source_user_id.sql 与 t5 报告「附录 B 需同步修正的行号清单」。
  UNIQUE KEY uq_pr_source (user_id, source_type, source_id, flow_kind),
  KEY idx_pr_user_time (user_id, occurred_at DESC),
  KEY idx_pr_cap (user_id, occurred_at, source_type, is_deleted),
  KEY idx_pr_updated (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 4. point_daily_stat（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `point_daily_stat` (
  user_id          VARCHAR(36)  NOT NULL,
  day_key          VARCHAR(16)  NOT NULL,
  record_points    INT          NOT NULL DEFAULT 0,
  goal_points      INT          NOT NULL DEFAULT 0,
  spent_points     INT          NOT NULL DEFAULT 0,
  record_count     INT          NOT NULL DEFAULT 0,
  rebuilt_at       BIGINT,
  updated_at       BIGINT       NOT NULL,
  PRIMARY KEY (user_id, day_key),
  KEY idx_pds_day (day_key DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 5. goal_def（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `goal_def` (
  id               VARCHAR(36)  PRIMARY KEY,
  name             VARCHAR(64)  NOT NULL,
  tier             VARCHAR(16)  NOT NULL,
  period           VARCHAR(16)  NOT NULL,
  metric           VARCHAR(32)  NOT NULL,
  category         VARCHAR(32),
  sub_types        TEXT,
  unit             VARCHAR(16),
  threshold        DOUBLE       NOT NULL,
  reward           INT          NOT NULL,
  icon             VARCHAR(255) NOT NULL,
  `order`          INT          NOT NULL,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 6. user_goal（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `user_goal` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  goal_id          VARCHAR(32)  NOT NULL,
  period_key       VARCHAR(32)  NOT NULL,
  progress         DOUBLE       NOT NULL DEFAULT 0,
  threshold        DOUBLE       NOT NULL,
  settled          TINYINT      NOT NULL DEFAULT 0,
  settled_at       BIGINT,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL,
  is_deleted       TINYINT      NOT NULL DEFAULT 0,
  device_id        VARCHAR(64),
  UNIQUE KEY uq_ug (user_id, goal_id, period_key),
  KEY idx_ug_updated (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 7. badge_def（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `badge_def` (
  id               VARCHAR(36)  PRIMARY KEY,
  name             VARCHAR(64)  NOT NULL,
  description      VARCHAR(255) NOT NULL,
  tier             VARCHAR(16)  NOT NULL,
  icon             VARCHAR(255) NOT NULL,
  metric           VARCHAR(32)  NOT NULL,
  threshold        DOUBLE       NOT NULL,
  `order`          INT          NOT NULL,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 8. user_badge（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `user_badge` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  badge_id         VARCHAR(64)  NOT NULL,
  unlocked         TINYINT      NOT NULL DEFAULT 0,
  unlocked_at      BIGINT,
  progress         DOUBLE       NOT NULL DEFAULT 0,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL,
  is_deleted       TINYINT      NOT NULL DEFAULT 0,
  device_id        VARCHAR(64),
  UNIQUE KEY uq_ub (user_id, badge_id),
  KEY idx_ub_updated (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 9. shop_item（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `shop_item` (
  id               VARCHAR(36)  PRIMARY KEY,
  section          VARCHAR(32)  NOT NULL,
  name             VARCHAR(64)  NOT NULL,
  description      VARCHAR(255),
  price            INT          NOT NULL,
  icon             VARCHAR(255) NOT NULL,
  `order`          INT          NOT NULL DEFAULT 0,
  on_shelf         TINYINT      NOT NULL DEFAULT 1,
  is_default_free  TINYINT      NOT NULL DEFAULT 0,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 10. user_purchase（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `user_purchase` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  item_id          VARCHAR(64)  NOT NULL,
  price_paid       INT          NOT NULL,
  purchased_at     BIGINT       NOT NULL,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL,
  is_deleted       TINYINT      NOT NULL DEFAULT 0,
  device_id        VARCHAR(64),
  UNIQUE KEY uq_up (user_id, item_id),
  KEY idx_up_updated (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 11. user_appearance（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `user_appearance` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  avatar_id        VARCHAR(64)  NOT NULL,
  frame_id         VARCHAR(64),
  theme_id         VARCHAR(64)  NOT NULL,
  nickname         VARCHAR(64),
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL,
  is_deleted       TINYINT      NOT NULL DEFAULT 0,
  device_id        VARCHAR(64),
  UNIQUE KEY uq_ua (user_id),
  KEY idx_ua_updated (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 12. science_progress（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `science_progress` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  article_id       VARCHAR(64)  NOT NULL,
  progress         DOUBLE       NOT NULL DEFAULT 0,
  is_favorite      TINYINT      NOT NULL DEFAULT 0,
  last_read_at     BIGINT,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL,
  is_deleted       TINYINT      NOT NULL DEFAULT 0,
  device_id        VARCHAR(64),
  UNIQUE KEY uq_sp (user_id, article_id),
  KEY idx_sp_updated (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 13. carbon_include（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `carbon_include` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  action           VARCHAR(32)  NOT NULL,
  points_spent     INT          NOT NULL,
  coin_amount      INT          NOT NULL,
  benefit_id       VARCHAR(64),
  benefit_name     VARCHAR(128),
  occurred_at      BIGINT       NOT NULL,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL,
  is_deleted       TINYINT      NOT NULL DEFAULT 0,
  device_id        VARCHAR(64),
  KEY idx_ci_user_time (user_id, occurred_at DESC),
  KEY idx_ci_updated (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 14. share_record（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `share_record` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  card_size        VARCHAR(32)  NOT NULL,
  reduction_kg     DOUBLE       NOT NULL,
  badge_count      INT          NOT NULL,
  saved_path       VARCHAR(255),
  shared_to        VARCHAR(128),
  created_at       BIGINT       NOT NULL,
  KEY idx_sr_user_time (user_id, created_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 15. sync_log（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `sync_log` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  peer_device      VARCHAR(64),
  direction        VARCHAR(16)  NOT NULL,
  status           VARCHAR(16)  NOT NULL,
  pulled_count     INT          NOT NULL DEFAULT 0,
  pushed_count     INT          NOT NULL DEFAULT 0,
  conflict_count   INT          NOT NULL DEFAULT 0,
  error_msg        TEXT,
  started_at       BIGINT       NOT NULL,
  finished_at      BIGINT,
  created_at       BIGINT       NOT NULL,
  KEY idx_sl_user_time (user_id, created_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 16. user_profile（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `user_profile` (
  id               VARCHAR(36)  PRIMARY KEY,
  user_id          VARCHAR(36)  NOT NULL,
  display_name     VARCHAR(64)  NOT NULL DEFAULT '碳小布用户',
  register_day     VARCHAR(16)  NOT NULL,
  onboarded        TINYINT      NOT NULL DEFAULT 0,
  last_active_at   BIGINT,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL,
  is_deleted       TINYINT      NOT NULL DEFAULT 0,
  device_id        VARCHAR(64),
  UNIQUE KEY uq_uprofile (user_id),
  KEY idx_uprofile_updated (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 17. device_info（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `device_info` (
  id               VARCHAR(36)  PRIMARY KEY,
  device_id        VARCHAR(64)  NOT NULL,
  device_name      VARCHAR(64),
  device_model     VARCHAR(64),
  is_self          TINYINT      NOT NULL DEFAULT 1,
  last_sync_at     BIGINT,
  paired_devices   TEXT,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 18. app_config（客户端同名表：按 §1.2 类型映射） ==========
CREATE TABLE IF NOT EXISTS `app_config` (
  id               VARCHAR(36)  PRIMARY KEY,
  value            TEXT         NOT NULL,
  version          VARCHAR(32),
  fetched_at       BIGINT,
  created_at       BIGINT       NOT NULL,
  updated_at       BIGINT       NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 19. server_user（管理表：逐字取自附录 B §3） ==========
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

-- ========== 20. admin_user（管理表：逐字取自附录 B §3） ==========
CREATE TABLE IF NOT EXISTS admin_user (
  id            VARCHAR(36)  PRIMARY KEY,
  username      VARCHAR(64)  NOT NULL,
  password_hash VARCHAR(100) NOT NULL,
  created_at    BIGINT       NOT NULL,
  last_login_at BIGINT,
  UNIQUE KEY uq_au_username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ========== 21. admin_op_log（管理表：逐字取自附录 B §3） ==========
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

