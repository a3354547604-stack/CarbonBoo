/**
 * ShopPriceFetcher —— 商品取价的**唯一网络入口**（附录 B §5.4 / 铁律 1 的例外之一）。
 *
 * 职责（只有这一件事）：
 *  ① `GET /api/v1/shop/items`（**无需 token** —— 附录 B §5.3 开头行与 §5.4 端点表都写明
 *     「只有取价接口无需 token」，故未登录也能拉）；
 *  ② **整份校验**：响应的 `data` 必须是 `{ version: string, items: [...] }`，且每个元素
 *     必备字段齐全、数值合法。**任何一处不合法 → 整份丢弃**（不做部分应用）；
 *  ③ 校验通过才**整份覆盖** `app_config['shop_items']`（连目录 `version` 一起存），
 *     失败/非法/超时则**一个字节都不写**，上一份有效目录原样保留。
 *
 * 为什么"整份"是硬要求（附录 B §5.4 原文）：
 * 「启动时有网 → 拉取并整份覆盖 `app_config['shop_items']`；失败或数据非法 → **整份丢弃**，
 *  继续用上一份有效配置；从未拉到过 → 用 `rawfile/shop/shop-items.json` 内置默认价。」
 * 半份目录比没有目录更糟：部分商品用了新价、部分用旧价，账目与后台对不上且无法解释。
 *
 * 为什么键名是 `shop_items`（收敛依据）：
 *  - `ConfigKeys.SHOP_ITEMS`（`AppConfig.ets:54`）= `'shop_items'`，注释写明"取价整份覆盖用"，
 *    与附录 B §5.4 的同名键**逐字一致**（AGENTS §1.2：附录 B 优先级高于其余叙述）；
 *  - 本文件落地前，`ShopService.remotePrices()` 读的是 `app_config['shop_prices']` ——
 *    该键**在 docs/ 中不存在**（全仓仅出现在 ShopService 自己与 build 产物里），属实现侧自造；
 *  - 服务端 `server/app/schemas/shop.py` 的字段描述里写作 `app_config['shop_items_version']`，
 *    那是**第三个**键名，且只出现在服务端一句描述性文案里，客户端从未使用 → 一并收敛到
 *    `shop_items`（把 `version` 与 `items` 同存一处，避免"目录与版本号分居两个键"的不一致窗口）。
 *
 * 超时：`HTTP_TIMEOUT_MS` = 3 秒（PLAN §6 / 附录 B §5.4 口径）。
 * 铁律 1：取价失败**绝不能阻塞任何本地功能** —— 本类从不抛错给调用方，
 * 调用方（`EntryAbility`）也只是记一行日志。
 */
import { HttpPort, HttpResponse, HTTP_TIMEOUT_MS } from './HttpPort';
import { AppConfig, ConfigKeys } from '../AppConfig';
import { AppResult, fail, ok } from '../../model/Result';
import { JsonArray, JsonObject, asArray, asObject, num, optStr, str } from '../../util/JsonUtil';
import { ShopItem } from '../../model/ShopTypes';

/** 一次取价的结果（供启动日志与用例断言）。 */
export interface ShopPriceOutcome {
  /** 是否整份覆盖成功。 */
  applied: boolean;
  /** 目录版本号（失败时为空串）。 */
  version: string;
  /** 入库商品条数（失败时为 0）。 */
  count: number;
  /** 失败原因（成功时为空串）。 */
  reason: string;
}

/** 允许的 section 取值（附录 B §5.4 / 建表 SQL 注释）。 */
const SECTIONS: string[] = ['frame', 'theme'];

/**
 * 把响应里的一条商品解析成 `ShopItem`；任一字段缺失/非法就抛错，由调用方整份丢弃。
 *
 * 用 `JsonUtil` 的**运行时校验**取值（不是 `as` 断言）：一旦服务端改了字段名或类型，
 * 这里立刻报出字段路径，而不是静默得到 undefined 再把价格写成 NaN。
 * @param o JSON 对象
 * @param index 元素下标（错误信息定位用）
 */
function itemOf(o: JsonObject, index: number): ShopItem {
  const where: string = `shop.items[${index}]`;
  const id: string = str(o, 'id', where);
  const section: string = str(o, 'section', where);
  if (SECTIONS.indexOf(section) < 0) {
    throw new Error(`${where}.section 非法：${section}（允许 frame|theme）`);
  }
  const price: number = num(o, 'price', where);
  if (!Number.isInteger(price) || price < 0) {
    throw new Error(`${where}.price 非法：${price}（要求非负整数）`);
  }
  const onShelf: number = num(o, 'onShelf', where);
  const isDefaultFree: number = num(o, 'isDefaultFree', where);
  const out: ShopItem = {
    id,
    section: section === 'theme' ? 'theme' : 'frame',
    name: str(o, 'name', where),
    price,
    icon: str(o, 'icon', where),
    order: num(o, 'order', where),
    onShelf: onShelf === 0 ? 0 : 1,
    isDefaultFree: isDefaultFree === 0 ? 0 : 1,
  };
  const description: string | undefined = optStr(o, 'description');
  if (description !== undefined) {
    out.description = description;
  }
  return out;
}

export class ShopPriceFetcher {
  private readonly http: HttpPort;
  private readonly cfg: AppConfig;

  /** @param http 网络端口（测试可注入 `FakeHttpClient`） @param cfg `app_config` 门面 */
  constructor(http: HttpPort, cfg: AppConfig) {
    this.http = http;
    this.cfg = cfg;
  }

  /** 取价端点（**无 token**）。 */
  private url(): string {
    return `${this.http.baseUrl()}/api/v1/shop/items`;
  }

  /**
   * 拉取并**整份覆盖**本地目录。**从不抛错**（铁律 1：取价失败不得影响本地功能）。
   *
   * 成功条件全部满足才写库：HTTP 200 + `ok:true` + `data.version` 是非空字符串 +
   * `data.items` 是数组且每项字段合法。
   * @returns 结果摘要；`applied=false` 时 `reason` 说明为何整份丢弃
   */
  async fetchAndStore(): Promise<AppResult<ShopPriceOutcome>> {
    let res: HttpResponse;
    try {
      res = await this.http.request({
        method: 'GET',
        url: this.url(),
        body: '',
        timeoutMs: HTTP_TIMEOUT_MS,
      });
    } catch (e) {
      return fail<ShopPriceOutcome>('SHOP_FETCH_THREW', `取价请求异常，整份丢弃：${ShopPriceFetcher.messageOf(e)}`);
    }
    if (res.status !== 200) {
      return fail<ShopPriceOutcome>('SHOP_FETCH_HTTP', `取价失败（HTTP ${res.status}），整份丢弃，保留上一份目录`);
    }
    let version: string = '';
    let items: ShopItem[] = [];
    try {
      const root: JsonObject = asObject(JSON.parse(res.body), 'shop');
      if (root['ok'] === false) {
        throw new Error('服务端 ok=false');
      }
      const data: JsonObject = asObject(ShopPriceFetcher.mustField(root, 'data'), 'shop.data');
      version = str(data, 'version', 'shop.data');
      if (version.length === 0) {
        throw new Error('shop.data.version 为空');
      }
      const arr: JsonArray = asArray(ShopPriceFetcher.mustField(data, 'items'), 'shop.data.items');
      if (arr.length === 0) {
        throw new Error('shop.data.items 为空（空目录不足以覆盖，整份丢弃）');
      }
      let i: number = 0;
      while (i < arr.length) {
        items.push(itemOf(asObject(arr[i], `shop.data.items[${i}]`), i));
        i = i + 1;
      }
    } catch (e) {
      return fail<ShopPriceOutcome>('SHOP_FETCH_INVALID', `取价数据非法，整份丢弃，保留上一份目录：${ShopPriceFetcher.messageOf(e)}`);
    }
    // 走到这里说明整份都合法 —— 一次性写入目录 + 版本号。
    try {
      await this.cfg.set(ConfigKeys.SHOP_ITEMS, ShopPriceFetcher.toJson(version, items));
    } catch (e) {
      return fail<ShopPriceOutcome>('SHOP_STORE_FAILED', `目录写入失败：${ShopPriceFetcher.messageOf(e)}`);
    }
    return ok<ShopPriceOutcome>({ applied: true, version, count: items.length, reason: '' });
  }

  /** 目录落盘形态：`{ version, items }` 同存一处，避免目录与版本号分居两键的不一致窗口。 */
  private static toJson(version: string, items: ShopItem[]): string {
    return JSON.stringify({ version, items });
  }

  /** 取必填子节点（缺失即抛错 → 由调用方整份丢弃）。公开给读取侧（`ShopService.catalog`）复用同一判据。 */
  static mustField(o: JsonObject, key: string): Object {
    const v: Object | undefined = o[key];
    if (v === undefined) {
      throw new Error(`缺少字段 ${key}`);
    }
    return v;
  }

  private static messageOf(e: Object): string {
    return e instanceof Error ? e.message : `${e}`;
  }
}
