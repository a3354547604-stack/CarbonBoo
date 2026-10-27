# 页面截图（docs/screenshots）

来源：**API 12 预览器实机渲染**（DevEco Studio 26 预览器 + `scripts/preview-run.ps1` 抓取），
不是设计稿、不是手绘。尺寸 **293×639**（预览器按面板高度等比缩放，非设备原始 1080×2340）。

> ⚠️ **全部为空态**：预览器里的 `RdbStore` 是 mock 实现（日志 `The RdbStore.querySql interface in the
> Previewer is a mocked implementation`），静态字典种子写不进库，所以每页都只能看到「还没有数据」。
> 带数据的版本需要真机或模拟器，见 `docs/toolchain/harmony-cli-build.md` §7.2。

## 已拍（16 张）

| 文件 | 页面 | 路由 | 入口 |
|---|---|---|---|
| `01-home.png` | 首页 | `HOME` | Tab 1 |
| `02-dashboard.png` | 数据看板 | `DASHBOARD` | Tab 2 |
| `03-records.png` | 记录列表 | `RECORD` | Tab 3 |
| `04-science.png` | 双碳科普 | `SCIENCE` | Tab 4 |
| `05-mine.png` | 我的 | `MINE` | Tab 5 |
| `06-goal.png` | 目标 | `GOAL` | 我的 → 目标与徽章 |
| `07-badge.png` | 徽章墙 | `BADGE` | 我的 → 目标与徽章 → 右上「徽章墙」 |
| `08-shop.png` | 碳小铺 | `SHOP` | 我的 → 碳小铺 |
| `09-point-log.png` | 积分明细 | `POINT_LOG` | 我的 → 积分明细 |
| `10-include.png` | 碳普惠（模拟） | `INCLUDE` | 我的 → 碳普惠 |
| `11-sync.png` | 设备协同 | `SYNC` | 我的 → 设备协同 |
| `12-appearance.png` | 外观 | `APPEARANCE` | 我的 → 更换外观 |
| `13-settings.png` | 设置 | `SETTINGS` | 我的 → 设置 |
| `14-record-edit.png` | 录入 | `RECORD_EDIT` | 记录 → ＋ 记一笔 |
| `16-record-search.png` | 记录搜索 | `RECORD_SEARCH` | 记录 → 右上 🔍 |
| `18-about.png` | 关于与合规 | `ABOUT` | 设置 → 关于与合规 |

## 待补（2 张，阻塞于「无数据源」）

| 文件 | 页面 | 阻塞原因 |
|---|---|---|
| `15-record-detail.png` | 记录明细 | 需要一条真实记录才能点进去；预览器写不进库 |
| `17-science-detail.png` | 科普详情 | 列表为空 → 无可点项；`ScienceDetailPage.reload()` 第一步 `hub.science.metaOf(id)` 查库即失败 |

补齐条件：真机（先在 `app/build-profile.json5` 配调试签名）或模拟器（`bcdedit /set hypervisorlaunchtype auto` + 重启）。

## 复现命令

```powershell
# 1) DevEco 里打开 app/entry/src/main/ets/pages/Index.ets → Ctrl+Shift+A → preview → 双击「预览器」标签最大化
# 2) 抓图
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\preview-run.ps1 -Action capture -OutFile docs\screenshots\01-home.png
# 3) 点 Tab（y=610；首页 x=31 / 看板 88 / 记录 148 / 科普 207 / 我的 266）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\preview-run.ps1 -Action click -PageX 148 -PageY 610 -OutFile docs\screenshots\03-records.png
```
