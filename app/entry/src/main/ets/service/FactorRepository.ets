/**
 * FactorRepository —— 因子库的 **rawfile 加载器**（唯一的因子 I/O 入口）。
 *
 * 职责：
 *  ① 从 `resources/rawfile/factors/carbon-factors.json` 读全文（**完全离线**，不出网）；
 *  ② 交给 `FactorLibrary.parse()` 做逐字段校验，得到强类型因子库；
 *  ③ 进程内缓存：一份不可变的因子库快照，全应用共用（铁律 3 的"因子库升级永不回写历史"
 *     正是靠"快照在内存里只读" + "记录落库时把四字段写死在行上"共同保证）。
 *
 * 铁律 1：因子库是**内置资源**，不依赖网络；服务端后续可下发新的商品价格（`app_config`），
 * 但**因子库不通过网络下发**（附录 A §6 因子维护规程）。
 * 铁律 3：因子库升级只提升 `meta.version`，历史记录的 `factor_value` / `factor_version`
 * 已是行内快照，永不回写。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { FactorLibrary } from './FactorLibrary';

/** rawfile 内相对路径（与附录 A §7 的"落盘路径"一致）。 */
const RAW_PATH: string = 'factors/carbon-factors.json';

export class FactorRepository {
  private static cached: FactorLibrary | undefined = undefined;

  /**
   * 加载因子库（带进程内缓存）。
   * @param context Ability 的 context（取 `resourceManager` 用）
   */
  static async load(context: common.Context): Promise<FactorLibrary> {
    if (FactorRepository.cached !== undefined) {
      return FactorRepository.cached;
    }
    const bytes: Uint8Array = await context.resourceManager.getRawFileContent(RAW_PATH);
    const text: string = new util.TextDecoder().decodeToString(bytes);
    const lib: FactorLibrary = FactorLibrary.parse(text);
    FactorRepository.cached = lib;
    return lib;
  }

  /** 已缓存则返回，否则 undefined（页面可据此决定是否需要 await）。 */
  static peek(): FactorLibrary | undefined {
    return FactorRepository.cached;
  }

  /** 清缓存（仅测试用：验证"重新加载后版本号变化"之类的行为）。 */
  static reset(): void {
    FactorRepository.cached = undefined;
  }
}
