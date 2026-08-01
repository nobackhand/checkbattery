# ============================================================
# EMA SMOOTHING FOR DISCHARGE RATE
# ============================================================

function Update-EMARate {
    [OutputType([int])]
    param([int]$RawRate)

    # Track recent rates for volatility detection
    $script:rateHistory.Add($RawRate) | Out-Null
    if ($script:rateHistory.Count -gt 10) { $script:rateHistory.RemoveAt(0) }

    # Adaptive alpha based on rate stability (coefficient of variation)
    $alpha = 0.15  # default
    $count = $script:rateHistory.Count
    if ($count -ge 5) {
        $sum = 0
        for ($i = 0; $i -lt $count; $i++) { $sum += $script:rateHistory[$i] }
        $mean = $sum / $count
        if ($mean -gt 0) {
            $varSum = 0
            for ($i = 0; $i -lt $count; $i++) {
                $d = $script:rateHistory[$i] - $mean
                $varSum += $d * $d
            }
            $cv = [math]::Sqrt($varSum / $count) / $mean
            if ($cv -lt 0.10) { $alpha = 0.30 }      # stable: respond faster
            elseif ($cv -gt 0.30) { $alpha = 0.08 }   # volatile: dampen more
        }
    }

    if ($script:emaRate -lt 0) {
        # First reading - initialize directly
        $script:emaRate = $RawRate
    } else {
        # EMA formula: R_EMA_t = alpha * R_raw_t + (1 - alpha) * R_EMA_(t-1)
        $script:emaRate = ($alpha * $RawRate) + ((1 - $alpha) * $script:emaRate)
    }

    return [int]$script:emaRate
}

function Get-CapacityDerivedRate {
    [OutputType([int])]
    param([int]$FullChargeCapacity, [double]$PercentExact, [AllowNull()][Nullable[datetime]]$Now = $null)
    if ($null -eq $Now) { $Now = Get-Date }
    $currentCapacity = $FullChargeCapacity * ($PercentExact / 100)

    if ($null -eq $script:lastCapacityCheck) {
        $script:lastCapacityCheck = @{ Time = $now; Capacity = $currentCapacity }
        return -1
    }

    $elapsed = ($now - $script:lastCapacityCheck.Time).TotalHours
    if ($elapsed -lt 0) {
        # Wall clock jumped backward (DST/NTP) - resync the sample or the
        # early-return below deadlocks sampling until real time re-passes it
        $script:lastCapacityCheck = @{ Time = $Now; Capacity = $currentCapacity }
        return -1
    }
    if ($elapsed -lt 0.0083) { return -1 }  # need at least 30 seconds

    $capDelta = $script:lastCapacityCheck.Capacity - $currentCapacity  # mWh consumed
    $derivedRate = [int]($capDelta / $elapsed)  # mW

    $script:lastCapacityCheck.Time = $Now
    $script:lastCapacityCheck.Capacity = $currentCapacity
    if ($derivedRate -gt 0) { return $derivedRate }
    return -1
}

function Get-SmoothedTimeRemaining {
    [OutputType([int])]
    param(
        [int]$RawRate,
        [int]$FullChargeCapacity,
        [double]$PercentExact,
        [bool]$IsCharging,
        [bool]$IsPluggedIn,
        [AllowNull()][Nullable[datetime]]$Now = $null
    )
    if ($null -eq $Now) { $Now = Get-Date }

    # --- Hysteresis: detect and handle AC state transitions ---
    if ($null -ne $script:lastAcState -and $script:lastAcState -ne $IsPluggedIn) {
        # AC state just changed — start hysteresis window
        $script:stateChangeTime = $Now
        # Reset EMA on state change to avoid polluting new state with old rate.
        # The held rate goes with it: a discharge rate is not a charge rate, so
        # carrying it across the transition let the "hold" path below compute a
        # confident time-to-full from how fast the battery had been DRAINING
        # (and vice versa on unplug) before the new state ever reported a rate.
        # The resume-from-sleep handler already clears all three together.
        $script:emaRate = -1
        $script:lastValidRate = -1
        $script:lastValidRateTime = $null
    }
    $script:lastAcState = $IsPluggedIn

    # During hysteresis window, return -1 to show "Calculating..."
    if ($null -ne $script:stateChangeTime) {
        $elapsed = ($Now - $script:stateChangeTime).TotalSeconds
        if ($elapsed -lt $script:hysteresisSeconds) {
            return -1
        } else {
            # Hysteresis window complete — clear it
            $script:stateChangeTime = $null
        }
    }

    # --- Determine effective rate ---
    $effectiveRate = -1

    if ($RawRate -gt 0 -and $RawRate -lt 4294967295) {
        # Valid rate — update EMA and track as last valid
        $effectiveRate = Update-EMARate -RawRate $RawRate
        $script:lastValidRate = $RawRate
        $script:lastValidRateTime = $Now
    } elseif ($script:lastValidRate -gt 0) {
        # Invalid rate but we have a previous valid one — only use if fresh (< 60s old)
        $rateAge = if ($null -ne $script:lastValidRateTime) { ($Now - $script:lastValidRateTime).TotalSeconds } else { 999 }
        if ($rateAge -lt 60) {
            $effectiveRate = Update-EMARate -RawRate $script:lastValidRate
        }
        # else: effectiveRate stays -1, triggers WMI/dotnet fallback
    }

    # --- Cross-validate with capacity-derived rate (discharging only) ---
    if ($effectiveRate -gt 0 -and -not $IsCharging -and $FullChargeCapacity -gt 0) {
        $derivedRate = Get-CapacityDerivedRate -FullChargeCapacity $FullChargeCapacity -PercentExact $PercentExact -Now $Now
        if ($derivedRate -gt 0) {
            $divergence = [math]::Abs($effectiveRate - $derivedRate) / [math]::Max($effectiveRate, $derivedRate)
            if ($divergence -gt 0.40) {
                $script:capacityRateMismatchCount++
                if ($script:capacityRateMismatchCount -ge 3) {
                    # WMI rate consistently diverges - prefer capacity-derived rate
                    $effectiveRate = Update-EMARate -RawRate $derivedRate
                }
            } else {
                $script:capacityRateMismatchCount = 0
            }
        }
    }

    # --- Calculate time remaining from smoothed rate ---
    if ($effectiveRate -gt 0 -and $FullChargeCapacity -gt 0 -and $PercentExact -gt 0) {
        if ($IsCharging) {
            # Time to full: remaining capacity to fill / charge rate
            $remainingCapacity = $FullChargeCapacity * ((100 - $PercentExact) / 100)
        } else {
            # Time remaining: current charge / discharge rate
            $remainingCapacity = $FullChargeCapacity * ($PercentExact / 100)
        }

        # Rate is in mW, capacity is in mWh, so time = capacity / rate (hours)
        $timeMinutes = [int](($remainingCapacity / $effectiveRate) * 60)
        return $timeMinutes
    }

    return -1
}

