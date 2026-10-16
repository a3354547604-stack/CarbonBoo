/**
 * 工程级 hvigor 构建脚本（Stage 模型 · 应用工程）
 *
 * 职责：把 `@ohos/hvigor-ohos-plugin` 的 appTasks 注册为工程级构建任务。
 * 依赖解析走本地命令行工具链（见 `hvigor/hvigor-config.json5`），不拉公网插件。
 */
import { appTasks } from '@ohos/hvigor-ohos-plugin';

export default {
  system: appTasks,
  plugins: []
};
