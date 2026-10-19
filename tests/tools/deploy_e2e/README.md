# `tests/tools/deploy_e2e/` · `server/deploy/` 容器化实跑工具

## 1. 解决什么问题

`docs/VERIFICATION.md` 的「未运行清单」里长期挂着一条 **`server/deploy/` 实跑**：仓库里有一套部署实物
（`nginx/carbonboo.conf`、`systemd/*.service|timer`、`backup-mysql.sh`、`migrate.sh`、`README.md`），
但历轮验证只做「读文件 + `bash -n`」的静态检查 —— **没人真起过 nginx、没人真跑过备份与还原**。

本工具把这条补上：**用容器把 deploy 实物真跑一遍**，并把每一项的原始输出落成证据。

跑完能回答的问题：

- 仓库那份 `carbonboo.conf` **字节不改**装进 `nginx:alpine` 能不能过 `nginx -t`、能不能真终止 TLS、能不能反代到应用？
- `HTTP→HTTPS 301`、`/docs` 生产关闭、客户端令牌打 `/admin/*` 403 —— 在**真实 HTTPS 链路**上成立吗？
- 限流 `zone=carbonboo_login` 到底限没限住？超阈值拿到的是 429 还是 503？未超阈值还 200 吗？
- `backup-mysql.sh` 真跑出的 dump 非空吗？**能不能被独立容器导入还原**？逐表行数对得上吗？
- `migrate.sh` 的 `--dry-run` 与真跑有对照吗？两个安全阀（库名含 `test`、无 mysql 客户端）真的拒跑吗？
- 三个 systemd 单元本体有没有语法/指令错误？里面有没有机密？

## 2. 怎么跑

```bash
bash tests/tools/deploy_e2e/run.sh              # 默认跑完自动清理现场
L1_KEEP=1 bash tests/tools/deploy_e2e/run.sh    # 保留现场（/tmp/cbe2e.XXXXXX，含全部原始输出）
```

**退出码**：

| 码 | 含义 |
|---|---|
| `0` | 全部探针通过（`探针：PASS=n FAIL=0`） |
| `1` | 有探针失败（逐条列出 `失败项`） |
| `2` | **环境不可达** —— 未运行，不是通过：无 `docker`、镜像不在本地、端口 `10080/10443` 被占、仓库 deploy 文件缺失 |

本工具**不联网**：镜像必须已在本地（`nginx:alpine` / `python:3.11-slim` / `mysql:8.0`），不会 `docker pull`。
可用环境变量覆盖：`DEPLOY_E2E_HTTP_PORT`（默认 10080）、`DEPLOY_E2E_HTTPS_PORT`（默认 10443）、
`DEPLOY_E2E_DB`（默认 `carbonboo_deploy_e2e`）、`DEPLOY_E2E_DOMAIN`（默认 `api.example.com`）、
`DEPLOY_E2E_MYSQL_CONTAINER`（默认 `carbonboo-mysql`）、`L1_KEEP=1`。

## 3. 依赖

| 依赖 | 用途 | 缺失时 |
|---|---|---|
| `docker`（本机 27.5.1） | 起容器/派生网络/执行 dump 与还原 | 退出码 `2` |
| 本地镜像 `nginx:alpine`、`python:3.11-slim`、`mysql:8.0` | nginx / 应用 / MySQL 客户端 | 退出码 `2` |
| 容器 `carbonboo-mysql`（`127.0.0.1:13307`） | 任务库、dump、还原 | 退出码 `2` |
| 仓库 `server/.venv/lib/python3.11/site-packages` | 应用容器**零安装**跑 FastAPI/uvicorn | 退出码 `2` |
| `openssl`、`curl`（宿主） | 自签证书、探针请求 | 退出码 `2` |

## 4. 覆盖范围（三态，**互不顶替**）

- **【实跑】** 派生网络 + 任务库建表种子、`nginx -t`（仓库原文件）、`nginx -T` 运行态留档、TLS 终止、301、反代、
  `/docs` 关闭、客户端令牌 403、限流 429/503、`backup-mysql.sh` + 真还原（21 表行数一致）、
  `migrate.sh` dry-run/真跑/两个安全阀、收尾清理。
- **【静态验证】** `systemd-analyze verify`（原样 + 派生副本）、三个单元的 ExecStart/加固/重启策略逐条核对、单元内无机密。
- **【未运行】** systemd 单元与 timer 的 enable/start/日志（WSL 无 PID1 systemd）、certbot 真实签发续期（不联网）、
  公网域名与防火墙、mysqldump 大库耗时、生产 MySQL 普通用户凭据。**一条都不算通过**，详见 `REPORT.md §11`。

## 5. 派生清单（改了什么）

与「生产单机」的差异**只有 5 项**（`REPORT.md §1` 逐条给了原因，运行态 diff 留档 `logs/conf.diff`）：

- **S1** `proxy_pass 127.0.0.1:8000` → 应用容器名（5 处，**唯一影响 nginx 配置文本的替换**）
- **S2** uvicorn 监听地址/`forwarded-allow-ips`（容器内需监听 0.0.0.0）
- **S3** 派生 `.env`（`APP_ENV=prod`、容器名 MySQL、任务库名、后台引导账号）
- **S4** `schema.sql`/`seed.sql` 的库名 2 行（**只在管道里替换，仓库文件一字未改**）
- **S5** systemd 单元的 `/opt/carbonboo` 前缀（**仅**用于 `9.6b` 的静态 `verify`，stub 是 `exit 0` 空脚本）

> `§4` 的 `nginx -t` 用的是**仓库原文件**（证书按生产路径挂载、上游保持 `127.0.0.1:8000`）⇒ 原文件本身零替换即通过。

## 6. 产物

默认跑完删除现场；`L1_KEEP=1` 时保留 `${WORK}`（`/tmp/cbe2e.XXXXXX`）：`logs/`（`nginx -T` 原文、配置 diff、
各探针原始响应、`rowcounts.txt`、`systemd_verify_*.log`）、`certs/`、`backups/`、`units/`、`stub/`、
派生 `app.env`/`schema.sql`/`seed.sql`（密钥已打码）。

## 7. 已知坑（都是本轮踩过的）

1. **容器之间只能用「容器名」互访**：`127.0.0.1` 在容器里不是宿主也不是别的容器 ⇒ nginx 必须 `proxy_pass http://<app容器名>:8000`（S1）。
2. **`carbonboo-mysql` 在默认 `bridge` 网络上没有名字可解析**：必须临时 `docker network connect` 到派生网络，收尾 `disconnect` 回 `bridge`
   （本工具是唯一触碰项目容器的地方，**只加网络连接、不动数据**）。
3. **dump 是容器内 `root:600` 写的，宿主读不了** → `gzip -t`/`zcat` 会全部失败并伪装成「备份损坏」。**校验与还原必须放回容器里做**。
4. **`/mnt/c` 是 drvfs 挂载，权限位被放成 0777** ⇒ `systemd-analyze verify` 会刷一堆「marked executable/world-writable」告警，
   与单元内容无关；判据要按**错误类别**归因，而不是看退出码。
5. **`systemd-analyze` 会检查 `ExecStart` 可执行性** ⇒ 生产路径 `/opt/carbonboo` 本机不存在时必然报错，会掩盖真正的问题；
   用 S5 副本把「路径不存在」与「单元本体有错」分开。
6. **不联网时 `docker pull` 直接失败**；镜像缺失要按退出码 `2` 走「环境不可达」，**不能**降级成 PASS。
7. **端口占用要先探测**（`10080`/`10443`）：被占时同样退 `2`，避免把「起不来」记成通过。
8. **限流探针要留「未超阈值」的对照**：只测「被拒」无法区分「限流生效」和「服务本来就坏」。
9. **收尾必须幂等**：`run.sh` 可反复连跑（本轮连跑三次 `EXIT=0`、`PASS=49 FAIL=0`、[PASS] 行名逐条一致）。

## 8. 与「真实云 VM 部署」的差异（别把本工具当生产验收）

| 生产单机 | 本工具 | 影响 |
|---|---|---|
| systemd 拉起 uvicorn | `docker run python:3.11-slim` 直接跑 uvicorn | 「单元本身正确」只做了静态校验（N1） |
| certbot 从 Let's Encrypt 签发 | openssl 自签 | 真实验签/续期未验（N2） |
| 公网域名 + 防火墙 + 备案 | `Host` 头 + 本机端口映射 | 网络层未验（N3） |
| 真实数据量 | 种子级数据（26 KB dump） | 备份耗时/锁表未测（N4） |
| 生产 MySQL 用户 | `.env` 管理员凭据 | 凭据与授权未验（N5） |

## 9. 相关文件

- `REPORT.md` —— 本轮实跑报告（逐项：实测命令 → 原始输出 → 结论 → 三分类）
- `run.sh` —— 工具本体（640 行，退出码 0/1/2）
- `../../server/deploy/README.md` —— 生产部署说明（被测对象的口径来源）
