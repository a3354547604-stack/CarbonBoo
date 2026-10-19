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

---

## 10. t75 追加：两条「未运行项」的关闭（`/admin` 经 nginx 的端到端 + systemd 的真启动）

> 本节只做**追加**，§1–§9 的既有内容一个字未改。背景：t56 交付时把这两条如实列为「未运行」
> （N1 systemd 从未启动、以及 `/admin` 经 nginx 的完整路径未跑），t75 把它们补上。

### 10.1 怎么跑

```bash
# 一条命令跑全部（新增的 7.5b / 7.6d / 9.8 阶段自动包含在内）
bash tests/tools/deploy_e2e/run.sh; echo "DEPLOY_EXIT=$?"

# 只跑 systemd 真启动（自包含：自己起容器、自己建任务库、跑完自己清）
bash tests/tools/deploy_e2e/run_systemd.sh; echo "SD_EXIT=$?"
L1_KEEP=1 bash tests/tools/deploy_e2e/run_systemd.sh   # 保留 §0–§6 全部原始输出
```

退出码沿用既有约定：**0 = 全过 / 1 = 有断言失败 / 2 = 环境不可达**（`run_systemd.sh` 退 2 时
`run.sh` §9.8 会把它记成「未运行（ENV）」，**不算通过**）。

### 10.2 `run_systemd.sh` 做什么（24 条断言，6 步）

| 步 | 做什么 | 代表断言 |
|---|---|---|
| §1 | 起 **PID1 = systemd** 的容器 | 1.1 `is-system-running=running`、1.2 `/proc/1/comm=systemd` |
| §2 | 容器内装 python3.11 / 建 `carbonboo` 用户 / 铺 `/opt/carbonboo/server` / 建 venv / 派生 `.env` / 建任务库 | 2.1–2.6 |
| §3 | 三个单元 `install -m 644` 进 `/etc/systemd/system/` 并逐文件 sha256 比对 + `daemon-reload` | 3.1、3.2 |
| §4 | `systemctl start carbonboo-server` → `is-active` + `MainPID`/`NRestarts` + `status`/`journalctl` + **容器内真 HTTP 探活** + `systemctl show` 生效值 | 4.1–4.6 |
| §5 | `systemctl start carbonboo-purge.timer` → `list-timers` → **用容器内临时副本真触发一次 purge** | 5.1–5.6 |
| §6 | 收尾（停/禁用单元、删容器、删任务库、删/留现场） | — |

容器配方（本机实测；**只加 `--privileged` + cgroup 只读会立刻退出，ExitCode=255 且无日志**）：

```bash
docker run -d --name carbonboo-deploy-sd-e2e --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp --network host \
  -v <repo>/server:/repo/server:ro -v <repo>/server/deploy/systemd:/repo/systemd:ro \
  jrei/systemd-debian:12
```

派生清单（与真机的差异，脚本逐条打印）：

- **D1** `/opt/carbonboo/server` 是仓库 `server/` 的 tar 副本；建 venv 前先 `rm -rf` 残留 `.venv`。
- **D2** 依赖优先走 `pip install -r requirements.txt -i https://mirrors.aliyun.com/pypi/simple/`（实测可用）；
  不通时回退「复制只读挂载里宿主 venv 的 site-packages + 手写与 pip 同形的 uvicorn 控制台脚本」，来源会标成 `copy`。
- **D3** `/opt/carbonboo/server/.env` 由仓库 `.env` 派生，**只换 `MYSQL_DB`**（指向任务库，不碰生产库）。
- **D4** 触发 purge 用容器内临时副本 `/etc/systemd/system/carbonboo-purge-e2e.timer`
  （`OnCalendar=*:*:00` + `RandomizedDelaySec=0s`）；仓库文件与它在 `/etc` 的安装副本 sha256 都不变。
- **D5** 探活改在**容器内**做：Docker Desktop 的 `--network host` 落在 docker-desktop VM 的 netns，
  宿主 WSL 的 `127.0.0.1:8000` 看不到（宿主 curl 实测 `000`）；容器内 `127.0.0.1:8000` 与真机
  「同机 nginx → 127.0.0.1:8000」同义。

### 10.3 `/admin` 经 nginx 的端到端（`run.sh` §7.5b + §7.6d，12 条断言）

在 t56 既有拓扑上（§5 应用容器 + §6 nginx 容器 + §3 自签证书 + S3 的 `ADMIN_BOOTSTRAP_*`），
用**等价真 HTTP 客户端**（curl + `--cacert` + `--resolve` + Cookie 罐）走
`https://api.example.com:10443/admin/...`：登录页（HTML）→ 错误口令 401 → 正确口令 200 + `adminToken` + `Set-Cookie`
→ 用户列表（含 7.5 真实注册的 `deploy_e2e_1`）→ 数据总览 → 配置读/写/回显（`dailyCap` 200→250）→
图标上传（`image/png` 原始字节）+ 取回（`image/png`）→ 改密（旧口令 401 / 新口令 200）→ 登出（会话失效）
→ 客户端令牌经 nginx 打 `/admin/{users,overview,config,icons/*}` **全部 403** →
`/admin/login` 12 次（每次换用户名）**12 次 429**（证明 nginx 自己那层限流没被旁路）。

**真浏览器图层（Edge + CDP）本轮未跑** —— 它由同仓 `tests/tools/admin_e2e/` 覆盖，属本轮 out of scope。

### 10.4 本轮新增/变化的派生（t56 的 S1–S5 之后）

- **S6**：应用容器多一个**可写**挂载 `${WORK}/icons → /app/admin_web/static/uploads/icons`。
  原因：仓库是**只读**挂载（保证「不改仓库一个字」），而图标上传要落盘；真机上
  `/opt/carbonboo/server` 本身可写（单元里 `ReadWritePaths=/opt/carbonboo/server`）。不给这个挂载时
  7.5b.7 会 500（`OSError: [Errno 30] Read-only file system: '.../frame_01-*.png.part'`）。
- **9.5 安全阀② 的容器换成 `${PY_IMAGE}`（python:3.11-slim）**：原实现用 `alpine:3.20` + `apk add bash`，
  拉不到 Alpine 源时变成 `rc=127` → 门禁假红（实测复现）。新镜像**本来就有 bash、且没有 mysql 客户端**，
  语义完全相同（仍是「无 mysql 客户端 ⇒ migrate.sh 必须 exit 3」），但不再依赖网络。
- **§11「未运行清单」的 N1 改写**：systemd 真启动已由 9.8 关闭；仍列为未运行的是「真云 VM 上的
  开机自启持久化（跨重启的 enable 状态）」与 `systemd-analyze security` 评分。

### 10.5 纠正 t56 的一条前提（环境变了/当时未测准）

t56 记「WSL 无 PID1 systemd」。本轮实测：`ps -p 1 -o comm=` → **systemd**、
`systemctl is-system-running` → **running**、`systemctl --version` → `systemd 259 (259.5-0ubuntu3.4)`。
之所以仍然用容器做真启动，原因是**没有 root**（`sudo -n true` → `sudo: interactive authentication is required`），
装不了宿主 `/etc/systemd/system`。

### 10.6 覆盖 / 不覆盖（t75 增补）

| 项目 | 本轮 | 不覆盖 |
|---|---|---|
| `/admin` 经 nginx | 真 TLS + 真 nginx + 真应用 + Cookie 会话全链路（12 条） | 真浏览器渲染/点击/截图（→ `admin_e2e`）、certbot 真签发、公网 DNS/防火墙 |
| systemd 单元 | PID1=systemd 容器内 enable/start/status/journalctl/list-timers + 真触发 purge（24 条） | 真云 VM 的开机自启持久化、`systemd-analyze security` 评分、SELinux/AppArmor 交互 |

### 10.7 已知坑（t75 新增）

1. **`/opt/carbonboo` 属主必须是 `carbonboo`**：单元 `User=carbonboo` 而目录是 root 且不可穿越时，
   systemd 报 `Failed to execute …: Permission denied`（`status=203/EXEC`）并 `Restart=always` 无限重启；
   此时 `systemctl is-active` 在自动重启窗口里**仍可能显示 active** ⇒ 判活必须同时钉 `MainPID≠0` 与 `NRestarts≤1`。
2. **timer 的 `RandomizedDelaySec=600` 会盖住 `OnCalendar`**：只把 `OnCalendar` 改成每分钟、等 90s 是等不到的
   （实测），临时副本必须同时把随机延迟归零。
3. **只读挂载 + 需要写盘的功能（图标上传）会 500**：`Errno 30` 直接指向只读文件系统；要么给可写挂载（S6），
   要么如实记为「该功能在本拓扑下未验」。
4. **最小 Debian 镜像连 `tar` 都没有**：`tar` 管道铺目录会静默失败（表现为「布局不完整」），
   装 python 时一并装 `tar ca-certificates`。
5. **`--network host` 在 Docker Desktop 上不是宿主的 netns**：容器内 `127.0.0.1:8000` 宿主看不到，
   探针要放容器内做。

## 11. t75 收尾修订（append-only，§1–§10 原文未改）

### 11.1 预备镜像：让 systemd 真启动不再依赖容器内 `apt`

`jrei/systemd-debian:12` 里**连 `python3` 和 `tar` 都没有**，原实现靠容器内 `apt-get install` 现装。实测出现过一次

```
E: Failed to fetch http://deb.debian.org/debian-security/pool/updates/main/p/python3.11/python3.11-venv_3.11.2-6+deb12u9_amd64.deb
   502  Bad Gateway
ENV-FAIL: 容器内 apt-get install python3 python3-venv tar ca-certificates 失败
```

⇒ `run_systemd.sh` 只能退 `2`（环境不可达），总门禁的 9.8 项随之变红（**不是**单元有问题）。现在：

- 默认用**派生镜像** `carbonboo-systemd-e2e:12`：`FROM jrei/systemd-debian:12` + 一步
  `apt-get install python3 python3-venv tar ca-certificates`（Debian 源换 `mirrors.aliyun.com`），**只建一次**；
- 镜像缺失时脚本自己 `docker build`（唯一联网处），失败则回退上游镜像并由**容器内 apt + 三次重试**兜底；
- 复跑日志里会打印 `NOTE: 镜像 carbonboo-systemd-e2e:12 就绪（prepared=1）` 与
  `NOTE: 容器内已具备 python3/tar（预备镜像，未联网安装）`。

可用 `DEPLOY_E2E_SD_PREPARED_IMAGE` / `DEPLOY_E2E_SD_IMAGE` / `DEPLOY_E2E_SD_APT_MIRROR` 覆盖这三处默认值。

### 11.2 §9.5 安全阀②的容器换成 `python:3.11-slim`

原实现用 `alpine:3.20` + `apk add bash`（要联网；拉不到源时变 `rc=127` ⇒ 门禁**假红**）。
现改用本地已有的 `${PY_IMAGE}`（`python:3.11-slim`：自带 `bash`、**没有** mysql/mariadb 客户端），
断言不变（仍要求 `exit 3`）。手工复跑原文：

```
STOP: 本机没有 mysql 客户端，无法执行迁移。
建议: 在目标机安装 mysql-client；或改用 .venv/bin/python 走 tests/conftest.py 的同一套执行器。
RC=3
```

### 11.3 未运行清单 N1 的改写

systemd 真启动已由 §9.8 关闭（24 条断言）。`run.sh` §11 的 N1 现在写的是**仍未运行**的部分：
真云 VM 上的开机自启持久化（跨重启的 `enable` 状态）与 `systemd-analyze security` 评分。

### 11.4 本机环境的一条纠正

**本机（WSL）的 PID 1 就是 systemd**：`ps -p 1 -o comm=` → `systemd`、`systemctl is-system-running` → `running`、
`systemd --version` → 259。t56 当时「WSL 内无 PID1 systemd」的前提已不成立。但本机 `sudo` 需**交互认证**
（`sudo: interactive authentication is required`，即无 root），所以真启动没有装到宿主
`/etc/systemd/system`，而是放进 PID1=systemd 的容器里做（等效、可清理、不污染宿主）。

### 11.5 本轮总门禁结果

`bash tests/tools/deploy_e2e/run.sh` → **`PASS=62 FAIL=0`、`DEPLOY_EXIT=0`**
（t56 的 49 条 + `/admin` 12 条 + systemd 1 条汇总；systemd 子脚本自身 24 条逐条打印）。
收尾核对：`docker ps -a` 只剩共享 `carbonboo-mysql`（未停/未删），无 carbonboo 派生网络与任务库残留。
