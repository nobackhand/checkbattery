# ============================================================
# BATTERY DATA COLLECTION
# ============================================================

function Read-DeviceNumber {
    <#
    .SYNOPSIS
        Validated read of ONE numeric property coming from outside the app
        (WMI / battery firmware). Returns $null - "no reading" - for anything
        that is not a finite number inside [Min, Max].

        Every value on Win32_Battery is whatever the OEM's firmware felt like
        reporting, and PowerShell's casts turn that into a crash or a lie:
        [int]4294967295 (the UInt32 "unknown" pattern) THROWS, [int]$null is a
        silent 0, [int] of a dual-battery array THROWS, and a string property
        sails through `-gt 0` before throwing on the cast. Validate here once
        instead of guessing at each call site.
    #>
    [OutputType([object])]
    param(
        # any-typed: one raw WMI property - number, string, $null, or an array.
        [AllowNull()][object]$Raw,
        [double]$Min = 0,
        [double]$Max = 2147483647
    )
    if ($null -eq $Raw) { return $null }
    # The cast is the shape check too: [double] throws for a collection (the
    # dual-battery array, a REG_MULTI_SZ) and for a non-numeric string alike.
    $value = 0.0
    try { $value = [double]$Raw } catch { return $null }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return $null }
    if ($value -lt $Min -or $value -gt $Max) { return $null }
    return $value
}

function Get-BatteryInfo {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][Nullable[datetime]]$Now = $null,
        # Test seam: when bound, this stands in for the Win32_Battery instance
        # instead of querying WMI, so the adversarial suite can hand the parser
        # firmware values no real machine here would produce.
        # any-typed: a WMI instance, a stub with the same properties, or $null.
        [AllowNull()][object]$WmiBattery = $null,
        # Test seam: same, for the .NET PowerStatus fallback source.
        # any-typed: a PowerStatus instance or a stub with the same properties.
        [AllowNull()][object]$PowerStatus = $null
    )
    if ($null -eq $Now) { $Now = Get-Date }
    $info = @{
        Percent            = -1
        PercentExact       = -1.0
        IsCharging         = $false
        IsPluggedIn        = $false
        IsFullyCharged     = $false
        NoBattery          = $false
        StatusText         = "Unknown"
        TimeMinutes        = -1
        TimeString         = "Estimating..."
        TimeLabel          = "Time Remaining:"
        PowerSource        = "Unknown"
        DesignCapacity     = -1
        FullChargeCapacity = -1
        DischargeRate      = -1
        ChargeRate         = -1
        BatteryWearPercent = -1.0
        ETA                = ""
        FullRuntimeMinutes = -1
        ElapsedTime        = ""
        ElapsedSince       = ""
    }

    # WMI primary source. Dual-battery laptops return an ARRAY here; member access
    # on it produces arrays that crash the [int] casts below, so take the first
    # pack (empty array pipes to $null, preserving the no-battery path).
    if ($PSBoundParameters.ContainsKey('WmiBattery')) {
        $wmiBattery = @($WmiBattery) | Select-Object -First 1
    } else {
        try {
            $wmiBattery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop) | Select-Object -First 1
        } catch {
            $wmiBattery = $null
        }
    }

    # .NET fallback source
    $dotnetPower = if ($PSBoundParameters.ContainsKey('PowerStatus')) { $PowerStatus }
    else { [System.Windows.Forms.SystemInformation]::PowerStatus }

    # No battery detection
    $dnChargeStatus = if ($dotnetPower) { Read-DeviceNumber -Raw $dotnetPower.BatteryChargeStatus -Min 0 -Max 255 } else { $null }
    if ($null -eq $wmiBattery) {
        if ($null -eq $dotnetPower -or ($null -ne $dnChargeStatus -and ([int]$dnChargeStatus -band 128) -eq 128)) {
            $info.NoBattery = $true
            $info.StatusText = "No Battery"
            $info.TimeString = "N/A"
            $info.PowerSource = "AC Power"
            return $info
        }
    }

    # Charge percentage. Firmware lies here, so validate rather than trust:
    # a null EstimatedChargeRemaining casts to 0 via [int] - a false "0%" that
    # paints the pill critical-red and fires the 5% alarm - and 255 is the
    # documented "unknown" sentinel. Anything outside 0-100 is treated as no
    # reading so the .NET source can answer instead.
    $wmiPct = $null
    if ($wmiBattery) {
        $wmiPct = Read-DeviceNumber -Raw $wmiBattery.EstimatedChargeRemaining -Min 0 -Max 100
    }
    if ($null -ne $wmiPct) {
        $info.PercentExact = $wmiPct
        $info.Percent = [int]$wmiPct
    } elseif ($dotnetPower) {
        # BatteryLifePercent is 255 when the driver has no reading, so the
        # fraction is range-checked before it becomes a percentage.
        $dnFraction = Read-DeviceNumber -Raw $dotnetPower.BatteryLifePercent -Min 0 -Max 1
        if ($null -ne $dnFraction) {
            $dnPct = [math]::Round($dnFraction * 100, 1)
            $info.PercentExact = $dnPct
            $info.Percent = [int]$dnPct
        }
    }

    # Charging status from WMI
    if ($wmiBattery) {
        # BatteryStatus is a UInt16 code 1-11; anything else (a string, an
        # array, an out-of-range code) means "unknown", not a state.
        $batteryStatus = Read-DeviceNumber -Raw $wmiBattery.BatteryStatus -Min 1 -Max 11
        $info.IsCharging = $batteryStatus -in @(2, 6, 7, 8, 9)
        $info.IsPluggedIn = $batteryStatus -in @(2, 3, 6, 7, 8, 9, 11)
        $info.IsFullyCharged = ($null -ne $batteryStatus -and $batteryStatus -eq 3)
    }

    # .NET cross-validation
    if ($dotnetPower) {
        if ($dotnetPower.PowerLineStatus -eq 'Online') {
            $info.IsPluggedIn = $true
        }
        if ($null -ne $dnChargeStatus -and ([int]$dnChargeStatus -band 8) -eq 8) {
            $info.IsCharging = $true
        }
    }

    if ($info.Percent -ge 100 -and $info.IsPluggedIn) {
        $info.IsFullyCharged = $true
        $info.IsCharging = $false
    }

    # --- Extended WMI data (capacity, rates, wear) ---
    if ($wmiBattery) {
        # Every one of these is firmware-supplied: validate the range FIRST, so
        # a UInt32 sentinel or a string never reaches an [int] cast. Min 1
        # because a zero capacity/rate is "no reading", not a measurement.
        $designCap = Read-DeviceNumber -Raw $wmiBattery.DesignCapacity -Min 1
        if ($null -ne $designCap) { $info.DesignCapacity = [int]$designCap }

        $fullCap = Read-DeviceNumber -Raw $wmiBattery.FullChargeCapacity -Min 1
        if ($null -ne $fullCap) { $info.FullChargeCapacity = [int]$fullCap }

        $dischargeRate = Read-DeviceNumber -Raw $wmiBattery.DischargeRate -Min 1
        if ($null -ne $dischargeRate) { $info.DischargeRate = [int]$dischargeRate }

        $chargeRate = Read-DeviceNumber -Raw $wmiBattery.ChargeRate -Min 1
        if ($null -ne $chargeRate) { $info.ChargeRate = [int]$chargeRate }

        # Full runtime from WMI (71582788 is the documented "unknown" sentinel)
        $runTime = Read-DeviceNumber -Raw $wmiBattery.EstimatedRunTime -Min 1
        if ($null -ne $runTime -and $runTime -ne 71582788) { $info.FullRuntimeMinutes = [int]$runTime }
    }

    # Battery wear
    if ($info.DesignCapacity -gt 0 -and $info.FullChargeCapacity -gt 0) {
        $info.BatteryWearPercent = [math]::Round((($info.DesignCapacity - $info.FullChargeCapacity) / $info.DesignCapacity) * 100, 1)
        if ($info.BatteryWearPercent -lt 0) { $info.BatteryWearPercent = 0.0 }
    }

    # Time remaining — use EMA-smoothed calculation for stability
    $timeMinutes = -1
    if (-not $info.IsFullyCharged) {
        # Determine raw rate based on charging state
        $rawRate = if ($info.IsCharging) { $info.ChargeRate } else { $info.DischargeRate }

        # Try EMA-smoothed calculation first (more stable)
        $timeMinutes = Get-SmoothedTimeRemaining `
            -RawRate $rawRate `
            -FullChargeCapacity $info.FullChargeCapacity `
            -PercentExact $info.PercentExact `
            -IsCharging $info.IsCharging `
            -IsPluggedIn $info.IsPluggedIn `
            -Now $Now

        # Fallback to WMI/dotnet if smoothed calculation unavailable
        if ($timeMinutes -le 0) {
            if (-not $info.IsCharging) {
                # These reads used to cast straight to [int]: EstimatedRunTime
                # is a UInt32, so the 4294967295 "unknown" pattern threw out of
                # Get-BatteryInfo on every timer tick.
                $runFallback = if ($wmiBattery) { Read-DeviceNumber -Raw $wmiBattery.EstimatedRunTime -Min 1 } else { $null }
                $dnRemaining = if ($dotnetPower) { Read-DeviceNumber -Raw $dotnetPower.BatteryLifeRemaining -Min 1 } else { $null }
                if ($null -ne $runFallback -and $runFallback -ne 71582788) {
                    $timeMinutes = [int]$runFallback
                } elseif ($null -ne $dnRemaining) {
                    $timeMinutes = [math]::Round($dnRemaining / 60)
                }
            } elseif ($info.IsCharging) {
                $toFull = if ($wmiBattery) { Read-DeviceNumber -Raw $wmiBattery.TimeToFullCharge -Min 1 } else { $null }
                if ($null -ne $toFull) { $timeMinutes = [int]$toFull }
            }
        }
    }
    # Sanity clamp: a tiny/glitchy rate can compute absurd estimates
    # (56,270 mWh / 100 mW = 562h). Nothing with a battery runs 100h+;
    # treat those as "no estimate yet" rather than displaying garbage.
    if ($timeMinutes -gt 5999) { $timeMinutes = -1 }
    $info.TimeMinutes = $timeMinutes

    # Format time string
    if ($timeMinutes -gt 0) {
        $hours = [math]::Floor($timeMinutes / 60)
        $minutes = $timeMinutes % 60
        if ($hours -gt 0 -and $minutes -gt 0) {
            $hourLabel = if ($hours -ne 1) { "hours" } else { "hour" }
            $minuteLabel = if ($minutes -ne 1) { "minutes" } else { "minute" }
            $info.TimeString = "$hours $hourLabel $minutes $minuteLabel"
        } elseif ($hours -gt 0) {
            $hourLabel = if ($hours -ne 1) { "hours" } else { "hour" }
            $info.TimeString = "$hours $hourLabel"
        } else {
            $minuteLabel = if ($minutes -ne 1) { "minutes" } else { "minute" }
            $info.TimeString = "$minutes $minuteLabel"
        }
    } else {
        $info.TimeString = "Estimating..."
    }

    # ETA - only when it lands within 12h; an "h:mm tt" more than half a day
    # out is ambiguous ("ETA 2:56 PM" on a 27h estimate reads as today)
    if ($timeMinutes -gt 0 -and $timeMinutes -le 720) {
        $eta = $Now.AddMinutes($timeMinutes)
        $info.ETA = $eta.ToString("h:mm tt")
    }

    # Status text.
    # The `-ge 0` guards are load-bearing: Percent is -1 when NO source gave a
    # reading, and "-1 is <= 10" made an unreadable battery report itself as
    # Critical - red hero text and a "Critical" title on data we do not have.
    if ($info.IsFullyCharged) {
        $info.StatusText = "Fully Charged"
    } elseif ($info.IsCharging) {
        $info.StatusText = "Charging"
    } elseif ($info.Percent -ge 0 -and $info.Percent -le 10) {
        $info.StatusText = "Critical"
    } elseif ($info.Percent -ge 0 -and $info.Percent -le 20) {
        $info.StatusText = "Low"
    } else {
        $info.StatusText = "Discharging"
    }

    # Labels
    $info.PowerSource = if ($info.IsPluggedIn) { "AC Power (plugged in)" } else { "Battery (unplugged)" }
    $info.TimeLabel = if ($info.IsCharging) { "Time to Full:" }
    elseif ($info.IsFullyCharged) { "Time Remaining:" }
    else { "Time Remaining:" }

    if ($info.IsFullyCharged) {
        $info.TimeString = "N/A (plugged in)"
    }

    # Elapsed time tracking
    if ($script:lastStateChange.State -eq "") {
        # First run — initialize
        $script:lastStateChange.Time = $Now
        $script:lastStateChange.Percent = $info.PercentExact
        $script:lastStateChange.State = $info.StatusText
    } elseif ($script:lastStateChange.State -ne $info.StatusText) {
        # State changed — reset
        $script:lastStateChange.Time = $Now
        $script:lastStateChange.Percent = $info.PercentExact
        $script:lastStateChange.State = $info.StatusText
    }

    # A backward wall-clock jump (DST, an NTP correction, the machine waking
    # with a stale RTC) makes this span negative, and [math]::Floor(-0.4) = -1
    # with .Minutes = -24 rendered as the nonsense "-1:-24". Resync the anchor
    # to now and report 0:00 - the same self-heal Get-CapacityDerivedRate does.
    if ($Now -lt $script:lastStateChange.Time) {
        $script:lastStateChange.Time = $Now
        $script:lastStateChange.Percent = $info.PercentExact
    }
    $elapsed = $Now - $script:lastStateChange.Time
    $elapsedHours = [math]::Floor($elapsed.TotalHours)
    $elapsedMins = $elapsed.Minutes
    $info.ElapsedTime = "{0}:{1:D2}" -f $elapsedHours, $elapsedMins
    $info.ElapsedSince = "$($script:lastStateChange.Percent)%"

    return $info
}

