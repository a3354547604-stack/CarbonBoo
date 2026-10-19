# tests/tools/repro —— 一键复现编排

> 目的：把「换一个人 / 换一台机器，照着文档能自己跑出来」这件事变成**一条命令**。
> 本工具只做编排（调用仓库自带的门禁工具），**不内联任何算法或期望值**：每条判定都来自
> 被调工具自己的退出码。

---

## 1. 它解决什么问题

仓库里的门禁分散在四处、各有自己的前置条件与退出码约定：

| 门禁 | 命令 | 前置 |
|---|---|---|
| L0 文档与数值一致性 | `python3 tests/tools/check_l0.py --strict` | 系统 `python3`（本机 3.14.4） |
| L1 纯逻辑复算（323 个断言点） | `bash tests/tools/l1_offline/run.sh` | `esbuild` + `node`（esbuild 不在 PATH 时需 `ESBUILD=`） |
| L1 hypium 用例（41 条 `it()`） | `bash tests/tools/l1_offline/run_tests.sh` | 同上（离线转译执行，**不是**真机 hypium） |
| L3 服务端 pytest（241 条） | `cd server && .venv/bin/python -m pytest tests/ -q` | Python 3.11 venv + 可达的 MySQL 8（本机容器在 **13307**） |
| 鸿蒙构建 | `source ~/harmony-toolchain/env.sh && cd app && hvigorw --no-daemon assembleHap` | 命令行工具链（仓库外，`~/harmony-toolchain/`） |

`run.sh` 把它们串起来，逐条给 `PASS / FAIL / ENV-SKIP` 与退出码，最后一行总结：

```
REPRO: PASS=5 FAIL=0 ENV-SKIP=0 TOTAL=5 log_dir=/tmp/cbrepro-XXXXXX
```

`ENV-SKIP` 是**显式**的：缺工具链 / 缺 venv / 连不上 MySQL 时不会伪装成通过，也不会算失败。

## 2. 怎么跑

```bash
# 在一份干净副本里（推荐：副本 = git archive HEAD，见 §4）
bash tests/tools/repro/run.sh

# 只跑某一条（排障）
REPRO_ONLY=l0| l1 | l1test | pytest | hap   bash tests/tools/repro/run.sh

# 自定日志目录 / 透传依赖路径
REPRO_LOG_DIR=/tmp/mylogs ESBUILD=~/harmony-toolchain/esbuild/bin/esbuild bash tests/tools/repro/run.sh
```

退出码：**0** = 全部 PASS（可含 ENV-SKIP 混合）｜**1** = 有 FAIL｜**2** = 全部 ENV-SKIP（环境不可达）。

## 3. 前置条件（每条都给文档出处）

1. **系统 `python3`**（L0 用）：本机 3.14.4。→ `docs/toolchain/server-env.md §1`
2. **`esbuild` + `node`**（L1 用）：默认读 `$HOME/harmony-toolchain/esbuild/bin/esbuild` 与
   `$HOME/harmony-toolchain/clt/command-line-tools/tool/node/bin/node`，可用 `ESBUILD` / `NODE` 覆盖。
   → `tests/tools/l1_offline/run.sh` 头部注释、`docs/toolchain/harmony-cli-build.md §7`
3. **Python 3.11 venv**（L3 用）：仓库**不带** `server/.venv`（约 1.3 万文件，不入库）。首次要建：
   ```bash
   cd server && python3.11 -m venv .venv \
     && .venv/bin/pip install -r requirements.txt -i https://mirrors.aliyun.com/pypi/simple/
   ```
   → `server/README.md §2`（首次需网络：PyPI 镜像）
4. **MySQL 8**（L3 用）：本机用容器 `carbonboo-mysql` 映射到 **127.0.0.1:13307**；凭据来自
   `server/.env`，**没有 `.env` 时用环境变量**（`MYSQL_HOST/PORT/USER/PASSWORD` + `MYSQL_ADMIN_USER/PASSWORD`）
   —— 这是 `server/README.md §8` 写明的官方形式。测试库名默认 `carbonboo_test_repro`（可用
   `CARBONBOO_TEST_DB` 改；库名不含 `test` 会被服务端测试直接拒绝，防误清真库）。
5. **鸿蒙命令行工具链**（构建用）：`~/harmony-toolchain/env.sh` + `hvigorw`，见
   `docs/toolchain/harmony-cli-build.md §1/§3`。

## 4. 「干净副本」怎么来（可复现性验证的正确做法）

`git archive` 只导出**被跟踪**的字节，天然不含 `.venv`、`oh_modules`、`build/`：

```bash
mkdir -p /tmp/cbrepro && git archive HEAD | tar -x -C /tmp/cbrepro
cd /tmp/cbrepro && git init -q && git add -A \
  && git -c user.name=repro -c user.email=repro@local commit -qm "archive HEAD"
git status --short          # 空
bash tests/tools/repro/run.sh
```

在副本里 `git init` 只是为了让「工作树是否干净」可判（也便于反证后 `git checkout --` 还原）。

## 5. 边界：这个工具**证明**什么、**不证明**什么

**证明**：在一份只含被跟踪字节的副本里，配合文档写明的环境前提，上面五条门禁能跑、能出预期的
退出码；`ENV-SKIP` 一定伴随一条「缺什么、按哪份文档装」的具体提示。

**不证明**：

- **不是**真机 hypium：`run_tests.sh` 是 esbuild 转译 + `node:sqlite` 垫片的**离线**执行；
  10 个套件 / 41 个 `it()` 在真机上仍然**没有跑过**（`hdc` 缺失、`/dev/kvm` 不可写、无模拟器）。
- **不是**端侧集成（L2 真机双设备）、**不是** `/admin` 浏览器交互（`tests/tools/admin_e2e/`
  需要 Windows Edge）、**不是** `server/deploy/` 容器化实跑（`tests/tools/deploy_e2e/`）、
  **不是**视觉走查（`tests/tools/vision_check/` 只验设计令牌色板，不出 18 页截图）。
- **不是**「文档描述的都是对的」：L0 只校验文档与 `tests/cases/carbon-calc.json` 的一致性，
  不校验叙述性文字的真假。
- 网络：`pip install` 首次需要 PyPI 镜像；其余步骤离线可跑。

## 6. 本工具不替代任何门禁

`repro/run.sh` 是**编排层**，不是判定层。任何一条门禁的判据都在它自己的脚本/测试里；
改这里的代码只应改「调用谁、怎么报」，**不应**改「算不算过」。

## 7. 已知坑（实测踩过，按严重度）

1. **`app/hvigor/hvigor-config.json5` 里两条 `file:` 绝对路径写死了 `~/harmony-toolchain/...`**
   （被跟踪文件，换机器必须改，文件内已有注释说明）。这是目前**唯一**会让「换机器一条命令跑通」
   失败的被跟踪配置；L1/L3 的同类依赖都走环境变量或 `$HOME` 解析。
2. venv 首次安装**必须联网**（PyPI 镜像）；离线机器上 L3 只能是 `ENV-SKIP`。
3. MySQL 端口在部分机器上是 **13307**（不是 3306）；本工具会从 `server/.env` 或 `MYSQL_PORT` 取，
   缺省 13307（`docs/toolchain/server-env.md §1`）。
4. `esbuild` 不在 PATH 时 L1 会 `ENV-SKIP`；设 `ESBUILD=` 即可（`docs/toolchain/harmony-cli-build.md §7`）。
5. 鸿蒙构建**不需要**签名：`assembleHap` 会打印 `WARN: No signingConfig found`，仍 `BUILD SUCCESSFUL`
   （只产出未签名 HAP）。
6. 构建产物全部被 `.gitignore` 覆盖，跑完副本 `git status --short` 仍为空；**不要**因此认为
   「构建没写文件」——它写了 `app/**/build/` 与 `.hvigor/`。
7. 本仓库有多份数值真相源副本（`tests/cases/carbon-calc.json` 与
   `app/entry/src/ohosTest/resources/rawfile/carbon-calc.json`），L1 用的是后者；两处必须逐字节一致
   （L0 会查一致性，工具不查 md5）。

## 8. 与其它证据工具的关系

| 工具 | 回答的问题 | 需要什么 |
|---|---|---|
| `tests/tools/repro/`（本工具） | 换机器能一键复现吗？ | 按 §3 装齐四条前置 |
| `tests/tools/l1_offline/` | 纯逻辑对不对（323 断言点 / 41 用例） | esbuild + node |
| `tests/tools/admin_e2e/` | `/admin` 七项功能与鉴权边界是否真能用 | Windows + Edge + MySQL + venv |
| `tests/tools/deploy_e2e/` | `server/deploy/` 四件部署实物是否真能用 | Docker |
| `tests/tools/offline_first/` | 未登录是否真的纯单机（出网=0） | esbuild + node |
| `tests/tools/l2_sync/` | 两设备跨端同步/LWW | Python + MySQL |
| `tests/tools/concurrency_e2e/` | 并发/竞态守恒 | Python + MySQL |

「未运行 = 不算通过」：任何工具 `ENV-SKIP` 的条目都不计入通过。
