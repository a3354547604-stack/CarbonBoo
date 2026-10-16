/**
 * 路由常量与路由参数（界面层唯一的"页面名字"来源，对应附录 C §1 的 18 个页面）。
 *
 * 为什么参数不放 NavPathStack 的 param 里直接读：
 *   ArkTS 禁 `as` 强制断言，`navDestination` 的 builder 拿到的 param 是 `Object`，
 *   读字段就必须强转。这里改成 push 时把**类型化**的参数对象放进 `NavParams`，
 *   builder 只按 name 分派、页面读 `NavParams.take()`（类型完整，零断言）。
 */
import { CategoryKey } from '../model/CarbonTypes';

/** 18 个页面的路由名（Tab 5 + 二级页 13）。 */
export class RouteName {
  static readonly HOME: string = 'home';
  static readonly DASHBOARD: string = 'dashboard';
  static readonly RECORD: string = 'record';
  static readonly SCIENCE: string = 'science';
  static readonly MINE: string = 'mine';
  static readonly RECORD_EDIT: string = 'recordEdit';
  static readonly RECORD_DETAIL: string = 'recordDetail';
  static readonly RECORD_SEARCH: string = 'recordSearch';
  static readonly GOAL: string = 'goal';
  static readonly BADGE: string = 'badge';
  static readonly SHOP: string = 'shop';
  static readonly POINT_LOG: string = 'pointLog';
  static readonly SCIENCE_DETAIL: string = 'scienceDetail';
  static readonly SYNC: string = 'sync';
  static readonly INCLUDE: string = 'include';
  static readonly APPEARANCE: string = 'appearance';
  static readonly SETTINGS: string = 'settings';
  static readonly ABOUT: string = 'about';
}

/** 路由参数（字段都可选，页面按需读）。 */
export class RouteParam {
  category?: CategoryKey = undefined;
  recordId?: string = undefined;
  articleId?: string = undefined;
  section?: string = undefined;

  static of(category?: CategoryKey): RouteParam {
    const p: RouteParam = new RouteParam();
    p.category = category;
    return p;
  }

  static record(recordId: string): RouteParam {
    const p: RouteParam = new RouteParam();
    p.recordId = recordId;
    return p;
  }

  static article(articleId: string): RouteParam {
    const p: RouteParam = new RouteParam();
    p.articleId = articleId;
    return p;
  }

  static shopSection(section: string): RouteParam {
    const p: RouteParam = new RouteParam();
    p.section = section;
    return p;
  }
}

/** push 时存下的参数；`take()` 读取后清空，避免下次进入串味。 */
export class NavParams {
  private static current: RouteParam | undefined = undefined;
  private static stack: NavPathStack | undefined = undefined;

  /** 由 `Index` 在首帧把 NavPathStack 交给本类（页面不再各自 @Consume 拿栈）。 */
  static attach(stack: NavPathStack): void {
    NavParams.stack = stack;
  }

  /** 压栈（二级页）。 */
  static push(name: string): void {
    const s: NavPathStack | undefined = NavParams.stack;
    if (s !== undefined) {
      s.pushPath({ name: name });
    }
  }

  /** 出栈。 */
  static pop(): void {
    const s: NavPathStack | undefined = NavParams.stack;
    if (s !== undefined) {
      s.pop();
    }
  }

  static set(param?: RouteParam): RouteParam {
    const p: RouteParam = param === undefined ? new RouteParam() : param;
    NavParams.current = p;
    return p;
  }

  static take(): RouteParam {
    const p: RouteParam = NavParams.current === undefined ? new RouteParam() : NavParams.current;
    NavParams.current = undefined;
    return p;
  }
}
