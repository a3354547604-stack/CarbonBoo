# `server/deploy/` 容器化实跑报告（t56）

> 本文件是**实跑记录**，不是设计文档。每一项都写清：**实测命令 → 原始输出 → 结论 → 分类**。
> 分类只有三种：**【实跑】**（真起了进程/容器并观测到行为）、**【静态验证】**（只读文件或只做语法/内容校验）、**【未运行】**（没跑，**一条都不算通过**）。

## 0. 基准与复现

| 项 | 值 |
|---|---|
| 基准 HEAD | `72d37f1e67e8bf320fb4d0c9bb6c826ef0fc70b2`（`git rev-parse HEAD` 原始输出） |
| `git ls-remote origin main` | `72d37f1e67e8bf320fb4d0c9bb6c826ef0fc70b2	refs/heads/main`（同值） |
| 复现命令 | `bash tests/tools/deploy_e2e/run.sh` |
| 退出码 | `0` = 全部探针通过；`1` = 有探针失败；`2` = 环境不可达（无 docker / 缺镜像 / 端口占用 / 仓库文件缺失） |
| 保留现场 | `L1_KEEP=1 bash tests/tools/deploy_e2e/run.sh`（现场目录 `/tmp/cbe2e.XXXXXX`，含 `nginx -T` 原文、证书、dump、日志） |
| 本工具行数 | `run.sh` 640 行 |

被测文件 sha256（开工时现场 `sha256sum`）：

```
f1edf4f89536869e20c6fae727b9825edc0794d2127a3acd1c597a9276722c6e  server/deploy/nginx/carbonboo.conf
13957d9abfee3f30664707dea7af6452375ef12c3cf607bc5aacee7cf7e17059  server/deploy/backup-mysql.sh
3a8f962aaac8611bd69615c61ef1518b19d6ef6157172809f1037f1f311f699b  server/deploy/migrate.sh
156714a9525a34908edeecc4832eb82ae249d94ee7cc10de0c36bbb1df75098b  server/deploy/systemd/carbonboo-server.service
8262d5473f3c5918a45fd6245a7f430379998169de83454d7239588d9d36d778  server/deploy/systemd/carbonboo-purge.service
f0f5465b2370fb4d7dcaffea90d7b071699e47d5fe62c0ef23c6e9a01eb2a0cf  server/deploy/systemd/carbonboo-purge.timer
30b537360c74eb401cb89f4c3c0af45bc2dd0adf3dadc97568fb7eb29b4dab7e  server/sql/schema.sql
c7a535526a3f3211e56a1c2fb07c97ecc560f18de2174a3a7971bdfdea43c6fc  server/sql/seed.sql
```

**结果**：`探针：PASS=49 FAIL=0`，`RESULT: PASS`，进程退出码 `0`；连跑三次均为 `EXIT=0`（见 §11）。

---

## 1. 派生清单：改了什么、为什么（**【实跑】**）

容器拓扑与「生产单机」的差异**只有**下面五项，逐条列出（`run.sh` 启动时打印，运行文件与仓库文件的 diff 留档在 `logs/conf.diff`）：

| 编号 | 替换 | 原因 |
|---|---|---|
| **S1** | `proxy_pass http://127.0.0.1:8000` → `http://carbonboo-deploy-e2e-app:8000`（5 处） | nginx 与应用在不同容器里，容器内 `127.0.0.1` 不是对方；**只改上游地址，不改语义** |
| **S2** | uvicorn `--host 127.0.0.1` → `0.0.0.0`；`--forwarded-allow-ips=127.0.0.1` → `*` | 容器内需监听所有接口才能被同网络容器访问；生产单机上这两个参数就是 `127.0.0.1`（`server.service` 原文如此） |
| **S3** | 派生 `.env`（不改仓库 `.env`）：`APP_ENV=prod`、`MYSQL_HOST=carbonboo-mysql`、`MYSQL_PORT=3306`、`MYSQL_DB=carbonboo_deploy_e2e`、`ADMIN_BOOTSTRAP_USERNAME/PASSWORD` | ① 要验「生产关 `/docs`」必须 `APP_ENV=prod`；② 容器按服务名访问 MySQL；③ 不碰生产库 `carbonboo`；④ 后台需一个引导管理员（口令只存在于运行期环境变量与派生文件，**未入库**） |
| **S4** | `sql/schema.sql` / `sql/seed.sql` 的库名 `carbonboo` → `carbonboo_deploy_e2e`（各 1 处：`CREATE DATABASE` 与 `USE`） | 仓库原生脚本写死生产库名；**只在管道里替换这 2 行**，仓库文件一字未改（`git status` 为空） |
| **S5** | systemd 单元的 `/opt/carbonboo` 前缀 → `${WORK}/stub/opt/carbonboo`（仅用于 `9.6b` 的 `systemd-analyze verify`，每单元一份副本，`mode 644`） | 生产安装路径本机不存在，`systemd-analyze` 的可执行性检查必然报错，会掩盖「单元本体是否有语法/指令错误」。stub 是一个 `exit 0` 的空脚本，**只**为了让可执行性检查通过 |

**关于 S1 的证明**（不是「我改了配置」而是「我改的只有上游地址」）：

```
  S1 的完整 diff（仓库文件 vs 运行文件）保存在 /tmp/cbe2e.XXXXXX/logs/conf.diff
      该 diff 的变更行数 = 10（应等于 5 的一倍：每处一行替换）
```

**【实跑】结论**：替换共 5 类，其中只有 S1 影响 nginx 配置文本（5 行），S2/S3 是启动参数与环境，S4 是 SQL 管道，S5 只服务于静态检查。

---

## 2. 派生网络 + 任务专属库（**【实跑】**）

**命令**（`run.sh` 内部）：

```bash
docker network create carbonboo-deploy-e2e-net
docker network connect carbonboo-deploy-e2e-net carbonboo-mysql     # 收尾 disconnect
docker run --rm -i -e MYSQL_PWD=... mysql:8.0 mysql -h carbonboo-mysql -uroot < schema.derived.sql
```

**原始输出**：

```
  carbonboo-mysql 已临时加入 carbonboo-deploy-e2e-net（收尾 disconnect；这是唯一一处触碰项目容器的动作，只加不减数据）
  PASS 2.1 导入 schema.sql（派生副本，21 张表）
  PASS 2.2 导入 seed.sql（静态字典）
  PASS 2.3 任务库表数 = 21
  PASS 2.4 种子生效（shop_item 行数 = 9）
```

**【实跑】结论**：任务专属库 `carbonboo_deploy_e2e` 建成，21 张表与种子到位；项目容器 `carbonboo-mysql` 只被临时接入派生网络，**未改其数据**，收尾已恢复 `bridge`。

---

## 3. TLS 证书：openssl 现场签发（**【实跑】**）

**命令**：容器内 `openssl req -x509 -newkey rsa:2048 ... -addext "subjectAltName=DNS:api.example.com,DNS:localhost,IP:127.0.0.1"`

**原始输出**：

```
  PASS 3.1 openssl 签发成功（fullchain.pem + privkey.pem）
    subject=C=CN, O=CarbonBoo Deploy E2E, CN=api.example.com
    issuer=C=CN, O=CarbonBoo Deploy E2E, CN=api.example.com
    notBefore=Oct 19 02:50:38 2026 GMT
    notAfter=Nov 18 02:50:38 2026 GMT
    X509v3 Subject Alternative Name:
        DNS:api.example.com, DNS:localhost, IP Address:127.0.0.1
  PASS 3.2 证书 SAN 含 DNS:api.example.com（+localhost/127.0.0.1）
  PASS 3.3 证书当前有效（notAfter=Nov 18 02:50:38 2026 GMT）
```

**【实跑】结论**：证书由 openssl 现场签发、SAN/有效期校验通过。
**边界**：这是**自签**证书，`curl --cacert` 200 说明的是「链路与证书挂载正确」，**不等于生产 TLS 已验证**（无 ACME、无真实域名、无 HSTS 预载）。

---

## 4. `nginx -t` 用**仓库原文件**（零改写）（**【实跑】**）

**命令**：

```bash
docker run --rm -v "$REPO/server/deploy/nginx/carbonboo.conf:/etc/nginx/conf.d/carbonboo.conf:ro" \
  -v "$WORK/certs:/etc/letsencrypt/live/api.example.com:ro" nginx:alpine nginx -t
```

**原始输出**：

```
    nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
    nginx: configuration file /etc/nginx/nginx.conf test is successful
    EXIT=0
    IN_CONTAINER_SHA256=f1edf4f89536869e20c6fae727b9825edc0794d2127a3acd1c597a9276722c6e
  PASS 4.1 仓库原文件 nginx -t 通过（证书路径/上游 127.0.0.1:8000 均在原地）
  PASS 4.2 容器内读到的配置与仓库文件逐字节一致（sha256 f1edf4f89536869e…）
```

**【实跑】结论**：仓库那份 `carbonboo.conf` **字节未改**地装进 `nginx:alpine` 并通过 `nginx -t`；证书按生产路径 `/etc/letsencrypt/live/api.example.com/` 挂载，上游 `127.0.0.1:8000` 保持原样（此步因而**不需要 S1**）。

---

## 5. 应用容器：仓库 `server/` 真代码 + `--workers 2`（**【实跑】**）

**命令**：`python:3.11-slim` + 挂载仓库 `server/` 与 `server/.venv/lib/python3.11/site-packages`，
`uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 2`（除 S2 的监听地址外与 `carbonboo-server.service` 的 `ExecStart` 同形）。

**原始输出**：

```
  PASS 5.1 应用容器启动（uvicorn app.main:app --workers 2，与 systemd ExecStart 同形）
  PASS 5.2 应用就绪：容器内 GET /api/v1/health → 200
      直连响应：{"ok":true,"version":"1.0.0","time":1792378244659}
      （顺带核对保留字列：本库名为 order 的列有 3 个 —— 这是 t46/t49 的引号修复对象）
```

**【实跑】结论**：仓库 `server/` 代码在容器里以 `--workers 2` 起得来，健康检查 200；**零 pip 安装**（直接用仓库 venv 的 site-packages）。

---

## 6. nginx 运行容器 + `nginx -T` 原文留档（**【实跑】**）

**命令**：`docker run -p 127.0.0.1:10080:80 -p 127.0.0.1:10443:443 ... nginx:alpine`（配置 = S1 后的派生副本）；
`docker exec <web> nginx -T > logs/nginx_T_dump.txt`。

**原始输出**：

```
  PASS 6.1 nginx 容器启动（-p 127.0.0.1:10080→80、:10443→443）
  PASS 6.2 运行中容器 nginx -t
      nginx -T 原文（含证书路径与上游）已留档：/tmp/cbe2e.XXXXXX/logs/nginx_T_dump.txt（232 行）
  PASS 6.3 运行配置含『zone=carbonboo_login』
  PASS 6.3 运行配置含『server_name api.example.com』
  PASS 6.3 运行配置含『/etc/letsencrypt/live/api.example.com/fullchain.pem』
  PASS 6.3 运行配置含『http://carbonboo-deploy-e2e-app:8000』
```

**【实跑】结论**：运行中的 nginx 加载的是「仓库那份 + 唯一 S1 替换」；`nginx -T` 全文留档（`logs/nginx_T_dump.txt`，另摘出仓库段 `logs/nginx_T_repo_section.txt`）。

---

## 7. 经 nginx 的 HTTPS 端到端 + 限流实测（**【实跑】**）

### 7.1–7.5 功能与鉴权

**原始输出**：

```
  PASS 7.1 TLS 终止 + 反代上游：GET /api/v1/health → 200 {"ok":true,"version":"1.0.0","time":1792378246090}
  PASS 7.2 HTTP→HTTPS：http://api.example.com:10080/ → 301 https://api.example.com/
  PASS 7.2b ACME 路径未被 301（404，留给 certbot 的 webroot）
  PASS 7.3 免鉴权业务接口：GET /api/v1/shop/items → 200，含 frame_01（1390 字节）
  PASS 7.4 生产关闭 /docs：GET /docs → 404、GET /openapi.json → 404（APP_ENV=prod）
      注册客户端账号 deploy_e2e_1 → HTTP 201（令牌长度 364）
  PASS 7.5 客户端令牌打 /admin/users → 403（{"ok":false,"code":"FORBIDDEN","message":"客户端令牌无权访问管理端（客户端与管理…）
      管理端已挂载：GET /admin/login → 200（INFO）
```

【实跑】结论：TLS 终止、301 跳转、反代上游、`/docs` 生产关闭、客户端令牌打 `/admin/*` 403、管理后台可挂载 —— 六项都在**真实 HTTPS 链路**上验过。

### 7.6 限流（`zone=carbonboo_login`，`rate=20r/m`）

**原始输出**：

```
      POST /api/v1/auth/login × 40 → 429=32 其它=8
  PASS 7.6a 登录接口超阈值被拒：40 次里 32 次拿到 429（limit_req_status 429 生效）
      GET /api/v1/shop/items × 30 → 503=20 200=10
  PASS 7.6b 取价接口超阈值被拒：30 次里 20 次拿到 503（该 location 未设 limit_req_status → nginx 默认 503）
  PASS 7.6c 同接口未超阈值时仍正常 200（10 次）
```

**【实跑】结论**：同一 zone 的三处 `location` 都真的限住了；**拒绝码不一致**（登录/改密 429，取价 503）已如实记录 → 见 §12-1。

---

## 8. `backup-mysql.sh` 真跑 + **真还原**（**【实跑】**）

**命令**：容器内 `bash /opt/carbonboo/server/deploy/backup-mysql.sh`（脚本从 `.env` 取管理员凭据，`mysqldump | gzip`，`chmod 600`，轮转）；
校验与还原在**另一个独立容器**里做（dump 由容器内 `root:600` 写出，宿主读不了，正好也证明「备份可被独立环境导入」）。

**原始输出**：

```
    [2026-10-19T02:50:48+00:00] 备份 carbonboo_deploy_e2e → /var/backups/carbonboo/carbonboo-20261019-0250.sql.gz
    [2026-10-19T02:50:48+00:00] 完成：8.0K
    [2026-10-19T02:50:48+00:00] 已清理超过 14 天的备份
  PASS 8.1 backup-mysql.sh 退出码 0
  PASS 8.2 dump 非空：carbonboo-20261019-0250.sql.gz 4552 字节（8.0K）
    GZIP_OK / SIZE=4552 / PERM=600 / TABLES=21 / UNCOMPRESSED_BYTES=26725
    FIRST_LINE=-- MySQL dump 10.13  Distrib 8.0.46, for Linux (x86_64)
  PASS 8.3 gzip 完整性校验通过（容器内 gzip -t）
  PASS 8.4 dump 内 CREATE TABLE 数 = 21
  PASS 8.5 dump 权限 = 600（脚本第 48 行 chmod）
  PASS 8.6 14 天轮转逻辑在脚本内（find ... -mtime +KEEP_DAYS -print -delete）
  PASS 8.7 把 dump 导回临时库 carbonboo_deploy_e2e_restore（独立容器执行）
      逐表行数（源库 / 还原库）保存在 logs/rowcounts.txt：admin_op_log 0 0 / app_config 3 3 / badge_def 8 8 / …（共 21 张表）
  PASS 8.8 还原后逐表行数与源库完全一致（21/21 表）
```

**边界**：任务库是种子级数据（解压后 26 KB），**锁表时长与大库耗时未测** → §11 N4。

---

## 9. `migrate.sh` 与 systemd（**混合**：9.1–9.5 实跑，9.6–9.7 静态）

**原始输出**：

```
    [dry-run] 001_uq_pr_source_user_id.sql：6 条语句待执行
    [dry-run] 未连接数据库。
  PASS 9.1 migrate.sh --dry-run 退出码 0（只列不连库）
    → 执行 001_uq_pr_source_user_id.sql … 迁移完成。校验（应为 user_id,source_type,source_id,flow_kind）：user_id,source_type,source_id,flow_kind
  PASS 9.2 migrate.sh 真跑任务库退出码 0
  PASS 9.3 迁移后 uq_pr_source 索引列 = user_id,source_type,source_id,flow_kind
  PASS 9.4 安全阀①：库名含 test → 拒跑（exit 2）
  PASS 9.5 安全阀②：无 mysql 客户端 → 拒跑（exit 3，不静默跳过迁移）
```

**【实跑】结论**：`--dry-run` 与真跑的对照成立（dry-run 只列不连库；真跑改了索引并自校验列序 = `user_id,source_type,source_id,flow_kind`，与 AGENTS B40 口径一致）；两个安全阀都**真的**以退出码 2 / 3 拒跑。

```
      9.6a 对仓库路径原样 verify：退出码 = 1
      carbonboo-purge.service: Command /opt/carbonboo/server/.venv/bin/python is not executable: No such file or directory
      carbonboo-server.service: Command /opt/carbonboo/server/.venv/bin/uvicorn is not executable: No such file or directory
  PASS 9.6a 原样 verify 的报错全部可归因于环境（drvfs 权限位 + 生产路径 /opt/carbonboo 不存在），无语法/依赖类错误
      9.6b 单元复制到 /tmp/cbe2e.XXXXXX/units（mode 644）+ ExecStart 前缀 S5 换成 stub：退出码 = 0
  PASS 9.6b 单元语法/指令/依赖全部通过 systemd-analyze verify（唯一失败原因是生产安装路径不存在）
  PASS 9.6c carbonboo-server.service 的 ExecStart/加固/重启策略 14 项逐条命中
  PASS 9.6d purge.service/.timer（30 天物理清除 + 每日 04:23 + 随机延迟 + 持久化）逐条命中
  PASS 9.6e 三个单元文件内无机密（密钥只从 server/.env 600 读）
  PASS 9.7 单元 ExecStart 与本次实跑的应用启动形态一致（uvicorn app.main:app --workers 2）
      systemctl: /usr/bin/systemctl（WSL 无 PID1 systemd，未运行）
```

**【静态验证】结论**：单元本体无语法/指令/依赖错误（S5 副本 `verify` 退出码 0）；`9.6a` 的报错只有两类且都可归因于环境（`/mnt/c` 由 drvfs 挂载，权限位显示为 0777；生产安装路径 `/opt/carbonboo` 本机不存在）。
**【未运行】**：单元与 timer **从未启动** → §11 N1。

---

## 10. 收尾清理（**【实跑】**）

```
  PASS 10.1 本工具的三个容器已全部删除
  PASS 10.2 两个临时库已删除
      carbonboo-mysql 现在的网络：bridge
  PASS 10.3 派生网络已删除
  PASS 10.4 被测路径 git status 干净（app/ server/ docs/ tests/cases/）
```

独立复核（本轮另跑）：`docker ps -a | grep -c carbonboo-deploy-e2e` → `0`；`docker network ls | grep -c carbonboo-deploy-e2e` → `0`；
`docker inspect carbonboo-mysql --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'` → `bridge `；
`SELECT schema_name … LIKE 'carbonboo_deploy_e2e%'` → **0 行**；`git status --short -- app/ server/ docs/ tests/cases/` → **0 行**。

---

## 11. 未运行清单（**明确不算通过**）

| 编号 | 未运行项 | 具体原因 | 退出码 / 原始输出 |
|---|---|---|---|
| **N1** | systemd 单元与 timer 的 enable/start/日志 | WSL 内**无 PID1 systemd**（`systemctl` 存在但 systemd 未作为 init 运行）；容器里也不是 systemd init ⇒ 只能做静态校验 9.6a/9.6b/9.6c/9.6d/9.6e/9.7 | 无（未执行）；`systemd-analyze verify` 原样 rc=1（环境性报错，见 §9） |
| **N2** | certbot 真实签发与续期（ACME） | 不联网、无真实域名，证书以 openssl 自签替代；`/.well-known/acme-challenge/` 只验了「未被 301」（404，留给 webroot） | 无 |
| **N3** | 公网域名 `api.example.com` 的 DNS/防火墙/WAF/备案 | 只有本机端口映射 + `Host` 头；**验的是配置与链路，不是真实域名与备案** | 无 |
| **N4** | mysqldump 的锁表时长与大库耗时 | 任务库只有种子级数据（解压后 26 725 字节） | 无 |
| **N5** | 生产 MySQL **普通用户**凭据 | 本工具用 `server/.env` 里的管理员凭据建库/还原 | 无 |
| **N6** | 环境不可达分支的完整覆盖 | 只验了「无 docker」一条：`env PATH=<无 docker 的 PATH> bash run.sh` → `ENV 没有 docker` | **EXIT=2** ✅（其余 env 分支如缺镜像/端口占用未逐个构造） |

### 连跑与「先失败后修好」的记录（诚实性）

- **run1**：`EXIT=1`，`PASS=40 FAIL=5` —— 失败项 `8.3 gzip 文件损坏 / 8.4 dump 内 table 数 = 0 / 8.7 还原 rc=1 / 8.8 行数不一致 / 9.6 systemd-analyze 报错`。
  **根因**：① dump 由容器内 `root:600` 写出，宿主用户读不了 ⇒ `gzip -t`/`zcat` 全部失败（**工具自身的缺陷，不是备份坏了**）；② `systemd-analyze verify` 的报错全是环境性的（drvfs 权限位 + `/opt/carbonboo` 不存在），断言写得太粗。
  **修法**：dump 的校验与还原改到**容器内**做；systemd 校验拆成 9.6a（原样，按错误类别归因）+ 9.6b（S5 副本，`verify` 必须 rc=0）+ 9.6c/9.6d/9.6e（单元内容逐条）。
- **run2 / run3**：`EXIT=0`，`PASS=49 FAIL=0`。
- **run4（提交后重跑，绑定提交字节）**：提交 `148c3f9b64581d8e72fd5f80d3cfc44bf0b6e78e` 之后**再跑一次** ⇒ `EXIT=0`，`PASS=49 FAIL=0`。
  连跑的一致性口径（避免把「一致」说满）：**探针名称与条数逐条一致（49/49）**，只有两处**动态值**必然不同 ——
  证书 `notAfter`（现场签发时刻）与 dump 文件名/字节数/健康响应里的时间戳。归一化后（把时间戳与 dump 名替换掉）比对：
  除 `3.3 notAfter=<时刻>` 一行外，`[PASS]` 行**逐字节相同**。

---

## 12. 观察与未决问题（按契约：**只报告不改**）

1. **同一限流 zone 的拒绝码不一致**（`server/deploy/nginx/carbonboo.conf`）：
   `:64`（`/api/v1/auth/(register|login)`）与 `:73`（`/admin/(login|password)`）设了 `limit_req_status 429`，
   而 `:52-54`（`= /api/v1/shop/items`）**未设** ⇒ 走 nginx 默认 **503**（实测 20/30 被拒为 503）。
   这不是故障（取价接口 503 语义上也说得通），但**同一 zone 两种拒绝码**会让客户端错误处理分叉；若要统一，加一行 `limit_req_status 429;` 即可。**我未改**（`server/deploy/` 不在本任务写入范围）。
2. **`limit_req` 的三处 burst 不一致**：取价 `burst=20`，登录/改密 `burst=10`。疑似刻意（取价是读接口），仅记录。
3. **`limit_req_zone` 的 key 是 `$binary_remote_addr`**：经 nginx 反代后，若前面再加 CDN/LB，需要 `real_ip` 模块，否则所有请求按同一 IP 限流。生产拓扑相关，仅记录。
4. **自签证书 ≠ 生产 TLS**：`curl --cacert` 200 只证明链路与挂载正确；ACME/续期/真实域名未验（N2/N3）。
5. **`backup-mysql.sh` 的 dump 权限 600 + root 属主**：在容器里没问题；若生产把备份目录挂共享/NFS，需要注意属主。仅记录。

**未触发 STOP 三行**：本轮未在 `server/deploy/nginx/carbonboo.conf` 或三个 systemd 单元里发现真缺陷（无「限流 zone 未定义 / `/docs` 未关 / 反代头缺失 / 证书路径不可替换」这类问题；zone 定义在 `:11`，`/docs` 实测 404，反代头与证书路径按生产约定）。

---

## 13. 证据留档（`L1_KEEP=1` 时保留在 `${WORK}`）

| 文件 | 内容 |
|---|---|
| `logs/nginx_T_dump.txt` | 运行容器 `nginx -T` 全文（232 行，含证书路径与上游） |
| `logs/nginx_T_repo_section.txt` | 从 `-T` 里摘出的仓库 `carbonboo.conf` 段 |
| `logs/conf.diff` | 仓库配置 vs 运行配置的完整 diff（变更行数 = 10） |
| `logs/nginx_t_asis.log` / `nginx_t_runtime.log` | `nginx -t` 两次（原文件 / 运行副本）原文 |
| `certs/fullchain.pem`、`certs/privkey.pem`、`logs/cert.txt` | 自签证书与 `x509 -text` 摘要 |
| `logs/health_direct.txt` / `health_via_nginx.txt` | 直连与应用经 nginx 的健康响应 |
| `logs/http_redirect.txt` | 301 跳转原始响应头 |
| `logs/shop_items.txt` | `GET /api/v1/shop/items` 响应体 |
| `logs/admin_403.txt` | 客户端令牌打 `/admin/users` 的 403 响应体 |
| `logs/register.json` | 现场注册的客户端账号响应（令牌长度 364） |
| `backups/*.sql.gz`、`logs/backup.log`、`logs/dump_check.log` | dump 本体与容器内校验（SIZE/PERM/TABLES/UNCOMPRESSED/FIRST_LINE） |
| `logs/rowcounts.txt` | 21 张表「源库 / 还原库」行数对照 |
| `logs/migrate_dry.log` / `migrate_real.log` / `migrate_guard_*.log` | `migrate.sh` 三种跑法原文（含两个安全阀） |
| `logs/systemd_verify_raw.log` / `systemd_verify_stub.log` | `systemd-analyze verify` 原样 / S5 副本原文 |
| `units/`、`stub/` | S5 副本与 stub 可执行文件 |
| `app.env`、`schema.sql`、`seed.sql` | S3/S4 派生文件（密钥已打码，未入库） |
