# server/sql/migrations · 增量迁移

## 用途

`sql/schema.sql` 是**结构基线**（`CREATE TABLE IF NOT EXISTS`，可重复执行），只负责"从零建出一个文档口径的库"；
`sql/migrations/NNN_*.sql` 是**在已有库上做增量**的脚本，用来修基线里的缺陷、或给老库补结构。

## 约定

1. 命名 `NNN_短描述.sql`（三位序号，从 001 开始，按序执行）。
2. **必须幂等**：优先用 `information_schema` 判断现状（`SET @x := (SELECT ...)` + `PREPARE/EXECUTE`），
   不要用 MySQL 8 不支持的 `CREATE INDEX IF NOT EXISTS`，也不要用 `DELIMITER`/存储过程
   （本仓库的 SQL 执行器按分号切分语句，见 `tests/conftest.py::_split_statements`）。
3. **不做破坏性改动**：禁止 `DROP TABLE`、`DROP COLUMN`、`RENAME COLUMN`（附录 B §9 迁移策略：
   删列/改名一律改为"新增列 + 数据迁移 + 旧列置空"）。
4. 每个文件首行用注释写清「改了什么 / 为什么 / 怎么执行」。
5. 改了索引或列之后，**必须**同步 `server/app/models/` 里的 ORM 声明
   （`tests/test_auth.py::compare_with_database` 会逐表逐列逐索引名比对，分叉即红）。

## 执行

```bash
# 单文件
mysql -h127.0.0.1 -uroot -p carbonboo < sql/migrations/001_uq_pr_source_user_id.sql
# 全部未执行的迁移（推荐；会拒绝在库名含 test 的库上跑）
bash deploy/migrate.sh carbonboo
```

测试库由 `tests/conftest.py` 在 `schema.sql` + `seed.sql` 之后**自动按序执行本目录全部迁移**，
所以「基线 + 迁移」这条路径每次跑 L3 都被真实验证（含重复执行的幂等性）。

## 清单

| 序号 | 文件 | 改了什么 | 为什么 |
|---|---|---|---|
| 001 | `001_uq_pr_source_user_id.sql` | `uq_pr_source` 加入 `user_id` 列 | 服务端多账号共库，业务唯一键不含账号会让两个账号的同名目标/同码商品互相顶掉；附录 B §2:142 需同步修正 |
