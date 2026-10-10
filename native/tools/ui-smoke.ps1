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
  [StructLayout(LayoutKind.Sequential)] public struct NID { public int cbSize; public IntPtr hWnd; public int uID; public Guid guid; }
  [DllImport("shell32.dll")] public static extern int Shell_NotifyIconGetRect(ref NID id, out RECT r);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
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
function Wait-Pill {
    # Polls rather than sleeps: the single-file exe's FIRST launch unpacks itself
    # (seconds on a cold disk), every later one starts in well under a second
    [OutputType([pscustomobject])]
    param([int]$ProcessId, [int]$TimeoutMs = 15000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $w = Get-Pill -ProcessId $ProcessId
        if ($w) { $w | Add-Member -NotePropertyName AfterMs -NotePropertyValue $sw.ElapsedMilliseconds; return $w }
        Start-Sleep -Milliseconds 100
    }
    return $null
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
# UI Automation: what the WinUI windows actually SAY, and their controls
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
function Get-WindowText {
    [OutputType([string])]
    param([IntPtr]$Hwnd)
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $all = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd).FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    return (@($all | ForEach-Object { $_.Current.Name }) -join ' | ')
}
function Find-UiElement {
    [OutputType([System.Windows.Automation.AutomationElement])]
    param([IntPtr]$Hwnd, [string]$AutomationId = '', [string]$Name = '')
    $prop = if ($AutomationId) { [System.Windows.Automation.AutomationElement]::AutomationIdProperty } else { [System.Windows.Automation.AutomationElement]::NameProperty }
    $cond = New-Object System.Windows.Automation.PropertyCondition($prop, $(if ($AutomationId) { $AutomationId } else { $Name }))
    return [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}
function Get-ShortcutTarget {
    [OutputType([string])]
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    return (New-Object -ComObject WScript.Shell).CreateShortcut($Path).TargetPath
}
$crashPath = Join-Path $env:LOCALAPPDATA 'BatteryPill\crash.log'
$exeFull = (Resolve-Path $Exe).Path
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'BatteryPill.lnk'
Remove-Item $crashPath -ErrorAction SilentlyContinue

# ---- 1. measured run: frames and a first look ----
$measure = Join-Path $OutDir 'measure.txt'
$env:BATTERYPILL_ICON_DUMP = Join-Path $OutDir 'icons'
$p = Start-Process $Exe -ArgumentList '--measure', $measure -PassThru
$w = Wait-Pill -ProcessId $p.Id
Add-Check -Name 'window appears' -Ok ($null -ne $w) -Detail $(if ($w) { "after $($w.AfterMs) ms (first launch) at $($w.L),$($w.T) size $($w.W)x$($w.Hgt)" } else { 'no WinUI window for the process' })
if ($w) { Save-Shot -X ($w.L - 30) -Y ($w.T - 30) -W ($w.W + 60) -H ($w.Hgt + 60) -Name 'pill-measured.png' }
$null = $p.WaitForExit(15000)
$m = if (Test-Path $measure) { Get-Content $measure -Raw } else { '' }
Add-Check -Name 'frames delivered' -Ok ($m -match 'frames=(\d+)' -and [int]$Matches[1] -gt 100) -Detail $m.Trim()
Remove-Item Env:BATTERYPILL_ICON_DUMP -ErrorAction SilentlyContinue
$iconCount = @(Get-ChildItem (Join-Path $OutDir 'icons') -Filter '*.png' -ErrorAction SilentlyContinue).Count
Add-Check -Name 'tray glyphs render' -Ok ($iconCount -eq 30) -Detail "$iconCount PNGs"
Add-Check -Name 'battery read works in this build' -Ok ($m -match 'reader=ok') -Detail $(if ($m -match 'reader=(\S+)') { $Matches[1] } else { 'no probe' })
Add-Check -Name 'live text shown' -Ok ($m -match 'pill_text=(\S+)' -and $Matches[1] -ne '') -Detail $(if ($m -match 'pill_text=(\S+)') { $Matches[1] })

# ---- 1b. upgrading from the PowerShell app, and Start with Windows ----
# A PowerShell user has the Startup shortcut and a config beside the old exe:
# the first native launch must import that config (and not crash on the
# shortcut - the trimmed build once did), and Settings must retarget it.
Remove-Item $cfgPath -ErrorAction SilentlyContinue
$psDir = Join-Path $env:TEMP 'bp-powershell-app'
New-Item -ItemType Directory -Force -Path $psDir | Out-Null
[IO.File]::WriteAllText((Join-Path $psDir 'BatteryWidget.config.json'), '{"X": 300, "Y": 220, "DisplayMode": "percent", "AccentColorIndex": 3, "Theme": "dark", "PillSize": "normal", "Opacity": 0.95}')
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($startupLnk); $lnk.TargetPath = (Join-Path $psDir 'BatteryPill.exe'); $lnk.Save()
$p = Start-Process $Exe -PassThru
$w = Wait-Pill -ProcessId $p.Id
$cfg = Get-Cfg
Add-Check -Name 'imports the PowerShell app settings' -Ok ($null -ne $w -and $cfg -and $cfg.DisplayMode -eq 'percent' -and $cfg.AccentColorIndex -eq 3) -Detail $(if ($cfg) { "mode $($cfg.DisplayMode), accent $($cfg.AccentColorIndex)" } elseif ($p.HasExited) { "exited $($p.ExitCode)" } else { 'no native config' })
if ($w) {
    $mg = [int][math]::Round(18 * [U]::GetDpiForWindow($w.H) / 96.0)
    Add-Check -Name 'the imported position is used' -Ok ($w.L + $mg -eq 300 -and $w.T + $mg -eq 220) -Detail "pill at $($w.L + $mg),$($w.T + $mg)"
}
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500
$sp = Start-Process $Exe -ArgumentList '--settings' -PassThru
Start-Sleep -Milliseconds 3000
$sw = Get-ProcessWindow -ProcessId $sp.Id | Where-Object { $_.Title -eq 'BatteryPill settings' } | Select-Object -First 1
$toggle = if ($sw) { Find-UiElement -Hwnd $sw.H -AutomationId 'AutoStartToggle' } else { $null }
if ($toggle) {
    $tp = $toggle.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    Add-Check -Name 'Start with Windows reads as off while it starts the old app' -Ok ($tp.Current.ToggleState -eq 'Off') -Detail "$($tp.Current.ToggleState)"
    $tp.Toggle(); Start-Sleep -Milliseconds 800
    $target = Get-ShortcutTarget -Path $startupLnk
    Add-Check -Name 'turning it on retargets the Startup shortcut' -Ok ($target -ieq $exeFull) -Detail "target '$target'"
    $tp.Toggle(); Start-Sleep -Milliseconds 800
    Add-Check -Name 'turning it off removes the shortcut' -Ok (-not (Test-Path $startupLnk)) -Detail ''
    Add-Check -Name 'settings survive the toggles' -Ok (-not $sp.HasExited) -Detail $(if ($sp.HasExited) { "exited $($sp.ExitCode)" })
} else {
    Add-Check -Name 'Start with Windows toggle found' -Ok $false -Detail $(if ($sw) { 'no AutoStartToggle element' } elseif ($sp.HasExited) { "settings run exited $($sp.ExitCode)" } else { 'no settings window' })
}
Stop-Process -Id $sp.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500
Remove-Item $startupLnk -ErrorAction SilentlyContinue
Remove-Item $cfgPath -ErrorAction SilentlyContinue

# ---- 2. a normal run: focus, click-through, click, fling, menu ----
$fgBefore = [U]::GetForegroundWindow()
$p = Start-Process $Exe -PassThru
$w = Wait-Pill -ProcessId $p.Id
if ($w) {
    Add-Check -Name 'warm launch shows the pill fast' -Ok ($w.AfterMs -lt 3000) -Detail "after $($w.AfterMs) ms"
    # Let the intro finish before reading geometry and clicking
    Start-Sleep -Milliseconds ([math]::Max(0, 2800 - $w.AfterMs))
    $w = Get-Pill -ProcessId $p.Id
}
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

# ---- tray icon ----
$traceText = if (Test-Path $env:BATTERYPILL_TRACE) { Get-Content $env:BATTERYPILL_TRACE -Raw } else { '' }
Add-Check -Name 'tray icon added' -Ok ($traceText -match 'tray added=True') -Detail ''
$trayHwnd = [U]::FindWindow('BatteryPillTray', 'BatteryPill tray')
# By class AND title: the title once came out as "B" (an ANSI default window
# proc on a Unicode window), and every tray check below then passed or failed blind
Add-Check -Name 'tray window found by its title' -Ok ($trayHwnd -ne [IntPtr]::Zero) -Detail ''
# What the shell sends for ONE left click on a version-4 icon: button down, button
# up, then NIN_SELECT. The card must open once and stay; the next click closes it.
function Send-TrayClick {
    [OutputType([void])]
    param([IntPtr]$Hwnd)
    foreach ($ev in 0x0201, 0x0202, 0x0400) { [void][U]::PostMessage($Hwnd, 0x8001, [IntPtr]0, [IntPtr]((1 -shl 16) -bor $ev)) }
}
# Start from no card at all (the hover card from the menu step must be gone)
[void][U]::SetCursorPos(600, 400); Start-Sleep -Milliseconds 700
$stale = Get-ProcessWindow -ProcessId $p.Id | Where-Object { $_.Title -eq 'BatteryPill details' } | Select-Object -First 1
Add-Check -Name 'no card before the tray click' -Ok ($null -eq $stale) -Detail ''
Send-TrayClick -Hwnd $trayHwnd; Start-Sleep -Milliseconds 900
$tc1 = Get-ProcessWindow -ProcessId $p.Id | Where-Object { $_.Title -eq 'BatteryPill details' } | Select-Object -First 1
Add-Check -Name 'one tray click opens the card and it stays' -Ok ($null -ne $tc1) -Detail $(if ($tc1) { "card $($tc1.W)x$($tc1.Hgt)" } else { 'no card after the click sequence' })
Send-TrayClick -Hwnd $trayHwnd; Start-Sleep -Milliseconds 700
$tc2 = Get-ProcessWindow -ProcessId $p.Id | Where-Object { $_.Title -eq 'BatteryPill details' } | Select-Object -First 1
Add-Check -Name 'the next tray click closes it' -Ok ($null -eq $tc2) -Detail ''
# The real icon, when the shell will say where it is (promoted out of the overflow)
Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue | ForEach-Object {
    if ((Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ExecutablePath -ieq $exeFull) { Set-ItemProperty $_.PSPath -Name IsPromoted -Value 1 -Type DWord }
}
Start-Sleep -Milliseconds 1000
$nid = New-Object U+NID; $nid.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($nid); $nid.hWnd = $trayHwnd; $nid.uID = 1
$tr = New-Object U+RECT
$hr = [U]::Shell_NotifyIconGetRect([ref]$nid, [ref]$tr)
if ($hr -eq 0 -and ($tr.R - $tr.L) -gt 0) {
    $tx = [int](($tr.L + $tr.R) / 2); $ty = [int](($tr.T + $tr.B) / 2)
    Write-Host "INFO  tray icon at $($tr.L),$($tr.T) $($tr.R - $tr.L)x$($tr.B - $tr.T)"
    Send-MouseMove -X $tx -Y $ty; Start-Sleep -Milliseconds 300
    Send-Click -Down $RIGHTDOWN -Up $RIGHTUP; Start-Sleep -Milliseconds 900
    $menuWnd = [U]::FindWindow('#32768', $null)
    if ($menuWnd -ne [IntPtr]::Zero) {
        $mr = New-Object U+RECT; [void][U]::GetWindowRect($menuWnd, [ref]$mr)
        Save-Shot -X ($mr.L - 8) -Y ($mr.T - 8) -W ($mr.R - $mr.L + 16) -H ($mr.B - $mr.T + 16) -Name 'tray-menu.png' -Zoom 2
        Write-Host "INFO  tray menu shown $($mr.R - $mr.L)x$($mr.B - $mr.T)"
    } else { Write-Host 'INFO  no tray menu window seen' }
    [U]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero); [U]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 400
    Send-MouseMove -X $tx -Y $ty; Start-Sleep -Milliseconds 200
    Send-Click -Down $LEFTDOWN -Up $LEFTUP; Start-Sleep -Milliseconds 900
    $tc = Get-ProcessWindow -ProcessId $p.Id | Where-Object { $_.Title -eq 'BatteryPill details' } | Select-Object -First 1
    if ($tc) {
        Save-Shot -X ($tc.L - 12) -Y ($tc.T - 12) -W ($tc.W + 24) -H ($tc.Hgt + 24) -Name 'tray-card.png' -Zoom 2
        Write-Host "INFO  tray click opened the card $($tc.W)x$($tc.Hgt)"
        Send-MouseMove -X 300 -Y 300; Start-Sleep -Milliseconds 200
        Send-Click -Down $LEFTDOWN -Up $LEFTUP; Start-Sleep -Milliseconds 400
    } else { Write-Host 'INFO  tray click: no card seen' }
} else {
    Write-Host "INFO  tray icon rect unavailable (hr=$hr; probably in the overflow area)"
}

# ---- 3. every battery state, rendered from fake firmware readings ----
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400
$cfgBefore = if (Test-Path $cfgPath) { (Get-FileHash $cfgPath).Hash } else { '' }
# What each card must say: its state and its percent
$expect = @{ discharging = 'Discharging', '64'; charging = 'Charging', '47'; low = 'Discharging', '9'; full = 'Fully Charged', '100'; capped = 'Plugged In', '80' }
foreach ($scenario in @('discharging', 'charging', 'low', 'full', 'capped')) {
    $env:BATTERYPILL_FAKE = $scenario
    $f = Start-Process $Exe -PassThru
    Start-Sleep -Milliseconds 2600
    $fw = Get-Pill -ProcessId $f.Id
    if (-not $fw) { Add-Check -Name "render $scenario" -Ok $false -Detail 'no pill window'; continue }
    Save-Shot -X ($fw.L - 30) -Y ($fw.T - 30) -W ($fw.W + 60) -H ($fw.Hgt + 60) -Name "pill-$scenario.png"
    [void][U]::SetCursorPos(($fw.L + [int]($fw.W / 2)), ($fw.T + [int]($fw.Hgt / 2))); Start-Sleep -Milliseconds 1000
    $fc = Get-ProcessWindow -ProcessId $f.Id | Where-Object { $_.Title -eq 'BatteryPill details' } | Select-Object -First 1
    if ($fc) { Save-Shot -X ($fc.L - 12) -Y ($fc.T - 12) -W ($fc.W + 24) -H ($fc.Hgt + 24) -Name "card-$scenario.png" -Zoom 2 }
    $said = if ($fc) { Get-WindowText -Hwnd $fc.H } else { '' }
    $title, $pct = $expect[$scenario]
    $okText = $said -match [regex]::Escape($title) -and $said -match "(^|\D)$pct(\D|$)"
    Add-Check -Name "render $scenario" -Ok ($null -ne $fc -and $okText) -Detail $(if ($fc) { "card $($fc.W)x$($fc.Hgt): $said" } else { 'no card' })
    [void][U]::SetCursorPos(5, 5); Start-Sleep -Milliseconds 300
    Stop-Process -Id $f.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
}
Remove-Item Env:BATTERYPILL_FAKE -ErrorAction SilentlyContinue
$cfgAfter = if (Test-Path $cfgPath) { (Get-FileHash $cfgPath).Hash } else { '' }
Add-Check -Name 'fake readings never touch the real config' -Ok ($cfgBefore -eq $cfgAfter) -Detail ''

# ---- settings window (both themes) ----
foreach ($theme in @('dark', 'light')) {
    $t = [IO.File]::ReadAllText($cfgPath)
    $t = [regex]::Replace($t, '"Theme":\s*"[a-z]+"', ('"Theme": "' + $theme + '"'))
    [IO.File]::WriteAllText($cfgPath, $t)
    $sp = Start-Process $Exe -ArgumentList '--settings' -PassThru
    Start-Sleep -Milliseconds 3000
    $sw = Get-ProcessWindow -ProcessId $sp.Id | Where-Object { $_.Title -eq 'BatteryPill settings' } | Select-Object -First 1
    Add-Check -Name "settings window opens ($theme)" -Ok ($null -ne $sw) -Detail $(if ($sw) { "$($sw.W)x$($sw.Hgt)" } else { 'no settings window' })
    if ($sw) {
        $o = 0; [void][U]::GetWindowThreadProcessId([U]::GetForegroundWindow(), [ref]$o)
        Add-Check -Name "settings takes focus ($theme)" -Ok ($o -eq $sp.Id) -Detail "foreground pid $o"
        Save-Shot -X $sw.L -Y $sw.T -W $sw.W -H ([math]::Min($sw.Hgt, 760)) -Name "settings-$theme.png" -Zoom 1
    }
    Stop-Process -Id $sp.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

# Full-screen context for the record
Add-Type -AssemblyName System.Windows.Forms
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
Save-Shot -X $vs.X -Y $vs.Y -W $vs.Width -H $vs.Height -Name 'desktop.png' -Zoom 1

# ---- 4. Exit from the menu: the real shutdown path ----
$p = Start-Process $Exe -PassThru
$w = Wait-Pill -ProcessId $p.Id
Start-Sleep -Milliseconds 1500
if ($w) {
    [void][U]::SetCursorPos(($w.L + [int]($w.W / 2)), ($w.T + [int]($w.Hgt / 2))); Start-Sleep -Milliseconds 250
    Send-Click -Down $RIGHTDOWN -Up $RIGHTUP; Start-Sleep -Milliseconds 900
    $popup = Get-ProcessWindow -ProcessId $p.Id | Where-Object { $_.Class -like '*Popup*' } | Select-Object -First 1
    $exitItem = if ($popup) { Find-UiElement -Hwnd $popup.H -Name 'Exit' } else { $null }
    $trayBefore = [U]::FindWindow('BatteryPillTray', 'BatteryPill tray')
    if ($exitItem) { $exitItem.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    $gone = $p.WaitForExit(6000)
    Add-Check -Name 'Exit from the menu ends the app' -Ok ($null -ne $exitItem -and $gone) -Detail $(if (-not $exitItem) { 'no Exit item' } elseif (-not $gone) { 'still running' } else { "exit code $($p.ExitCode)" })
    Add-Check -Name 'the tray icon goes with it' -Ok ($trayBefore -ne [IntPtr]::Zero -and [U]::FindWindow('BatteryPillTray', 'BatteryPill tray') -eq [IntPtr]::Zero) -Detail $(if ($trayBefore -eq [IntPtr]::Zero) { 'tray window never found' })
}
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
$crash = if (Test-Path $crashPath) { (Get-Content $crashPath -TotalCount 3) -join ' / ' } else { '' }
Add-Check -Name 'nothing crashed' -Ok (-not (Test-Path $crashPath)) -Detail $crash
if (Test-Path $crashPath) { Copy-Item $crashPath (Join-Path $OutDir 'crash.log') }
$results | ConvertTo-Json | Set-Content (Join-Path $OutDir 'results.json')
$failed = @($results | Where-Object { -not $_.Ok }).Count
Write-Host "UI smoke: $($results.Count - $failed) passed, $failed failed"
exit $(if ($failed -gt 0) { 1 } else { 0 })
