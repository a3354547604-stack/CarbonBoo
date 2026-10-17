# 交付复评报告（round 2）· CarbonBoo（赛题二）

> 评审人：reviewer-cn（AgentTeams 成员，交付评审员）
> 本轮评审对象：**t28 修复轮**（承接 t8 评审的 R1–R8），提交 `030eb0c` / `154f0e6` / `b5c7110` / `fccf524`
> 本轮基准 commit（**完整 40 位**，`git rev-parse HEAD` 实跑）：
> `fccf5245c6c61b337287b4d9e04ebf573f5f8bcb`
> 推送证据（`AGENTS.md §5.1-4` 唯一合格证据，原文照录）：
> ```
> $ git ls-remote origin main
> fccf5245c6c61b337287b4d9e04ebf573f5f8bcb	refs/heads/main
> $ git rev-parse HEAD
> fccf5245c6c61b337287b4d9e04ebf573f5f8bcb
> ```
> 上一轮评审（t8）的基线：`9d73de043ba1fec90cf252f5c9b7a37970f87334` → `9d73de4`（本人评审提交，含 343 行评审与 R1–R8）
> 本报告只写本文件；**未修改任何被测源码与规格文档**。开工时 `git status --short` **输出为空**（工作树干净），写完后只有 ` M docs/REVIEW.md`。

---

## §0 结论

**verdict = `pass`**

一句话：**t8 的 8 条 findings 中，R1/R2/R3/R4/R5/R6/R8 七条经本轮逐条复核确认为真闭环（不是把 status 翻成 closed、也不是只看 diff）；R7 按 outOfScope 正确地没有动；数值真相源经程序化逐键比对确认「除 `docConflicts` 的 B21/B42 两段 `correct` 文本外零改动」；L0 门禁 `$?` 单独捕获为 EXIT=0；四个提交零触碰 `app/`、`server/`、`tests/tools/`。**
本轮**新发现**一条 t28 引入的低危问题（O1：`ohosTest` 基准副本未随基准同步，导致离线复算门禁第 0 项 FAIL），不影响任何数值断言、不影响交付功能，故不据此判 `needs_revision`，但必须列报并留待有 `app/` 写入窗口时一行修掉。

不判 `needs_revision` 的理由：R1 是上一轮唯一的 medium 级契约冲突（`AGENTS.md §1.3` 停手条件），本轮已用宽口径全局核实到「例外集语境 8 处全部五类 + 保留失败降级半句，剩余 16 行全部为非例外集语境」；R2 是另一条 medium（用户 m00004 视觉模型要求），本轮已按「未运行 + 明写未满足 + 原始输出贴全」三件套落账，不再属于「未声明」。没有 blocker / high。
不判 `reject` 的理由：本轮改动全在文档与基准 `docConflicts` 文本，无任何测试期望值、断言、用例被削弱（见 §6）。

---

## §1 复核范围与本次实跑清单

### 1.1 改动范围（`git diff --name-status 9d73de4..HEAD` 原文）

```
M	docs/APPENDIX-C-ui-screens.md
M	docs/CHANGELOG.md
M	docs/PLAN.md
M	docs/VERIFICATION.md
M	docs/adr/0001-account-and-sync.md
M	tests/README.md
M	tests/cases/carbon-calc.json
```

```
$ git diff --stat 9d73de4..HEAD -- app/ server/ tests/tools/ | wc -l
0
```
⇒ **被测代码零改动**，故本轮按任务书要求**不重跑全量 L3**（server/ 零 diff，全量 L3 结论不因本轮而变）。

四个提交的实际分工（`git show --stat` 实跑）：

| 提交 | 文件数 | 行数 | 主题 |
|---|---|---|---|
| `030eb0c` | 3 | +9 / −9 | R1（例外集四类→五类，PLAN 6 处 + ADR 1 处）+ R4（两处落盘路径） |
| `154f0e6` | 1 | +2 / −2 | R5（因子口径 21→31）+ R8（PointCap 行改写） |
| `b5c7110` | 1 | +11 | R6（`7e3e969` 补记）+ CHANGELOG §9 |
| `fccf524` | 2 | +154 / −6 | R2（N8 视觉走查）+ R3（V9 判据勘误）+ B21/B42 登记补正 |

### 1.2 本轮我本人实跑的清单（可复现，原始输出见下文各节）

| # | 命令 | 结果 |
|---|---|---|
| 1 | `git rev-parse HEAD` + `git ls-remote origin main` | 两值相同 = `fccf524…`（§0） |
| 2 | `git diff --name-status 9d73de4..HEAD` | 7 文件全 M，全为文档/基准（§1.1） |
| 3 | `grep -rn "四类" docs/ AGENTS.md tests/cases/carbon-calc.json --exclude=REVIEW.md --exclude=VERIFICATION.md` | **16 行**（§2.2） |
| 4 | `git grep -n "四类" 9d73de4 -- docs AGENTS.md tests ':!docs/REVIEW.md' ':!docs/VERIFICATION.md'` | **20 行**（§2.1，修复前基线） |
| 5 | 逐行读 `docs/PLAN.md:95/:118/:143/:620/:935/:1046/:1071`、`docs/adr/0001-account-and-sync.md:17` 原文 | 8 处均五类（§2.3） |
| 6 | `python3` 载入 `9d73de4` 与 HEAD 两份基准 JSON 逐键比对 | 数值区 7 键全 identical（§6） |
| 7 | `md5sum tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json` | `e096b2db…` vs `c096da45…`（§7） |
| 8 | `node /tmp/cbverify/verify.mjs` | 第 0 项 **FAIL**（副本漂移），`VERIFY_EXIT=1`（§7） |
| 9 | `python3 tests/tools/check_l0.py --strict > log 2>&1; L0=$?` | **L0_EXIT=0**（§8） |
| 10 | `sed -n` 逐行核对 R2/R3/R4/R5/R8 落点原文 | 全部改到位（§3–§5） |
| 11 | `stat -c '%a %n' server/.env` | `555`（R7 未修，如预期，§5.4） |

---

## §2 R1（medium）例外集口径：四类 → 五类 — **真闭环**

### 2.1 修复前基线（`9d73de4`，宽口径，20 行）

```
$ git grep -n "四类" 9d73de4 -- docs AGENTS.md tests ':!docs/REVIEW.md' ':!docs/VERIFICATION.md'
9d73de4:AGENTS.md:61: … 例外集补齐为**四类**（登录/注册、多设备同步、商品取价、云端备份）…
9d73de4:AGENTS.md:66: … B47 … 统一为五类，本文件内不再存在「四类」口径）
9d73de4:AGENTS.md:247: | 2026-11-06 | **v4.2 文档契约勘误**：… §6 未登录例外集补齐为四类 …
9d73de4:docs/APPENDIX-D-acceptance.md:48: … 4 根柱 = 该月四类减排量 …
9d73de4:docs/APPENDIX-D-acceptance.md:538: > 四类之和必须等于总减排：`21.6000 + 14.0400 + 13.5000 + 12.6000 = 61.7400`；
9d73de4:docs/APPENDIX-E-demo-script.md:67: … 柱状图对比四类行为的贡献 …
9d73de4:docs/APPENDIX-E-demo-script.md:134: … 覆盖出行、水电燃气、旧物回收、光盘行动四类共三十个因子 …
9d73de4:docs/CHANGELOG.md:34: … 例外集由三项补齐为**四类**（登录/注册、多设备同步、商品取价、云端备份）…
9d73de4:docs/CHANGELOG.md:39: … 四类改为 出行 ≈0.30 / 节水节电 ≈0.…
9d73de4:docs/DECISION-0002-doc-contract-errata.md:22: | D5 | `AGENTS.md §6` 未登录例外集补齐为**四类** …
9d73de4:docs/PLAN.md:95: … 例外仅四类：登录/注册、多设备同步、商品取价、云端备份 …      ← 真缺陷
9d73de4:docs/PLAN.md:118: … 除「登录/注册…云端备份」四类外全部功能必须可用 …            ← 真缺陷
9d73de4:docs/PLAN.md:143: … 仅用于**登录/注册、多设备同步、商品取价、云端备份**四类 … ← 真缺陷
9d73de4:docs/PLAN.md:375: | F2-2 | 柱状图：分类减排对比 | F | 四类并列 |
9d73de4:docs/PLAN.md:620: … 只有「登录/注册、多设备同步、商品取价、云端备份」四类需要它 … ← 真缺陷
9d73de4:docs/PLAN.md:935: … 只有「…云端备份」四类需要服务端 …                          ← 真缺陷
9d73de4:docs/PLAN.md:1071: … **除上述四类外客户端不依赖服务端** …                    ← 真缺陷
9d73de4:docs/adr/0001-account-and-sync.md:17: - 铁律 1 的例外集固定为四类：**登录/注册、多设备同步、商品取价、云端备份**。 ← 真缺陷
9d73de4:tests/cases/carbon-calc.json:955: "correct": "… 除「登录/注册、多设备同步、商品取价、云端备份」四类 …   ← 真缺陷（**B42.correct**）
9d73de4:tests/cases/carbon-calc.json:971: "correct": "… 四类 21.6000/14.0400/13.5000/12.6000 …"        ← 减排分类，非缺陷
```
20 行；其中**例外集语境 8 处**（`docs/PLAN.md` 6 处 = `:95`/`:118`/`:143`/`:620`/`:935`/`:1071`，`docs/adr/0001-account-and-sync.md:17` 1 处，`tests/cases/carbon-calc.json:955` 即 **B42.correct** 1 处）；其余 12 行为减排分类语境或历史留痕。
注意：**B21.correct 不在这 20 行里**——它的旧原文写的是「网络例外仅**四项**」，从未含「四类」（故需靠 §2.3 末尾那次宽口径外的自查才抓得到，见 O2）。

### 2.2 现状（HEAD，宽口径，16 行；行数由 20 降到 16 的原因见 §2.4）

```
$ grep -rn "四类" docs/ AGENTS.md tests/cases/carbon-calc.json \
    --exclude=REVIEW.md --exclude=VERIFICATION.md
docs/APPENDIX-D-acceptance.md:48
docs/APPENDIX-D-acceptance.md:538
docs/APPENDIX-E-demo-script.md:67
docs/APPENDIX-E-demo-script.md:134
docs/CHANGELOG.md:34
docs/CHANGELOG.md:39
docs/CHANGELOG.md:97
docs/CHANGELOG.md:100
docs/CHANGELOG.md:103
docs/DECISION-0002-doc-contract-errata.md:22
docs/PLAN.md:375
AGENTS.md:61
AGENTS.md:66
AGENTS.md:247
tests/cases/carbon-calc.json:955
tests/cases/carbon-calc.json:971
→ wc -l = 16
```

### 2.3 逐行语境判定（**这是本轮判定 R1 的核心，不是看 diff**）

| 出处 | 语境 | 判定 |
|---|---|---|
| `docs/APPENDIX-D-acceptance.md:48` | 减排分类：D2-2「4 根柱 = 该月四类减排量」 | 非例外集，**正确** |
| `docs/APPENDIX-D-acceptance.md:538` | 减排分类：「四类之和必须等于总减排 `21.6000 + 14.0400 + 13.5000 + 12.6000 = 61.7400`」 | 非例外集，**正确** |
| `docs/APPENDIX-E-demo-script.md:67` | 减排分类：旁白「柱状图对比四类行为的贡献」 | 非例外集，**正确** |
| `docs/APPENDIX-E-demo-script.md:134` | 减排分类：「覆盖出行、水电燃气、旧物回收、光盘行动四类共三十个因子」 | 非例外集，**正确** |
| `docs/PLAN.md:375` | 减排分类：F2-2「柱状图：分类减排对比 → 四类并列」 | 非例外集，**正确（未动是对的）** |
| `docs/CHANGELOG.md:34` / `:39` | 历史留痕（v4.2 当轮记录「由三项补齐为四类」「四类改为…」） | 历史记录，**正确** |
| `docs/CHANGELOG.md:97` / `:100` / `:103` | t28 本轮**新写**的收尾登记，自述「曾经是四类」 | 新增文本，**正确** |
| `docs/DECISION-0002-doc-contract-errata.md:22` | 历史决策留档（D5，记录 v4.2 当时的决定） | 历史记录，**正确** |
| `AGENTS.md:61` | B42 条目：同句已写「**t21 起再补「配置下发」→ 五类**（与 B47 同组，见 §5.1）」 | 历史留痕+补丁，**正确** |
| `AGENTS.md:66` | B47 条目：「t21 已把…统一为五类，本文件内不再存在「四类」口径」 | 自述，**正确** |
| `AGENTS.md:247` | 变更日志 v4.2 行 | 历史记录，**正确** |
| `tests/cases/carbon-calc.json:955` | B42.correct，命中处是句尾自述「本条原文的『四类』于 t28 一并改五类」 | 自述，**正确** |
| `tests/cases/carbon-calc.json:971` | B44.correct 减排分类「四类 21.6000/14.0400/13.5000/12.6000」 | 非例外集，**正确** |

⇒ **16 行里 0 行是「例外集语境的当前口径」**。

### 2.4 例外集语境 8 处：逐行读原文（原文摘录，确认「五类」且保留「失败降级」半句）

- `docs/PLAN.md:95`：「…任何必做功能**不得依赖网络或登录态**；例外仅**五类**：登录/注册、多设备同步、商品取价、云端备份、配置下发（`GET /api/v1/config`，与取价同组；五类均带失败降级，只影响数据新鲜度，不影响可用性）」
- `docs/PLAN.md:118`：「…**除「登录/注册 / 多设备同步 / 商品取价 / 云端备份 / 配置下发」五类外全部功能必须可用**；五类都带失败降级（取价失败 → 内置默认价，配置下发失败 → 内置种子），故「例外」只影响这五类的数据新鲜度，不影响其他可用性（例外集与 `AGENTS.md` §2、ADR-0001 一致）」
- `docs/PLAN.md:143`：「仅用于**登录/注册、多设备同步、商品取价、云端备份、配置下发**五类（未登录不发起任何请求），**全应用唯一网络出口**：`app/entry/src/main/ets/viewmodel/net/HttpPort.ets`（`HttpClient` 是该文件内的类名，见 `HttpPort.ets:62`）」← R4 也在这一行闭环
- `docs/PLAN.md:620`：「**服务端是必做件**（账号 + 同步 + 取价 + 备份 + 配置下发，见 ADR-0001）；…只有「登录/注册、多设备同步、商品取价、云端备份、配置下发」五类需要它（五类均带失败降级，取不到即用内置值）。**唯一可选件是服务端上的 Web 后台管理端（`/admin`）。**」
- `docs/PLAN.md:935`：「…只有「登录/注册、多设备同步、商品取价、云端备份、配置下发」五类需要服务端（五类均带失败降级：取价失败 → 内置默认价，配置下发失败 → 内置种子；铁律 1 与 §1.2）」
- **`docs/PLAN.md:1046`（A2 断网验收的执行依据，本轮重点核对）**：
  现状原文：`| A2 | 飞行模式下，除「登录/注册、多设备同步、商品取价、云端备份、配置下发」**五类**外全部功能可用；五类均带失败降级（取价失败 → 内置默认价，配置失败 → 内置种子），故断网只影响这五类的数据新鲜度，不影响其他可用性 | 断网完整走一遍 |`
  修复前原文（`git show 9d73de4:docs/PLAN.md | sed -n '1046p'` 实测）：`| A2 | 飞行模式下，除「登录/注册、多设备同步、商品取价、云端备份」外**全部功能可用** | 断网完整走一遍 |`
  ⇒ **已改，且改后与代码一致**（客户端登录后会拉 `GET /api/v1/config`，按四类验收会得出与实现相反预期）
- `docs/PLAN.md:1071`（R2 风险表）：「登录、同步、取价、云端备份与配置下发不可用（均有失败降级，只损失数据新鲜度）… **除上述五类外客户端不依赖服务端**，准备离线降级脚本（附录 E §5）」
- `docs/adr/0001-account-and-sync.md:17`：「铁律 1 的例外集固定为**五类**：…（第五类 `GET /api/v1/config` 于 2026-11-07 由 B47 冻结，免鉴权、与取价同组；口径与 `AGENTS.md` §2 铁律 1 / §5 L2 / §6、`PLAN.md` 各节一致）。五类均带失败降级（取价失败 → 内置默认价，配置下发失败 → 内置种子），故「例外」只影响这五类的数据新鲜度，不影响其他可用性。」

行数账：20（修复前）− 8（例外集语境已改五类）+ 3（`docs/CHANGELOG.md:97/:100/:103` 本轮新写的收尾登记自述）+ 1（`tests/cases/carbon-calc.json:955` B42.correct 改写后仍含「四类」自述）= **16**，与实测一致。这一算术是本报告自己算的，用于确认「16 行不是漏改留下的」。

**追加自查（任务书未要求，宽口径 `grep "四类"` 抓不到的同类残留）**：
- `AGENTS.md:71`（B21 条目）仍写「未登录 = 纯单机，网络例外仅**四项**」——它是同一批口径里唯一未被本轮修复覆盖的「当前口径残留」，位于 §1.4「已清零」清单内；`AGENTS.md` 不在 t28 的 write scope，故列为低危观察 **O2**（§9），不据此判 needs_revision。
- `docs/CHANGELOG.md:116`（v4.1 段「可依赖网络的例外**仅四项**」）= 历史留痕，正确。
- 其余「四项 / 三项」命中（`docs/APPENDIX-B-data-and-api.md:901`、`docs/APPENDIX-D-acceptance.md:209`、`docs/APPENDIX-E-demo-script.md:135`、`docs/APPENDIX-F-compliance.md:15/:16`、`docs/CHANGELOG.md:68/:110`、`docs/DECISION-0003-…:29`、`AGENTS.md:66`、基准 B39.bad / B42.bad / B47.correct）**全部是无关语境**（未决项四项 / 后台三项配置 / 四项创新拓展）。
- 全仓 `grep -rn "六类"` → **0**（没有继续膨胀成第三套口径）。

**R1 判定：`passed` — 真闭环。**

---

## §3 R2（medium）视觉走查 + 用户 m00004「视觉模型」要求 — **按「未运行」正确落账**

判据（任务书）：N8 必须是「未运行」而非「通过」、原始输出贴全、且明写「用户 m00004 的视觉模型要求未满足，须在最终交付说明中显式告知」。三条逐一核：

### 3.1 三处落点

| 位置 | 内容 |
|---|---|
| `docs/VERIFICATION.md:100`（未运行项表 N8 行） | 「**无。18 个页面一张截图都产生不出来**，故本轮**没有任何视觉走查结论**。**用户 m00004 的「前端子代理须有视觉模型」一条未满足，须在最终交付说明中显式告知**（原始输出见 §7.6）」 |
| `docs/VERIFICATION.md:616`（§7.6 专节） | 标题即「### 7.6 前端视觉走查（N8，本轮新增 · **未运行**）」 |
| `docs/VERIFICATION.md:986`（未运行项汇总表） | 同内容 + 判图腿证据：「`ARK_API_KEY` 在本会话不存在（`cordis.yml:79` 声明该变量，但 `env` 为空、`.dsh/.env` 不存在，空 key 打端点得 HTTP 400 `InvalidParameter … AuthHeader`）」 |

`docs/VERIFICATION.md:685` 原文：「- **N8 未运行，不得算作通过。** 本轮**没有任何**视觉走查结论 —— 既没有截图，也没有任何模型对页面外观的判断。」
`docs/VERIFICATION.md:686` 原文：「- **用户 m00004「前端子代理须有视觉模型」这条要求未满足**…**须在最终交付说明中显式告知用户。**」
`docs/VERIFICATION.md:687` 原文：补跑方式（装 `hdc` 或起模拟器 → `hdc shell snapshot_display` 逐页取图 → 有效 `ARK_API_KEY` 调 `POST https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions` 判图）+「**本轮不做任何「看起来还行」的口头替代**」。

### 3.2 原始输出贴全（`docs/VERIFICATION.md:616-687`）

```
$ command -v hdc                      → （空）
$ hdc list targets
Command 'hdc' not found, did you mean: command 'htc' from deb httptunnel (3.3+dfsg-6build1) …
Try: sudo apt install <deb name>                                    EXIT=127
$ ldd --version | head -1
ldd (Ubuntu GLIBC 2.43-2ubuntu2.4) 2.43
$ ls -l /dev/kvm
crw-rw---- 1 root kvm 10, 232 Oct 14 22:10 /dev/kvm
$ test -w /dev/kvm; echo $?
1
$ env | grep -i ARK_API_KEY          → （无输出）  $? = 1
$ ls -l /mnt/c/Users/Administrator/.dsh/.env
ls: cannot access '…': No such file or directory
$ grep -n "apiKeyEnv" /mnt/c/Users/Administrator/.dsh/profiles/desktop/cordis.yml
79:        apiKeyEnv: ARK_API_KEY
（上下文 baseURL: https://ark.cn-beijing.volces.com/api/coding/v3）
$ curl … -H "Authorization: Bearer " …        → HTTP=400
{"error":{"code":"InvalidParameter","message":"The parameter `` specified in the request are not valid:
 invalid parameter: AuthHeader. Request id: …","param":"","type":"BadRequest"}}
```

⇒ 截图腿（`hdc` 未装 / 无真机 / `/dev/kvm` 不可写）与判图腿（无 `ARK_API_KEY`）**两条腿都有命令 + 原始输出**，且结论是「未运行」，不是「通过」。

### 3.3 与 t8 的 R2 差异

t8 判 R2 的理由是「要求未达成**且未在交付物中声明**」。本轮两项都已闭合：① `docs/VERIFICATION.md` 三处明写未满足；② 明写「须在最终交付说明中显式告知用户」。**声明责任已落盘，剩下的只是「告知」这个动作**——属交付话术，由队长在最终交付说明里执行，不再是文档缺陷。

**R2 判定：`passed`（按「未运行 + 已声明」口径）。**

---

## §4 R3（low）V9 判据：窄模式假绿 → 宽口径 + 结论改判「部分闭环」 — **真闭环**

判据（任务书）：必须**改成宽口径**，且**结论从「闭环」改判为「部分闭环」**；若 `docs/VERIFICATION.md` 里还写着「闭环」，则判 needs_revision。逐条核：

| 位置 | 现状原文（摘） | 判定 |
|---|---|---|
| `docs/VERIFICATION.md:67`（V9 行判据列） | 「**宽口径语义覆盖** `grep -rn "四类"`（+ `grep -n "五类" AGENTS.md`）+ 141 个网络调用点全表审查」 | 已宽口径 ✅ |
| `docs/VERIFICATION.md:67`（V9 行结论列） | 「…例外集语境判据由窄模式改为宽口径后重新判定为 **部分闭环**（R3 勘误，见 §7.1）」 | 已改判 ✅ |
| `docs/VERIFICATION.md:153`（F3 行） | 「…**原判据 `grep "四类网络例外\|四类例外"` 是窄模式假绿（t28 / R3 撤回）**」+ 结论列 = **部分闭环** | 已改判 ✅ |
| `docs/VERIFICATION.md:538`（§7.1 开头） | 「> **判据勘误（t28 / R3）**：本节原来的判据是**窄模式**…**这是假绿**」 | 已自我撤回 ✅ |
| `docs/VERIFICATION.md:609` | 「**判据本身错了**：原判据用窄模式找两个连写短语，`PLAN.md` 6 处 + `ADR-0001:17` 一处 + `B21.correct` 一项共 8 处例外集语境**根本不匹配**，判「闭环」是无证据的」（8 处这个数字对，但第 8 处是 `B42.correct` 不是 `B21.correct` —— 原文错标，见 **O3**） | ✅（数字正确，id 标注有误 → O3） |
| `docs/VERIFICATION.md:610` | 「**修完之后仍不能写「闭环」**：宽口径下还剩 13 行含「四类」，其中 10 行是**历史留痕 / 历史缺陷记录 / 减排分类**…3 行是本节新写的收尾登记…**故结论为「部分闭环」，而不是「闭环」**」 | ✅ |

- 全仓 `grep -rn "五类闭环"` → 唯一命中是 `docs/VERIFICATION.md:538` 引号内的转述「就判「五类闭环」——**这是假绿**」⇒ **无肯定式残留**，不构成假闭环。
- `docs/VERIFICATION.md:541` 附了宽口径 `git grep -n "四类" 9d73de4 -- docs AGENTS.md tests ':!docs/REVIEW.md' ':!docs/VERIFICATION.md'` 的原始输出（20 行），`docs/VERIFICATION.md:567` 附了现状 16 行 ⇒ **两个基线都留了原文**，可复现。
- `fccf524` 对 `docs/VERIFICATION.md` 只删 4 行（V9 行、F3 行、两条窄模式 grep 命令），**未删任何既有通过项**（V1–V20 全部保留，V9 是被改写）。

**R3 判定：`passed`。**

---

## §5 R4 / R5 / R6 / R7 / R8

### 5.1 R4（low）两处落盘路径 — **真闭环**

| 位置 | 现状 | 原文（`git show 9d73de4:…`） |
|---|---|---|
| `docs/APPENDIX-C-ui-screens.md:158` | 「> 落盘路径：`app/entry/src/main/ets/components/`」 | `app/entry/src/main/ets/view/components/` |
| `docs/PLAN.md:143` | 「**全应用唯一网络出口**：`app/entry/src/main/ets/viewmodel/net/HttpPort.ets`（`HttpClient` 是该文件内的类名，见 `HttpPort.ets:62`）」 | `common/HttpClient.ets` |

仓库实测（不是照抄文档）：
```
$ ls app/entry/src/main/ets/
components  dao  data  entryability  infra  model  pages  service  util  viewmodel
$ ls -d app/entry/src/main/ets/view      → No such file or directory
$ ls -d app/entry/src/main/ets/common    → No such file or directory
$ sed -n '51p;55p;62p' app/entry/src/main/ets/viewmodel/net/HttpPort.ets
export interface HttpPort {
  request(req: HttpRequest): Promise<HttpResponse>;
export class HttpClient implements HttpPort {
```
⇒ 文档引用的**路径、类名、行号三者与仓库逐条对得上**。
全仓残留复查：`grep -rn "ets/view/\|ets/common/\|common/HttpClient\|view/components" --include=*.md` → 除 `docs/CHANGELOG.md` 三行勘误登记（历史留痕）外**零残留**
（`docs/APPENDIX-C-ui-screens.md:87` 的 `common/AppTheme.ets` 是 B43 期留下的「**在仓库里不存在**」勘误说明体，不是契约）。

### 5.2 R5（low）因子口径 21 → 31 — **真闭环**

`tests/README.md:44` 现状原文：「包含：**31 项**因子相关条目 = 30 条因子（20 条 `recording: true` 可录入 + 10 条 `recording: false` 对照镜像）+ 换算常量 `CAR_OWN_FACTOR` 1 条；另含 2 条换算规则、18 组正向样例、5 组封顶样例、6 条边界样例、`docConflicts` 待修清单。条目口径与 `docs/APPENDIX-A-carbon-factors.md §2.5` 的「30 条 + `CAR_OWN_FACTOR` 1 条 = 31 项」镜像关系一致（B36）」
实测对齐：基准 `factors` **31 条**、app 因子库 **30 条**（`CAR_OWN_FACTOR` 在 `conversions` 里）⇒ 文档与基准一致。

### 5.3 R6（low）`7e3e969` 变更留痕 — **真闭环**

`docs/CHANGELOG.md:95` 新增「### 9. 补记 `7e3e969` 与例外集五类收尾（t28，2026-11-07）」，`docs/CHANGELOG.md:99` 原文写清：
- ① 删掉 `server/tests/test_authz.py` 里断言 `app/api/v1/{sync,shop,backup}.py` 与 `admin_web/mount.py`「不存在」的用例（t5/t6 正要创建它们 ⇒ 会让下游 verify 必红），改为只自检本切片唯一身份实现 `auth_provider.py` 存在；
- ② 删掉 `assert … or True` 恒真断言，改为断言调用次数 `len(calls) == 6`；
- 附「提交时自检 `cd server && .venv/bin/python -m pytest tests/ -q` → 69 passed」+「并做了反脆弱自检（临时创建 t5/t6 目标文件后重跑仍 69 passed）」；
- 并自述「此前该提交只在 `git log` 里可查、本文件无痕，属漏记（评审 R6）」。

⇒ 既有「改了什么」也有「为什么不是放宽断言」的机制说明，且带当时的命令与结果。

### 5.4 R7（low）`server/.env` 权限 555 — **按预期未修（正确）**

```
$ stat -c '%a %n' server/.env
555 server/.env
$ git check-ignore -v server/.env
server/.gitignore:2:.env	server/.env
```
`AGENTS.md §6` 要求密钥文件 600；当前 555（`r-xr-xr-x`，连属主都不可写）。但：
- 该文件**未入仓**（`git ls-files` 里只有 `server/.env.example`）⇒ 无泄漏；
- 属 `server/` 本机卫生，是 t28 的 outOfScope。
⇒ 留给用户在本机 `chmod 600 server/.env`。**越界检查通过：t28 没有动它**（`git diff --name-status 9d73de4..HEAD` 无 `server/` 任何文件）。

### 5.5 R8（low）`PointCap.test.ets` 命名偏差 — **真闭环（改为文档侧说明）**

`tests/README.md:67` 现状：「| ~~`PointCap.test.ets`~~ | 封顶 5 组（无独立套件，由 `CalcSamples.test.ets` + `CalcBaselineValidator.ets` 承载），不再单独建文件 |」
`tests/README.md:117` 另有：「**F10（`PointCap.test.ets` 不存在）→ 非缺陷，是有意设计。**」

---

## §6 数值真相源：**程序化逐键比对，零改动**（非目测 diff）

```
$ git show 9d73de4:tests/cases/carbon-calc.json > /tmp/t29_bench_old.json
md5 old(9d73de4): c096da45ba7e1852d25cf91699fcb42b
md5 new(HEAD)   : e096b2db77bbcc9a43ee8728cbd883e9
```

Python `json.load` 后逐键 `==` 比对（**不是看 diff**）：

| 顶层键 | identical |
|---|---|
| `boundarySamples` | **True** |
| `capSamples` | **True** |
| `constants` | **True** |
| `conversions` | **True** |
| `factors` | **True** |
| `meta` | **True** |
| `samples` | **True** |
| `docConflicts` | False（预期内） |

`docConflicts` 深挖：
```
条数 旧/新: 47 / 47
id 集合相同: True
open: []                （47 条全部 closed）
有差异条目: ['B21', 'B42']
  B21 差异字段=['correct']  correct len 210 → 313  status=closed
  B42 差异字段=['correct']  correct len 100 → 175  status=closed
```
⇒ **只有 B21/B42 两段 `correct` 文本变，其余 45 条一字未动；数值区（samples / capSamples / boundarySamples / factors / conversions / constants / meta）逐键 identical。**
与任务书允许范围（「只许 `docConflicts` 的 B21/B42 `correct` 文本变」）**完全一致**。

现状口径：`samples=18 / capSamples=5 / boundarySamples=6 / factors=31 / meta.factorVersion=CF-2026.2`。

---

## §7 修复是否引入新问题 — 本轮唯一实质发现（O1，low）

### O1（low）：`ohosTest` 基准副本未随 `tests/cases/carbon-calc.json` 同步

```
$ md5sum tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
e096b2db77bbcc9a43ee8728cbd883e9  tests/cases/carbon-calc.json
c096da45ba7e1852d25cf91699fcb42b  app/entry/src/ohosTest/resources/rawfile/carbon-calc.json
byte identical: False
```
逐提交追踪（`git show <commit>:<path> | md5sum`）：

| commit | `tests/cases/carbon-calc.json` | `app/entry/src/ohosTest/resources/rawfile/carbon-calc.json` | 一致？ |
|---|---|---|---|
| `5f751c4`（初始建立） | `3a16bcb0…` | `d41d8cd9…`（空文件） | 尚未建立副本 |
| `9d73de4`（t8 基线） | `c096da45…` | `c096da45…` | **一致** |
| `fccf524`（HEAD） | `e096b2db…` | `c096da45…` | **不一致** |

内容差异**只在 `docConflicts`**（数值区 7 键全 identical，差异 id 仍是 `B21`/`B42`）⇒ **不影响任何 L1 断言的正确性**。

但它违反的是**用例自己写死的契约**（`app/entry/src/ohosTest/ets/test/CalcSamples.test.ets:8-13` 原文）：
> 基准文件按 `tests/README.md` §3 拷进 `app/entry/src/ohosTest/resources/rawfile/carbon-calc.json`，测试运行期从 rawfile 读它。**副本与 `tests/cases/carbon-calc.json` 必须字节一致**（离线复算脚本会先比对 md5 再复算，防副本漂移）。

实测后果（离线复算门禁第 0 项）：
```
$ node /tmp/cbverify/verify.mjs
FAIL ohosTest 里的基准副本与 tests/cases/carbon-calc.json 不一致（副本漂移）
OK   samples（正向样例） = 18
… 其余全部 OK …
VERIFY_EXIT=1
```
（`/tmp/cbverify/verify.mjs:29-31` 判据原文：`const benchJson = read('/tests/cases/carbon-calc.json'); const copyJson = read('/app/entry/src/ohosTest/resources/rawfile/carbon-calc.json'); if (benchJson !== copyJson) bad('…副本漂移');`）

**归属与定级**：t28 的 inScope 是 9 个文件（含 `tests/cases/carbon-calc.json`，**不含** `app/entry/src/ohosTest/resources/rawfile/carbon-calc.json`）⇒ 修它属 `app/` 写入范围，**t28 本轮无法修**。但「改基准未同步副本」这个副作用确实是 t28 引入的（`9d73de4` 时点两者字节一致）。定级 **low**：不影响任何数值断言、不影响交付功能，只影响「两份基准必须字节一致」这条自定契约与离线复算门禁的绿灯。
**修法**：`cp tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json`（一行，需要 `app/` 写入窗口）。

---

## §8 门禁

```
$ python3 tests/tools/check_l0.py --strict > /tmp/t29_l0.log 2>&1; L0=$?; echo "L0_EXIT=$L0"
L0_EXIT=0

L0-1 数值基准自检    检查项：28    错误：0
L0-2 文档已知冲突扫描  扫描文件：89   命中：0
L0-3 人工待修清单（tests/cases/carbon-calc.json → docConflicts）：0 条
========================================================================
结论：PASS —— 基准自洽，文档无已知冲突
```
（`$?` 单独捕获，不是管道尾值；`扫描文件 89` 比 t8 的 82 多，是因为本轮新增/改写文档与两个报告文件。）

---

## §9 低危观察（不作为 `needs_revision` 依据，记录备查）

| id | 级别 | 问题 | 建议修法 | 位置 |
|---|---|---|---|---|
| **O1** | low（**本轮新发现**） | `ohosTest` 基准副本未随基准同步，导致离线复算门禁第 0 项 FAIL（见 §7） | `cp tests/cases/carbon-calc.json app/entry/src/ohosTest/resources/rawfile/carbon-calc.json` | `app/entry/src/ohosTest/resources/rawfile/carbon-calc.json` |
| **O2** | low | 同一批口径残留：`AGENTS.md:71`（B21 条目）仍写「网络例外仅**四项**」。宽口径 `grep "四类"` 抓不到（写的是「四项」），故本轮修复天然漏网 | 在该条目尾部补「（t21 起为五类，含配置下发）」 | `AGENTS.md:71` |
| **O3** | low | `docs/VERIFICATION.md:609` 把第 8 处例外集语境**错标成 `B21.correct`**：`B21.correct` 的旧原文是「网络例外仅**四项**」，从未含「四类」，压根不在宽口径 20 行基线里；真正的第 8 处是 `tests/cases/carbon-calc.json:955` 的 **`B42.correct`**（旧原文「除「…」**四类网络例外**」）。「8 处」这个数字是对的，只有 id 标错。另 `:610` 的「宽口径下还剩 13 行…其中 10 行…3 行是本节新写的收尾登记」与 `:585` 的「20 − 7 = 13；+3 = 16」口径不顺：13 若已含那 3 行新写，就与实测 16 行不符；若不含，则「其中 3 行是…」自相矛盾。两处都只是行文瑕疵，不影响「部分闭环」这个结论 | ① `:609` 把 `B21.correct` 改为 `B42.correct`；② `:610` 改为「20 − 7 = 13 行仍在（含 `B42.correct` 改写后的自述行），加上本节新写的 3 行，宽口径共 16 行」 | `docs/VERIFICATION.md:609` `/`:610` |
| **O4** | low | 「离线复算」这条证据链的脚本（`verify.mjs` / `recompute.py` / `validator.mjs`）全在 `/tmp/cbverify`、`/tmp/cbv24`，仓内 `tests/tools/` 只有 `check_l0.py` ⇒ 报告里引用的复算结论**不可从仓库复现**（机器重启即失效） | 把复算脚本纳入 `tests/tools/`（并与 `check_l0.py` 一起纳入门禁），或至少在 `tests/README.md` 写明复现步骤 | `tests/tools/` |

---

## §10 结论与放行建议

**verdict = `pass`**

| 项 | 判定 | 依据 |
|---|---|---|
| R1 例外集四类→五类 | **passed** | 宽口径 16 行逐条判语境，例外集语境 8 处全部五类 + 保留失败降级；`docs/PLAN.md:1046`（A2 断网验收）已改（§2） |
| R2 视觉走查 N8 | **passed** | 三处落点、状态「未运行」、原始输出贴全、明写「m00004 视觉模型要求未满足，须在最终交付说明显式告知」（§3） |
| R3 V9 判据 | **passed** | 判据改宽口径；结论由「闭环」改判「部分闭环」；无「五类闭环」肯定式残留（§4） |
| R4 落盘路径 | **passed** | 两处路径与仓库实测一致，类名与行号对得上（§5.1） |
| R5 因子口径 | **passed** | 21 → 31 项，与基准 `factors=31` 一致（§5.2） |
| R6 `7e3e969` 留痕 | **passed** | `docs/CHANGELOG.md §9` 写清机制 + 当时命令与结果（§5.3） |
| R7 `.env` 权限 | **passed（正确未修）** | 555 仍在，未入仓无泄漏；越界检查通过（§5.4） |
| R8 PointCap 命名 | **passed** | 改为文档侧说明「无独立套件、有意设计」（§5.5） |
| 数值真相源 | **passed** | 程序化逐键：数值区 7 键 identical，仅 B21/B42 `correct` 文本变（§6） |
| 修复引入新问题 | **O1（low）** | `ohosTest` 基准副本漂移（§7） |

**放行建议**：
1. **本轮修复可以放行**，R1 这条 medium 级契约冲突已实质消除，可认为「文档契约冻结」这一前置结论重新成立（唯一残留是 O2 的一处「四项」措辞，属同义历史条目，不影响任何验收执行）。
2. 下一次有 `app/` 写入窗口时，用一行 `cp` 消掉 O1（顺带可把 O2 的 `AGENTS.md:71` 补一句）。
3. 交付说明里**必须显式告知用户**：视觉模型/视觉走查未做（`docs/VERIFICATION.md:100/:686/:986` 已写明要告知），以及 L1（36 个 `it()`）、L2、`server/deploy/` 实跑、`/admin` 浏览器交互均未在本机运行——**未运行不等于通过**。

**本报告边界**：只写本文件；未 `stash` / `clean` / `checkout --` / `reset`；**未 push**（WSL 内无推送凭据），提交 SHA 单独报给队长。
