# 提交物（赛题二 · 碳足迹·全民绿色生活碳积分与减排指南）

本目录是**参赛提交材料**，按《开源鸿蒙大赛作品提交要求》生成。全部材料**不含**参赛团队、指导老师、院校信息。

## 一、三份材料

| 文件 | 对应要求 | 实测 |
|---|---|---|
| `01-设计方案-碳小布CarbonBoo.docx` | 详细版 Word；含设计思路、功能实现逻辑、技术架构、软硬件选型、测试结果；**正文宋体、小四（12pt）、1.5 倍行距** | 14.2 MB；251 段 / 23 表 / 22 图；A4；Normal 样式 = 宋体 12pt、行距 1.5；标题用 Heading 1/2/3 + TOC 域 |
| `02-演示视频-碳小布CarbonBoo.mp4` | mp4，≤100MB，**≤5 分钟**，清晰展示操作流程与功能效果 | 4.1 MB；**1920×1080 / 30fps / H.264**；时长 **4:58**（298 秒） |
| `03-演示文稿-碳小布CarbonBoo.pptx` | 图文并茂，讲解 **≤10 分钟** | 10.4 MB；16 页 16:9；13 页含界面截图；每页均带演讲备注 |
| `04-真机录屏片段-碳小布CarbonBoo.mp4` | **补充证据**（不占三件套名额，不进 rar） | 524 KB；720×1594；**14.6 秒**；模拟器上真实滑动/跳转的连续帧（首页 → 记录 → 记录明细 → 看板 → 我的 → 徽章墙） |

## 二、打包命名（提交前必做）

官方格式：`赛题序号+赛题名称+XX学校团队名称.rar`

已在仓库根生成占位包，**提交前请把「XX学校」「XX队」改成你们的真实校名与队名**：

```
赛题二+碳足迹·全民绿色生活碳积分与减排指南+XX学校XX队.rar
```

示例（官方给的样子）：`赛题一+非物质文化遗产指尖传承独立展示应用+XX学校筑梦队.rar`

> 注意：**rar 文件名里要写校名与队名**，但**压缩包内的三份材料里一律不能出现**——这两条并不冲突。

## 三、重新生成

三份材料全部由脚本生成，改内容后重跑即可：

```powershell
$py = 'C:\Users\Admin\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
& $py scripts\build_submission_docx.py      # → submit\01-设计方案-碳小布CarbonBoo.docx
& $py scripts\build_submission_video.py     # → submit\02-演示视频-碳小布CarbonBoo.mp4
& $py scripts\build_submission_pptx.py      # → submit\03-演示文稿-碳小布CarbonBoo.pptx
```

依赖：`python-docx`、`python-pptx`、`Pillow`（bundled Python 已内置）、`imageio-ffmpeg` 提供的 ffmpeg 二进制。

视频脚本的时间轴与 `docs/APPENDIX-E-demo-script.md` §2 的 9 个分镜一一对应；
截图取自 `docs/screenshots/`，是**HarmonyOS 模拟器（API 26 / 1280×2832）上的真实运行截图**，由 `scripts/emu-shot.ps1` 抓取，且全部带演示数据（252 条记录 / 5,641 分 / 55.9896 kgCO₂e）。

## 四、已知情况（如实说明）

1. **截图真机口径**：模拟器（HarmonyOS 7.0.0，API 26）上安装的是**已签名的 HAP**（`scripts/sign-hap.ps1`，OpenHarmony 公开测试证书）；应用本身 `compileSdkVersion` 为 **API 12**。真机（API 12）尚未实测，属未覆盖项。
2. **18 张截图齐备**：含 `15-record-detail`（记录明细）与 `17-science-detail`（科普详情）；数据由「关于与合规 → 连点版本号 7 次 → 开发者选项 → 播种演示数据」生成。
3. **视频是"界面实拍 + 讲解字幕"的合成片**，素材是上面 18 张真实截图；不是屏幕录制。为补足这一点，另附 `04-真机录屏片段-碳小布CarbonBoo.mp4`（模拟器上逐帧抓取的连续操作，14.6 秒），可证明跳转与滚动是真实运行的。`screenrecord` 在该模拟器镜像上不可用，故采用「连续 `snapshot_display` 抽帧 + ffmpeg 合成」的方式取得真录屏。
4. **报名已过期**：官方报名截止 2026-10-30（此前仅填写过预报名）。**作品提交截止 2026-11-06**，按竞赛 QQ 群规定方式提交。
