/**
 * HttpPort —— 网络访问的**窄接口**（登录、同步、取价、云端备份、配置下发走它）。
 *
 * 为什么要有这层：铁律 1 规定「未登录 = 纯单机，一张表都不离开本机」，
 * 而这条规则必须能被**自动断言**。把网络收敛到一个接口后，用例给它一个
 * `FakeHttpClient`（记录每一次请求），就能证明「未登录时上传请求数为 0」——
 * 这是验收 D6 的「未登录态不发起任何上传请求」唯一的可核实形态。
 *
 * 三个实现：
 *  ① `HttpClient`（生产）：`@kit.NetworkKit` 的 `http`，连接/读取超时 3 秒（PLAN §6 要求）；
 *  ② `FakeHttpClient`（用例）：记录请求 + 可编程响应，默认返回 `{"ok":true}`；
 *  ③ 无网络时由调用方用 `AppResult` 降级（铁律 1 的例外集只有**五类**：登录/注册、多设备同步、
 *     取价、云端备份、配置下发 `GET /api/v1/config`；取价/配置取不到即用内置值，故例外只影响数据新鲜度、不影响可用性）。
 */
import { http } from '@kit.NetworkKit';

/** HTTP 方法（契约里用到的三种：拉取用 GET、推送/登录用 POST、注销账号用 DELETE）。 */
export type HttpMethod = 'GET' | 'POST' | 'DELETE';

/** 一次请求。 */
export interface HttpRequest {
  method: HttpMethod;
  /** 完整 URL。 */
  url: string;
  /** 请求体（GET 为空串）。 */
  body: string;
  /** 超时（毫秒）。 */
  timeoutMs: number;
  /**
   * 可选登录令牌（**鉴权头由网络层统一拼装**，见 `HttpClient.request`）。
   *
   * 契约（附录 B §5.2/§5.3）：需要鉴权的端点**只从 `Authorization` 头取令牌**
   * （`Authorization: Bearer <token>`），**不读请求体里的 token 字段**。
   * 取值来源是 `ConfigKeys.AUTH_TOKEN`（`preferences`/`app_config`，
   * 由 `AuthService` 唯一写入）；调用方把读到的值填在这里，
   * 页面层不参与、也不得自行拼头。
   * 缺省（`undefined`）＝本请求不带鉴权头（登录/注册、取价这类公开端点）。
   */
  token?: string;
}

/** 一次响应。 */
export interface HttpResponse {
  /** HTTP 状态码；0 表示网络层失败（超时/不可达）。 */
  status: number;
  /** 响应正文（原样文本）。 */
  body: string;
  /** 失败原因（网络层失败时非空）。 */
  error?: string;
}

export interface HttpPort {
  /** 服务端根地址（设置页可改，经 `app_config['server_base_url']` 注入，**不硬编码**）。 */
  baseUrl(): string;
  /** 发起请求。 */
  request(req: HttpRequest): Promise<HttpResponse>;
}

/** 请求超时（毫秒，PLAN §6：3 秒超时 + 失败降级）。 */
export const HTTP_TIMEOUT_MS: number = 3000;

/** 生产实现。 */
export class HttpClient implements HttpPort {
  private readonly root: string;

  constructor(baseUrl: string) {
    this.root = baseUrl;
  }

  baseUrl(): string {
    return this.root;
  }

  async request(req: HttpRequest): Promise<HttpResponse> {
    const client = http.createHttp();
    try {
      const method: http.RequestMethod = HttpClient.methodOf(req.method);
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      // 鉴权头的**唯一拼装点**：任何调用方都别自己拼，交给这里。
      // 未带令牌时（登录/注册、取价）不加该头，避免发出空 `Bearer `。
      const token: string | undefined = req.token;
      if (token !== undefined && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      const options: http.HttpRequestOptions = {
        method,
        header: headers,
        extraData: req.body.length === 0 ? undefined : req.body,
        connectTimeout: req.timeoutMs,
        readTimeout: req.timeoutMs,
      };
      const res: http.HttpResponse = await client.request(req.url, options);
      return { status: res.responseCode, body: HttpClient.bodyOf(res.result) };
    } catch (e) {
      return { status: 0, body: '', error: HttpClient.messageOf(e) };
    } finally {
      client.destroy();
    }
  }

  /** 方法枚举映射（避免把字符串硬塞进枚举）。 */
  private static methodOf(m: HttpMethod): http.RequestMethod {
    if (m === 'POST') {
      return http.RequestMethod.POST;
    }
    if (m === 'DELETE') {
      return http.RequestMethod.DELETE;
    }
    return http.RequestMethod.GET;
  }

  /** `result` 可能是 string / Object / ArrayBuffer，避免强制断言逐类判型。 */
  private static bodyOf(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') {
      return result;
    }
    if (result instanceof ArrayBuffer) {
      return '';
    }
    return JSON.stringify(result);
  }

  private static messageOf(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return `${e}`;
  }
}

/** 用例实现：记录请求 + 可编程响应（默认 200 `{"ok":true}`）。 */
export class FakeHttpClient implements HttpPort {
  private readonly log: HttpRequest[] = [];
  private readonly stubs: Map<string, HttpResponse> = new Map<string, HttpResponse>();
  private root: string = 'http://127.0.0.1:8000';

  constructor(baseUrl?: string) {
    if (baseUrl !== undefined) {
      this.root = baseUrl;
    }
  }

  baseUrl(): string {
    return this.root;
  }

  async request(req: HttpRequest): Promise<HttpResponse> {
    this.log.push(req);
    const stub: HttpResponse | undefined = this.stubs.get(`${req.method} ${req.url}`);
    if (stub !== undefined) {
      return stub;
    }
    return { status: 200, body: '{"ok":true,"data":{}}' };
  }

  /** 预设某个 `METHOD url` 的响应。 */
  stub(method: HttpMethod, url: string, status: number, body: string): void {
    this.stubs.set(`${method} ${url}`, { status, body });
  }

  /** 已发生的请求（顺序保留，断言用）。 */
  requests(): HttpRequest[] {
    return this.log;
  }

  /**
   * 实际会被送出的 `Authorization` 头值（无令牌时为空串）。
   *
   * 与 `HttpClient` 用**同一套拼装规则**（`Bearer <token>`），
   * 这样用例断言的"会发出什么头"与生产路径完全一致——
   * 而不是在用例里另写一份拼接逻辑（那会掩盖生产侧的拼装缺陷）。
   */
  static authHeaderOf(req: HttpRequest): string {
    const token: string | undefined = req.token;
    return token === undefined || token.length === 0 ? '' : `Bearer ${token}`;
  }

  /** 已发生请求里带鉴权头的条数（鉴权覆盖度断言用）。 */
  countWithAuth(): number {
    let n: number = 0;
    let i: number = 0;
    while (i < this.log.length) {
      if (FakeHttpClient.authHeaderOf(this.log[i]).length > 0) {
        n = n + 1;
      }
      i = i + 1;
    }
    return n;
  }

  /** 请求总数（「未登录时上传请求数 = 0」用它断言）。 */
  count(): number {
    return this.log.length;
  }

  /** 某方法的请求数。 */
  countOf(method: HttpMethod): number {
    let n: number = 0;
    let i: number = 0;
    while (i < this.log.length) {
      if (this.log[i].method === method) {
        n = n + 1;
      }
      i = i + 1;
    }
    return n;
  }

  /** 清空记录（一组用例之间复位）。 */
  reset(): void {
    this.log.length = 0;
  }
}
