#!/usr/bin/env node
/**
 * 协议补全代理（就地跑在独立进程里，串在"真实客户端 ↔ 真实服务端"之间）。
 *
 * 用途只有一个：附录 B §5.3 规定服务端响应里的 `offsetMs` = **服务端时钟 − 客户端时钟**，
 * 而服务端只在 push 响应里给这个字段（`SyncPullData` 没有它）。为了让"客户端取反换算
 * `clientOffsetMs = -respOffsetMs`"这条契约**可被端到端验证**，本代理把同一轮 push 的
 * `offsetMs` 原样补进紧随其后的 pull 响应里 —— 数据面完全由真实服务端产生，代理只补这一个字段。
 *
 * 用法：node proxy.mjs <upstreamBaseUrl>   （监听 127.0.0.1 的随机端口）
 * 就绪后在 stdout 打印一行：__L2PROXY__{"port":<n>}
 *
 * 注意：**必须独立进程**。它若跑在用例驱动进程里，驱动的 `spawnSync` 会阻塞事件循环，
 * 代理就无法应答设备子进程，直接把用例挂死。
 */
const upstream = process.argv[2];
if (upstream === undefined) {
  console.error('用法: node proxy.mjs <upstreamBaseUrl>');
  process.exit(2);
}
const nodeHttp = await import('node:http');
let lastOffset = 0;

const server = nodeHttp.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    const headers = { 'Content-Type': 'application/json' };
    if (req.headers.authorization !== undefined) {
      headers.Authorization = req.headers.authorization;
    }
    fetch(`${upstream}${req.url}`, {
      method: req.method,
      headers,
      body: req.method === 'GET' ? undefined : body,
      signal: AbortSignal.timeout(15000),
    })
      .then(async (up) => {
        let text = await up.text();
        if (req.url.includes('/sync/push')) {
          try {
            lastOffset = JSON.parse(text).data.offsetMs;
          } catch (e) {
            lastOffset = 0;
          }
        }
        if (req.url.includes('/sync/pull')) {
          try {
            const o = JSON.parse(text);
            o.data.offsetMs = lastOffset;
            text = JSON.stringify(o);
          } catch (e) {
            /* 上游不是 JSON 就原样透传 */
          }
        }
        res.writeHead(up.status, { 'Content-Type': 'application/json' });
        res.end(text);
      })
      .catch((e) => {
        res.writeHead(502, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ proxyError: String(e) }));
      });
  });
});
server.listen(0, '127.0.0.1', () => {
  console.log(`__L2PROXY__${JSON.stringify({ port: server.address().port })}`);
});
