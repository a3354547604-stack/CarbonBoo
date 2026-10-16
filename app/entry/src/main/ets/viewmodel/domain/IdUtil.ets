/**
 * IdUtil —— 主键生成（客户端生成，多设备不冲突）。
 *
 * 职责：`uuid()` 生成 UUID v4 形态的 36 位字符串，供碳记录、流水、目标、徽章、
 * 购买、外观、科普进度、兑换、分享、日志各表主键使用。
 *
 * 为什么不引第三方 uuid 库：AGENTS §7.1 禁止第三方包，而 v4 的形态要求只有两条
 *（第 13 位固定 `4`、第 17 位取 `8|9|a|b`），20 行足够，且不依赖任何 SDK。
 * 随机源用 `Math.random()`：本应用的冲突概率远低于 `id` 之外的业务唯一键
 *（uq_pr_source / uq_ug / uq_ub / uq_up / uq_ua / uq_sp / uq_uprofile 才是真正的幂等防线）。
 */
export class IdUtil {
  private static readonly HEX: string = '0123456789abcdef';

  /** UUID v4 形态（`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`）。 */
  static uuid(): string {
    let out: string = '';
    let i: number = 0;
    while (i < 32) {
      if (i === 8 || i === 12 || i === 16 || i === 20) {
        out = out + '-';
      }
      if (i === 12) {
        out = out + '4';
      } else if (i === 16) {
        out = out + IdUtil.HEX.charAt(8 + Math.floor(Math.random() * 4));
      } else {
        out = out + IdUtil.HEX.charAt(Math.floor(Math.random() * 16));
      }
      i = i + 1;
    }
    return out;
  }

  /** 设备标识（首次运行生成一次，落 `device_info` 与 `app_config['device_id']`）。 */
  static deviceId(): string {
    return `d-${IdUtil.uuid().substring(0, 8)}`;
  }

  /** 短标识（`user_goal` / `user_badge` / `user_purchase` 等派生行用）。 */
  static shortId(prefix: string): string {
    return `${prefix}_${IdUtil.uuid().substring(0, 12)}`;
  }

  /** 碳记录类流水的幂等键：`<记录ID>#<revision>`（附录 B §2 口径）。 */
  static recordSourceId(recordId: string, revision: number): string {
    return `${recordId}#${revision}`;
  }

  /** 目标类流水的幂等键：`<goalId>:<periodKey>`。 */
  static goalSourceId(goalId: string, periodKey: string): string {
    return `${goalId}:${periodKey}`;
  }
}
