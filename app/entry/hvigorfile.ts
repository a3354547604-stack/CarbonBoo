/**
 * entry 模块 hvigor 构建脚本（Stage 模型 · HAP 模块）。
 *
 * 职责：注册 `hapTasks`（编译 ArkTS、打包资源与 HAP）。
 * 模块已是应用内 HAP，`plugins` 保持为空——本工程不引入任何第三方构建插件。
 */
import { hapTasks } from '@ohos/hvigor-ohos-plugin';

export default {
  system: hapTasks,
  plugins: []
};
