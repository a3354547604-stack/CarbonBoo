<#
.SYNOPSIS
DevEco Studio 预览器操作器：定位手机页面矩形、截图、模拟点击。

.DESCRIPTION
- 手机页面矩形靠「行/列亮像素剖面」在 IDE 窗口截图里定位（不是亮度包围盒，
  因为 IDE 顶部工具条与底部状态栏本身就有大量亮像素）。
- 点击坐标以「页面图内像素」为准（就是你用看图软件在 PNG 上量到的坐标）：
  脚本把页面矩形换算成屏幕坐标后左击一次。预览器会把鼠标事件当成触摸事件。

.PARAMETER Action
info = 只打印页面矩形与窗口矩形；capture = 截图；click = 点击（可同时截图）。

.PARAMETER PageX / PageY
点击点，单位是页面图内像素（左上角为 0,0）。

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\preview-run.ps1 -Action info
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\preview-run.ps1 -Action click -PageX 100 -PageY 680 -OutFile .\docs\screenshots\02-dashboard.png
#>
param(
    [ValidateSet('info', 'capture', 'click')][string]$Action = 'capture',
    [string]$OutFile = '',
    [int]$PageX = -1,
    [int]$PageY = -1,
    [int]$Brightness = 200,
    [int]$Inset = 2,
    [double]$ScanTopPct = 6,
    [double]$ScanBottomPct = 94,
    [string]$ProcessName = 'devecostudio64',
    [int]$DelayMs = 400,
    [int]$AfterClickMs = 900
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('Win32Preview' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Preview {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP = 0x0004;

    public static void MakeDpiAware() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
        try { if (SetProcessDpiAwareness(2) == 0) return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }

    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(60);
        mouse_event(LEFTDOWN, 0, 0, 0, IntPtr.Zero);
        System.Threading.Thread.Sleep(60);
        mouse_event(LEFTUP, 0, 0, 0, IntPtr.Zero);
    }
}
"@
    [Win32Preview]::MakeDpiAware()
}

function Get-IdeHandle {
    param([string]$Name)
    $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($procs.Count -eq 0) { throw "找不到进程 $Name 的主窗口" }
    $titled = $procs | Where-Object { $_.MainWindowTitle -ne '' }
    if ($titled) { return ($titled | Select-Object -First 1).MainWindowHandle }
    return $procs[0].MainWindowHandle
}

function Get-WindowShot {
    param([IntPtr]$Hwnd)
    if ([Win32Preview]::IsIconic($Hwnd)) { [void][Win32Preview]::ShowWindow($Hwnd, 9) }
    [void][Win32Preview]::SetForegroundWindow($Hwnd)
    Start-Sleep -Milliseconds $DelayMs
    $r = New-Object Win32Preview+RECT
    [void][Win32Preview]::GetWindowRect($Hwnd, [ref]$r)
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { throw '窗口尺寸异常' }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $g.Dispose()
    return [pscustomobject]@{ Bitmap = $bmp; Left = $r.Left; Top = $r.Top; Width = $w; Height = $h }
}

function Get-PageRect {
    param([System.Drawing.Bitmap]$Bmp, [int]$W, [int]$H)
    $lockRect = New-Object System.Drawing.Rectangle 0, 0, $W, $H
    $data = $Bmp.LockBits($lockRect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $buf = New-Object byte[] ($stride * $H)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    $Bmp.UnlockBits($data)

    $y0 = [int]($H * $ScanTopPct / 100.0)
    $y1 = [int]($H * $ScanBottomPct / 100.0)
    $spanY = $y1 - $y0

    $cols = New-Object System.Collections.ArrayList
    $colThresh = [int]($spanY * 0.30)
    for ($x = 0; $x -lt $W; $x++) {
        $c = 0
        $base = $y0 * $stride + $x * 4
        for ($y = $y0; $y -lt $y1; $y++) {
            $o = $base + ($y - $y0) * $stride
            if ((($buf[$o + 2] + $buf[$o + 1] + $buf[$o]) / 3) -ge $Brightness) { $c++ }
        }
        if ($c -ge $colThresh) { [void]$cols.Add($x) }
    }
    if ($cols.Count -lt 20) { throw '没找到页面列：预览器是否已渲染并最大化？' }
    $px0 = ($cols | Measure-Object -Minimum).Minimum
    $px1 = ($cols | Measure-Object -Maximum).Maximum

    $spanX = $px1 - $px0 + 1
    $rowThresh = [int]($spanX * 0.60)
    $rows = New-Object System.Collections.ArrayList
    for ($y = $y0; $y -lt $y1; $y++) {
        $c = 0
        $base = $y * $stride + $px0 * 4
        for ($x = $px0; $x -le $px1; $x++) {
            $o = $base + ($x - $px0) * 4
            if ((($buf[$o + 2] + $buf[$o + 1] + $buf[$o]) / 3) -ge $Brightness) { $c++ }
        }
        if ($c -ge $rowThresh) { [void]$rows.Add($y) }
    }
    if ($rows.Count -lt 20) { throw '没找到页面行' }
    $py0 = ($rows | Measure-Object -Minimum).Minimum
    $py1 = ($rows | Measure-Object -Maximum).Maximum

    $px0 += $Inset; $py0 += $Inset; $px1 -= $Inset; $py1 -= $Inset
    return [pscustomobject]@{
        X = $px0; Y = $py0
        Width = ($px1 - $px0 + 1); Height = ($py1 - $py0 + 1)
    }
}

$hwnd = Get-IdeHandle -Name $ProcessName
$shot = Get-WindowShot -Hwnd $hwnd
$page = Get-PageRect -Bmp $shot.Bitmap -W $shot.Width -H $shot.Height
$screenX = $shot.Left + $page.X
$screenY = $shot.Top + $page.Y

if ($Action -eq 'info') {
    Write-Output ("WINDOW {0}x{1} @ ({2},{3})" -f $shot.Width, $shot.Height, $shot.Left, $shot.Top)
    Write-Output ("PAGE   {0}x{1} @ screen ({2},{3})" -f $page.Width, $page.Height, $screenX, $screenY)
    $shot.Bitmap.Dispose()
    return
}

if ($Action -eq 'click') {
    if ($PageX -lt 0 -or $PageY -lt 0) { throw 'click 需要 -PageX / -PageY' }
    if ($PageX -ge $page.Width -or $PageY -ge $page.Height) {
        throw ("点击点 ({0},{1}) 超出页面范围 {2}x{3}" -f $PageX, $PageY, $page.Width, $page.Height)
    }
    [Win32Preview]::Click($screenX + $PageX, $screenY + $PageY)
    Start-Sleep -Milliseconds $AfterClickMs
    $shot.Bitmap.Dispose()
    if ($OutFile -eq '') {
        Write-Output ("CLICKED page({0},{1}) -> screen({2},{3})" -f $PageX, $PageY, ($screenX + $PageX), ($screenY + $PageY))
        return
    }
    $shot = Get-WindowShot -Hwnd $hwnd
    $page = Get-PageRect -Bmp $shot.Bitmap -W $shot.Width -H $shot.Height
}

$cw = $page.Width
$ch = $page.Height
if ($cw -lt 50 -or $ch -lt 50) { throw "裁切区域过小 ${cw}x${ch}" }
$cropRect = New-Object System.Drawing.Rectangle $page.X, $page.Y, $cw, $ch
$crop = $shot.Bitmap.Clone($cropRect, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutFile))
if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
$crop.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$crop.Dispose()
$shot.Bitmap.Dispose()

Write-Output ("SAVED {0}  {1}x{2}  {3} B  (window {4}x{5} @ {6},{7}; page @ {8},{9})" -f `
        $OutFile, $cw, $ch, (Get-Item $OutFile).Length, $shot.Width, $shot.Height, $shot.Left, $shot.Top, $page.X, $page.Y)
