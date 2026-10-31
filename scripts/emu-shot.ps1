# 模拟器截图助手：点击（可选）→ 等待 → 截图 → 拉回仓库
#
# 为什么用 hdc 而不是预览器：
#   DevEco 预览器的 relationalStore 是模拟实现（写不进种子数据），
#   所以在预览器里所有数据页都是空态、记录明细与科普详情进不去。
#   模拟器（HarmonyOS 7.0.0 / API 26，x86_64）是真实运行时，RDB 真落盘。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\emu-shot.ps1 -Name 01-home
#   ... -Name 03-records -Click '639,2576'
#   ... -Name 06-goal -Click '644,1472' -Wait 3
#   ... -Name 13-settings -Swipe '640,2200,640,900'
# 输出：docs\screenshots\<Name>.png（JPEG 抓图转 PNG，保持 1280x2832 原始分辨率）
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$Click = '',
  [string]$Swipe = '',
  [int]$Wait = 2,
  [string]$Hdc = 'C:\Users\Admin\ohos-sdk\12\toolchains\hdc.exe'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $repo 'docs\screenshots'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

if (-not (Test-Path $Hdc)) { throw "找不到 hdc：$Hdc" }

function Invoke-Hdc([string[]]$hdcArgs) {
  & $Hdc @hdcArgs 2>&1 | ForEach-Object { $_.Trim() }
}

# 1) 可选交互
if ($Swipe -ne '') {
  $p = $Swipe.Split(',')
  if ($p.Length -ne 4) { throw '-Swipe 需要 "x1,y1,x2,y2"' }
  Invoke-Hdc @('shell', "uitest uiInput swipe $($p[0]) $($p[1]) $($p[2]) $($p[3]) 600") | Out-Null
  Start-Sleep -Milliseconds 800
}
if ($Click -ne '') {
  $p = $Click.Split(',')
  if ($p.Length -ne 2) { throw '-Click 需要 "x,y"' }
  Invoke-Hdc @('shell', "uitest uiInput click $($p[0]) $($p[1])") | Out-Null
}

Start-Sleep -Seconds $Wait

# 2) 设备侧抓图 → 拉到临时目录
$remote = '/data/local/tmp/emu-shot.jpeg'
Invoke-Hdc @('shell', "snapshot_display -f $remote") | Out-Null
$tmp = Join-Path $env:TEMP 'emu-shot.jpeg'
if (Test-Path $tmp) { Remove-Item $tmp -Force }
Invoke-Hdc @('file', 'recv', $remote, $tmp) | Out-Null
if (-not (Test-Path $tmp)) { throw '抓图失败：没有拉到文件' }

# 3) JPEG → PNG（保持分辨率）
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile($tmp)
$w = $img.Width
$h = $img.Height
$dest = Join-Path $outDir ("{0}.png" -f $Name)
try {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.DrawImage($img, 0, 0, $w, $h)
  $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
} finally {
  $img.Dispose()
}

Write-Output ("SAVED {0}  {1}x{2}  {3} B" -f $dest, $w, $h, (Get-Item $dest).Length)
