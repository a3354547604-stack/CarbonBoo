-- ============================================================================
-- 迁移 001 · 把 point_record 的业务唯一键改成按 user_id 隔离
--
-- 改了什么
--   uq_pr_source(source_type, source_id, flow_kind)
--     → uq_pr_source(user_id, source_type, source_id, flow_kind)
--
-- 为什么必须改（t5 复核发现，附录 B §2:142 现文缺 user_id）
--   服务端是**多账号共库**，而业务唯一键的取值口径本身不含账号：
--     goal           → '<goalId>:<periodKey>'     （附录 B §2:136）
--     shop_item      → '<shop_item.id>'
--     carbon_record  → '<carbon_record.id>#<revision>'
--   `source_id` 里没有账号维度，于是两个账号同一天达成同一个目标（例如都拿到 S1:D:2026-11-06）
--   会得到完全相同的 (source_type, source_id, flow_kind)：
--     · 后入账的那个账号被唯一索引挡下，**合法积分流水丢失**；
--     · 代码侧只能把它识别成「撞了别人的行」并响亮拒绝（见 services/sync_service._diagnose_ignored），
--       而正确的行为是各行其是。
--   同一处缺陷在客户端 SQLite 上同样存在（`ClientSchema` 的 uq_pr_source；本机库同时容纳
--   local-guest / demo-user / 账号 userId 三种 user_id），需文档侧同步修正（见 t5 报告）。
--
-- 幂等：靠 information_schema 判断索引现状，可重复执行；不存在索引时直接建，已含 user_id 时什么也不做。
-- 执行：mysql -h127.0.0.1 -uroot -p carbonboo < sql/migrations/001_uq_pr_source_user_id.sql
--      （或统一走 deploy/migrate.sh）
-- ============================================================================

SET @pr_index_exists := (
  SELECT COUNT(DISTINCT index_name) FROM information_schema.statistics
   WHERE table_schema = DATABASE() AND table_name = 'point_record' AND index_name = 'uq_pr_source'
);

SET @pr_index_has_user := (
  SELECT COUNT(*) FROM information_schema.statistics
   WHERE table_schema = DATABASE() AND table_name = 'point_record'
     AND index_name = 'uq_pr_source' AND column_name = 'user_id'
);

SET @pr_sql := CASE
  WHEN @pr_index_exists = 0 THEN
    'CREATE UNIQUE INDEX uq_pr_source ON point_record (user_id, source_type, source_id, flow_kind)'
  WHEN @pr_index_has_user = 0 THEN
    'ALTER TABLE point_record DROP INDEX uq_pr_source, ADD UNIQUE KEY uq_pr_source (user_id, source_type, source_id, flow_kind)'
  ELSE 'SELECT 1'
END;

PREPARE pr_stmt FROM @pr_sql;
EXECUTE pr_stmt;
DEALLOCATE PREPARE pr_stmt;
