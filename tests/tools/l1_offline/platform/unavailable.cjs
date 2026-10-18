/**
 * 未提供垫片的 Kit —— 明确的失败点。
 *
 * 目的：离线执行只覆盖**纯逻辑**模块。若某条链路真的 require 到 `@kit.ArkUI` / `@kit.ImageKit` /
 * `@kit.MediaLibraryKit` 这类只有设备上才存在的 Kit，必须**立刻炸**并说明原因，而不是让 Node 报
 * `MODULE_NOT_FOUND` 或静默返回空对象 —— 后者会让 UI 依赖被"假装满足"，把边界糊掉。
 */

'use strict';

const UNSUPPORTED = [
  '@kit.ArkUI',
  '@kit.ImageKit',
  '@kit.MediaLibraryKit',
  '@kit.NotificationKit',
  '@kit.BackgroundTasksKit',
  '@kit.DistributedServiceKit',
];

module.exports = new Proxy(
  {},
  {
    get(_target, prop) {
      throw new Error(
        `离线 L1 执行不了 ${String(prop)}：该符号来自仅设备可用的 Kit（${UNSUPPORTED.join(' / ')}）。` +
        `L1 只覆盖纯逻辑模块，UI/媒体/通知等必须在真机 hypium 里验证（见 tests/tools/l1_offline/README.md 的边界说明）。`
      );
    },
  }
);
