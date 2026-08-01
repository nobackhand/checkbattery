# tools\render-states.ps1
#
# Headless state renderer for the widget source (Windows PowerShell 5.1).
# Assembles the src\ modules (tools\_assemble.ps1), then
# stages a modified copy of the widget in a temp dir (message loop stripped,
# render harness appended, harness-specific mutex), runs it via a child
# "powershell -STA -File" process, and captures:
#   - PNGs of the requested states into -OutDir
#   - a control-geometry dump for EVERY popup state into <OutDir>\geometry.txt
#     (type, X, Right, Width, wrapped-line count, text). The dump is the
#     reliable layout oracle; the PNGs are for eyeballing.
# Never touches repo files: the widget resolves its config path from
# $PSScriptRoot, and the harness copy lives in the temp stage dir.
# Kills the child process if it exceeds -TimeoutSec.
#
# Usage:
#   .\tools\render-states.ps1
#   .\tools\render-states.ps1 -States popup-discharge,settings -DrawToBitmap
# -DrawToBitmap: capture via Control.DrawToBitmap instead of CopyFromScreen
#   (needed under RDP, where CopyFromScreen fails; slightly less faithful).

param(
    [string]$OutDir = (Join-Path $env:TEMP 'batterypill-renders'),
    [string[]]$States = @('popup-discharge', 'popup-charging', 'popup-nobattery', 'popup-collecting', 'pill-time', 'pill-percent', 'pill-both', 'settings'),
    [switch]$DrawToBitmap,
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = 'Stop'
$validStates = @('popup-discharge', 'popup-charging', 'popup-nobattery', 'popup-collecting', 'pill-time', 'pill-percent', 'pill-both', 'settings')
foreach ($s in $States) {
    if ($validStates -notcontains $s) {
        Write-Host "FAIL: unknown state '$s'. Valid: $($validStates -join ', ')"
        exit 1
    }
}

. (Join-Path $PSScriptRoot '_assemble.ps1')
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path $OutDir).Path

# Remove stale outputs for the requested states so old files cannot mislead
foreach ($s in $States) {
    $stale = Join-Path $OutDir ($s + '.png')
    if (Test-Path $stale) { Remove-Item $stale -Force }
}
$geomPath = Join-Path $OutDir 'geometry.txt'
if (Test-Path $geomPath) { Remove-Item $geomPath -Force }

# Stage the harness in an isolated temp dir (widget config load/save lands here)
$stageDir = Join-Path $env:TEMP ('batterypill-harness-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageDir | Out-Null
$harnessPath = Join-Path $stageDir 'harness.ps1'

$text = Get-AssembledWidgetText
$runPattern = '\[System\.Windows\.Forms\.Application\]::Run\(\$script:mainForm\)'
if ($text -notmatch $runPattern) {
    Write-Host 'FAIL: Application::Run line not found in the assembled widget source (source changed?)'
    Remove-Item $stageDir -Recurse -Force
    exit 1
}
$text = $text -replace $runPattern, '# (message loop removed by tools/render-states.ps1)'
# Harness-specific mutex so a running real widget cannot block us on a MessageBox
$text = $text.Replace('Global\BatteryWidgetSingleInstance', 'Global\BatteryPillRenderHarness')

$suffix = @'

# ============ RENDER HARNESS (appended by tools\render-states.ps1) ============
$ErrorActionPreference = 'Stop'
$OUT = '__OUTDIR__'
$HZSTATES = '__STATES__'.Split(',')
$HZDTB = ('__DTB__' -eq '1')
$GEOM = Join-Path $OUT 'geometry.txt'
# Quiesce the live update timer so real WMI data cannot repaint mid-capture
if ($null -ne $script:timer) { $script:timer.Stop() }

function Add-GeomLine {
    param([string]$line)
    [System.IO.File]::AppendAllText($GEOM, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $true))
}

function Seed-History {
    param([bool]$charging = $false)
    $h = @()
    $base = (Get-Date).AddHours(-2)
    for ($i = 0; $i -lt 48; $i++) {
        if ($charging) { $p = [math]::Min(100, 42 + $i * 1.25) }
        else { $p = [math]::Max(6, 95 - $i * 1.55 + [math]::Sin($i / 3.0) * 2.5) }
        $isC = $false
        if ($charging) { $isC = ($i -lt 34) } else { $isC = ($i -lt 6) }
        $h += [pscustomobject]@{ Time = $base.AddMinutes($i * 2.5); Percent = [int]$p; IsCharging = $isC }
    }
    return ,$h
}

function Write-GeometryDump {
    param([string]$stateName, [hashtable]$info)
    $df = New-Object System.Windows.Forms.Form
    $df.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $df.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $df.ClientSize = New-Object System.Drawing.Size(300, 480)
    $null = New-BatteryPopupContent -BatteryInfo $info -Form $df -PopupWidth 300 -DpiScale 1.0 -CloseHintText ""
    $df.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $df.Location = New-Object System.Drawing.Point(-4000, -4000)
    $df.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.Application]::DoEvents()
    Add-GeomLine ("=== state {0} (popupWidth=300 dpi=1.0) ===" -f $stateName)
    foreach ($c in $df.Controls) {
        $lineCount = 1
        if ($null -ne $c.Font -and $c.Font.Height -gt 0) { $lineCount = [math]::Max(1, [math]::Round($c.Height / $c.Font.Height)) }
        $txt = ''
        if ($null -ne $c.Text) { $txt = ($c.Text -replace '\r?\n', ' / ') }
        Add-GeomLine ("{0,-12} X={1,4} R={2,4} W={3,4} lines={4} '{5}'" -f $c.GetType().Name, $c.Left, ($c.Left + $c.Width), $c.Width, $lineCount, $txt)
    }
    Add-GeomLine ''
    $df.Hide()
    $df.Dispose()
}

function Render-PopupState {
    param([string]$name, [hashtable]$info, [switch]$EmptyHistory)
    $script:config.Theme = 'dark'
    Set-Theme
    if ($EmptyHistory) { $script:batteryHistory = @() }
    else { $script:batteryHistory = Seed-History -charging:([bool]$info.IsCharging) }
    Write-GeometryDump -stateName $name -info $info   # oracle first: survives capture failures
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.BackColor = $script:theme.PopupBg
    $f.ClientSize = New-Object System.Drawing.Size(300, 480)
    $res = New-BatteryPopupContent -BatteryInfo $info -Form $f -PopupWidth 300 -DpiScale 1.0 -CloseHintText ""
    $f.ClientSize = New-Object System.Drawing.Size(300, [int]$res.TotalHeight)
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.Location = New-Object System.Drawing.Point(60, 60)
    $script:hzForm = $f
    $script:hzPath = Join-Path $OUT ($name + '.png')
    $script:hzDtb = $HZDTB
    $script:hzTimer = New-Object System.Windows.Forms.Timer
    $script:hzTimer.Interval = 450
    $script:hzTimer.Add_Tick({
        $script:hzTimer.Stop()
        $cf = $script:hzForm
        $bmp = New-Object System.Drawing.Bitmap($cf.ClientSize.Width, $cf.ClientSize.Height)
        if ($script:hzDtb) {
            $cf.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $cf.ClientSize.Width, $cf.ClientSize.Height)))
        } else {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($cf.Bounds.Location, [System.Drawing.Point]::Empty, $cf.Bounds.Size)
            $g.Dispose()
        }
        $bmp.Save($script:hzPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $cf.Close()
    })
    $script:hzTimer.Start()
    $f.ShowDialog() | Out-Null
    $script:hzTimer.Dispose()
    $f.Dispose()
    Write-Host ("saved {0}.png (300x{1})" -f $name, [int]$res.TotalHeight)
}

function Render-PillState {
    param([string]$name, [hashtable]$info, [string]$mode)
    $script:config.Theme = 'dark'
    Set-Theme
    $script:config.DisplayMode = $mode
    Update-PillSize
    for ($k = 0; $k -lt 15; $k++) { Update-FloatingBar -BatteryInfo $info }   # converge accent lerp
    $script:floatingBar.Refresh()
    $w = $script:floatingBar.Width; $h = $script:floatingBar.Height
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $script:floatingBar.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
    $bmp.Save((Join-Path $OUT ($name + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("saved {0}.png ({1}x{2})" -f $name, $w, $h)
}

function Render-SettingsState {
    param([string]$name)
    $script:config.Theme = 'dark'
    Set-Theme
    $script:hzPath = Join-Path $OUT ($name + '.png')
    $script:hzDtb = $HZDTB
    $script:hzTries = 0
    $script:hzTimer = New-Object System.Windows.Forms.Timer
    $script:hzTimer.Interval = 500
    $script:hzTimer.Add_Tick({
        $sf = $null
        foreach ($of in [System.Windows.Forms.Application]::OpenForms) {
            if ($of.Text -like '*Settings*') { $sf = $of; break }
        }
        if ($null -ne $sf) {
            $script:hzTimer.Stop()
            $b = $sf.Bounds
            $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
            if ($script:hzDtb) {
                $sf.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $b.Width, $b.Height)))
            } else {
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
                $g.Dispose()
            }
            $bmp.Save($script:hzPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            Write-Host ("saved settings.png ({0}x{1})" -f $b.Width, $b.Height)
            $sf.Close()
        } else {
            $script:hzTries++
            if ($script:hzTries -ge 10) {
                $script:hzTimer.Stop()
                Write-Host 'WARN: settings form not found; closing active form to unblock'
                $af = [System.Windows.Forms.Form]::ActiveForm
                if ($null -ne $af) { $af.Close() }
            }
        }
    })
    $script:hzTimer.Start()
    Show-SettingsPanel
    $script:hzTimer.Dispose()
}

$hzDischarge = @{
    Percent = 72; PercentExact = 72.0; IsCharging = $false; IsPluggedIn = $false; IsFullyCharged = $false; NoBattery = $false
    StatusText = 'Discharging'; TimeMinutes = 188; TimeString = '3 hours 8 minutes'; TimeLabel = 'Time Remaining:'
    PowerSource = 'Battery (unplugged)'; DesignCapacity = 59970; FullChargeCapacity = 56270; DischargeRate = 8241; ChargeRate = -1
    BatteryWearPercent = 6.2; ETA = '6:42 PM'; FullRuntimeMinutes = 272; ElapsedTime = '1:24'; ElapsedSince = '91%'
}
$hzCharging = @{
    Percent = 47; PercentExact = 47.0; IsCharging = $true; IsPluggedIn = $true; IsFullyCharged = $false; NoBattery = $false
    StatusText = 'Charging'; TimeMinutes = 63; TimeString = '1 hour 3 minutes'; TimeLabel = 'Time to Full:'
    PowerSource = 'AC Power (plugged in)'; DesignCapacity = 59970; FullChargeCapacity = 56270; DischargeRate = -1; ChargeRate = 24680
    BatteryWearPercent = 6.2; ETA = '5:10 PM'; FullRuntimeMinutes = -1; ElapsedTime = '0:21'; ElapsedSince = '35%'
}
$hzNoBattery = @{
    Percent = -1; PercentExact = -1.0; IsCharging = $false; IsPluggedIn = $false; IsFullyCharged = $false; NoBattery = $true
    StatusText = 'No Battery'; TimeMinutes = -1; TimeString = 'N/A'; TimeLabel = 'Time Remaining:'; PowerSource = 'AC Power'
    DesignCapacity = -1; FullChargeCapacity = -1; DischargeRate = -1; ChargeRate = -1; BatteryWearPercent = -1.0
    ETA = ''; FullRuntimeMinutes = -1; ElapsedTime = ''; ElapsedSince = ''
}
$hzCollecting = @{
    Percent = 64; PercentExact = 64.0; IsCharging = $false; IsPluggedIn = $false; IsFullyCharged = $false; NoBattery = $false
    StatusText = 'Discharging'; TimeMinutes = -1; TimeString = 'Estimating...'; TimeLabel = 'Time Remaining:'
    PowerSource = 'Battery (unplugged)'; DesignCapacity = 59970; FullChargeCapacity = 56270; DischargeRate = -1; ChargeRate = -1
    BatteryWearPercent = 6.2; ETA = ''; FullRuntimeMinutes = -1; ElapsedTime = '0:02'; ElapsedSince = '64%'
}

$hzFailed = 0
foreach ($s in $HZSTATES) {
    try {
        switch ($s) {
            'popup-discharge'  { Render-PopupState -name $s -info $hzDischarge }
            'popup-charging'   { Render-PopupState -name $s -info $hzCharging }
            'popup-nobattery'  { Render-PopupState -name $s -info $hzNoBattery }
            'popup-collecting' { Render-PopupState -name $s -info $hzCollecting -EmptyHistory }
            'pill-time'        { Render-PillState -name $s -info $hzDischarge -mode 'time' }
            'pill-percent'     { Render-PillState -name $s -info $hzDischarge -mode 'percent' }
            'pill-both'        { Render-PillState -name $s -info $hzCharging -mode 'both' }
            'settings'         { Render-SettingsState -name $s }
            default            { Write-Host ("WARN: unknown state '{0}' skipped" -f $s) }
        }
    } catch {
        Write-Host ("ERROR in state {0}: {1}" -f $s, $_.Exception.Message)
        $hzFailed++
    }
}
# Cleanup so nothing lingers after the process exits
if ($null -ne $script:notifyIcon) { $script:notifyIcon.Visible = $false; $script:notifyIcon.Dispose() }
if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) { $script:floatingBar.Hide() }
if ($hzFailed -eq 0) { Write-Host 'HARNESS-DONE'; exit 0 }
Write-Host ("HARNESS-FAILED ({0} state(s))" -f $hzFailed)
exit 1
'@

$dtbFlag = '0'
if ($DrawToBitmap) { $dtbFlag = '1' }
$suffix = $suffix.Replace('__OUTDIR__', $OutDir).Replace('__STATES__', ($States -join ',')).Replace('__DTB__', $dtbFlag)
[System.IO.File]::WriteAllText($harnessPath, $text + "`r`n" + $suffix, (New-Object System.Text.UTF8Encoding $true))
# Pre-seed config so the first-run tooltip never fires during captures
[System.IO.File]::WriteAllText((Join-Path $stageDir 'BatteryWidget.config.json'), '{ "FirstRunShown": true }', (New-Object System.Text.ASCIIEncoding))

$outLog = Join-Path $stageDir 'stdout.log'
$errLog = Join-Path $stageDir 'stderr.log'
$psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $harnessPath + '"'))
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Write-Host "Harness process $($proc.Id) started (timeout ${TimeoutSec}s)..."

$timedOut = $false
if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    $timedOut = $true
    Write-Host "TIMEOUT: killing harness process $($proc.Id)"
    try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch {}
    $null = $proc.WaitForExit(5000)
}
# NOTE: after Start-Process + WaitForExit(ms), ExitCode can be $null in PS 5.1
# (handle quirk) - informational only; success keys on the HARNESS-DONE sentinel.
$exitCode = $null
try { $exitCode = $proc.ExitCode } catch {}

$stdoutText = ''
if (Test-Path $outLog) { $stdoutText = [System.IO.File]::ReadAllText($outLog) }
if ($stdoutText.Trim()) { Write-Host $stdoutText.TrimEnd() }
if (Test-Path $errLog) {
    $errText = [System.IO.File]::ReadAllText($errLog)
    if ($errText.Trim()) { Write-Host '--- harness stderr ---'; Write-Host $errText.TrimEnd() }
}
Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '---'
$produced = @(Get-ChildItem -Path $OutDir -Filter '*.png' | Where-Object { $States -contains $_.BaseName })
foreach ($f in $produced) { Write-Host ("output: {0} ({1} bytes)" -f $f.FullName, $f.Length) }
if (Test-Path $geomPath) { Write-Host "output: $geomPath" }

# The child prints HARNESS-DONE only when every requested state rendered without error
if ((-not $timedOut) -and $stdoutText.Contains('HARNESS-DONE')) {
    Write-Host "RESULT: PASS ($($produced.Count) image(s) in $OutDir)"
    exit 0
}
Write-Host "RESULT: FAIL (timedOut=$timedOut exitCode=$exitCode)"
exit 1
