# tests\_stress-worker.ps1
#
# One worker process for the Concurrency stress test. Concurrency.Tests.ps1
# starts several of these against a SINGLE config file and then checks what
# each one saw.
#
#   -Role writer   loops Save-Config over $Path (the app's real save path)
#   -Role reader   loops Import-Config over $Path (the app's real load path)
#
# Both roles run the shipped functions, lifted out of the widget source by the
# harness - no reimplementation - so whatever the app does under concurrent
# access is exactly what this measures. Results go to -Result as JSON.

param(
    [Parameter(Mandatory = $true)][ValidateSet('writer', 'reader')][string]$Role,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Result,
    [int]$Iterations = 150,
    [int]$SleepMs = 5,
    # Wall-clock start barrier (round-trip "o" string) so every worker begins
    # hammering at the same instant instead of stepping through in launch order.
    [string]$StartAt = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_harness.ps1')

# The optional import keeps ONE worker able to run against both the pre-fix and
# post-fix source: the atomic-write helper does not exist in the old file, and
# Import-WidgetFunction throws on a name it cannot find.
. (Import-WidgetFunction @('Write-IoFailure', 'Get-ConfigPath', 'Read-ConfigField', 'Import-Config', 'Save-Config'))
foreach ($optional in @('Write-TextFileAtomic', 'Read-TextFileShared')) {
    try { . (Import-WidgetFunction $optional) } catch { }
}

# No forms in a test host: failures are recorded in $script:ioFailures only.
$script:ioNotifyEnabled = $false
$script:ioFailures = @()

if ($StartAt) {
    $target = [datetime]::Parse($StartAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    while ((Get-Date) -lt $target) { Start-Sleep -Milliseconds 2 }
}

$summary = [ordered]@{
    Role         = $Role
    Attempts     = 0
    IoFailures   = 0
    TornReads    = 0
    FirstFailure = ''
}

if ($Role -eq 'writer') {
    $script:config = @{
        X                  = 100
        Y                  = 200
        Opacity            = 0.85
        RefreshInterval    = 3000
        PositionLocked     = $false
        DisplayMode        = 'time'
        PillSize           = 'normal'
        Theme              = 'dark'
        AccentColorIndex   = 3
        AutoHideFullscreen = $false
        FirstRunShown      = $true
    }
    # A realistic file, not a stub: the app persists up to 200 history entries,
    # which is what makes the write big enough to be caught half-done.
    $script:batteryHistory = New-Object System.Collections.ArrayList
    $now = Get-Date
    for ($h = 0; $h -lt 200; $h++) {
        [void]$script:batteryHistory.Add(@{ Time = $now.AddMinutes( - $h); Percent = 50; IsCharging = $false })
    }
    $script:emaRate = 12345.0
    $script:lastValidRate = 12345

    for ($i = 1; $i -le $Iterations; $i++) {
        $script:config.X = 100 + ($i % 50)
        Save-Config -Path $Path
        $summary.Attempts++
        if ($SleepMs -gt 0) { Start-Sleep -Milliseconds $SleepMs }
    }
} else {
    for ($i = 1; $i -le $Iterations; $i++) {
        $script:ioFailures = @()
        $loaded = Import-Config -Path $Path
        $summary.Attempts++
        # X is only ever saved as 100..149. -1 is the built-in default, i.e. the
        # load gave up and the user's settings just reset themselves.
        if ($loaded.X -lt 100 -or $loaded.Theme -ne 'dark' -or $loaded.AccentColorIndex -ne 3) {
            $summary.TornReads++
            if (-not $summary.FirstFailure) {
                $summary.FirstFailure = "reset to defaults (X=$($loaded.X), Theme=$($loaded.Theme))"
            }
        }
        if ($script:ioFailures.Count -gt 0) {
            $summary.IoFailures += $script:ioFailures.Count
            if (-not $summary.FirstFailure) { $summary.FirstFailure = $script:ioFailures[0].Detail }
        }
        if ($SleepMs -gt 0) { Start-Sleep -Milliseconds $SleepMs }
    }
}

if ($Role -eq 'writer') {
    $summary.IoFailures = $script:ioFailures.Count
    if ($script:ioFailures.Count -gt 0) { $summary.FirstFailure = $script:ioFailures[0].Detail }
}

$summary | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Result -Encoding ASCII -Force
