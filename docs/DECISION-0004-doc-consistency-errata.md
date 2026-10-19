# DECISION-0004 · 文档一致性勘误（页面数定真值 / `it()` 计数统一 / F1·F2 状态更正）

> **决策日期**：2026-10-19 ｜ **依据**：`AGENTS.md §10`（改动 `AGENTS.md` 必须留决策记录并更新 §10 表 + `docs/CHANGELOG.md`）、t71 报出的三条文档失真、任务 t74
> **写入范围**：`AGENTS.md`、`README.md`、`docs/VERIFICATION.md`（新增 §R16 + 三处当前口径行 + 三处指针）、`docs/CHANGELOG.md`、本文件、六个 `tests/tools/*/README.md`
> **不改动**：`app/**`、`server/**`、`tests/cases/carbon-calc.json`、任何测试断言或工具实现

---

## 1. 页面数：真值 = **18**（t71 把 `README.md:7` 改成 19 是错的）

**证据（全部现场取）**

```
$ grep -n '^## 1\. 页面清单' docs/APPENDIX-C-ui-screens.md
9:## 1. 页面清单（18 个）
$ sed -n '4p' docs/APPENDIX-C-ui-screens.md
> **版本**：v4.1（**18 个页面**＝5 Tab ＋ 13 二级页；另有 7 个半模态）
$ grep -n '^## ' docs/APPENDIX-C-ui-screens.md | grep '页面'
 5. 页面 1 · 首页 HOME … 22. 页面 18 · 关于与合规 ABOUT      （§5–§22，共 18 节，逐页一一对应）
$ ls app/entry/src/main/ets/pages/*.ets | wc -l
19
$ grep -rn '@Entry' app/entry/src/main/ets/pages/
app/entry/src/main/ets/pages/Index.ets:1:  @Entry 页面：导航壳 + 5 个 Tab（附录 C §2）。
app/entry/src/main/ets/pages/Index.ets:…  @Entry
```

**判据：`Index.ets` 是导航壳，不是页面。**
① 它是 `pages/` 下**唯一**带 `@Entry` 的文件，其文件头注释自述「页面：导航壳 + 5 个 Tab（附录 C §2）」；
② 附录 C §2「导航结构」把 `MainPage = Tabs（5 个 Tab）` 画在 `EntryAbility → NavigationStack →` 之下，即 5 个 Tab 的**宿主**；
③ 附录 C §1「页面清单（18 个）」的表只列 #1–#18（5 Tab + 13 二级页），**没有 `Index`/`MainPage` 这一行**；
④ 既有评审已用过同一口径：`docs/REVIEW.md:305`「`app/`：19 个页面文件（`Index` + 18 页）」。

**结论：磁盘 19 个 `.ets` = 18 个页面 + 1 个导航壳**（`README.md:20` 的「18 个页面」、`AGENTS.md:7` 的「18 个页面」本来就对，是 t71 改的 `README.md:7` 引入了矛盾）。

**为什么不写 STOP**：两处口径不是"天生不可统一"，而是**计数对象不同**（文件数 vs 页面数）。按 AGENTS §1.3，冲突指"同一对象的两种取值"；此处对象已被附录 C 的清单钉死（18 个页面），故直接定真值并在两处都写成**可自证的形式**（`18 个页面（pages/ 19 个 .ets = 18 页 + Index 导航壳）`），不留歧义。

---

## 2. `it()` 计数：真值 = **41**（历史轮次的「36」一律**不改写**）

**实测**：`app/entry/src/ohosTest/ets/test/` 下 11 个 `.test.ets`（`List.test.ets` 含 0 条 `it()`，故**有效套件 10 个**），逐文件 `grep -cE '^\s*it\('` = 1/1/6/1/1/**0**/15/1/8/6/1 ⇒ **合计 41**；`bash tests/tools/l1_offline/run_tests.sh` 实测 `hypium 用例：41 条，PASS=41 FAIL=0`。t45 时确为 36 条，t62 增补 5 条后变 41（`LwwMerge.test.ets` 11→16 条）。

**口径纪律**（本轮逐处判定，全文对照表见 `docs/VERIFICATION.md §R16.2`）：

- **历史留痕**（某一轮当时的数字 / 某次命令的原始输出）⇒ **原文一字不改**，只在本轮新增的 §R16 集中给更正指针；
- **当前口径陈述**（"现在的工具/现在的事实"）⇒ 直接改成 41。

---

## 3. F1 / F2 状态：**均已修复**（原文不改，只追加指针）

| 编号 | 问题（t57 报出） | 修复提交 | 现证据 |
|---|---|---|---|
| **F1**（blocker） | 新设备**首同步**撞 `uq_ua` / `uq_uprofile` 等唯一索引（客户端 pull 侧只按 `id` 认领本机行） | **t62**：`RowClaim.of()` 三级认领（按 `user_id` 的单例表 → 业务键 → `id`）+ `INSERT OR IGNORE` | `l2_sync` 主用例 `#0.2` / `#8.3` / `#8.4` **现均 PASS**（修复现场断言，修复前必红）；`LwwMerge.test.ets` ⑪⑫⑮ 覆盖认领 SQL 轨迹 |
| **F2**（high） | `SyncPullData` 无 `offsetMs` ⇒ 附录 B §6.4-6 的 `clientOffsetMs = −respOffsetMs` 在真链路上不可达 | **t62**：校正值改从 **push 握手腿**取（pull 体有该字段时响应字段优先）；**t68** 再补：服务端落库换算到**服务端基准**、客户端 pull 落库换算到**客户端基准**（附录 B §5.3:1095/1097） | `#4.5` / `#4.6` / `#4.7` **现均 PASS**；t68 的 `#4.9`（时钟往返不漂移）在三轮连推下逐轮严格成立（t73 重建判据后三连跑确定性绿） |

⇒ `docs/VERIFICATION.md:228`（§R14.1 第 16 行）与 `:257`/`:258`（§R14.4 未决 1/2）里「F1/F2 未修」的陈述**已过期**：这三处按纪律**保留原文**，各自追加一行更正指针（见 `docs/VERIFICATION.md §R16.3`）。

---

## 4. 为什么不往 `tests/cases/carbon-calc.json → docConflicts` 登记

`AGENTS.md §9` 的登记要求针对**新增的契约缺陷**（B1–B47 那一类：影响数值 / 字段 / 接口 / 页面元素 / 验收的实质冲突）。本轮三条都是**陈述失真**（某个数字 / 某个状态写得不对），契约本身（附录 A–F）无需改动；且 `tests/cases/carbon-calc.json` 明确在本任务写入范围之外。故留痕落在本文件 + `AGENTS.md §10` + `docs/CHANGELOG.md` + `docs/VERIFICATION.md §R16`。

---

## 5. 门禁

`python3 tests/tools/check_l0.py --strict` → `L0_EXIT=0`（`L0-1` 28 检查项 0 错误 / `L0-2` 89 文件 0 命中 / `L0-3` 0 条）。`AGENTS.md` 头部状态行与 `README.md` 头部状态行的页面数已统一为 18。
