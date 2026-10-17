# 碳小布 CarbonBoo · 项目文档导航（v4.1）

> 本目录是「碳小布 / CarbonBoo」项目的**计划书与规格文档**。
> 定位：**只约束代码与最终效果**，不涉及人员分工与工期管理。
> 读者：AI 编码代理（vibecoding 全程依据）+ 项目负责人。
> 用途：**不对外发布、不作为比赛提交物**。
> **v4.1 口径**：比赛文件对赛题二的全部要求 —— **5 项主要功能 + 4 项创新拓展 = 9 项，全部实现**；**服务端（账号 + 云端同步 + 取价 + 云端备份）是必做件**，仅 Web 后台管理端可选（ADR-0001）。
> **本文件的"文档清单与阅读顺序"是全仓库唯一的导航来源**：`../README.md` 只保留入口顺序并指向本表，不重复描述。

---

## 文档清单与阅读顺序

| 顺序 | 文件 | 内容 | 什么时候读 |
|:--:|---|---|---|
| 0 | [../GLOSSARY.md](../GLOSSARY.md) | **名词唯一口径**：术语、账号态、三类同步的区别 | 任何时候，先对齐术语 |
| 1 | [PLAN.md](./PLAN.md) | **主计划书**：定位、四条铁律、技术栈、架构、九项覆盖、功能矩阵、模块规格、积分/目标/碳小铺、多设备协同、验收 A1–A18、风险、里程碑 M0–M11 | 任何时候先读它 |
| 2 | [APPENDIX-A-carbon-factors.md](./APPENDIX-A-carbon-factors.md) | **碳因子库全表**（可直接转 JSON 常量）+ 核算公式 + 目标↔因子绑定 + 待复核清单 | 实现「低碳行为核算」前必读 |
| 3 | [APPENDIX-B-data-and-api.md](./APPENDIX-B-data-and-api.md) | **客户端 19 张表建表 SQL + TypeScript 模型 + REST 契约（账号 / 取价 / 同步 / 后台）+ 近场协同协议 + 12 个 Dao + `AuthProvider` 契约 + 种子数据** | 实现数据层 / 服务端前必读 |
| 4 | [APPENDIX-C-ui-screens.md](./APPENDIX-C-ui-screens.md) | **18 个页面 + 7 个半模态**的元素清单、设计令牌、字段绑定、交互流、空态与文案 | 实现任何页面前必读 |
| 5 | [APPENDIX-D-acceptance.md](./APPENDIX-D-acceptance.md) | **验收清单**（D1-1～D10-8、C1–C10、P1–P10、E1–E12）+ 18 组手算样例 + 封顶/边界样例 + 演示数据规格（唯一来源） | 每完成一个模块后自查 |
| 6 | [APPENDIX-E-demo-script.md](./APPENDIX-E-demo-script.md) | **4 分 50 秒演示分镜 + 10 分钟路演逐字稿 + PPT 16 页大纲** + 降级方案 + 话术禁忌 | 定义"最终效果"；排练与录屏用 |
| 7 | [APPENDIX-F-compliance.md](./APPENDIX-F-compliance.md) | **赛题官方要求 ↔ 本项目 9 项覆盖的双向对照表**（含官方原文摘录与不做清单） | 需要确认"有没有漏做"时读 |

| 8 | [adr/0001-account-and-sync.md](./adr/0001-account-and-sync.md) | **账号与同步决策**：服务端必做（账号 + 同步 + 取价 + 备份）、仅 Web 后台可选、不接华为账号；注销后云端软删保留 30 天 | 涉及登录 / 同步 / 服务端时 |
| 9 | [CHANGELOG.md](./CHANGELOG.md) | **全仓库唯一变更记录**（各附录末尾的"变更摘要"都指向这里） | 想知道"哪一版改了什么"时 |
| 10 | [DECISION-0002-doc-contract-errata.md](./DECISION-0002-doc-contract-errata.md) | **v4.2 文档契约勘误的决策记录**：`uq_pr_source` 补 `user_id`、同步契约七处、附录 C 落盘路径、附录 D §9 演示数据口径（`AGENTS.md §10` ① 要求的留档） | 想追"这一轮文档为什么这么改"时 |
| 11 | [DECISION-0003-runtime-config-and-sync-anchor.md](./DECISION-0003-runtime-config-and-sync-anchor.md) | **运行期配置下发通道与同步锚点基准的决策记录**（D1–D10）：`offsetMs` 客户端取反 / `lastSyncAt` 单一服务端基准 + 派生 `lastSyncAtLocal` / 新增免鉴权 `GET /api/v1/config`（附录 B §5.5）与「整份校验失败即整份丢弃」的落地口径（B46 / B47） | 想追"配置怎么下发、时间戳在哪个基准上比"时 |

---

## 一页速览

- **赛题**：第三届河南省高等学校信息技术应用创新大赛 · **赛题二「碳足迹·全民绿色生活碳积分与减排指南」**（纯北向应用开发类）
- **产品名**：中文「碳小布」／英文「CarbonBoo」；包名 `com.carbonboo.app`
- **形态**：OpenHarmony 手机/平板应用，**本地优先 · 未登录即单机**（离线全功能，例外仅「登录 / 云端同步 / 取价 / 云端备份」），**API 12+**，DevEco Studio + ArkTS / Stage 模型
- **客户端技术栈**：ArkTS + ArkUI 声明式 + `relationalStore`（19 张表）+ `preferences` + Canvas 自绘图表 + 端侧 AI 推理接口 + 鸿蒙近场协同（演示层）；**不引入任何第三方 npm / HAR 包**
- **服务端（必做件）**：Python 3.11 + FastAPI + MySQL 8（`server/`）：账号 + 多设备同步 + 商品取价 + 云端备份；其中 **Web 后台管理端**才是可选项
- **赛题覆盖**：**5 项主要功能 + 4 项创新拓展，共 9 项，全部实现**
- **四条铁律**：① 本地优先 ② 单一计算入口 ③ 因子快照 ④ 积分单向可追溯
- **关键数值**：30 个碳因子（20 个可录入，回收 8 + 光盘 2 标"参考值"）／19 张表（9 张参与同步）／18 个页面／7 个半模态／14 个 Service／11 个目标／8 枚徽章／8 个头像框／`100 积分 = 1 碳币`／记录类积分日封顶 200
- **当前阶段**：**S1–S6 已实现并落库**（`app/` 19 张表 + 18 个页面；`server/` 21 张表 + 账号 / 多设备同步 / 取价 / 云端备份 + L3 pytest），**S7 创新项与 `/admin` 后台收尾中**；文档口径 **v4.2（2026-11-06 文档契约勘误）**
- **文档结构**：1 份主计划书 + 6 份附录（A–F）+ 词汇表 + 决策记录；主计划书给全局约束，附录给"照着写"的细节（SQL、接口、页面元素、因子值、验收项）

---

## 赛题二要求 ↔ 文档覆盖对照（9 项）

| 赛题二原文 | 类别 | 本项目实现 | 详见 |
|---|:--:|---|---|
| 主要功能 1 · 低碳行为核算 | 必做 | 4 大类 **30 个因子**（20 个可录入）+ 自动核算 + 因子快照 + 累计碳足迹 | [A](./APPENDIX-A-carbon-factors.md) · [PLAN §7.1](./PLAN.md) |
| 主要功能 2 · 数据可视化看板 | 必做 | 折线/柱状/饼图 + 日周月年 + 分类下钻 + 分类查询 | [C §6](./APPENDIX-C-ui-screens.md) · [PLAN §7.3](./PLAN.md) |
| 主要功能 3 · 碳积分激励体系 | 必做 | 积分账本 + **11 个周期目标** + **8 枚徽章** + 碳小铺（8 头像框） | [PLAN §9~§11](./PLAN.md) · [C §13~§16](./APPENDIX-C-ui-screens.md) |
| 主要功能 4 · 双碳科普专栏 | 必做 | **12 篇**内置图文（政策/技巧/知识）+ 阅读进度 + 收藏，完全离线 | [C §8](./APPENDIX-C-ui-screens.md) · [PLAN §7.7](./PLAN.md) |
| 主要功能 5 · 本地数据管理 | 必做 | 本地备份/恢复（含快照与护栏）+ 三份 CSV 报表导出 | [PLAN §7.8](./PLAN.md) |
| 创新 1 · 鸿蒙特色能力·多设备同步 | 创新 | **服务端云端同步（主通路，同账号 + LWW）** + 鸿蒙近场协同演示层 + 协同页（待同步数/冲突数）+ **家庭碳积分只读合并统计** | [B §5.3/§6](./APPENDIX-B-data-and-api.md) · [PLAN §7.9/§7.10/§12/§13](./PLAN.md) · [C §18](./APPENDIX-C-ui-screens.md) |
| 创新 2 · 端侧 AI·图片识别低碳行为 | 创新 | 图片识图 → 候选类型（**不展示置信度数字**）→ **用户确认** → 预填录入；图片不落盘；图标网格降级 | [PLAN §7.11](./PLAN.md) · [C §10 / §23.1](./APPENDIX-C-ui-screens.md) |
| 创新 3 · 平台对接·碳普惠积分互通 | 创新 | **模拟**碳普惠：`100 积分 = 1 碳币`，单向不可逆，常驻「模拟演示」标注 | [PLAN §7.12](./PLAN.md) · [C §19](./APPENDIX-C-ui-screens.md) |
| 创新 4 · 智能服务 | 创新 | 个性化任务推送 + 生活建议（5 条优先级规则）+ **社交分享卡片**（两种尺寸） | [PLAN §7.13](./PLAN.md) · [C §23.2](./APPENDIX-C-ui-screens.md) |

> 完整的"官方原文 ↔ 实现位置 ↔ 验收项"三列对照，以及 12 条**不做清单**，见 [APPENDIX-F-compliance.md](./APPENDIX-F-compliance.md)。

---

## 跨文档对照速查（容易找错的那几处）

| 要找什么 | 直接去 |
|---|---|
| 减排量公式（唯一口径） | [APPENDIX-A](./APPENDIX-A-carbon-factors.md) §3.1；[PLAN §7.1](./PLAN.md) |
| 出行类"净减排"口径与 `CAR_OWN_FACTOR` | [APPENDIX-A](./APPENDIX-A-carbon-factors.md) §2.1 / §2.6 |
| 积分怎么算、日封顶 200 的取数 SQL | [PLAN §9.2](./PLAN.md) |
| 11 个目标的周期、阈值与奖励 | [PLAN §10](./PLAN.md)；[APPENDIX-A](./APPENDIX-A-carbon-factors.md) §3.5 |
| 碳小铺定价与外观体系 | [PLAN §11](./PLAN.md) |
| 19 张表的建表 SQL | [APPENDIX-B](./APPENDIX-B-data-and-api.md) §2 |
| 服务端同步（主通路）与近场协同协议 | [APPENDIX-B](./APPENDIX-B-data-and-api.md) §5.3（REST + LWW）、§6（近场）；[PLAN §12/§13](./PLAN.md) |
| 账号 / 登录 / 注销怎么实现 | [ADR-0001](./adr/0001-account-and-sync.md)；[APPENDIX-B](./APPENDIX-B-data-and-api.md) §5.2、§7.1（`AuthProvider` 契约） |
| 18 个页面的元素与绑定 | [APPENDIX-C](./APPENDIX-C-ui-screens.md) §1（清单）、§5~§22（逐页） |
| 端侧 AI 的接口契约 | [APPENDIX-B](./APPENDIX-B-data-and-api.md) §4（`AiRecognizeResult`）；[PLAN §7.11](./PLAN.md) |
| 18 组碳计算手算样例（验收基准） | [APPENDIX-D](./APPENDIX-D-acceptance.md) §3.1；封顶样例 §3.2；边界 §3.3 |
| 验收项 A1–A18 与附录 D 的对应 | [APPENDIX-D](./APPENDIX-D-acceptance.md) §11；[PLAN §16](./PLAN.md) |
| 演示数据的条数与分布（唯一来源） | [APPENDIX-D](./APPENDIX-D-acceptance.md) §9（附录 E 与 GLOSSARY 只引用） |
| 官方要求 ↔ 实现的双向对照 | [APPENDIX-F](./APPENDIX-F-compliance.md) |
| 明确不做的事 | [APPENDIX-F](./APPENDIX-F-compliance.md) §5 |

---

## 目录约定（写代码时按此创建）

```
CarbonBoo/                # 仓库根（本目录的上一层）
├─ AGENTS.md              # 编码代理规约（冲突裁决 / 停手规则 / 待修清单）
├─ GLOSSARY.md            # 名词唯一口径
├─ README.md              # 项目入口与文档导航
├─ docs/                  # 本目录：计划书与规格（PLAN + 附录 A–F + adr/ + CHANGELOG.md）
├─ tests/                 # L0 检查器 + 数值基准（详情见 tests/README.md）
├─ app/                   # HarmonyOS 应用工程（DevEco Studio 打开这一层）
│  └─ entry/src/main/resources/rawfile/
│     ├─ factors/carbon-factors.json       # 因子库（附录 A §7 全文）
│     ├─ science/sci-01.md ~ sci-12.md     # 12 篇科普（附录 C §8）
│     ├─ science/science-index.json        # 科普索引
│     └─ shop/shop-items.json              # 碳小铺内置默认价（离线回退）
├─ server/                # 必做：FastAPI + MySQL（账号 + 同步 + 取价；后台管理端可选）
└─ _src/                  # 碳因子原始资料（PDF + 抽取文本），只读参考
```

> `_src/` 是**资料**，不是交付物；`app/`、`server/` 将在编码阶段创建。
