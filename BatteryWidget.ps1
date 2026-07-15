#Requires -Version 5.0

<#
.SYNOPSIS
    Battery Widget - System tray battery monitor with floating desktop bar.
.DESCRIPTION
    Displays a battery icon in the Windows notification area (system tray)
    and a floating draggable bar on the desktop showing time remaining and
    battery percentage. Hover over the pill (500ms) to see a detailed popup with
    capacity, discharge rate, ETA, elapsed time, and battery wear.
    Auto-refreshes every 3 seconds with EMA-smoothed estimates.
.EXAMPLE
    powershell -STA -File .\BatteryWidget.ps1
#>

# --- Load assemblies ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing


# P/Invoke for proper icon handle cleanup, DPI awareness, and fullscreen detection
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Icon {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public extern static bool DestroyIcon(IntPtr handle);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    // CS_DROPSHADOW support for popup elevation
    [DllImport("user32.dll", EntryPoint = "GetClassLong")]
    private static extern int GetClassLong32(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "GetClassLongPtr")]
    private static extern IntPtr GetClassLong64(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetClassLong")]
    private static extern int SetClassLong32(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", EntryPoint = "SetClassLongPtr")]
    private static extern IntPtr SetClassLong64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    public static void EnableDropShadow(IntPtr hWnd) {
        const int GCL_STYLE = -26;
        const int CS_DROPSHADOW = 0x00020000;
        if (IntPtr.Size == 8) {
            long style = GetClassLong64(hWnd, GCL_STYLE).ToInt64();
            SetClassLong64(hWnd, GCL_STYLE, new IntPtr(style | CS_DROPSHADOW));
        } else {
            int style = GetClassLong32(hWnd, GCL_STYLE);
            SetClassLong32(hWnd, GCL_STYLE, style | CS_DROPSHADOW);
        }
    }

    // Dark title bar for standard (chromed) windows so they don't clash with a dark body
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public static void UseDarkTitleBar(IntPtr hWnd) {
        int useDark = 1;
        // DWMWA_USE_IMMERSIVE_DARK_MODE = 20 on Win10 2004+/Win11; older builds used 19
        if (DwmSetWindowAttribute(hWnd, 20, ref useDark, 4) != 0) {
            DwmSetWindowAttribute(hWnd, 19, ref useDark, 4);
        }
    }
}
"@

# Declare DPI awareness before any forms are created
[Win32Icon]::SetProcessDPIAware() | Out-Null

# --- Single-instance guard ---
$script:mutexName = "Global\BatteryWidgetSingleInstance"
$script:createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, $script:mutexName, [ref]$script:createdNew)

if (-not $script:createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
        "Battery Widget is already running.",
        "Battery Widget",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit
}

# --- Theme color references ---
$script:theme = @{
    PillBg       = [System.Drawing.Color]::FromArgb(24, 24, 28)
    PopupBg      = [System.Drawing.Color]::FromArgb(26, 26, 30)
    TextPrimary  = [System.Drawing.Color]::FromArgb(245, 245, 250)
    TextDim      = [System.Drawing.Color]::FromArgb(145, 145, 155)
    TextLight    = [System.Drawing.Color]::FromArgb(220, 220, 225)
    TextMuted    = [System.Drawing.Color]::FromArgb(80, 80, 86)
    Border       = [System.Drawing.Color]::FromArgb(50, 50, 56)
    SettingsBg   = [System.Drawing.Color]::FromArgb(32, 32, 36)
    TrackBg      = [System.Drawing.Color]::FromArgb(40, 40, 46)
    SparkBg      = [System.Drawing.Color]::FromArgb(20, 20, 24)
    SparkGuide   = [System.Drawing.Color]::FromArgb(255, 255, 255)
}

$script:appVersion = "1.0.0"

function Get-SystemTheme {
    try {
        $regPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        $val = Get-ItemPropertyValue -Path $regPath -Name "AppsUseLightTheme" -ErrorAction Stop
        return ($val -eq 1)  # $true = light theme
    } catch {
        return $false  # default to dark
    }
}

function Apply-Theme {
    $useDark = $true
    $themeSetting = $script:config.Theme
    if ($themeSetting -eq "light") { $useDark = $false }
    elseif ($themeSetting -eq "auto") { $useDark = -not (Get-SystemTheme) }

    if ($useDark) {
        $script:theme.PillBg       = [System.Drawing.Color]::FromArgb(24, 24, 28)
        $script:theme.PopupBg      = [System.Drawing.Color]::FromArgb(26, 26, 30)
        $script:theme.TextPrimary  = [System.Drawing.Color]::FromArgb(245, 245, 250)
        $script:theme.TextDim      = [System.Drawing.Color]::FromArgb(145, 145, 155)
        $script:theme.TextLight    = [System.Drawing.Color]::FromArgb(220, 220, 225)
        $script:theme.TextMuted    = [System.Drawing.Color]::FromArgb(80, 80, 86)
        $script:theme.Border       = [System.Drawing.Color]::FromArgb(50, 50, 56)
        $script:theme.SettingsBg   = [System.Drawing.Color]::FromArgb(32, 32, 36)
        $script:theme.TrackBg      = [System.Drawing.Color]::FromArgb(40, 40, 46)
        $script:theme.SparkBg      = [System.Drawing.Color]::FromArgb(20, 20, 24)
        $script:theme.SparkGuide   = [System.Drawing.Color]::FromArgb(255, 255, 255)
    } else {
        $script:theme.PillBg       = [System.Drawing.Color]::FromArgb(242, 242, 247)
        $script:theme.PopupBg      = [System.Drawing.Color]::FromArgb(248, 248, 252)
        $script:theme.TextPrimary  = [System.Drawing.Color]::FromArgb(28, 28, 30)
        $script:theme.TextDim      = [System.Drawing.Color]::FromArgb(100, 100, 110)
        $script:theme.TextLight    = [System.Drawing.Color]::FromArgb(50, 50, 55)
        $script:theme.TextMuted    = [System.Drawing.Color]::FromArgb(170, 170, 180)
        $script:theme.Border       = [System.Drawing.Color]::FromArgb(200, 200, 210)
        $script:theme.SettingsBg   = [System.Drawing.Color]::FromArgb(235, 235, 240)
        $script:theme.TrackBg      = [System.Drawing.Color]::FromArgb(215, 215, 220)
        $script:theme.SparkBg      = [System.Drawing.Color]::FromArgb(232, 232, 238)
        $script:theme.SparkGuide   = [System.Drawing.Color]::FromArgb(60, 60, 68)
    }

    # Refresh cached brushes for new theme
    Initialize-PillBrushes

    # Apply to floating bar immediately
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $script:floatingBar.BackColor = $script:theme.PillBg
        $script:floatingBar.Invalidate()
    }
}

# --- Fullscreen detection state ---
$script:isFullscreenHidden = $false

function Test-FullscreenApp {
    try {
        $hwnd = [Win32Icon]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $false }
        $rect = New-Object Win32Icon+RECT
        [Win32Icon]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
        # Check if foreground window covers any screen entirely
        foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
            $b = $scr.Bounds
            if ($rect.Left -le $b.Left -and $rect.Top -le $b.Top -and
                $rect.Right -ge $b.Right -and $rect.Bottom -ge $b.Bottom) {
                return $true
            }
        }
        return $false
    } catch {
        return $false
    }
}

# --- Elapsed time tracking state ---
$script:lastStateChange = @{
    Time    = Get-Date
    Percent = -1
    State   = ""
}

# --- EMA smoothing state for stable battery estimates ---
$script:emaRate = -1           # Smoothed rate (mW) using Exponential Moving Average
$script:lastValidRate = -1     # Last known good rate (for "hold" logic when rate unavailable)
$script:lastValidRateTime = $null  # Timestamp when lastValidRate was set (for stale expiry)
$script:rateHistory = New-Object System.Collections.ArrayList  # Last 10 raw rates (for adaptive alpha)
$script:lastCapacityCheck = $null  # @{ Time; Capacity } for capacity-derived rate cross-validation
$script:capacityRateMismatchCount = 0  # Consecutive divergence count for cross-validation

# --- Battery history for sparkline (last 2 hours) ---
$script:batteryHistory = New-Object System.Collections.ArrayList

# --- Hysteresis state for AC state transitions ---
$script:lastAcState = $null    # Previous AC plugged-in state
$script:stateChangeTime = $null # Timestamp of last AC state change
$script:hysteresisSeconds = 2  # Dead time after AC plug/unplug to ignore rate spikes

# ============================================================
# BATTERY DATA COLLECTION
# ============================================================

function Get-BatteryInfo {
    param([Parameter(Mandatory=$false)][object]$Now = $null)
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

    # WMI primary source
    try {
        $wmiBattery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop
    } catch {
        $wmiBattery = $null
    }

    # .NET fallback source
    $dotnetPower = [System.Windows.Forms.SystemInformation]::PowerStatus

    # No battery detection
    if ($null -eq $wmiBattery) {
        if ($null -eq $dotnetPower -or ([int]$dotnetPower.BatteryChargeStatus -band 128) -eq 128) {
            $info.NoBattery = $true
            $info.StatusText = "No Battery"
            $info.TimeString = "N/A"
            $info.PowerSource = "AC Power"
            return $info
        }
    }

    # Charge percentage
    if ($wmiBattery) {
        $info.Percent = [int]$wmiBattery.EstimatedChargeRemaining
        $info.PercentExact = [double]$wmiBattery.EstimatedChargeRemaining
    } elseif ($dotnetPower) {
        $info.PercentExact = [math]::Round($dotnetPower.BatteryLifePercent * 100, 1)
        $info.Percent = [int]$info.PercentExact
    }

    # Charging status from WMI
    if ($wmiBattery) {
        $batteryStatus = $wmiBattery.BatteryStatus
        $info.IsCharging  = $batteryStatus -in @(2, 6, 7, 8, 9)
        $info.IsPluggedIn = $batteryStatus -in @(2, 3, 6, 7, 8, 9, 11)
        $info.IsFullyCharged = $batteryStatus -eq 3
    }

    # .NET cross-validation
    if ($dotnetPower) {
        if ($dotnetPower.PowerLineStatus -eq 'Online') {
            $info.IsPluggedIn = $true
        }
        if (([int]$dotnetPower.BatteryChargeStatus -band 8) -eq 8) {
            $info.IsCharging = $true
        }
    }

    if ($info.Percent -ge 100 -and $info.IsPluggedIn) {
        $info.IsFullyCharged = $true
        $info.IsCharging = $false
    }

    # --- Extended WMI data (capacity, rates, wear) ---
    if ($wmiBattery) {
        try {
            if ($wmiBattery.DesignCapacity -and $wmiBattery.DesignCapacity -gt 0) {
                $info.DesignCapacity = [int]$wmiBattery.DesignCapacity
            }
        } catch {}

        try {
            if ($wmiBattery.FullChargeCapacity -and $wmiBattery.FullChargeCapacity -gt 0) {
                $info.FullChargeCapacity = [int]$wmiBattery.FullChargeCapacity
            }
        } catch {}

        try {
            if ($null -ne $wmiBattery.DischargeRate -and $wmiBattery.DischargeRate -gt 0 -and $wmiBattery.DischargeRate -lt 4294967295) {
                $info.DischargeRate = [int]$wmiBattery.DischargeRate
            }
        } catch {}

        try {
            if ($null -ne $wmiBattery.ChargeRate -and $wmiBattery.ChargeRate -gt 0 -and $wmiBattery.ChargeRate -lt 4294967295) {
                $info.ChargeRate = [int]$wmiBattery.ChargeRate
            }
        } catch {}

        # Full runtime from WMI
        try {
            if ($wmiBattery.EstimatedRunTime -and $wmiBattery.EstimatedRunTime -ne 71582788 -and $wmiBattery.EstimatedRunTime -gt 0) {
                $info.FullRuntimeMinutes = [int]$wmiBattery.EstimatedRunTime
            }
        } catch {}
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
                if ($wmiBattery -and $wmiBattery.EstimatedRunTime -and $wmiBattery.EstimatedRunTime -ne 71582788) {
                    $timeMinutes = [int]$wmiBattery.EstimatedRunTime
                } elseif ($dotnetPower -and $dotnetPower.BatteryLifeRemaining -gt 0) {
                    $timeMinutes = [math]::Round($dotnetPower.BatteryLifeRemaining / 60)
                }
            } elseif ($info.IsCharging) {
                if ($wmiBattery -and $wmiBattery.TimeToFullCharge -and $wmiBattery.TimeToFullCharge -ne 0) {
                    $timeMinutes = [int]$wmiBattery.TimeToFullCharge
                }
            }
        }
    }
    $info.TimeMinutes = $timeMinutes

    # Format time string
    if ($timeMinutes -gt 0) {
        $hours   = [math]::Floor($timeMinutes / 60)
        $minutes = $timeMinutes % 60
        if ($hours -gt 0 -and $minutes -gt 0) {
            $hourLabel   = if ($hours -ne 1) { "hours" } else { "hour" }
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

    # ETA
    if ($timeMinutes -gt 0) {
        $eta = $Now.AddMinutes($timeMinutes)
        $info.ETA = $eta.ToString("h:mm tt")
    }

    # Status text
    if ($info.IsFullyCharged) {
        $info.StatusText = "Fully Charged"
    } elseif ($info.IsCharging) {
        $info.StatusText = "Charging"
    } elseif ($info.Percent -le 10) {
        $info.StatusText = "Critical"
    } elseif ($info.Percent -le 20) {
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

    $elapsed = $Now - $script:lastStateChange.Time
    $elapsedHours = [math]::Floor($elapsed.TotalHours)
    $elapsedMins  = $elapsed.Minutes
    $info.ElapsedTime = "{0}:{1:D2}" -f $elapsedHours, $elapsedMins
    $info.ElapsedSince = "$($script:lastStateChange.Percent)%"

    return $info
}

# ============================================================
# EMA SMOOTHING FOR DISCHARGE RATE
# ============================================================

function Update-EMARate {
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
    param([int]$FullChargeCapacity, [double]$PercentExact, [object]$Now = $null)
    if ($null -eq $Now) { $Now = Get-Date }
    $currentCapacity = $FullChargeCapacity * ($PercentExact / 100)

    if ($null -eq $script:lastCapacityCheck) {
        $script:lastCapacityCheck = @{ Time = $now; Capacity = $currentCapacity }
        return -1
    }

    $elapsed = ($now - $script:lastCapacityCheck.Time).TotalHours
    if ($elapsed -lt 0.0083) { return -1 }  # need at least 30 seconds

    $capDelta = $script:lastCapacityCheck.Capacity - $currentCapacity  # mWh consumed
    $derivedRate = [int]($capDelta / $elapsed)  # mW

    $script:lastCapacityCheck.Time = $Now
    $script:lastCapacityCheck.Capacity = $currentCapacity
    if ($derivedRate -gt 0) { return $derivedRate }
    return -1
}

function Get-SmoothedTimeRemaining {
    param(
        [int]$RawRate,
        [int]$FullChargeCapacity,
        [double]$PercentExact,
        [bool]$IsCharging,
        [bool]$IsPluggedIn,
        [object]$Now = $null
    )
    if ($null -eq $Now) { $Now = Get-Date }

    # --- Hysteresis: detect and handle AC state transitions ---
    if ($null -ne $script:lastAcState -and $script:lastAcState -ne $IsPluggedIn) {
        # AC state just changed — start hysteresis window
        $script:stateChangeTime = $Now
        # Reset EMA on state change to avoid polluting new state with old rate
        $script:emaRate = -1
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

# ============================================================
# HELPER: POWER PLAN MANAGEMENT
# ============================================================

function Get-PowerPlans {
    try {
        $output = & powercfg /list 2>&1
        if ($LASTEXITCODE -ne 0) { return @() }
        $result = @()
        foreach ($line in $output) {
            if ($line -match 'GUID:\s+(\S+)\s+\((.+?)\)(\s+\*)?') {
                $result += @{
                    Name     = $Matches[2]
                    GUID     = $Matches[1]
                    IsActive = [bool]$Matches[3]
                }
            }
        }
        return $result
    } catch { return @() }
}

function Set-ActivePowerPlan {
    param([string]$PlanGUID)
    try {
        & powercfg /setactive $PlanGUID 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Update-PowerPlanMenu {
    param([System.Windows.Forms.ToolStripMenuItem]$MenuItem)
    $MenuItem.DropDownItems.Clear()
    $plans = Get-PowerPlans
    foreach ($plan in $plans) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($plan.Name)
        $item.Checked = $plan.IsActive
        $item.Tag = $plan.GUID
        $item.Add_Click({
            $guid = $this.Tag
            $ok = Set-ActivePowerPlan -PlanGUID $guid
            if (-not $ok) {
                Show-BatteryNotification -Message "Admin rights needed" -SubMessage "Cannot switch power plan without elevation"
            }
        })
        $MenuItem.DropDownItems.Add($item) | Out-Null
    }
    if ($plans.Count -eq 0) {
        $noItem = New-Object System.Windows.Forms.ToolStripMenuItem("Not available")
        $noItem.Enabled = $false
        $MenuItem.DropDownItems.Add($noItem) | Out-Null
    }
}

# ============================================================
# HELPER: STATUS COLOR & ACCENT COLOR
# ============================================================

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        "Fully Charged" { [System.Drawing.Color]::FromArgb(0, 200, 0) }
        "Charging"      { [System.Drawing.Color]::FromArgb(255, 200, 0) }
        "Critical"      { [System.Drawing.Color]::Red }
        "Low"           { [System.Drawing.Color]::Orange }
        "No Battery"    { [System.Drawing.Color]::Gray }
        default         { [System.Drawing.Color]::FromArgb(0, 180, 255) }
    }
}

# Accent color presets (index 0-7)
$script:accentPresets = @(
    [System.Drawing.Color]::FromArgb(45, 212, 100),   # 0: Green (default)
    [System.Drawing.Color]::FromArgb(60, 140, 255),   # 1: Blue
    [System.Drawing.Color]::FromArgb(160, 100, 255),  # 2: Purple
    [System.Drawing.Color]::FromArgb(0, 210, 210),    # 3: Cyan
    [System.Drawing.Color]::FromArgb(255, 105, 180),  # 4: Pink
    [System.Drawing.Color]::FromArgb(0, 180, 160),    # 5: Teal
    [System.Drawing.Color]::FromArgb(255, 160, 40),   # 6: Orange
    [System.Drawing.Color]::FromArgb(220, 220, 230)   # 7: White
)

function Get-AccentColor {
    param(
        [int]$Percent,
        [bool]$IsCharging
    )
    # Yellow when charging (any level)
    if ($IsCharging) {
        return [System.Drawing.Color]::FromArgb(255, 200, 0)
    }
    # Color-coded by battery level — warning colors always override
    if ($Percent -le 10) {
        return [System.Drawing.Color]::FromArgb(255, 70, 70)   # Red - critical
    }
    if ($Percent -le 20) {
        return [System.Drawing.Color]::FromArgb(255, 140, 0)   # Orange - low
    }
    if ($Percent -le 50) {
        return [System.Drawing.Color]::FromArgb(255, 200, 0)   # Yellow - medium
    }
    # Healthy (>50%) — use selected accent color preset
    $idx = 0
    if ($null -ne $script:config -and $null -ne $script:config.AccentColorIndex) {
        $idx = [math]::Max(0, [math]::Min(7, [int]$script:config.AccentColorIndex))
    }
    return $script:accentPresets[$idx]
}

function Get-BarBackColor {
    param([int]$Percent, [bool]$IsCharging)
    if ($IsCharging) {
        return [System.Drawing.Color]::FromArgb(40, 120, 40)
    }
    if ($Percent -le 10) { return [System.Drawing.Color]::FromArgb(180, 30, 30) }
    if ($Percent -le 20) { return [System.Drawing.Color]::FromArgb(200, 120, 0) }
    if ($Percent -le 50) { return [System.Drawing.Color]::FromArgb(160, 160, 0) }
    return [System.Drawing.Color]::FromArgb(30, 130, 30)
}

# ============================================================
# DYNAMIC TRAY ICON
# ============================================================

function New-BatteryIcon {
    param(
        [int]$Percent,
        [string]$Status
    )

    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # Pill dimensions (leave 1px margin for anti-aliasing)
    $pillX = 1
    $pillY = 4
    $pillW = 14
    $pillH = 8
    $radius = 3

    # Create rounded rectangle path
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($pillX, $pillY, $d, $d, 180, 90)
    $path.AddArc($pillX + $pillW - $d, $pillY, $d, $d, 270, 90)
    $path.AddArc($pillX + $pillW - $d, $pillY + $pillH - $d, $d, $d, 0, 90)
    $path.AddArc($pillX, $pillY + $pillH - $d, $d, $d, 90, 90)
    $path.CloseFigure()

    # Dark background fill (matches floating pill)
    $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(24, 24, 28))
    $g.FillPath($bgBrush, $path)
    $bgBrush.Dispose()

    # Accent fill (from left, proportional to percent)
    $pct = [math]::Max(0, [math]::Min(100, $Percent))
    $fillWidth = [math]::Max(0, [int](($pct / 100) * $pillW))
    if ($fillWidth -gt 0) {
        $oldClip = $g.Clip
        $g.SetClip($path)

        # Get accent color based on battery level and charging state
        $baseColor = Get-AccentColor -Percent $Percent -IsCharging ($Status -eq "Charging")
        $accentColor = [System.Drawing.Color]::FromArgb(180, $baseColor.R, $baseColor.G, $baseColor.B)

        $fillBrush = New-Object System.Drawing.SolidBrush($accentColor)
        $g.FillRectangle($fillBrush, $pillX, $pillY, $fillWidth, $pillH)
        $fillBrush.Dispose()

        $g.Clip = $oldClip
    }

    # Border (slightly brighter than pill for visibility at small size)
    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, 80, 86), 1)
    $g.DrawPath($borderPen, $path)
    $borderPen.Dispose()

    $path.Dispose()
    $g.Dispose()

    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $bmp.Dispose()

    return @{ Icon = $icon; Handle = $hIcon }
}

# ============================================================
# FLOATING BAR — POSITION PERSISTENCE
# ============================================================

function Get-ConfigPath {
    $dir = $PSScriptRoot
    if (-not $dir) { $dir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
    if (-not $dir) { $dir = $PWD.Path }
    return Join-Path $dir "BatteryWidget.config.json"
}

function Load-Config {
    $configPath = Get-ConfigPath
    $default = @{
        X = -1
        Y = -1
        Opacity = 0.85
        RefreshInterval = 3000
        PositionLocked = $false
        DisplayMode = "time"
        PillSize = "normal"
        Theme = "dark"
        AccentColorIndex = 0
        AutoHideFullscreen = $false
        FirstRunShown = $false
        BatteryHistory = @()
        EmaRate = -1
        LastValidRate = -1
        ConfigSavedAt = $null
    }
    if (Test-Path $configPath) {
        try {
            $json = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($null -ne $json.X -and $null -ne $json.Y) {
                $default.X = [int]$json.X
                $default.Y = [int]$json.Y
            }
            if ($null -ne $json.Opacity) {
                $default.Opacity = [math]::Max(0.3, [math]::Min(1.0, [double]$json.Opacity))
            }
            if ($null -ne $json.RefreshInterval) {
                $default.RefreshInterval = [int]$json.RefreshInterval
            }
            if ($null -ne $json.PositionLocked) {
                $default.PositionLocked = [bool]$json.PositionLocked
            }
            if ($null -ne $json.DisplayMode -and $json.DisplayMode -in @("time", "percent", "both")) {
                $default.DisplayMode = $json.DisplayMode
            }
            if ($null -ne $json.PillSize -and $json.PillSize -in @("compact", "normal", "expanded")) {
                $default.PillSize = $json.PillSize
            }
            if ($null -ne $json.Theme -and $json.Theme -in @("dark", "light", "auto")) {
                $default.Theme = $json.Theme
            }
            if ($null -ne $json.AccentColorIndex) {
                $default.AccentColorIndex = [math]::Max(0, [math]::Min(7, [int]$json.AccentColorIndex))
            }
            if ($null -ne $json.AutoHideFullscreen) {
                $default.AutoHideFullscreen = [bool]$json.AutoHideFullscreen
            }
            if ($null -ne $json.FirstRunShown) {
                $default.FirstRunShown = [bool]$json.FirstRunShown
            }
            # Load battery history from config
            if ($null -ne $json.BatteryHistory -and $json.BatteryHistory.Count -gt 0) {
                $loadedHistory = @()
                foreach ($entry in $json.BatteryHistory) {
                    try {
                        $loadedHistory += @{
                            Time       = [DateTime]::Parse($entry.Time)
                            Percent    = [int]$entry.Percent
                            IsCharging = [bool]$entry.IsCharging
                        }
                    } catch {}
                }
                $default.BatteryHistory = $loadedHistory
            }
            # Restore persisted EMA state (expire if config older than 10 minutes)
            if ($null -ne $json.EmaRate -and $null -ne $json.ConfigSavedAt) {
                try {
                    $savedAge = ((Get-Date) - [DateTime]::Parse($json.ConfigSavedAt)).TotalMinutes
                    if ($savedAge -lt 10) {
                        $default.EmaRate = [double]$json.EmaRate
                        $default.LastValidRate = [int]$json.LastValidRate
                    }
                } catch {}
            }
        } catch {}
    }
    return $default
}

function Save-Config {
    $configPath = Get-ConfigPath
    try {
        # Serialize last 200 history entries (timestamps as ISO8601)
        $historyToSave = @()
        if ($null -ne $script:batteryHistory -and $script:batteryHistory.Count -gt 0) {
            $startIdx = [math]::Max(0, $script:batteryHistory.Count - 200)
            for ($hi = $startIdx; $hi -lt $script:batteryHistory.Count; $hi++) {
                $h = $script:batteryHistory[$hi]
                $historyToSave += @{
                    Time       = $h.Time.ToString("o")
                    Percent    = $h.Percent
                    IsCharging = $h.IsCharging
                }
            }
        }
        @{
            X = $script:config.X
            Y = $script:config.Y
            Opacity = $script:config.Opacity
            RefreshInterval = $script:config.RefreshInterval
            PositionLocked = $script:config.PositionLocked
            DisplayMode = $script:config.DisplayMode
            PillSize = $script:config.PillSize
            Theme = $script:config.Theme
            AccentColorIndex = $script:config.AccentColorIndex
            AutoHideFullscreen = $script:config.AutoHideFullscreen
            FirstRunShown = $script:config.FirstRunShown
            BatteryHistory = $historyToSave
            EmaRate = $script:emaRate
            LastValidRate = $script:lastValidRate
            ConfigSavedAt = (Get-Date).ToString("o")
        } | ConvertTo-Json -Depth 3 | Set-Content $configPath -Force
    } catch {
        Show-BatteryNotification "Config Save Failed" "Settings may not persist"
    }
}

# ============================================================
# AUTO-START WITH WINDOWS
# ============================================================

function Get-ExePath {
    # Get the path of the current executable or script
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    $exePath = $process.MainModule.FileName
    # If running as script, use PowerShell with script path
    if ($exePath -like "*powershell*" -or $exePath -like "*pwsh*") {
        return $null  # Can't create shortcut for script mode
    }
    return $exePath
}

function Get-AutoStartEnabled {
    $startupPath = [Environment]::GetFolderPath('Startup')
    $shortcutPath = Join-Path $startupPath "BatteryPill.lnk"
    return (Test-Path $shortcutPath)
}

function Set-AutoStart {
    param([bool]$Enable)
    $startupPath = [Environment]::GetFolderPath('Startup')
    $shortcutPath = Join-Path $startupPath "BatteryPill.lnk"

    if ($Enable) {
        $exePath = Get-ExePath
        if ($null -eq $exePath) {
            [System.Windows.Forms.MessageBox]::Show(
                "Auto-start is only available when running the compiled .exe version.",
                "BatteryPill",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return $false
        }

        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $exePath
            $shortcut.WorkingDirectory = Split-Path $exePath
            $shortcut.Description = "BatteryPill - Battery Widget"
            $shortcut.Save()
            return $true
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to create startup shortcut: $_",
                "BatteryPill",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return $false
        }
    } else {
        if (Test-Path $shortcutPath) {
            try {
                Remove-Item $shortcutPath -Force
                return $true
            } catch {
                return $false
            }
        }
        return $true
    }
}

# ============================================================
# HELPER — DOUBLE BUFFERING
# ============================================================

function Enable-DoubleBuffering {
    param([System.Windows.Forms.Form]$Form)
    $Form.GetType().GetProperty("DoubleBuffered",
        [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    ).SetValue($Form, $true, $null)
}

# ============================================================
# CACHED GDI+ BRUSHES/PENS FOR PAINT HANDLER
# ============================================================

$script:pillBgBrush    = $null
$script:pillTextBrush  = $null
$script:pillBorderPen  = $null

function Initialize-PillBrushes {
    # Dispose old cached objects
    if ($null -ne $script:pillBgBrush)   { $script:pillBgBrush.Dispose() }
    if ($null -ne $script:pillTextBrush) { $script:pillTextBrush.Dispose() }
    if ($null -ne $script:pillBorderPen) { $script:pillBorderPen.Dispose() }
    # Create from current theme colors
    $script:pillBgBrush    = New-Object System.Drawing.SolidBrush($script:theme.PillBg)
    $script:pillTextBrush  = New-Object System.Drawing.SolidBrush($script:theme.TextPrimary)
    $script:pillBorderPen  = New-Object System.Drawing.Pen($script:theme.Border, 1)
}

# ============================================================
# FLOATING BAR — FORM
# ============================================================

function Get-PillDimensions {
    # Returns @{ Width, Height, FontSize } based on PillSize and DisplayMode
    $mode = $script:config.DisplayMode
    $size = $script:config.PillSize
    switch ($size) {
        "compact"  { return @{ Width = 80; Height = 28; FontSize = 9.0; FontSize2 = 0 } }
        "expanded" { return @{ Width = 140; Height = 42; FontSize = 10.2; FontSize2 = 7.5 } }
        default {
            # normal — grows if DisplayMode is "both"
            if ($mode -eq "both") {
                return @{ Width = 108; Height = 42; FontSize = 10.0; FontSize2 = 7.5 }
            }
            return @{ Width = 108; Height = 34; FontSize = 10.2; FontSize2 = 0 }
        }
    }
}

function Update-PillSize {
    # Rebuild pill dimensions and region without recreating the form
    if ($null -eq $script:floatingBar -or $script:floatingBar.IsDisposed) { return }
    $dims = Get-PillDimensions
    $sz = New-Object System.Drawing.Size($dims.Width, $dims.Height)
    $script:floatingBar.MinimumSize = New-Object System.Drawing.Size(0, 0)
    $script:floatingBar.MaximumSize = New-Object System.Drawing.Size(0, 0)
    $script:floatingBar.Size = $sz
    $script:floatingBar.MinimumSize = $sz
    $script:floatingBar.MaximumSize = $sz
    # Rebuild region — use pill radius capped at half height for fully rounded ends
    $script:pillRadius = [math]::Min(8, [int]($dims.Height / 2))
    $rd = $script:pillRadius * 2
    $rPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rPath.AddArc(0, 0, $rd, $rd, 180, 90)
    $rPath.AddArc($dims.Width - $rd - 1, 0, $rd, $rd, 270, 90)
    $rPath.AddArc($dims.Width - $rd - 1, $dims.Height - $rd - 1, $rd, $rd, 0, 90)
    $rPath.AddArc(0, $dims.Height - $rd - 1, $rd, $rd, 90, 90)
    $rPath.CloseFigure()
    $script:floatingBar.Region = New-Object System.Drawing.Region($rPath)
    $rPath.Dispose()
    # Update font
    if ($null -ne $script:pillFont) { $script:pillFont.Dispose() }
    $script:pillFont = New-Object System.Drawing.Font("Segoe UI Semibold", $dims.FontSize, [System.Drawing.FontStyle]::Bold)
    if ($dims.FontSize2 -gt 0) {
        if ($null -ne $script:pillFont2) { $script:pillFont2.Dispose() }
        $script:pillFont2 = New-Object System.Drawing.Font("Segoe UI", $dims.FontSize2, [System.Drawing.FontStyle]::Regular)
    }
    $script:floatingBar.Invalidate()
}

function Test-PositionOnScreen {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height)
    # Check if the center of the pill falls within any connected screen's working area
    $centerX = $X + [int]($Width / 2)
    $centerY = $Y + [int]($Height / 2)
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        if ($scr.WorkingArea.Contains($centerX, $centerY)) { return $true }
    }
    return $false
}

function New-FloatingBar {
    # Paint state — updated by Update-FloatingBar, read by Paint handler
    $script:barAccentColor = [System.Drawing.Color]::FromArgb(45, 212, 100)
    $script:barDisplayText = "..."
    $script:barDisplayPercent = 50
    $script:barIsCharging = $false

    # Pulse animation state for charging effect
    $script:pulseAlpha = 105
    $script:wasChargingLastUpdate = $false

    # Smooth color transition state
    $script:currentDisplayColor = [System.Drawing.Color]::FromArgb(45, 212, 100)
    $script:targetAccentColor = [System.Drawing.Color]::FromArgb(45, 212, 100)

    # Plug/unplug flash state
    $script:flashAlpha = 0
    $script:lastPluggedState = $null

    # Low battery warning state
    $script:lowBatPulseActive = $false
    $script:lowBatBorderAlpha = 0
    $script:lowBatBorderDir = 1
    $script:lowBatOpacityPulse = $false
    $script:lowBatShown15 = $false
    $script:lowBatShown10 = $false
    $script:lowBatShown5 = $false

    # Cached GDI objects for paint handler (avoid per-frame allocation)
    Initialize-PillBrushes
    $dims = Get-PillDimensions
    $script:pillFont = New-Object System.Drawing.Font("Segoe UI Semibold", $dims.FontSize, [System.Drawing.FontStyle]::Bold)
    $script:pillFont2 = $null
    if ($dims.FontSize2 -gt 0) {
        $script:pillFont2 = New-Object System.Drawing.Font("Segoe UI", $dims.FontSize2, [System.Drawing.FontStyle]::Regular)
    }
    $script:pillStringFormat = New-Object System.Drawing.StringFormat
    $script:pillStringFormat.Alignment = [System.Drawing.StringAlignment]::Center
    $script:pillStringFormat.LineAlignment = [System.Drawing.StringAlignment]::Center

    # Secondary display text for "both" mode
    $script:barDisplayText2 = ""

    # Hover popup state
    $script:hoverPopup = $null
    $script:hoverPopupVisible = $false
    $script:estimatingLabel = $null

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $pillSz = New-Object System.Drawing.Size($dims.Width, $dims.Height)
    $form.Size = $pillSz
    $form.MinimumSize = $pillSz
    $form.MaximumSize = $pillSz
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Opacity = $script:config.Opacity

    # Region-based clipping for rounded corners (no TransparencyKey = no purple fringe)
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $regionPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rd = 16
    $regionPath.AddArc(0, 0, $rd, $rd, 180, 90)
    $regionPath.AddArc($dims.Width - $rd - 1, 0, $rd, $rd, 270, 90)
    $regionPath.AddArc($dims.Width - $rd - 1, $dims.Height - $rd - 1, $rd, $rd, 0, 90)
    $regionPath.AddArc(0, $dims.Height - $rd - 1, $rd, $rd, 90, 90)
    $regionPath.CloseFigure()
    $form.Region = New-Object System.Drawing.Region($regionPath)
    $regionPath.Dispose()

    # Enable double-buffering to reduce flicker
    Enable-DoubleBuffering -Form $form

    # Custom paint — the entire pill is the battery: fill level + text
    $form.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $w = $sender.Width
        $h = $sender.Height
        $radius = if ($null -ne $script:pillRadius) { $script:pillRadius } else { 8 }

        # --- Rounded rectangle path (full pill), 1px inset from region ---
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = ($radius - 1) * 2
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc($w - $d - 1, 0, $d, $d, 270, 90)
        $path.AddArc($w - $d - 1, $h - $d - 1, $d, $d, 0, 90)
        $path.AddArc(0, $h - $d - 1, $d, $d, 90, 90)
        $path.CloseFigure()

        # --- Background (entire pill, theme-aware — cached brush) ---
        $g.FillPath($script:pillBgBrush, $path)

        # --- Battery charge fill (left-to-right, clipped to pill shape) ---
        $pct = [math]::Max(0, [math]::Min(100, $script:barDisplayPercent))
        $fillWidth = [math]::Max(0, [math]::Round(($pct / 100) * $w))
        if ($fillWidth -gt 0) {
            # Clip to the rounded pill shape
            $oldClip = $g.Clip
            $g.SetClip($path)

            # Semi-transparent accent gradient fill (left brighter, right slightly darker)
            # Use pulse alpha when charging for animated glow effect
            $ac = $script:barAccentColor
            $baseAlpha = if ($script:barIsCharging) { $script:pulseAlpha } else { 100 }
            $fillLeft  = [System.Drawing.Color]::FromArgb([math]::Min(255, $baseAlpha + 20), $ac.R, $ac.G, $ac.B)
            $fillRight = [System.Drawing.Color]::FromArgb([math]::Max(60, $baseAlpha - 20), $ac.R, $ac.G, $ac.B)
            $fillRect = New-Object System.Drawing.Rectangle(0, 0, [math]::Max(1, $fillWidth), $h)
            $fillBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $fillRect, $fillLeft, $fillRight,
                [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            $g.FillRectangle($fillBrush, $fillRect)
            $fillBrush.Dispose()

            $g.Clip = $oldClip
        }

        # --- Glass effect: convex top highlight band ---
        $oldClip2 = $g.Clip
        $g.SetClip($path)
        $topBandRect = New-Object System.Drawing.Rectangle(0, 0, $w, 6)
        $topBandBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $topBandRect,
            [System.Drawing.Color]::FromArgb(35, 255, 255, 255),
            [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
            [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
        $g.FillRectangle($topBandBrush, $topBandRect)
        $topBandBrush.Dispose()

        # --- Glass effect: bottom shadow band ---
        $botBandRect = New-Object System.Drawing.Rectangle(0, ($h - 4), $w, 4)
        $botBandBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $botBandRect,
            [System.Drawing.Color]::FromArgb(0, 0, 0, 0),
            [System.Drawing.Color]::FromArgb(20, 0, 0, 0),
            [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
        $g.FillRectangle($botBandBrush, $botBandRect)
        $botBandBrush.Dispose()

        # --- Glass effect: charge boundary glow ---
        if ($fillWidth -gt 2 -and $fillWidth -lt $w) {
            $glowX = $fillWidth - 2
            $glowRect = New-Object System.Drawing.Rectangle($glowX, 0, 5, $h)
            $ac2 = $script:barAccentColor
            $glowBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $glowRect,
                [System.Drawing.Color]::FromArgb(60, $ac2.R, $ac2.G, $ac2.B),
                [System.Drawing.Color]::FromArgb(0, $ac2.R, $ac2.G, $ac2.B),
                [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            $g.FillRectangle($glowBrush, $glowRect)
            $glowBrush.Dispose()
        }
        $g.Clip = $oldClip2

        # --- Text rendering (supports single-line and dual-line modes) ---
        if ($script:barDisplayText2 -and $script:barDisplayText2.Length -gt 0 -and $null -ne $script:pillFont2) {
            # Dual-line mode: top = accent-colored primary, bottom = dim secondary
            $ac3 = $script:barAccentColor
            $topBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, $ac3.R, $ac3.G, $ac3.B))
            $topRect = New-Object System.Drawing.RectangleF(0, 2, $w, ($h / 2))
            $g.DrawString($script:barDisplayText, $script:pillFont, $topBrush, $topRect, $script:pillStringFormat)
            $topBrush.Dispose()
            $botBrush = New-Object System.Drawing.SolidBrush($script:theme.TextDim)
            $botRect = New-Object System.Drawing.RectangleF(0, ($h / 2) - 2, $w, ($h / 2))
            $g.DrawString($script:barDisplayText2, $script:pillFont2, $botBrush, $botRect, $script:pillStringFormat)
            $botBrush.Dispose()
        } else {
            # Single-line mode (centered — cached brush)
            $textRect = New-Object System.Drawing.RectangleF(0, 0, $w, $h)
            $g.DrawString($script:barDisplayText, $script:pillFont, $script:pillTextBrush, $textRect, $script:pillStringFormat)
        }

        # --- Plug/unplug flash overlay (green tint on light theme, white on dark) ---
        if ($script:flashAlpha -gt 0) {
            $isLight = ($script:theme.PillBg.R -gt 128)
            if ($isLight) {
                $flashBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($script:flashAlpha, 45, 212, 100))
            } else {
                $flashBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($script:flashAlpha, 255, 255, 255))
            }
            $g.FillPath($flashBrush, $path)
            $flashBrush.Dispose()
        }

        # --- Low battery warning: pulsing red border at 15% ---
        if ($null -ne $script:lowBatBorderAlpha -and $script:lowBatBorderAlpha -gt 0) {
            $warnPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($script:lowBatBorderAlpha, 235, 85, 75), 2)
            $g.DrawPath($warnPen, $path)
            $warnPen.Dispose()
        } else {
            # --- Border (cached pen) ---
            $g.DrawPath($script:pillBorderPen, $path)
        }

        $path.Dispose()
    })

    # Hover timer for delayed popup (500ms)
    $script:hoverTimer = New-Object System.Windows.Forms.Timer
    $script:hoverTimer.Interval = 500
    $script:hoverTimer.Add_Tick({
        $script:hoverTimer.Stop()
        if (-not $script:hoverPopupVisible -and -not $script:floatingBar.ContextMenuStrip.Visible) {
            Show-HoverPopup
        }
    })

    # Dismiss check timer (100ms delay to allow moving to popup)
    $script:dismissTimer = New-Object System.Windows.Forms.Timer
    $script:dismissTimer.Interval = 100
    $script:dismissTimer.Add_Tick({
        # Check if mouse is over pill or popup
        $mousePos = [System.Windows.Forms.Cursor]::Position
        $overPill = $false
        $overPopup = $false

        if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed -and $script:floatingBar.Visible) {
            $pillRect = New-Object System.Drawing.Rectangle($script:floatingBar.Location, $script:floatingBar.Size)
            $pillRect.Inflate(10, 10)   # 10px grace area around pill
            $overPill = $pillRect.Contains($mousePos)
        }

        if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed -and $script:hoverPopup.Visible) {
            $popupRect = New-Object System.Drawing.Rectangle($script:hoverPopup.Location, $script:hoverPopup.Size)
            $popupRect.Inflate(10, 10)  # 10px grace area around popup
            $overPopup = $popupRect.Contains($mousePos)
        }

        if (-not $overPill -and -not $overPopup) {
            $script:dismissTimer.Stop()
            Close-HoverPopup
        }
    })

    # Mouse enter - start hover timer
    $form.Add_MouseEnter({
        if (-not $script:hoverPopupVisible -and -not $script:isDragging) {
            $script:hoverTimer.Start()
        }
    })

    # Mouse leave - stop timer, start dismiss check
    $form.Add_MouseLeave({
        $script:hoverTimer.Stop()
        if ($script:hoverPopupVisible) {
            $script:dismissTimer.Start()
        }
    })

    # Drag handling — track if mouse actually moved to distinguish click vs drag
    $script:isDragging = $false
    $script:didDrag = $false
    $script:dragOffset = New-Object System.Drawing.Point(0, 0)

    $dragDown = {
        param($sender, $e)
        if ($script:positionLocked) { return }
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:isDragging = $true
            $script:didDrag = $false
            $script:dragOffset = $e.Location
            $script:floatingBar.Cursor = [System.Windows.Forms.Cursors]::SizeAll
        }
    }
    $dragMove = {
        param($sender, $e)
        if ($script:isDragging) {
            $dx = [math]::Abs($e.X - $script:dragOffset.X)
            $dy = [math]::Abs($e.Y - $script:dragOffset.Y)
            if ($dx -gt 3 -or $dy -gt 3) {
                $script:didDrag = $true
                $newX = $script:floatingBar.Left + $e.X - $script:dragOffset.X
                $newY = $script:floatingBar.Top  + $e.Y - $script:dragOffset.Y

                # Snap-to-edge: magnetic snap within 15px of screen edge → 8px from edge
                $snapThreshold = 15
                $snapMargin = 8
                $cursorPos = [System.Windows.Forms.Cursor]::Position
                $screen = [System.Windows.Forms.Screen]::FromPoint($cursorPos).WorkingArea
                $barW = $script:floatingBar.Width
                $barH = $script:floatingBar.Height
                # Left edge
                if ([math]::Abs($newX - $screen.Left) -lt $snapThreshold) { $newX = $screen.Left + $snapMargin }
                # Right edge
                if ([math]::Abs(($newX + $barW) - $screen.Right) -lt $snapThreshold) { $newX = $screen.Right - $barW - $snapMargin }
                # Top edge
                if ([math]::Abs($newY - $screen.Top) -lt $snapThreshold) { $newY = $screen.Top + $snapMargin }
                # Bottom edge
                if ([math]::Abs(($newY + $barH) - $screen.Bottom) -lt $snapThreshold) { $newY = $screen.Bottom - $barH - $snapMargin }

                $script:floatingBar.Location = New-Object System.Drawing.Point($newX, $newY)
            }
        }
    }
    $dragUp = {
        param($sender, $e)
        if ($script:isDragging) {
            $script:isDragging = $false
            $script:floatingBar.Cursor = [System.Windows.Forms.Cursors]::Default
            if ($script:didDrag) {
                $script:config.X = $script:floatingBar.Left
                $script:config.Y = $script:floatingBar.Top
                Save-Config
            }
            # No click-to-popup — hover handles popup display
        }
    }

    # Apply drag/click events to form only (no label — everything is paint-drawn)
    $form.Add_MouseDown($dragDown)
    $form.Add_MouseMove($dragMove)
    $form.Add_MouseUp($dragUp)

    # Set position from config (validate against current screens)
    $useDefault = $true
    if ($script:config.X -ge 0 -and $script:config.Y -ge 0) {
        if (Test-PositionOnScreen -X $script:config.X -Y $script:config.Y -Width $form.Width -Height $form.Height) {
            $form.Location = New-Object System.Drawing.Point($script:config.X, $script:config.Y)
            $useDefault = $false
        }
    }
    if ($useDefault) {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Location = New-Object System.Drawing.Point(
            ($screen.Right - $form.Width - 10),
            ($screen.Bottom - $form.Height - 10)
        )
        $script:config.X = $form.Left
        $script:config.Y = $form.Top
    }

    return $form
}

function New-SparklinePanel {
    param([int]$Y, [System.Drawing.Color]$AccentColor)
    # Creates a 380x40 panel that draws battery history sparkline
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(20, $Y)
    $panel.Size = New-Object System.Drawing.Size(380, 40)
    $panel.BackColor = [System.Drawing.Color]::Transparent
    $panel.Tag = @{ AccentColor = $AccentColor }
    $panel.Add_Paint({
        param($sender, $e)
        $sg = $e.Graphics
        $sg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $sw = $sender.Width
        $sh = $sender.Height

        # Background (theme-aware)
        $bgBrush = New-Object System.Drawing.SolidBrush($script:theme.SparkBg)
        $sg.FillRectangle($bgBrush, 0, 0, $sw, $sh)
        $bgBrush.Dispose()

        # Border
        $bdrPen = New-Object System.Drawing.Pen($script:theme.Border, 1)
        $sg.DrawRectangle($bdrPen, 0, 0, $sw - 1, $sh - 1)
        $bdrPen.Dispose()

        $guide = $script:theme.SparkGuide

        $history = $script:batteryHistory
        if ($null -eq $history -or $history.Count -lt 2) {
            # Not enough data — show placeholder
            $noDataFont = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)
            $noDataBrush = New-Object System.Drawing.SolidBrush($script:theme.TextMuted)
            $sg.DrawString("Collecting history...", $noDataFont, $noDataBrush, 8, 12)
            $noDataBrush.Dispose(); $noDataFont.Dispose()
            return
        }

        $count = $history.Count
        $acColor = $sender.Tag.AccentColor

        # Draw charging background bands (green tinted regions)
        $chargeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(15, 45, 212, 100))
        for ($i = 0; $i -lt $count; $i++) {
            if ($history[$i].IsCharging) {
                $x1 = [int](($i / [math]::Max(1, $count - 1)) * $sw)
                $sg.FillRectangle($chargeBrush, $x1, 0, [math]::Max(2, [int]($sw / $count) + 1), $sh)
            }
        }
        $chargeBrush.Dispose()

        # Draw sparkline
        $linePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, $acColor.R, $acColor.G, $acColor.B), 1.5)
        $points = New-Object System.Drawing.PointF[] $count
        for ($i = 0; $i -lt $count; $i++) {
            $px = ($i / [math]::Max(1, $count - 1)) * $sw
            $py = $sh - (($history[$i].Percent / 100.0) * ($sh - 4)) - 2
            $points[$i] = New-Object System.Drawing.PointF($px, $py)
        }
        if ($count -ge 2) {
            $sg.DrawLines($linePen, $points)
        }
        $linePen.Dispose()

        # Current value dot at the end of the sparkline
        if ($count -ge 2) {
            $lastPt = $points[$count - 1]
            $dotBrush = New-Object System.Drawing.SolidBrush(
                [System.Drawing.Color]::FromArgb(255, $acColor.R, $acColor.G, $acColor.B))
            $sg.FillEllipse($dotBrush, $lastPt.X - 3, $lastPt.Y - 3, 6, 6)
            $dotBrush.Dispose()
        }

        # 50% dashed guide line
        $halfY = $sh - ((50.0 / 100.0) * ($sh - 4)) - 2
        $dashPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, $guide.R, $guide.G, $guide.B), 1)
        $dashPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $sg.DrawLine($dashPen, 0, [int]$halfY, $sw, [int]$halfY)
        $dashPen.Dispose()
        $guideFont = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Regular)
        $guideBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, $guide.R, $guide.G, $guide.B))
        $sg.DrawString("50%", $guideFont, $guideBrush, 2, [int]$halfY - 12)
        $guideBrush.Dispose()

        # Time range label (right edge)
        if ($count -ge 2) {
            $firstTime = $history[0].Time
            $lastTime = $history[$count - 1].Time
            $spanMin = [int](($lastTime - $firstTime).TotalMinutes)
            $spanText = if ($spanMin -ge 60) { "{0}h" -f [math]::Round($spanMin / 60.0, 1) } else { "{0} min" -f $spanMin }
            $spanSize = $sg.MeasureString($spanText, $guideFont)
            $spanBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, $guide.R, $guide.G, $guide.B))
            $sg.DrawString($spanText, $guideFont, $spanBrush, ($sw - $spanSize.Width - 2), ($sh - $spanSize.Height - 1))
            $spanBrush.Dispose()
        }
        $guideFont.Dispose()
    })
    return $panel
}

function New-BatteryPopupContent {
    param(
        [hashtable]$BatteryInfo,
        [System.Windows.Forms.Form]$Form,
        [int]$PopupWidth,
        [double]$DpiScale,
        [string]$CloseHintText
    )
    # Shared popup content builder — used by both hover and tray popups
    # Returns @{ TotalHeight; Fonts (array for disposal) }

    $statusColor = Get-StatusColor -Status $BatteryInfo.StatusText
    $lightGray = $script:theme.TextLight
    $dimGray   = $script:theme.TextDim
    $labelFont = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Regular)
    $valueFont = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Regular)
    # Hero fonts for top section (Time — the data users care about most)
    $heroValueFont = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Regular)

    # --- Title with percentage (e.g. "Discharging — 72%") ---
    if ($BatteryInfo.IsFullyCharged) {
        $titleText = "Fully Charged"
    } elseif ($BatteryInfo.IsCharging) {
        $titleText = "Charging"
    } elseif ($BatteryInfo.NoBattery) {
        $titleText = "No Battery"
    } else {
        $titleText = "Discharging"
    }
    if (-not $BatteryInfo.NoBattery -and $BatteryInfo.PercentExact -ge 0) {
        $titleText = "$titleText — $($BatteryInfo.PercentExact)%"
    }
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $titleText
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $script:theme.TextPrimary
    $titleLabel.Location = New-Object System.Drawing.Point(20, 10)
    $titleLabel.AutoSize = $true
    $titleLabel.MaximumSize = New-Object System.Drawing.Size(($PopupWidth - 40), 0)
    $Form.Controls.Add($titleLabel)

    # Separator line under title
    $sepLabel = New-Object System.Windows.Forms.Label
    $sepLabel.Location = New-Object System.Drawing.Point(20, 32)
    $sepLabel.Size = New-Object System.Drawing.Size(($PopupWidth - 40), 1)
    $sepLabel.BackColor = $script:theme.Border
    $Form.Controls.Add($sepLabel)

    # --- Row layout (DPI-aware) ---
    $rh = [int](18 * $DpiScale)
    $heroRh = [int](24 * $DpiScale)
    $lx = 20
    $lw = [int](74 * $DpiScale)
    $vx = $lx + $lw + [int](6 * $DpiScale)   # value column starts AFTER the label column so labels never collide with values at any DPI
    $vw = $PopupWidth - $vx - 20
    $y = [int](40 * $DpiScale)

    # Helper to add a label+value row (value right-aligned)
    function Add-PopupRow {
        param($TargetForm, $RowY, $Label, $Value, $LFont, $VFont, $DColor, $VColor, $RLx, $RVx, $RLw, $RVw, $RowHeight)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Label; $lbl.Font = $LFont; $lbl.ForeColor = $DColor
        $lbl.Location = New-Object System.Drawing.Point($RLx, $RowY)
        $lbl.AutoSize = $true; $lbl.MaximumSize = New-Object System.Drawing.Size($RLw, 0)
        $TargetForm.Controls.Add($lbl)
        $val = New-Object System.Windows.Forms.Label
        $val.Text = $Value; $val.Font = $VFont; $val.ForeColor = $VColor
        $val.Location = New-Object System.Drawing.Point($RVx, $RowY)
        $val.AutoSize = $false
        $val.Size = New-Object System.Drawing.Size($RVw, $RowHeight)
        $val.TextAlign = [System.Drawing.ContentAlignment]::TopRight
        $TargetForm.Controls.Add($val)
        return $val
    }

    # Row 1: Percent (highlighted)
    if (-not $BatteryInfo.NoBattery) {
        $pctText = "$($BatteryInfo.PercentExact)%"
        $null = Add-PopupRow -TargetForm $Form -RowY $y -Label "Percent:" -Value $pctText -LFont $labelFont -VFont $valueFont -DColor $script:theme.TextMuted -VColor $statusColor -RLx $lx -RVx $vx -RLw $lw -RVw $vw -RowHeight $rh
        $y += $rh
    }

    # Row 2: Capacity (hidden when N/A)
    if ($BatteryInfo.FullChargeCapacity -gt 0 -and $BatteryInfo.PercentExact -ge 0) {
        $currentCharge = [math]::Round($BatteryInfo.FullChargeCapacity * ($BatteryInfo.PercentExact / 100))
        $capText = "{0:N0} / {1:N0} mWh" -f $currentCharge, $BatteryInfo.FullChargeCapacity
    } elseif ($BatteryInfo.FullChargeCapacity -gt 0) {
        $capText = "{0:N0} mWh" -f $BatteryInfo.FullChargeCapacity
    } else {
        $capText = "N/A"
    }
    if ($capText -ne "N/A") {
        $null = Add-PopupRow -TargetForm $Form -RowY $y -Label "Capacity:" -Value $capText -LFont $labelFont -VFont $valueFont -DColor $script:theme.TextMuted -VColor $lightGray -RLx $lx -RVx $vx -RLw $lw -RVw $vw -RowHeight $rh
        $y += $rh
    }

    # Row 3: Discharge/Charge Rate (hidden when N/A)
    if ($BatteryInfo.IsCharging -and $BatteryInfo.ChargeRate -gt 0) {
        $rateText = "+{0:N0} mW" -f $BatteryInfo.ChargeRate
        $rateColor = [System.Drawing.Color]::FromArgb(45, 212, 100)
    } elseif (-not $BatteryInfo.IsCharging -and $BatteryInfo.DischargeRate -gt 0) {
        $rateText = "-{0:N0} mW" -f $BatteryInfo.DischargeRate
        $rateColor = $lightGray
    } else {
        $rateText = "N/A"
        $rateColor = $dimGray
    }
    if ($rateText -ne "N/A") {
        $null = Add-PopupRow -TargetForm $Form -RowY $y -Label "Rate:" -Value $rateText -LFont $labelFont -VFont $valueFont -DColor $script:theme.TextMuted -VColor $rateColor -RLx $lx -RVx $vx -RLw $lw -RVw $vw -RowHeight $rh
        $y += $rh
    }

    # Row 4: Time Remaining with ETA (hero row)
    if ($BatteryInfo.IsFullyCharged) {
        $timeText = "Fully Charged"
    } elseif ($BatteryInfo.TimeMinutes -gt 0) {
        $h = [math]::Floor($BatteryInfo.TimeMinutes / 60)
        $m = $BatteryInfo.TimeMinutes % 60
        $shortTime = "{0}h {1:D2}m" -f $h, $m
        if ($BatteryInfo.ETA) {
            $timeText = "$shortTime — ETA $($BatteryInfo.ETA)"
        } else {
            $timeText = $shortTime
        }
    } else {
        $timeText = "Estimating..."
    }
    $timeRowLabel = if ($BatteryInfo.IsCharging) { "To Full:" } else { "Remaining:" }
    # Spacer before time row
    $y += [int](4 * $DpiScale)
    $timeValLabel = Add-PopupRow -TargetForm $Form -RowY $y -Label $timeRowLabel -Value $timeText -LFont $labelFont -VFont $heroValueFont -DColor $dimGray -VColor $script:theme.TextPrimary -RLx $lx -RVx $vx -RLw $lw -RVw $vw -RowHeight $heroRh
    if ($timeText -eq "Estimating...") { $script:estimatingLabel = $timeValLabel }
    $y += $heroRh

    # Group gap (replaces separator line)
    $y += [int](6 * $DpiScale)

    # Row 5: Elapsed Time
    $elapsedText = "$($BatteryInfo.ElapsedTime) (from $($BatteryInfo.ElapsedSince))"
    $null = Add-PopupRow -TargetForm $Form -RowY $y -Label "Elapsed:" -Value $elapsedText -LFont $labelFont -VFont $valueFont -DColor $script:theme.TextMuted -VColor $lightGray -RLx $lx -RVx $vx -RLw $lw -RVw $vw -RowHeight $rh
    $y += $rh

    # Row 6: Full Runtime (hidden when N/A)
    if ($BatteryInfo.FullRuntimeMinutes -gt 0) {
        $frH = [math]::Floor($BatteryInfo.FullRuntimeMinutes / 60)
        $frM = $BatteryInfo.FullRuntimeMinutes % 60
        $fullRtText = "~{0}h {1:D2}m full" -f $frH, $frM
    } else {
        $fullRtText = "N/A"
    }
    if ($fullRtText -ne "N/A") {
        $null = Add-PopupRow -TargetForm $Form -RowY $y -Label "Runtime:" -Value $fullRtText -LFont $labelFont -VFont $valueFont -DColor $script:theme.TextMuted -VColor $lightGray -RLx $lx -RVx $vx -RLw $lw -RVw $vw -RowHeight $rh
        $y += $rh
    }

    # Row 7: Battery Wear (hidden when N/A)
    if ($BatteryInfo.BatteryWearPercent -ge 0 -and $BatteryInfo.DesignCapacity -gt 0) {
        $wearText = "{0:N1}%" -f $BatteryInfo.BatteryWearPercent
    } else {
        $wearText = "N/A"
    }
    if ($wearText -ne "N/A") {
        $null = Add-PopupRow -TargetForm $Form -RowY $y -Label "Wear:" -Value $wearText -LFont $labelFont -VFont $valueFont -DColor $script:theme.TextMuted -VColor $lightGray -RLx $lx -RVx $vx -RLw $lw -RVw $vw -RowHeight $rh
        $y += $rh
    }

    # Spacer before sparkline
    $y += [int](6 * $DpiScale)

    # Battery history sparkline (40px tall)
    $sparkAccent = Get-AccentColor -Percent $BatteryInfo.Percent -IsCharging $BatteryInfo.IsCharging
    $sparkPanel = New-SparklinePanel -Y $y -AccentColor $sparkAccent
    $sparkPanel.Size = New-Object System.Drawing.Size(($PopupWidth - 40), 40)
    $Form.Controls.Add($sparkPanel)
    $y += 40

    # Spacer after sparkline
    $y += [int](4 * $DpiScale)

    # Power source with icon
    $powerIcon = if ($BatteryInfo.IsPluggedIn) { [char]0x26A1 } else { [char]0x2022 }
    $powerLabel = New-Object System.Windows.Forms.Label
    $powerLabel.Text = "$powerIcon $($BatteryInfo.PowerSource)"
    $powerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Regular)
    $powerLabel.ForeColor = $dimGray
    $powerLabel.Location = New-Object System.Drawing.Point(20, $y)
    $powerLabel.AutoSize = $true
    $powerLabel.MaximumSize = New-Object System.Drawing.Size(($PopupWidth - 40), 0)
    $Form.Controls.Add($powerLabel)
    $y += 16

    # Close hint (skip when empty — hover popup passes "")
    if ($CloseHintText) {
        $hintLabel = New-Object System.Windows.Forms.Label
        $hintLabel.Text = $CloseHintText
        $hintLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Regular)
        $hintLabel.ForeColor = $script:theme.TextMuted
        $hintLabel.Location = New-Object System.Drawing.Point(20, $y)
        $hintLabel.AutoSize = $true
        $hintLabel.MaximumSize = New-Object System.Drawing.Size(($PopupWidth - 40), 0)
        $Form.Controls.Add($hintLabel)
    }

    $fontsToDispose = @($labelFont, $valueFont, $heroValueFont, $titleLabel.Font, $powerLabel.Font)
    if ($CloseHintText) { $fontsToDispose += $hintLabel.Font }
    return @{
        TotalHeight = $y + 8
        Fonts = $fontsToDispose
    }
}

function Show-BatteryNotification {
    param([string]$Message, [string]$SubMessage)
    # Custom dark-themed notification card — slides in from bottom-right, auto-dismiss 10s
    $gDs = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $nDs = $gDs.DpiX / 96.0
    $gDs.Dispose()
    $nW = [int](320 * $nDs); $nH = [int](100 * $nDs)

    $notif = New-Object System.Windows.Forms.Form
    $notif.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $notif.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $notif.Size = New-Object System.Drawing.Size($nW, $nH)
    $notif.TopMost = $true
    $notif.ShowInTaskbar = $false
    $notif.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
    $notif.Opacity = 0
    Enable-DoubleBuffering -Form $notif

    # 3C. Escape to dismiss
    $notif.KeyPreview = $true
    $notif.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $script:notifPhase = "out" } })

    # Position on same screen as pill (fallback to primary)
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $screen = [System.Windows.Forms.Screen]::FromPoint($script:floatingBar.Location).WorkingArea
    } else {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    }
    $notif.Location = New-Object System.Drawing.Point(($screen.Right - $nW - 10), ($screen.Bottom - 10))

    # Rounded region (DPI-scaled)
    $nr = 10; $nd = $nr * 2
    $nrW = $nW - 2; $nrH = $nH - 2
    $nPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $nPath.AddArc(0, 0, $nd, $nd, 180, 90)
    $nPath.AddArc($nrW, 0, $nd, $nd, 270, 90)
    $nPath.AddArc($nrW, $nrH, $nd, $nd, 0, 90)
    $nPath.AddArc(0, $nrH, $nd, $nd, 90, 90)
    $nPath.CloseFigure()
    $notif.Region = New-Object System.Drawing.Region($nPath)
    $nPath.Dispose()

    $notif.Add_Paint({
        param($sender, $e)
        $ng = $e.Graphics
        $ng.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $ng.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        # Red accent bar on left
        $accentBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 70, 70))
        $ng.FillRectangle($accentBrush, 0, 0, 4, $sender.Height)
        $accentBrush.Dispose()
        # Border
        $bPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $br = 10; $bd = $br * 2
        $brW = $sender.Width - 2; $brH = $sender.Height - 2
        $bPath.AddArc(0, 0, $bd, $bd, 180, 90)
        $bPath.AddArc($brW, 0, $bd, $bd, 270, 90)
        $bPath.AddArc($brW, $brH, $bd, $bd, 0, 90)
        $bPath.AddArc(0, $brH, $bd, $bd, 90, 90)
        $bPath.CloseFigure()
        $bPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, 255, 70, 70), 1)
        $ng.DrawPath($bPen, $bPath)
        $bPen.Dispose(); $bPath.Dispose()
    })

    # Title
    $nPad = [int](16 * $nDs)
    $nTitle = New-Object System.Windows.Forms.Label
    $nTitle.Text = $Message
    $nTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
    $nTitle.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
    $nTitle.Location = New-Object System.Drawing.Point($nPad, $nPad)
    $nTitle.AutoSize = $true
    $nTitle.MaximumSize = New-Object System.Drawing.Size(($nW - $nPad * 2), 0)
    $notif.Controls.Add($nTitle)

    # Sub-message
    $nSub = New-Object System.Windows.Forms.Label
    $nSub.Text = $SubMessage
    $nSub.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
    $nSub.ForeColor = $script:theme.TextLight
    $nSub.Location = New-Object System.Drawing.Point($nPad, [int](48 * $nDs))
    $nSub.AutoSize = $true
    $nSub.MaximumSize = New-Object System.Drawing.Size(($nW - $nPad * 2), 0)
    $notif.Controls.Add($nSub)

    # Click-to-dismiss on notification and its labels
    $dismissClick = { $script:notifPhase = "out" }
    $notif.Add_Click($dismissClick)
    $nTitle.Add_Click($dismissClick)
    $nSub.Add_Click($dismissClick)

    $notif.Show()

    # Slide-in with cubic ease-out, then auto-dismiss after 10s
    $script:notifSlideTarget = $screen.Bottom - $nH - 20
    $script:notifSlideStart = $notif.Top
    $script:notifAnimStart = Get-Date
    $script:notifAnimDuration = 300  # ms
    $script:notifPhase = "in"  # "in", "hold", "out"
    $script:notifHoldStart = $null
    $notifTimer = New-Object System.Windows.Forms.Timer
    $notifTimer.Interval = 16
    $notifTimer.Add_Tick({
        if ($null -eq $notif -or $notif.IsDisposed) { $notifTimer.Stop(); $notifTimer.Dispose(); return }
        if ($script:notifPhase -eq "in") {
            $elapsed = ((Get-Date) - $script:notifAnimStart).TotalMilliseconds
            $t = [math]::Min(1.0, $elapsed / $script:notifAnimDuration)
            # Cubic ease-out: 1 - (1 - t)^3
            $eased = 1.0 - [math]::Pow(1.0 - $t, 3)
            $notif.Opacity = $eased
            $startY = $script:notifSlideStart
            $targetY = $script:notifSlideTarget
            $notif.Top = [int]($startY + ($targetY - $startY) * $eased)
            if ($t -ge 1.0) {
                $notif.Opacity = 1.0
                $notif.Top = $targetY
                $script:notifPhase = "hold"
                $script:notifHoldStart = Get-Date
            }
        } elseif ($script:notifPhase -eq "hold") {
            if (((Get-Date) - $script:notifHoldStart).TotalSeconds -ge 10) {
                $script:notifPhase = "out"
            }
        } elseif ($script:notifPhase -eq "out") {
            $notif.Opacity -= 0.06
            if ($notif.Opacity -le 0) {
                $notifTimer.Stop(); $notifTimer.Dispose()
                $notif.Close(); $notif.Dispose()
            }
        }
    })
    $notifTimer.Start()
}

function Update-FloatingBar {
    param([hashtable]$BatteryInfo)

    if ($null -eq $script:floatingBar -or $script:floatingBar.IsDisposed) { return }

    # Update display text based on DisplayMode
    $timeStr = ""
    $pctStr = ""
    if ($BatteryInfo.NoBattery) {
        $timeStr = "N/A"
        $pctStr = "N/A"
    } elseif ($BatteryInfo.IsFullyCharged) {
        $timeStr = "Full"
        $pctStr = "100%"
    } elseif ($BatteryInfo.TimeMinutes -gt 0) {
        $h = [math]::Floor($BatteryInfo.TimeMinutes / 60)
        $m = $BatteryInfo.TimeMinutes % 60
        $timeStr = if ($h -gt 0) { "${h}h ${m}m" } else { "${m}m" }
        $pctStr = "$($BatteryInfo.Percent)%"
    } else {
        # Time unavailable — show percent if charging, dashes if discharging
        if ($BatteryInfo.IsCharging) {
            $timeStr = "$($BatteryInfo.Percent)%"
        } else {
            $timeStr = "--:--"
        }
        $pctStr = "$($BatteryInfo.Percent)%"
    }

    $displayMode = $script:config.DisplayMode
    switch ($displayMode) {
        "percent" {
            $script:barDisplayText = $pctStr
            $script:barDisplayText2 = ""
        }
        "both" {
            $script:barDisplayText = $pctStr
            $script:barDisplayText2 = $timeStr
        }
        default {
            # "time" mode (default)
            $script:barDisplayText = $timeStr
            $script:barDisplayText2 = ""
        }
    }

    # Update battery percent and charging state for the mini icon
    $script:barDisplayPercent = $BatteryInfo.Percent
    $script:barIsCharging = $BatteryInfo.IsCharging

    # Smooth pulse transition: reset alpha when charging starts
    if ($BatteryInfo.IsCharging -and -not $script:wasChargingLastUpdate) {
        $script:pulseAlpha = 105
    }
    $script:wasChargingLastUpdate = $BatteryInfo.IsCharging
    Update-PulseTimerState

    # Accent color — smooth lerp toward target (30% per tick ≈ 15s to converge)
    $script:targetAccentColor = Get-AccentColor -Percent $BatteryInfo.Percent -IsCharging $BatteryInfo.IsCharging
    $lerpFactor = 0.30
    $curR = $script:currentDisplayColor.R + ($script:targetAccentColor.R - $script:currentDisplayColor.R) * $lerpFactor
    $curG = $script:currentDisplayColor.G + ($script:targetAccentColor.G - $script:currentDisplayColor.G) * $lerpFactor
    $curB = $script:currentDisplayColor.B + ($script:targetAccentColor.B - $script:currentDisplayColor.B) * $lerpFactor
    $script:currentDisplayColor = [System.Drawing.Color]::FromArgb([int]$curR, [int]$curG, [int]$curB)
    $script:barAccentColor = $script:currentDisplayColor

    # Plug/unplug flash — detect AC state change
    if ($null -ne $script:lastPluggedState -and $script:lastPluggedState -ne $BatteryInfo.IsPluggedIn) {
        $script:flashAlpha = 180  # Start flash
        Update-PulseTimerState
    }
    $script:lastPluggedState = $BatteryInfo.IsPluggedIn

    # Low battery warning logic — show once per threshold per discharge cycle
    if ($BatteryInfo.IsPluggedIn -or $BatteryInfo.IsCharging) {
        # Reset warning flags when plugged in
        $script:lowBatShown15 = $false
        $script:lowBatShown10 = $false
        $script:lowBatShown5 = $false
        $script:lowBatPulseActive = $false
        $script:lowBatBorderAlpha = 0
        $script:lowBatOpacityPulse = $false
    } else {
        $pct = $BatteryInfo.Percent
        # 15% — pulsing red border
        if ($pct -le 15 -and $pct -gt 10) {
            $script:lowBatPulseActive = $true
            $script:lowBatOpacityPulse = $false
        }
        # 10% — opacity oscillation + border pulse
        if ($pct -le 10 -and $pct -gt 5) {
            $script:lowBatPulseActive = $true
            $script:lowBatOpacityPulse = $true
            if (-not $script:lowBatShown10) {
                $script:lowBatShown10 = $true
                Show-BatteryNotification -Message "Low Battery - $pct%" -SubMessage "Connect charger soon"
            }
        }
        # 5% — critical notification
        if ($pct -le 5 -and $pct -gt 0) {
            $script:lowBatPulseActive = $true
            $script:lowBatOpacityPulse = $true
            if (-not $script:lowBatShown5) {
                $script:lowBatShown5 = $true
                $timeLeft = if ($BatteryInfo.TimeMinutes -gt 0) { "$($BatteryInfo.TimeMinutes) min remaining" } else { "Very low battery" }
                Show-BatteryNotification -Message "Critical Battery - $pct%" -SubMessage $timeLeft
            }
        }
    }

    # Trigger repaint
    $script:floatingBar.Invalidate()
}

# ============================================================
# HOVER POPUP (NON-MODAL)
# ============================================================

function Get-EaseInOutCubic {
    param([double]$t)
    # Cubic ease-in-out: smooth acceleration then deceleration, $t in [0,1]
    if ($t -lt 0.5) { return 4.0 * $t * $t * $t }
    return 1.0 - [Math]::Pow(-2.0 * $t + 2.0, 3) / 2.0
}

function Close-HoverPopup {
    if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
        # Start eased fade-out (100ms duration)
        $script:fadeOutStart = (Get-Date).Ticks
        if ($null -eq $script:fadeOutTimer) {
            $script:fadeOutTimer = New-Object System.Windows.Forms.Timer
            $script:fadeOutTimer.Interval = 16
            $script:fadeOutTimer.Add_Tick({
                if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
                    $elapsed = ((Get-Date).Ticks - $script:fadeOutStart) / 10000.0  # ms
                    $t = [Math]::Min(1.0, $elapsed / 100.0)
                    $eased = Get-EaseInOutCubic -t $t
                    if ($t -ge 1.0) {
                        $script:fadeOutTimer.Stop()
                        $script:hoverPopup.Close()
                        $script:hoverPopup.Dispose()
                        $script:hoverPopup = $null
                        # Dispose popup fonts to prevent GDI+ handle leak
                        if ($null -ne $script:hoverPopupFonts) {
                            foreach ($f in $script:hoverPopupFonts) { if ($null -ne $f) { $f.Dispose() } }
                            $script:hoverPopupFonts = $null
                        }
                    } else {
                        $script:hoverPopup.Opacity = 1.0 - $eased
                    }
                } else {
                    $script:fadeOutTimer.Stop()
                }
            })
        }
        $script:fadeOutTimer.Start()
    } else {
        $script:hoverPopup = $null
    }
    $script:hoverPopupVisible = $false
    $script:estimatingLabel = $null
    # Stop fade-in if running
    if ($null -ne $script:fadeInTimer) { $script:fadeInTimer.Stop() }
}

function Show-HoverPopup {
    # Close any existing popup immediately (no fade when reopening)
    if ($null -ne $script:fadeOutTimer) { $script:fadeOutTimer.Stop() }
    if ($null -ne $script:fadeInTimer) { $script:fadeInTimer.Stop() }
    if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
        $script:hoverPopup.Close()
        $script:hoverPopup.Dispose()
        $script:hoverPopup = $null
        if ($null -ne $script:hoverPopupFonts) {
            foreach ($f in $script:hoverPopupFonts) { if ($null -ne $f) { $f.Dispose() } }
            $script:hoverPopupFonts = $null
        }
    }
    $script:hoverPopupVisible = $false

    $BatteryInfo = Get-BatteryInfo

    $popup = New-Object System.Windows.Forms.Form
    $popup.Text = "Battery Widget"
    $popup.Size = New-Object System.Drawing.Size(420, 400)
    $popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $popup.ShowInTaskbar = $false
    $popup.TopMost = $true
    $popup.BackColor = $script:theme.PopupBg
    $popup.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $popup.KeyPreview = $true
    Enable-DoubleBuffering -Form $popup
    # Enable CS_DROPSHADOW for popup elevation
    $popup.Add_HandleCreated({ [Win32Icon]::EnableDropShadow($popup.Handle) })

    # Rounded border
    $popup.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $r = 10; $rd2 = $r * 2
        $bw = $sender.Width - 1; $bh = $sender.Height - 1
        $borderPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $borderPath.AddArc(0, 0, $rd2, $rd2, 180, 90)
        $borderPath.AddArc($bw - $rd2, 0, $rd2, $rd2, 270, 90)
        $borderPath.AddArc($bw - $rd2, $bh - $rd2, $rd2, $rd2, 0, 90)
        $borderPath.AddArc(0, $bh - $rd2, $rd2, $rd2, 90, 90)
        $borderPath.CloseFigure()
        $borderPen = New-Object System.Drawing.Pen($script:theme.Border, 1)
        $g.DrawPath($borderPen, $borderPath)
        $borderPen.Dispose(); $borderPath.Dispose()
    })

    # DPI scale and popup width
    $gDpi = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $dpiScale = $gDpi.DpiX / 96.0
    $gDpi.Dispose()
    $popupW = [int](300 * $dpiScale)
    $popup.Size = New-Object System.Drawing.Size($popupW, 400)

    # Build shared content
    $content = New-BatteryPopupContent -BatteryInfo $BatteryInfo -Form $popup -PopupWidth $popupW -DpiScale $dpiScale -CloseHintText ""
    $script:hoverPopupFonts = $content.Fonts

    # Resize form to fit content
    $popup.ClientSize = New-Object System.Drawing.Size($popupW, $content.TotalHeight)

    # Set rounded region to clip corners
    $prd = 20; $pw = $popup.ClientSize.Width; $ph = $popup.ClientSize.Height
    $popupRegionPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $popupRegionPath.AddArc(0, 0, $prd, $prd, 180, 90)
    $popupRegionPath.AddArc($pw - $prd - 1, 0, $prd, $prd, 270, 90)
    $popupRegionPath.AddArc($pw - $prd - 1, $ph - $prd - 1, $prd, $prd, 0, 90)
    $popupRegionPath.AddArc(0, $ph - $prd - 1, $prd, $prd, 90, 90)
    $popupRegionPath.CloseFigure()
    $popup.Region = New-Object System.Drawing.Region($popupRegionPath)
    $popupRegionPath.Dispose()

    # Position near the floating pill (deferred — uses actual final size)
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $screen = [System.Windows.Forms.Screen]::FromPoint($script:floatingBar.Location).WorkingArea
    } else {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    }
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $barLoc = $script:floatingBar.Location
        $barSize = $script:floatingBar.Size
        $popX = $barLoc.X + ($barSize.Width / 2) - ($popup.Width / 2)
        $popY = $barLoc.Y - $popup.Height - 8
        if ($popY -lt $screen.Top) { $popY = $barLoc.Y + $barSize.Height + 8 }
        $popX = [math]::Max($screen.Left, [math]::Min($popX, $screen.Right - $popup.Width))
        $popY = [math]::Max($screen.Top, [math]::Min($popY, $screen.Bottom - $popup.Height))
        $popup.Location = New-Object System.Drawing.Point([int]$popX, [int]$popY)
    } else {
        $popup.Location = New-Object System.Drawing.Point(($screen.Right - $popup.Width - 10), ($screen.Bottom - $popup.Height - 10))
    }

    # Mouse leave/enter on popup — dismiss check
    $popup.Add_MouseLeave({ $script:dismissTimer.Start() })
    $popup.Add_MouseEnter({ $script:dismissTimer.Stop() })
    $popup.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Close-HoverPopup } })

    # Store reference and show with eased fade-in (150ms duration)
    $script:hoverPopup = $popup
    $script:hoverPopupVisible = $true
    if ($null -ne $script:fadeOutTimer) { $script:fadeOutTimer.Stop() }
    $popup.Opacity = 0
    $popup.Show()
    $script:fadeInStart = (Get-Date).Ticks
    if ($null -eq $script:fadeInTimer) {
        $script:fadeInTimer = New-Object System.Windows.Forms.Timer
        $script:fadeInTimer.Interval = 16
        $script:fadeInTimer.Add_Tick({
            if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
                $elapsed = ((Get-Date).Ticks - $script:fadeInStart) / 10000.0  # ms
                $t = [Math]::Min(1.0, $elapsed / 150.0)
                $eased = Get-EaseInOutCubic -t $t
                if ($t -ge 1.0) { $script:hoverPopup.Opacity = 1.0; $script:fadeInTimer.Stop() }
                else { $script:hoverPopup.Opacity = $eased }
            } else { $script:fadeInTimer.Stop() }
        })
    }
    $script:fadeInTimer.Start()
}

# ============================================================
# DETAIL POPUP WINDOW (MODAL - for tray icon click)
# ============================================================

function Show-BatteryPopup {
    param([hashtable]$BatteryInfo)

    $popup = New-Object System.Windows.Forms.Form
    $popup.Text = "Battery Widget"
    $popup.Size = New-Object System.Drawing.Size(420, 400)
    $popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $popup.ShowInTaskbar = $false
    $popup.TopMost = $true
    $popup.BackColor = $script:theme.PopupBg
    $popup.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $popup.KeyPreview = $true
    Enable-DoubleBuffering -Form $popup
    # Enable CS_DROPSHADOW for popup elevation
    $popup.Add_HandleCreated({ [Win32Icon]::EnableDropShadow($popup.Handle) })

    # Rounded border
    $popup.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $r = 10; $rd2 = $r * 2
        $bw = $sender.Width - 1; $bh = $sender.Height - 1
        $borderPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $borderPath.AddArc(0, 0, $rd2, $rd2, 180, 90)
        $borderPath.AddArc($bw - $rd2, 0, $rd2, $rd2, 270, 90)
        $borderPath.AddArc($bw - $rd2, $bh - $rd2, $rd2, $rd2, 0, 90)
        $borderPath.AddArc(0, $bh - $rd2, $rd2, $rd2, 90, 90)
        $borderPath.CloseFigure()
        $borderPen = New-Object System.Drawing.Pen($script:theme.Border, 1)
        $g.DrawPath($borderPen, $borderPath)
        $borderPen.Dispose(); $borderPath.Dispose()
    })

    # DPI scale and popup width
    $gDpi2 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $dpiScale = $gDpi2.DpiX / 96.0
    $gDpi2.Dispose()
    $popupW = [int](300 * $dpiScale)
    $popup.Size = New-Object System.Drawing.Size($popupW, 400)

    # Build shared content
    $content = New-BatteryPopupContent -BatteryInfo $BatteryInfo -Form $popup -PopupWidth $popupW -DpiScale $dpiScale -CloseHintText "Click outside or press Esc to close"

    # Resize form to fit content
    $popup.ClientSize = New-Object System.Drawing.Size($popupW, $content.TotalHeight)

    # Set rounded region to clip corners
    $prd = 20; $pw = $popup.ClientSize.Width; $ph = $popup.ClientSize.Height
    $popupRegionPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $popupRegionPath.AddArc(0, 0, $prd, $prd, 180, 90)
    $popupRegionPath.AddArc($pw - $prd - 1, 0, $prd, $prd, 270, 90)
    $popupRegionPath.AddArc($pw - $prd - 1, $ph - $prd - 1, $prd, $prd, 0, 90)
    $popupRegionPath.AddArc(0, $ph - $prd - 1, $prd, $prd, 90, 90)
    $popupRegionPath.CloseFigure()
    $popup.Region = New-Object System.Drawing.Region($popupRegionPath)
    $popupRegionPath.Dispose()

    # Position near the floating pill (deferred — uses actual final size)
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $screen = [System.Windows.Forms.Screen]::FromPoint($script:floatingBar.Location).WorkingArea
    } else {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    }
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $barLoc = $script:floatingBar.Location
        $barSize = $script:floatingBar.Size
        $popX = $barLoc.X + ($barSize.Width / 2) - ($popup.Width / 2)
        $popY = $barLoc.Y - $popup.Height - 8
        if ($popY -lt $screen.Top) { $popY = $barLoc.Y + $barSize.Height + 8 }
        $popX = [math]::Max($screen.Left, [math]::Min($popX, $screen.Right - $popup.Width))
        $popY = [math]::Max($screen.Top, [math]::Min($popY, $screen.Bottom - $popup.Height))
        $popup.Location = New-Object System.Drawing.Point([int]$popX, [int]$popY)
    } else {
        $popup.Location = New-Object System.Drawing.Point(($screen.Right - $popup.Width - 10), ($screen.Bottom - $popup.Height - 10))
    }

    # Close on deactivate or Escape
    $popup.Add_Deactivate({ $popup.Close() })
    $popup.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $popup.Close() } })

    $popup.ShowDialog() | Out-Null
    $script:estimatingLabel = $null
    # Dispose popup fonts to prevent GDI+ handle leak
    foreach ($f in $content.Fonts) { if ($null -ne $f) { $f.Dispose() } }
    $popup.Dispose()
}

# ============================================================
# SETTINGS PANEL
# ============================================================

function Set-DarkComboBox {
    # Apply owner-draw dark theme to a ComboBox
    param([System.Windows.Forms.ComboBox]$Combo)
    $Combo.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    $Combo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Combo.Add_DrawItem({
        param($sender, $e)
        if ($e.Index -lt 0) { return }
        $e.DrawBackground()
        $isSelected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -eq [System.Windows.Forms.DrawItemState]::Selected
        # Settings panel is always dark, so use fixed light-on-dark colors (theme text would be invisible in Light theme)
        $bgColor = if ($isSelected) { [System.Drawing.Color]::FromArgb(64, 64, 72) } else { [System.Drawing.Color]::FromArgb(50, 50, 56) }
        $fgColor = if ($isSelected) { [System.Drawing.Color]::FromArgb(245, 245, 250) } else { [System.Drawing.Color]::FromArgb(230, 230, 235) }
        $bgBrush = New-Object System.Drawing.SolidBrush($bgColor)
        $e.Graphics.FillRectangle($bgBrush, $e.Bounds)
        $bgBrush.Dispose()
        $text = $sender.Items[$e.Index].ToString()
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $sender.Font, $e.Bounds, $fgColor, [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter)
    })
}

function Show-FirstRunTooltip {
    if ($script:config.FirstRunShown) { return }
    $script:config.FirstRunShown = $true
    Save-Config

    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $ds = $g.DpiX / 96.0
    $g.Dispose()
    $ttW = [int](260 * $ds); $ttH = [int](110 * $ds)

    $script:firstRunTip = New-Object System.Windows.Forms.Form
    $script:firstRunTip.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $script:firstRunTip.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $script:firstRunTip.Size = New-Object System.Drawing.Size($ttW, $ttH)
    $script:firstRunTip.TopMost = $true
    $script:firstRunTip.ShowInTaskbar = $false
    $script:firstRunTip.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
    $script:firstRunTip.Opacity = 0
    Enable-DoubleBuffering -Form $script:firstRunTip

    # Rounded region
    $tr = 8; $td = $tr * 2
    $tPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tPath.AddArc(0, 0, $td, $td, 180, 90)
    $tPath.AddArc($ttW - $td - 2, 0, $td, $td, 270, 90)
    $tPath.AddArc($ttW - $td - 2, $ttH - $td - 2, $td, $td, 0, 90)
    $tPath.AddArc(0, $ttH - $td - 2, $td, $td, 90, 90)
    $tPath.CloseFigure()
    $script:firstRunTip.Region = New-Object System.Drawing.Region($tPath)
    $tPath.Dispose()

    $script:firstRunTip.Add_Paint({
        param($sender, $e)
        $tg = $e.Graphics
        $tg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $bPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $br = 8; $bd = $br * 2
        $bPath.AddArc(0, 0, $bd, $bd, 180, 90)
        $bPath.AddArc($sender.Width - $bd - 2, 0, $bd, $bd, 270, 90)
        $bPath.AddArc($sender.Width - $bd - 2, $sender.Height - $bd - 2, $bd, $bd, 0, 90)
        $bPath.AddArc(0, $sender.Height - $bd - 2, $bd, $bd, 90, 90)
        $bPath.CloseFigure()
        $bPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, 45, 212, 100), 1)
        $tg.DrawPath($bPen, $bPath)
        $bPen.Dispose(); $bPath.Dispose()
        # Green accent bar on left
        $acBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(45, 212, 100))
        $tg.FillRectangle($acBrush, 0, 0, 3, $sender.Height)
        $acBrush.Dispose()
    })

    $pad = [int](14 * $ds)
    $tips = @(
        "Hover over the pill for details"
        "Drag to move, snaps to screen edges"
        "Right-click for settings & options"
    )
    $script:firstRunFont = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)
    $ty = $pad
    foreach ($text in $tips) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "  $text"
        $lbl.UseMnemonic = $false  # render literal '&' (e.g. "settings & options") instead of eating it as an accelerator
        $lbl.Font = $script:firstRunFont
        $lbl.ForeColor = $script:theme.TextLight
        $lbl.Location = New-Object System.Drawing.Point($pad, $ty)
        $lbl.AutoSize = $true
        $lbl.MaximumSize = New-Object System.Drawing.Size(($ttW - $pad * 2), 0)
        $lbl.Add_Click({ $script:tipPhase = "out" })
        $script:firstRunTip.Controls.Add($lbl)
        $ty += [int](24 * $ds)
    }

    # Click to dismiss
    $script:firstRunTip.Add_Click({ $script:tipPhase = "out" })

    # Position near pill
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $barLoc = $script:floatingBar.Location
        $barSize = $script:floatingBar.Size
        $tipX = $barLoc.X + ($barSize.Width / 2) - ($ttW / 2)
        $tipY = $barLoc.Y - $ttH - 8
        $screen = [System.Windows.Forms.Screen]::FromPoint($barLoc).WorkingArea
        if ($tipY -lt $screen.Top) { $tipY = $barLoc.Y + $barSize.Height + 8 }
        $tipX = [math]::Max($screen.Left + 4, [math]::Min($tipX, $screen.Right - $ttW - 4))
        $tipY = [math]::Max($screen.Top + 4, [math]::Min($tipY, $screen.Bottom - $ttH - 4))
        $script:firstRunTip.Location = New-Object System.Drawing.Point([int]$tipX, [int]$tipY)
    }

    $script:firstRunTip.Show()

    # Fade in then auto-dismiss after 8s
    $script:tipPhase = "in"
    $script:tipAnimStart = Get-Date
    $script:tipHoldStart = $null
    $script:firstRunTimer = New-Object System.Windows.Forms.Timer
    $script:firstRunTimer.Interval = 16
    $script:firstRunTimer.Add_Tick({
        if ($null -eq $script:firstRunTip -or $script:firstRunTip.IsDisposed) {
            $script:firstRunTimer.Stop(); $script:firstRunTimer.Dispose(); return
        }
        if ($script:tipPhase -eq "in") {
            $elapsed = ((Get-Date) - $script:tipAnimStart).TotalMilliseconds
            $t = [math]::Min(1.0, $elapsed / 200)
            $script:firstRunTip.Opacity = $t
            if ($t -ge 1.0) { $script:tipPhase = "hold"; $script:tipHoldStart = Get-Date }
        } elseif ($script:tipPhase -eq "hold") {
            if (((Get-Date) - $script:tipHoldStart).TotalSeconds -ge 8) { $script:tipPhase = "out" }
        } elseif ($script:tipPhase -eq "out") {
            $script:firstRunTip.Opacity -= 0.08
            if ($script:firstRunTip.Opacity -le 0) {
                $script:firstRunTimer.Stop(); $script:firstRunTimer.Dispose()
                $script:firstRunFont.Dispose()
                $script:firstRunTip.Close(); $script:firstRunTip.Dispose()
            }
        }
    })
    $script:firstRunTimer.Start()
}

function Show-SettingsPanel {
    # Manual DPI scaling — WinForms AutoScaleMode doesn't work reliably with SetProcessDPIAware()
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $ds = $g.DpiX / 96.0
    $g.Dispose()

    $settings = New-Object System.Windows.Forms.Form
    $settings.Text = "BatteryPill Settings"
    $settings.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $settings.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $settings.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $settings.MaximizeBox = $false
    $settings.MinimizeBox = $false
    $settings.TopMost = $true
    $settings.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
    $settings.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $settings.Add_HandleCreated({ [Win32Icon]::UseDarkTitleBar($settings.Handle) })

    $labelFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $sectionFont = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $sectionColor = [System.Drawing.Color]::FromArgb(45, 212, 100)
    $m = [int](20 * $ds)
    $cw = [int](280 * $ds)
    $bh = [int](34 * $ds)
    $y = $m

    # Settings tooltips
    $settingsTooltip = New-Object System.Windows.Forms.ToolTip
    $settingsTooltip.InitialDelay = 400
    $settingsTooltip.ReshowDelay = 200
    $settings.Add_FormClosed({
        $settingsTooltip.Dispose()
        $labelFont.Dispose()
        $sectionFont.Dispose()
    })

    # --- Behavior section header ---
    $bhvSep = New-Object System.Windows.Forms.Label
    $bhvSep.Location = New-Object System.Drawing.Point($m, $y)
    $bhvSep.Size = New-Object System.Drawing.Size($cw, 1)
    $bhvSep.BackColor = $script:theme.Border
    $settings.Controls.Add($bhvSep)
    $y += [int](8 * $ds)
    $bhvHeader = New-Object System.Windows.Forms.Label
    $bhvHeader.Text = "B E H A V I O R"
    $bhvHeader.Font = $sectionFont
    $bhvHeader.ForeColor = $sectionColor
    $bhvHeader.Location = New-Object System.Drawing.Point($m, $y)
    $bhvHeader.AutoSize = $true
    $settings.Controls.Add($bhvHeader)
    $y += [int](24 * $ds)

    # Auto-start checkbox
    $autoStartCheck = New-Object System.Windows.Forms.CheckBox
    $autoStartCheck.Text = "Start with Windows"
    $autoStartCheck.Font = $labelFont
    $autoStartCheck.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $autoStartCheck.Location = New-Object System.Drawing.Point($m, $y)
    $autoStartCheck.AutoSize = $true
    $autoStartCheck.Checked = Get-AutoStartEnabled
    $autoStartCheck.Add_CheckedChanged({
        $result = Set-AutoStart -Enable $autoStartCheck.Checked
        if (-not $result) {
            $autoStartCheck.Checked = Get-AutoStartEnabled
        }
    })
    $settings.Controls.Add($autoStartCheck)
    $settingsTooltip.SetToolTip($autoStartCheck, "Automatically launch BatteryPill when Windows starts")
    $y += [int](30 * $ds)

    # Show floating pill checkbox
    $showBarCheck = New-Object System.Windows.Forms.CheckBox
    $showBarCheck.Text = "Show floating pill"
    $showBarCheck.Font = $labelFont
    $showBarCheck.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $showBarCheck.Location = New-Object System.Drawing.Point($m, $y)
    $showBarCheck.AutoSize = $true
    $showBarCheck.Checked = ($null -ne $script:floatingBar -and $script:floatingBar.Visible)
    $showBarCheck.Add_CheckedChanged({
        if ($showBarCheck.Checked) {
            $script:floatingBar.Show()
            $toggleBarItem.Text = "Hide Bar"
        } else {
            $script:floatingBar.Hide()
            $toggleBarItem.Text = "Show Bar"
        }
    })
    $settings.Controls.Add($showBarCheck)
    $settingsTooltip.SetToolTip($showBarCheck, "Show or hide the floating battery pill on your desktop")
    $y += [int](30 * $ds)

    # Lock position checkbox
    $lockPosCheck = New-Object System.Windows.Forms.CheckBox
    $lockPosCheck.Text = "Lock pill position"
    $lockPosCheck.Font = $labelFont
    $lockPosCheck.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $lockPosCheck.Location = New-Object System.Drawing.Point($m, $y)
    $lockPosCheck.AutoSize = $true
    $lockPosCheck.Checked = $script:positionLocked
    $lockPosCheck.Add_CheckedChanged({
        $script:positionLocked = $lockPosCheck.Checked
        $script:config.PositionLocked = $lockPosCheck.Checked
        Save-Config
    })
    $settings.Controls.Add($lockPosCheck)
    $settingsTooltip.SetToolTip($lockPosCheck, "Prevent accidental dragging of the pill")
    $y += [int](30 * $ds)

    # Auto-hide in fullscreen checkbox
    $autoHideCheck = New-Object System.Windows.Forms.CheckBox
    $autoHideCheck.Text = "Auto-hide in fullscreen"
    $autoHideCheck.Font = $labelFont
    $autoHideCheck.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $autoHideCheck.Location = New-Object System.Drawing.Point($m, $y)
    $autoHideCheck.AutoSize = $true
    $autoHideCheck.Checked = $script:config.AutoHideFullscreen
    $autoHideCheck.Add_CheckedChanged({
        $script:config.AutoHideFullscreen = $autoHideCheck.Checked
        Save-Config
    })
    $settings.Controls.Add($autoHideCheck)
    $settingsTooltip.SetToolTip($autoHideCheck, "Hide pill when fullscreen apps are active (games, videos)")
    $y += [int](46 * $ds)

    # --- Appearance section header ---
    $appSep = New-Object System.Windows.Forms.Label
    $appSep.Location = New-Object System.Drawing.Point($m, $y)
    $appSep.Size = New-Object System.Drawing.Size($cw, 1)
    $appSep.BackColor = $script:theme.Border
    $settings.Controls.Add($appSep)
    $y += [int](8 * $ds)
    $appHeader = New-Object System.Windows.Forms.Label
    $appHeader.Text = "A P P E A R A N C E"
    $appHeader.Font = $sectionFont
    $appHeader.ForeColor = $sectionColor
    $appHeader.Location = New-Object System.Drawing.Point($m, $y)
    $appHeader.AutoSize = $true
    $settings.Controls.Add($appHeader)
    $y += [int](24 * $ds)

    # --- Display mode section ---
    $displayLabel = New-Object System.Windows.Forms.Label
    $displayLabel.Text = "Display mode:"
    $displayLabel.Font = $labelFont
    $displayLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $displayLabel.Location = New-Object System.Drawing.Point($m, $y)
    $displayLabel.AutoSize = $true
    $settings.Controls.Add($displayLabel)
    $y += [int](26 * $ds)

    $displayCombo = New-Object System.Windows.Forms.ComboBox
    $displayCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $displayCombo.Font = $labelFont
    $displayCombo.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $displayCombo.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $displayCombo.Location = New-Object System.Drawing.Point($m, $y)
    $displayCombo.Size = New-Object System.Drawing.Size($cw, [int](28 * $ds))
    $displayCombo.Items.AddRange(@("Time remaining", "Percentage", "Both (% + time)"))
    $displayIdx = switch ($script:config.DisplayMode) {
        "time"    { 0 }
        "percent" { 1 }
        "both"    { 2 }
        default   { 0 }
    }
    $displayCombo.SelectedIndex = $displayIdx
    $displayCombo.Add_SelectedIndexChanged({
        $modeMap = @("time", "percent", "both")
        $script:config.DisplayMode = $modeMap[$displayCombo.SelectedIndex]
        Update-PillSize
        Save-Config
    })
    Set-DarkComboBox -Combo $displayCombo
    $settings.Controls.Add($displayCombo)
    $settingsTooltip.SetToolTip($displayCombo, "Choose what information appears on the pill")
    $y += [int](42 * $ds)

    # --- Pill size section ---
    $sizeLabel = New-Object System.Windows.Forms.Label
    $sizeLabel.Text = "Pill size:"
    $sizeLabel.Font = $labelFont
    $sizeLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $sizeLabel.Location = New-Object System.Drawing.Point($m, $y)
    $sizeLabel.AutoSize = $true
    $settings.Controls.Add($sizeLabel)
    $y += [int](26 * $ds)

    $sizeCombo = New-Object System.Windows.Forms.ComboBox
    $sizeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $sizeCombo.Font = $labelFont
    $sizeCombo.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $sizeCombo.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $sizeCombo.Location = New-Object System.Drawing.Point($m, $y)
    $sizeCombo.Size = New-Object System.Drawing.Size($cw, [int](28 * $ds))
    $sizeCombo.Items.AddRange(@("Compact (80x28)", "Normal (108x34)", "Expanded (140x42)"))
    $sizeIdx = switch ($script:config.PillSize) {
        "compact"  { 0 }
        "normal"   { 1 }
        "expanded" { 2 }
        default    { 1 }
    }
    $sizeCombo.SelectedIndex = $sizeIdx
    $sizeCombo.Add_SelectedIndexChanged({
        $sizeMap = @("compact", "normal", "expanded")
        $script:config.PillSize = $sizeMap[$sizeCombo.SelectedIndex]
        Update-PillSize
        Save-Config
    })
    Set-DarkComboBox -Combo $sizeCombo
    $settings.Controls.Add($sizeCombo)
    $settingsTooltip.SetToolTip($sizeCombo, "Adjust the size of the floating pill")
    $y += [int](42 * $ds)

    # --- Accent color section ---
    $accentLabel = New-Object System.Windows.Forms.Label
    $accentLabel.Text = "Accent color:"
    $accentLabel.Font = $labelFont
    $accentLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $accentLabel.Location = New-Object System.Drawing.Point($m, $y)
    $accentLabel.AutoSize = $true
    $settings.Controls.Add($accentLabel)
    $y += [int](26 * $ds)

    $colorNames = @("Green", "Blue", "Purple", "Cyan", "Pink", "Teal", "Orange", "White")
    $circleSize = [int](24 * $ds)
    $circleSpacing = [int](32 * $ds)
    for ($ci = 0; $ci -lt 8; $ci++) {
        $colorPanel = New-Object System.Windows.Forms.Panel
        $colorPanel.Size = New-Object System.Drawing.Size($circleSize, $circleSize)
        $colorPanel.Location = New-Object System.Drawing.Point(($m + $ci * $circleSpacing), $y)
        $colorPanel.BackColor = [System.Drawing.Color]::Transparent
        $colorPanel.Tag = @{ Index = $ci; Hovered = $false }
        $colorPanel.Add_Paint({
            param($sender, $e)
            $cg = $e.Graphics
            $cg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $tagData = $sender.Tag
            $idx = $tagData.Index
            $isHovered = $tagData.Hovered
            $color = $script:accentPresets[$idx]
            $brush = New-Object System.Drawing.SolidBrush($color)
            # Scale circle radius 1.15x on hover
            if ($isHovered) {
                $scale = 1.15
                $cw = $sender.Width - 5; $ch = $sender.Height - 5
                $sw = [int]($cw * $scale); $sh = [int]($ch * $scale)
                $sx = [int]((($sender.Width - $sw) / 2) - 0.5)
                $sy = [int]((($sender.Height - $sh) / 2) - 0.5)
                $cg.FillEllipse($brush, $sx, $sy, $sw, $sh)
            } else {
                $cg.FillEllipse($brush, 2, 2, $sender.Width - 5, $sender.Height - 5)
            }
            $brush.Dispose()
            # Selection ring (accent-colored glow)
            if ($idx -eq $script:config.AccentColorIndex) {
                $ringColor = [System.Drawing.Color]::FromArgb(200, $color.R, $color.G, $color.B)
                $ringPen = New-Object System.Drawing.Pen($ringColor, 2)
                $cg.DrawEllipse($ringPen, 1, 1, $sender.Width - 3, $sender.Height - 3)
                $ringPen.Dispose()
            }
        })
        $colorPanel.Add_MouseEnter({ param($sender); $sender.Tag.Hovered = $true; $sender.Invalidate() })
        $colorPanel.Add_MouseLeave({ param($sender); $sender.Tag.Hovered = $false; $sender.Invalidate() })
        $colorPanel.Add_Click({
            param($sender)
            $script:config.AccentColorIndex = $sender.Tag.Index
            Save-Config
            # Repaint all color circles to update selection ring
            foreach ($ctrl in $settings.Controls) {
                if ($ctrl -is [System.Windows.Forms.Panel] -and $null -ne $ctrl.Tag -and $ctrl.Tag -is [hashtable] -and $null -ne $ctrl.Tag.Index) {
                    $ctrl.Invalidate()
                }
            }
        })
        $colorPanel.Cursor = [System.Windows.Forms.Cursors]::Hand
        $settings.Controls.Add($colorPanel)
    }
    $y += [int](36 * $ds)

    # --- Theme section ---
    $themeLabel = New-Object System.Windows.Forms.Label
    $themeLabel.Text = "Theme:"
    $themeLabel.Font = $labelFont
    $themeLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $themeLabel.Location = New-Object System.Drawing.Point($m, $y)
    $themeLabel.AutoSize = $true
    $settings.Controls.Add($themeLabel)
    $y += [int](26 * $ds)

    $themeCombo = New-Object System.Windows.Forms.ComboBox
    $themeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $themeCombo.Font = $labelFont
    $themeCombo.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $themeCombo.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $themeCombo.Location = New-Object System.Drawing.Point($m, $y)
    $themeCombo.Size = New-Object System.Drawing.Size($cw, [int](28 * $ds))
    $themeCombo.Items.AddRange(@("Dark", "Light", "Auto (follow Windows)"))
    $themeIdx = switch ($script:config.Theme) {
        "dark"  { 0 }
        "light" { 1 }
        "auto"  { 2 }
        default { 0 }
    }
    $themeCombo.SelectedIndex = $themeIdx
    $themeCombo.Add_SelectedIndexChanged({
        $themeMap = @("dark", "light", "auto")
        $script:config.Theme = $themeMap[$themeCombo.SelectedIndex]
        Apply-Theme
        Save-Config
    })
    Set-DarkComboBox -Combo $themeCombo
    $settings.Controls.Add($themeCombo)
    $settingsTooltip.SetToolTip($themeCombo, "Color scheme (Auto follows Windows theme)")
    $y += [int](54 * $ds)

    # --- Advanced section header ---
    $advSep = New-Object System.Windows.Forms.Label
    $advSep.Location = New-Object System.Drawing.Point($m, $y)
    $advSep.Size = New-Object System.Drawing.Size($cw, 1)
    $advSep.BackColor = $script:theme.Border
    $settings.Controls.Add($advSep)
    $y += [int](8 * $ds)
    $advHeader = New-Object System.Windows.Forms.Label
    $advHeader.Text = "A D V A N C E D"
    $advHeader.Font = $sectionFont
    $advHeader.ForeColor = $sectionColor
    $advHeader.Location = New-Object System.Drawing.Point($m, $y)
    $advHeader.AutoSize = $true
    $settings.Controls.Add($advHeader)
    $y += [int](24 * $ds)

    # Opacity label
    $opacityLabel = New-Object System.Windows.Forms.Label
    $opacityLabel.Text = "Opacity:"
    $opacityLabel.Font = $labelFont
    $opacityLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $opacityLabel.Location = New-Object System.Drawing.Point($m, $y)
    $opacityLabel.AutoSize = $true
    $settings.Controls.Add($opacityLabel)

    # Opacity value label (right-aligned)
    $opacityValueLabel = New-Object System.Windows.Forms.Label
    $opacityValueLabel.Text = "{0}%" -f [int]($script:config.Opacity * 100)
    $opacityValueLabel.Font = $labelFont
    $opacityValueLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $opacityValueLabel.Location = New-Object System.Drawing.Point([int](260 * $ds), $y)
    $opacityValueLabel.AutoSize = $true
    $settings.Controls.Add($opacityValueLabel)
    $y += [int](24 * $ds)

    # Opacity slider (30-100 maps to 0.3-1.0)
    $opacitySlider = New-Object System.Windows.Forms.TrackBar
    $opacitySlider.Minimum = 30
    $opacitySlider.Maximum = 100
    $opacitySlider.Value = [int]($script:config.Opacity * 100)
    $opacitySlider.TickFrequency = 10
    $opacitySlider.Location = New-Object System.Drawing.Point($m, $y)
    $opacitySlider.Size = New-Object System.Drawing.Size($cw, [int](30 * $ds))
    $opacitySlider.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
    $opacitySlider.Add_ValueChanged({
        $newOpacity = $opacitySlider.Value / 100.0
        $script:floatingBar.Opacity = $newOpacity
        $script:config.Opacity = $newOpacity
        $opacityValueLabel.Text = "{0}%" -f $opacitySlider.Value
    })
    $opacitySlider.Add_MouseUp({ Save-Config })
    $settings.Controls.Add($opacitySlider)
    $y += [int](67 * $ds)

    # --- Refresh rate section ---

    $refreshLabel = New-Object System.Windows.Forms.Label
    $refreshLabel.Text = "Refresh rate:"
    $refreshLabel.Font = $labelFont
    $refreshLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $refreshLabel.Location = New-Object System.Drawing.Point($m, $y)
    $refreshLabel.AutoSize = $true
    $settings.Controls.Add($refreshLabel)
    $y += [int](26 * $ds)

    $refreshCombo = New-Object System.Windows.Forms.ComboBox
    $refreshCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $refreshCombo.Font = $labelFont
    $refreshCombo.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $refreshCombo.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $refreshCombo.Location = New-Object System.Drawing.Point($m, $y)
    $refreshCombo.Size = New-Object System.Drawing.Size($cw, [int](28 * $ds))
    $refreshCombo.Items.AddRange(@("1 second", "3 seconds", "5 seconds", "10 seconds"))
    $selectedIndex = switch ($script:config.RefreshInterval) {
        1000 { 0 }
        3000 { 1 }
        5000 { 2 }
        10000 { 3 }
        default { 1 }
    }
    $refreshCombo.SelectedIndex = $selectedIndex
    $refreshCombo.Add_SelectedIndexChanged({
        $intervalMap = @(1000, 3000, 5000, 10000)
        $newInterval = $intervalMap[$refreshCombo.SelectedIndex]
        $script:timer.Interval = $newInterval
        $script:config.RefreshInterval = $newInterval
        Save-Config
    })
    Set-DarkComboBox -Combo $refreshCombo
    $settings.Controls.Add($refreshCombo)
    $settingsTooltip.SetToolTip($refreshCombo, "How often battery data refreshes (lower = more CPU)")
    $y += [int](54 * $ds)

    # --- Buttons section ---

    # Reset position button
    $resetBtn = New-Object System.Windows.Forms.Button
    $resetBtn.Text = "Reset Pill Position"
    $resetBtn.Font = $labelFont
    $resetBtn.Size = New-Object System.Drawing.Size($cw, $bh)
    $resetBtn.Location = New-Object System.Drawing.Point($m, $y)
    $resetBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $resetBtn.FlatAppearance.BorderSize = 0
    $resetBtn.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $resetBtn.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $resetBtn.Add_Click({
        if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
            $screen = [System.Windows.Forms.Screen]::FromPoint($script:floatingBar.Location).WorkingArea
        } else {
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        }
        $newX = $screen.Right - $script:floatingBar.Width - 10
        $newY = $screen.Bottom - $script:floatingBar.Height - 10
        $script:floatingBar.Location = New-Object System.Drawing.Point($newX, $newY)
        $script:config.X = $newX
        $script:config.Y = $newY
        Save-Config
        Show-BatteryNotification "Position Reset" "Pill moved to default location"
    })
    $settings.Controls.Add($resetBtn)
    $settingsTooltip.SetToolTip($resetBtn, "Move pill back to default position (bottom-right)")
    $y += [int](38 * $ds)

    # Close button (accent green)
    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = "Close"
    $closeBtn.Font = $labelFont
    $closeBtn.Size = New-Object System.Drawing.Size($cw, $bh)
    $closeBtn.Location = New-Object System.Drawing.Point($m, $y)
    $closeBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeBtn.FlatAppearance.BorderSize = 0
    $closeBtn.BackColor = [System.Drawing.Color]::FromArgb(45, 212, 100)
    $closeBtn.ForeColor = [System.Drawing.Color]::FromArgb(10, 10, 12)
    $closeBtn.Add_Click({ $settings.Close() })
    $settings.Controls.Add($closeBtn)

    # Auto-size form to fit content
    $settings.ClientSize = New-Object System.Drawing.Size(($cw + $m * 2), ($y + $bh + $m))

    $settings.ShowDialog() | Out-Null
    $settings.Dispose()
}

function Show-AboutDialog {
    $about = New-Object System.Windows.Forms.Form
    $about.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $about.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $about.ShowInTaskbar = $false
    $about.TopMost = $true
    $about.BackColor = $script:theme.PopupBg
    $about.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $about.KeyPreview = $true
    Enable-DoubleBuffering -Form $about

    # Drop shadow
    $about.Add_HandleCreated({ [Win32Icon]::EnableDropShadow($about.Handle) })

    # Rounded border paint
    $about.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $r = 10; $rd2 = $r * 2
        $bw = $sender.Width - 1; $bh = $sender.Height - 1
        $borderPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $borderPath.AddArc(0, 0, $rd2, $rd2, 180, 90)
        $borderPath.AddArc($bw - $rd2, 0, $rd2, $rd2, 270, 90)
        $borderPath.AddArc($bw - $rd2, $bh - $rd2, $rd2, $rd2, 0, 90)
        $borderPath.AddArc(0, $bh - $rd2, $rd2, $rd2, 90, 90)
        $borderPath.CloseFigure()
        $borderPen = New-Object System.Drawing.Pen($script:theme.Border, 1)
        $g.DrawPath($borderPen, $borderPath)
        $borderPen.Dispose(); $borderPath.Dispose()
    })

    # DPI scale
    $gDpi = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $ds = $gDpi.DpiX / 96.0
    $gDpi.Dispose()

    $fw = [int](320 * $ds)
    $m = [int](30 * $ds)
    $y = $m

    # Title
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "BatteryPill"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", (12 * $ds), [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $script:theme.TextPrimary
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point($m, $y)
    $about.Controls.Add($titleLabel)
    $y += [int](30 * $ds)

    # Version
    $versionLabel = New-Object System.Windows.Forms.Label
    $versionLabel.Text = "Version $script:appVersion"
    $versionLabel.Font = New-Object System.Drawing.Font("Segoe UI", (8.5 * $ds))
    $versionLabel.ForeColor = $script:theme.TextDim
    $versionLabel.AutoSize = $true
    $versionLabel.Location = New-Object System.Drawing.Point($m, $y)
    $about.Controls.Add($versionLabel)
    $y += [int](24 * $ds)

    # Description
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Windows battery monitor with floating pill"
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", (8.5 * $ds))
    $descLabel.ForeColor = $script:theme.TextLight
    $descLabel.AutoSize = $true
    $descLabel.MaximumSize = New-Object System.Drawing.Size(($fw - $m * 2), 0)
    $descLabel.Location = New-Object System.Drawing.Point($m, $y)
    $about.Controls.Add($descLabel)
    $y += [int](30 * $ds)

    # Website link
    $siteLink = New-Object System.Windows.Forms.LinkLabel
    $siteLink.Text = "batterypill.com"
    $siteLink.Font = New-Object System.Drawing.Font("Segoe UI", (8.5 * $ds))
    $siteLink.LinkColor = [System.Drawing.Color]::FromArgb(100, 149, 237)
    $siteLink.ActiveLinkColor = [System.Drawing.Color]::FromArgb(130, 170, 255)
    $siteLink.AutoSize = $true
    $siteLink.Location = New-Object System.Drawing.Point($m, $y)
    $siteLink.Add_LinkClicked({ Start-Process "https://batterypill.com" })
    $about.Controls.Add($siteLink)
    $y += [int](22 * $ds)

    # Donate link
    $donateLink = New-Object System.Windows.Forms.LinkLabel
    $donateLink.Text = "Buy me a coffee"
    $donateLink.Font = New-Object System.Drawing.Font("Segoe UI", (8.5 * $ds))
    $donateLink.LinkColor = [System.Drawing.Color]::FromArgb(255, 200, 60)
    $donateLink.ActiveLinkColor = [System.Drawing.Color]::FromArgb(255, 220, 100)
    $donateLink.AutoSize = $true
    $donateLink.Location = New-Object System.Drawing.Point($m, $y)
    $donateLink.Add_LinkClicked({ Start-Process "https://buymeacoffee.com/nobackhand" })
    $about.Controls.Add($donateLink)
    $y += [int](34 * $ds)

    # Footer
    $footerLabel = New-Object System.Windows.Forms.Label
    $footerLabel.Text = "Built with PowerShell + WinForms"
    $footerLabel.Font = New-Object System.Drawing.Font("Segoe UI", (7 * $ds))
    $footerLabel.ForeColor = $script:theme.TextMuted
    $footerLabel.AutoSize = $true
    $footerLabel.Location = New-Object System.Drawing.Point($m, $y)
    $about.Controls.Add($footerLabel)
    $y += [int](20 * $ds)

    # Set form size
    $fh = $y + $m
    $about.ClientSize = New-Object System.Drawing.Size($fw, $fh)

    # Rounded region
    $prd = 20; $pw = $about.ClientSize.Width; $ph = $about.ClientSize.Height
    $regionPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $regionPath.AddArc(0, 0, $prd, $prd, 180, 90)
    $regionPath.AddArc($pw - $prd - 1, 0, $prd, $prd, 270, 90)
    $regionPath.AddArc($pw - $prd - 1, $ph - $prd - 1, $prd, $prd, 0, 90)
    $regionPath.AddArc(0, $ph - $prd - 1, $prd, $prd, 90, 90)
    $regionPath.CloseFigure()
    $about.Region = New-Object System.Drawing.Region($regionPath)

    # Close on Escape
    $about.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $about.Close() }
    })

    # Close on deactivate (click outside)
    $about.Add_Deactivate({ $about.Close() })

    $about.ShowDialog() | Out-Null
    # Dispose fonts created for about dialog labels
    foreach ($ctrl in $about.Controls) {
        if ($null -ne $ctrl.Font) { $ctrl.Font.Dispose() }
    }
    $about.Dispose()
}

# ============================================================
# UPDATE FUNCTIONS
# ============================================================

function Update-TrayIcon {
    $now = Get-Date
    $info = Get-BatteryInfo -Now $now

    # Only regenerate icon when state actually changes
    $needsNewIcon = ($info.Percent -ne $script:cachedIconPercent) -or
                    ($info.IsCharging -ne $script:cachedIconCharging) -or
                    ($info.IsFullyCharged -ne $script:cachedIconFullyCharged)

    if ($needsNewIcon) {
        # Destroy previous icon handle
        if ($script:lastIconHandle) {
            [Win32Icon]::DestroyIcon($script:lastIconHandle) | Out-Null
            $script:lastIconHandle = $null
        }

        $iconResult = New-BatteryIcon -Percent $info.Percent -Status $info.StatusText
        $script:lastIconHandle = $iconResult.Handle
        $script:notifyIcon.Icon = $iconResult.Icon

        $script:cachedIconPercent = $info.Percent
        $script:cachedIconCharging = $info.IsCharging
        $script:cachedIconFullyCharged = $info.IsFullyCharged
    }

    # Build tooltip (max 127 chars)
    if ($info.NoBattery) {
        $script:notifyIcon.Text = "Battery Widget: No battery detected"
    } else {
        $tipText = "Battery: $($info.Percent)% - $($info.StatusText)"
        if ($info.TimeString -and $info.TimeString -ne "N/A (plugged in)") {
            $tipText += " | $($info.TimeString)"
        }
        if ($tipText.Length -gt 127) { $tipText = $tipText.Substring(0, 124) + "..." }
        $script:notifyIcon.Text = $tipText
    }

    # Update floating bar
    Update-FloatingBar -BatteryInfo $info

    # Record history for sparkline (cap at 2400 entries = ~2h at 3s intervals)
    $script:batteryHistory.Add(@{
        Time = $now
        Percent = $info.Percent
        IsCharging = $info.IsCharging
    }) | Out-Null
    if ($script:batteryHistory.Count -gt 2400) {
        $script:batteryHistory.RemoveAt(0)
    }

    $script:lastBatteryInfo = $info
}

# ============================================================
# MAIN APPLICATION SETUP
# ============================================================

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:config = Load-Config
Apply-Theme
$script:positionLocked = $script:config.PositionLocked

# Restore battery history from config (gives immediate sparkline data on restart)
if ($script:config.BatteryHistory.Count -gt 0) {
    $script:batteryHistory = New-Object System.Collections.ArrayList
    foreach ($entry in $script:config.BatteryHistory) {
        $script:batteryHistory.Add($entry) | Out-Null
    }
}
# Restore persisted EMA state (smooth estimates immediately on restart)
if ($script:config.EmaRate -gt 0) {
    $script:emaRate = $script:config.EmaRate
    $script:lastValidRate = $script:config.LastValidRate
    $script:lastValidRateTime = Get-Date  # treat as fresh since config was recent (< 10 min)
}
$script:lastIconHandle = $null
$script:lastBatteryInfo = $null
$script:cachedIconPercent = -1
$script:cachedIconCharging = $null
$script:cachedIconFullyCharged = $null

# Hidden main form (message pump owner)
$script:mainForm = New-Object System.Windows.Forms.Form
$script:mainForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$script:mainForm.ShowInTaskbar = $false
$script:mainForm.Visible = $false
$script:mainForm.Text = "BatteryWidget"

# NotifyIcon
$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:notifyIcon.Visible = $true

# Floating bar
$script:floatingBar = New-FloatingBar
$script:floatingBar.Show()

# First-run welcome tooltip
Show-FirstRunTooltip

# Register sleep/wake event - reset EMA state on resume from sleep/hibernate
$script:powerModeHandler = {
    param($sender, $e)
    if ($e.Mode -eq [Microsoft.Win32.PowerModes]::Resume) {
        $script:emaRate = -1
        $script:lastValidRate = -1
        $script:lastValidRateTime = $null
        $script:rateHistory.Clear()
        $script:lastCapacityCheck = $null
        $script:capacityRateMismatchCount = 0
        $script:stateChangeTime = Get-Date  # trigger hysteresis window
    }
}
[Microsoft.Win32.SystemEvents]::add_PowerModeChanged($script:powerModeHandler)

# Re-validate pill position when displays change (monitor disconnect/resolution change)
$script:displaySettingsHandler = {
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        if (-not (Test-PositionOnScreen -X $script:floatingBar.Left -Y $script:floatingBar.Top -Width $script:floatingBar.Width -Height $script:floatingBar.Height)) {
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $newX = $screen.Right - $script:floatingBar.Width - 10
            $newY = $screen.Bottom - $script:floatingBar.Height - 10
            $script:floatingBar.Location = New-Object System.Drawing.Point($newX, $newY)
            $script:config.X = $newX
            $script:config.Y = $newY
            Save-Config
        }
    }
}
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($script:displaySettingsHandler)

# Auto-dismiss timer for pill context menu (closes when mouse moves away)
$script:menuDismissTimer = New-Object System.Windows.Forms.Timer
$script:menuDismissTimer.Interval = 200
$script:menuDismissTimer.Add_Tick({
    if ($null -eq $pillContextMenu -or -not $pillContextMenu.Visible) {
        $script:menuDismissTimer.Stop()
        return
    }
    $mousePos = [System.Windows.Forms.Cursor]::Position
    $overMenu = $false
    # Main menu bounds + 10px grace
    $menuRect = New-Object System.Drawing.Rectangle($pillContextMenu.Location, $pillContextMenu.Size)
    $menuRect.Inflate(10, 10)
    if ($menuRect.Contains($mousePos)) { $overMenu = $true }
    # Check any visible submenu (Power Plan dropdown)
    if (-not $overMenu) {
        foreach ($item in $pillContextMenu.Items) {
            if ($item -is [System.Windows.Forms.ToolStripMenuItem] -and $item.HasDropDown -and $item.DropDown.Visible) {
                $subRect = New-Object System.Drawing.Rectangle($item.DropDown.Location, $item.DropDown.Size)
                $subRect.Inflate(10, 10)
                if ($subRect.Contains($mousePos)) { $overMenu = $true; break }
            }
        }
    }
    if (-not $overMenu) {
        $script:menuDismissTimer.Stop()
        $pillContextMenu.Close()
    }
})

# Pill context menu (right-click on floating bar)
$pillContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$pillContextMenu.Add_Opening({
    $script:hoverTimer.Stop()
    if ($script:hoverPopupVisible) {
        Close-HoverPopup
    }
    Update-PowerPlanMenu -MenuItem $pillPowerItem
    $script:menuDismissTimer.Start()
})
$pillContextMenu.Add_Closed({ $script:menuDismissTimer.Stop() })

$pillHideItem = New-Object System.Windows.Forms.ToolStripMenuItem("Hide Pill")
$pillHideItem.Add_Click({
    $script:floatingBar.Hide()
    # Update tray menu item too
    $toggleBarItem.Text = "Show Bar"
})

$pillSettingsItem = New-Object System.Windows.Forms.ToolStripMenuItem("Settings...")
$pillSettingsItem.Add_Click({ Show-SettingsPanel })

$pillPowerItem = New-Object System.Windows.Forms.ToolStripMenuItem("Power Plan")

$pillSeparator1 = New-Object System.Windows.Forms.ToolStripSeparator

$pillRefreshItem = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh")
$pillRefreshItem.Add_Click({ Update-TrayIcon })

$pillAboutItem = New-Object System.Windows.Forms.ToolStripMenuItem("About")
$pillAboutItem.Add_Click({ Show-AboutDialog })

$pillSeparator2 = New-Object System.Windows.Forms.ToolStripSeparator

$pillExitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
$pillExitItem.Add_Click({
    $script:timer.Stop()
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    $script:floatingBar.Close()
    $script:mainForm.Close()
})

$pillContextMenu.Items.Add($pillHideItem) | Out-Null
$pillContextMenu.Items.Add($pillSettingsItem) | Out-Null
$pillContextMenu.Items.Add($pillPowerItem) | Out-Null
$pillContextMenu.Items.Add($pillSeparator1) | Out-Null
$pillContextMenu.Items.Add($pillRefreshItem) | Out-Null
$pillContextMenu.Items.Add($pillAboutItem) | Out-Null
$pillContextMenu.Items.Add($pillSeparator2) | Out-Null
$pillContextMenu.Items.Add($pillExitItem) | Out-Null

$script:floatingBar.ContextMenuStrip = $pillContextMenu

# Tray context menu
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$toggleBarItem = New-Object System.Windows.Forms.ToolStripMenuItem("Hide Bar")
$toggleBarItem.Add_Click({
    if ($script:floatingBar.Visible) {
        $script:floatingBar.Hide()
        $toggleBarItem.Text = "Show Bar"
    } else {
        $script:floatingBar.Show()
        $toggleBarItem.Text = "Hide Bar"
    }
})

$settingsItem = New-Object System.Windows.Forms.ToolStripMenuItem("Settings...")
$settingsItem.Add_Click({ Show-SettingsPanel })

$trayPowerItem = New-Object System.Windows.Forms.ToolStripMenuItem("Power Plan")

$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh")
$refreshItem.Add_Click({ Update-TrayIcon })

$aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem("About")
$aboutItem.Add_Click({ Show-AboutDialog })

$separatorItem = New-Object System.Windows.Forms.ToolStripSeparator

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
$exitItem.Add_Click({
    $script:timer.Stop()
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    $script:floatingBar.Close()
    $script:mainForm.Close()
})

$contextMenu.Add_Opening({
    Update-PowerPlanMenu -MenuItem $trayPowerItem
})

$contextMenu.Items.Add($toggleBarItem) | Out-Null
$contextMenu.Items.Add($settingsItem) | Out-Null
$contextMenu.Items.Add($trayPowerItem) | Out-Null
$contextMenu.Items.Add($refreshItem) | Out-Null
$contextMenu.Items.Add($aboutItem) | Out-Null
$contextMenu.Items.Add($separatorItem) | Out-Null
$contextMenu.Items.Add($exitItem) | Out-Null

$script:notifyIcon.ContextMenuStrip = $contextMenu

# Left-click tray icon opens popup
$script:notifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $currentInfo = Get-BatteryInfo
        Show-BatteryPopup -BatteryInfo $currentInfo
    }
})

# Timer for periodic updates
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = $script:config.RefreshInterval
$script:timer.Add_Tick({
    try { Update-TrayIcon } catch {}
})

# Pulse timer for charging animation (smooth pulsing glow effect)
$script:pulseTimer = New-Object System.Windows.Forms.Timer
$script:pulseTimer.Interval = 33  # 33ms for smooth animation (~30 FPS)
$script:pulseTimer.Add_Tick({
    try {
        $needsRepaint = $false
        if ($script:barIsCharging) {
            # Sine-wave breathing pulse: 5-second cycle, alpha 90-120
            $t = (Get-Date).Ticks / 10000000.0
            $script:pulseAlpha = [int](105 + 15 * [Math]::Sin($t * 1.257))
            $needsRepaint = $true
        }
        # Plug/unplug flash decay (180→0 over ~750ms at 50ms tick = ~12 per tick)
        if ($script:flashAlpha -gt 0) {
            $script:flashAlpha = [math]::Max(0, $script:flashAlpha - 12)
            $needsRepaint = $true
        }
        # Low battery warning animations
        if ($null -ne $script:lowBatPulseActive -and $script:lowBatPulseActive) {
            # Pulsing red border (4.7s cycle at 50ms tick = ~94 ticks)
            $script:lowBatBorderAlpha += $script:lowBatBorderDir * 3
            if ($script:lowBatBorderAlpha -ge 220) { $script:lowBatBorderAlpha = 220; $script:lowBatBorderDir = -1 }
            elseif ($script:lowBatBorderAlpha -le 80) { $script:lowBatBorderAlpha = 80; $script:lowBatBorderDir = 1 }
            # Opacity oscillation at 10% and below
            if ($script:lowBatOpacityPulse -and $null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
                $opBase = 0.8 + 0.2 * [math]::Sin((Get-Date).Ticks / 10000000.0 * 1.5)
                $script:floatingBar.Opacity = [math]::Max(0.6, [math]::Min(1.0, $opBase))
            }
            $needsRepaint = $true
        }
        # "Estimating..." text pulse in popup
        if ($null -ne $script:estimatingLabel -and -not $script:estimatingLabel.IsDisposed) {
            $t2 = (Get-Date).Ticks / 10000000.0
            $alpha = [int](120 + 80 * [Math]::Sin($t2 * 2.5))
            $script:estimatingLabel.ForeColor = [System.Drawing.Color]::FromArgb(
                $alpha, $script:theme.TextPrimary.R, $script:theme.TextPrimary.G, $script:theme.TextPrimary.B)
        }
        if ($needsRepaint -and $null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
            $script:floatingBar.Invalidate()
        }
        # Auto-stop when all animations complete
        Update-PulseTimerState
    } catch {}
})
# Timer starts idle — Update-PulseTimerState will start it when animations are active

function Update-PulseTimerState {
    # Start pulse timer only when animations need it, stop when idle
    $anyActive = $script:barIsCharging -or ($script:flashAlpha -gt 0) -or ($null -ne $script:lowBatPulseActive -and $script:lowBatPulseActive) -or ($null -ne $script:estimatingLabel -and -not $script:estimatingLabel.IsDisposed)
    if ($anyActive) {
        if (-not $script:pulseTimer.Enabled) { $script:pulseTimer.Start() }
    } else {
        if ($script:pulseTimer.Enabled) { $script:pulseTimer.Stop() }
    }
}

# Auto-hide in fullscreen timer (1-second check)
$script:fullscreenTimer = New-Object System.Windows.Forms.Timer
$script:fullscreenTimer.Interval = 1000
$script:fullscreenTimer.Add_Tick({
    try {
        if (-not $script:config.AutoHideFullscreen) { return }
        $isFS = Test-FullscreenApp
        if ($isFS -and -not $script:isFullscreenHidden) {
            # Fade out pill
            $script:isFullscreenHidden = $true
            if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed -and $script:floatingBar.Visible) {
                $script:floatingBar.Hide()
            }
        } elseif (-not $isFS -and $script:isFullscreenHidden) {
            # Restore pill
            $script:isFullscreenHidden = $false
            if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed -and -not $script:floatingBar.Visible) {
                $script:floatingBar.Show()
            }
        }
    } catch {}
})
$script:fullscreenTimer.Start()

# Cleanup on form closing
$script:mainForm.Add_FormClosing({
    # Save config (including battery history) on exit
    Save-Config
    $script:timer.Stop()
    $script:timer.Dispose()
    $script:pulseTimer.Stop()
    $script:pulseTimer.Dispose()
    $script:fullscreenTimer.Stop()
    $script:fullscreenTimer.Dispose()
    # Clean up hover timers
    if ($null -ne $script:hoverTimer) {
        $script:hoverTimer.Stop()
        $script:hoverTimer.Dispose()
    }
    if ($null -ne $script:dismissTimer) {
        $script:dismissTimer.Stop()
        $script:dismissTimer.Dispose()
    }
    if ($null -ne $script:menuDismissTimer) {
        $script:menuDismissTimer.Stop()
        $script:menuDismissTimer.Dispose()
    }
    # Close hover popup and fade timers
    if ($null -ne $script:fadeInTimer) { $script:fadeInTimer.Stop(); $script:fadeInTimer.Dispose() }
    if ($null -ne $script:fadeOutTimer) { $script:fadeOutTimer.Stop(); $script:fadeOutTimer.Dispose() }
    if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
        $script:hoverPopup.Close(); $script:hoverPopup.Dispose(); $script:hoverPopup = $null
    }
    $script:hoverPopupVisible = $false
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    if ($script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $script:floatingBar.Close()
        $script:floatingBar.Dispose()
    }
    if ($script:lastIconHandle) {
        [Win32Icon]::DestroyIcon($script:lastIconHandle) | Out-Null
    }
    # Dispose cached GDI objects
    if ($null -ne $script:pillFont) { $script:pillFont.Dispose() }
    if ($null -ne $script:pillFont2) { $script:pillFont2.Dispose() }
    if ($null -ne $script:pillStringFormat) { $script:pillStringFormat.Dispose() }
    if ($null -ne $script:pillBgBrush)   { $script:pillBgBrush.Dispose() }
    if ($null -ne $script:pillTextBrush) { $script:pillTextBrush.Dispose() }
    if ($null -ne $script:pillBorderPen) { $script:pillBorderPen.Dispose() }
    # Unregister system events to avoid leaks
    [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($script:powerModeHandler)
    [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($script:displaySettingsHandler)
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
})

# Initial update and start
Update-TrayIcon
$script:timer.Start()

# Run the application message loop
[System.Windows.Forms.Application]::Run($script:mainForm)
