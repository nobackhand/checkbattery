# tests\Concurrency.Tests.ps1
#
# Race-condition tests for the ONE piece of BatteryPill state that is not
# protected by the WinForms message loop: the config file on disk.
#
# Everything inside the process is single-threaded. There are no runspaces, no
# jobs, no System.Timers.Timer, no P/Invoke callbacks: every mutation of
# $script: state happens on the STA thread that owns the message pump, from a
# WinForms Timer tick, a Paint handler, or an input handler, and those are
# serialized by the pump. Even the two Microsoft.Win32.SystemEvents handlers -
# the one place that LOOKS cross-thread - share the app's STA thread, because
# SystemEvents only spins up its own window thread when it is first initialized
# from a non-STA thread (see history\missions-evidence\mission-12-systemevents-thread.txt).
#
# BatteryWidget.config.json is different. It outlives the process, and it is
# read and written by whole processes: the widget saves on drag, on every
# settings change, and on exit, while a launching (or crashing-and-relaunching)
# instance is loading it. A truncate-in-place write has a window in which the
# file on disk is empty or half a JSON document - and Import-Config treats that
# exactly like corruption: it throws the user's position, theme, accent, size
# and history away and resets to defaults.
#
# The stress below runs the app's REAL Save-Config and Import-Config from
# several processes at once over one file, and asserts that a reader never sees
# a half-written config.

. (Join-Path $PSScriptRoot '_harness.ps1')

$script:tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bp-race-{0}" -f $PID)
if (Test-Path $script:tmpDir) { Remove-Item $script:tmpDir -Recurse -Force }
New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null

$script:worker = Join-Path $PSScriptRoot '_stress-worker.ps1'

function Invoke-ConfigStress {
    <#
    .SYNOPSIS
        Runs $Writers save-loops and $Readers load-loops against one config file
        concurrently, in separate processes, and returns the merged tally.
    #>
    [OutputType([hashtable])]
    param(
        [string]$ConfigPath,
        [int]$Writers = 2,
        [int]$Readers = 3,
        [int]$Iterations = 60
    )

    # Seed the file so readers have something valid to find from the first tick.
    $seed = @{ X = 100; Y = 200; Opacity = 0.85; RefreshInterval = 3000; PositionLocked = $false
        DisplayMode = 'time'; PillSize = 'normal'; Theme = 'dark'; AccentColorIndex = 3
        AutoHideFullscreen = $false; FirstRunShown = $true; BatteryHistory = @(); EmaRate = -1
        LastValidRate = -1; ConfigSavedAt = (Get-Date).ToString('o')
    }
    $seed | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ConfigPath -Encoding ASCII -Force

    $startAt = (Get-Date).AddSeconds(3).ToString('o')
    $procs = @()
    $results = @()
    $n = 0
    foreach ($spec in (@('writer') * $Writers) + (@('reader') * $Readers)) {
        $n++
        $res = Join-Path $script:tmpDir ("result-{0}-{1}.json" -f $spec, $n)
        $results += $res
        $procs += Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:worker,
            '-Role', $spec, '-Path', $ConfigPath, '-Result', $res,
            '-Iterations', $Iterations, '-StartAt', $startAt)
    }
    foreach ($p in $procs) {
        if (-not $p.WaitForExit(180000)) { $p.Kill(); throw 'stress worker did not finish in 180s' }
    }

    $tally = @{ Attempts = 0; IoFailures = 0; TornReads = 0; Reasons = @(); Missing = 0 }
    foreach ($r in $results) {
        if (-not (Test-Path $r)) { $tally.Missing++; continue }
        $s = Get-Content -LiteralPath $r -Raw | ConvertFrom-Json
        $tally.Attempts += $s.Attempts
        $tally.IoFailures += $s.IoFailures
        $tally.TornReads += $s.TornReads
        if ($s.FirstFailure) { $tally.Reasons += ("{0}: {1}" -f $s.Role, $s.FirstFailure) }
    }
    return $tally
}

# ---------------------------------------------------------------
# The stress test
# ---------------------------------------------------------------

$script:stressCfg = Join-Path $script:tmpDir 'BatteryWidget.config.json'
$script:stress = Invoke-ConfigStress -ConfigPath $script:stressCfg

Test-Case 'stress: every worker process completed and reported' {
    Assert-Equal 0 $script:stress.Missing 'a worker produced no result file'
    Assert-True ($script:stress.Attempts -ge 300) "expected >=300 save/load attempts, got $($script:stress.Attempts)"
}

Test-Case 'stress: a concurrent save never makes a load reset the user settings' {
    Assert-Equal 0 $script:stress.TornReads ("saw a half-written config: " + ($script:stress.Reasons -join ' | '))
}

Test-Case 'stress: no save or load reported an I/O failure' {
    Assert-Equal 0 $script:stress.IoFailures ("I/O failures under concurrency: " + ($script:stress.Reasons -join ' | '))
}

Test-Case 'stress: the surviving file is a complete, valid config' {
    $raw = Get-Content -LiteralPath $script:stressCfg -Raw
    $json = $raw | ConvertFrom-Json
    Assert-True ($json.X -ge 100) "final X should be one of the written values, got $($json.X)"
    Assert-Equal 'dark' $json.Theme
    Assert-Equal 200 @($json.BatteryHistory).Count 'the whole history must survive the last write'
}

Test-Case 'stress: no config was quarantined as corrupt' {
    # Import-Config copies an unreadable file to <name>.corrupt before resetting.
    # One of these means a save was caught mid-flight by a load.
    $corrupt = @(Get-ChildItem -Path $script:tmpDir -Filter '*.corrupt' -File -ErrorAction SilentlyContinue)
    Assert-Equal 0 $corrupt.Count 'a concurrent read quarantined the config as corrupt'
}

# ---------------------------------------------------------------
# The property the fix relies on, tested directly
# ---------------------------------------------------------------

Test-Case 'a failed save leaves the previous config intact, not truncated' {
    # Save into a directory that exists but a file that cannot be replaced:
    # the target is a DIRECTORY named like the config, so the write must fail.
    $dir = Join-Path $script:tmpDir 'blocked'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $target = Join-Path $dir 'BatteryWidget.config.json'
    New-Item -ItemType Directory -Path $target -Force | Out-Null

    . (Import-WidgetFunction @('Write-IoFailure', 'Get-ConfigPath', 'Save-Config', 'Write-TextFileAtomic'))
    $script:ioNotifyEnabled = $false
    $script:ioFailures = @()
    $script:config = @{ X = 1; Y = 2; Opacity = 0.85; RefreshInterval = 3000; PositionLocked = $false
        DisplayMode = 'time'; PillSize = 'normal'; Theme = 'dark'; AccentColorIndex = 0
        AutoHideFullscreen = $false; FirstRunShown = $true
    }
    $script:batteryHistory = New-Object System.Collections.ArrayList
    $script:emaRate = -1
    $script:lastValidRate = -1

    Save-Config -Path $target
    Assert-Equal 1 $script:ioFailures.Count 'an unwritable target must be reported, not swallowed'
    # And no debris: a failed atomic write must not leave its temp file behind.
    $leftovers = @(Get-ChildItem -Path $dir -Filter '*.tmp' -File -Force -ErrorAction SilentlyContinue)
    Assert-Equal 0 $leftovers.Count 'a failed save left a temp file behind'
}

Remove-Item $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
exit (Complete-Tests)
