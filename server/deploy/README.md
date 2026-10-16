# server/deploy · 部署与运维

> 目标形态（ADR-0001）：**境内轻量云 + 备案域名 + TLS**；MySQL 只监听 `127.0.0.1`；
> 公网只开 **SSH / 80 / 443**；密钥只进 `server/.env`（权限 600）；`/admin` 强口令 + 登录限流；
> `/docs` 生产默认关闭（路演前临时开）。

## 0. 组件与端口

| 组件 | 监听 | 说明 |
|---|---|---|
| uvicorn（FastAPI） | `127.0.0.1:8000` | `--workers 2`；连接池口径见下 |
| MySQL 8 | `127.0.0.1:3306` | **不对外**；`max_connections=30` |
| nginx | `0.0.0.0:80/443` | TLS 终止 + 反代 + `/admin` 限流 |
| 定时任务 | — | `mysqldump` 备份 + 30 天超期账号物理清除 |

## 1. 连接池口径（**不要改**）

`AGENTS §7.2`：`--workers 2` 时必须显式 `pool_size=5, max_overflow=5, pool_recycle=1800`。
若用驱动默认的 `pool_size=5, max_overflow=10`：

```
2 × (5 + 10) = 30  ← 正好打满 MySQL max_connections=30，第 31 个连接直接被拒
2 × (5 +  5) = 20  ← 留 10 个给管理端 / 运维 / mysqldump
```

`app/core/database.py` 已写死这三个值并从 `Settings` 读取；`tests/test_auth.py` 有断言把乘积 < 30 钉住。

## 2. 首次部署

```bash
# ① 代码与依赖
cd /opt && git clone <repo> carbonboo && cd carbonboo/server
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

# ② 密钥（只进 .env，权限 600；代码内没有任何默认密钥）
cp .env.example .env
python3 - <<'PY'
import secrets
print("JWT_SECRET=" + secrets.token_urlsafe(48))
print("ADMIN_JWT_SECRET=" + secrets.token_urlsafe(48))
PY
# 把两把不同的密钥写进 .env，并填 MySQL 连接信息（应用账号最小权限）
chmod 600 .env

# ③ 数据库（基线 + 种子 + 增量迁移）
mysql -h127.0.0.1 -uroot -p < sql/schema.sql     # 21 张表（幂等）
mysql -h127.0.0.1 -uroot -p carbonboo < sql/seed.sql   # 静态字典（幂等）
bash deploy/migrate.sh carbonboo                  # 增量迁移（幂等；拒绝在 *test* 库上执行）

# ④ systemd
install -m 644 deploy/systemd/carbonboo-server.service /etc/systemd/system/
install -m 644 deploy/systemd/carbonboo-purge.service  /etc/systemd/system/
install -m 644 deploy/systemd/carbonboo-purge.timer    /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now carbonboo-server carbonboo-purge.timer

# ⑤ nginx + TLS
install -m 644 deploy/nginx/carbonboo.conf /etc/nginx/conf.d/
certbot --nginx -d api.example.com          # 域名待定（ADR-0001 唯一未决项④）
nginx -t && systemctl reload nginx

# ⑥ 防火墙：只开 SSH/80/443
ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw enable
```

> **服务端地址禁止硬编码**（AGENTS §6）：客户端经设置页 / 构建期常量注入 `server_base_url`，
> 带 3 秒超时与失败降级（取价失败 → 整份丢弃 → 内置默认价）。

## 3. 日常运维

```bash
systemctl status carbonboo-server                 # 是否活着
curl -s https://api.example.com/api/v1/health     # {"ok":true,"version":"1.0.0","time":...}
bash deploy/backup-mysql.sh                       # 手动备份（cron 里每天 03:17）
.venv/bin/python -m app.services.auth_provider    # 超期账号物理清除（timer 每天跑）
journalctl -u carbonboo-server -n 200 --no-pager  # 看同步/账号日志
```

## 4. 变更与回滚

* 结构变更：**只加表、只加列**（`ALTER TABLE ... ADD COLUMN` 必须带默认值），禁止 `DROP`/改名（附录 B §9）；
  新迁移放进 `sql/migrations/NNN_*.sql`，命名与幂等要求见 `sql/migrations/README.md`。
* 迁移脚本一旦上线**不再修改**，要改就新增下一个序号。
* 回滚：`git checkout <上一个 tag>` + `systemctl restart carbonboo-server`；结构不回滚（只加不删即可）。
* 每次发布后跑一遍：`.venv/bin/python -m pytest tests/ -q`（L3 打真实 MySQL，**不要**在生产库上跑；
  测试库名必须含 `test`，`tests/conftest.py` 会拒绝其它库名）。

## 5. 本目录文件

| 文件 | 用途 |
|---|---|
| `migrate.sh` | 按序执行 `sql/migrations/*.sql`（幂等；`--dry-run` 只列不跑；拒绝 `*test*` 库） |
| `backup-mysql.sh` | `mysqldump` 全库备份 + 保留 14 天 + 权限 600 |
| `systemd/carbonboo-server.service` | uvicorn `--workers 2` 常驻服务 |
| `systemd/carbonboo-purge.{service,timer}` | 每天跑一次超期账号物理清除（ADR-0001 决策③） |
| `nginx/carbonboo.conf` | TLS + 反代 + `/admin` 登录限流 + 请求体上限 |
