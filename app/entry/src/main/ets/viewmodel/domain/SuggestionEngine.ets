/**
 * SuggestionEngine —— 首页「今日建议」的候选生成（纯函数，**每日至多 1 条**）。
 *
 * 职责：按优先级产出一组建议，首页只展示第 1 条，点「换一条」按序循环
 *（附录 C §5 规则 4、PLAN §7.13.2：每日至多一条主建议）。
 *
 * 为什么不用随机数：建议里的数字必须来自真实账本（今天几条、连续几天、累计多少），
 * 随机文案会在演示时和页面数字打架；这里全部由 `Formatter` 格式化真实计数。
 */
import { Formatter } from '../../util/Formatter';

/** 建议生成上下文（由 `StatsService` 填）。 */
export interface SuggestionContext {
  recordCount: number;
  todayCount: number;
  streak: number;
  travelCount: number;
  recycleCount: number;
  totalReduction: number;
  todayEarned: number;
  /** 距最近一条记录的天数（无记录给 -1）。 */
  daysSinceLast: number;
  /** 已解锁徽章数。 */
  badgeCount: number;
}

/** 一条建议。 */
export interface Suggestion {
  id: string;
  text: string;
}

export class SuggestionEngine {
  /**
   * 生成建议列表（按优先级降序；至少 1 条）。
   * @param ctx 上下文
   */
  static list(ctx: SuggestionContext): Suggestion[] {
    const out: Suggestion[] = [];
    if (ctx.recordCount === 0) {
      out.push({ id: 'first', text: '今天还没有记录，从一次绿色出行开始吧' });
    }
    if (ctx.todayEarned >= 200) {
      out.push({ id: 'capped', text: '今日记录分已到上限 200 分，明天再来' });
    }
    if (ctx.streak >= 3) {
      out.push({ id: 'streak', text: `已连续记录 ${ctx.streak} 天，今天也别断` });
    }
    if (ctx.daysSinceLast >= 3) {
      out.push({ id: 'back', text: `已经 ${ctx.daysSinceLast} 天没有记录了，补一条吧` });
    }
    if (ctx.travelCount >= 5) {
      out.push({ id: 'travel', text: `绿色出行 ${ctx.travelCount} 次，继续给通勤换个方式` });
    }
    if (ctx.recycleCount === 0 && ctx.recordCount > 0) {
      out.push({ id: 'recycle', text: '还没有回收记录，废纸与废铝的减排量很可观' });
    }
    if (ctx.badgeCount > 0 && ctx.badgeCount < 8) {
      out.push({ id: 'badge', text: `已解锁 ${ctx.badgeCount}/8 枚徽章，看看还差哪几枚` });
    }
    out.push({
      id: 'total',
      text: `累计减排 ${Formatter.reduction(ctx.totalReduction)} kgCO₂e，继续加油`,
    });
    return out;
  }

  /**
   * 取一条（用于「换一条」循环）。
   * @param list 候选
   * @param offset 轮换序号（可任意大，内部取模）
   */
  static pick(list: Suggestion[], offset: number): Suggestion {
    if (list.length === 0) {
      return { id: 'empty', text: '记录一条今天的行为，就能看到减排量' };
    }
    const idx: number = offset % list.length;
    return list[idx];
  }
}
