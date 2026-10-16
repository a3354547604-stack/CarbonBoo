-- ===========================================================================
-- CarbonBoo 服务端种子数据（静态字典）· server/sql/seed.sql
--
-- 用法：mysql -h 127.0.0.1 -P 3306 -u carbonboo -p < sql/schema.sql
--       mysql -h 127.0.0.1 -P 3306 -u carbonboo -p < sql/seed.sql
--
-- 口径来源（不在此新造任何数值）：
--   目标 11 条   → docs/APPENDIX-B-data-and-api.md §8.1（数值唯一来源 docs/PLAN.md §10.1）
--   徽章 8 条    → docs/APPENDIX-B-data-and-api.md §8.2
--   商品 9 条    → docs/APPENDIX-B-data-and-api.md §8.3（8 个头像框总价 51,000 分）
--   因子库版本   → docs/APPENDIX-A-data-factors.md §2.5（CF-2026.2，全仓唯一数值版本号）
--   每日封顶 200 → docs/PLAN.md §9（实入 A = max(0, min(C, 200 − D))）
--   口令策略/账号口径 → docs/adr/0001-account-and-sync.md
--
-- 幂等：全部 INSERT ... ON DUPLICATE KEY UPDATE，可重复执行（后台改价后重跑会把字典打回文档值，
--       因此**只在初始化与回归测试时执行**；线上改价走 /admin，不要重跑本脚本覆写 shop_item）。
-- 时间戳：静态字典统一用固定值 1755009600000（2025-08-12T14:40:00Z），保证种子可复现。
-- ===========================================================================

SET NAMES utf8mb4;
USE carbonboo;  -- 目标库（schema.sql 已 CREATE DATABASE IF NOT EXISTS carbonboo）
SET @SEED_TS = 1755009600000;

-- ---------- 1. goal_def：11 个目标（PLAN §10.1 / 附录 B §8.1） ----------
INSERT INTO `goal_def`
  (`id`, `name`, `tier`, `period`, `metric`, `category`, `sub_types`, `unit`,
   `threshold`, `reward`, `icon`, `order`, `created_at`, `updated_at`)
VALUES
  ('S1', '零碳出行', 'short', 'day', 'count', 'travel', '["walk","bicycle","ebike","bus","metro","carpool"]', '条', 1, 20, 'ic_goal_s1', 1, @SEED_TS, @SEED_TS),
  ('S2', '省电小标兵', 'short', 'day', 'sum_amount', 'utility', '["elec_grid"]', 'kWh', 5, 20, 'ic_goal_s2', 2, @SEED_TS, @SEED_TS),
  ('S3', '光盘卫士', 'short', 'day', 'count', 'plate', '["meal"]', '条', 1, 15, 'ic_goal_s3', 3, @SEED_TS, @SEED_TS),
  ('S4', '回收一袋', 'short', 'week', 'count', 'recycle', NULL, '条', 3, 40, 'ic_goal_s4', 4, @SEED_TS, @SEED_TS),
  ('S5', '记录不间断', 'short', 'week', 'distinct_days', NULL, NULL, '天', 5, 60, 'ic_goal_s5', 5, @SEED_TS, @SEED_TS),
  ('M1', '百公里绿色出行', 'mid', 'month', 'sum_amount', 'travel', '["walk","bicycle","ebike","bus","metro","carpool"]', 'km', 100, 200, 'ic_goal_m1', 6, @SEED_TS, @SEED_TS),
  ('M2', '减碳吨目标', 'mid', 'quarter', 'sum_reduction', NULL, NULL, 'kg', 50, 300, 'ic_goal_m2', 7, @SEED_TS, @SEED_TS),
  ('M3', '回收百千克', 'mid', 'quarter', 'sum_amount', 'recycle', NULL, 'kg', 20, 200, 'ic_goal_m3', 8, @SEED_TS, @SEED_TS),
  ('M4', '光盘习惯养成', 'mid', 'month', 'count', 'plate', '["meal"]', '条', 20, 150, 'ic_goal_m4', 9, @SEED_TS, @SEED_TS),
  ('M5', '减碳达人', 'mid', 'year', 'sum_reduction', NULL, NULL, 'kg', 200, 500, 'ic_goal_m5', 10, @SEED_TS, @SEED_TS),
  ('L1', '种树百天计划', 'long', 'hundred_days', 'distinct_days', NULL, NULL, '天', 80, 1000, 'ic_goal_l1', 11, @SEED_TS, @SEED_TS)
ON DUPLICATE KEY UPDATE
  `name`=VALUES(`name`), `tier`=VALUES(`tier`), `period`=VALUES(`period`), `metric`=VALUES(`metric`),
  `category`=VALUES(`category`), `sub_types`=VALUES(`sub_types`), `unit`=VALUES(`unit`),
  `threshold`=VALUES(`threshold`), `reward`=VALUES(`reward`), `icon`=VALUES(`icon`),
  `order`=VALUES(`order`), `updated_at`=VALUES(`updated_at`);

-- ---------- 2. badge_def：8 枚徽章（附录 B §8.2；徽章一律不发积分） ----------
INSERT INTO `badge_def`
  (`id`, `name`, `description`, `tier`, `icon`, `metric`, `threshold`, `order`, `created_at`, `updated_at`)
VALUES
  ('B_FIRST', '初次碳迹', '完成第 1 条低碳行为记录', 'bronze', 'ic_badge_first', 'first_record', 1, 1, @SEED_TS, @SEED_TS),
  ('B_STREAK_7', '七日不辍', '连续 7 个自然日每天至少 1 条记录', 'bronze', 'ic_badge_streak7', 'streak', 7, 2, @SEED_TS, @SEED_TS),
  ('B_STREAK_30', '月度坚持', '连续 30 个自然日每天至少 1 条记录', 'silver', 'ic_badge_streak30', 'streak', 30, 3, @SEED_TS, @SEED_TS),
  ('B_TOTAL_10', '减排十千克', '累计减排量达到 10 kgCO₂e', 'bronze', 'ic_badge_total10', 'total_reduction', 10, 4, @SEED_TS, @SEED_TS),
  ('B_TOTAL_100', '减排百千克', '累计减排量达到 100 kgCO₂e', 'gold', 'ic_badge_total100', 'total_reduction', 100, 5, @SEED_TS, @SEED_TS),
  ('B_GREEN_TRIP', '绿色骑士', '出行类低碳记录累计 50 条', 'silver', 'ic_badge_green', 'travel_count', 50, 6, @SEED_TS, @SEED_TS),
  ('B_RECYCLER', '循环使者', '回收类累计 20 kg', 'silver', 'ic_badge_recycler', 'recycle_kg', 20, 7, @SEED_TS, @SEED_TS),
  ('B_TREE', '种树人', '集齐全部 8 个头像框', 'gold', 'ic_badge_tree', 'frame_count', 8, 8, @SEED_TS, @SEED_TS)
ON DUPLICATE KEY UPDATE
  `name`=VALUES(`name`), `description`=VALUES(`description`), `tier`=VALUES(`tier`),
  `icon`=VALUES(`icon`), `metric`=VALUES(`metric`), `threshold`=VALUES(`threshold`),
  `order`=VALUES(`order`), `updated_at`=VALUES(`updated_at`);

-- ---------- 3. shop_item：9 件商品（附录 B §8.3；8 框总价 51,000，主题 1 套免费） ----------
INSERT INTO `shop_item`
  (`id`, `section`, `name`, `description`, `price`, `icon`, `order`, `on_shelf`, `is_default_free`,
   `created_at`, `updated_at`)
VALUES
  ('frame_01', 'frame', '嫩芽', '初生的绿色', 1500, 'res://frame_01', 1, 1, 0, @SEED_TS, @SEED_TS),
  ('frame_02', 'frame', '藤蔓', '向上生长', 2500, 'res://frame_02', 2, 1, 0, @SEED_TS, @SEED_TS),
  ('frame_03', 'frame', '风车', '清洁能源', 3500, 'res://frame_03', 3, 1, 0, @SEED_TS, @SEED_TS),
  ('frame_04', 'frame', '星河', '夜空中的光', 4500, 'res://frame_04', 4, 1, 0, @SEED_TS, @SEED_TS),
  ('frame_05', 'frame', '极光', '极地之美', 6000, 'res://frame_05', 5, 1, 0, @SEED_TS, @SEED_TS),
  ('frame_06', 'frame', '墨竹', '坚韧挺拔', 8000, 'res://frame_06', 6, 1, 0, @SEED_TS, @SEED_TS),
  ('frame_07', 'frame', '鎏金', '岁月沉淀', 10000, 'res://frame_07', 7, 1, 0, @SEED_TS, @SEED_TS),
  ('frame_08', 'frame', '年轮', '时间的礼物', 15000, 'res://frame_08', 8, 1, 0, @SEED_TS, @SEED_TS),
  ('theme_default', 'theme', '默认主题（免费）', '绿色系默认外观', 0, 'res://theme_default', 1, 1, 1, @SEED_TS, @SEED_TS)
ON DUPLICATE KEY UPDATE
  `section`=VALUES(`section`), `name`=VALUES(`name`), `description`=VALUES(`description`),
  `price`=VALUES(`price`), `icon`=VALUES(`icon`), `order`=VALUES(`order`),
  `on_shelf`=VALUES(`on_shelf`), `is_default_free`=VALUES(`is_default_free`),
  `updated_at`=VALUES(`updated_at`);

-- ---------- 4. carbon_factor_meta：因子库版本（附录 A §2.5；B32 唯一数值版本号） ----------
INSERT INTO `carbon_factor_meta` (`id`, `version`, `source_updated`, `note`, `created_at`, `updated_at`)
VALUES ('CF-2026.2', 'CF-2026.2', '2026-11-06',
        '因子库版本号唯一来源；30 条因子 + CAR_OWN_FACTOR = 31 项，见 docs/APPENDIX-A-data-factors.md §2.5。服务端只登记版本，不参与碳计算（铁律 2：唯一计算入口是客户端 CarbonService.calculate()）。',
        @SEED_TS, @SEED_TS)
ON DUPLICATE KEY UPDATE `version`=VALUES(`version`), `source_updated`=VALUES(`source_updated`),
  `note`=VALUES(`note`), `updated_at`=VALUES(`updated_at`);

-- ---------- 5. app_config：服务端配置默认值（键值对；后台 /admin/config 可改） ----------
INSERT INTO `app_config` (`id`, `value`, `version`, `fetched_at`, `created_at`, `updated_at`)
VALUES
  -- 每日积分封顶 200：PLAN §9（实入 A = max(0, min(C, 200 − D))）
  ('points_daily_cap', '200', NULL, NULL, @SEED_TS, @SEED_TS),
  -- 商品目录版本：客户端启动拉取 /api/v1/shop/items 后整份覆盖 app_config['shop_items']
  ('shop_items_version', '2026.02.01-1', '2026.02.01-1', @SEED_TS, @SEED_TS, @SEED_TS),
  -- 账号注销保留期 30 天：ADR-0001 决策 ③（云端数据软删除保留 30 天，期内可恢复）
  ('account_purge_retention_days', '30', NULL, NULL, @SEED_TS, @SEED_TS)
ON DUPLICATE KEY UPDATE `value`=VALUES(`value`), `version`=VALUES(`version`), `updated_at`=VALUES(`updated_at`);

-- ---------- 自检（执行完可跑：应为 11 / 8 / 9 / >=3） ----------
-- SELECT (SELECT COUNT(*) FROM goal_def) AS goals,
--        (SELECT COUNT(*) FROM badge_def) AS badges,
--        (SELECT COUNT(*) FROM shop_item) AS items,
--        (SELECT COUNT(*) FROM app_config) AS configs,
--        (SELECT SUM(price) FROM shop_item WHERE section='frame') AS frame_total_price;  -- 期望 51000

