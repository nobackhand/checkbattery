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

# --- Query battery data from WMI (primary source) ---
try {
    $wmiBattery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop
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
if ($null -eq $wmiBattery) {
    if ($null -eq $dotnetPower -or ([int]$dotnetPower.BatteryChargeStatus -band 128) -eq 128) {
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
if ($wmiBattery) {
    $chargePercent = [int]$wmiBattery.EstimatedChargeRemaining
} elseif ($dotnetPower) {
    $chargePercent = [int]($dotnetPower.BatteryLifePercent * 100)
} else {
    $chargePercent = -1
}

# --- Determine charging status ---
# WMI BatteryStatus: 1=Discharging, 2=AC connected, 3=Fully Charged,
# 4=Low, 5=Critical, 6=Charging, 7=Charging+High, 8=Charging+Low,
# 9=Charging+Critical, 10=Undefined, 11=Partially Charged
$isCharging = $false
$isPluggedIn = $false
$isFullyCharged = $false

if ($wmiBattery) {
    $batteryStatus = $wmiBattery.BatteryStatus
    $isCharging  = $batteryStatus -in @(2, 6, 7, 8, 9)
    $isPluggedIn = $batteryStatus -in @(2, 3, 6, 7, 8, 9, 11)
    $isFullyCharged = $batteryStatus -eq 3
}

if ($dotnetPower) {
    if ($dotnetPower.PowerLineStatus -eq 'Online') {
        $isPluggedIn = $true
    }
    if (([int]$dotnetPower.BatteryChargeStatus -band 8) -eq 8) {
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
    # Discharging: get estimated run time
    if ($wmiBattery -and $wmiBattery.EstimatedRunTime -and $wmiBattery.EstimatedRunTime -ne 71582788) {
        $timeMinutes = [int]$wmiBattery.EstimatedRunTime
    } elseif ($dotnetPower -and $dotnetPower.BatteryLifeRemaining -gt 0) {
        $timeMinutes = [math]::Round($dotnetPower.BatteryLifeRemaining / 60)
    }
} elseif ($isCharging) {
    # Charging: get time to full
    if ($wmiBattery -and $wmiBattery.TimeToFullCharge -and $wmiBattery.TimeToFullCharge -ne 0) {
        $timeMinutes = [int]$wmiBattery.TimeToFullCharge
    }
}

# --- Format time as hours and minutes ---
if ($timeMinutes -gt 0) {
    $hours   = [math]::Floor($timeMinutes / 60)
    $minutes = $timeMinutes % 60

    if ($hours -gt 0 -and $minutes -gt 0) {
        $hourLabel   = if ($hours -ne 1) { "hours" } else { "hour" }
        $minuteLabel = if ($minutes -ne 1) { "minutes" } else { "minute" }
        $timeString  = "$hours $hourLabel $minutes $minuteLabel"
    } elseif ($hours -gt 0) {
        $hourLabel  = if ($hours -ne 1) { "hours" } else { "hour" }
        $timeString = "$hours $hourLabel"
    } else {
        $minuteLabel = if ($minutes -ne 1) { "minutes" } else { "minute" }
        $timeString  = "$minutes $minuteLabel"
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
$batteryBar = "    [$bar] $chargePercent%"

# --- Determine status text and color ---
if ($isFullyCharged) {
    $statusText  = "Fully Charged"
    $statusColor = "Green"
} elseif ($isCharging) {
    $statusText  = "Charging"
    $statusColor = "Yellow"
} elseif ($chargePercent -le 10) {
    $statusText  = "Critical"
    $statusColor = "Red"
} elseif ($chargePercent -le 20) {
    $statusText  = "Low"
    $statusColor = "DarkYellow"
} else {
    $statusText  = "Discharging"
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
Write-Host "    Battery Level:    " -NoNewline; Write-Host "$chargePercent%" -ForegroundColor $statusColor
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
if ($chargePercent -le 10 -and -not $isCharging -and -not $isPluggedIn) {
    Write-Host "    WARNING: Battery critically low! Plug in immediately." -ForegroundColor Red
    Write-Host ""
} elseif ($chargePercent -le 20 -and -not $isCharging -and -not $isPluggedIn) {
    Write-Host "    Battery is low. Consider plugging in." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  $separator" -ForegroundColor DarkGray
Write-Host ""
