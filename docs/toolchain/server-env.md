# CarbonBoo 服务端开发环境 —— 队长实测笔记

> 由队长在 2026-10-16 亲手实测。给 server-api / admin-web / qa-verifier 用。

## 0. 一句话跑法（**用这条，别自创**）

```bash
cd server && CARBONBOO_TEST_DB=carbonboo_test_<你的任务号> .venv/bin/python -m pytest tests/ -q
```

三个必踩点：
1. **WSL 没有 `python` 命令**（系统 python3.14 也没装 pytest）。必须用 **`server/.venv/bin/python`**（Python 3.11.17）。
2. **MySQL 端口是 13307，不是 13306。** 见 §1。
3. **必须给每个并发者一个独立的测试库名**（`CARBONBOO_TEST_DB=...`），否则会假失败。见 §1.1。

## 1. MySQL：两个容器，认准 `carbonboo-mysql`

### 1.0 本项目用哪个（**关键，别连错**）

| 容器 | 端口 | 归属 |
|---|---|---|
| **`carbonboo-mysql`** | **`127.0.0.1:13307`** | **本项目 server/ 用它**（root/cbpass123，库 `carbonboo` / `carbonboo_test`） |
| `cb-mysql` | `127.0.0.1:13306` | **他人/mysql 服务器**，**不要连**（连错会得到「表不存在」或污染别人数据的假象） |

`server/.env` 里已写好 `MYSQL_PORT=13307`；`server/tests/conftest.py:44` 的端口候选是 `(3306, 13307)`，
`conftest.py:95` 读 `CARBONBOO_TEST_DB` 覆盖测试库名（**库名必须含 `test`**，否则夹具直接停手防误清）。

### 1.1 并发跑 pytest 会让彼此假失败（**队长实测踩过**）

多个成员同时对同一个测试库跑 pytest，建表/改表互相打断，报：

```
sqlalchemy.exc.OperationalError: (pymysql.err.OperationalError)
(1412, 'Table definition has changed, please retry transaction')
```

**这不是代码缺陷。** 队长实测：同一个提交，共用库跑出 16 failed / 111 passed，
改用 `CARBONBOO_TEST_DB=carbonboo_test_captain` 后 **127 passed**。
→ 规矩：**每个并发者用自己的库名**。

### 1.2 连接细节

- 版本 **MySQL 8.0.46**，账户 `root` / `cbpass123`。
- **必须用 TCP**：`mysql --protocol=TCP -h127.0.0.1`。容器内 `localhost` 走 socket 会报
  `Access denied for user 'root'@'localhost'`（root@localhost 与 root@% 两条记录、plugin 是
  `caching_sha2_password`）；走 `-h127.0.0.1` 就正常。**这不是密码错了，别去改密码。**
- 从宿主机连：
  ```bash
  docker run --rm --network host docker.m.daocloud.io/library/mysql:8.0 \
    mysql --protocol=TCP -h127.0.0.1 -P13307 -uroot -pcbpass123 -e "SELECT VERSION()"
  ```
- 已实测：建表 `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4` + `DECIMAL(18,4)` 正常。

SQLAlchemy 连接串（注意端口是 **13307**）：
```
mysql+pymysql://root:cbpass123@127.0.0.1:13307/carbonboo?charset=utf8mb4
```

> 附：`cb-mysql` 的建法（**历史，本项目不用**）
> ```bash
> docker run -d --name cb-mysql -e MYSQL_ROOT_PASSWORD=cbpass123 \
>   -e MYSQL_DATABASE=carbonboo -p 13306:3306 \
>   docker.m.daocloud.io/library/mysql:8.0
> ```

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

**注意 `--network host`**：容器里 `127.0.0.1:13307` 才指向宿主机的 MySQL。
不加 host 网络时要用 `--network cb-net` 或 host.docker.internal。

## 4. 诚实边界

- 本机**没有 systemd、没有 nginx**，`server/deploy/` 的 systemd 单元与 TLS 只能**写出来**，
  无法真实 `systemctl start` 验证。容器化路径可验证。
- L3 用例若因环境跑不起来，**如实报告哪些没跑**，不要写「通过」。
- **队长已独立复跑**（2026-10-16，隔离库名）：`cd server && CARBONBOO_TEST_DB=carbonboo_test_captain .venv/bin/python -m pytest tests/ -q` → **127 passed**。这是 t3+t5 的真实基线。
