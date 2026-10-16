# CarbonBoo 服务端开发环境 —— 队长实测笔记

> 由队长在 2026-10-16 亲手实测。给 server-api / admin-web / qa-verifier 用。

## 1. MySQL 已经跑起来了（可直接用）

```bash
docker run -d --name cb-mysql \
  -e MYSQL_ROOT_PASSWORD=cbpass123 -e MYSQL_DATABASE=carbonboo \
  -p 13306:3306 docker.m.daocloud.io/library/mysql:8.0
```

- 版本 **MySQL 8.0.46**，容器名 `cb-mysql`，映射 **宿主机 `127.0.0.1:13306`**。
- 账户 `root` / `cbpass123`，库 `carbonboo`（utf8mb4）。
- **必须用 TCP**：`mysql --protocol=TCP -h127.0.0.1`。容器内 `localhost` 走 socket 会报
  `Access denied for user 'root'@'localhost'`（root@localhost 与 root@% 两条记录、plugin 是
  `caching_sha2_password`）；走 `-h127.0.0.1` 就正常。**这不是密码错了，别去改密码。**
- 从宿主机连（推荐，最接近 server 真实场景）：
  ```bash
  docker run --rm --network host docker.m.daocloud.io/library/mysql:8.0 \
    mysql --protocol=TCP -h127.0.0.1 -P13306 -uroot -pcbpass123 -e "SELECT VERSION()"
  ```
- 已实测：建表 `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4` + `DECIMAL(18,4)` 正常。

SQLAlchemy 连接串（注意端口是 13306）：
```
mysql+pymysql://root:cbpass123@127.0.0.1:13306/carbonboo?charset=utf8mb4
```

## 2. Python 依赖栈已验证可装

**WSL 系统 Python 3.14.4 没有 pip**（`No module named pip`，且用户非 root 装不了）。
`pypi.org` 与清华源**都不可达**，只有阿里云源可用：`https://mirrors.aliyun.com/pypi/simple/`。

实测在 `python:3.12-slim` 容器里一次装齐（**版本已跑通**）：
```bash
docker run --rm python:3.12-slim sh -c '
pip install -q -i https://mirrors.aliyun.com/pypi/simple/ \
  fastapi "uvicorn[standard]" sqlalchemy pymysql "passlib[bcrypt]" \
  "python-jose[cryptography]" pydantic-settings pytest httpx'
```
结果：`fastapi 0.143.2` / `sqlalchemy 2.1.4` / `pydantic 2.14.1` / `pytest 9.1.1` —— **全部 import 成功**。

> 依赖清单里 `pymysql`、`passlib[bcrypt]`、`python-jose[cryptography]` 都已实测可装。
> 若 `passlib` 与新版 `bcrypt` 有 API 摩擦，可直接用 `bcrypt` 库本身，不必强求 passlib。

## 3. 建议的 L3 跑法

MySQL 用容器（已就绪），FastAPI 也跑容器或直接在 `python:3.12-slim` 里跑：

```bash
# 建表
docker run --rm --network host -v "$PWD/server:/app" -w /app python:3.12-slim \
  sh -c 'pip install -q -i https://mirrors.aliyun.com/pypi/simple/ -r requirements.txt && \
         python -c "import app.main"'
```

**注意 `--network host`**：容器里 `127.0.0.1:13306` 才指向宿主机的 MySQL。
不加 host 网络时要用 `--network cb-net` 或 host.docker.internal。

## 4. 诚实边界

- 本机**没有 systemd、没有 nginx**，`server/deploy/` 的 systemd 单元与 TLS 只能**写出来**，
  无法真实 `systemctl start` 验证。容器化路径可验证。
- L3 用例若因环境跑不起来，**如实报告哪些没跑**，不要写「通过」。
