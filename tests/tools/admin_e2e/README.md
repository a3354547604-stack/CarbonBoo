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

---

# §t76 追加：真 nginx(TLS) 反代下的浏览器图层（本轮新增，上文 t55/t59 正文一字未改）

## 为什么加这一段

t75 用「等价真 HTTP 客户端（curl + Cookie）」验过 `/admin` **经真 nginx(TLS) 反代**的 62 条探针，
但它如实把**「真浏览器图层未运行」**列进了未运行项：**curl 不是浏览器**——表单会不会真提交、
`fetch` 会不会真打出去、页内 `#flash` 会不会真渲染、`<input type=file>` 走 `DOM.setFileInputFiles`
后端能不能取回、Cookie 会不会真被清，curl 一律答不了。

本轮把 t55/t59 的 Windows 侧 CDP 驱动**接到真 nginx 前面**：同一份 `cdp_driver.py` 跑两遍，
第一遍直连 uvicorn（t55 原有行为，一字未动），第二遍浏览器 origin 换成
`https://api.example.com:<nginx 端口>`，两遍都驱动真实 Edge headless。

## 怎么加（`run.sh` 新增 4b 阶段 + 新增 `compare_paths.py`）

1. **派生 nginx 配置，不改 `server/deploy/**`**：`sed` 从 `server/deploy/nginx/carbonboo.conf`
   生成副本，只改两处 —— 证书路径 → 容器内 `/etc/nginx/tls/`、上游 `http://127.0.0.1:8000`
   → `http://host.docker.internal:<uvicorn 端口>`（实测替换 5 处）。**生产配置一个字没动**。
2. **自签证书**：`openssl req -x509 … -subj "/CN=api.example.com" -addext "subjectAltName=DNS:api.example.com"`，
   因此 `compare_paths.py` 可以对 `api.example.com` 做**真正的 TLS 链 + 主机名校验**（不是关掉校验）。
3. **真容器**：`docker run -d --name cb-admin-e2e-nginx --add-host host.docker.internal:host-gateway
   -p …:443 -p …:80 -v <派生 conf> -v <证书> nginx:alpine`；用完 `docker rm -f`。
4. **浏览器侧**：第二份 `--user-data-dir`（Windows 可写路径，避免 t55 那个「静默退回默认 profile」坑）+
   `--host-resolver-rules="MAP api.example.com 127.0.0.1"` + `--ignore-certificate-errors`（自签）+
   **`--no-proxy-server`**（见下面「新增已知坑」第 8 条）。
5. **口令衔接**：两遍跑的是**同一个任务库**，第一遍 ⑥ 已经把管理员口令从引导口令改成 `$NEW_PW`，
   所以第二遍 `run.json` 的 `admin_password` 必须是 `$NEW_PW`（新口令另取 `$NEW_PW_2`）。
   这不是缺陷，是同一套用例连跑两遍的必然。
6. **逐字节比对**（`compare_paths.py`，WSL python3 纯标准库，退出码同 0/1/2）：
   断言项集合一致（`⑧` 资源探针与其收尾截图 `14_resource_paths` 仅 nginx 侧；第二遍截图名带
   `nginx_` 前缀，比对前归一）、两侧 `failed==0`、TLS 对端证书 DER sha256 == 挂载证书文件、
   登录页 HTML sha256 一致、浏览器实际加载过的 `/admin/static/*` 状态码 + 响应体 sha256 一致、
   nginx 侧截图 ≥3 张且品牌主色 `#2E7D5B` 像素 >0。

## 新增可覆盖变量

| 变量 | 默认 | 用途 |
|---|---|---|
| `CB_ADMIN_E2E_NGINX` | `1` | 置 `0` 关闭 4b 阶段（退回 t55 行为） |
| `CB_ADMIN_E2E_NGINX_IMAGE` | `nginx:alpine` | 反代镜像；**指向不存在的镜像即进入 ENV-UNREACHABLE** |
| `CB_ADMIN_E2E_NGINX_HTTPS_PORT` / `_HTTP_PORT` / `_CDP_PORT` | `10443` / `10080` / `9334` | 端口 |

## 本轮实测（原始输出见提交信息；基线 `git rev-parse HEAD` = `22a3fbf5f7ebb4a1b71d5b75bd040c9bf8a281d9`）

```text
$ bash tests/tools/admin_e2e/run.sh; echo "ADMIN_E2E_EXIT=$?"
直连 checks: PASS=98 FAIL=0 driver_exit=0
nginx checks: PASS=103 FAIL=0 driver_exit=0 compare_exit=0
RESULT: PASS —— 直连与真 nginx(TLS) 反代两条路径均由真实 Edge headless + CDP 驱动通过
ADMIN_E2E_EXIT=0
```

真浏览器经 nginx 跑到的关键断言（`/tmp/cb-admin-e2e/driver_nginx.log` 原文摘录）：

```text
[PASS] ① 诊断：本次导航抓到的响应 = GET https://api.example.com:10443/admin/login → 200；
       GET https://api.example.com:10443/admin/static/admin.css → 200；…/admin.js → 200
[PASS] ⑤ 重载商品页后能看到新图标（<img> 指向 /admin/icons/）: 命中（CDP DOM.setFileInputFiles）
[PASS] ⑥ 失败提示落在页内 #flash（文本非空、可见、不再是模态弹窗）:
       #flash found=True hidden=False text='管理员用户名或口令错误' class='flash is-error'
[PASS] ⑥ 负向对照：改密后旧口令登录被拒（POST /admin/login → 401）: 实测 HTTP 401 POST
[PASS] ⑦ 登出后浏览器已不持有会话 Cookie（正向对照）: Network.getCookies 中 carbonboo_admin_token 条数=0
[PASS] ⑧ 页面资源全部同源于浏览器 origin（无反代改写/外链）: origin=https://api.example.com:10443 资源数=2 非同源=[]
[PASS] ⑧ 静态资源路径命中 /admin/static/（或图标 /admin/icons/）: ["/admin/static/admin.css", "/admin/static/admin.js"]
[PASS] 资源 /admin/static/admin.css 直连==nginx: 直连 200/8633B sha=ec9aad5341ee… nginx 200/8633B sha=ec9aad5341ee…
[PASS] 资源 /admin/static/admin.js  直连==nginx: 直连 200/8538B sha=5ac4cfb2e870… nginx 200/8538B sha=5ac4cfb2e870…
[PASS] 登录页 HTML 逐字节一致（sha256）: 直连=15b6976687bf8dc4… nginx=15b6976687bf8dc4…
[PASS] nginx 对端证书 sha256 == 挂载证书文件: peer=d2b833a5df28febf… expected=d2b833a5df28febf…
[PASS] 至少 3 张截图命中品牌主色 #2E7D5B（Windows Pillow 逐像素）: 实测 14 张：
       nginx_01_login_page 14321px; nginx_02_after_login 8214px; nginx_03_users 7941px;
       nginx_04_logs 9120px; nginx_05_config_read 44060px; nginx_06_config_write 44060px
```

截图证据（`artifacts/`，1440×900，Windows 侧 Pillow 逐像素统计）：

| 文件 | 对应用例 | brand_pixels(#2E7D5B) |
|---|---|---|
| `artifacts/nginx_01_login_page.png` | ① 登录页（经 nginx） | 14321 |
| `artifacts/nginx_03_users.png` | ② 用户列表有真实数据 | 7941 |
| `artifacts/nginx_04_logs.png` | ③ 日志页有真实数据 | 9120 |
| `artifacts/nginx_05_config_read.png` / `nginx_06_config_write.png` | ④ 配置写入并重载回显 | 44060 / 44060 |
| `artifacts/nginx_07_items_icon.png` | ⑤ 图标上传后取回 | 26207 |

**「反代与直连一致」的结论**：断言项集合逐项相同（归一后各 111 项）、登录页与两个静态资源
**响应体 sha256 完全相同**、Cookie 行为无分叉（HttpOnly 会话 Cookie 在 https 下正常收发、登出后清零）。
**没有观察到任何静态资源或 Cookie 分叉**。

## 退出码 0 / 1 / 2 本轮都实测过（不是只写在表里）

| 退出码 | 怎么造出来的 | 原始输出 |
|---|---|---|
| `0` | 正常跑 | `ADMIN_E2E_EXIT=0`，见上 |
| `1` | 比对脚本修好前的中间态（compare 报 `[FAIL]`，驱动本身全绿） | `RESULT: FAIL —— 见上面的 [FAIL] 行…` + `ADMIN_E2E_EXIT=1` |
| `2` | `CB_ADMIN_E2E_NGINX_IMAGE=carbonboo-definitely-not-an-image:1 bash tests/tools/admin_e2e/run.sh` | `[ENV-FAIL] nginx 镜像不可用…` + `RESULT: ENV-UNREACHABLE —— 未运行（退出码 2）` + `ADMIN_E2E_EXIT=2` |

## 新增已知坑（t55 那 7 条之外）

8. **Windows 系统代理会让 Chromium 的 `--host-resolver-rules` 失效**：实测无 `--no-proxy-server` 时
   主机名请求走系统代理 → `net::ERR_CONNECTION_RESET` / `net::ERR_CONNECTION_ABORTED`，而
   `--dump-dom` 直连 `https://127.0.0.1:<port>` 正常。加 `--no-proxy-server` 后页面正常渲染。
   **这是浏览器侧环境问题，不是反代缺陷**。
9. **`Report.shots_by_name` 的键名带截图前缀**：第二遍 `SHOT_PREFIX=nginx_` 后，
   仍按裸名 `shots_by_name.get("01_login_page")` 查回会拿到 `None` → `TypeError`。
   现已改为直接用 `screenshot()` 的返回值。
10. **`http.client.HTTPSConnection("127.0.0.1", …)` 会拿 IP 做主机名校验**，
    报 `certificate verify failed: IP address mismatch`；要么用 `server_hostname="api.example.com"`
    的 `wrap_socket`（本工具做法，仍**开着**校验），要么就只能关校验（不推荐）。

## 覆盖边界（本轮**没有**证明的事，如实列出）

* `server/deploy/nginx/carbonboo.conf` 只被**派生**：Let's Encrypt 真实证书目录、真实域名解析、
  HSTS/H2/限流在生产域名下的行为**未验证**（本轮是自签证书 + `--host-resolver-rules`）。
* 只有 Edge（Chromium）一个浏览器内核；不覆盖 Firefox/Safari、真机移动端。
* nginx 限流 `limit_req zone=carbonboo_login` 在**本轮的请求密度**下没有触发 429（单一管理员、串行点击）；
  `429` 语义由 t75 的 62 条 curl 探针覆盖，本轮不复现。
* 并发/压测不在范围（单浏览器、串行）。
* 真机端侧与多机分布式同步无关本轮（本工具只覆盖 `/admin` Web 图层）。

## 清理与不变量（本轮实测）

* `docker ps -a | grep -c carbonboo` = **1**（只有共享 `carbonboo-mysql`，未停未删）；无遗留
  `cb-admin-e2e-nginx` 容器 / 网络 / 卷；Edge 进程里查 `cb-admin-e2e` 的 profile = **0** 条。
* 任务库 `carbonboo_admin_e2e` 跑后已 drop（`SHOW DATABASES` 无此库）。
* 生产库 `carbonboo` **21 张表逐表行数跑前 == 跑后**（脚本内 `diff` 校验，与 t55 同法）。
* `server/**`、`app/**`、`docs/**`、`tests/cases/**` 一行未改。

## 与上文两处的差异说明（只追加，不改上文）

* 上文「退出码」表格写「当前 **97 项**」是 t55 的计数；t59 修好后直连路径为 **98 项**，
  本轮 nginx 路径为 **103 项**（含 `⑧` 资源探针）+ 比对脚本 16 项。以上文为准会偏旧，特此标注。
* 上文 §「本工具实测发现的一条小缺陷」记的 `login.html` 缺 `id="flash"`：**t59 已修复**
  （`server/admin_web/templates/login.html` 补了 `id="flash"`），本轮在真浏览器经 nginx 复验通过
  （见上面 `#flash found=True …` 那行）。上文保留原样作为历史记录。
