# 服务端作为账号与同步后端（不接华为账号）

**Status**: accepted（2026-10-14 立；2026-11-06 补记决策 ①②③，未决项只剩 ④）

碳小布要求"多设备协同"，原计划交给鸿蒙分布式数据服务；但那条路要求同账号、可信设备、真机（模拟器不支持），且游客态两台设备共用 `local-guest` 会互相串数据。因此改为：**服务端承担账号与数据同步**，登录可选——未登录即纯单机、不上传任何数据，登录后才有跨设备同步、云端备份与家庭合并统计；鸿蒙分布式协同降级为近场演示层（spike 通过才保留）。**不接华为账号**：Account Kit 属 HarmonyOS/HMS 能力，OpenHarmony API 12 无此能力，且需 AGC 建应用 + 签名指纹 + 申请 `quickLoginMobilePhone` 权限，个人开发者落不了地；登录实现统一收敛到 `AuthProvider`（`local` / `server`，预留 `huaweiId`），将来只加实现、不动上层。

## Considered Options

- **华为账号（Account Kit）**：否决。OpenHarmony API 12 文档无该能力（[OpenHarmony 论坛答复](https://forums.openharmony.cn/forum.php?mod=viewthread&tid=3776)）；接入需 AGC 应用配置、签名证书指纹与账号权限申请，仅真机调试（[Codelab](https://developer.huawei.com/consumer/cn/codelabsPortal/carddetails/tutorials_NEXT-AccountKit-QuickLogin)、[全流程](https://blog.csdn.net/weixin_28455801/article/details/158239963)）。
- **自建账号**（`username + password + JWT + bcrypt`，附录 B §5.2 已有）：采用。
- **纯鸿蒙分布式协同**（v4.0 原方案）：降级为 best-effort 演示层，不再作为同步主通路。

## Consequences

- 服务端由"可选演示件"变为**必做件**；其中的 Web 后台管理端仍为可选。
- 需按本决策改写：`PLAN.md` §8.1/§12/§13/§16、`APPENDIX-B` §5.3/§5.4/§6、`APPENDIX-C` §18/§21/§22、`APPENDIX-D` §1.6/§1.10/§6、`APPENDIX-E` §5。旧口径"服务端不承担协同、不作为任何客户端功能的前置依赖"作废。
- 铁律 1 的例外集固定为四类：**登录/注册、多设备同步、商品取价、云端备份**。
- 新增安全与隐私要求：TLS、`/admin` 强口令与限流、客户/管理两套 JWT 密钥隔离、MySQL 不对外；界面文案不得再声称"绝不上传数据"，改为"默认本地，登录后才上传，可随时关闭或注销"。

## Decisions（2026-11-06 负责人拍板，原「未决」①②③ 已关闭）

| # | 原未决问题 | 裁决 |
|:--:|---|---|
| ① | 首次登录时本机历史数据如何绑定上传 | **全部上传并入账号**：登录成功后把本机 `user_id = 'local-guest'` 的历史数据整体改挂账号 `userId`、置 `sync_state = 'pending'`，随后全量上传（`AuthService` 内的 `AccountMigrator` + `CloudSyncService`）。**不做**"只上传新数据"，也**不做**"云端另存一份、本机保留游客数据"。 |
| ② | 鸿蒙分布式协同是否保留 | **保留为近场演示层**：只做同一 Wi-Fi 下双机演示（`distributedDeviceManager` / `distributedDataObject` / `distributedKVStore`），**不承担跨设备一致性**；可整体关闭——摘掉 `DistributedService` 后其余功能不受影响。spike 不通只影响创新项演示，不阻塞任何必做切片。 |
| ③ | 注销账号后云端数据的保留策略 | **软删除并保留 30 天，期间可恢复**：`DELETE /api/v1/auth/account` 校验密码后置 `server_user.is_active = 0` 并给该账号云端行打软删除标记；30 天后由定时任务物理清除。**本机数据一条不删**（注销 ≠ 清空本机）。 |
| ④ | 云服务器规格 / 地区 / 域名 | **仍未定——本 ADR 唯一未决项**。落地形态按"境内轻量云 + 备案域名 + TLS"即可，**不阻塞编码**：服务端地址一律经配置注入，禁止硬编码（AGENTS.md §6）。 |

> 口径落点：`PLAN.md` §5.1/§5.3/§7.9/§7.10/§12/§13、`APPENDIX-B` §5.2/§5.3/§6/§7.1、`APPENDIX-C` §18/§21、`APPENDIX-D` §6、`APPENDIX-E` §5 均已按上表改写。
> 名词口径以 `GLOSSARY.md` §账号与状态 / §三类"同步" 为准（登录、注销、云端同步、云端备份、家庭合并统计）。
