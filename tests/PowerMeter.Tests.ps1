# tests\PowerMeter.Tests.ps1
#
# Read-PowerMeterMilliwatts - the UI-thread half of the platform power meter.
#
# The probe for the "Power Meter" counter set is C# (PowerMeterProbe in
# 010-init) running on a pool thread, because a process's first perf-category
# query reads every perf provider on the machine: measured at 22.7s on a busy
# desktop. Made on the UI thread at startup, as v1.4.0 did, it froze the app -
# no pill, a dead tray icon - for that long. A stub of the probe type stands in
# here, so the polling logic is tested without touching this machine's perf
# counters, and so a probe that has NOT answered yet can be simulated: that is
# the case that froze startup.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Read-PowerMeterMilliwatts')

Add-Type @"
public static class PowerMeterProbe {
    public static int NextState = 0;
    public static double NextRead = -1;
    public static bool ReadThrows = false;
    public static int StateCalls = 0;
    public static int Closes = 0;
    public static int State() { StateCalls++; return NextState; }
    public static double Read() {
        if (ReadThrows) throw new System.InvalidOperationException("counter gone");
        return NextRead;
    }
    public static void Close() { Closes++; }
}
"@

Write-Host 'PowerMeter.Tests.ps1'

function Reset-Probe {
    [OutputType([void])]
    param([int]$State = 0, [double]$Read = -1, [bool]$Throws = $false)
    [PowerMeterProbe]::NextState = $State
    [PowerMeterProbe]::NextRead = $Read
    [PowerMeterProbe]::ReadThrows = $Throws
    [PowerMeterProbe]::StateCalls = 0
    [PowerMeterProbe]::Closes = 0
    $script:powerMeterState = 'untried'
}

Test-Case 'meter: while the probe is still running there is no reading, and nothing is decided' {
    # The startup case. The first read must come straight back with "no
    # reading" - not wait for the probe, and not write the meter off.
    Reset-Probe -State 0
    Assert-Equal (-1) (Read-PowerMeterMilliwatts)
    Assert-Equal 'untried' $script:powerMeterState
}

Test-Case 'meter: a probe that finishes later is picked up on a later tick' {
    Reset-Probe -State 0
    Assert-Equal (-1) (Read-PowerMeterMilliwatts)
    [PowerMeterProbe]::NextState = 1
    [PowerMeterProbe]::NextRead = 23500
    Assert-Equal 23500 (Read-PowerMeterMilliwatts)
    Assert-Equal 'ok' $script:powerMeterState
}

Test-Case 'meter: a probe that found no meter is remembered - never asked again' {
    Reset-Probe -State -1
    Assert-Equal (-1) (Read-PowerMeterMilliwatts)
    Assert-Equal 'unavailable' $script:powerMeterState
    Assert-Equal (-1) (Read-PowerMeterMilliwatts)
    Assert-Equal 1 ([PowerMeterProbe]::StateCalls)
}

Test-Case 'meter: zero means no reading (meters that are present but report 0)' {
    # Verified on a ZBook Ultra G1A: instances present, CookedValue 0.
    Reset-Probe -State 1 -Read 0
    Assert-Equal (-1) (Read-PowerMeterMilliwatts)
    Assert-Equal 'ok' $script:powerMeterState
}

Test-Case 'meter: a counter that fails mid-session is dropped for good' {
    Reset-Probe -State 1 -Throws $true
    Assert-Equal (-1) (Read-PowerMeterMilliwatts)
    Assert-Equal 'unavailable' $script:powerMeterState
    Assert-Equal 1 ([PowerMeterProbe]::Closes)
}

exit (Complete-Tests)
