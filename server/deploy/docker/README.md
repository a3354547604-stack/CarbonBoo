# server/deploy/docker · 容器部署（本机生产环境实际采用）

> **目标形态**：单台只有 IP、没有域名与 TLS 的云主机（ADR-0001 未决项④ 未定），
> 用 Docker Compose 跑「nginx + FastAPI + MySQL 8」三件套。
> 口径与宿主机版 `server/deploy/README.md` 完全一致：公网只开 SSH/80/443；后端与数据库都不对外；
> 密钥只进 `.env`（600）；`/admin` 强口令 + 登录限流；`/docs` 生产默认关闭。
> systemd 变体（`deploy/systemd/`）保留备用，二者**不要同时启用**。

## 0. 本机部署事实（2026-11-06 实测）

| 项 | 值 |
|---|---|
| 主机 | `123.206.99.28`（腾讯云 CVM，Debian 12 bookworm，2 vCPU / 2 GB + 2 GB swapfile） |
| 代码位置 | `/opt/carbonboo/server/`（`server/` 目录整份，不含 `.venv` / `.env`） |
| compose 项目 | `carbonboo`（文件 `/opt/carbonboo/server/deploy/docker/docker-compose.yml`） |
| 访问入口 | `http://123.206.99.28/` → nginx:80 → server:8000 |
| 备份目录 | `/opt/carbonboo/backups/`（cron `20 3 * * *`，保留 14 天） |
| 数据卷 | `carbonboo-mysql-data`（MySQL 数据）、`carbonboo-admin-uploads`（后台商城图标） |

三个容器（`docker compose ps`）：

| 容器 | 镜像 | 端口 | 内存上限 |
|---|---|---|---|
| `carbonboo-nginx` | `nginx:alpine` | `0.0.0.0:80`（唯一对外） | 96 MB |
| `carbonboo-server` | `carbonboo-server:CF-2026.2`（本目录 Dockerfile 构建） | 仅内网 `8000` | 640 MB |
| `carbonboo-mysql` | `mysql:8.0` | 仅内网 `3306` | 768 MB |

实测占用：server ≈ 168 MB、mysql ≈ 172 MB、nginx ≈ 4 MB。

## 1. 首次部署（从零到可用）

```bash
# ① 传代码（本机 WSL 侧；远端没有 rsync，用 tar 管道）
tar -czf - --exclude='./.venv' --exclude='./.pytest_cache' --exclude='*/__pycache__' \
    --exclude='./.env' -C server . \
  | ssh root@123.206.99.28 'mkdir -p /opt/carbonboo/server && tar -xzf - -C /opt/carbonboo/server'

# ② swap（2 GB 内存 + MySQL + 构建，没有 swap 时构建容易 OOM）
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab

# ③ 密钥（在服务器上执行）
cd /opt/carbonboo/server/deploy/docker
cp .env.example .env
JWT=$(openssl rand -hex 32); ADMIN=$(openssl rand -hex 32)
sed -i -e "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$(openssl rand -hex 16)|" \
       -e "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)|" \
       -e "s|^JWT_SECRET=.*|JWT_SECRET=${JWT}|" \
       -e "s|^ADMIN_JWT_SECRET=.*|ADMIN_JWT_SECRET=${ADMIN}|" .env
chmod 600 .env          # 两把 JWT 密钥必须不同且 >=32 位，否则启动即 ValueError

# ④ 构建 + 启动（首次会自动建表 + 灌种子，见 §2）
docker compose build
docker compose up -d
docker compose ps       # 三个容器都要 healthy / Up

# ⑤ 定时备份
bash backup.sh 14       # 先手动跑一次确认能落盘
( crontab -l 2>/dev/null; echo "20 3 * * * /opt/carbonboo/server/deploy/docker/backup.sh 14 >> /var/log/carbonboo-backup.log 2>&1" ) | crontab -
```

> **只对公网开 80**：`3306` / `8000` 都不映射到宿主，等价于宿主机版的「只监听 127.0.0.1」。
> 云厂商安全组另外只放行 22 / 80（配好证书后加 443）。

## 2. 建表与种子（`sql/` 挂载进 initdb 目录）

`docker-compose.yml` 把 `server/sql` 只读挂到容器的 `/docker-entrypoint-initdb.d`，
MySQL 官方 entrypoint **仅在数据卷为空时**按文件名顺序执行 `*.sql` —— 于是：

- `schema.sql`（21 张表，幂等）先跑，`seed.sql`（静态字典，幂等）后跑；
- 已有数据卷**不会**再跑一遍；改结构必须走 `sql/migrations/`（见下）。

> ⚠ 路径基准是 compose 文件所在目录（`server/deploy/docker/`），`sql` 在 `server/sql`，
> 所以挂载必须写 `../../sql`。写成 `../sql` 会得到一个**空目录**：MySQL 正常启动、
> 但库里 0 张表，症状是 `/api/v1/health` 200 而 `/api/v1/shop/items` 500（本项目踩过一次）。

首次初始化实测结果（2026-11-06）：

```
表数量 21：admin_op_log admin_user app_config badge_def carbon_factor_meta carbon_include
          carbon_record device_info goal_def point_daily_stat point_record science_progress
          server_user share_record shop_item sync_log user_appearance user_badge
          user_goal user_profile user_purchase
种子：carbon_factor_meta 1 · shop_item 9 · goal_def 11 · badge_def 8
      （carbon_include / science_progress 等业务表初始为空，属正常）
字符集：utf8mb4 / utf8mb4_0900_ai_ci · max_connections=30 · innodb_buffer_pool=256M
```

**已有库的增量迁移**（容器没有宿主客户端，走容器内的 mysql）：

```bash
docker exec -i carbonboo-mysql sh -c 'MYSQL_PWD="$0" mysql -uroot carbonboo' "$(sed -n 's/^MYSQL_ROOT_PASSWORD=//p' .env | tail -1)" \
  < /opt/carbonboo/server/sql/migrations/001_uq_pr_source_user_id.sql
```

## 3. 首次管理员与后台

`admin_user` 表空时，`ADMIN_BOOTSTRAP_USERNAME` / `ADMIN_BOOTSTRAP_PASSWORD`（`.env`）可创建首个管理员：

```bash
curl -i -c /tmp/ck -X POST http://127.0.0.1/admin/login \
  --data-urlencode "username=$ADMIN_BOOTSTRAP_USERNAME" \
  --data-urlencode "password=$ADMIN_BOOTSTRAP_PASSWORD"
# 期望：HTTP/1.1 303 See Other + set-cookie: carbonboo_admin_token=...
```

后台页面：`/admin`（总览）、`/admin/items`（商品与取价）、`/admin/orders`、`/admin/users`、
`/admin/logs`（审计）、`/admin/config`（系统配置下发）、`/admin/password`（改密）。

- 引导完成后 `admin_user` 非空，那两条环境变量**自动失效**，建议在 `.env` 里清空后 `docker compose up -d`。
- 忘记口令的唯一正规找回：`docker exec -it carbonboo-server python -m admin_web.cli create-admin --username <名字> --reset`。
- 当前只有 HTTP，故 `.env` 里显式 `ADMIN_COOKIE_SECURE=false`；配好 TLS 后必须改回 `true`，
  否则会话 Cookie 会在明网传输（prod 默认值就是 true，这里是有意降级）。

## 4. 日常运维

```bash
cd /opt/carbonboo/server/deploy/docker

docker compose ps                        # 状态
docker compose logs -f --tail 100 server # 应用日志（uvicorn access/error）
docker compose logs -f --tail 50 mysql   # 数据库日志
docker stats --no-stream                 # 内存/CPU

curl -s http://127.0.0.1/api/v1/health   # {"ok":true,"version":"1.0.0","time":...}
curl -s http://127.0.0.1/api/v1/config   # 配置下发（免令牌）
bash backup.sh 14                        # 手动备份 → /opt/carbonboo/backups/

docker compose restart server            # 只重启应用
docker compose down && docker compose up -d   # 整栈重启（数据卷保留）
```

**发布新版本**（代码有改动时）：

```bash
# 本机：改完 → 推到 origin/main
# 服务器：
cd /opt/carbonboo/server
# ① 覆盖代码（本机用 tar 管道，或服务器 git pull）
# ② 重建 + 滚动重启
cd deploy/docker && docker compose build && docker compose up -d
```

**恢复备份**：

```bash
gunzip -c /opt/carbonboo/backups/carbonboo-YYYYmmdd-HHmm.sql.gz \
  | docker exec -i -e MYSQL_PWD="$(sed -n 's/^MYSQL_ROOT_PASSWORD=//p' .env | tail -1)" \
      carbonboo-mysql mysql -uroot carbonboo
```

## 5. 加 TLS（有域名之后）

1. 域名 A 记录指向 `123.206.99.28`；
2. 用 `certbot certonly --standalone -d api.example.com` 取证书（先停 nginx 或改用 webroot）；
3. 把证书挂进 `carbonboo-nginx`（`./nginx/certs:/etc/nginx/certs:ro`），在
   `nginx/carbonboo.conf` 里加 443 server 段（照抄 `deploy/nginx/carbonboo.conf` 的 SSL 段）；
4. compose 打开 `443:443`，`.env` 改 `ADMIN_COOKIE_SECURE=true`，`docker compose up -d`；
5. 云安全组放行 443。

## 6. 与宿主机（systemd）变体的取舍

| 维度 | 容器版（本机采用） | systemd 版 |
|---|---|---|
| 隔离 | 三件套各自容器，端口不落到宿主 | 进程跑在宿主，MySQL 与 uvicorn 绑 127.0.0.1 |
| 依赖 | 宿主只需 docker；Python 依赖锁在镜像里 | 宿主需 python3.11+ / venv / mysql 客户端 |
| 迁移 | `sql/migrations/` + `docker exec mysql` | `deploy/migrate.sh`（宿主 mysql 客户端） |
| 备份 | `docker exec mysqldump`（本目录 `backup.sh`） | `deploy/backup-mysql.sh` |
| 超期账号清除 | 尚未接入（timer 版在 `deploy/systemd/carbonboo-purge.*`） | `carbonboo-purge.timer` 每天跑 |

> 容器版**未接** `carbonboo-purge` 定时器：注销账号的物理清除（保留期 30 天）目前需手动跑
> `docker exec carbonboo-server python -m app.services.auth_provider`（`purge_expired_accounts()` 的运维入口，
> 见 `app/services/auth_provider.py` 文件末 `__main__`）。要自动化就照 backup 的办法加一条 cron：
> `30 3 * * * docker exec carbonboo-server python -m app.services.auth_provider >> /var/log/carbonboo-purge.log 2>&1`
