# tests\Estimation.Tests.ps1
#
# Tests for the battery-estimation core in BatteryWidget.ps1: the EMA smoother
# and the "hold the last valid rate" logic that Get-SmoothedTimeRemaining uses
# when WMI stops reporting a rate. This is the code behind the single number
# the pill exists to show, and it is the one place the app can invent a figure
# out of thin air, so its state transitions get pinned here.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Update-EMARate', 'Get-CapacityDerivedRate', 'Get-SmoothedTimeRemaining')

Write-Host 'Estimation.Tests.ps1'

# The module-level estimator state, exactly as BatteryWidget.ps1 initializes it.
function Reset-EstimatorState {
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
}

$t0 = [datetime]'2026-07-29T09:00:00'

# ---- Update-EMARate ----

Test-Case 'Update-EMARate seeds from the first reading instead of easing up from zero' {
    Reset-EstimatorState
    Assert-Equal 12000 (Update-EMARate -RawRate 12000)
}

Test-Case 'Update-EMARate smooths a jump instead of snapping to it' {
    Reset-EstimatorState
    [void](Update-EMARate -RawRate 10000)
    # alpha 0.15 on the second reading: 0.15*20000 + 0.85*10000 = 11500
    Assert-Equal 11500 (Update-EMARate -RawRate 20000)
}

# ---- Get-SmoothedTimeRemaining ----

Test-Case 'computes time remaining from the smoothed discharge rate' {
    Reset-EstimatorState
    # 50000 mWh pack at 50% = 25000 mWh left, draining at 10000 mW = 2.5h = 150 min
    Assert-Equal 150 (Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0)
}

Test-Case 'holds the last valid rate through a momentary WMI dropout' {
    Reset-EstimatorState
    [void](Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0)
    # Same power state, rate briefly unavailable: the held rate keeps the estimate alive
    Assert-Equal 150 (Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0.AddSeconds(3))
}

Test-Case 'suppresses the estimate during the post-plug hysteresis window' {
    Reset-EstimatorState
    [void](Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0)
    Assert-Equal (-1) (Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $true -IsPluggedIn $true -Now $t0.AddSeconds(1))
}

Test-Case 'does not reuse the pre-unplug discharge rate as a charge rate' {
    # REGRESSION: the AC transition reset $emaRate but left $lastValidRate/-Time
    # alone, so once the 2s hysteresis expired the "hold" path fed the old
    # DISCHARGE rate into a time-to-full calculation. The pill showed a
    # confident, entirely invented "time to full" the moment you plugged in,
    # before the charger had ever reported a rate.
    Reset-EstimatorState
    [void](Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0)
    # Plug in: hysteresis window
    [void](Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $true -IsPluggedIn $true -Now $t0.AddSeconds(1))
    # Hysteresis over, charger still not reporting a rate: no estimate, not a
    # figure derived from how fast the battery was draining a moment ago.
    Assert-Equal (-1) (Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $true -IsPluggedIn $true -Now $t0.AddSeconds(6))
}

Test-Case 'uses the real charge rate once the charger reports one' {
    Reset-EstimatorState
    [void](Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0)
    [void](Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $true -IsPluggedIn $true -Now $t0.AddSeconds(1))
    # 25000 mWh still to fill at 25000 mW = 1h = 60 min
    Assert-Equal 60 (Get-SmoothedTimeRemaining -RawRate 25000 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $true -IsPluggedIn $true -Now $t0.AddSeconds(6))
}

Test-Case 'unplugging does not reuse the charge rate as a discharge rate either' {
    Reset-EstimatorState
    [void](Get-SmoothedTimeRemaining -RawRate 25000 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $true -IsPluggedIn $true -Now $t0)
    [void](Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0.AddSeconds(1))
    Assert-Equal (-1) (Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0.AddSeconds(6))
}

Test-Case 'drops a held rate that has gone stale (older than 60s)' {
    Reset-EstimatorState
    [void](Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0)
    Assert-Equal (-1) (Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0.AddSeconds(120))
}

exit (Complete-Tests)
