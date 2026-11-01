<#
  打包比赛提交物。

  产出（都在 <repo>/submit/ 下）：
    04-源代码-碳小布CarbonBoo.zip      完整源代码工程（去编译产物/中间缓存/依赖缓存/密钥）
    提交包-碳小布CarbonBoo/             四个材料放一起
    提交包-碳小布CarbonBoo.rar          上面那个目录打成一个包

  用法（Windows PowerShell 5.1）：
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package_submission.ps1
    # 只想重打源码包、不动 rar：
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package_submission.ps1 -SkipRar

  设计要点：
  1. **白名单式收集**：按目录逐个走，靠规则排除，而不是「先把所有东西塞进去再删」——
     避免把 .venv / oh_modules / build / .env(密钥) / 截图 / 第三方 PDF 带进包。
  2. 排除清单写死在 `$ExcludeDirNames` / `$ExcludeFilePatterns`，改规则只改这两处。
  3. 打包后**自检**：列出 zip 里命中禁词（`.env`、`build/`、`oh_modules`、`_src`、`screenshots`）的条目，
     有命中就报错退出，不生成 rar。
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [switch]$SkipRar
)

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$submitDir = Join-Path $RepoRoot 'submit'
$zipPath   = Join-Path $submitDir '04-源代码-碳小布CarbonBoo.zip'
$stageDir  = Join-Path $submitDir '提交包-碳小布CarbonBoo'
$rarPath   = Join-Path $submitDir '提交包-碳小布CarbonBoo.rar'
$rarExe    = 'C:\Program Files\WinRAR\Rar.exe'

# ── 排除规则 ───────────────────────────────────────────────────────────────
# 目录名命中即整棵跳过
$ExcludeDirNames = @(
  '.git', '.idea', '.vscode', '.hvigor', '.preview', 'build', 'dist', 'outputs',
  'oh_modules', 'node_modules', '.venv', 'venv', '__pycache__', '.pytest_cache',
  'screenshots', '_src', '_rec', '_frames', 'submit', 'sign', 'coverage', '.claude'
)
# 文件名/通配命中即跳过
$ExcludeFilePatterns = @(
  '*.log', '*.tmp', '*.pyc', '*.pyo', '*.rar', '*.zip', '*.hap', '*.hsp', '*.app',
  '_tmp_*', '.DS_Store', 'Thumbs.db',
  # 密钥与本机配置：绝不能进提交包
  '.env', 'local.properties'
)
# 允许进包、但即使命中上面通配也要保留的（暂无，留位）
$ForceIncludeFiles = @()

# ── 工具函数 ───────────────────────────────────────────────────────────────
function Test-ExcludedPath {
  param([string]$RelativePath, [string]$FileName)
  $parts = $RelativePath -split '[\\/]'
  foreach ($p in $parts) {
    if ($ExcludeDirNames -contains $p) { return $true }
  }
  foreach ($pat in $ExcludeFilePatterns) {
    if ($FileName -like $pat) { return $true }
  }
  foreach ($f in $ForceIncludeFiles) {
    if ($FileName -like $f) { return $false }
  }
  return $false
}

function Add-TreeToZip {
  param($Zip, [string]$SourceDir, [string]$EntryPrefix)
  $files = Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Force
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($SourceDir.Length).TrimStart('\', '/')
    $relFull = if ($EntryPrefix) { "$EntryPrefix/$($rel -replace '\\', '/')" } else { $rel -replace '\\', '/' }
    if (Test-ExcludedPath -RelativePath $rel -FileName $f.Name) { continue }
    $entry = $Zip.CreateEntry($relFull, [System.IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = $f.LastWriteTime
    $stream = $entry.Open()
    try {
      $fs = [System.IO.File]::OpenRead($f.FullName)
      try { $fs.CopyTo($stream) } finally { $fs.Dispose() }
    } finally { $stream.Dispose() }
  }
}

# ── 1. 打源码包 ────────────────────────────────────────────────────────────
Write-Host '== 生成源代码压缩包 ==' -ForegroundColor Cyan
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# 进包的顶层内容（显式列出，避免误带）
$topFiles = @('README.md', 'AGENTS.md', 'GLOSSARY.md', '.gitattributes', '.gitignore')
$topDirs  = @('app', 'server', 'tests', 'scripts', 'docs')

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
  foreach ($f in $topFiles) {
    $full = Join-Path $RepoRoot $f
    if (-not (Test-Path $full)) { continue }
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $zip, $full, $f, [System.IO.Compression.CompressionLevel]::Optimal)
  }
  foreach ($d in $topDirs) {
    $full = Join-Path $RepoRoot $d
    if (-not (Test-Path $full)) { continue }
    Write-Host ("  收集 {0} …" -f $d)
    Add-TreeToZip -Zip $zip -SourceDir $full -EntryPrefix $d
  }
} finally { $zip.Dispose() }

$zipSize = (Get-Item $zipPath).Length
Write-Host ("  已生成 {0}（{1:N1} MB）" -f (Split-Path $zipPath -Leaf), ($zipSize / 1MB)) -ForegroundColor Green

# ── 2. 自检：禁词扫描 ──────────────────────────────────────────────────────
Write-Host '== 自检（禁词扫描）==' -ForegroundColor Cyan
$zipCheck = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  $entries = $zipCheck.Entries | ForEach-Object { $_.FullName }
} finally { $zipCheck.Dispose() }

$forbidden = @(
  @{ Name = '密钥文件 .env';    Pattern = '(?i)(^|/)\.env$' },
  @{ Name = '编译产物 build/';  Pattern = '(?i)(^|/)build/' },
  @{ Name = '依赖缓存 oh_modules'; Pattern = '(?i)oh_modules' },
  @{ Name = '第三方资料 _src/';  Pattern = '(?i)(^|/)_src/' },
  @{ Name = '大截图 screenshots'; Pattern = '(?i)screenshots/' },
  @{ Name = '虚拟环境 .venv';   Pattern = '(?i)\.venv/' },
  @{ Name = 'Git 元数据 .git';  Pattern = '(?i)^\.git/' }
)
$bad = @()
foreach ($f in $forbidden) {
  $hit = $entries | Where-Object { $_ -match $f.Pattern }
  if ($hit) { $bad += ("{0}: {1} 条（例：{2}）" -f $f.Name, @($hit).Count, @($hit)[0]) }
}
Write-Host ("  条目数 {0}" -f $entries.Count)
if ($bad.Count -gt 0) {
  Write-Host '  ✗ 命中禁用内容：' -ForegroundColor Red
  $bad | ForEach-Object { Write-Host ("    - {0}" -f $_) -ForegroundColor Red }
  throw '源码包自检未通过，未继续打包 rar。'
}
Write-Host '  ✓ 未命中任何禁用内容' -ForegroundColor Green

# 顺带报告体积构成，便于判断有没有误带大文件
$bigTop = $entries | ForEach-Object { ($_ -split '/')[0] } | Group-Object | Sort-Object Count -Descending |
  Select-Object -First 6 | ForEach-Object { "{0}({1})" -f $_.Name, $_.Count }
Write-Host ("  顶层构成：{0}" -f ($bigTop -join '  '))

if ($SkipRar) {
  Write-Host '== 已指定 -SkipRar，跳过提交包 ==' -ForegroundColor Yellow
  return
}

# ── 3. 组装提交包目录 ──────────────────────────────────────────────────────
Write-Host '== 组装提交包 ==' -ForegroundColor Cyan
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir | Out-Null

$wanted = @(
  @{ Src = '01-设计方案-碳小布CarbonBoo.docx';  Name = '01-设计方案-碳小布CarbonBoo.docx' },
  @{ Src = '02-演示视频-碳小布CarbonBoo.mp4';   Name = '02-演示视频-碳小布CarbonBoo.mp4' },
  @{ Src = '03-演示文稿-碳小布CarbonBoo.pptx';  Name = '03-答辩PPT-碳小布CarbonBoo.pptx' },
  @{ Src = 'README.md';                        Name = '00-提交说明.md' },
  @{ Src = '04-源代码-碳小布CarbonBoo.zip';     Name = '04-源代码-碳小布CarbonBoo.zip' }
)
$missing = @()
foreach ($w in $wanted) {
  $src = Join-Path $submitDir $w.Src
  if (-not (Test-Path $src)) { $missing += $w.Src; continue }
  Copy-Item -LiteralPath $src -Destination (Join-Path $stageDir $w.Name)
  Write-Host ("  + {0}（{1:N1} MB）" -f $w.Name, ((Get-Item $src).Length / 1MB))
}
if ($missing.Count -gt 0) {
  Write-Host ("  ! 缺文件：{0}" -f ($missing -join '、')) -ForegroundColor Yellow
}

# ── 4. 打 rar ─────────────────────────────────────────────────────────────
Write-Host '== 打 rar ==' -ForegroundColor Cyan
if (-not (Test-Path $rarExe)) { throw "找不到 Rar.exe：$rarExe" }
if (Test-Path $rarPath) { Remove-Item $rarPath -Force }
& $rarExe a -m5 -ep1 -idq $rarPath (Join-Path $stageDir '*')
if ($LASTEXITCODE -ne 0) { throw "rar 打包失败，退出码 $LASTEXITCODE" }
Write-Host ("  已生成 {0}（{1:N1} MB）" -f (Split-Path $rarPath -Leaf), ((Get-Item $rarPath).Length / 1MB)) -ForegroundColor Green

Write-Host ''
Write-Host '完成。提交前记得：' -ForegroundColor Cyan
Write-Host '  1) 把 rar 改名成官方格式：赛题二+碳足迹·全民绿色生活碳积分与减排指南+学校名+队名.rar'
Write-Host '  2) 确认 02-演示视频 是你们自己录的最终版（不是脚本合成的演示片）'
Write-Host '  3) 包内材料不得出现院校/团队/指导教师字样（docx 与 pptx 已做过文本扫描）'
