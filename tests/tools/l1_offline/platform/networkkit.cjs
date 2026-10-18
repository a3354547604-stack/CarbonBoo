/**
 * NetworkKit 垫片 —— `http`。
 *
 * L1 是**纯逻辑**层：网络必须由用例注入的假实现（`HttpPort` 的 test double、`HttpClient` 的替身）承担，
 * 不允许真的出网。所以这里的 `request()` 默认**直接失败**并给出一句能看懂的错，而不是悄悄连本机
 * 或公网 —— 悄悄联网会让"离线可复现"这句话变成假的，也会让同一份代码在评委机器上行为不同。
 *
 * 需要走真网络时（不属于 L1，例如手工排查）显式设 `L1_ALLOW_NETWORK=1`。
 */

'use strict';

const RequestMethod = {
  OPTIONS: 'OPTIONS',
  GET: 'GET',
  HEAD: 'HEAD',
  POST: 'POST',
  PUT: 'PUT',
  DELETE: 'DELETE',
  TRACE: 'TRACE',
  CONNECT: 'CONNECT',
};

class HttpRequest {
  request(url, options) {
    if (process.env.L1_ALLOW_NETWORK !== '1') {
      return Promise.reject(new Error(
        `离线执行（L1）不出网：拦截了对 ${url} 的请求。L1 里网络必须由用例注入的假实现承担；` +
        `若确需真网络，显式设 L1_ALLOW_NETWORK=1（这已不属于 L1 的范畴）。`
      ));
    }
    const opts = options || {};
    const method = opts.method || RequestMethod.GET;
    return fetch(url, {
      method,
      headers: opts.header || {},
      body: typeof opts.extraData === 'string' ? opts.extraData : undefined,
    }).then(async (res) => {
      const text = await res.text();
      return { responseCode: res.status, result: text, header: {} };
    });
  }

  destroy() {
    return Promise.resolve();
  }
}

const http = {
  RequestMethod,
  createHttp() {
    return new HttpRequest();
  },
};

module.exports = { http };
