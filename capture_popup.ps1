Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class CaptureHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, IntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X, Y;
    }

    public const uint MOUSEEVENTF_MOVE = 0x0001;

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public static List<RECT> GetProcessWindows(uint pid, int minSize) {
        var results = new List<RECT>();
        EnumWindows((hWnd, lParam) => {
            if (IsWindowVisible(hWnd)) {
                uint wpid;
                GetWindowThreadProcessId(hWnd, out wpid);
                if (wpid == pid) {
                    RECT rect;
                    GetWindowRect(hWnd, out rect);
                    int w = rect.Right - rect.Left;
                    int h = rect.Bottom - rect.Top;
                    if (w > minSize && h > minSize) {
                        results.Add(rect);
                    }
                }
            }
            return true;
        }, IntPtr.Zero);
        return results;
    }

    public static void MoveCursorTo(int screenX, int screenY) {
        SetCursorPos(screenX, screenY);
        // Nudge with relative mouse_event to generate WM_MOUSEMOVE
        mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, IntPtr.Zero);
        System.Threading.Thread.Sleep(50);
        mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, IntPtr.Zero);
    }
}
"@

# Make this process DPI-aware so coordinates match the widget
[CaptureHelper]::SetProcessDPIAware() | Out-Null

# Find running widget or launch it
$widgetProc = Get-Process -Name "BatteryWidget" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($widgetProc) {
    Write-Host "Found running BatteryWidget PID: $($widgetProc.Id)"
    $pid_ = [uint32]$widgetProc.Id
} else {
    $exePath = Get-ChildItem (Join-Path $PSScriptRoot "BatteryPill-*.exe") | Select-Object -First 1 -ExpandProperty FullName
    Write-Host "Launching $exePath..."
    $proc = Start-Process -FilePath $exePath -PassThru
    $pid_ = [uint32]$proc.Id
    Write-Host "Launched PID: $pid_"
    Write-Host "Waiting 6 seconds for startup..."
    Start-Sleep -Seconds 6
    if ($proc.HasExited) {
        Write-Host "ERROR: Widget exited with code $($proc.ExitCode)" -ForegroundColor Red
        exit 1
    }
}

# Step 1: Find the pill window
$windows = [CaptureHelper]::GetProcessWindows($pid_, 20)
Write-Host "Found $($windows.Count) visible windows before hover:"
foreach ($w in $windows) {
    $ww = $w.Right - $w.Left; $wh = $w.Bottom - $w.Top
    Write-Host "  ($($w.Left),$($w.Top)) ${ww}x${wh}"
}

if ($windows.Count -eq 0) {
    Write-Host "ERROR: No widget windows found" -ForegroundColor Red
    exit 1
}

# Filter out hidden/off-screen windows (WinForms parks hidden forms at -32000)
$onScreen = $windows | Where-Object { $_.Left -gt -10000 -and $_.Top -gt -10000 }
if ($onScreen.Count -eq 0) {
    Write-Host "ERROR: No on-screen windows found" -ForegroundColor Red
    exit 1
}

# Pill is the smallest on-screen window
$pill = $onScreen[0]
foreach ($w in $onScreen) {
    $area = ($w.Right - $w.Left) * ($w.Bottom - $w.Top)
    $pillArea = ($pill.Right - $pill.Left) * ($pill.Bottom - $pill.Top)
    if ($area -lt $pillArea) { $pill = $w }
}
$pillW = $pill.Right - $pill.Left
$pillH = $pill.Bottom - $pill.Top
$pillCX = $pill.Left + [int]($pillW / 2)
$pillCY = $pill.Top + [int]($pillH / 2)
Write-Host "Pill: ($($pill.Left),$($pill.Top)) ${pillW}x${pillH}, center: ($pillCX, $pillCY)"

# Step 2: Move cursor OFF the pill first, then onto it (ensures MouseEnter fires)
Write-Host "Moving cursor away first..."
[CaptureHelper]::MoveCursorTo(($pill.Left - 50), $pillCY)
Start-Sleep -Milliseconds 500

Write-Host "Moving cursor to pill center..."
[CaptureHelper]::MoveCursorTo($pillCX, $pillCY)

# Wait for hover delay (500ms) + fade-in (150ms) + buffer
Write-Host "Waiting 2.5s for hover popup to appear and fade in..."
Start-Sleep -Milliseconds 2500

# Verify cursor position
$curPos = New-Object CaptureHelper+POINT
[CaptureHelper]::GetCursorPos([ref]$curPos) | Out-Null
Write-Host "Cursor now at: ($($curPos.X), $($curPos.Y))"

# Step 3: Re-enumerate windows to find popup
$windows2 = [CaptureHelper]::GetProcessWindows($pid_, 20)
Write-Host "Found $($windows2.Count) visible windows after hover:"
foreach ($w in $windows2) {
    $ww = $w.Right - $w.Left; $wh = $w.Bottom - $w.Top
    Write-Host "  ($($w.Left),$($w.Top)) ${ww}x${wh}"
}

if ($windows2.Count -lt 2) {
    Write-Host "Popup didn't appear. Retry..." -ForegroundColor Yellow
    [CaptureHelper]::MoveCursorTo(($pill.Left - 50), $pillCY)
    Start-Sleep -Milliseconds 500
    [CaptureHelper]::MoveCursorTo($pillCX, $pillCY)
    Start-Sleep -Milliseconds 3000
    $windows2 = [CaptureHelper]::GetProcessWindows($pid_, 20)
    Write-Host "Found $($windows2.Count) visible windows on retry:"
    foreach ($w in $windows2) {
        $ww = $w.Right - $w.Left; $wh = $w.Bottom - $w.Top
        Write-Host "  ($($w.Left),$($w.Top)) ${ww}x${wh}"
    }
}

# Compute bounding box (only on-screen windows)
$onScreen2 = $windows2 | Where-Object { $_.Left -gt -10000 -and $_.Top -gt -10000 }
$minX = [int]::MaxValue; $minY = [int]::MaxValue
$maxX = [int]::MinValue; $maxY = [int]::MinValue
foreach ($w in $onScreen2) {
    if ($w.Left -lt $minX) { $minX = $w.Left }
    if ($w.Top -lt $minY) { $minY = $w.Top }
    if ($w.Right -gt $maxX) { $maxX = $w.Right }
    if ($w.Bottom -gt $maxY) { $maxY = $w.Bottom }
}

$pad = 20
$captureX = [math]::Max(0, $minX - $pad)
$captureY = [math]::Max(0, $minY - $pad)
$captureW = ($maxX - $minX) + $pad * 2
$captureH = ($maxY - $minY) + $pad * 2

Write-Host "Capture region: ($captureX, $captureY) ${captureW}x${captureH}"

if ($captureW -le 0 -or $captureH -le 0) {
    Write-Host "ERROR: Invalid capture dimensions" -ForegroundColor Red
    exit 1
}

# Capture screenshot
$bmp = New-Object System.Drawing.Bitmap($captureW, $captureH)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($captureX, $captureY, 0, 0, (New-Object System.Drawing.Size($captureW, $captureH)))
$g.Dispose()

$outPath = Join-Path $PSScriptRoot "docs\screenshot-popup.png"
$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Host ""
Write-Host "Screenshot saved to: $outPath" -ForegroundColor Green
$fileSize = [math]::Round((Get-Item $outPath).Length / 1KB)
Write-Host "File size: $fileSize KB"
Write-Host "Dimensions: ${captureW}x${captureH}"
