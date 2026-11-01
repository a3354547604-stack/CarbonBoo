# 提交物（赛题二 · 碳足迹·全民绿色生活碳积分与减排指南）

本目录是**参赛提交材料**，按《开源鸿蒙大赛作品提交要求》生成。全部材料**不含**参赛团队、指导老师、院校信息。

## 一、三份材料

| 文件 | 对应要求 | 实测 |
|---|---|---|
| `01-设计方案-碳小布CarbonBoo.docx` | 详细版 Word；含设计思路、功能实现逻辑、技术架构、软硬件选型、测试结果；**正文宋体、小四（12pt）、1.5 倍行距** | 15.6 MB；252 段 / 24 表 / **18 图**；A4；Normal 样式 = 宋体 12pt、行距 1.5；标题用 Heading 1/2/3 + TOC 域 |
| `02-演示视频-碳小布CarbonBoo.mp4` | mp4，≤100MB，**≤5 分钟**，清晰展示操作流程与功能效果 | **团队自行录制的真机操作录屏**（详见第四节第 5 条）；提交前需确认 mp4、≤100MB、≤5 分钟 |
| `03-演示文稿-碳小布CarbonBoo.pptx` | 图文并茂，讲解 **≤10 分钟** | 10.0 MB；**17 页** 16:9；**12 页含界面截图**（一页一屏，图与文字一一对应）；每页均带演讲备注 |

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
# submit\02-演示视频-碳小布CarbonBoo.mp4 由团队自行录屏 + 配音后直接放入，本仓库不提供生成脚本
& $py scripts\build_submission_pptx.py      # → submit\03-演示文稿-碳小布CarbonBoo.pptx
```

依赖：`python-docx`、`python-pptx`、`Pillow`（bundled Python 已内置）、`imageio-ffmpeg` 提供的 ffmpeg 二进制。

视频脚本的时间轴与 `docs/APPENDIX-E-demo-script.md` §2 的 9 个分镜一一对应；
截图取自 `docs/screenshots/`，是**HarmonyOS 模拟器（API 26 / 1280×2832）上的真实运行截图**，由 `scripts/emu-shot.ps1` 抓取，且全部带演示数据（252 条记录 / 55.9896 kgCO₂e / 4,241 分，其中包含一次 1,500 分的头像框兑换）。

## 四、已知情况（如实说明）

1. **截图真机口径**：模拟器（HarmonyOS 7.0.0，API 26）上安装的是**已签名的 HAP**（`scripts/sign-hap.ps1`，OpenHarmony 公开测试证书）；应用本身 `compileSdkVersion` 为 **API 12**。真机（API 12）尚未实测，属未覆盖项。
2. **18 张截图齐备**：含 `15-record-detail`（记录明细）与 `17-science-detail`（科普详情）；数据由「关于与合规 → 连点版本号 7 次 → 开发者选项 → 播种演示数据」生成。
2.1 **近场协同（创新项Ⅰ）实测边界**：已在**两台**模拟器（Mate 90 Pro 1280×2832 + Mate X7 2210×2416）上验证——运行时权限 `ohos.permission.DISTRIBUTED_DATASYNC` 申请通过（`granted=true results=[0]`）、`distributedDeviceManager` 能力判定可用（`available=true`）、无对端时面板正确降级不崩。因两台模拟器无华为账号、未建立可信设备关系，`getAvailableDeviceListSync()` 返回 0，**「发现对端 → 分布式 KV 同步 → 家庭合并」一段未跑通**，该段由 7 条离线用例以假端口覆盖。这也是本轮修掉的一个**真 bug**：该权限属 user_grant，未在运行时申请时任何真机/模拟器都会因 `code 201` 让能力恒判不可用。
3. **演示视频是团队自己录制的真实操作录屏**（在已安装应用上录屏 + 后期配音），不再是早期的静帧合成片。
4. **报名已由学校统一完成**（原官方报名截止 2026-10-30，此前为预报名；现已解决）。**作品提交截止 2026-11-06**，按竞赛 QQ 群规定方式提交。
5. **视频已由团队自行录制**：`02-演示视频-碳小布CarbonBoo.mp4` 请用最终成片覆盖；提交前核对 mp4 格式、≤100MB、≤5 分钟（官方硬指标）。
6. **设备侧自动化测试只跑通一半**：`hypium` 已在模拟器上真实执行——`aa test` 结果 `Tests run: 49, Failure: 0, Error: 38, Pass: 11`。11 条纯逻辑用例通过；38 条依赖真数据库/真 `rawfile` 的用例报 `Parameter error.Illegal context.`（401）与 `GetRawFileContent failed`，根因是 `aa test` 启动的测试进程拿不到 `AbilityContext`（最小探针 `Probe.test.ets` 实测 `getCurrentTopAbility failed=true`、`appContext open ok=false`），**属框架环境限制而非代码缺陷**；这 38 条的覆盖来自离线一致性执行器（`49/49` 通过、复算 323 个断言点一致）。细节见 `docs/VERIFICATION.md §R19`。

