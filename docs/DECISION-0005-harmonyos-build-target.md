# DECISION-0005 · 构建目标由 OpenHarmony API 12 切换到 HarmonyOS `6.1.1(24)`

- 日期：2026-11-06
- 状态：**已决策并落地**
- 相关：`app/build-profile.json5`、`docs/toolchain/harmony-cli-build.md §8`、`docs/PLAN.md`（§ 官方要求表）

## 背景

评审/演示要在真机上跑。用 §1 那套 **OpenHarmony API 12** SDK（`runtimeOS: OpenHarmony`）打出的 HAP，
装到 HUAWEI BRE-AL80（`const.ohos.apiversion=24`、`const.ohos.fullname=OpenHarmony-6.1.1.120`、
`const.product.software.version=BRE-AL80 6.1.0.135(SP8C00E120R1P7)`）上被拒：

```
[Fail]Error: failed to install bundle. code:00401004
请尝试匹配设备和应用的 API 版本。设备的 rpcid.json 中不包含以下能力:
SystemCapability.HiDumper / SystemCapability.DataTransitManager /
SystemCapability.MediaLibrary.Core / SystemCapability.MediaLibrary.DistributedCore /
SystemCapability.PowerManager.BatteryManager.Extension / SystemCapability.PowerManager.PowerManager.Extension /
SystemCapability.Security.DeviceSecurityLevel / SystemCapability.UserIAM.UserAuth.PinAuth /
SystemCapability.Security.DeviceAuth
```

这 9 条是 **OpenHarmony 5.0(API 12) syscap 清单**里的条目，HarmonyOS 侧没有同名能力项，
安装器逐条比对全部落空 → 拒装。即：**根因是 SDK 族不匹配，不是权限、不是签名、也不是 API 高低**。
降 API、换证书都救不了。

## 决策

1. `app/build-profile.json5` 改为 `"runtimeOS": "HarmonyOS"`、`"compatibleSdkVersion": "6.1.1(24)"`、
   `"targetSdkVersion": "6.1.1(24)"`，省略 `compileSdkVersion`（由已装 HarmonyOS SDK 决定，本机
   DevEco 26.0.0.851 自带 `HarmonyOS 26.0.0` / `apiVersion 26`）。
2. **`compatibleSdkVersion` 取设备 API 24，不取 SDK 的 26**：`minAPIVersion` 高于设备会直接被拒装；
   设备是 24 就写 24。平台版本号必须是 `6.1.1`，写 `6.1.0(24)` 会报
   `00303083 The platform version '6.1.0' and API version '24' … do not match`
   （判据：`tools/hvigor/hvigor-ohos-plugin/src/sdk/sdk-util.d.ts:46`）。
3. **源级特性集仍是 API 12**：不引入 API 13+ 的新接口，`@ohos.*` 用法、19 张表、页面契约、验收项
   一律不动。这次只换「编译器 + 喂给安装器的 SDK 元数据」，不换业务实现。文档里历史性的「API 12」
   表述（附录 A–F 的规格句、`docs/REVIEW.md` 等）**保持原样**，它们是「用到的能力集合」的基准，
   不是「构建目标」的记录。
4. `app/local.properties` 的 `sdk.dir` 指向 `C:/Program Files/Huawei/DevEco Studio/sdk`
   （其下 `default/{openharmony,hms}` + `sdk-pkg.json`）。该文件不入库。
5. 构建入口由 WSL 的 `hvigorw`（CLT 5.8.9，只认 OpenHarmony SDK）改为 **DevEco 自带 node + hvigor 6.26.8**，
   且 `jbr\bin` 必须在 `PATH`（否则打包阶段 `spawn java ENOENT`）。命令原文见
   `docs/toolchain/harmony-cli-build.md §8`。

## 证据（2026-11-06 实测）

| 检查 | 结果 |
|---|---|
| `assembleHap`（DevEco hvigor 6.26.8 + HarmonyOS SDK 26） | **BUILD SUCCESSFUL**，产物 `entry-default-unsigned.hap` 2.6 MB |
| 产物 `module.json` | `compileSdkVersion 26.0.0.105`、`compileSdkType HarmonyOS`、`targetAPIVersion 60101024`、`minAPIVersion 60101024`、`apiReleaseType Release` |
| 未签名包装机 | `code:9568320 error: no signature file` —— **00401004（API 不匹配）已消失**，只剩签名 |
| 关于页文案 `about_platform_line` | 由「基于 OpenHarmony · API 12」改为「基于 HarmonyOS · API 24」 |

## 遗留

- **签名必须在 DevEco 里做**（`File → Project Structure → Signing Configs` → 自动签名，需登录华为账号 + 设备 USB 授权）。仓库只产 unsigned HAP，签名材料不入库。
- 赛题原文写「基于 OpenHarmony，要求 API 版本 12 及以上」。本决策**没有**降低这个要求：源码仍只用
  API 12 能力；只是构建/安装侧的 SDK 族必须与真机一致。若最终评审机是 OpenHarmony 设备，
  把 `runtimeOS` 改回 `OpenHarmony` + 整数 12 即可（同一份源码两套构建口径，见 `build-profile.json5` 头注释）。
