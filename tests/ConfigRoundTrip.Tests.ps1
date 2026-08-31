# tests\ConfigRoundTrip.Tests.ps1
#
# Save-Config -> Import-Config round trip.
#
# Adversarial.Tests.ps1 pounds Import-Config with malformed FILES; nothing
# covered the pairing of the two halves. That pairing is where settings die
# quietly: a field the writer emits but the reader rejects (or never reads)
# resets on every launch, and the user just sees their preference "not
# sticking" with no error anywhere. Every persisted field is asserted here,
# including the ones added most recently (FunLines, Animations), plus the
# forward/backward compatibility cases that a shipped app actually meets:
# a config written by an OLDER build, and one written by a NEWER build.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Import-Config', 'Save-Config', 'Read-ConfigField',
    'ConvertTo-ConfigBool', 'Read-TextFileShared', 'Write-TextFileAtomic',
    'Get-ConfigPath', 'Write-IoFailure', 'Read-DeviceNumber')

Write-Host 'ConfigRoundTrip.Tests.ps1'

# Write-IoFailure needs these; the widget sets them at module load.
$script:ioFailures = New-Object System.Collections.ArrayList
$script:ioNotifyEnabled = $false
$script:ioFailureAccent = $null

$script:tmpDir = Join-Path $env:TEMP ("batterypill-cfgtest-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:tmpDir
$script:cfgPath = Join-Path $script:tmpDir 'BatteryWidget.config.json'

function Set-WidgetState {
    # The module-scope state Save-Config serializes.
    [OutputType([void])]
    param([hashtable]$Config)
    $script:config = $Config
    $script:batteryHistory = New-Object System.Collections.ArrayList
    $script:emaRate = -1
    $script:lastValidRate = -1
    $script:lastAcState = $null
}

function New-FullConfig {
    # Every persisted field, each set to a NON-default value, so a field that
    # silently falls back to its default fails the assertion instead of
    # accidentally matching it.
    [OutputType([hashtable])]
    param()
    return @{
        X                  = 1234
        Y                  = 567
        Opacity            = 0.42
        RefreshInterval    = 5000
        PositionLocked     = $true
        DisplayMode        = 'percent'
        PillSize           = 'expanded'
        Theme              = 'light'
        AccentColorIndex   = 5
        AutoHideFullscreen = $true
        FirstRunShown      = $true
        FunLines           = $false
        Animations         = $false
        BatteryHistory     = @()
        EmaRate            = -1
        LastValidRate      = -1
        ConfigSavedAt      = $null
    }
}

Test-Case 'round trip: every persisted field survives save then load' {
    Set-WidgetState -Config (New-FullConfig)
    Save-Config -Path $script:cfgPath
    $loaded = Import-Config -Path $script:cfgPath
    foreach ($field in @('X', 'Y', 'Opacity', 'RefreshInterval', 'PositionLocked', 'DisplayMode',
            'PillSize', 'Theme', 'AccentColorIndex', 'AutoHideFullscreen', 'FirstRunShown',
            'FunLines', 'Animations')) {
        Assert-Equal $script:config.$field $loaded.$field
    }
}

Test-Case 'round trip: a false boolean stays false (not reset to its default)' {
    # The failure mode that matters: both new toggles default to TRUE, so a
    # writer/reader mismatch reads as "the off switch does not work".
    Set-WidgetState -Config (New-FullConfig)
    Save-Config -Path $script:cfgPath
    $loaded = Import-Config -Path $script:cfgPath
    Assert-Equal $false $loaded.FunLines
    Assert-Equal $false $loaded.Animations
}

Test-Case 'round trip: two consecutive saves are stable' {
    # Load-then-save must not drift a value (a lossy field would degrade a
    # little on every launch).
    Set-WidgetState -Config (New-FullConfig)
    Save-Config -Path $script:cfgPath
    $first = Import-Config -Path $script:cfgPath
    Set-WidgetState -Config $first
    Save-Config -Path $script:cfgPath
    $second = Import-Config -Path $script:cfgPath
    foreach ($field in @('X', 'Y', 'Opacity', 'RefreshInterval', 'PositionLocked', 'DisplayMode',
            'PillSize', 'Theme', 'AccentColorIndex', 'AutoHideFullscreen', 'FirstRunShown',
            'FunLines', 'Animations')) {
        Assert-Equal $first.$field $second.$field
    }
}

Test-Case 'compat: a config from an older build (no new fields) loads with defaults' {
    # Upgrading must not fail or blank out the settings that DO exist.
    $old = @{
        X               = 100
        Y               = 200
        Opacity         = 0.9
        RefreshInterval = 3000
        DisplayMode     = 'both'
        PillSize        = 'compact'
        Theme           = 'auto'
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($script:cfgPath, $old, (New-Object System.Text.UTF8Encoding $false))
    $loaded = Import-Config -Path $script:cfgPath
    Assert-Equal 100 $loaded.X
    Assert-Equal 'both' $loaded.DisplayMode
    Assert-Equal 'compact' $loaded.PillSize
    Assert-Equal 'auto' $loaded.Theme
    # Absent toggles fall back to their shipped defaults, both on.
    Assert-Equal $true $loaded.FunLines
    Assert-Equal $true $loaded.Animations
}

Test-Case 'compat: a config from a NEWER build keeps its unknown fields out of the way' {
    # Downgrading (or running an older build on a synced config) must not
    # crash and must not corrupt the fields this build does understand.
    $newer = @{
        X                 = 300
        Y                 = 400
        DisplayMode       = 'time'
        FunLines          = $false
        Animations        = $true
        SomeFutureSetting = 'quantum'
        AnotherOne        = @{ nested = $true }
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($script:cfgPath, $newer, (New-Object System.Text.UTF8Encoding $false))
    $loaded = Import-Config -Path $script:cfgPath
    Assert-Equal 300 $loaded.X
    Assert-Equal $false $loaded.FunLines
    Assert-Equal $true $loaded.Animations
}

Test-Case 'round trip: the estimator state survives, including its power state' {
    # Save-Config serializes the estimator from MODULE state, not from
    # $script:config, so New-FullConfig cannot cover it. EmaWasPluggedIn is
    # the persistence half of the fix that stops a discharge rate being
    # reused as a charge rate after a restart - if it does not round-trip,
    # Restore-EstimatorState refuses every restore and the smoothing feature
    # silently stops working.
    Set-WidgetState -Config (New-FullConfig)
    $script:emaRate = 13500.0
    $script:lastValidRate = 13000
    $script:lastAcState = $true
    Save-Config -Path $script:cfgPath
    $loaded = Import-Config -Path $script:cfgPath
    Assert-Equal 13500.0 $loaded.EmaRate
    Assert-Equal 13000 $loaded.LastValidRate
    Assert-Equal $true $loaded.EmaWasPluggedIn
}

Test-Case 'round trip: a FALSE power state survives (not lost as $null)' {
    # $false is the discharging case and the one that matters most: read back
    # as $null it would look like "unknown" and block the restore entirely.
    Set-WidgetState -Config (New-FullConfig)
    $script:emaRate = 9000.0
    $script:lastValidRate = 9000
    $script:lastAcState = $false
    Save-Config -Path $script:cfgPath
    $loaded = Import-Config -Path $script:cfgPath
    Assert-Equal $false $loaded.EmaWasPluggedIn
}

Test-Case 'round trip: battery history survives, capped at the persisted 200' {
    Set-WidgetState -Config (New-FullConfig)
    $t0 = [datetime]'2026-08-30T12:00:00'
    for ($i = 0; $i -lt 260; $i++) {
        $null = $script:batteryHistory.Add(@{
                Time       = $t0.AddSeconds($i * 3)
                Percent    = (50 + ($i % 40))
                IsCharging = ($i % 7 -eq 0)
            })
    }
    Save-Config -Path $script:cfgPath
    $loaded = Import-Config -Path $script:cfgPath
    Assert-Equal 200 @($loaded.BatteryHistory).Count
    # The tail is what is kept - the newest sample must be the last one written.
    $lastSaved = $script:batteryHistory[$script:batteryHistory.Count - 1]
    $lastLoaded = @($loaded.BatteryHistory)[-1]
    Assert-Equal $lastSaved.Percent $lastLoaded.Percent
}

# ---- cleanup ----
Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue

exit (Complete-Tests)
