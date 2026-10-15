# 附录 A · 碳因子库与核算公式

> **配套文档**：[PLAN.md](./PLAN.md) §7.1 行为核算引擎、§9 积分体系
> **因子库版本**：`CF-2026.2`（v4.0，删除修正系数）
> **最后更新**：面对 `_src/` 生态环境部 2024 全国电力碳足迹因子、T/CECA-G 团体标准附录 D、GB/T 51366 等资料整理
> **读者**：AI 编码代理。本附录是 `CarbonService.calculate()` 的**唯一实现依据**。

---

## 1. 数据来源与可信度分级

| 来源编号 | 来源 | 可信度 | 说明 |
|---|---|:--:|---|
| `SRC-MEE-2024` | 生态环境部《2024 年全国电力碳足迹因子》 | **verified** | 电网排放因子权威来源 |
| `SRC-GB51366` | GB/T 51366《建筑碳排放计算标准》（经 T/CECA-G 团体标准附录 D 转引） | **verified** | 建材/回收类再生减排系数 |
| `SRC-MEE-GHG` | 《省级温室气体清单编制指南》 | **verified** | 化石燃料燃烧因子 |
| `SRC-IEA` | IEA 交通与能源统计口径 | provisional | 出行类参考值 |
| `SRC-EEA` | 欧洲环境署交通排放系数 | provisional | 出行类参考值 |
| `SRC-CALC` | 本项目按同类量级推算 | **provisional** | 必须标"参考值"角标 |
| `SRC-CCAP-FW` | 中国碳普惠方法学（食物浪费相关） | provisional | 光盘类参考值 |
| `SRC-DERIVED` | 本项目按「燃油车自身排放 − 该出行方式自身排放」推导 | provisional | **出行类净减排因子（v4.0 统一口径，见 §2.1）** |

**可信度语义**
- `verified`：可直接引用，界面不标角标。
- `provisional`：**界面必须在因子名后标「参考值」角标**，路演不得宣称权威。

---

## 2. 因子全表

> **`recording` 列**＝该因子是否出现在**录入表单的可选子类**中。
> - `recording: true` 的因子共 **20 个**（出行 7 / 水电燃气 5 / 回收 6 / 光盘 2），对应 PLAN §7.1 的「因子库规模 ≥ 20」约束。
> - `recording: false` 的因子（**10 个**）只保留在因子库 JSON 中，**用于科普展示与等效换算**，不出现在录入表单。

### 2.1 出行（`travel`，单位统一 `km`）

> **v4.0 统一口径（重要）**：出行类因子一律采用「**相对燃油车的净减排**」——
> `净减排因子 = max(0, CAR_OWN_FACTOR − 该方式自身排放)`，其中 `CAR_OWN_FACTOR = 0.1920`（燃油车自身排放，见 §2.6）。
> 参与 `减排量 = 活动量 × 因子值` 计算的是「**净减排因子**」列；「自身排放」列**不参与计分**，仅用于科普对照页与「少开一天车」换算。

| # | `subType` | 名称 | 自身排放 kgCO₂e/km | **净减排因子 kgCO₂e/km（计算用）** | 来源 | 可信度 | recording |
|:--:|---|---|--:|--:|---|:--:|:--:|
| 1 | `walk` | 步行 | 0.0000 | **0.1920** | SRC-DERIVED | provisional | ✅ |
| 2 | `bicycle` | 自行车 | 0.0000 | **0.1920** | SRC-DERIVED | provisional | ✅ |
| 3 | `ebike` | 电动自行车 | 0.0120 | **0.1800** | SRC-DERIVED | provisional | ✅ |
| 4 | `bus` | 公交车 | 0.0400 | **0.1520** | SRC-DERIVED | provisional | ✅ |
| 5 | `metro` | 地铁 | 0.0300 | **0.1620** | SRC-DERIVED | provisional | ✅ |
| 6 | `ev` | 新能源车 | 0.1050 | **0.0870** | SRC-DERIVED | provisional | ✅ |
| 7 | `carpool` | 拼车（人均分摊） | 0.1200 | **0.0720** | SRC-DERIVED | provisional | ✅ |
| 8 | `car` | 燃油车（**对照基准**，不录入） | 0.1920 | 0.0000 | SRC-EEA | provisional | ❌ |
| 9 | `motorcycle` | 摩托车 | 0.1030 | 0.0890 | SRC-DERIVED | provisional | ❌ |
| 10 | `hsr` | 高铁 | 0.0270 | 0.1650 | SRC-DERIVED | provisional | ❌ |
| 11 | `flight` | 飞机（国内经济舱） | 0.1580 | 0.0340 | SRC-DERIVED | provisional | ❌ |

> **替代基准说明（v4.0）**：每一种出行方式都按「**这一段路如果开燃油车会排多少、现在换了别的方式省下多少**」计算，所以 `bus` / `metro` / `ev` / `carpool` 的因子 = `0.1920 − 自身排放`，**不再二次相减**。
>
> - `car` 的净减排因子恒为 `0.0000`（开燃油车本身不产生减排），它只作为**对照基准**出现在科普页；「少开一天车」这种"没开车"的行为**取 `CAR_OWN_FACTOR = 0.1920`**（见 §3.2），**不得取表里 car 的 0.0000**。
> - `walk` / `bicycle` 的因子**不是 0**：步行与骑行的自身排放确实是 0，但它们的减排意义正是「替代了本会发生的那次驾车出行」，故净减排因子 = 燃油车全量 `0.1920`。若记 0，则「骑行 5 km」会得到 0 减排、0 积分，与「零碳出行」每日目标的设计意图（骑行 5 km → 0.9600 kg → 96 分）直接冲突。
> - 因此 `walk` / `bicycle` / `ev` 的可信度由 `verified` 降为 `provisional`：它们的**自身排放**数据可信，但**净减排值**继承了对照基准 `0.1920`（SRC-EEA，provisional）的不确定性。

### 2.2 水电燃气（`utility`）

| # | `subType` | 名称 | 单位 | 因子值 | 来源 | 可信度 | recording |
|:--:|---|---|---|--:|---|:--:|:--:|
| 12 | `elec_grid` | 电网用电 | kg/kWh | 0.5703 | SRC-MEE-2024 | verified | ✅ |
| 13 | `water` | 自来水 | kg/L | 0.000168 | SRC-CALC | provisional | ✅ |
| 14 | `gas` | 天然气 | kg/m³ | 2.1840 | SRC-MEE-GHG | verified | ✅ |
| 15 | `lpg` | 液化石油气 | kg/kg | 3.1010 | SRC-MEE-GHG | verified | ✅ |
| 16 | `heating` | 集中供暖 | kg/m²·月 | 3.1000 | SRC-CALC | provisional | ✅ |
| 17 | `water_treat` | 污水处理（避免） | kg/L | 0.000120 | SRC-CALC | provisional | ❌ |
| 18 | `elec_thermal` | 燃煤发电（对照） | kg/kWh | 0.8700 | SRC-CALC | provisional | ❌ |
| 19 | `elec_gas` | 燃气发电（对照） | kg/kWh | 0.4200 | SRC-CALC | provisional | ❌ |

> **`elec_grid` 说明**：0.5703 kgCO₂e/kWh 为生态环境部 2024 年全国电力碳足迹因子口径。**不得**与"全国电网平均排放因子(0.5810)"混用。

### 2.3 旧物回收（`recycle`，单位统一 `kg`）

| # | `subType` | 名称 | 因子值 kgCO₂e/kg | 来源 | 可信度 | recording |
|:--:|---|---|--:|---|:--:|:--:|
| 20 | `paper` | 废纸 | 0.9000 | SRC-GB51366 | verified | ✅ |
| 21 | `aluminum` | 废铝 | 9.0000 | SRC-GB51366 | verified | ✅ |
| 22 | `steel` | 废钢铁 | 1.2000 | SRC-GB51366 | verified | ✅ |
| 23 | `plastic` | 废塑料 | 1.5000 | SRC-GB51366 | verified | ✅ |
| 24 | `glass` | 废玻璃 | 1.0000 | SRC-GB51366 | verified | ✅ |
| 25 | `electronic` | 废电子产品 | 12.0000 | SRC-GB51366 | verified | ✅ |
| 26 | `textile` | 旧衣物 | 3.6000 | SRC-GB51366 | verified | ❌ |
| 27 | `wood` | 废木材 | 0.7000 | SRC-CALC | provisional | ❌ |

> **件数换算**：录入表单提供"按件"输入，换算常量 `AVG_ITEM_WEIGHT_KG`（见 §3.2）。

### 2.4 光盘行动（`plate`）

| # | `subType` | 名称 | 单位 | 因子值 | 来源 | 可信度 | recording |
|:--:|---|---|---|--:|---|:--:|:--:|
| 28 | `meal` | 光盘行动·按餐次 | kg/次 | 0.3500 | SRC-CCAP-FW | provisional | ✅ |
| 29 | `food_waste` | 减少食物浪费·按重量 | kg/kg | 2.5000 | SRC-CCAP-FW | provisional | ✅ |
| 30 | `kitchen_waste` | 厨余垃圾减量（对照） | kg/kg | 0.9000 | SRC-CALC | provisional | ❌ |

### 2.5 因子库统计

| 项 | 数量 |
|---|--:|
| 因子总数 | **30**（出行 11 / 水电燃气 8 / 回收 8 / 光盘 3 = **30**，编号 #1–#30） |
| `recording: true`（进录入表单） | **20**（出行 7 / 水电燃气 5 / 回收 6 / 光盘 2） |
| `recording: false`（只做展示/换算） | **10**（出行 4 / 水电燃气 3 / 回收 2 / 光盘 1） |
| `verified` | **10**（水电燃气 3 + 回收 7） |
| `provisional` | **20** |

> **v4.0 修正**：v3 曾误写「总数 31、`recording:false` 11、`verified` 14」——三处分项相加均对不上（11+8+8+3=30、20+10=30、10+20=30）。现已按上表逐行重数并改正。出行类因子统一改为「净减排」口径后，其可信度整体降为 `provisional`（继承对照基准 `CAR_OWN_FACTOR` 的不确定性），故 `verified` 由 13 降为 **10**。

### 2.6 换算与等效常量

| 常量名 | 值 | 单位 | 说明 |
|---|--:|---|---|
| `CAR_OWN_FACTOR` | 0.1920 | kgCO₂e/km | **燃油车自身排放**；出行类净减排因子 = `max(0, 该值 − 自身排放)`（见 §2.1），「少开一天车」也用它（见 §3.2） |
| `TREE_ABSORB_KG_PER_YEAR` | 18.3 | kgCO₂e/棵·年 | 一棵树年均固碳量 |
| `CAR_KM_PER_KG` | 5.21 | km/kg | 1 kgCO₂e ≈ 燃油车少开 5.21 km |
| `PHONE_CHARGE_KG` | 0.0082 | kgCO₂e/次 | 1 kgCO₂e ≈ 手机充电 122 次 |
| `AVG_CAR_TRIP_KM` | 8.0 | km/次 | 一次典型驾车出行里程 |
| `AVG_ITEM_WEIGHT_KG` | 0.5 | kg/件 | 回收"按件"输入时的平均质量 |
| `KWH_PER_KG` | 1.75 | kWh/kg | 1 kgCO₂e ≈ 1.75 kWh 电网用电 |

---

## 3. 核算公式

### 3.1 主公式（唯一口径，铁律 2）

```
减排量(kgCO₂e) = 活动量 × 因子值
```

- **保留 4 位小数存储**，展示保留 2 位小数（结果 < 1 kg 时展示 3 位）。
- **v4.0 变更：彻底删除修正系数 `correctionFactor`**。
  - 历史做法（已废弃）：`减排量 = 活动量 × 因子值 × 修正系数`，修正系数取 0.9 / 1.0 / 1.1 三档。
  - 删除理由：档位既增加实现复杂度，又让**手算验收与评审解释**变模糊；改为单一因子值后，任何一条记录都可被现场手算复核。
  - **影响面**：`carbon-factors.json` 的 `meta.correctionOptions` 字段删除；`carbon_record.correction_factor` 列删除；录入页不再有"计算档位"控件；APPENDIX-C / D / E 中所有涉及档位的条目同步删除。
- **禁止增量累加**：每条记录独立按上述公式算，不得把新活动量累加到旧活动量上再算。

### 3.2 按次 / 按件换算

| 输入方式 | 换算 |
|---|---|
| 回收"按件" | `活动量(kg) = 件数 × AVG_ITEM_WEIGHT_KG` |
| "少开一天车"等效 | `活动量(km) = 天数 × AVG_CAR_TRIP_KM`，因子取 **`CAR_OWN_FACTOR = 0.1920`**（见 §2.6）。**注意：不取 §2.1 表里 `car` 的净减排因子 0.0000**——"本来要开车但没开"省下的正是燃油车全量排放 |
| 燃气填金额 | 由用户所在地气价反推 `m³`，**气价由用户自己输入**，不内置任何地区气价 |

### 3.3 积分换算与封顶（口径与 PLAN §9 完全一致）

```
单笔应得 C = round(减排量 × 100)          // 1 kgCO₂e = 100 分
今日已得 D = SUM(point_record.points)
             WHERE user_id = ?
               AND occurred_at ∈ [今日 00:00, 今日 23:59:59]
               AND source_type IN ('record', 'record_capped')
               AND is_deleted = 0
实入 A = max(0, min(C, 200 − D))
capped = (A < C)
```

| 规则 | 内容 |
|---|---|
| 换算口径 | **1 kgCO₂e = 100 分** |
| 记录类日封顶 | **200 分**（`MAX_DAILY_RECORD_POINT = 200`） |
| 目标奖励 | **不封顶**，不计入 D |
| 徽章 | **不发积分** |
| 小于 1 分 | `减排量 < 0.005 kg` 时**不生成积分流水**（仍可保存碳记录） |
| 四舍五入 | `0.005 kg → round(0.5) = 1 分` |
| 判定数据源 | **`point_record` 实时聚合**，不读 `point_daily_stat` |
| `point_daily_stat` | **纯展示缓存**，可由 `PointService.rebuildDailyStat(userId)` 全量重建，验收 A5 校验一致性 |

**通胀测算（设计依据，与 PLAN §9.6 一致）**

| 项 | 数值 |
|---|--:|
| 典型单笔记录应得 | 约 96~1350 分（视行为） |
| 典型单日记录实得 | **200 分**（封顶生效） |
| 典型单日目标奖励 | 约 55 分（S1+S2+S3） |
| 典型单日合计 | 约 **255 分** |
| 典型单月合计 | 约 **7,650 分** |
| 集齐 8 头像框总价 | **51,000 分** → 约 **7 个月** |

### 3.4 数值精度与存储

| 项 | 规则 |
|---|---|
| 因子值 | 存 6 位小数，展示 4 位 |
| 减排量 | **存 4 位小数**（`REAL` / `DOUBLE`） |
| 展示减排量 | 2 位小数；`< 1 kg` 时 3 位小数 |
| 积分 | **整数**，只来自 `round()` |
| 禁止 | 用浮点累加求总量（一律用 SQL `SUM()` 或按记录逐条重算） |

### 3.5 目标 ↔ 因子绑定表

> 与 PLAN §10 的 11 个目标逐条对应，`GoalService` 判定时必须按本表取数。

| 目标 | 判定用到的因子 | 聚合方式 | `period_key` 格式 |
|---|---|---|---|
| S1 零碳出行 | `travel` 类、`subType ∈ {walk, bicycle, ebike, bus, metro, carpool}` | `COUNT(*) ≥ 1` | `D:YYYY-MM-DD` |
| S2 省电小标兵 | `utility.elec_grid` | `SUM(amount) ≥ 5`（kWh） | `D:YYYY-MM-DD` |
| S3 光盘卫士 | `plate.meal` | `COUNT(*) ≥ 1` | `D:YYYY-MM-DD` |
| S4 回收一袋 | `recycle` 类全部 | `COUNT(*) ≥ 3`（条数） | `W:YYYY-Www` |
| S5 记录不间断 | —（不限类型） | `COUNT(DISTINCT 日期) ≥ 5` | `W:YYYY-Www` |
| M1 百公里绿色出行 | `travel` 类、`subType ∈ {walk, bicycle, ebike, bus, metro, carpool}` | `SUM(amount) ≥ 100`（km） | `M:YYYY-MM` |
| M2 减碳吨目标 | —（全部记录） | `SUM(reduction_kg) ≥ 50` | `Q:YYYY-Qq` |
| M3 回收百千克 | `recycle` 类、`unit = 'kg'` | `SUM(amount) ≥ 20`（kg） | `Q:YYYY-Qq` |
| M4 光盘习惯养成 | `plate.meal` | `COUNT(*) ≥ 20` | `M:YYYY-MM` |
| M5 减碳达人 | —（全部记录） | `SUM(reduction_kg) ≥ 200` | `Y:YYYY` |
| L1 种树百天计划 | —（不限类型） | 注册起 100 天窗口内 `COUNT(DISTINCT 日期) ≥ 80` | `L:YYYY-MM-DD`（注册日） |

**周期口径**：日 = 自然日；周 = **ISO 周（周一 00:00 起）**；月 = 自然月；季 = 1/4/7/10 月起；年 = 自然年；L1 = 注册日起 100 天。

---

## 4. 输入合理范围（超限提示但不阻断）

| 类目 | 上限 | 超限行为 |
|---|--:|---|
| 出行单次距离 | 200 km | Toast 提示范围异常；仍保存，标 `is_abnormal = 1` |
| 用电 | 200 kWh | 同上 |
| 用水 | 2000 L | 同上 |
| 天然气 | 100 m³ | 同上 |
| 回收质量 | 500 kg | 同上 |
| 光盘 | 20 次 | 同上 |

- `is_abnormal = 1` 的记录**照常参与减排量与积分计算**，仅在记录详情页显示"数值异常"角标。
- 下限：所有数值必须 **> 0**，否则保存按钮置灰。

---

## 5. 等效换算文案（首页与分享卡片使用）

| 条件 | 文案模板 |
|---|---|
| `reduction ≥ 18.3` | `相当于种下 {reduction/18.3 保留1位} 棵树` |
| `reduction ≥ 5.21` | `相当于少开 {reduction×5.21 保留0位} 公里燃油车` |
| `reduction ≥ 1` | `相当于给手机充电 {reduction/0.0082 保留0位} 次` |

> 命中多条时**按上表顺序取第一条**（不做并列展示），保证文案长度可控。

---

## 6. 因子维护规程（四步）

1. **登记来源**：新因子必须填写 `source` 与 `confidence`，`source` 不存在时先补进 §1 表格。
2. **标注可信度**：无权威依据一律 `provisional`，并在界面显示「参考值」角标。
3. **版本号 +1**：修改任何因子值必须提升因子库版本（`CF-2026.2` → `CF-2026.3`）。
4. **历史不改写**：旧记录保存了因子快照（铁律 3），**永不回算**；只有新记录使用新因子值。

---

## 7. 因子库 JSON 全文

> 落盘路径：`app/entry/src/main/resources/rawfile/factors/carbon-factors.json`
> **`correctionOptions` 字段已删除**（v4.0）。

```json
{
  "meta": {
    "version": "CF-2026.2",
    "updatedAt": "2026-02-01",
    "owner": "carbonboo",
    "note": "单一因子值口径，无修正系数"
  },
  "sources": [
    { "id": "SRC-MEE-2024", "name": "生态环境部 2024 年全国电力碳足迹因子", "level": "verified" },
    { "id": "SRC-GB51366", "name": "GB/T 51366 建筑碳排放计算标准（T/CECA-G 附录 D 转引）", "level": "verified" },
    { "id": "SRC-MEE-GHG", "name": "省级温室气体清单编制指南", "level": "verified" },
    { "id": "SRC-IEA", "name": "IEA 交通与能源统计口径", "level": "provisional" },
    { "id": "SRC-EEA", "name": "欧洲环境署交通排放系数", "level": "provisional" },
    { "id": "SRC-CALC", "name": "本项目按同类量级推算", "level": "provisional" },
    { "id": "SRC-CCAP-FW", "name": "中国碳普惠方法学（食物浪费）", "level": "provisional" },
    { "id": "SRC-DERIVED", "name": "本项目按「燃油车自身排放 − 该方式自身排放」推导", "level": "provisional" }
  ],
  "categories": [
    { "key": "travel", "name": "出行", "unit": "km", "icon": "ic_cat_travel", "color": "#4A90D9", "order": 1 },
    { "key": "utility", "name": "水电燃气", "unit": "mixed", "icon": "ic_cat_utility", "color": "#E6A23C", "order": 2 },
    { "key": "recycle", "name": "旧物回收", "unit": "kg", "icon": "ic_cat_recycle", "color": "#7FB069", "order": 3 },
    { "key": "plate", "name": "光盘行动", "unit": "mixed", "icon": "ic_cat_plate", "color": "#D98C6A", "order": 4 }
  ],
  "factors": [
    { "category": "travel", "subType": "walk",        "name": "步行",            "unit": "km",   "value": 0.1920, "ownValue": 0.0000, "source": "SRC-DERIVED", "confidence": "provisional", "recording": true  },
    { "category": "travel", "subType": "bicycle",     "name": "自行车",          "unit": "km",   "value": 0.1920, "ownValue": 0.0000, "source": "SRC-DERIVED", "confidence": "provisional", "recording": true  },
    { "category": "travel", "subType": "ebike",       "name": "电动自行车",      "unit": "km",   "value": 0.1800, "ownValue": 0.0120, "source": "SRC-DERIVED", "confidence": "provisional", "recording": true  },
    { "category": "travel", "subType": "bus",         "name": "公交车",          "unit": "km",   "value": 0.1520, "ownValue": 0.0400, "source": "SRC-DERIVED", "confidence": "provisional", "recording": true  },
    { "category": "travel", "subType": "metro",       "name": "地铁",            "unit": "km",   "value": 0.1620, "ownValue": 0.0300, "source": "SRC-DERIVED", "confidence": "provisional", "recording": true  },
    { "category": "travel", "subType": "ev",          "name": "新能源车",        "unit": "km",   "value": 0.0870, "ownValue": 0.1050, "source": "SRC-DERIVED", "confidence": "provisional", "recording": true  },
    { "category": "travel", "subType": "carpool",     "name": "拼车（人均）",    "unit": "km",   "value": 0.0720, "ownValue": 0.1200, "source": "SRC-DERIVED", "confidence": "provisional", "recording": true  },
    { "category": "travel", "subType": "car",         "name": "燃油车（对照）",  "unit": "km",   "value": 0.0000, "ownValue": 0.1920, "source": "SRC-EEA",      "confidence": "provisional", "recording": false },
    { "category": "travel", "subType": "motorcycle",  "name": "摩托车（对照）",  "unit": "km",   "value": 0.0890, "ownValue": 0.1030, "source": "SRC-DERIVED", "confidence": "provisional", "recording": false },
    { "category": "travel", "subType": "hsr",         "name": "高铁（对照）",    "unit": "km",   "value": 0.1650, "ownValue": 0.0270, "source": "SRC-DERIVED", "confidence": "provisional", "recording": false },
    { "category": "travel", "subType": "flight",      "name": "飞机（对照）",    "unit": "km",   "value": 0.0340, "ownValue": 0.1580, "source": "SRC-DERIVED", "confidence": "provisional", "recording": false },

    { "category": "utility", "subType": "elec_grid",   "name": "电网用电",       "unit": "kWh",   "value": 0.5703,   "source": "SRC-MEE-2024", "confidence": "verified",    "recording": true  },
    { "category": "utility", "subType": "water",       "name": "自来水",         "unit": "L",     "value": 0.000168, "source": "SRC-CALC",     "confidence": "provisional", "recording": true  },
    { "category": "utility", "subType": "gas",         "name": "天然气",         "unit": "m³",    "value": 2.1840,   "source": "SRC-MEE-GHG",  "confidence": "verified",    "recording": true  },
    { "category": "utility", "subType": "lpg",         "name": "液化石油气",     "unit": "kg",    "value": 3.1010,   "source": "SRC-MEE-GHG",  "confidence": "verified",    "recording": true  },
    { "category": "utility", "subType": "heating",     "name": "集中供暖",       "unit": "m²·月", "value": 3.1000,   "source": "SRC-CALC",     "confidence": "provisional", "recording": true  },
    { "category": "utility", "subType": "water_treat", "name": "污水处理（对照）","unit": "L",    "value": 0.000120, "source": "SRC-CALC",     "confidence": "provisional", "recording": false },
    { "category": "utility", "subType": "elec_thermal","name": "燃煤发电（对照）","unit": "kWh",   "value": 0.8700,   "source": "SRC-CALC",     "confidence": "provisional", "recording": false },
    { "category": "utility", "subType": "elec_gas",    "name": "燃气发电（对照）","unit": "kWh",   "value": 0.4200,   "source": "SRC-CALC",     "confidence": "provisional", "recording": false },

    { "category": "recycle", "subType": "paper",      "name": "废纸",       "unit": "kg", "value": 0.9000,  "source": "SRC-GB51366", "confidence": "verified",    "recording": true  },
    { "category": "recycle", "subType": "aluminum",   "name": "废铝",       "unit": "kg", "value": 9.0000,  "source": "SRC-GB51366", "confidence": "verified",    "recording": true  },
    { "category": "recycle", "subType": "steel",      "name": "废钢铁",     "unit": "kg", "value": 1.2000,  "source": "SRC-GB51366", "confidence": "verified",    "recording": true  },
    { "category": "recycle", "subType": "plastic",    "name": "废塑料",     "unit": "kg", "value": 1.5000,  "source": "SRC-GB51366", "confidence": "verified",    "recording": true  },
    { "category": "recycle", "subType": "glass",      "name": "废玻璃",     "unit": "kg", "value": 1.0000,  "source": "SRC-GB51366", "confidence": "verified",    "recording": true  },
    { "category": "recycle", "subType": "electronic", "name": "废电子产品", "unit": "kg", "value": 12.0000, "source": "SRC-GB51366", "confidence": "verified",    "recording": true  },
    { "category": "recycle", "subType": "textile",    "name": "旧衣物",     "unit": "kg", "value": 3.6000,  "source": "SRC-GB51366", "confidence": "verified",    "recording": false },
    { "category": "recycle", "subType": "wood",       "name": "废木材",     "unit": "kg", "value": 0.7000,  "source": "SRC-CALC",     "confidence": "provisional", "recording": false },

    { "category": "plate", "subType": "meal",         "name": "光盘行动（按餐次）", "unit": "次", "value": 0.3500, "source": "SRC-CCAP-FW", "confidence": "provisional", "recording": true  },
    { "category": "plate", "subType": "food_waste",   "name": "减少食物浪费",       "unit": "kg", "value": 2.5000, "source": "SRC-CCAP-FW", "confidence": "provisional", "recording": true  },
    { "category": "plate", "subType": "kitchen_waste","name": "厨余减量（对照）",   "unit": "kg", "value": 0.9000, "source": "SRC-CALC",     "confidence": "provisional", "recording": false }
  ],
  "conversions": {
    "AVG_ITEM_WEIGHT_KG": 0.5,
    "AVG_CAR_TRIP_KM": 8.0,
    "KWH_PER_KG": 1.75,
    "CAR_OWN_FACTOR": 0.1920
  },
  "equivalents": {
    "TREE_ABSORB_KG_PER_YEAR": 18.3,
    "CAR_KM_PER_KG": 5.21,
    "PHONE_CHARGE_KG": 0.0082
  },
  "limits": {
    "travelKm": 200,
    "elecKwh": 200,
    "waterL": 2000,
    "gasM3": 100,
    "recycleKg": 500,
    "plateTimes": 20
  },
  "points": {
    "perKgCo2e": 100,
    "dailyRecordCap": 200,
    "minReductionForPoint": 0.005,
    "carbonCoinRate": 100
  }
}
```

---

## 8. 因子复核清单（编码前完成）

| # | 待复核项 | 当前值 | 建议来源 | 状态 |
|:--:|---|---|---|---|
| 1 | 电动自行车因子 | 0.0120 kg/km | 查找国内电动自行车全生命周期研究 | ⬜ 待复核 |
| 2 | 燃油车对照基准 `CAR_OWN_FACTOR` | 0.1920 kg/km | 用国内乘用车平均油耗实测值核对（**出行类全部净减排因子都由它派生**） | ⬜ 待复核 |
| 3 | 自来水与污水处理因子 | 0.000168 / 0.000120 kg/L | 地方水务公开数据 | ⬜ 待复核 |
| 4 | 集中供暖因子 | 3.1000 kg/m²·月 | 北方采暖地区实测值 | ⬜ 待复核 |
| 5 | 光盘行动按餐次因子 | 0.3500 kg/次 | 碳普惠方法学原文核对 | ⬜ 待复核 |

> **已闭环项（v4.0）**：原第 2 项「公交 / 地铁替代基准口径」已由用户拍板采用「相对燃油车净减排」口径定案（见 §2.1），不再列为待复核；复核重心转为**核对 `CAR_OWN_FACTOR = 0.1920` 这个基准值本身**，因为它一改，出行 11 个因子全部跟着变。

> 复核完成前，以上 5 项在界面**必须显示「参考值」角标**，路演话术必须说明"部分因子为参考值"。

---

## 9. v4.0 相对 v3 的变更摘要

| 变更 | 说明 |
|---|---|
| **删除修正系数** | 主公式简化为 `活动量 × 因子值`；`correctionOptions`、`correction_factor` 列、录入页档位控件全部移除 |
| **出行类统一为「净减排」口径** | 出行因子 = `max(0, CAR_OWN_FACTOR − 自身排放)`；`walk`/`bicycle` 由 0.0000 改为 **0.1920**（骑行 5 km 得 0.9600 kg / 96 分），`bus` 0.1520、`metro` 0.1620、`ev` 0.0870、`carpool` 0.0720、`ebike` 0.1800；JSON 每个出行因子新增 `ownValue` 字段保留自身排放值供科普对照 |
| **新增常量 `CAR_OWN_FACTOR = 0.1920`** | 出行净减排因子的对照基准；「少开一天车」改用它（不再误取 `car` 行的 0.0000） |
| **因子按 `recording` 分层** | **30** 个因子中 **20 个**进录入表单（满足 PLAN §7.1 的「≥20」约束），**10 个**只做展示与换算 |
| **统计数字订正** | v3 误写的「总数 31 / `recording:false` 11 / `verified` 14」三处相加皆不成立，已改为 **30 / 10 / verified 10、provisional 20** |
| **积分口径换源** | 封顶判定改为 `point_record` 实时聚合，`point_daily_stat` 降级为可重建的展示缓存 |
| **新增碳币兑换率** | `points.carbonCoinRate = 100`（`100 积分 = 1 碳币`，单向） |
| **JSON 版本** | `CF-2026.1` → `CF-2026.2` |
