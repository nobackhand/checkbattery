# tests\Estimation.Tests.ps1
#
# Regression suite for the battery-estimation module (src\030-estimation.ps1) - the
# three functions that turn raw WMI readings into the single number the pill
# exists to show:
#
#     Update-EMARate           adaptive-alpha smoother over the raw rate
#     Get-CapacityDerivedRate  independent mW rate measured from capacity drift
#     Get-SmoothedTimeRemaining  the estimator the whole UI reads
#
# This is the app's business-critical module: every visible surface (pill,
# popup, tray tooltip, low-battery warnings) renders what it returns, and it is
# the one place the app can invent an authoritative-looking figure out of thin
# air. So all three public functions are pinned here, edge cases included -
# every guard (zero capacity, drained battery, cold start, clock jumps,
# sub-sample intervals, charging sign flips), every branch of the adaptive
# alpha, and every state transition (AC plug/unplug, dropout, staleness,
# capacity cross-validation).
#
# Every test below was confirmed to FAIL against a deliberate one-line mutation
# of the code it covers; see history/missions-evidence/mission-09-mutation.log.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Update-EMARate', 'Get-CapacityDerivedRate', 'Get-SmoothedTimeRemaining')

Write-Host 'Estimation.Tests.ps1'

# The module-level estimator state, exactly as the widget source initializes it.
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

Test-Case 'Update-EMARate keeps only the last 10 raw rates' {
    # The window feeds the volatility measure below. If it grows without bound
    # it both leaks for the life of the process and freezes alpha, because a
    # months-old reading keeps dragging the mean.
    Reset-EstimatorState
    for ($i = 1; $i -le 12; $i++) { [void](Update-EMARate -RawRate ($i * 1000)) }
    Assert-Equal 10 $script:rateHistory.Count
    Assert-Equal 3000 $script:rateHistory[0]  # the two oldest fell off the front
    Assert-Equal 12000 $script:rateHistory[9]
}

Test-Case 'Update-EMARate speeds up (alpha 0.30) when the rate is stable' {
    # Five identical readings then a small step: cv ~= 0.018 (< 0.10), so the
    # smoother is allowed to track a steady load faster.
    Reset-EstimatorState
    for ($i = 1; $i -le 5; $i++) { [void](Update-EMARate -RawRate 10000) }
    # 0.30*10500 + 0.70*10000 = 10150
    Assert-Equal 10150 (Update-EMARate -RawRate 10500)
}

Test-Case 'Update-EMARate dampens harder (alpha 0.08) when the rate is volatile' {
    # Same five readings, then a doubling: cv ~= 0.319 (> 0.30), so a spiky load
    # must move the estimate LESS than the default alpha would.
    Reset-EstimatorState
    for ($i = 1; $i -le 5; $i++) { [void](Update-EMARate -RawRate 10000) }
    # 0.08*20000 + 0.92*10000 = 10800 (default alpha 0.15 would give 11500)
    Assert-Equal 10800 (Update-EMARate -RawRate 20000)
}

Test-Case 'Update-EMARate will not read a nonsensical window as a rock-steady rate' {
    # The volatility measure divides by the window mean, so a mean of zero or
    # below makes the coefficient of variation meaningless: NaN for an all-zero
    # window (a machine reporting no rate at all), and NEGATIVE for a window of
    # sign-flipped garbage - and any negative number satisfies "cv < 0.10", the
    # stable-rate test. The mean > 0 guard is the only thing stopping garbage
    # readings from tripling alpha to 0.30 and making the smoother MORE trusting
    # of exactly the input it should trust least.
    Reset-EstimatorState
    for ($i = 1; $i -le 4; $i++) { [void](Update-EMARate -RawRate 0) }
    Assert-Equal 0 (Update-EMARate -RawRate 0)  # 5th reading = window full, cv computed

    # Four sane readings, then one wildly sign-flipped one drags the window mean
    # to -40000 while the running average is still positive (so the smoother
    # really does take the EMA branch here).
    Reset-EstimatorState
    for ($i = 1; $i -le 4; $i++) { [void](Update-EMARate -RawRate 100000) }
    # Default alpha 0.15: 0.15*-600000 + 0.85*100000 = -5000.
    # cv would be -7.0 here, which satisfies "cv < 0.10", so an unguarded
    # volatility test would call this stable and use alpha 0.30 (-110000).
    Assert-Equal (-5000) (Update-EMARate -RawRate -600000)
}

Test-Case 'Update-EMARate returns a whole mW figure but keeps full precision internally' {
    # Callers get an int; the running average must NOT be re-quantised each
    # tick or the rounding error compounds over hours of 3-second samples.
    Reset-EstimatorState
    [void](Update-EMARate -RawRate 10000)
    # 0.15*10005 + 0.85*10000 = 10000.75
    Assert-Equal 10001 (Update-EMARate -RawRate 10005)
    Assert-Equal 10000.75 $script:emaRate
}

# ---- Get-CapacityDerivedRate ----

Test-Case 'Get-CapacityDerivedRate has nothing to measure on the first sample' {
    Reset-EstimatorState
    Assert-Equal (-1) (Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 50.0 -Now $t0)
}

Test-Case 'Get-CapacityDerivedRate refuses to extrapolate from under 30 seconds' {
    # Percent is reported in whole-ish steps, so a short interval turns a
    # quantisation step into an enormous fake mW figure (here: 90000 mW).
    Reset-EstimatorState
    [void](Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 50.0 -Now $t0)
    Assert-Equal (-1) (Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 49.0 `
            -Now $t0.AddSeconds(20))
}

Test-Case 'Get-CapacityDerivedRate resyncs when the wall clock jumps backward' {
    # DST/NTP can move the clock behind the stored sample. Without the resync
    # the sample time stays in the future and sampling deadlocks until real
    # time catches back up to it.
    Reset-EstimatorState
    [void](Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 50.0 -Now $t0)
    $back = $t0.AddSeconds(-60)
    Assert-Equal (-1) (Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 50.0 -Now $back)
    Assert-Equal $back $script:lastCapacityCheck.Time
}

Test-Case 'Get-CapacityDerivedRate measures mW from the capacity drop' {
    Reset-EstimatorState
    [void](Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 50.0 -Now $t0)
    # 25000 mWh -> 15000 mWh over one hour = 10000 mW
    Assert-Equal 10000 (Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 30.0 `
            -Now $t0.AddHours(1))
}

Test-Case 'Get-CapacityDerivedRate advances its sample so the next reading is incremental' {
    # If the stored sample is not moved forward, every later reading is measured
    # against the ORIGINAL capacity - an average since boot, not a current rate.
    Reset-EstimatorState
    [void](Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 50.0 -Now $t0)
    [void](Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 30.0 -Now $t0.AddHours(1))
    # 15000 -> 10000 mWh in the last hour = 5000 mW (measuring from t0 gives 7500)
    Assert-Equal 5000 (Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 20.0 `
            -Now $t0.AddHours(2))
}

Test-Case 'Get-CapacityDerivedRate reports nothing while capacity is rising' {
    # It is a DISCHARGE cross-check. A charging battery yields a negative delta,
    # which must be discarded, not handed back as a rate.
    Reset-EstimatorState
    [void](Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 30.0 -Now $t0)
    Assert-Equal (-1) (Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 50.0 `
            -Now $t0.AddHours(1))
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

Test-Case 'still holds a rate that is just inside the 60s freshness window' {
    # The other side of the staleness boundary: a dropout lasting most of a
    # minute must not blank the pill while the reading is still usable.
    Reset-EstimatorState
    [void](Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0)
    Assert-Equal 150 (Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0.AddSeconds(59))
}

Test-Case 'invents nothing on a cold start with no rate at all' {
    # First tick after launch on a machine WMI has not reported a rate for:
    # there is no history to hold, so the honest answer is "no estimate".
    Reset-EstimatorState
    Assert-Equal (-1) (Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0)
}

Test-Case 'reports no estimate when the pack capacity is unknown' {
    # Desktops and some VMs report FullChargeCapacity 0; dividing by it or
    # multiplying through it yields "0m", i.e. a confident "battery dead now".
    Reset-EstimatorState
    Assert-Equal (-1) (Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 0 `
            -PercentExact 50.0 -IsCharging $false -IsPluggedIn $false -Now $t0)
}

Test-Case 'reports no estimate when the battery reads 0%' {
    Reset-EstimatorState
    Assert-Equal (-1) (Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 50000 `
            -PercentExact 0.0 -IsCharging $false -IsPluggedIn $false -Now $t0)
}

Test-Case 'charging at 100% is 0 minutes to full, not a full-pack runtime' {
    # The charging branch must measure the capacity still to FILL. Measuring the
    # capacity present instead reads "2h 30m to full" on a battery already full.
    Reset-EstimatorState
    Assert-Equal 0 (Get-SmoothedTimeRemaining -RawRate 20000 -FullChargeCapacity 50000 `
            -PercentExact 100.0 -IsCharging $true -IsPluggedIn $true -Now $t0)
}

Test-Case 'prefers the capacity-derived rate after 3 consecutive divergent samples' {
    # WMI's DischargeRate lies on some machines. Capacity drift says 5000 mW
    # while WMI insists on 10000 mW; after the third disagreement the estimator
    # switches to what the capacity actually did.
    Reset-EstimatorState
    $fixed = @{ RawRate = 10000; FullChargeCapacity = 50000; IsCharging = $false; IsPluggedIn = $false }
    [void](Get-SmoothedTimeRemaining @fixed -PercentExact 50.0 -Now $t0)                # seeds the capacity sample
    [void](Get-SmoothedTimeRemaining @fixed -PercentExact 40.0 -Now $t0.AddHours(1))    # divergence 1
    [void](Get-SmoothedTimeRemaining @fixed -PercentExact 30.0 -Now $t0.AddHours(2))    # divergence 2
    Assert-Equal 2 $script:capacityRateMismatchCount
    # Divergence 3: the derived 5000 mW is folded into the EMA (-> 9250 mW), so
    # 10000 mWh left reads 65 min instead of the 60 min WMI's rate would give.
    Assert-Equal 65 (Get-SmoothedTimeRemaining @fixed -PercentExact 20.0 -Now $t0.AddHours(3))
}

Test-Case 'a single divergent sample does not stick - agreement resets the counter' {
    # Without the reset, three disagreements spread over an entire session
    # (a spike an hour apart) would permanently override a healthy WMI rate.
    Reset-EstimatorState
    $fixed = @{ RawRate = 10000; FullChargeCapacity = 50000; IsCharging = $false; IsPluggedIn = $false }
    [void](Get-SmoothedTimeRemaining @fixed -PercentExact 50.0 -Now $t0)
    [void](Get-SmoothedTimeRemaining @fixed -PercentExact 40.0 -Now $t0.AddHours(1))  # derived 5000 -> diverges
    Assert-Equal 1 $script:capacityRateMismatchCount
    # Capacity now drops 10000 mWh in an hour, matching WMI exactly.
    Assert-Equal 60 (Get-SmoothedTimeRemaining @fixed -PercentExact 20.0 -Now $t0.AddHours(2))
    Assert-Equal 0 $script:capacityRateMismatchCount
}

exit (Complete-Tests)
