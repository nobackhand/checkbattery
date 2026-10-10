# UI smoke test for the native pill, driven with REAL mouse input.
#
# Runs where an unsigned build is allowed to start: the GitHub Windows runner
# (no Smart App Control). Launches the app, checks frame delivery, focus,
# click-through, click-to-cycle, fling/glide/save and the context menu, and
# saves screenshots to -OutDir. Exits 1 if any check fails.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$OutDir
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$env:BATTERYPILL_TRACE = Join-Path $OutDir 'trace.log'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class U {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, UIntPtr e);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
[void][U]::SetProcessDpiAwarenessContext([IntPtr](-4))
$LEFTDOWN = 0x2; $LEFTUP = 0x4; $RIGHTDOWN = 0x8; $RIGHTUP = 0x10
$results = New-Object System.Collections.ArrayList
function Add-Check {
    [OutputType([void])]
    param([string]$Name, [bool]$Ok, [string]$Detail)
    [void]$results.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
    Write-Host ("{0}  {1}  {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail)
}
function Get-ProcessWindow {
    [OutputType([System.Collections.ArrayList])]
    param([int]$ProcessId)
    $list = New-Object System.Collections.ArrayList
    [void][U]::EnumWindows({ param($h, $l)
            $o = 0; [void][U]::GetWindowThreadProcessId($h, [ref]$o)
            if ($o -eq $ProcessId -and [U]::IsWindowVisible($h)) {
                $r = New-Object U+RECT; [void][U]::GetWindowRect($h, [ref]$r)
                $sb = New-Object Text.StringBuilder 128; [void][U]::GetClassName($h, $sb, 128)
                $tb = New-Object Text.StringBuilder 128; [void][U]::GetWindowText($h, $tb, 128)
                [void]$list.Add([pscustomobject]@{ H = $h; Class = $sb.ToString(); Title = $tb.ToString(); L = $r.L; T = $r.T; W = $r.R - $r.L; Hgt = $r.B - $r.T })
            }; $true }, [IntPtr]::Zero)
    return $list.ToArray()
}
function Get-Pill {
    [OutputType([pscustomobject])]
    param([int]$ProcessId)
    return (Get-ProcessWindow -ProcessId $ProcessId | Where-Object { $_.Title -eq 'BatteryPill' } | Select-Object -First 1)
}
function Save-Shot {
    [OutputType([void])]
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Name, [int]$Zoom = 3)
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size($W, $H))); $g.Dispose()
    $big = New-Object System.Drawing.Bitmap(($W * $Zoom), ($H * $Zoom)); $bg = [System.Drawing.Graphics]::FromImage($big)
    $bg.InterpolationMode = 'NearestNeighbor'; $bg.PixelOffsetMode = 'Half'; $bg.DrawImage($bmp, 0, 0, ($W * $Zoom), ($H * $Zoom)); $bg.Dispose()
    $big.Save((Join-Path $OutDir $Name)); $big.Dispose(); $bmp.Dispose()
}
$cfgPath = Join-Path $env:LOCALAPPDATA 'BatteryPill\BatteryWidget.config.json'
function Send-MouseMove {
    # An absolute move through the input stack, as a physical mouse would send:
    # SetCursorPos only relocates the cursor, which pointer capture may never see
    [OutputType([void])]
    param([int]$X, [int]$Y)
    $sw = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize
    $nx = [uint32][math]::Round($X * 65535.0 / ($sw.Width - 1))
    $ny = [uint32][math]::Round($Y * 65535.0 / ($sw.Height - 1))
    [U]::mouse_event(0x8001, $nx, $ny, 0, [UIntPtr]::Zero)
}
function Get-Cfg {
    [OutputType([pscustomobject])]
    param()
    if (Test-Path $cfgPath) { return (Get-Content $cfgPath -Raw | ConvertFrom-Json) }
    return $null
}
function Send-Click {
    [OutputType([void])]
    param([uint32]$Down, [uint32]$Up)
    [U]::mouse_event($Down, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [U]::mouse_event($Up, 0, 0, 0, [UIntPtr]::Zero)
}

# ---- 1. measured run: frames and a first look ----
$measure = Join-Path $OutDir 'measure.txt'
$p = Start-Process $Exe -ArgumentList '--measure', $measure -PassThru
Start-Sleep -Milliseconds 2200
$w = Get-Pill -ProcessId $p.Id
Add-Check -Name 'window appears' -Ok ($null -ne $w) -Detail $(if ($w) { "at $($w.L),$($w.T) size $($w.W)x$($w.Hgt)" } else { 'no WinUI window for the process' })
if ($w) { Save-Shot -X ($w.L - 30) -Y ($w.T - 30) -W ($w.W + 60) -H ($w.Hgt + 60) -Name 'pill-measured.png' }
$null = $p.WaitForExit(15000)
$m = if (Test-Path $measure) { Get-Content $measure -Raw } else { '' }
Add-Check -Name 'frames delivered' -Ok ($m -match 'frames=(\d+)' -and [int]$Matches[1] -gt 100) -Detail $m.Trim()
Add-Check -Name 'live text shown' -Ok ($m -match 'pill_text=(\S+)' -and $Matches[1] -ne '') -Detail $(if ($m -match 'pill_text=(\S+)') { $Matches[1] })

# ---- 2. a normal run: focus, click-through, click, fling, menu ----
$fgBefore = [U]::GetForegroundWindow()
$p = Start-Process $Exe -PassThru
Start-Sleep -Milliseconds 2800
$w = Get-Pill -ProcessId $p.Id
if (-not $w) { Add-Check -Name 'normal launch' -Ok $false -Detail 'no window'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $results | ConvertTo-Json | Set-Content (Join-Path $OutDir 'results.json'); exit 1 }
$fgAfter = [U]::GetForegroundWindow()
$o = 0; [void][U]::GetWindowThreadProcessId($fgAfter, [ref]$o)
Add-Check -Name 'launch does not take focus' -Ok ($o -ne $p.Id) -Detail "foreground before=$fgBefore after=$fgAfter (pill pid $($p.Id), foreground pid $o)"
Save-Shot -X ($w.L - 30) -Y ($w.T - 30) -W ($w.W + 60) -H ($w.Hgt + 60) -Name 'pill.png'
$scale = $w.W / 144.0
$margin = [int][math]::Round(18 * $scale)
$cx = $w.L + [int]($w.W / 2); $cy = $w.T + [int]($w.Hgt / 2)

[void][U]::SetCursorPos($w.L + 3, $w.T + 3); Start-Sleep -Milliseconds 300
$marginThrough = (([int64][U]::GetWindowLongPtr($w.H, -20)) -band 0x20) -ne 0
[void][U]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 300
$capsuleThrough = (([int64][U]::GetWindowLongPtr($w.H, -20)) -band 0x20) -ne 0
Add-Check -Name 'shadow margin is click-through' -Ok $marginThrough -Detail ''
Add-Check -Name 'capsule takes clicks' -Ok (-not $capsuleThrough) -Detail ''

$before = (Get-Cfg).DisplayMode; if (-not $before) { $before = 'time' }
Send-Click -Down $LEFTDOWN -Up $LEFTUP; Start-Sleep -Milliseconds 700
$after = (Get-Cfg).DisplayMode
Add-Check -Name 'click cycles the display mode' -Ok ($null -ne $after -and $after -ne $before) -Detail "'$before' -> '$after'"
$o = 0; [void][U]::GetWindowThreadProcessId([U]::GetForegroundWindow(), [ref]$o)
Add-Check -Name 'clicking does not take focus' -Ok ($o -ne $p.Id) -Detail "foreground pid $o"
Save-Shot -X ($w.L - 30) -Y ($w.T - 30) -W ($w.W + 60) -H ($w.Hgt + 60) -Name 'pill-after-click.png'

[void][U]::SetCursorPos(5, 5); Start-Sleep -Milliseconds 500
$w = Get-Pill -ProcessId $p.Id; $cx = $w.L + [int]($w.W / 2); $cy = $w.T + [int]($w.Hgt / 2)
[void][U]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 150
[U]::mouse_event($LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 120
for ($i = 1; $i -le 12; $i++) { Send-MouseMove -X ($cx - 20 * $i) -Y ($cy - 6 * $i); Start-Sleep -Milliseconds 8 }
$atRelease = Get-Pill -ProcessId $p.Id
[U]::mouse_event($LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 2000
$landed = Get-Pill -ProcessId $p.Id
Add-Check -Name 'drag moves the pill' -Ok (($w.L - $atRelease.L) -gt 150) -Detail "start $($w.L), at release $($atRelease.L)"
Add-Check -Name 'a fling glides on after release' -Ok (($atRelease.L - $landed.L) -gt 20) -Detail "glided a further $($atRelease.L - $landed.L) px to $($landed.L),$($landed.T)"
$cfg = Get-Cfg
Add-Check -Name 'landing position is saved' -Ok ($cfg.X -eq ($landed.L + $margin) -and $cfg.Y -eq ($landed.T + $margin)) -Detail "saved $($cfg.X),$($cfg.Y); window+margin $($landed.L + $margin),$($landed.T + $margin)"

$cx = $landed.L + [int]($landed.W / 2); $cy = $landed.T + [int]($landed.Hgt / 2)
# Hover: rest on the pill, the details card appears beside it; leave, it goes
[void][U]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 900
$card = Get-ProcessWindow -ProcessId $p.Id | Where-Object { $_.Title -eq 'BatteryPill details' } | Select-Object -First 1
Add-Check -Name 'hover shows the details card' -Ok ($null -ne $card) -Detail $(if ($card) { "card $($card.W)x$($card.Hgt) at $($card.L),$($card.T)" } else { 'no card window' })
if ($card) { Save-Shot -X ($card.L - 12) -Y ($card.T - 12) -W ($card.W + 24) -H ($card.Hgt + 24) -Name 'flyout.png' -Zoom 2 }
[void][U]::SetCursorPos(5, 5); Start-Sleep -Milliseconds 700
$cardAfter = Get-ProcessWindow -ProcessId $p.Id | Where-Object { $_.Title -eq 'BatteryPill details' } | Select-Object -First 1
Add-Check -Name 'the card goes when the cursor leaves' -Ok ($null -eq $cardAfter) -Detail ''
[void][U]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 200

[void][U]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 250
Send-Click -Down $RIGHTDOWN -Up $RIGHTUP; Start-Sleep -Milliseconds 900
$popup = Get-ProcessWindow -ProcessId $p.Id | Where-Object { $_.Class -like '*Popup*' } | Select-Object -First 1
Add-Check -Name 'right-click opens the menu' -Ok ($null -ne $popup) -Detail $(if ($popup) { "$($popup.Class) $($popup.W)x$($popup.Hgt)" })
if ($popup) { Save-Shot -X ($popup.L - 10) -Y ($popup.T - 10) -W ($popup.W + 20) -H ($popup.Hgt + 20) -Name 'menu.png' -Zoom 2 }
[U]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero); [U]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 300

# Full-screen context for the record
Add-Type -AssemblyName System.Windows.Forms
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
Save-Shot -X $vs.X -Y $vs.Y -W $vs.Width -H $vs.Height -Name 'desktop.png' -Zoom 1

Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
$results | ConvertTo-Json | Set-Content (Join-Path $OutDir 'results.json')
$failed = @($results | Where-Object { -not $_.Ok }).Count
Write-Host "UI smoke: $($results.Count - $failed) passed, $failed failed"
exit $(if ($failed -gt 0) { 1 } else { 0 })
