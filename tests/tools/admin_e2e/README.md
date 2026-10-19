# `tests/tools/admin_e2e/` —— `/admin` 浏览器级端到端验证（Edge headless + CDP）

## 解决什么问题

`/admin`（`server/admin_web/`，19 条路由、9 个 Jinja2 模板、`static/admin.js` 单一脚本）此前只有
`server/tests/test_admin.py` 的 **HTTP 层**覆盖（85 条用例走 `TestClient`）——**没有任何一条证据来自真实浏览器**：
表单能不能提交、`fetch` 会不会真的打出去、`PUT /admin/config` 写进去的值刷新后还在不在、
`<input type=file>` 上传图标后页面上的 `<img>` 会不会变、改密后旧口令是不是真的进不来、
登出后 Cookie 有没有被清、未登录访问 `/admin/users` 会不会被 303 挡回登录页——
这些**只有把页面真正渲染出来、把点击真正发出去**才知道。

本目录就是补这一层：**真实服务端 + 真实浏览器 + 真实鼠标点击级交互**，七项功能与四条鉴权边界逐项留证，
并落 13 张截图 + `artifacts/report.json`（机器可读）。

## 怎么跑

```bash
bash tests/tools/admin_e2e/run.sh
echo "RUN_EXIT=$?"
```

一把跑完：建任务库 → 起 uvicorn → 起 Edge headless → 驱动 → 归档截图 → 删库杀进程。

| 退出码 | 含义 |
|---|---|
| `0` | 全部断言通过（当前 **97 项**：七项功能 + 四条鉴权边界 + 13 张截图的像素校验） |
| `1` | 有断言失败（看 stdout 的 `[FAIL]` 行与 `artifacts/report.json`） |
| `2` | 环境不可达（MySQL 容器 / Edge / CDP / 服务端 任一不可用）—— 如实记「未运行」，**不算通过** |

可覆盖的环境变量（默认值见 `run.sh` 顶部）：

| 变量 | 默认 | 用途 |
|---|---|---|
| `CB_ADMIN_E2E_DB` | `carbonboo_admin_e2e` | 任务专属库名（跑完删除，不碰 `carbonboo` 主库） |
| `CB_ADMIN_E2E_PORT` | `8041` | uvicorn 端口 |
| `CB_ADMIN_E2E_CDP_PORT` | `9333` | Edge DevTools 端口 |
| `CB_ADMIN_E2E_CONTAINER` | `carbonboo-mysql` | MySQL 容器名（`127.0.0.1:13307`） |

## 依赖（本工具**不安装任何依赖**）

| 资源 | 位置 | 说明 |
|---|---|---|
| 服务端 | `server/.venv/bin/uvicorn` | 用项目自己的虚拟环境起 `app.main:app`，**一行代码都不改** |
| MySQL | 容器 `carbonboo-mysql` → `127.0.0.1:13307` | 复用项目容器；任务库由 `server/sql/schema.sql` + `seed.sql` 建 |
| 浏览器 | `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe` | `--headless=new` |
| 驱动运行时 | `C:\Users\Administrator\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe` | Python 3.12 + Pillow（系统自带，仅用于生成上传夹具与截图像素校验） |

### 为什么驱动必须跑在 **Windows 侧**

* WSL2 是 NAT 网络：**WSL → Windows 的入站被挡**（实测 `curl http://<windows-host>:9333/json/version` 超时 `exit 28`），
  Edge 的 DevTools 端口只监听 **Windows 的** `127.0.0.1`；
* 反过来 **Windows → WSL 的 `localhost` 转发是通的**，所以浏览器能直接访问 WSL 里的 `http://127.0.0.1:8041`；
* 结论：**浏览器与驱动同侧（Windows），被测服务端在 WSL** —— 这也是 `cdp_driver.py` 用标准库
  自己实现 RFC6455 WebSocket 客户端（Windows 侧没有 `websockets`/`httpx`）的原因。

## 覆盖范围（逐项）

| # | 功能 | 关键证据 |
|---|---|---|
| ① | 登录页 + 表单提交 | 页面文本命中、`#login-form` 存在、提交后 `location.pathname === /admin` 且总览页渲染 |
| ② | 用户列表 | 表头四项 + **库内真值**（跑前用真实 API 注册的客户端账号出现在表里） |
| ③ | 操作日志 | 表头 + **本次管理员登录记录**（登录时写 `admin_op_log`，浏览器读到的就是库里的） |
| ④ | 系统配置 读 + 写 | `PUT /admin/config` 200 → **刷新后回显新值**（200 → 240 落库） |
| ⑤ | 商品图标上传 | 真实 `<input type=file>` + `DOM.setFileInputFiles` → `POST /admin/items/frame_01/icon` 200 → 库内 `icon` 指向 `/admin/icons/*` → `GET` 回来是 PNG（magic `[137,80,78,71,13,10,26,10]`）→ 页面 `<img>` 命中 |
| ⑥ | 改密 | `POST /admin/password` 200 + 页面回显；**负向对照**（旧口令 → `401` + 原生 alert）与**正向对照**（新口令登录成功进总览） |
| ⑦ | 登出 + 鉴权边界 | 登出前 `HttpOnly` Cookie 存在 → 登出 200 → Cookie 清空 → 未登录访问 `/admin/users` **浏览器侧 303**（`Network.requestWillBeSent.redirectResponse`）+ 旁路 `urllib` 原始 `303` → 被清掉的旧 Cookie 原样重放仍 `200`（**无状态 JWT，如实记录**）→ 客户端令牌打 `/admin/*` **403** |
| — | 13 张截图 | 视口 1440×900、非空白像素比例、颜色数、品牌主色 `#2E7D5B` 像素数、**与其它截图的 md5 查重**（同画面必须是「预期同画面」） |

## 产物

* `tests/tools/admin_e2e/artifacts/*.png` —— 13 张截图，文件名即步骤（`01_login_page` … `13_relogin_new_password`）。
  **13 张里有 10 个互不相同的 md5**：登录页状态被 4 张共用（`01_login_page` / `09_after_logout` /
  `10_users_unauthenticated` / `11_client_token_probe` —— 后三张**本来就该**回到同一个登录页），
  驱动对这类「预期同画面」用 `dup_ok=True` 记 `[INFO]` 而不计为重复；其余 9 张各自唯一。
* `tests/tools/admin_e2e/artifacts/report.json` —— 全部断言（`checks`）、截图指标（`shots`）、
  浏览器原生弹窗（`dialogs`）、绑定信息（`base_url` / `browser` / `viewport` / `admin_username`）
* `/tmp/cb-admin-e2e/{driver.log,uvicorn.log,edge.log}` —— 中间日志（仓库外）

## 边界（**写死，不许含糊**）

* **不替代** L1 hypium 设备执行：本工具只驱动 `/admin`，与 `app/` 的 36 个 `it()` 无关，**两证不可互相顶替**。
* **不替代** L2 端侧集成（需要两台真实设备）。
* **不替代** `server/deploy/` 实跑（容器/systemd/TLS/防火墙都没跑）。
* **不替代** 18 页 App 视觉走查：本工具只有 `/admin` 的 13 张截图，**App 侧零截图**。
* **只有 Edge**：不做 Chrome/Firefox/Safari 兼容性，不做移动端视口。
* **不做 HTTPS**：走明文 `http://127.0.0.1:8041`（TLS/证书不在本工具范围）。
* **不做并发/性能/压测**：单浏览器、串行点击。
* **不碰被测代码**：只读 `server/sql/*.sql`、只**启动**服务端进程；跑完删库、杀进程、清 profile。
* **口令只经仓库外的 `$TMP/run.json` 传递**（本脚本临时生成，跑完即失效），不写入任何被提交的文件。

## 已知坑（本工具实测踩过的，写下来省下一次）

1. **CDP 的 `redirectResponse` 是 `params` 的兄弟字段**，不在 `params.request` 里 —— 写成
   `params.request.redirectResponse` 会永远拿不到重定向那一跳，于是「未登录访问 `/admin/users` → 303」
   这条断言会**假失败**（Chrome 对 303 不发独立的 `responseReceived`）。
2. **`--user-data-dir` 必须给 Windows 路径**（`C:/Users/...`）。给 `/mnt/c/...` 会被 Windows 侧的 Edge
   忽略并**退回用户默认 profile**：上一轮登录写下的 Cookie 会被下一轮继承，表现为「刚起浏览器就已登录」，
   导航到 `/admin/login` 也直接 303 到 `/admin`（`pages.render_login` 对有效会话会跳 `next`）。
   驱动另外在连接后立即 `Network.clearBrowserCookies`，不依赖 profile 是否干净。
3. **WSL 连不上 Windows 的 CDP 端口**（NAT 入站被挡，`curl` 超时 `exit 28`），别在 WSL 侧调 CDP。
4. **uvicorn 冷启动可能 >30 s**（`run.sh` 等到 120 s 并打印进度），起慢了不等于起不来。
5. **Windows 控制台编码是 cp936**：驱动必须 `sys.stdout.reconfigure(encoding="utf-8")` +
   `PYTHONIOENCODING=utf-8 PYTHONUTF8=1`，否则中文断言详情全是乱码。
6. **失败登录会弹原生 `window.alert` 卡死渲染进程**（见下），CDP 必须挂
   `Page.javascriptDialogOpening` → `Page.handleJavaScriptDialog(accept=true)`，否则后续 `Runtime.evaluate` 永远不返回。
7. `grep -c` 在零命中时退出码是 1，`set -o pipefail` 下要用 `| head -1` 兜住。

## 本工具实测发现的一条小缺陷（已如实记录，未修：`server/**` 不在本任务写入范围）

`server/admin_web/templates/login.html:30` 的错误提示容器是 `<div class="flash is-error" role="alert">`，
**没有 `id="flash"`**；而 `server/admin_web/static/admin.js:16` 是
`if (!box) { window.alert(message); return; }`。于是**登录页上的失败提示会退化成浏览器原生 `alert`**
（实测文案 `管理员用户名或口令错误`）：用户看到的是原生弹窗而不是页内红条，脚本化的端到端驱动会被它卡住。
修法很小（给该 `div` 加 `id="flash"`），但属 `server/**`，留给相应任务。
