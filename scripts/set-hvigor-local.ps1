<#
.SYNOPSIS
  把 app/hvigor/hvigor-config.json5 的两行 file: 依赖改成**本机** hvigor 路径，并把它标记为
  skip-worktree（本地改动不进 git status，也就不会被误提交）。

.DESCRIPTION
  为什么需要这个脚本：
  `@ohos/hvigor` 与 `@ohos/hvigor-ohos-plugin`（6.26.8）在 registry.npmjs.org、registry.npmmirror.com、
  repo.huaweicloud.com/repository/npm/ 全是 404，repo.harmonyos.com/npm/ 是 401（需华为账号）；
  hvigor 的 json5 既不支持环境变量展开、也不接受相对路径。所以这两行**只能写本机绝对路径**。

  仓库里保留的是队友 Linux 的 `/home/qinyixiang/...` 版（他那侧的 `sed s#/home/qinyixiang#$HOME#`
  规则继续有效）。Windows 侧用本脚本，且这处改动**永不提交** —— 所以脚本同时设置 skip-worktree。
  详细理由与坑见 docs/toolchain/harmony-cli-build.md §坑 4-W。

.PARAMETER DevEcoRoot
  DevEco Studio 安装目录。默认 `C:\Program Files\Huawei\DevEco Studio`。
  脚本会取 `<DevEcoRoot>/tools/hvigor/{hvigor,hvigor-ohos-plugin}`。

.PARAMETER SdkRoot
  可选。给了就顺带把 `app/local.properties` 的 `sdk.dir` 写成它（该文件已被 .gitignore 忽略，不入库）。
  例：`-SdkRoot 'C:\Users\Admin\ohos-sdk'`。

.EXAMPLE
  pwsh -File scripts/set-hvigor-local.ps1

.EXAMPLE
  pwsh -File scripts/set-hvigor-local.ps1 -SdkRoot 'C:\Users\Admin\ohos-sdk'

.NOTES
  幂等：重复执行结果相同。pull 后若发现 hvigor 版本变了，先
  `git update-index --no-skip-worktree app/hvigor/hvigor-config.json5`，再重跑本脚本。
#>
[CmdletBinding()]
param(
  [string]$DevEcoRoot = 'C:\Program Files\Huawei\DevEco Studio',
  [string]$SdkRoot = ''
)

$ErrorActionPreference = 'Stop'

# ---- 0. 定位仓库根与目标文件 -------------------------------------------------
$repo = Split-Path -Parent $PSScriptRoot
$cfg = Join-Path $repo 'app/hvigor/hvigor-config.json5'
if (-not (Test-Path -LiteralPath $cfg)) {
  throw "找不到 hvigor 配置文件：$cfg（本脚本必须在仓库的 scripts/ 目录下）"
}

# ---- 1. 校验 hvigor 两个包存在 -----------------------------------------------
$pluginDir = Join-Path $DevEcoRoot 'tools/hvigor/hvigor-ohos-plugin'
$hvigorDir = Join-Path $DevEcoRoot 'tools/hvigor/hvigor'
foreach ($d in @($pluginDir, $hvigorDir)) {
  if (-not (Test-Path -LiteralPath $d)) {
    throw "hvigor 包不存在：$d`n请检查 -DevEcoRoot（当前：$DevEcoRoot）"
  }
}

# ---- 2. 路径转 POSIX 风格：file:C:/Program Files/... ------------------------
# 三个踩过的写法（见文档）：file:/home/... 与 file:/c/... 都会被 pnpm 解错，
# 必须写成「盘符直接跟冒号」的 file:C:/...
function ConvertTo-StableSpec([string]$winPath) {
  $posix = $winPath -replace '\\', '/'
  return 'file:' + $posix
}
$pluginSpec = ConvertTo-StableSpec $pluginDir
$hvigorSpec = ConvertTo-StableSpec $hvigorDir

# ---- 3. 原地改写两行（保留 BOM 状态与其余内容不动）---------------------------
$bytes = [System.IO.File]::ReadAllBytes($cfg)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$text = [System.IO.File]::ReadAllText($cfg, [System.Text.UTF8Encoding]::new($false))

$before = $text
$text = [regex]::Replace($text, '("@ohos/hvigor-ohos-plugin"\s*:\s*)"[^"]*"', ('$1"' + $pluginSpec + '"'))
$text = [regex]::Replace($text, '("@ohos/hvigor"\s*:\s*)"[^"]*"', ('$1"' + $hvigorSpec + '"'))

if ($text -ne $before) {
  $enc = [System.Text.UTF8Encoding]::new($hasBom)
  [System.IO.File]::WriteAllText($cfg, $text, $enc)
  Write-Host "[改写] app/hvigor/hvigor-config.json5 两行 file: 依赖已指向本机" -ForegroundColor Green
} else {
  Write-Host "[跳过] 两行已经是本机路径，无需改动" -ForegroundColor DarkGray
}

# ---- 4. 可选：写 app/local.properties 的 sdk.dir -----------------------------
if ($SdkRoot -ne '') {
  if (-not (Test-Path -LiteralPath $SdkRoot)) {
    throw "SDK 目录不存在：$SdkRoot"
  }
  $localProps = Join-Path $repo 'app/local.properties'
  $sdkLine = 'sdk.dir=' + ($SdkRoot -replace '/', '\')
  # 用 .NET 写而不是 Set-Content：`-Encoding utf8NoBOM` 只有 PowerShell 7+ 才有，
  # 而本仓库的 Windows 侧常常只有 5.1（`pwsh` 不在 PATH）。
  [System.IO.File]::WriteAllText($localProps, ($sdkLine + "`r`n"), [System.Text.UTF8Encoding]::new($false))
  Write-Host "[改写] app/local.properties → $sdkLine（本地文件，不入库）" -ForegroundColor Green
}

# ---- 5. 设置 skip-worktree：本地改动永不进 git status -----------------------
$git = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path -LiteralPath $git)) { $git = 'git' }
Push-Location $repo
try {
  & $git update-index --skip-worktree app/hvigor/hvigor-config.json5
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[警告] skip-worktree 设置失败（该文件可能尚未被 git 跟踪）" -ForegroundColor Yellow
  } else {
    Write-Host "[标记] app/hvigor/hvigor-config.json5 已设 skip-worktree" -ForegroundColor Green
  }

  # ---- 6. 自检：打印现状，便于一眼确认 ------------------------------------
  Write-Host ''
  Write-Host '--- 自检 ---' -ForegroundColor Cyan
  & $git ls-files -v app/hvigor/hvigor-config.json5
  & $git status --short
  Write-Host ''
  Select-String -LiteralPath $cfg -Pattern 'file:' | ForEach-Object { '  ' + $_.Line.Trim() }
} finally {
  Pop-Location
}

Write-Host ''
Write-Host '完成。下一步：' -ForegroundColor Cyan
Write-Host '  app/ 下执行 hvigorw assembleHap 验证（见 docs/toolchain/harmony-cli-build.md）'
