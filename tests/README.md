# tests/ · 碳小布 CarbonBoo 测试

> 规则依据：`AGENTS.md` §5（测试即完成定义）、§1.4（待修清单）。
> 原则：**能跑的断言才算验收**；人工勾选的条目（附录 D）只是入口，最终必须落到这里的某一层。

---

## 1. 分层

| 层 | 范围 | 现在能否跑 | 位置 |
|:--:|---|:--:|---|
| **L0** | 数值与文档一致性：碳计算 18 组样例、封顶 5 组、边界样例、文档已知冲突扫描 | ✅ **现在就能跑**（只依赖 Python 3） | `tests/tools/check_l0.py` + `tests/cases/` |
| **L1** | 纯逻辑单测（ArkTS / hypium）：计算、封顶、目标与徽章幂等、备份往返、CSV 编码、LWW 合并 | ⏳ 等 `app/` 工程建立后 | `app/entry/src/ohosTest/ets/test/` |
| **L2** | 端侧集成：两条真机协同脚本、飞行模式全功能、性能打点 | ⏳ 等 M2 之后 | 手工脚本 + 录屏，结果记入 `docs/APPENDIX-D` |
| **L3** | 服务端（pytest）：账号、鉴权隔离、取价、同步幂等与冲突 | ⏳ 等 `server/` 建立后 | `server/tests/` |

---

## 2. L0：现在就能跑

```bash
# 报告模式：列出问题，不失败
python3 tests/tools/check_l0.py

# 门禁模式：有任何待修项就退出码 1（建议接进提交前检查）
python3 tests/tools/check_l0.py --strict
```

**退出码**：`0` 通过 ｜ `1` 文档仍有待修项（仅 `--strict`）｜ `2` 数值基准自身算错（任何模式下都是错误）。

它做三件事：
1. 用 `tests/cases/carbon-calc.json` 的样例独立重算 `减排量`、`应得积分 C`、`实入积分 A`，确认**测试基准本身没算错**；
2. 扫描 `docs/` 里已知的错误数值与错误名字（电网因子 0.5777、10 个目标、`REMINDER_AGENT`、`science/index.json` 等）；
3. 打印 `docConflicts` 的人工待修清单。

> **当前预期结果是"基准 OK + 文档有命中"**——这不是测试写错了，而是 AGENTS.md §1.4 的待修项还没清零。

---

## 3. 数据基准：`tests/cases/carbon-calc.json`

**这是所有碳计算与积分数值的唯一真相源**（`AGENTS.md` §1.2）。`docs/` 与它不一致时：改文档，不改基准；确有必要改基准时，必须同时改文档并在同一次提交里完成。

包含：21 个因子（20 个可录入 + `CAR_OWN_FACTOR`）、2 条换算规则、18 组正向样例、5 组封顶样例、6 条边界样例、`docConflicts` 待修清单。

它同时是 L1 的输入：ArkTS 单测**不要重复抄数字**，应当把这份 JSON 拷进 `app/entry/src/ohosTest/resources/` 后逐条断言。

---

## 4. 完成定义（DoD）

一个切片算完成，必须同时满足：

1. `python3 tests/tools/check_l0.py --strict` 通过（该切片涉及的文档冲突已清零）；
2. 该切片对应的 L1/L3 用例全部通过，且**新增的边界用例一起入库**；
3. 提交信息里写清：跑过的命令 + 结果；
4. 不允许为了让测试变绿而改期望值、删断言、跳过用例；**改基准 = 一次需要理由的决策**，必须写进 `docs/DECISION-*.md` 或提交信息正文。

---

## 5. 待建的 L1 / L3 清单（按切片，照抄即可）

### L1 · ArkTS（hypium）— `app/entry/src/ohosTest/ets/test/`
| 文件 | 用例 |
|---|---|
| `CalcSamples.test.ets` | 18 组正向样例：断言 `reductionKg`（4 位小数）与应得 C；**并含 5 组封顶样例**：断言实入 A、`capped` 标记、`<0.005 kg` 不生成流水 |
| ~~`PointCap.test.ets`~~ | **已并入 `CalcSamples.test.ets`**（同上行，5 组封顶样例），不再单独建文件 |
| `GoalIdempotent.test.ets` | 同一 `(goalId, periodKey)` 重复触发只发一次；跨周期重置；11 个目标判定 |
| `BadgeIdempotent.test.ets` | 8 枚徽章幂等、不发积分、删除记录后不撤销 |
| `ShopPurchase.test.ets` | 购买事务原子性、重复购买被拒、余额不足不可买 |
| `BackupRoundTrip.test.ets` | 备份 → 清空 → 恢复：记录/积分/徽章/已购/科普进度五项一致；`schemaVersion` 不符则拒绝 |
| `CsvExport.test.ets` | UTF-8 BOM、`\r\n`、中文列头、无"修正系数"列 |
| `LwwMerge.test.ets` | 新者胜、平局、软删除传播、幂等（同 id 不重复）；**时钟偏移与 `deviceId` 平局裁决当前无断言**（实现未做，见该文件头 `STOP` 记录） |
| `NotLoggedIn.test.ets` | 未登录态：不发起任何上传请求（可注入假 HttpClient 计数） |

> **清单与仓库一致（2026-11-06 核对）**：上表去重后为 **8 个** `.test.ets` 文件，与
> `ls app/entry/src/ohosTest/ets/test/*.test.ets` 实测一致（`List.test.ets` 是套件汇总入口，不计入用例文件）。
> 新增用例文件必须同时在 `List.test.ets` 里 `import` 并调用，否则不会被收集。

### L3 · pytest — `server/tests/`
| 文件 | 用例 |
|---|---|
| `test_auth.py` | 注册/登录/me/登出；用户名与密码规则；重复用户名 409 |
| `test_authz.py` | 客户端 token 访问 `/admin/*` 必须 403；两套密钥互不通用 |
| `test_shop.py` | 取价接口契约；非法数据整份丢弃 |
| `test_sync.py` | push/pull 幂等；LWW 结果与服务端一致；冲突计数正确 |

---

## 6. 目录

```
tests/
├─ README.md              # 本文件
├─ cases/
│  └─ carbon-calc.json    # 数值唯一真相源（L0 与 L1 共用）
└─ tools/
   └─ check_l0.py         # L0 检查器（现在即可运行）
```
