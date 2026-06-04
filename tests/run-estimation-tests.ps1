#requires -Version 5.1
<#
.SYNOPSIS
    Dependency-free unit-test runner for BatteryEstimation.ps1.
.DESCRIPTION
    No Pester, no modules. Dot-sources ../BatteryEstimation.ps1 (resolved
    relative to $PSScriptRoot), runs plain assertions over the pure
    estimation math, prints [PASS]/[FAIL] <name> per case, and exits 1 if
    any case fails (0 otherwise). Runs identically locally and in CI.

    The Pester twin tests/Estimation.Tests.ps1 covers the SAME cases.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Locate and load the system under test -------------------------------
$estimationPath = Join-Path (Join-Path $PSScriptRoot '..') 'BatteryEstimation.ps1'
$estimationPath = (Resolve-Path -LiteralPath $estimationPath).Path
. $estimationPath

# --- Tiny assertion harness ----------------------------------------------
$script:failures = 0
$script:passes = 0

function Reset-EstimationState {
    # Re-initialize the module-level $script: state so every case is
    # independent (mirrors the initializers at the top of BatteryEstimation.ps1).
    $script:emaRate = -1
    $script:lastValidRate = -1
    $script:lastValidRateTime = $null
    $script:rateHistory = New-Object System.Collections.ArrayList
    $script:lastCapacityCheck = $null
    $script:capacityRateMismatchCount = 0
    $script:lastAcState = $null
    $script:stateChangeTime = $null
    $script:hysteresisSeconds = 2
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        Reset-EstimationState
        & $Body
        Write-Host "[PASS] $Name"
        $script:passes++
    } catch {
        Write-Host "[FAIL] $Name -- $($_.Exception.Message)"
        $script:failures++
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message = 'expected condition to be true')
    if (-not $Condition) { throw $Message }
}

function Assert-Near {
    param([double]$Actual, [double]$Expected, [double]$Tolerance, [string]$Label = 'value')
    $delta = [math]::Abs($Actual - $Expected)
    if ($delta -gt $Tolerance) {
        throw "$Label expected ~$Expected (+/-$Tolerance) but got $Actual (delta $delta)"
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label = 'value')
    if ($Actual -ne $Expected) {
        throw "$Label expected '$Expected' but got '$Actual'"
    }
}

# ========================================================================
# Get-SmoothedTimeRemaining
# ========================================================================

Test-Case 'Get-SmoothedTimeRemaining: discharging 10W / 50Wh / 60% ~= 180 min' {
    # 10 W = 10000 mW draw, 50 Wh = 50000 mWh full, 60% charge.
    # remaining = 50000 * 0.60 = 30000 mWh; time = 30000/10000 h * 60 = 180 min.
    $result = Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 50000 `
        -PercentExact 60.0 -IsCharging $false -IsPluggedIn $false
    Assert-Near -Actual $result -Expected 180 -Tolerance 5 -Label 'discharge minutes'
}

Test-Case 'Get-SmoothedTimeRemaining: charging 20W / 50Wh / 30% ~= 105 min to full' {
    # 20 W = 20000 mW charge, 50 Wh = 50000 mWh full, 30% charge.
    # remaining-to-full = 50000 * 0.70 = 35000 mWh; time = 35000/20000 h * 60 = 105 min.
    $result = Get-SmoothedTimeRemaining -RawRate 20000 -FullChargeCapacity 50000 `
        -PercentExact 30.0 -IsCharging $true -IsPluggedIn $true
    Assert-Near -Actual $result -Expected 105 -Tolerance 5 -Label 'charge minutes'
}

Test-Case 'Get-SmoothedTimeRemaining: tiny-rate underflow is clamped to <= 6000 min (100h cap)' {
    # RawRate = 1 mW against a large capacity would yield ~1.8M minutes;
    # the 6000-minute (100h) cap must clamp it.
    $result = Get-SmoothedTimeRemaining -RawRate 1 -FullChargeCapacity 50000 `
        -PercentExact 60.0 -IsCharging $false -IsPluggedIn $false
    Assert-True ($result -le 6000) "result should be clamped to <= 6000 but was $result"
    Assert-Equal $result 6000 'clamped minutes'
}

Test-Case 'Get-SmoothedTimeRemaining: zero rate with no prior valid rate returns sentinel -1' {
    # RawRate = 0 is invalid and there is no lastValidRate -> documented sentinel -1.
    $result = Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
        -PercentExact 60.0 -IsCharging $false -IsPluggedIn $false
    Assert-Equal $result -1 'unknown-rate sentinel'
}

Test-Case 'Get-SmoothedTimeRemaining: first-call / unavailable rate does not throw or return garbage' {
    # Fresh state + unusable rate -> sentinel -1, never an enormous number.
    $result = Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 0 `
        -PercentExact 0.0 -IsCharging $false -IsPluggedIn $false
    Assert-Equal $result -1 'first-call sentinel'
    Assert-True ($result -le 6000) "sentinel path must never exceed cap, got $result"
}

# ========================================================================
# Update-EMARate
# ========================================================================

Test-Case 'Update-EMARate: constant input converges to that rate' {
    $last = -1
    for ($i = 0; $i -lt 20; $i++) { $last = Update-EMARate -RawRate 10000 }
    Assert-Near -Actual $last -Expected 10000 -Tolerance 1 -Label 'converged EMA'
}

Test-Case 'Update-EMARate: step change is smoothed, not a hard snap, and lies between old and new' {
    # Settle at 10000, then feed a single 20000 sample.
    $old = -1
    for ($i = 0; $i -lt 20; $i++) { $old = Update-EMARate -RawRate 10000 }
    $new = Update-EMARate -RawRate 20000
    # Smoothed: must move UP toward 20000 but not reach it (no hard snap).
    Assert-True ($new -gt $old) "EMA should rise above old $old, got $new"
    Assert-True ($new -lt 20000) "EMA should not snap to 20000, got $new"
    Assert-True ($new -gt $old -and $new -lt 20000) "EMA $new must be strictly between old $old and new raw 20000"
}

Test-Case 'Update-EMARate: first reading initializes directly to the raw rate' {
    $first = Update-EMARate -RawRate 12345
    Assert-Equal $first 12345 'first EMA reading'
}

# ========================================================================
# Get-CapacityDerivedRate
# ========================================================================

Test-Case 'Get-CapacityDerivedRate: first call seeds baseline and returns -1 (insufficient data)' {
    $t0 = Get-Date '2026-01-01T00:00:00'
    $r = Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 60.0 -Now $t0
    Assert-Equal $r -1 'baseline-seed return'
}

Test-Case 'Get-CapacityDerivedRate: representative drop over time returns a sane positive rate' {
    # Seed at 60% then sample again 1 hour later at 40%.
    # 60% of 50000 = 30000 mWh; 40% = 20000 mWh; consumed 10000 mWh over 1h => ~10000 mW.
    $t0 = Get-Date '2026-01-01T00:00:00'
    $t1 = $t0.AddHours(1)
    $null = Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 60.0 -Now $t0
    $rate = Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 40.0 -Now $t1
    Assert-True ($rate -gt 0) "expected positive derived rate, got $rate"
    Assert-Near -Actual $rate -Expected 10000 -Tolerance 50 -Label 'capacity-derived rate (mW)'
}

Test-Case 'Get-CapacityDerivedRate: too-soon resample (< 30s) returns -1 (unavailable)' {
    $t0 = Get-Date '2026-01-01T00:00:00'
    $t1 = $t0.AddSeconds(10)  # under the 30s minimum window
    $null = Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 60.0 -Now $t0
    $rate = Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 59.0 -Now $t1
    Assert-Equal $rate -1 'too-soon resample'
}

# --- Summary --------------------------------------------------------------
Write-Host ''
Write-Host "Ran $($script:passes + $script:failures) cases: $($script:passes) passed, $($script:failures) failed."
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
