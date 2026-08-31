# tests\History.Tests.ps1
#
# Regression suite for Add-BatteryHistorySample - the recorder behind the
# sparkline, the scrub readout and the health card's session line.
#
# Everything downstream trusts this buffer to hold real percentages. It is
# the one place a "no reading" sentinel can enter the app's own data and be
# treated as a measurement, so what it REFUSES matters as much as what it
# stores.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Add-BatteryHistorySample')

Write-Host 'History.Tests.ps1'

$histT0 = [datetime]'2026-08-31T09:00:00'

function Reset-History {
    [OutputType([void])]
    param()
    $script:batteryHistory = New-Object System.Collections.ArrayList
}

function New-Sample {
    [OutputType([hashtable])]
    param([int]$Percent = 55, [bool]$IsCharging = $false, [bool]$NoBattery = $false)
    return @{ Percent = $Percent; IsCharging = $IsCharging; NoBattery = $NoBattery }
}

Test-Case 'records an ordinary reading' {
    Reset-History
    Add-BatteryHistorySample -Info (New-Sample -Percent 55) -Now $histT0
    Assert-Equal 1 $script:batteryHistory.Count
    Assert-Equal 55 $script:batteryHistory[0].Percent
    Assert-Equal $false $script:batteryHistory[0].IsCharging
    Assert-Equal $histT0 $script:batteryHistory[0].Time
}

Test-Case 'records the charging flag as given' {
    Reset-History
    Add-BatteryHistorySample -Info (New-Sample -Percent 40 -IsCharging $true) -Now $histT0
    Assert-Equal $true $script:batteryHistory[0].IsCharging
}

Test-Case 'a desktop with no battery records nothing' {
    Reset-History
    Add-BatteryHistorySample -Info (New-Sample -Percent -1 -NoBattery $true) -Now $histT0
    Assert-Equal 0 $script:batteryHistory.Count
}

Test-Case 'the NoBattery guard stands on its own, not on the percent guard' {
    # In production NoBattery always arrives with Percent -1, so the case
    # above passes on either guard alone and cannot tell them apart. A
    # plausible percent with NoBattery set isolates this one.
    Reset-History
    Add-BatteryHistorySample -Info (New-Sample -Percent 55 -NoBattery $true) -Now $histT0
    Assert-Equal 0 $script:batteryHistory.Count
}

Test-Case 'an unreadable percent on a battery that IS present is refused' {
    # The guard used to be `-not NoBattery`, but NoBattery only means the
    # battery is ABSENT. A present-but-unreadable tick (CIM query throws, or
    # .NET returns the 255 unknown sentinel) yields Percent = -1 with
    # NoBattery = $false, so -1 was stored as though it were a measurement.
    Reset-History
    Add-BatteryHistorySample -Info (New-Sample -Percent -1) -Now $histT0
    Assert-Equal 0 $script:batteryHistory.Count
}

Test-Case 'an out-of-range percent is refused' {
    Reset-History
    Add-BatteryHistorySample -Info (New-Sample -Percent 255) -Now $histT0
    Add-BatteryHistorySample -Info (New-Sample -Percent 101) -Now $histT0
    Assert-Equal 0 $script:batteryHistory.Count
}

Test-Case 'the boundaries themselves are kept' {
    Reset-History
    Add-BatteryHistorySample -Info (New-Sample -Percent 0) -Now $histT0
    Add-BatteryHistorySample -Info (New-Sample -Percent 100) -Now $histT0
    Assert-Equal 2 $script:batteryHistory.Count
}

Test-Case 'a dropout does not corrupt the run around it' {
    # The failure this prevents: one -1 tick inside a clean discharge run made
    # the health card report "used 51%" for a battery that had dropped 5.
    Reset-History
    Add-BatteryHistorySample -Info (New-Sample -Percent 50) -Now $histT0
    Add-BatteryHistorySample -Info (New-Sample -Percent -1) -Now $histT0.AddSeconds(3)
    Add-BatteryHistorySample -Info (New-Sample -Percent 49) -Now $histT0.AddSeconds(6)
    Assert-Equal 2 $script:batteryHistory.Count
    foreach ($entry in $script:batteryHistory) {
        if ($entry.Percent -lt 0) { throw 'a negative percent reached the buffer' }
    }
}

Test-Case 'the buffer is capped at 2400 and keeps the newest samples' {
    Reset-History
    for ($i = 0; $i -lt 2450; $i++) {
        Add-BatteryHistorySample -Info (New-Sample -Percent (($i % 101))) -Now $histT0.AddSeconds($i * 3)
    }
    Assert-Equal 2400 $script:batteryHistory.Count
    # The tail is what survives: the last sample written is still last.
    Assert-Equal (2449 % 101) $script:batteryHistory[$script:batteryHistory.Count - 1].Percent
    Assert-Equal $histT0.AddSeconds(2449 * 3) $script:batteryHistory[$script:batteryHistory.Count - 1].Time
}

exit (Complete-Tests)
