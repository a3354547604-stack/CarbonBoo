# `tests/tools/vision_check/` —— 判图腿（视觉模型通道）的可复现入口

一条命令，把「我们自己的设计令牌」画成色板图，交给视觉模型判读，并按可判读性给出 PASS/FAIL。

```bash
bash tests/tools/vision_check/run.sh ; echo RUN_EXIT=$?
```

正常输出末尾是：

```
  自检：色块像素 == 令牌色值  17/17 ✓
  HTTP_STATUS = 200   elapsed = 9.1s
RESULT: PASS —— 视觉模型通道可用，且判读了 AppTheme 真实色板（背景 + 17/17 色块）
RUN_EXIT=0
```

## 它到底验了什么

1. **从真实源解析**（不手抄常数表）：读 `app/entry/src/main/ets/util/AppTheme.ets`，把
   `static readonly COLOR_*/CAT_*: string = '#RRGGBB'` 这些**颜色令牌**解析出来，并在 stdout
   逐个回显（色名 / 十六进制 / 源码里的用途注释）。源码改了、增删了颜色，脚本跟着变；
   脚本里**没有任何一份硬编码色值表**。
2. **用这些色值渲染色板**：每色一块矩形，块上写色名、十六进制、用途；网格布局 4 列，
   页面底色直接用令牌 `COLOR_BG`（所以「背景色是什么」这一问有据可依）。
   渲染完立刻做**像素自检**：从 PNG 里采样每个色块的像素，必须等于解析到的令牌色值
   （不一致就判「渲染器漂了」并退出 2）—— 防止拿一张和令牌无关的图去「证明」判图能力。
3. **让视觉模型真的看一眼**：从凭据库 `.dsh/.credentials.yaml → refs.ARK_API_KEY` 取 key
   （**不落盘、不回显明文**，只打印 `ark-bb…16 (len=46)` 这种掩码），POST 到
   `https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions`，
   model `deepseek-v4-1-flash-260910`（支持 image 输入），content 里放 `text` + `image_url`
   （`data:image/png;base64,...`）。**完整原始响应**打到 stdout（`RAW_RESPONSE_BEGIN/END`）。
4. **判定**：默认要求
   - 模型给出的**背景色**被描述为浅色（不含「深/暗/黑」），且
   - 至少 **8/17** 个色块被正确说出（色名或十六进制任一命中）。

   两条都满足 → `RESULT: PASS` / `RUN_EXIT=0`；否则非 0 退出，并打印未命中的色块。
   门槛可调：`VISION_MIN_MATCHED=12`。

## 失败时会发生什么（**不会静默通过**）

| 情况 | 退出码 | 打印 |
|---|---|---|
| 找不到带 Pillow 的 python | `2` | 列出试过的解释器 + 用 `VISION_PYTHON=` 指定的办法 |
| 缺 `AppTheme.ets` / 解析不到任何颜色令牌 | `2` | 报路径 / 提示源码结构变了 |
| 渲染出的像素与令牌色值不符 | `2` | 逐个打印「期望 / 实得」 |
| 端点不可达（无出网/需代理） | `3` | `连不上视觉端点 … （[WinError 10061] …）` |
| HTTP 非 200 | `3` | 打印 `HTTP_STATUS` 与响应原文 |
| 响应不是 `chat.completion` / `content` 为空 | `3` | 说明无法判定 |
| 凭据库里没有 `refs.ARK_API_KEY` | `4` | 报文件与 ref 名（不打印任何值） |
| 判读未达门槛 | `1` | 命中/未命中的色块清单 + 背景色判定 |

产物默认写到系统临时目录并在退出时删除（失败路径也删）；要留下证据加
`VISION_CHECK_KEEP=1 VISION_CHECK_OUTDIR=<目录>`。

## 可调的环境变量

| 变量 | 作用 |
|---|---|
| `VISION_PYTHON` | 指定带 Pillow 的解释器（默认自动挑 Windows python） |
| `VISION_ENDPOINT` / `VISION_MODEL` | 换端点 / 换模型名 |
| `VISION_CREDS` / `VISION_KEY_REF` | 换凭据库路径 / 换 ref 名 |
| `VISION_MIN_MATCHED` | 色块命中门槛（默认 8） |
| `VISION_CHECK_KEEP` / `VISION_CHECK_OUTDIR` | 保留产物 / 指定产物目录 |

## 边界（必读：它不是截图腿，也不能替代截图腿）

- **它验的是设计令牌色板，不是页面截图外观。** 它只能说明「视觉模型通道可用，且能把
  CarbonBoo 自己的设计令牌如实读出来」。
- **它不能替代 18 个页面的视觉走查。** 截图腿至今**一张图都产生不出来**：`hdc` 未安装、
  无真机无模拟器、`/dev/kvm` 不可写、SDK Previewer 崩于 glibc 2.43。
  本工具不碰设备、不启动模拟器、不渲染任何页面，所以**一页 UI 也没验**。
- 因此报告里必须分开写：**「视觉模型通道 = 已跑通」** 与 **「页面级视觉走查 = 仍不可做」**，
  两句话不能合并成一句「视觉走查完成」。
- 它也不替代 hypium（不动 DB/网络/生命周期），不替代 L3，不改变任何验收判定。
- 判读结论依赖模型本身：模型答错会 FAIL，模型答对了也只是「这张色板图可判读」。
  想要更强的一致性证据，可加 `VISION_MIN_MATCHED=17` 要求逐色块全中。

## 为什么不用 WSL 的 python3

Pillow 只装在 Windows 运行时的 python 里（`…/dsh-primary-runtime/dependencies/python/python.exe`），
WSL 的 `python3` 有 `yaml` 但没有 `PIL`。`run.sh` 因此自动挑「能 `import PIL`」的解释器，
并在用 Windows python 时把 WSL 路径（`/mnt/c/...`）翻成 `C:/...` 再传过去。
key 的读取两种解释器都能用：有 `yaml` 就用 `yaml`，没有就按 `refs:` 缩进块做行解析。
