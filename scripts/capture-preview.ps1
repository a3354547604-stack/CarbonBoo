<#
.SYNOPSIS
从 DevEco Studio 的「预览器」面板里截出手机页面图。

.DESCRIPTION
做法：激活 IDE 窗口 -> 整窗抓屏 -> 用「行/列亮像素剖面」找出白色页面矩形 -> 裁切另存。

为什么不直接按亮度包围盒：IDE 顶部工具条与底部状态栏本身就有大量亮像素，
包围盒会退化成整个窗口（实测 1847x1021 整屏）。剖面法只认「有一大片连续亮像素」
的那一块，能稳定锁定手机白底页面。

.PARAMETER OutFile
输出 PNG 路径（必填）。

.PARAMETER Brightness
亮像素阈值，默认 200（白底页面 240+，IDE 深色主题 30~60）。

.PARAMETER Inset
裁切后再向内收缩的像素数，默认 2（去掉手机圆角黑边）。

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\capture-preview.ps1 `
    -OutFile .\docs\screenshots\01-home.png
#>
param(
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$Brightness = 200,
    [int]$Inset = 2,
    [double]$ScanTopPct = 6,
    [double]$ScanBottomPct = 94,
    [string]$ProcessName = 'devecostudio64',
    [int]$DelayMs = 400
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('Win32Capture' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Capture {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    // 逐显示器 DPI 感知。不声明的话 125% 缩放下 CopyFromScreen 只拿逻辑像素（模糊放大图）。
    public static void MakeDpiAware() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
        try { if (SetProcessDpiAwareness(2) == 0) return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }
}
"@
    [Win32Capture]::MakeDpiAware()
}

function Get-IdeWindowHandle {
    param([string]$Name)
    $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($procs.Count -eq 0) { throw "找不到进程 $Name 的主窗口（DevEco Studio 是否在运行？）" }
    $withTitle = $procs | Where-Object { $_.MainWindowTitle -ne '' }
    if ($withTitle) { return ($withTitle | Select-Object -First 1).MainWindowHandle }
    return $procs[0].MainWindowHandle
}

$hwnd = Get-IdeWindowHandle -Name $ProcessName
if ([Win32Capture]::IsIconic($hwnd)) { [void][Win32Capture]::ShowWindow($hwnd, 9) }
[void][Win32Capture]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds $DelayMs

$rect = New-Object Win32Capture+RECT
[void][Win32Capture]::GetWindowRect($hwnd, [ref]$rect)
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
if ($w -le 0 -or $h -le 0) { throw '窗口尺寸异常' }

$bmp = New-Object System.Drawing.Bitmap $w, $h
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
$gfx.Dispose()

# ---- 取像素（一次 LockBits，避免百万次 GetPixel）----
$lockRect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
$data = $bmp.LockBits($lockRect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $data.Stride
$buf = New-Object byte[] ($stride * $h)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
$bmp.UnlockBits($data)

$y0 = [int]($h * $ScanTopPct / 100.0)
$y1 = [int]($h * $ScanBottomPct / 100.0)
$spanY = $y1 - $y0

# 列剖面：某一列里亮像素占扫描区高度的比例
$colCount = New-Object int[] $w
for ($x = 0; $x -lt $w; $x++) {
    $c = 0
    $base = $y0 * $stride + $x * 4
    for ($y = $y0; $y -lt $y1; $y++) {
        $o = $base + ($y - $y0) * $stride
        $v = ($buf[$o + 2] + $buf[$o + 1] + $buf[$o]) / 3
        if ($v -ge $Brightness) { $c++ }
    }
    $colCount[$x] = $c
}

$colThresh = [int]($spanY * 0.30)
$cols = @()
for ($x = 0; $x -lt $w; $x++) { if ($colCount[$x] -ge $colThresh) { $cols += $x } }
if ($cols.Count -lt 20) { throw "没找到页面列（阈值 $colThresh）。预览器是否已渲染并最大化？" }
$px0 = ($cols | Measure-Object -Minimum).Minimum
$px1 = ($cols | Measure-Object -Maximum).Maximum

# 行剖面：在页面列范围内，某一行亮像素占比
$rowCount = New-Object int[] $h
$spanX = $px1 - $px0 + 1
for ($y = $y0; $y -lt $y1; $y++) {
    $c = 0
    $base = $y * $stride + $px0 * 4
    for ($x = $px0; $x -le $px1; $x++) {
        $o = $base + ($x - $px0) * 4
        $v = ($buf[$o + 2] + $buf[$o + 1] + $buf[$o]) / 3
        if ($v -ge $Brightness) { $c++ }
    }
    $rowCount[$y] = $c
}

$rowThresh = [int]($spanX * 0.60)
$rows = @()
for ($y = $y0; $y -lt $y1; $y++) { if ($rowCount[$y] -ge $rowThresh) { $rows += $y } }
if ($rows.Count -lt 20) { throw "没找到页面行（阈值 $rowThresh）" }
$py0 = ($rows | Measure-Object -Minimum).Minimum
$py1 = ($rows | Measure-Object -Maximum).Maximum

# 向内收缩
$px0 += $Inset; $py0 += $Inset; $px1 -= $Inset; $py1 -= $Inset
$cw = $px1 - $px0 + 1
$ch = $py1 - $py0 + 1
if ($cw -lt 50 -or $ch -lt 50) { throw "裁切区域过小 ${cw}x${ch}" }

$cropRect = New-Object System.Drawing.Rectangle $px0, $py0, $cw, $ch
$crop = $bmp.Clone($cropRect, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutFile))
if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
$crop.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$crop.Dispose()
$bmp.Dispose()

Write-Output ("SAVED {0}  {1}x{2}  {3} B  (IDE {4}x{5})" -f $OutFile, $cw, $ch, (Get-Item $OutFile).Length, $w, $h)
