# t8 交付评审报告 · CarbonBoo（赛题二）

> 评审人：reviewer-cn（AgentTeams 成员，交付评审员）
> 评审对象：HEAD = `39be3b043ba1fec90cf252f5c9b7a37970f87334`（`git rev-parse HEAD` 实跑；`git ls-remote origin main` 同值 ⇒ 已推送，符合 `AGENTS.md §5.1-4`）
> 被评审的验证轮：t7 / t24（`docs/VERIFICATION.md`，904 行，`39be3b0` 入库）
> 本报告只写本文件；**未修改任何被测源码与规格文档**。评审结束时 `git status --short` 除本文件外为空。

---

## §0 结论

**verdict = `needs_revision`**

一句话：**三部分（app / server / /admin）实体齐备、编译门禁真实、四条铁律静态成立、无任何测试篡改，可以进入收尾；但「文档契约已冻结」这一前置结论不成立——例外集口径在 `docs/PLAN.md` / `docs/adr/0001` / 基准 `docConflicts` 正文里仍是「四类」，与 `AGENTS.md` 的「五类」直接冲突，命中 `AGENTS.md §1.3` 停手条件；同时用户 m00004 明示的「前端子代理须有视觉模型」一项从未达成、也未在交付物中声明未达成。**

不判 `reject` 的理由：逐提交扫描全历史，**没有**「为让测试通过而改期望值 / 删断言 / 跳用例」的提交（见 §6，三个涉事提交逐行核查后均判为非违规）；L0 门禁 EXIT=0；编译门禁注入自证成立。
不判 `pass` 的理由：见 §8 的 R1（medium，直接触发 §1.3）与 R2（medium，用户明示要求未达成且未声明）。

---

## §1 评审方法：我实跑了什么、采信了什么

| 项 | 我本人实跑 | 原始输出（摘） |
|---|---|---|
| 基准复核 | ✅ | `git rev-parse HEAD` → `39be3b043ba1fec90cf252f5c9b7a37970f87334`；`git ls-remote origin main` → 同值 |
| L0 门禁 | ✅ | `python3 tests/tools/check_l0.py --strict` → `L0-1 检查项 28 错误 0` / `L0-2 扫描 82 文件命中 0` / `L0-3 docConflicts 0 条` / `结论：PASS`，**EXIT=0** |
| 编译门禁注入自证 | ✅（本人做，未采信他人） | 见 §2 |
| L1 用例 | ❌ 无法运行 | 见 §7 与 §9 |
| L3 服务端 | ✅ 子集重跑 | `CARBONBOO_TEST_DB=carbonboo_test_t8 ./.venv/bin/python -m pytest tests/test_config.py tests/test_shop.py -q` → **35 passed**, 1 warning in 137.83s，EXIT=0；`… tests/test_admin.py -q -k "forbidden or not_accepted or different_keys"` → **19 passed, 66 deselected**, 1 warning in 17.82s，EXIT=0 |
| L3 全量 237 passed | 采信（无法本地复现全量耗时） | 由队长代跑：`237 passed, 252.98s`，EXIT=0。**间接证据**：`git diff --stat fa91daa..HEAD -- app/ server/ tests/` 输出为空 ⇒ 该次运行所对应的代码自 `fa91daa` 起未再改动，结论可沿用。**但仍属间接证据，本报告不给它「我复现过」的措辞。** |
| `/admin` 11 条路径可达性 | 采信（队长真 uvicorn + 真 MySQL 逐条打） | `/admin/login` 200；未登录其余页 303；`/admin/static/admin.css` 200；`/admin/nonexistent` 404；**带客户端 token 打 `/admin/*` 全部 403（含未注册路径 `/admin/nonexistent`，说明拦在中间件）**；同 token 打 `/api/v1/auth/me` 200；无 token 401 |
| `GET /api/v1/config` 免鉴权 | 采信（并在代码侧交叉核对，见 §5） | 无 `Authorization` → 200，`{"ok":true,"data":{"version":"0.0.0","pointsDailyCap":200,"badgesEnabled":true,"goalRewards":[{"goalId":"L1","reward":1000},…],"serverTime":1792219350197}}`；`badgesEnabled` 是 **JSON 布尔** `true` 而非 `1`；`goalRewards` 11 条按 goalId 升序 |
| 规约红线（`any` / `@ts-ignore` / 第三方包 / `as`） | 采信队长，并抽查 `as` 唯一真断言行 | `app/` 内 `: any` = 0、`@ts-ignore` = 0、非相对 import（排除 `@ohos`/`@kit`）= 0；`as X` 命中 4 处 = 2 个 `import * as J` + 1 个 `export { … as … }` + **唯一真断言 `app/entry/src/main/ets/util/JsonUtil.ets:33` `return v as JsonObject;`**，其上 `:24-31` 已做运行时判定并注释说明。**我核对后同意判合规**（这是 SDK 类型缺失处的窄化断言，且提供方已先做 `typeof`/`in` 判定，非「用 as 掩盖类型错误」） |
| git 历史（改期望值/删断言/跳用例） | ✅ 本人全历史逐提交扫描 | 见 §6 |

**基准数值实测**（现场，非转抄）：`md5sum tests/cases/carbon-calc.json` = `c096da45ba7e1852d25cf91699fcb42b`；`samples 18 / capSamples 5 / boundarySamples 6 / factors 31 / meta.factorVersion CF-2026.2 / docConflicts 47 条 closed 47、open 0`。ohosTest 副本 md5 同值。

---

## §2 编译门禁自证（本项目最大的历史坑，必须成对证明）

坑的背景：`pages/Index.ets` 曾不 import 任何业务模块，`service/`、`data/` 整目录掉出编译图，而 `assembleHap` 照报 `BUILD SUCCESSFUL`。因此**单独的 `BUILD SUCCESSFUL` 不是证据**，必须用「注入未定义**引用** → 必须 BUILD FAILED」自证。

我做的（`cp` 备份、`cp` 还原，**未用 `git checkout`**，遵守任务边界）：

```
# 锚点文件：app/entry/src/main/ets/viewmodel/net/SyncService.ets（md5 d0fce64796fa5d901b243cc926616980）
# 注入（追加到文件尾，必须是引用表达式，纯声明不会失败）：
const T8_GATE_PROBE: number = T8_UNDEFINED_PROBE_SYMBOL + 1;

1 ERROR: ArkTS:ERROR File: /mnt/c/Users/Administrator/Desktop/CarbonBoo/app/entry/src/main/ets/viewmodel/net/SyncService.ets:831:31
Cannot find name 'T8_UNDEFINED_PROBE_SYMBOL'.
COMPILE RESULT:FAIL {ERROR:2}
> hvigor ERROR: BUILD FAILED in 22 s 26 ms
INJECT_EXIT=255

# 还原（md5 复原 d0fce64796fa5d901b243cc926616980 → 与备份逐字节相同）
> hvigor Finished :entry:default@PackInfo… / CompileArkTS… UP-TO-DATE
BUILD SUCCESSFUL in 26 s 186 ms
RESTORE_EXIT=0
产物 app/entry/build/default/outputs/default/entry-default-unsigned.hap = 2,445,613 字节
```

结论：
1. **编译门禁是真实的**——错误自定位到 `SyncService.ets:831:31`，说明 `viewmodel/net/` 层确在编译图内且受编译器校验；
2. **工作树零污染**——还原后 `git status --short` 输出为空（也反面证明评审开始前工作树本就是干净的）；
3. ⚠️ **必须如实写出的局限**：队长代跑的那次 `assembleHap`（`BUILD SUCCESSFUL in 5 s 552 ms`）与我这次还原后的 `26 s 186 ms` **都是增量构建，含大量 `UP-TO-DATE`**，它们**不能**证明「从零全量可编译」。本轮**没有**做 `clean` 后的全量构建（任务边界禁止触碰构建产物以外的东西，且全量构建耗时长）。真正被证明的是「门禁真实 + 改动可见」，这一点足够支撑「不是假绿」，但不足以支撑「全量可编译」。

---

## §3 三部分交付对照用户 m00004 原始要求

User said (m00004)：交付三部分 ① `app/` 鸿蒙客户端（ArkTS API 12，按 `AGENTS.md §4` 切片 S1–S7）② `server/`（FastAPI + MySQL）③ `/admin` Web 后台。

### ① `app/` 鸿蒙客户端 — **在，且可编译**

| 要求 | 实测证据 | 判定 |
|---|---|---|
| ArkTS / API 12 | `app/build-profile.json5` / `hvigorw assembleHap` 通过；`app/entry/src/main/ets/**` 全 `.ets` | ✅ |
| S1 数据地基（19 张表 + 因子库 + `CarbonService.calculate`） | `app/entry/src/main/ets/data/schema/ClientSchema.ets` 实有 **19 条 `CREATE TABLE`**（第 20 处 grep 命中是文件头注释「43 条 = 19 CREATE TABLE + 24 CREATE INDEX」）；`resources/base/rawfile/factors/carbon-factors.json` **30 条**（+ `CAR_OWN_FACTOR` = 31，与基准一致）；`service/CarbonCalc.ets:153` 唯一乘法点 | ✅ |
| S2 记录闭环（录入→落库→首页/记录页/看板同源） | `pages/` **19** 个文件（`Index.ets` + 18 页：Home/Dashboard/Record/Science/Mine 五 Tab + RecordEdit/RecordDetail/RecordSearch/Goal/Badge/Shop/PointLog/ScienceDetail/Sync/Include/Appearance/Settings/About 十三二级页）；`viewmodel/RouteName.ets` **18** 个 `static readonly` 常量，`Index.ets` 引用 `RouteName.` **13** 处 | ✅ |
| S3 激励闭环（封顶 / 11 目标 / 8 徽章） | `resources/base/rawfile/goals/goal-defs.json` **11** 项、`badges/badge-defs.json` **8** 项；封顶逻辑在 `PointService` + `CarbonCalc` | ✅ 结构在；**行为未运行**（§9） |
| S4 外观闭环（碳小铺 / 主题树） | `shop/shop-items.json` **9** 项；`pages/ShopPage.ets`、`AppearancePage.ets`、`components/CategoryTag.ets` 均入图 | ✅ |
| S5 主要功能（科普 12 篇 / 备份恢复导出清空） | `rawfile/science/science-index.json` **12** 项 + `sci-01..12.md` **12** 篇；`components/BackupListSheet.ets` 存在 | ✅ |
| S6 服务端对接（账号/取价/同步） | `viewmodel/net/{HttpPort,ServerConfigFetcher,ShopPriceFetcher,SyncService}.ets` | ✅ |
| S7 创新项（识图 / 碳普惠 / 分享卡） | `components/SimulationBanner.ets`、`DemoModeBanner.ets`、`DevOptionsSheet.ets` | ✅ 有承载 |
| UI 组件层 | `components/` **23** 个 `.ets` | ✅ |
| L1 单测 | `app/entry/src/ohosTest/ets/test/` 10 套件、**36 个 `it()`**（`List.test.ets` 10 import / 10 调用一一对应，`grep "  it("` 合计 36） | ⚠️ **编写齐全但一条都没跑过**，见 §9 |

### ② `server/` FastAPI + MySQL — **在，L3 真实通过**

| 要求 | 实测证据 | 判定 |
|---|---|---|
| FastAPI + SQLAlchemy + MySQL 8 | `server/app/`（`api/` `core/` `models/` `schemas/` `services/`）、`server/pyproject.toml`、`server/requirements.txt` | ✅ |
| 21 张表 | `server/sql/schema.sql` **21** 条 `CREATE TABLE` | ✅ |
| 账号（register/login/me/logout）+ 双 JWT 密钥隔离 | `server/app/api/v1/auth.py`；`tests/test_authz.py` 16 个用例；客户端 token 打 `/admin/*` → 403（队长实测 + 我 19 passed 复现） | ✅ |
| 商品取价 | `server/app/api/v1/shop.py` | ✅ |
| 同步 pull/push（LWW / 幂等 / 软删除） | `server/app/api/v1/sync.py` + `services/sync_service.py`；`tests/test_sync.py` **48 passed** 真实通过 | ✅ |
| 云端备份三端点 | `tests/test_sync.py` 覆盖（`test_backup.py` 不存在，属 F11，非缺陷） | ✅ |
| 配置下发 `GET /api/v1/config`（B47） | `server/app/api/v1/config.py` 模块注释明写「无需 token / 只读 / `version` 读 `app_config['config_version']` 缺失 → `"0.0.0"` / `pointsDailyCap` 缺失或非整数 → `200`」；`server/app/api/v1/__init__.py:68` 挂载；App 侧 `ServerConfigFetcher.ets:94` 消费 ⇒ **D10-5 闭环** | ✅ |
| 部署脚本 | `server/deploy/` **7 个文件**（`README.md` / `backup-mysql.sh` / `migrate.sh` / `nginx/carbonboo.conf` / `systemd/` 三个 unit） | ✅ 静态语法校验过；**未实跑**（§9） |
| L3 pytest | 全量 **237 passed**（队长）；我复现子集 **35 passed** + **19 passed** | ✅ |

### ③ `/admin` Web 管理后台 — **在，路由全**

`server/admin_web/api.py` 路由全表（实测正则抓取）：`GET/POST /login`、`POST /logout`、`POST /password`、`GET/POST /items`、`PATCH /items/{item_id}`、`POST /items/{item_id}/icon`、`GET /icons/{filename}`、`GET /static/{filename}`、`GET /users`、`GET /overview`、`GET /orders`、`GET/PUT /config`、`GET /logs`、`GET ""`、`GET "/"`。
对 `docs/PLAN.md §13.2` 七项：**登录改口令 ✓ / 商品管理 ✓ / 用户列表 ✓ / 订单 ✓ / 系统配置（GET+PUT，且被 App 真实读取，见 B47）✓ / 操作日志 ✓ / 数据总览 ✓** —— 七项全部有落点，`server/admin_web/templates/` 下 9 个模板（`base/config/items/login/logs/orders/overview/password/users.html`）。
⚠️ **浏览器交互未跑**（SSR + `admin.js`），见 §9。

### 其他 m00004 约束

| 要求 | 实测 | 判定 |
|---|---|---|
| 用 git 管理便于回滚 | `git log` 线性、前缀规范（`feat:`/`fix:`/`docs:`/`test:`/`chore:`）、每次提交单独推送；`git log --oneline -40` 无 merge/force 痕迹 | ✅ |
| 前端要用前端 skill | `/mnt/c/Users/Administrator/.dsh/skills/carbonboo-arkui-ui/SKILL.md` **存在**（Windows home 下；WSL `~/.dsh` 下没有——这是路径口径差异，不是缺失） | ✅ |
| 前端要用**视觉模型** | **全仓 `grep -rn "v4-1-flash\|视觉模型\|visual model"`（排除 build/ 与 .agent-teams/）→ 零命中**；`docs/VERIFICATION.md` 全 904 行无一处提及 | ❌ **见 finding R2** |
| 子代理统一 `deepseek-v4.1-flash`；供应商链 ark > commandcode > workbuddy 免费 > workbuddy 国内版 | 提交作者统一 `CarbonBoo Captain <captain@carbonboo.local>`，部分为 `a3354547604-stack <…@163.com>`；**仓库内无任何可核验的模型/路由痕迹** | ⚠️ **不可核验**，只能作为队长自述采信（§9） |
| 队长只指派、不亲自开发 | 同上前提；`git log` 作者串一致，无区分度 | ⚠️ **不可核验** |

---

## §4 对 `docs/VERIFICATION.md` 每条「通过」的证据审计

该报告的结构是**三态严格**的（`通过` / `失败` / `未运行`），这一点值得肯定：它在 §10.3 用原始输出证明了「无真机 / 无模拟器 / Previewer glibc 崩溃 / `hvigorw test` EXIT=124」，并明确写「**36 个 `it()` 全部是「已编译、未执行」。本报告不把任何一条算作通过。**」——**没有把未运行项算作通过，不构成虚报。**

### 4.1 通过项 V1–V20 逐条判定

| 项 | 声称 | 有无命令 + 原始输出 | 我的判定 |
|---|---|---|---|
| V1 L0 EXIT=0 | 28 检查项 / 82 文件 0 命中 / docConflicts 0 | ✅ 有，且我自己重跑复现同值 | ✅ 采信 |
| V2 基准自检 `18 5 6 31` | 有 | ✅ 有，我实测同值 | ✅ |
| V3 独立复算 70 检查点 | `/tmp/cbv24/ev/recompute.py`（Decimal + `ROUND_HALF_UP`，只读基准 JSON，不调被测代码） | ✅ 有脚本路径 + 输出「失败 0」 | ✅ 采信；**我自己独立复算了一遍**（见 §6.3），结论一致 |
| V4 half-up vs banker's | `half_up(0.005×100)=1` vs `half_even=0`；float 实算 `0.005*100=0.5 → round=0` | ✅ 有 | ✅ |
| V5 float 累加误差 | 1000×0.1920 = `192.00000000000017` | ✅ 有 | ✅ |
| V6 编译门禁 4 组注入 | 全部 EXIT=255 且自定位 | ✅ 有 | ✅ 采信；**我自己独立做了一组成对实验**（§2），一致 |
| V7 import 闭包 108 个 `.ets` | 有 | ✅ | ✅ |
| V8 副本零污染 | md5 与 `git show 308d09f:<path>` 逐字节相同 | ✅ | ✅ |
| V9 「例外集五类之外 0 处残留」 | `grep "四类网络例外\|四类例外"` 唯一命中是报告自身 | ✅ 命令与输出都有 | ❌ **结论不成立**，见 4.2 与 R6 |
| V10–V13 四条铁律 | 文件:行 | ✅ | ✅ 我独立复核一致（§5） |
| V14 未登录态零上传（**静态**） | `NotLoggedIn.test.ets:48/:62` `expect(http.count()).assertEqual(0)`；`SyncService.ets:171-176/:223-228/:272-277` 三处短路在发请求前；`BackupService.ets` 构造参数只有 `(store, state, files)` 无 `HttpPort` | ✅ 有，且**明确标了「静态」** | ✅ 措辞诚实 |
| V15 契约 A/B/C 三方对齐 | 19 表逐名全等；21 表逐列列名全等；类型映射违反 0；因子三向 `30 条逐字段 + CAR_OWN_FACTOR` 全等 | ✅ | ✅ |
| V16 L1 静态核查 | 10 import / 10 调用一一对应 | ✅ | ✅ 我复核一致 |
| V17 48 passed | `test_sync.py` | ✅ | ✅ 我用隔离库跑 `test_config+test_shop` 35 passed 复现同环境可用性 |
| V18 19 passed / 19 deselected | `/admin` 403 子集 | ✅ | ✅ **我重跑复现：19 passed, 66 deselected** |
| V19 规约红线零命中 | `: any` / `@ts-ignore` / SQL in pages | ✅ | ✅ |
| V20 `git status --short` 三次采样相同 | 有 | ✅ | ✅ |

### 4.2 V9 的问题（**这条属于「有输出、有命令，但证据模式选错导致结论过度**）

V9 用的模式是 `grep "四类网络例外\|四类例外"`。我实跑同一模式，唯一命中确实是报告自身的 151/534 行 ——**词面可复现**。但改用宽口径 `grep -rn "四类"` 后，我实测命中 8 处**真残留**（见 §8 R1）：`docs/PLAN.md:95/:118/:143/:620/:935/:1046/:1071`、`docs/adr/0001-account-and-sync.md:17`。这些地方的措辞是「例外仅四类：…」「四类需要服务端」「固定为四类」，**不含「网络例外」四字**，因此被窄模式整批漏过。

⇒ 判定：**V9 的「闭环」判定不成立**。这不是伪造，是**证据模式与结论不匹配**；但它直接导致 t1 的 B21/B42 被过早标 closed。

### 4.3 失败项 F15–F18 与未运行项 N1–N7

| 编号 | 内容 | 判定 |
|---|---|---|
| F15 | `docs/VERIFICATION.md` round 1/2 从未入库（round 3 才由 `39be3b0` 入库） | ✅ 属实；已由 round 3 补上，**现已可审计** |
| F16 | `git archive` 副本跑 `hvigorw test` 假失败（`oh_modules/` 被 `.gitignore:29` 忽略 → `Failed to resolve OhmUrl for "@ohos/hypium"`） | ✅ 属方法学缺陷非代码缺陷，报告已如此定性 |
| F17 | 契约点名的 `PointCap` 套件不存在 | ✅ 属实；5 组封顶由 `CalcSamples.test.ets:78` + `CalcBaselineValidator.ets:210-224` 承载。**这是契约与实现的接口命名偏差，非功能缺失**，判低 |
| F18 | 任务书给的 MySQL 凭据 `root/cbpass123` 仍 1045 拒绝 | ✅ 属实；真实凭据在 `server/.env`（`MYSQL_USER=carbonboo`）。**属任务书侧问题** |
| N1 | L1 全部 36 个 `it()` 未运行（`hdc list targets` → `Connect server failed`；`test -w /dev/kvm` 失败 uid 1000 不在 kvm 组；GLIBC 2.43 Previewer `pthread_mutex_lock` robust 断言崩） | ✅ **如实单列，未算通过** —— 正确 |
| N2 | `hvigorw test` 执行段 `after 19 s 880 ms` 后静默 → `timeout 420` EXIT=124 | ✅ 如实 |
| N3 | L2 端侧集成未跑 | ✅ 如实 |
| N4 | `server/deploy/` 实跑未做（沿用 `bash -n` / `systemd-analyze verify` / `migrate.sh --dry-run` EXIT=0） | ✅ 如实 |
| N5 | `/admin` 浏览器交互未跑 | ✅ 如实 |
| N6/N7 | t18/t13 运行态未验 | ✅ 如实 |

---

## §5 四条铁律在代码中的真实性（文件:行）

| 铁律 | 判定 | 证据 |
|---|---|---|
| **1. 本地优先**（本机 `relationalStore` 唯一真相源；网络仅五类例外） | ✅ **代码成立，文档口径未统一**（见 R1） | 代码：`app/entry/src/main/ets/viewmodel/net/HttpPort.ets:51` `export interface HttpPort`、`:62` `export class HttpClient implements HttpPort`、`:131` `export class FakeHttpClient implements HttpPort` —— 网络出口单一；`:55` `request(req: HttpRequest): Promise<HttpResponse>`；四个消费者 `HttpPort.ets` / `ServerConfigFetcher.ets` / `ShopPriceFetcher.ets` / `SyncService.ets` 全在 `viewmodel/net/`。五类的代码落点：配置下发 `ServerConfigFetcher.ets:94` `` return `${this.http.baseUrl()}/api/v1/config` ``，冷启动 `entryability/EntryAbility.ets` 调 `ServerConfigFetcher`。**文档反例**：`docs/PLAN.md:95`「例外仅四类：登录/注册、多设备同步、商品取价、云端备份」 |
| **2. 单一计算入口**（减排量只能由 `CarbonService.calculate()` 产出） | ✅ | 唯一入口 `app/entry/src/main/ets/service/CarbonService.ets:76` `static calculate(activity: ActivityInput, factor: FactorSnapshot, options?: CalcOptions): CarbonCalculation`，算数底座在 `service/CarbonCalc.ets`：`:153` `const product: Dec = Dec.from(amount).mul(Dec.from(factorValue));` + `:154` `roundHalfUp(REDUCTION_DECIMALS)`（减排量）；`:164` `Dec.from(reductionKg).mul(Dec.fromInt(rate)).toInt()`（应得 C）；`:258`/`:267` 是**单位换算**（`天数×8.0 km`、`件数×0.5 kg`）而非因子乘法。页面/组件层：`grep -rn "SELECT \|INSERT INTO" pages/ components/` **零命中**；页面层唯一乘法是 `AppearancePage.ets:82-83/:144` 的 `AppTheme.AVATAR_SIZE * 0.72` 尺寸运算，**无因子乘法** |
| **3. 因子快照**（落库写 `factor_value`/`factor_version`/`factor_source`/`confidence`，升级永不回写历史） | ✅ | `app/entry/src/main/ets/data/schema/ClientSchema.ets:85-88` 四列均为 `NOT NULL`；快照构造点 `service/CarbonService.ets:187` `static snapshotOf(...)`，调用处 `viewmodel/RecordService.ets:149/:306/:367`（`:149` `CarbonService.snapshotOf(item.value, version, item.source, item.confidence)`，紧接 `:151` 用其调 `CarbonService.calculate`）；全仓 `grep "UPDATE carbon_record SET factor"` 零命中（无回写路径） |
| **4. 积分单向可追溯**（余额 = 收入 − 支出；流水只增不删；只能经 `PointService` 写入） | ✅ | 全 `app/` + `server/` `grep -rn "UPDATE point_record\|DELETE FROM point_record"` → **零命中**；唯一写入 `viewmodel/PointService.ets:153` `INSERT OR IGNORE INTO point_record`；冲正走负额新行 `PointService.ets:190 reverse()`、`:196` `points: -points`；余额聚合三处同口径 `COALESCE(SUM(points), 0)`：`PointService.ets:91`、`SyncService.ets:362`（成员）、`:377`（合计）——**这正是 t21 F1 修复后的形态，`CASE WHEN flow_kind` 二次取负已归零**（执行代码 0 命中，唯一 1 处在 `:342` 历史注释） |

---

## §6 AGENTS §5 红线与 git 历史抽查（**结论：未发现违规**）

方法：`for c in $(git log --format=%h --reverse); do git show $c | grep -cE '^-.*(expect\(|assert)'; done` —— 全历史逐提交扫描「被删除的断言行」，**只有 3 个提交命中**。

### 6.1 `797832f`（1 行）—— **不是放宽，是陈旧断言对齐既有基准**

```
- expect(bench.factors.length).assertEqual(30);
+ expect(bench.boundarySamples.length).assertEqual(6);
+ expect(bench.factors.length).assertEqual(31);
```
- 时序：`git merge-base --is-ancestor e2972b7 797832f` → **是祖先**。基准 `factors` 早在 `e2972b7`（2026-10-16）就已由 21 改 31（B36 授权的 10 条 `recording:false` 对照镜像）；`797832f` 只是把**落后于基准的断言**对齐，并**新增**一条 `boundarySamples = 6` 断言 ⇒ **断言总数 +1，强度不降**。
- 提交正文 45–47 行明写理由（`… 但基准 factors 实际 31 条（30 条因子 + 换算常量 CAR_OWN_FACTOR，A §2.5 原文）→ 改为 31`）。
- 判定：**不构成 §5 违规**。

### 6.2 `7e3e969`（7 行，`test(server): 移除会给 t5/t6 埋雷的跨切片断言与恒真断言`）—— **不是删断言，是删掉「断言未来切片不许存在」和恒真断言**

删除的 7 行：
```
- assert all(name != "is_available" for name, _ in calls) or True          # ← `or True` 恒真，永不失败
- assert not (SERVER_DIR / "app" / "admin").exists()
- assert not (SERVER_DIR / "templates").exists()
- assert not (SERVER_DIR / "static").exists()
- for name in ("sync.py", "shop.py", "backup.py"):
-     assert not (SERVER_DIR / "app" / "api" / "v1" / name).exists()
- assert (SERVER_DIR / "admin_web").joinpath("mount.py").exists() is False
- assert Path(SERVER_DIR / "app" / "services" / "auth_provider.py").exists()
```
新增（净增强度）：
```
+ assert len(calls) == 6                                    # 把恒真改成真断言：六接口全经抽象转发
+ assert provider_module.exists()
+ assert "class AuthProvider" in provider_module.read_text(encoding="utf-8")
```
- **时序是决定性的**：`git ls-tree -r --name-only 7e3e969 -- server/app/api/v1/` → 只有 `__init__.py` 与 `auth.py`；t5 的 `a2a2b51` 在 22:58、t6 的 `0931112` 在 23:51 才创建 `sync/shop/backup/admin_web`。被删的是「**断言下游切片的产品尚不存在**」这种方向错误的断言——它会让 t5/t6 的 verify 必然打红；用例已改名 `test_auth_provider_module_is_the_only_identity_implementation` 并在 docstring 注明「**不要**在这里断言 "sync.py/shop.py/backup.py/admin_web 不存在" —— t5/t6 会创建它们，那样等于给下游切片埋雷」。
- 判定：**不构成 §5 违规**（删的是恒真断言与范围外的目标性断言，删后**断言强度上升**）。⚠️ 但该提交**未在 `docs/CHANGELOG.md` / `tests/README.md` 留痕**，属可追责性瑕疵，见 R7。

### 6.3 `447e5e6`（8 行）—— **实为改写，断言强度上升**

```
- expect(res.data === undefined ? -1 : res.data).assertEqual(0);
+ expect(res.data === undefined ? -1 : res.data.pulled).assertEqual(0);      # ×3，返回结构由数字改为对象
- expect(numOf(after, 'amount')).assertEqual(5);          → + assertEqual(77)
- expect(textOf(after, 'device_id')).assertEqual('dev-aaa') → + 'dev-zzz'
```
同提交**新增 28 条 `expect(...)`**（`res2`/`res3` 三条链、`backupCalls === 3`、`pushOrPull === 0`、`authed === 3`、`LAST_SYNC_AT === 424242` 等）。提交正文 400+ 行说明改前证据，并**自捕**「旧 ①–⑤/⑨ 用 `fullRestore` 驱动 LWW 断言会「通过但什么都没测到」的假绿，已改为 `driveLww()` 走真实 `sync()`」。
我另核 `LwwMerge.test.ets:440-484`：改后的期望与 `SyncService.ets:622-668` 的平局裁决实现（`rUpdated === lUpdated` → `remoteDevice > localDevice` 取远端，否则保留本机）**逐条语义对应**，不是为了让变绿而改。
判定：**不构成 §5 违规**。

### 6.4 跳用例 / 期望值史

- `grep -rn "pytest.skip\|pytest.mark.skip\|xfail" server/tests/` → 唯一命中是 `conftest.py` 的形参名 `skip_db_statements`（跳过 `CREATE DATABASE`/`USE` 语句，不适用例）⇒ **0 个真跳过**。
- `grep -rn "\.skip(\|describe.skip\|\.only(" app/entry/src/ohosTest/` → **0 命中**。
- 基准期望值：按 `git log -- tests/cases/carbon-calc.json` 的 11 个提交逐个算哈希 —— `samples` 期望值 hash 恒为 `9070b787`、`capSamples` 恒为 `6bc711c9`（**自初始 `5f751c4` 起从未变**）；`factors` 的 `(key, value)` hash 只在 `e2972b7` 由 `1bda0042` → `a3920cc1`，逐 key 比对：**21 个共有 key 的 value 无任何变化**，只新增 10 个 key（`car`/`elec_gas`/`elec_thermal`/`flight`/`hsr`/`kitchen_waste`/`motorcycle`/`textile`/`water_treat`/`wood`）。
- 我另做一遍**独立复算**（`decimal.Decimal` + `ROUND_HALF_UP`，只读基准 JSON、不调被测代码）：18 组正向 `reduction = round_half_up(amount × factor, 4)` 与 `C = round_half_up(kg × 100, 0)` → **fails = 0**；5 组封顶 `A = max(0, min(C, 200 − D))`（`countsTowardCap: false` 时不封顶）→ **fails = 0**。

⇒ **判定：未违反 AGENTS §5「不得为让测试通过而改期望值 / 删断言 / 跳过用例」，不判 `reject`。**

---

## §7 已知局限（必须原样交代，不许圆场）

1. **L1 全部 36 个 `it()` 一条都没跑过。** 本机 `hdc list targets` → `Connect server failed`；`test -w /dev/kvm` 失败（uid 1000 不在 kvm 组）；SDK Previewer 与 GLIBC 2.43 不兼容（`Fatal glibc error: pthread_mutex_lock.c:426 __pthread_mutex_lock_full: Assertion 'e != ESRCH || !robust' failed`）；`hvigorw test` 执行段 `Finished :entry:default@UnitTestArkTS... after 19 s 880 ms` 之后静默 → `timeout 420` EXIT=124。
   ⇒ **编译通过 ≠ 用例通过。本报告不把任何一条 L1 用例算作通过。**
2. **L2 端侧集成未跑**（需两台设备 / 真机 + 模拟器）。
3. **`server/deploy/` 未实跑**（只做 `bash -n` / `systemd-analyze verify` / `migrate.sh --dry-run`）。
4. **`/admin` 浏览器交互未跑**（SSR 页面与 `admin.js` 的实际渲染/交互只经 HTTP 状态码与 L3 覆盖）。
5. **全量干净构建未做**（见 §2 第 3 点：两次 `assembleHap` 都是增量）。
6. **不可核验项**：①子代理是否统一 `deepseek-v4.1-flash`；②队长是否只指派、不亲自开发；③各轮供应链路由（ark > commandcode > workbuddy）实际使用情况。仓库内**无任何可核验痕迹**（`git log` 作者串统一为 `CarbonBoo Captain <captain@carbonboo.local>`，部分为 `a3354547604-stack <…@163.com>`），只能作为队长自述采信，**不列入 defect**。
7. `/tmp/cbv24/` 下的验证证据（V3/V6/V7 的脚本与输出）**未入库**，属易失证据；round 1/2 的报告原本也只在本机 `/tmp`（F15），round 3 才入库。建议后续把 `tests/tools/` 下的复算脚本纳入版本管理。

---

## §8 Findings（结构化）

```json
[
  {
    "id": "R1",
    "severity": "medium",
    "problem": "网络例外集口径在仓库内仍有两套：AGENTS.md 为「五类」（含配置下发），但 docs/PLAN.md 七处、docs/adr/0001 一处、以及基准 tests/cases/carbon-calc.json 的 B21/B42 正文仍是「四类」。这不是措辞差异——PLAN:1046 的 A2 验收标准本身就是「除四类外全部功能可用」，而代码实现的是五类（配置下发会发请求），照 A2 断网验收会得到与契约不一致的预期。t1 曾以 B21「全仓统一」、t21 以 F3「五类闭环」结案，两次的范围都只在 AGENTS.md 内成立。直接命中 AGENTS.md §1.3「两份文档对同一…不一致 → 立刻停止」。",
    "file": "docs/PLAN.md",
    "line": 95,
    "requiredFix": "先定口径（建议五类，与 AGENTS §2 铁律 1 和代码一致），再一次性改齐：docs/PLAN.md:95/:118/:143/:620/:935/:1046(A2 验收标准)/:1071(R2)、docs/adr/0001-account-and-sync.md:17、AGENTS.md:61（B42 描述句补「t21 起五类」的现行口径）、docs/CHANGELOG.md:34 与 docs/DECISION-0002-doc-contract-errata.md:22（历史行可保留但须加「后经 t21 补为五类」注）、tests/cases/carbon-calc.json:783(B21) 与 :951(B42) 的 correct 正文。改完重跑 python3 tests/tools/check_l0.py --strict 并确认 EXIT=0。"
  },
  {
    "id": "R2",
    "severity": "medium",
    "problem": "用户 m00004 明示「前端子代理须有前端 skill 与视觉模型」，其中前端 skill 已满足（~/.dsh/skills/carbonboo-arkui-ui/SKILL.md 存在且被用于 app/ 开发），但**视觉模型一项从未达成，且未在任何交付物中声明未达成**：全仓（排除 build/ 与 .agent-teams/）grep 「v4-1-flash|视觉模型|visual model」零命中，docs/VERIFICATION.md 全 904 行无一处提及。VERIFICATION.md 对「没跑」的项（L1/L2/deploy/admin）都做了三态如实单列，唯独漏掉这条用户明示要求，属「选择性沉默」。",
    "file": "docs/VERIFICATION.md",
    "line": 900,
    "requiredFix": "两条路选一并在交付物里写清：(a) 补做视觉走查——用可用的视觉模型对 18 个页面截图逐页核对附录 C 的视觉契约，把原始输出/截图路径写进 VERIFICATION.md；(b) 若确认无法获得（ark 的 deepseek-v4-1-flash-260910 额度冻结），在 docs/VERIFICATION.md 的「未运行项」表中新增一条 N8「视觉模型走查：未做，原因 <原文错误信息>」，并在最终的交付说明里显式告知用户这一条未满足。不得以沉默代替声明。"
  },
  {
    "id": "R3",
    "severity": "low",
    "problem": "docs/VERIFICATION.md 的 V9 用窄模式 grep \"四类网络例外\\|四类例外\" 得出「全仓仅剩报告自身命中 ⇒ 五类闭环」的结论。该模式漏掉了改用词的真残留（「例外仅四类：」「四类需要服务端」「固定为四类」等 8 处，见 R1）。命令与输出都真实，但证据模式与结论不匹配，导致 t1 的 B21/B42 被过早标 closed。",
    "file": "docs/VERIFICATION.md",
    "line": 151,
    "requiredFix": "把 V9 的判据从「精确短语 grep」改为「语义覆盖 grep」（如 grep -rn \"四类\" docs/ AGENTS.md 再逐条人工判定是否为例外集语境），并在 VERIFICATION.md 里附宽口径的原始输出；同时把该条从「闭环」改为「部分闭环（AGENTS.md 内闭环，PLAN/ADR 未跟进）」。"
  },
  {
    "id": "R4",
    "severity": "low",
    "problem": "文档落盘路径与仓库实际不符（B43 同型漏网，B43 只修了 AppTheme 那一处）：docs/APPENDIX-C-ui-screens.md:158 写「落盘路径：app/entry/src/main/ets/view/components/」，但 app/entry/src/main/ets/ 下没有 view/ 目录（实为 components/）；docs/PLAN.md:143 写「全应用唯一网络出口：common/HttpClient.ets」，但 app/entry/src/main/ets/common/ 不存在（唯一出口实为 app/entry/src/main/ets/viewmodel/net/HttpPort.ets，其中 :51 接口 HttpPort、:62 类 HttpClient、:131 类 FakeHttpClient）。这类路径错误会让下游 agent 按文档新建目录，直接造成目录结构分叉。",
    "file": "docs/APPENDIX-C-ui-screens.md",
    "line": 158,
    "requiredFix": "docs/APPENDIX-C-ui-screens.md:158 改为 app/entry/src/main/ets/components/；docs/PLAN.md:143 改为 app/entry/src/main/ets/viewmodel/net/HttpPort.ets（并注明类名 HttpClient 在该文件内）。docs/PLAN.md:237 架构图里的 HttpClient 是类名不是路径，无需改。改完 grep -rn \"ets/view/\\|common/HttpClient\" docs/ 应为零命中。"
  },
  {
    "id": "R5",
    "severity": "low",
    "problem": "tests/README.md:44 仍写「包含：21 个因子（20 个可录入 + CAR_OWN_FACTOR）」，而基准实测 factors=31（30 条 + CAR_OWN_FACTOR），APPENDIX-A §2.5 也已写死 31 项。B36 改了基准与附录 A，漏了 tests/README.md。虽然不影响任何断言（L0 不校验此句），但它是「测试基准说明书」，写错会误导后来者按 21 条去核。",
    "file": "tests/README.md",
    "line": 44,
    "requiredFix": "改为「31 项 = 30 条因子（20 条 recording:true + 10 条 recording:false 对照镜像）+ 换算常量 CAR_OWN_FACTOR」。注意 tests/ 不在本评审的写入范围，须由可写该目录的成员执行。"
  },
  {
    "id": "R6",
    "severity": "low",
    "problem": "7e3e969 删了 7 行断言（其中 1 条是 `or True` 恒真断言，另 6 条是「断言下游切片产品尚不存在」的目标性断言），改名并加重了断言，行为本身合规；但该提交未在 docs/CHANGELOG.md 或 tests/README.md 留痕，后续审计者只能靠读 git show 才知道历史上曾存在这些断言。AGENTS.md §9 要求「新发现的缺陷…在 docs/CHANGELOG.md 记一行」，删断言这类动作同样应有可追溯记录。",
    "file": "docs/CHANGELOG.md",
    "line": 1,
    "requiredFix": "在 docs/CHANGELOG.md 补一行：2026-10-16 / 7e3e969 / test(server) 移除「断言下游切片文件不存在」的跨切片断言与 `or True` 恒真断言，改为断言 len(calls)==6 与 AuthProvider 单实现 / 理由：跨切片断言会让 t5/t6 的 verify 必红。"
  },
  {
    "id": "R7",
    "severity": "low",
    "problem": "server/.env 权限为 555（stat -c '%a' 实测），AGENTS.md §6 要求「密钥只进 .env（600）」。该文件已被 server/.gitignore:2 忽略（git check-ignore 确认，git ls-files 只有 .env.example），未泄进仓库，所以只是本机运维卫生问题，不构成泄密。",
    "file": "server/.env",
    "line": 1,
    "requiredFix": "chmod 600 server/.env；顺带 chmod 600 也适用于任何后续生成的密钥文件。不需改代码。"
  },
  {
    "id": "R8",
    "severity": "low",
    "problem": "契约点名的 PointCap 测试套件不存在（F17/沿用 F10）：附录 D 与 tests/README 用 PointCap 作为封顶 5 组的承载名，实际由 CalcSamples.test.ets:78 的 expect(bench.capSamples.length).assertEqual(5) 加 CalcBaselineValidator.ets:210-224 承载。功能不缺，缺的是「契约名字 ↔ 文件」的对应关系，验收时按名字找会找不到。",
    "file": "tests/README.md",
    "line": 75,
    "requiredFix": "在 tests/README.md 的套件表里把 PointCap 一行改为「封顶 5 组（无独立套件，由 CalcSamples.test.ets + CalcBaselineValidator.ets 承载）」，或在附录 D/PLAN 的契约清单里同步更名，二者择一即可。"
  }
]
```

### 分级说明

- **blocker / high：0 条。** 没有发现红线违规、没有测试造假、三部分实体齐备、L0 EXIT=0、编译门禁真实。
- **medium：2 条（R1、R2）。** R1 是「文档契约冻结」这一前置结论的反例且命中 §1.3；R2 是用户明示要求未达成且未声明。
- **low：6 条（R3–R8）。** 记录质量、路径勘误、运维卫生、契约命名。

---

## §9 放行建议

三部分本身**已具备交付实体**；阻断 `pass` 的不是功能缺失，而是**契约与声明的完整性**。建议按以下顺序收口，再复审：

1. **必须**（放行前置）：修 R1（例外集口径一次性改齐，重跑 L0 到 EXIT=0）与 R2（视觉模型——补做，或在 VERIFICATION 里作为 N8 显式声明未满足并告知用户）。
2. **应当**：修 R3（把 V9 的判据换成语义覆盖，并把结论降级为「部分闭环」）、R4（两处落盘路径）、R5（31 项）。
3. **可选**：R6（补 CHANGELOG 留痕）、R7（`chmod 600`）、R8（套件命名对齐）。
4. **交付说明中必须向用户显式交代的局限**（不得粉饰）：L1 全部 36 个 `it()` 未运行、L2 未跑、`server/deploy/` 未实跑、`/admin` 浏览器交互未跑、无全量干净构建、视觉模型未达成、模型路由与分工不可核验。

> 本报告不修改任何被测源码与规格文档；R1–R8 的 `requiredFix` 须由拥有对应写入范围的成员执行。
