# tests\PowerDraw.Tests.ps1
#
# Regression suite for the system power-draw feature (v1.4.0):
#
#     Get-PowerDraw          the source ladder: platform meter > pack rate; the
#                            draw/charge distinction; glitch caps
#     Get-PowerText          "14 W" / "14.2 W" / "+45 W" / ""
#     Get-PowerDrawWord      sipping .. full send
#     Get-PowerSentence      the popup's power line
#     Get-PillText "power"   the pill's fourth display mode and its fallbacks
#     Get-PowerDrawStats     avg/peak over the current discharge run
#     Add-BatteryHistorySample  records Watts (and refuses to record a charge rate as draw)
#     Get-BatteryInfo        end to end through the WMI / meter seams
#
# The one number this feature adds is easy to get subtly wrong: a charge rate
# shown as consumption, a hashtable key named Count, a meter that reports 0.
# These pin the decisions.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Get-PowerDraw', 'Get-PowerText', 'Get-PowerDrawWord', 'Get-PowerSentence',
    'Get-PillText', 'Get-PowerDrawStats', 'Add-BatteryHistorySample', 'Format-Duration',
    'Read-DeviceNumber', 'Get-BatteryInfo', 'Update-EMARate', 'Get-CapacityDerivedRate', 'Get-SmoothedTimeRemaining')

Write-Host 'PowerDraw.Tests.ps1'

$pdT0 = [datetime]'2026-09-04T10:00:00'
$emDash = [string][char]0x2014

function New-DrawReading {
    [OutputType([hashtable])]
    param(
        [double]$Watts = 8.2,
        [string]$Kind = 'draw',
        [string]$Source = 'battery',
        [int]$Percent = 72,
        [bool]$IsPluggedIn = $false,
        [bool]$NoBattery = $false,
        [bool]$IsCharging = $false,
        [bool]$IsFullyCharged = $false,
        [int]$TimeMinutes = 188
    )
    return @{
        Percent         = $Percent
        PercentExact    = [double]$Percent
        IsCharging      = $IsCharging
        IsPluggedIn     = $IsPluggedIn
        IsFullyCharged  = $IsFullyCharged
        NoBattery       = $NoBattery
        StatusText      = 'Discharging'
        TimeMinutes     = $TimeMinutes
        ETA             = ''
        PowerDrawWatts  = $Watts
        PowerDrawKind   = $Kind
        PowerDrawSource = $Source
    }
}

# ---- Get-PowerDraw: the source ladder ----

Test-Case 'draw: on battery the discharge rate is the system draw' {
    $d = Get-PowerDraw -DischargeRate 8241 -IsCharging $false
    Assert-Equal 8.2 $d.Watts
    Assert-Equal 'draw' $d.Kind
    Assert-Equal 'battery' $d.Source
}

Test-Case 'draw: the platform meter outranks the pack rate' {
    $d = Get-PowerDraw -MeterMilliwatts 14200 -DischargeRate 8241
    Assert-Equal 14.2 $d.Watts
    Assert-Equal 'meter' $d.Source
}

Test-Case 'draw: a meter reading of 0 is "no reading", not 0 W' {
    $d = Get-PowerDraw -MeterMilliwatts 0 -DischargeRate 8241
    Assert-Equal 8.2 $d.Watts
    Assert-Equal 'battery' $d.Source
}

Test-Case 'draw: while charging the charge rate is reported as CHARGE, never as draw' {
    $d = Get-PowerDraw -ChargeRate 24680 -IsCharging $true
    Assert-Equal 24.7 $d.Watts
    Assert-Equal 'charge' $d.Kind
}

Test-Case 'draw: charging with no charge rate is no reading' {
    $d = Get-PowerDraw -ChargeRate -1 -DischargeRate 8241 -IsCharging $true
    Assert-Equal (-1.0) $d.Watts
    Assert-Equal '' $d.Kind
}

Test-Case 'draw: fully charged is no reading even if the firmware still reports a rate' {
    $d = Get-PowerDraw -DischargeRate 500 -IsFullyCharged $true
    Assert-Equal '' $d.Kind
}

Test-Case 'draw: no battery and no meter is no reading' {
    $d = Get-PowerDraw -NoBattery $true
    Assert-Equal '' $d.Kind
}

Test-Case 'draw: a desktop with a platform meter still reports' {
    $d = Get-PowerDraw -NoBattery $true -MeterMilliwatts 65000
    Assert-Equal 65.0 $d.Watts
    Assert-Equal 'meter' $d.Source
}

Test-Case 'draw: a 400 W "discharge" is a firmware glitch, dropped' {
    $d = Get-PowerDraw -DischargeRate 400000
    Assert-Equal '' $d.Kind
}

Test-Case 'draw: plugged in and holding (no rates) is no reading' {
    $d = Get-PowerDraw -DischargeRate -1 -ChargeRate -1 -IsCharging $false
    Assert-Equal '' $d.Kind
}

# ---- Get-PowerText ----

Test-Case 'text: one decimal by default' {
    Assert-Equal '8.2 W' (Get-PowerText -Watts 8.2 -Kind 'draw')
}

Test-Case 'text: zero decimals rounds half away from zero (the pill)' {
    Assert-Equal '15 W' (Get-PowerText -Watts 14.5 -Kind 'draw' -Decimals 0)
    Assert-Equal '8 W' (Get-PowerText -Watts 8.2 -Kind 'draw' -Decimals 0)
}

Test-Case 'text: charge carries a plus sign' {
    Assert-Equal '+24.7 W' (Get-PowerText -Watts 24.7 -Kind 'charge')
}

Test-Case 'text: no reading is empty, so callers pick their own fallback' {
    Assert-Equal '' (Get-PowerText -Watts -1 -Kind 'draw')
    Assert-Equal '' (Get-PowerText -Watts 8.2 -Kind '')
}

# ---- Get-PowerDrawWord ----

Test-Case 'word: the bands' {
    Assert-Equal 'sipping' (Get-PowerDrawWord -Watts 3)
    Assert-Equal 'cruising' (Get-PowerDrawWord -Watts 8.2)
    Assert-Equal 'working' (Get-PowerDrawWord -Watts 20)
    Assert-Equal 'pushing it' (Get-PowerDrawWord -Watts 30)
    Assert-Equal 'full send' (Get-PowerDrawWord -Watts 60)
    Assert-Equal '' (Get-PowerDrawWord -Watts 0)
}

# ---- Get-PowerSentence ----

Test-Case 'sentence: from the pack' {
    Assert-Equal 'Drawing 8.2 W' (Get-PowerSentence -BatteryInfo (New-DrawReading))
}

Test-Case 'sentence: from the platform meter' {
    Assert-Equal 'Using 14.2 W' (Get-PowerSentence -BatteryInfo (New-DrawReading -Watts 14.2 -Source 'meter'))
}

Test-Case 'sentence: charging says so, without the plus' {
    Assert-Equal 'Charging at 24.7 W' (Get-PowerSentence -BatteryInfo (New-DrawReading -Watts 24.7 -Kind 'charge' -IsCharging $true))
}

Test-Case 'sentence: fun mode appends the word; charging gets none' {
    Assert-Equal "Drawing 8.2 W $emDash cruising" (Get-PowerSentence -BatteryInfo (New-DrawReading) -Fun $true)
    Assert-Equal 'Charging at 24.7 W' (Get-PowerSentence -BatteryInfo (New-DrawReading -Watts 24.7 -Kind 'charge') -Fun $true)
}

Test-Case 'sentence: no reading is no line' {
    Assert-Equal '' (Get-PowerSentence -BatteryInfo (New-DrawReading -Watts -1 -Kind '' -Source ''))
}

# ---- Get-PillText "power" ----

Test-Case 'pill power: whole watts on battery' {
    $t = Get-PillText -BatteryInfo (New-DrawReading) -DisplayMode 'power'
    Assert-Equal '8 W' $t.Primary
    Assert-Equal '' $t.Secondary
}

Test-Case 'pill power: charging shows the inflow with a plus' {
    $t = Get-PillText -BatteryInfo (New-DrawReading -Watts 24.7 -Kind 'charge' -IsCharging $true -IsPluggedIn $true) -DisplayMode 'power'
    Assert-Equal '+25 W' $t.Primary
}

Test-Case 'pill power: plugged in with nothing to measure reads AC' {
    $t = Get-PillText -BatteryInfo (New-DrawReading -Watts -1 -Kind '' -Source '' -IsPluggedIn $true) -DisplayMode 'power'
    Assert-Equal 'AC' $t.Primary
}

Test-Case 'pill power: no battery reads AC' {
    $t = Get-PillText -BatteryInfo (New-DrawReading -Watts -1 -Kind '' -Source '' -NoBattery $true -Percent -1) -DisplayMode 'power'
    Assert-Equal 'AC' $t.Primary
}

Test-Case 'pill power: on battery before the first reading falls back to the percent' {
    $t = Get-PillText -BatteryInfo (New-DrawReading -Watts -1 -Kind '' -Source '') -DisplayMode 'power'
    Assert-Equal '72%' $t.Primary
}

Test-Case 'pill power: unknown percent on battery shows dashes, never -1%' {
    $t = Get-PillText -BatteryInfo (New-DrawReading -Watts -1 -Kind '' -Source '' -Percent -1) -DisplayMode 'power'
    Assert-Equal '--' $t.Primary
}

Test-Case 'pill: the other modes are untouched by the new fields' {
    Assert-Equal '3h 8m' (Get-PillText -BatteryInfo (New-DrawReading) -DisplayMode 'time').Primary
    Assert-Equal '72%' (Get-PillText -BatteryInfo (New-DrawReading) -DisplayMode 'percent').Primary
}

# ---- Get-PowerDrawStats ----

function New-History {
    [OutputType([System.Collections.ArrayList])]
    param([hashtable[]]$Samples)
    $h = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($s in $Samples) {
        $entry = @{ Time = $pdT0.AddSeconds(3 * $i); Percent = 70 - $i; IsCharging = $false }
        foreach ($k in $s.Keys) { $entry[$k] = $s[$k] }
        $null = $h.Add($entry)
        $i++
    }
    return $h
}

Test-Case 'stats: avg and peak over the run' {
    $h = New-History @(@{ Watts = 10.0 }, @{ Watts = 20.0 }, @{ Watts = 12.0 }, @{ Watts = 14.0 })
    $s = Get-PowerDrawStats -History $h
    Assert-Equal 4 $s.Samples
    Assert-Equal 14.0 $s.Avg
    Assert-Equal 20.0 $s.Peak
}

Test-Case 'stats: too few readings is "nothing to say yet"' {
    $h = New-History @(@{ Watts = 10.0 }, @{ Watts = 20.0 })
    Assert-Equal 0 (Get-PowerDrawStats -History $h).Samples
}

Test-Case 'stats: the Samples key is a real count, not the hashtable size' {
    # A key named Count would be shadowed by the hashtable's own .Count (3)
    $s = Get-PowerDrawStats -History $null
    Assert-Equal 0 $s.Samples
    Assert-Equal 3 $s.Count
}

Test-Case 'stats: samples without a reading are skipped, not averaged as zero' {
    $h = New-History @(@{ Watts = -1.0 }, @{ }, @{ Watts = 10.0 }, @{ Watts = 20.0 }, @{ Watts = 30.0 })
    $s = Get-PowerDrawStats -History $h
    Assert-Equal 3 $s.Samples
    Assert-Equal 20.0 $s.Avg
}

Test-Case 'stats: a charging sample ends the run' {
    $h = New-History @(@{ Watts = 90.0 }, @{ Watts = -1.0; IsCharging = $true }, @{ Watts = 10.0 }, @{ Watts = 10.0 }, @{ Watts = 10.0 })
    $s = Get-PowerDrawStats -History $h
    Assert-Equal 3 $s.Samples
    Assert-Equal 10.0 $s.Peak
}

Test-Case 'stats: a time gap (sleep / restored history) ends the run' {
    $h = New-History @(@{ Watts = 90.0 }, @{ Watts = 10.0 }, @{ Watts = 10.0 }, @{ Watts = 10.0 })
    $h[0].Time = $pdT0.AddHours(-9)   # last night's sample
    $s = Get-PowerDrawStats -History $h
    Assert-Equal 3 $s.Samples
    Assert-Equal 10.0 $s.Peak
}

Test-Case 'stats: a plugged-in stretch (full, or parked at a charge cap) ends the run' {
    # Battery run peaks at 90 W, cable goes in at 100% (IsCharging false -
    # nothing flows, so no charge sample ever lands), cable comes out an
    # hour later: the new run must not inherit last run's peak.
    $h = New-History @(@{ Watts = 90.0 }, @{ Watts = 90.0 },
        @{ Watts = -1.0; IsPluggedIn = $true }, @{ Watts = -1.0; IsPluggedIn = $true }, @{ Watts = -1.0; IsPluggedIn = $true },
        @{ Watts = 10.0 }, @{ Watts = 10.0 }, @{ Watts = 10.0 })
    $s = Get-PowerDrawStats -History $h
    Assert-Equal 3 $s.Samples
    Assert-Equal 10.0 $s.Peak
}

Test-Case 'stats: on AC with a platform meter, the run is the AC stretch only' {
    $h = New-History @(@{ Watts = 90.0 }, @{ Watts = 90.0 }, @{ Watts = 90.0 },
        @{ Watts = 12.0; IsPluggedIn = $true }, @{ Watts = 14.0; IsPluggedIn = $true }, @{ Watts = 16.0; IsPluggedIn = $true })
    $s = Get-PowerDrawStats -History $h
    Assert-Equal 3 $s.Samples
    Assert-Equal 14.0 $s.Avg
    Assert-Equal 16.0 $s.Peak
}

Test-Case 'stats: samples from before the plugged flag existed count as on-battery' {
    $h = New-History @(@{ Watts = 10.0 }, @{ Watts = 20.0 }, @{ Watts = 30.0 })
    foreach ($s in $h) { $s.Remove('IsPluggedIn') }
    Assert-Equal 3 (Get-PowerDrawStats -History $h).Samples
}

Test-Case 'stats: while charging there is no draw session' {
    $h = New-History @(@{ Watts = 10.0 }, @{ Watts = 10.0 }, @{ Watts = 10.0 }, @{ Watts = -1.0; IsCharging = $true })
    Assert-Equal 0 (Get-PowerDrawStats -History $h).Samples
}

# ---- Add-BatteryHistorySample ----

Test-Case 'history: a draw reading is recorded as Watts' {
    $script:batteryHistory = New-Object System.Collections.ArrayList
    Add-BatteryHistorySample -Info (New-DrawReading -Watts 8.2) -Now $pdT0
    Assert-Equal 8.2 $script:batteryHistory[0].Watts
}

Test-Case 'history: a charge rate is NOT recorded as draw' {
    $script:batteryHistory = New-Object System.Collections.ArrayList
    Add-BatteryHistorySample -Info (New-DrawReading -Watts 24.7 -Kind 'charge' -IsCharging $true) -Now $pdT0
    Assert-Equal (-1.0) $script:batteryHistory[0].Watts
}

Test-Case 'history: the plugged-in state is recorded, so a full-and-parked stretch can end a run' {
    $script:batteryHistory = New-Object System.Collections.ArrayList
    Add-BatteryHistorySample -Info (New-DrawReading -Watts -1 -Kind '' -Source '' -IsPluggedIn $true -IsFullyCharged $true) -Now $pdT0
    Add-BatteryHistorySample -Info (New-DrawReading -Watts 8.2) -Now $pdT0.AddSeconds(3)
    Assert-Equal $true $script:batteryHistory[0].IsPluggedIn
    Assert-Equal $false $script:batteryHistory[1].IsPluggedIn
}

Test-Case 'history: no reading records -1' {
    $script:batteryHistory = New-Object System.Collections.ArrayList
    Add-BatteryHistorySample -Info (New-DrawReading -Watts -1 -Kind '' -Source '') -Now $pdT0
    Assert-Equal (-1.0) $script:batteryHistory[0].Watts
}

# ---- Get-BatteryInfo end to end (through the seams; never the real meter) ----

function Reset-Estimator {
    [OutputType([void])]
    param()
    $script:emaRate = -1
    $script:lastValidRate = -1
    $script:lastValidRateTime = $null
    $script:rateHistory = New-Object System.Collections.ArrayList
    $script:lastCapacityCheck = $null
    $script:capacityRateMismatchCount = 0
    $script:lastAcState = $null
    $script:stateChangeTime = $null
    $script:hysteresisSeconds = 2
    $script:lastStateChange = @{ Time = $pdT0; Percent = -1; State = "" }
    # If Get-BatteryInfo ever reached the real meter under a bound seam, this
    # would be the tell: the function is not lifted here and would throw.
    $script:powerMeterState = 'untried'
    $script:powerMeterCounter = $null
}

function New-WmiStub {
    [OutputType([pscustomobject])]
    param([int]$Status = 1, [AllowNull()][Nullable[int]]$Discharge = $null, [AllowNull()][Nullable[int]]$Charge = $null)
    return [pscustomobject]@{
        EstimatedChargeRemaining = 72
        BatteryStatus            = $Status
        DischargeRate            = $Discharge
        ChargeRate               = $Charge
        DesignCapacity           = 59970
        FullChargeCapacity       = 56270
        EstimatedRunTime         = 188
        TimeToFullCharge         = $null
    }
}

function New-PowerStub {
    [OutputType([pscustomobject])]
    param([string]$Line = 'Offline', [int]$ChargeStatus = 0)
    return [pscustomobject]@{
        BatteryChargeStatus  = $ChargeStatus
        BatteryLifePercent   = 0.72
        PowerLineStatus      = $Line
        BatteryLifeRemaining = -1
    }
}

Test-Case 'info: discharging laptop reports the pack draw' {
    Reset-Estimator
    $i = Get-BatteryInfo -Now $pdT0 -WmiBattery (New-WmiStub -Status 1 -Discharge 8241) -PowerStatus (New-PowerStub)
    Assert-Equal 8.2 $i.PowerDrawWatts
    Assert-Equal 'draw' $i.PowerDrawKind
    Assert-Equal 'battery' $i.PowerDrawSource
}

Test-Case 'info: charging laptop reports the inflow as charge' {
    Reset-Estimator
    $i = Get-BatteryInfo -Now $pdT0 -WmiBattery (New-WmiStub -Status 2 -Charge 24680) -PowerStatus (New-PowerStub -Line 'Online' -ChargeStatus 8)
    Assert-Equal 24.7 $i.PowerDrawWatts
    Assert-Equal 'charge' $i.PowerDrawKind
}

Test-Case 'info: the meter seam outranks the pack' {
    Reset-Estimator
    $i = Get-BatteryInfo -Now $pdT0 -WmiBattery (New-WmiStub -Status 1 -Discharge 8241) -PowerStatus (New-PowerStub) -MeterMilliwatts 14200
    Assert-Equal 14.2 $i.PowerDrawWatts
    Assert-Equal 'meter' $i.PowerDrawSource
}

Test-Case 'info: plugged in and holding at a charge cap has no number (the ZBook case)' {
    Reset-Estimator
    $i = Get-BatteryInfo -Now $pdT0 -WmiBattery (New-WmiStub -Status 11) -PowerStatus (New-PowerStub -Line 'Online')
    Assert-Equal (-1.0) $i.PowerDrawWatts
    Assert-Equal '' $i.PowerDrawKind
}

Test-Case 'info: a desktop with a platform meter reports it on the no-battery path' {
    Reset-Estimator
    $i = Get-BatteryInfo -Now $pdT0 -WmiBattery $null -PowerStatus (New-PowerStub -Line 'Online' -ChargeStatus 128) -MeterMilliwatts 65000
    Assert-Equal $true $i.NoBattery
    Assert-Equal 65.0 $i.PowerDrawWatts
    Assert-Equal 'meter' $i.PowerDrawSource
}

Test-Case 'info: a desktop without a meter stays silent' {
    Reset-Estimator
    $i = Get-BatteryInfo -Now $pdT0 -WmiBattery $null -PowerStatus (New-PowerStub -Line 'Online' -ChargeStatus 128)
    Assert-Equal '' $i.PowerDrawKind
}

exit (Complete-Tests)
