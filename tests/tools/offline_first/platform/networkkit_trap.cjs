/**
 * NetworkKit **平台层陷阱**（t58 用）—— 包住 l1_offline 的 `networkkit.cjs` 垫片。
 *
 * 为什么要多包一层：`l1_offline/platform/networkkit.cjs` 已经有「L1 不出网」的语义（`request()` 默认
 * reject），但它**不会记录**谁尝试出网。本文件在保留原错误文本的前提下，把每次尝试记进
 * `globalThis.__PLATFORM_TRAP__`，并额外提供两种模式：
 *
 *  - `globalThis.__OFFLINE_FIRST_MODE__ === 'throw'`（第一段）：立即 reject 一句带 URL 的错，
 *    用于反证「本机流程偷偷走平台网络」一定会红；
 *  - 其它取值：委托原垫片（于是 `L1_ALLOW_NETWORK` 语义、原始错误文本一字不变）。
 *
 * 边界：**只替换平台 API，不碰任何被测实现**；它只影响 `@kit.NetworkKit` 的说明符解析。
 */

'use strict';

const ORIGINAL = require('../../l1_offline/platform/networkkit.cjs');

const hits = (globalThis.__PLATFORM_TRAP__ = globalThis.__PLATFORM_TRAP__ || []);

function record(url, options) {
  const rec = { url: String(url), method: String((options || {}).method || 'GET') };
  hits.push(rec);
  process.stdout.write(`[TRAP-PLATFORM] @kit.NetworkKit 出网尝试：${rec.method} ${rec.url}\n`);
  return rec;
}

class Request {
  constructor() {
    this._inner = ORIGINAL.http.createHttp();
  }

  request(url, options) {
    record(url, options);
    if (globalThis.__OFFLINE_FIRST_MODE__ === 'throw') {
      return Promise.reject(new Error(
        `离线陷阱（本机流程不得出网）：拦截了对 ${url} 的平台层请求。` +
        `未登录 = 纯单机，本机流程（录入/科普/小铺/备份端点）不允许出网。`
      ));
    }
    return this._inner.request(url, options);
  }

  destroy() {
    return this._inner.destroy();
  }
}

const http = {
  RequestMethod: ORIGINAL.http.RequestMethod,
  createHttp() {
    return new Request();
  },
};

module.exports = { http };
