#Requires -Version 5.0

<#
.SYNOPSIS
    Checks battery life remaining and displays status.
.DESCRIPTION
    Queries Windows battery information using WMI and .NET APIs
    to display current charge level, charging status, and estimated
    time remaining in hours and minutes.
.EXAMPLE
    .\CheckBattery.ps1
#>

[CmdletBinding()]
param()

# Platform check for PowerShell 7+ (PS 5.1 is Windows-only)
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Error "This script requires Windows."
    exit 1
}

# --- Validated read of one firmware-supplied number ---
# Win32_Battery values come from the OEM's firmware, and PowerShell's casts turn
# bad ones into crashes or lies: [int]4294967295 (the UInt32 "unknown" pattern)
# THROWS, [int]$null is a silent 0%, and [int] of the array a dual-battery
# laptop returns THROWS. Returns $null - "no reading" - for anything that is not
# a finite number inside [Min, Max].
function Read-DeviceNumber {
    [OutputType([object])]
    param(
        # any-typed: one raw WMI property - number, string, $null, or an array.
        [AllowNull()][object]$Raw,
        [double]$Min = 0,
        [double]$Max = 2147483647
    )
    if ($null -eq $Raw) { return $null }
    # The cast is the shape check too: [double] throws for a collection (the
    # dual-battery array) and for a non-numeric string alike.
    $value = 0.0
    try { $value = [double]$Raw } catch { return $null }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return $null }
    if ($value -lt $Min -or $value -gt $Max) { return $null }
    return $value
}

# --- Query battery data from WMI (primary source) ---
# A dual-battery laptop returns an ARRAY here; member access on it yields arrays
# that used to crash every [int] cast below, so take the first pack (an empty
# array pipes to $null, preserving the no-battery path).
try {
    $wmiBattery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop) | Select-Object -First 1
} catch {
    Write-Verbose "WMI query failed: $_"
    $wmiBattery = $null
}

# --- Query battery data from .NET (fallback source) ---
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $dotnetPower = [System.Windows.Forms.SystemInformation]::PowerStatus
} catch {
    Write-Verbose ".NET PowerStatus query failed: $_"
    $dotnetPower = $null
}

# --- Handle no battery ---
$noBattery = $false
$dnChargeStatus = if ($dotnetPower) { Read-DeviceNumber -Raw $dotnetPower.BatteryChargeStatus -Min 0 -Max 255 } else { $null }
if ($null -eq $wmiBattery) {
    if ($null -eq $dotnetPower -or ($null -ne $dnChargeStatus -and ([int]$dnChargeStatus -band 128) -eq 128)) {
        $noBattery = $true
    }
}

if ($noBattery) {
    $separator = "=" * 39
    Write-Host ""
    Write-Host "  $separator" -ForegroundColor DarkGray
    Write-Host "      BatteryPill - Battery Status" -ForegroundColor White
    Write-Host "  $separator" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    No battery detected." -ForegroundColor Yellow
    Write-Host "    This appears to be a desktop PC" -ForegroundColor Yellow
    Write-Host "    or a device without a battery." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    You're on wall power - nothing to charge here." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  $separator" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# --- Extract charge percentage ---
# 255 is the documented WMI "unknown" sentinel and a null casts to a false 0%,
# so anything outside 0-100 is treated as no reading and the .NET source
# (itself 255 when unknown, hence the 0-1 range check) answers instead.
$chargePercent = -1
$wmiPct = if ($wmiBattery) { Read-DeviceNumber -Raw $wmiBattery.EstimatedChargeRemaining -Min 0 -Max 100 } else { $null }
$dnFraction = if ($dotnetPower) { Read-DeviceNumber -Raw $dotnetPower.BatteryLifePercent -Min 0 -Max 1 } else { $null }
if ($null -ne $wmiPct) {
    $chargePercent = [int]$wmiPct
} elseif ($null -ne $dnFraction) {
    $chargePercent = [int]($dnFraction * 100)
}

# --- Determine charging status ---
# WMI BatteryStatus: 1=Discharging, 2=AC connected, 3=Fully Charged,
# 4=Low, 5=Critical, 6=Charging, 7=Charging+High, 8=Charging+Low,
# 9=Charging+Critical, 10=Undefined, 11=Partially Charged
$isCharging = $false
$isPluggedIn = $false
$isFullyCharged = $false

if ($wmiBattery) {
    # A UInt16 code 1-11; anything else means "unknown", not a state.
    $batteryStatus = Read-DeviceNumber -Raw $wmiBattery.BatteryStatus -Min 1 -Max 11
    $isCharging = $batteryStatus -in @(2, 6, 7, 8, 9)
    $isPluggedIn = $batteryStatus -in @(2, 3, 6, 7, 8, 9, 11)
    $isFullyCharged = ($null -ne $batteryStatus -and $batteryStatus -eq 3)
}

if ($dotnetPower) {
    if ($dotnetPower.PowerLineStatus -eq 'Online') {
        $isPluggedIn = $true
    }
    if ($null -ne $dnChargeStatus -and ([int]$dnChargeStatus -band 8) -eq 8) {
        $isCharging = $true
    }
}

if ($chargePercent -ge 100 -and $isPluggedIn) {
    $isFullyCharged = $true
    $isCharging = $false
}

# --- Calculate time remaining in minutes ---
$timeMinutes = -1

if (-not $isCharging -and -not $isFullyCharged) {
    # Discharging: get estimated run time (71582788 is the "unknown" sentinel)
    $runTime = if ($wmiBattery) { Read-DeviceNumber -Raw $wmiBattery.EstimatedRunTime -Min 1 } else { $null }
    $dnRemaining = if ($dotnetPower) { Read-DeviceNumber -Raw $dotnetPower.BatteryLifeRemaining -Min 1 } else { $null }
    if ($null -ne $runTime -and $runTime -ne 71582788) {
        $timeMinutes = [int]$runTime
    } elseif ($null -ne $dnRemaining) {
        $timeMinutes = [math]::Round($dnRemaining / 60)
    }
} elseif ($isCharging) {
    # Charging: get time to full
    $toFull = if ($wmiBattery) { Read-DeviceNumber -Raw $wmiBattery.TimeToFullCharge -Min 1 } else { $null }
    if ($null -ne $toFull) { $timeMinutes = [int]$toFull }
}

# --- Format time as hours and minutes ---
if ($timeMinutes -gt 0) {
    $hours = [math]::Floor($timeMinutes / 60)
    $minutes = $timeMinutes % 60

    if ($hours -gt 0 -and $minutes -gt 0) {
        $hourLabel = if ($hours -ne 1) { "hours" } else { "hour" }
        $minuteLabel = if ($minutes -ne 1) { "minutes" } else { "minute" }
        $timeString = "$hours $hourLabel $minutes $minuteLabel"
    } elseif ($hours -gt 0) {
        $hourLabel = if ($hours -ne 1) { "hours" } else { "hour" }
        $timeString = "$hours $hourLabel"
    } else {
        $minuteLabel = if ($minutes -ne 1) { "minutes" } else { "minute" }
        $timeString = "$minutes $minuteLabel"
    }
} else {
    $timeString = "Estimating..."
}

# --- Build visual battery bar ---
$barWidth = 34
$filledWidth = [math]::Round(($chargePercent / 100) * $barWidth)
if ($filledWidth -gt $barWidth) { $filledWidth = $barWidth }
if ($filledWidth -lt 0) { $filledWidth = 0 }

$bar = ("|" * $filledWidth) + (" " * ($barWidth - $filledWidth))
# "--" not "-1%": -1 is the app's no-reading marker, not a charge level.
$percentText = if ($chargePercent -ge 0) { "$chargePercent%" } else { "--" }
$batteryBar = "    [$bar] $percentText"

# --- Determine status text and color ---
# The `-ge 0` guards below are load-bearing: -1 means NO source gave a reading,
# and "-1 is <= 10" reported an unreadable battery as Critical.
if ($isFullyCharged) {
    $statusText = "Fully Charged"
    $statusColor = "Green"
} elseif ($isCharging) {
    $statusText = "Charging"
    $statusColor = "Yellow"
} elseif ($chargePercent -ge 0 -and $chargePercent -le 10) {
    $statusText = "Critical"
    $statusColor = "Red"
} elseif ($chargePercent -ge 0 -and $chargePercent -le 20) {
    $statusText = "Low"
    $statusColor = "DarkYellow"
} else {
    $statusText = "Discharging"
    $statusColor = "Cyan"
}

$powerSourceText = if ($isPluggedIn) { "AC Power (plugged in)" } else { "Battery (unplugged)" }

$timeLabel = if ($isCharging) { "Time to Full:     " }
elseif ($isFullyCharged) { "Time Remaining:   " }
else { "Time Remaining:   " }

$timeDisplay = if ($isFullyCharged) { "N/A (plugged in)" } else { $timeString }

# --- Display output ---
$separator = "=" * 39

Write-Host ""
Write-Host "  $separator" -ForegroundColor DarkGray
Write-Host "      BatteryPill - Battery Status" -ForegroundColor White
Write-Host "  $separator" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Battery Level:    " -NoNewline; Write-Host $percentText -ForegroundColor $statusColor
Write-Host "    Status:           " -NoNewline; Write-Host $statusText -ForegroundColor $statusColor
Write-Host "    Power Source:     $powerSourceText"
Write-Host "    $timeLabel" -NoNewline

if (-not $isCharging -and -not $isFullyCharged -and $timeMinutes -gt 0 -and $timeMinutes -le 30) {
    Write-Host $timeDisplay -ForegroundColor Red
} else {
    Write-Host $timeDisplay
}

Write-Host ""
Write-Host $batteryBar -ForegroundColor $statusColor
Write-Host ""

# --- Warnings ---
if ($chargePercent -ge 0 -and $chargePercent -le 10 -and -not $isCharging -and -not $isPluggedIn) {
    Write-Host "    WARNING: Battery critically low! Plug in immediately." -ForegroundColor Red
    Write-Host ""
} elseif ($chargePercent -ge 0 -and $chargePercent -le 20 -and -not $isCharging -and -not $isPluggedIn) {
    Write-Host "    Battery is low. Consider plugging in." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  $separator" -ForegroundColor DarkGray
Write-Host ""
