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
    Border       = [System.Drawing.Color]::FromArgb(50, 50, 56)
    SettingsBg   = [System.Drawing.Color]::FromArgb(32, 32, 36)
    TrackBg      = [System.Drawing.Color]::FromArgb(40, 40, 46)
}

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
        $script:theme.Border       = [System.Drawing.Color]::FromArgb(50, 50, 56)
        $script:theme.SettingsBg   = [System.Drawing.Color]::FromArgb(32, 32, 36)
        $script:theme.TrackBg      = [System.Drawing.Color]::FromArgb(40, 40, 46)
    } else {
        $script:theme.PillBg       = [System.Drawing.Color]::FromArgb(242, 242, 247)
        $script:theme.PopupBg      = [System.Drawing.Color]::FromArgb(248, 248, 252)
        $script:theme.TextPrimary  = [System.Drawing.Color]::FromArgb(28, 28, 30)
        $script:theme.TextDim      = [System.Drawing.Color]::FromArgb(100, 100, 110)
        $script:theme.TextLight    = [System.Drawing.Color]::FromArgb(50, 50, 55)
        $script:theme.Border       = [System.Drawing.Color]::FromArgb(200, 200, 210)
        $script:theme.SettingsBg   = [System.Drawing.Color]::FromArgb(235, 235, 240)
        $script:theme.TrackBg      = [System.Drawing.Color]::FromArgb(215, 215, 220)
    }

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
            -IsPluggedIn $info.IsPluggedIn

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
        $eta = (Get-Date).AddMinutes($timeMinutes)
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
        $script:lastStateChange.Time = Get-Date
        $script:lastStateChange.Percent = $info.PercentExact
        $script:lastStateChange.State = $info.StatusText
    } elseif ($script:lastStateChange.State -ne $info.StatusText) {
        # State changed — reset
        $script:lastStateChange.Time = Get-Date
        $script:lastStateChange.Percent = $info.PercentExact
        $script:lastStateChange.State = $info.StatusText
    }

    $elapsed = (Get-Date) - $script:lastStateChange.Time
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

    # Alpha controls smoothing: lower = more stable, higher = more responsive
    # 0.15 gives ~13 sample half-life (good balance for 10-second polling)
    $alpha = 0.15

    if ($script:emaRate -lt 0) {
        # First reading — initialize directly
        $script:emaRate = $RawRate
    } else {
        # EMA formula: R_EMA_t = α × R_raw_t + (1 - α) × R_EMA_(t-1)
        $script:emaRate = ($alpha * $RawRate) + ((1 - $alpha) * $script:emaRate)
    }

    return [int]$script:emaRate
}

function Get-SmoothedTimeRemaining {
    param(
        [int]$RawRate,
        [int]$FullChargeCapacity,
        [double]$PercentExact,
        [bool]$IsCharging,
        [bool]$IsPluggedIn
    )

    # --- Hysteresis: detect and handle AC state transitions ---
    if ($null -ne $script:lastAcState -and $script:lastAcState -ne $IsPluggedIn) {
        # AC state just changed — start hysteresis window
        $script:stateChangeTime = Get-Date
        # Reset EMA on state change to avoid polluting new state with old rate
        $script:emaRate = -1
    }
    $script:lastAcState = $IsPluggedIn

    # During hysteresis window, return -1 to show "Calculating..."
    if ($null -ne $script:stateChangeTime) {
        $elapsed = ((Get-Date) - $script:stateChangeTime).TotalSeconds
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
    } elseif ($script:lastValidRate -gt 0) {
        # Invalid rate but we have a previous valid one — use EMA with last valid
        $effectiveRate = Update-EMARate -RawRate $script:lastValidRate
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
        } catch {}
    }
    return $default
}

function Save-Config {
    $configPath = Get-ConfigPath
    try {
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
        } | ConvertTo-Json | Set-Content $configPath -Force
    } catch {}
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
# FLOATING BAR — FORM
# ============================================================

function Get-PillDimensions {
    # Returns @{ Width, Height, FontSize } based on PillSize and DisplayMode
    $mode = $script:config.DisplayMode
    $size = $script:config.PillSize
    switch ($size) {
        "compact"  { return @{ Width = 80; Height = 28; FontSize = 8.5; FontSize2 = 0 } }
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
    # Rebuild region
    $rd = 16
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

function New-FloatingBar {
    # Paint state — updated by Update-FloatingBar, read by Paint handler
    $script:barAccentColor = [System.Drawing.Color]::FromArgb(45, 212, 100)
    $script:barDisplayText = "..."
    $script:barDisplayPercent = 50
    $script:barIsCharging = $false

    # Pulse animation state for charging effect
    $script:pulseAlpha = 100
    $script:pulseDirection = 1  # 1 = increasing, -1 = decreasing
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
        $radius = 8

        # --- Rounded rectangle path (full pill) ---
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $radius * 2
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc($w - $d - 1, 0, $d, $d, 270, 90)
        $path.AddArc($w - $d - 1, $h - $d - 1, $d, $d, 0, 90)
        $path.AddArc(0, $h - $d - 1, $d, $d, 90, 90)
        $path.CloseFigure()

        # --- Background (entire pill, theme-aware) ---
        $bgBrush = New-Object System.Drawing.SolidBrush($script:theme.PillBg)
        $g.FillPath($bgBrush, $path)
        $bgBrush.Dispose()

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
            $botBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 180, 185))
            $botRect = New-Object System.Drawing.RectangleF(0, ($h / 2) - 2, $w, ($h / 2))
            $g.DrawString($script:barDisplayText2, $script:pillFont2, $botBrush, $botRect, $script:pillStringFormat)
            $botBrush.Dispose()
        } else {
            # Single-line mode (centered)
            $textBrush = New-Object System.Drawing.SolidBrush($script:theme.TextPrimary)
            $textRect = New-Object System.Drawing.RectangleF(0, 0, $w, $h)
            $g.DrawString($script:barDisplayText, $script:pillFont, $textBrush, $textRect, $script:pillStringFormat)
            $textBrush.Dispose()
        }

        # --- Plug/unplug flash overlay ---
        if ($script:flashAlpha -gt 0) {
            $flashBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($script:flashAlpha, 255, 255, 255))
            $g.FillPath($flashBrush, $path)
            $flashBrush.Dispose()
        }

        # --- Low battery warning: pulsing red border at 15% ---
        if ($null -ne $script:lowBatBorderAlpha -and $script:lowBatBorderAlpha -gt 0) {
            $warnPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($script:lowBatBorderAlpha, 255, 70, 70), 2)
            $g.DrawPath($warnPen, $path)
            $warnPen.Dispose()
        } else {
            # --- Border ---
            $borderPen = New-Object System.Drawing.Pen($script:theme.Border, 1)
            $g.DrawPath($borderPen, $path)
            $borderPen.Dispose()
        }

        $path.Dispose()
    })

    # Hover timer for delayed popup (500ms)
    $script:hoverTimer = New-Object System.Windows.Forms.Timer
    $script:hoverTimer.Interval = 500
    $script:hoverTimer.Add_Tick({
        $script:hoverTimer.Stop()
        if (-not $script:hoverPopupVisible) {
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
            $overPill = $pillRect.Contains($mousePos)
        }

        if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed -and $script:hoverPopup.Visible) {
            $popupRect = New-Object System.Drawing.Rectangle($script:hoverPopup.Location, $script:hoverPopup.Size)
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

    # Set position from config
    if ($script:config.X -ge 0 -and $script:config.Y -ge 0) {
        $form.Location = New-Object System.Drawing.Point($script:config.X, $script:config.Y)
    } else {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Location = New-Object System.Drawing.Point(
            ($screen.Right - $form.Width - 10),
            ($screen.Bottom - $form.Height - 10)
        )
    }

    # Hover tooltip
    $script:barTooltip = New-Object System.Windows.Forms.ToolTip
    $script:barTooltip.InitialDelay = 300
    $script:barTooltip.ReshowDelay = 100
    $script:barTooltip.SetToolTip($form, "")

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

        # Background
        $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(20, 20, 24))
        $sg.FillRectangle($bgBrush, 0, 0, $sw, $sh)
        $bgBrush.Dispose()

        # Border
        $bdrPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 40, 46), 1)
        $sg.DrawRectangle($bdrPen, 0, 0, $sw - 1, $sh - 1)
        $bdrPen.Dispose()

        $history = $script:batteryHistory
        if ($null -eq $history -or $history.Count -lt 2) {
            # Not enough data — show placeholder
            $noDataFont = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)
            $noDataBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(80, 80, 86))
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
    })
    return $panel
}

function Show-BatteryNotification {
    param([string]$Message, [string]$SubMessage)
    # Custom dark-themed notification card — slides in from bottom-right, auto-dismiss 10s
    $notif = New-Object System.Windows.Forms.Form
    $notif.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $notif.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $notif.Size = New-Object System.Drawing.Size(320, 100)
    $notif.TopMost = $true
    $notif.ShowInTaskbar = $false
    $notif.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
    $notif.Opacity = 0
    Enable-DoubleBuffering -Form $notif

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $notif.Location = New-Object System.Drawing.Point(($screen.Right - 330), ($screen.Bottom - 10))

    # Rounded region
    $nr = 10; $nd = $nr * 2
    $nPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $nPath.AddArc(0, 0, $nd, $nd, 180, 90)
    $nPath.AddArc(318, 0, $nd, $nd, 270, 90)
    $nPath.AddArc(318, 78, $nd, $nd, 0, 90)
    $nPath.AddArc(0, 78, $nd, $nd, 90, 90)
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
        $ng.FillRectangle($accentBrush, 0, 10, 4, 80)
        $accentBrush.Dispose()
        # Border
        $bPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $br = 10; $bd = $br * 2
        $bPath.AddArc(0, 0, $bd, $bd, 180, 90)
        $bPath.AddArc(318, 0, $bd, $bd, 270, 90)
        $bPath.AddArc(318, 78, $bd, $bd, 0, 90)
        $bPath.AddArc(0, 78, $bd, $bd, 90, 90)
        $bPath.CloseFigure()
        $bPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, 255, 70, 70), 1)
        $ng.DrawPath($bPen, $bPath)
        $bPen.Dispose(); $bPath.Dispose()
    })

    # Title
    $nTitle = New-Object System.Windows.Forms.Label
    $nTitle.Text = $Message
    $nTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11, [System.Drawing.FontStyle]::Bold)
    $nTitle.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
    $nTitle.Location = New-Object System.Drawing.Point(16, 16)
    $nTitle.AutoSize = $true
    $nTitle.MaximumSize = New-Object System.Drawing.Size(290, 0)
    $notif.Controls.Add($nTitle)

    # Sub-message
    $nSub = New-Object System.Windows.Forms.Label
    $nSub.Text = $SubMessage
    $nSub.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
    $nSub.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
    $nSub.Location = New-Object System.Drawing.Point(16, 48)
    $nSub.AutoSize = $true
    $nSub.MaximumSize = New-Object System.Drawing.Size(290, 0)
    $notif.Controls.Add($nSub)

    $notif.Show()

    # Slide-in and fade-in animation, then auto-dismiss after 10s
    $script:notifSlideTarget = $screen.Bottom - 120
    $script:notifPhase = "in"  # "in", "hold", "out"
    $script:notifHoldStart = $null
    $notifTimer = New-Object System.Windows.Forms.Timer
    $notifTimer.Interval = 16
    $notifTimer.Add_Tick({
        if ($null -eq $notif -or $notif.IsDisposed) { $notifTimer.Stop(); $notifTimer.Dispose(); return }
        if ($script:notifPhase -eq "in") {
            $notif.Opacity = [math]::Min(1.0, $notif.Opacity + 0.08)
            $curY = $notif.Top
            $targetY = $script:notifSlideTarget
            $newY = $curY + [int](($targetY - $curY) * 0.25)
            if ([math]::Abs($newY - $targetY) -lt 2) { $newY = $targetY }
            $notif.Top = $newY
            if ($notif.Opacity -ge 1.0 -and $newY -eq $targetY) {
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
        $timeStr = "--:--"
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
        $script:pulseAlpha = 100
        $script:pulseDirection = 1
    }
    $script:wasChargingLastUpdate = $BatteryInfo.IsCharging

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

    # Update tooltip text
    if ($null -ne $script:barTooltip) {
        $tooltipText = if ($BatteryInfo.NoBattery) {
            "No battery detected"
        } elseif ($BatteryInfo.IsFullyCharged) {
            "$($BatteryInfo.Percent)% $([char]0x2022) Fully charged"
        } elseif ($BatteryInfo.IsCharging) {
            if ($BatteryInfo.TimeMinutes -gt 0) {
                "$($BatteryInfo.Percent)% $([char]0x2022) Charging ($($script:barDisplayText) to full)"
            } else {
                "$($BatteryInfo.Percent)% $([char]0x2022) Charging"
            }
        } else {
            if ($BatteryInfo.TimeMinutes -gt 0) {
                "$($BatteryInfo.Percent)% $([char]0x2022) $($script:barDisplayText) remaining"
            } else {
                "$($BatteryInfo.Percent)% $([char]0x2022) Discharging"
            }
        }
        $script:barTooltip.SetToolTip($script:floatingBar, $tooltipText)
    }

    # Trigger repaint
    $script:floatingBar.Invalidate()
}

# ============================================================
# HOVER POPUP (NON-MODAL)
# ============================================================

function Close-HoverPopup {
    if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
        # Start fade-out instead of instant close
        if ($null -eq $script:fadeOutTimer) {
            $script:fadeOutTimer = New-Object System.Windows.Forms.Timer
            $script:fadeOutTimer.Interval = 16
            $script:fadeOutTimer.Add_Tick({
                if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
                    $newOpacity = $script:hoverPopup.Opacity - 0.16
                    if ($newOpacity -le 0) {
                        $script:fadeOutTimer.Stop()
                        $script:hoverPopup.Close()
                        $script:hoverPopup.Dispose()
                        $script:hoverPopup = $null
                    } else {
                        $script:hoverPopup.Opacity = $newOpacity
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
    $popup.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 30)
    $popup.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $popup.KeyPreview = $true
    Enable-DoubleBuffering -Form $popup

    # Rounded border
    $popup.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $r = 10
        $rd2 = $r * 2
        $bw = $sender.Width - 1
        $bh = $sender.Height - 1
        $borderPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $borderPath.AddArc(0, 0, $rd2, $rd2, 180, 90)
        $borderPath.AddArc($bw - $rd2, 0, $rd2, $rd2, 270, 90)
        $borderPath.AddArc($bw - $rd2, $bh - $rd2, $rd2, $rd2, 0, 90)
        $borderPath.AddArc(0, $bh - $rd2, $rd2, $rd2, 90, 90)
        $borderPath.CloseFigure()
        $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 60, 66), 1)
        $g.DrawPath($borderPen, $borderPath)
        $borderPen.Dispose()
        $borderPath.Dispose()
    })

    # DPI-aware popup layout
    $gDpi = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $dpiScale = $gDpi.DpiX / 96.0
    $gDpi.Dispose()

    $statusColor = Get-StatusColor -Status $BatteryInfo.StatusText
    $lightGray = [System.Drawing.Color]::FromArgb(220, 220, 225)
    $dimGray   = [System.Drawing.Color]::FromArgb(145, 145, 155)
    $labelFont = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)
    $valueFont = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)

    # Scale popup width for DPI
    $popupW = [int](360 * $dpiScale)
    $popup.Size = New-Object System.Drawing.Size($popupW, 400)

    # --- Title ---
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Battery Details"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $titleLabel.Location = New-Object System.Drawing.Point(20, 10)
    $titleLabel.AutoSize = $true
    $titleLabel.MaximumSize = New-Object System.Drawing.Size(($popupW - 40), 0)
    $popup.Controls.Add($titleLabel)

    # Separator line under title
    $sepLabel = New-Object System.Windows.Forms.Label
    $sepLabel.Location = New-Object System.Drawing.Point(20, 32)
    $sepLabel.Size = New-Object System.Drawing.Size(($popupW - 40), 1)
    $sepLabel.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $popup.Controls.Add($sepLabel)

    # --- Row layout (DPI-aware) ---
    $rh = [int](19 * $dpiScale)
    $lx = 20
    $vx = [int](82 * $dpiScale)
    $lw = [int](72 * $dpiScale)
    $vw = $popupW - $vx - 20
    $y = [int](38 * $dpiScale)

    # Helper function to add a row
    function Add-PopupRow {
        param($Form, $Y, $Label, $Value, $LabelFont, $ValueFont, $DimColor, $ValueColor, $Lx, $Vx, $Lw, $Vw)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Label
        $lbl.Font = $LabelFont
        $lbl.ForeColor = $DimColor
        $lbl.Location = New-Object System.Drawing.Point($Lx, $Y)
        $lbl.AutoSize = $true
        $lbl.MaximumSize = New-Object System.Drawing.Size($Lw, 0)
        $Form.Controls.Add($lbl)

        $val = New-Object System.Windows.Forms.Label
        $val.Text = $Value
        $val.Font = $ValueFont
        $val.ForeColor = $ValueColor
        $val.Location = New-Object System.Drawing.Point($Vx, $Y)
        $val.AutoSize = $true
        $val.MaximumSize = New-Object System.Drawing.Size($Vw, 0)
        $Form.Controls.Add($val)
    }

    # Row 1: Percent
    $pctText = if ($BatteryInfo.NoBattery) { "No Battery" } else { "$($BatteryInfo.PercentExact)%" }
    Add-PopupRow -Form $popup -Y $y -Label "Percent:" -Value $pctText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $statusColor -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 2: Capacity
    if ($BatteryInfo.FullChargeCapacity -gt 0 -and $BatteryInfo.PercentExact -ge 0) {
        $currentCharge = [math]::Round($BatteryInfo.FullChargeCapacity * ($BatteryInfo.PercentExact / 100))
        $capText = "{0:N0} / {1:N0} mWh" -f $currentCharge, $BatteryInfo.FullChargeCapacity
    } elseif ($BatteryInfo.FullChargeCapacity -gt 0) {
        $capText = "{0:N0} mWh" -f $BatteryInfo.FullChargeCapacity
    } else {
        $capText = "N/A"
    }
    Add-PopupRow -Form $popup -Y $y -Label "Capacity:" -Value $capText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 3: Discharge/Charge Rate
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
    Add-PopupRow -Form $popup -Y $y -Label "Rate:" -Value $rateText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $rateColor -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 4: Time Remaining with ETA
    if ($BatteryInfo.IsFullyCharged) {
        $timeText = "Fully Charged"
    } elseif ($BatteryInfo.TimeMinutes -gt 0) {
        $h = [math]::Floor($BatteryInfo.TimeMinutes / 60)
        $m = $BatteryInfo.TimeMinutes % 60
        $shortTime = "{0}:{1:D2}" -f $h, $m
        if ($BatteryInfo.ETA) {
            $timeText = "$shortTime (until $($BatteryInfo.ETA))"
        } else {
            $timeText = $shortTime
        }
    } else {
        $timeText = "Estimating..."
    }
    $timeRowLabel = if ($BatteryInfo.IsCharging) { "To Full:" } else { "Remaining:" }
    Add-PopupRow -Form $popup -Y $y -Label $timeRowLabel -Value $timeText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 5: Elapsed Time
    $elapsedText = "$($BatteryInfo.ElapsedTime) (from $($BatteryInfo.ElapsedSince))"
    Add-PopupRow -Form $popup -Y $y -Label "Elapsed:" -Value $elapsedText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 6: Full Runtime
    if ($BatteryInfo.FullRuntimeMinutes -gt 0) {
        $frH = [math]::Floor($BatteryInfo.FullRuntimeMinutes / 60)
        $frM = $BatteryInfo.FullRuntimeMinutes % 60
        $fullRtText = "{0}:{1:D2}" -f $frH, $frM
    } else {
        $fullRtText = "N/A"
    }
    Add-PopupRow -Form $popup -Y $y -Label "Runtime:" -Value $fullRtText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 7: Battery Wear
    if ($BatteryInfo.BatteryWearPercent -ge 0 -and $BatteryInfo.DesignCapacity -gt 0) {
        $wearText = "{0:N1}% of {1:N0} mWh" -f $BatteryInfo.BatteryWearPercent, $BatteryInfo.DesignCapacity
    } else {
        $wearText = "N/A"
    }
    Add-PopupRow -Form $popup -Y $y -Label "Wear:" -Value $wearText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Spacer
    $y += [int](4 * $dpiScale)

    # Battery history sparkline
    $sparkAccent = Get-AccentColor -Percent $BatteryInfo.Percent -IsCharging $BatteryInfo.IsCharging
    $sparkPanel = New-SparklinePanel -Y $y -AccentColor $sparkAccent
    $sparkPanel.Size = New-Object System.Drawing.Size(($popupW - 40), 30)
    $popup.Controls.Add($sparkPanel)
    $y += 32

    # Custom GDI+ progress bar
    $barPct = [math]::Max(0, [math]::Min(100, $BatteryInfo.Percent))
    $barAccent = $sparkAccent
    $progressPanel = New-Object System.Windows.Forms.Panel
    $barW = $popupW - 40
    $progressPanel.Location = New-Object System.Drawing.Point(20, $y)
    $progressPanel.Size = New-Object System.Drawing.Size($barW, 12)
    $progressPanel.BackColor = [System.Drawing.Color]::Transparent
    $progressPanel.Tag = @{ Percent = $barPct; AccentColor = $barAccent }
    $progressPanel.Add_Paint({
        param($sender, $e)
        $pg = $e.Graphics
        $pg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pw2 = $sender.Width
        $ph2 = $sender.Height
        $pr = 7
        $pd = $pr * 2
        $trackPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $trackPath.AddArc(0, 0, $pd, $pd, 180, 90)
        $trackPath.AddArc($pw2 - $pd - 1, 0, $pd, $pd, 270, 90)
        $trackPath.AddArc($pw2 - $pd - 1, $ph2 - $pd - 1, $pd, $pd, 0, 90)
        $trackPath.AddArc(0, $ph2 - $pd - 1, $pd, $pd, 90, 90)
        $trackPath.CloseFigure()
        $trackBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, 40, 46))
        $pg.FillPath($trackBrush, $trackPath)
        $trackBrush.Dispose()
        $tagData = $sender.Tag
        $fillPct = $tagData.Percent
        $acColor = $tagData.AccentColor
        $fw = [math]::Max(0, [math]::Round(($fillPct / 100) * $pw2))
        if ($fw -gt $pd) {
            $fillPath = New-Object System.Drawing.Drawing2D.GraphicsPath
            $fillPath.AddArc(0, 0, $pd, $pd, 180, 90)
            $fillPath.AddArc($fw - $pd - 1, 0, $pd, $pd, 270, 90)
            $fillPath.AddArc($fw - $pd - 1, $ph2 - $pd - 1, $pd, $pd, 0, 90)
            $fillPath.AddArc(0, $ph2 - $pd - 1, $pd, $pd, 90, 90)
            $fillPath.CloseFigure()
            $fillRect2 = New-Object System.Drawing.Rectangle(0, 0, [math]::Max(1, $fw), $ph2)
            $fLeft = [System.Drawing.Color]::FromArgb(200, $acColor.R, $acColor.G, $acColor.B)
            $fRight = [System.Drawing.Color]::FromArgb(140, $acColor.R, $acColor.G, $acColor.B)
            $fillBrush2 = New-Object System.Drawing.Drawing2D.LinearGradientBrush($fillRect2, $fLeft, $fRight, [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            $pg.FillPath($fillBrush2, $fillPath)
            $fillBrush2.Dispose()
            $glassRect = New-Object System.Drawing.Rectangle(0, 0, $fw, [int]($ph2 / 2))
            $glassBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($glassRect, [System.Drawing.Color]::FromArgb(40, 255, 255, 255), [System.Drawing.Color]::FromArgb(0, 255, 255, 255), [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
            $oldClip3 = $pg.Clip
            $pg.SetClip($fillPath)
            $pg.FillRectangle($glassBrush, $glassRect)
            $pg.Clip = $oldClip3
            $glassBrush.Dispose()
            $fillPath.Dispose()
        }
        $borderPen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(55, 55, 62), 1)
        $pg.DrawPath($borderPen2, $trackPath)
        $borderPen2.Dispose()
        $trackPath.Dispose()
    })
    $popup.Controls.Add($progressPanel)

    $y += 14

    # Power source
    $powerLabel = New-Object System.Windows.Forms.Label
    $powerLabel.Text = $BatteryInfo.PowerSource
    $powerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Regular)
    $powerLabel.ForeColor = $dimGray
    $powerLabel.Location = New-Object System.Drawing.Point(20, $y)
    $powerLabel.AutoSize = $true
    $powerLabel.MaximumSize = New-Object System.Drawing.Size(($popupW - 40), 0)
    $popup.Controls.Add($powerLabel)

    $y += 16

    # Close hint
    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Text = "Move mouse away to close"
    $hintLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Regular)
    $hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 86)
    $hintLabel.Location = New-Object System.Drawing.Point(20, $y)
    $hintLabel.AutoSize = $true
    $hintLabel.MaximumSize = New-Object System.Drawing.Size(($popupW - 40), 0)
    $popup.Controls.Add($hintLabel)

    # Resize form to fit content
    $popup.ClientSize = New-Object System.Drawing.Size($popupW, ($y + 12))

    # Set rounded region to clip corners
    $popupRadius = 10
    $prd = $popupRadius * 2
    $pw = $popup.ClientSize.Width
    $ph = $popup.ClientSize.Height
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
        if ($popY -lt $screen.Top) {
            $popY = $barLoc.Y + $barSize.Height + 8
        }
        $popX = [math]::Max($screen.Left, [math]::Min($popX, $screen.Right - $popup.Width))
        $popY = [math]::Max($screen.Top, [math]::Min($popY, $screen.Bottom - $popup.Height))
        $popup.Location = New-Object System.Drawing.Point([int]$popX, [int]$popY)
    } else {
        $popup.Location = New-Object System.Drawing.Point(
            ($screen.Right - $popup.Width - 10),
            ($screen.Bottom - $popup.Height - 10)
        )
    }

    # Mouse leave on popup - start dismiss check
    $popup.Add_MouseLeave({
        $script:dismissTimer.Start()
    })

    # Mouse enter on popup - cancel dismiss
    $popup.Add_MouseEnter({
        $script:dismissTimer.Stop()
    })

    # Close on Escape
    $popup.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            Close-HoverPopup
        }
    })

    # Store reference and show with fade-in
    $script:hoverPopup = $popup
    $script:hoverPopupVisible = $true
    # Stop any running fade-out
    if ($null -ne $script:fadeOutTimer) { $script:fadeOutTimer.Stop() }
    $popup.Opacity = 0
    $popup.Show()
    # Fade-in timer (150ms total, +0.11 per 16ms tick)
    if ($null -eq $script:fadeInTimer) {
        $script:fadeInTimer = New-Object System.Windows.Forms.Timer
        $script:fadeInTimer.Interval = 16
        $script:fadeInTimer.Add_Tick({
            if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
                $newOpacity = $script:hoverPopup.Opacity + 0.11
                if ($newOpacity -ge 1.0) {
                    $script:hoverPopup.Opacity = 1.0
                    $script:fadeInTimer.Stop()
                } else {
                    $script:hoverPopup.Opacity = $newOpacity
                }
            } else {
                $script:fadeInTimer.Stop()
            }
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
    $popup.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 30)
    $popup.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $popup.KeyPreview = $true
    Enable-DoubleBuffering -Form $popup

    # Rounded border
    $popup.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $r = 10
        $rd2 = $r * 2
        $bw = $sender.Width - 1
        $bh = $sender.Height - 1
        $borderPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $borderPath.AddArc(0, 0, $rd2, $rd2, 180, 90)
        $borderPath.AddArc($bw - $rd2, 0, $rd2, $rd2, 270, 90)
        $borderPath.AddArc($bw - $rd2, $bh - $rd2, $rd2, $rd2, 0, 90)
        $borderPath.AddArc(0, $bh - $rd2, $rd2, $rd2, 90, 90)
        $borderPath.CloseFigure()
        $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 60, 66), 1)
        $g.DrawPath($borderPen, $borderPath)
        $borderPen.Dispose()
        $borderPath.Dispose()
    })

    # DPI-aware popup layout
    $gDpi2 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $dpiScale = $gDpi2.DpiX / 96.0
    $gDpi2.Dispose()

    $statusColor = Get-StatusColor -Status $BatteryInfo.StatusText
    $lightGray = [System.Drawing.Color]::FromArgb(220, 220, 225)
    $dimGray   = [System.Drawing.Color]::FromArgb(145, 145, 155)
    $labelFont = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)
    $valueFont = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)

    $popupW = [int](360 * $dpiScale)
    $popup.Size = New-Object System.Drawing.Size($popupW, 400)

    # --- Title ---
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Battery Details"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $titleLabel.Location = New-Object System.Drawing.Point(20, 10)
    $titleLabel.AutoSize = $true
    $titleLabel.MaximumSize = New-Object System.Drawing.Size(($popupW - 40), 0)
    $popup.Controls.Add($titleLabel)

    # Separator line under title
    $sepLabel = New-Object System.Windows.Forms.Label
    $sepLabel.Location = New-Object System.Drawing.Point(20, 32)
    $sepLabel.Size = New-Object System.Drawing.Size(($popupW - 40), 1)
    $sepLabel.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $popup.Controls.Add($sepLabel)

    # --- Row layout (DPI-aware) ---
    $rh = [int](19 * $dpiScale)
    $lx = 20
    $vx = [int](82 * $dpiScale)
    $lw = [int](72 * $dpiScale)
    $vw = $popupW - $vx - 20
    $y = [int](38 * $dpiScale)

    # Helper function (not scriptblock) to add a row
    function Add-PopupRow {
        param($Form, $Y, $Label, $Value, $LabelFont, $ValueFont, $DimColor, $ValueColor, $Lx, $Vx, $Lw, $Vw)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Label
        $lbl.Font = $LabelFont
        $lbl.ForeColor = $DimColor
        $lbl.Location = New-Object System.Drawing.Point($Lx, $Y)
        $lbl.AutoSize = $true
        $lbl.MaximumSize = New-Object System.Drawing.Size($Lw, 0)
        $Form.Controls.Add($lbl)

        $val = New-Object System.Windows.Forms.Label
        $val.Text = $Value
        $val.Font = $ValueFont
        $val.ForeColor = $ValueColor
        $val.Location = New-Object System.Drawing.Point($Vx, $Y)
        $val.AutoSize = $true
        $val.MaximumSize = New-Object System.Drawing.Size($Vw, 0)
        $Form.Controls.Add($val)
    }

    # Row 1: Percent
    $pctText = if ($BatteryInfo.NoBattery) { "No Battery" } else { "$($BatteryInfo.PercentExact)%" }
    Add-PopupRow -Form $popup -Y $y -Label "Percent:" -Value $pctText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $statusColor -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 2: Capacity (current charge / full charge capacity)
    if ($BatteryInfo.FullChargeCapacity -gt 0 -and $BatteryInfo.PercentExact -ge 0) {
        $currentCharge = [math]::Round($BatteryInfo.FullChargeCapacity * ($BatteryInfo.PercentExact / 100))
        $capText = "{0:N0} / {1:N0} mWh" -f $currentCharge, $BatteryInfo.FullChargeCapacity
    } elseif ($BatteryInfo.FullChargeCapacity -gt 0) {
        $capText = "{0:N0} mWh" -f $BatteryInfo.FullChargeCapacity
    } else {
        $capText = "N/A"
    }
    Add-PopupRow -Form $popup -Y $y -Label "Capacity:" -Value $capText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 3: Discharge/Charge Rate
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
    Add-PopupRow -Form $popup -Y $y -Label "Rate:" -Value $rateText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $rateColor -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 4: Time Remaining with ETA
    if ($BatteryInfo.IsFullyCharged) {
        $timeText = "Fully Charged"
    } elseif ($BatteryInfo.TimeMinutes -gt 0) {
        $h = [math]::Floor($BatteryInfo.TimeMinutes / 60)
        $m = $BatteryInfo.TimeMinutes % 60
        $shortTime = "{0}:{1:D2}" -f $h, $m
        if ($BatteryInfo.ETA) {
            $timeText = "$shortTime (until $($BatteryInfo.ETA))"
        } else {
            $timeText = $shortTime
        }
    } else {
        $timeText = "Estimating..."
    }
    $timeRowLabel = if ($BatteryInfo.IsCharging) { "To Full:" } else { "Remaining:" }
    Add-PopupRow -Form $popup -Y $y -Label $timeRowLabel -Value $timeText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 5: Elapsed Time
    $elapsedText = "$($BatteryInfo.ElapsedTime) (from $($BatteryInfo.ElapsedSince))"
    Add-PopupRow -Form $popup -Y $y -Label "Elapsed:" -Value $elapsedText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 6: Full Runtime
    if ($BatteryInfo.FullRuntimeMinutes -gt 0) {
        $frH = [math]::Floor($BatteryInfo.FullRuntimeMinutes / 60)
        $frM = $BatteryInfo.FullRuntimeMinutes % 60
        $fullRtText = "{0}:{1:D2}" -f $frH, $frM
    } else {
        $fullRtText = "N/A"
    }
    Add-PopupRow -Form $popup -Y $y -Label "Runtime:" -Value $fullRtText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Row 7: Battery Wear (with design capacity)
    if ($BatteryInfo.BatteryWearPercent -ge 0 -and $BatteryInfo.DesignCapacity -gt 0) {
        $wearText = "{0:N1}% of {1:N0} mWh" -f $BatteryInfo.BatteryWearPercent, $BatteryInfo.DesignCapacity
    } else {
        $wearText = "N/A"
    }
    Add-PopupRow -Form $popup -Y $y -Label "Wear:" -Value $wearText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
    $y += $rh

    # Spacer
    $y += [int](4 * $dpiScale)

    # Battery history sparkline
    $sparkAccent2 = Get-AccentColor -Percent $BatteryInfo.Percent -IsCharging $BatteryInfo.IsCharging
    $sparkPanel2 = New-SparklinePanel -Y $y -AccentColor $sparkAccent2
    $sparkPanel2.Size = New-Object System.Drawing.Size(($popupW - 40), 30)
    $popup.Controls.Add($sparkPanel2)
    $y += 32

    # Custom GDI+ progress bar
    $barPct = [math]::Max(0, [math]::Min(100, $BatteryInfo.Percent))
    $barAccent = $sparkAccent2
    $barW = $popupW - 40
    $progressPanel = New-Object System.Windows.Forms.Panel
    $progressPanel.Location = New-Object System.Drawing.Point(20, $y)
    $progressPanel.Size = New-Object System.Drawing.Size($barW, 12)
    $progressPanel.BackColor = [System.Drawing.Color]::Transparent
    $progressPanel.Tag = @{ Percent = $barPct; AccentColor = $barAccent }
    $progressPanel.Add_Paint({
        param($sender, $e)
        $pg = $e.Graphics
        $pg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pw2 = $sender.Width
        $ph2 = $sender.Height
        $pr = 7
        $pd = $pr * 2
        $trackPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $trackPath.AddArc(0, 0, $pd, $pd, 180, 90)
        $trackPath.AddArc($pw2 - $pd - 1, 0, $pd, $pd, 270, 90)
        $trackPath.AddArc($pw2 - $pd - 1, $ph2 - $pd - 1, $pd, $pd, 0, 90)
        $trackPath.AddArc(0, $ph2 - $pd - 1, $pd, $pd, 90, 90)
        $trackPath.CloseFigure()
        $trackBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, 40, 46))
        $pg.FillPath($trackBrush, $trackPath)
        $trackBrush.Dispose()
        $tagData = $sender.Tag
        $fillPct = $tagData.Percent
        $acColor = $tagData.AccentColor
        $fw = [math]::Max(0, [math]::Round(($fillPct / 100) * $pw2))
        if ($fw -gt $pd) {
            $fillPath = New-Object System.Drawing.Drawing2D.GraphicsPath
            $fillPath.AddArc(0, 0, $pd, $pd, 180, 90)
            $fillPath.AddArc($fw - $pd - 1, 0, $pd, $pd, 270, 90)
            $fillPath.AddArc($fw - $pd - 1, $ph2 - $pd - 1, $pd, $pd, 0, 90)
            $fillPath.AddArc(0, $ph2 - $pd - 1, $pd, $pd, 90, 90)
            $fillPath.CloseFigure()
            $fillRect2 = New-Object System.Drawing.Rectangle(0, 0, [math]::Max(1, $fw), $ph2)
            $fLeft = [System.Drawing.Color]::FromArgb(200, $acColor.R, $acColor.G, $acColor.B)
            $fRight = [System.Drawing.Color]::FromArgb(140, $acColor.R, $acColor.G, $acColor.B)
            $fillBrush2 = New-Object System.Drawing.Drawing2D.LinearGradientBrush($fillRect2, $fLeft, $fRight, [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            $pg.FillPath($fillBrush2, $fillPath)
            $fillBrush2.Dispose()
            $glassRect = New-Object System.Drawing.Rectangle(0, 0, $fw, [int]($ph2 / 2))
            $glassBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($glassRect, [System.Drawing.Color]::FromArgb(40, 255, 255, 255), [System.Drawing.Color]::FromArgb(0, 255, 255, 255), [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
            $oldClip3 = $pg.Clip
            $pg.SetClip($fillPath)
            $pg.FillRectangle($glassBrush, $glassRect)
            $pg.Clip = $oldClip3
            $glassBrush.Dispose()
            $fillPath.Dispose()
        }
        $borderPen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(55, 55, 62), 1)
        $pg.DrawPath($borderPen2, $trackPath)
        $borderPen2.Dispose()
        $trackPath.Dispose()
    })
    $popup.Controls.Add($progressPanel)

    $y += 14

    # Power source
    $powerLabel = New-Object System.Windows.Forms.Label
    $powerLabel.Text = $BatteryInfo.PowerSource
    $powerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Regular)
    $powerLabel.ForeColor = $dimGray
    $powerLabel.Location = New-Object System.Drawing.Point(20, $y)
    $powerLabel.AutoSize = $true
    $powerLabel.MaximumSize = New-Object System.Drawing.Size(($popupW - 40), 0)
    $popup.Controls.Add($powerLabel)

    $y += 16

    # Close hint
    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Text = "Click outside or press Esc to close"
    $hintLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Regular)
    $hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 86)
    $hintLabel.Location = New-Object System.Drawing.Point(20, $y)
    $hintLabel.AutoSize = $true
    $hintLabel.MaximumSize = New-Object System.Drawing.Size(($popupW - 40), 0)
    $popup.Controls.Add($hintLabel)

    # Resize form to fit content
    $popup.ClientSize = New-Object System.Drawing.Size($popupW, ($y + 12))

    # Set rounded region to clip corners
    $popupRadius = 10
    $prd = $popupRadius * 2
    $pw = $popup.ClientSize.Width
    $ph = $popup.ClientSize.Height
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
        if ($popY -lt $screen.Top) {
            $popY = $barLoc.Y + $barSize.Height + 8
        }
        $popX = [math]::Max($screen.Left, [math]::Min($popX, $screen.Right - $popup.Width))
        $popY = [math]::Max($screen.Top, [math]::Min($popY, $screen.Bottom - $popup.Height))
        $popup.Location = New-Object System.Drawing.Point([int]$popX, [int]$popY)
    } else {
        $popup.Location = New-Object System.Drawing.Point(
            ($screen.Right - $popup.Width - 10),
            ($screen.Bottom - $popup.Height - 10)
        )
    }

    # Close on deactivate
    $popup.Add_Deactivate({ $popup.Close() })

    # Close on Escape
    $popup.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $popup.Close()
        }
    })

    $popup.ShowDialog() | Out-Null
    $popup.Dispose()
}

# ============================================================
# SETTINGS PANEL
# ============================================================

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

    $labelFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $m = [int](20 * $ds)
    $cw = [int](280 * $ds)
    $bh = [int](34 * $ds)
    $y = $m

    # --- Checkboxes section ---

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
    $y += [int](46 * $ds)

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
    $settings.Controls.Add($displayCombo)
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
    $settings.Controls.Add($sizeCombo)
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
        $colorPanel.Tag = $ci
        $colorPanel.Add_Paint({
            param($sender, $e)
            $cg = $e.Graphics
            $cg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $idx = $sender.Tag
            $color = $script:accentPresets[$idx]
            $brush = New-Object System.Drawing.SolidBrush($color)
            $cg.FillEllipse($brush, 2, 2, $sender.Width - 5, $sender.Height - 5)
            $brush.Dispose()
            # Selection ring
            if ($idx -eq $script:config.AccentColorIndex) {
                $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)
                $cg.DrawEllipse($ringPen, 1, 1, $sender.Width - 3, $sender.Height - 3)
                $ringPen.Dispose()
            }
        })
        $colorPanel.Add_Click({
            param($sender)
            $script:config.AccentColorIndex = $sender.Tag
            Save-Config
            # Repaint all color circles to update selection ring
            foreach ($ctrl in $settings.Controls) {
                if ($ctrl -is [System.Windows.Forms.Panel] -and $null -ne $ctrl.Tag -and $ctrl.Tag -is [int] -and $ctrl.Tag -ge 0 -and $ctrl.Tag -le 7) {
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
    $settings.Controls.Add($themeCombo)
    $y += [int](54 * $ds)

    # --- Opacity section ---

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
        Save-Config
    })
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
    $settings.Controls.Add($refreshCombo)
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
    })
    $settings.Controls.Add($resetBtn)
    $y += [int](38 * $ds)

    # Close button (accent green)
    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = "Close"
    $closeBtn.Font = $labelFont
    $closeBtn.Size = New-Object System.Drawing.Size($cw, $bh)
    $closeBtn.Location = New-Object System.Drawing.Point($m, $y)
    $closeBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeBtn.FlatAppearance.BorderSize = 0
    $closeBtn.BackColor = [System.Drawing.Color]::FromArgb(76, 175, 80)
    $closeBtn.ForeColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $closeBtn.Add_Click({ $settings.Close() })
    $settings.Controls.Add($closeBtn)

    # Auto-size form to fit content
    $settings.ClientSize = New-Object System.Drawing.Size(($cw + $m * 2), ($y + $bh + $m))

    $settings.ShowDialog() | Out-Null
    $settings.Dispose()
}

# ============================================================
# UPDATE FUNCTIONS
# ============================================================

function Update-TrayIcon {
    $info = Get-BatteryInfo

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
        Time = Get-Date
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

# Pill context menu (right-click on floating bar)
$pillContextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$pillHideItem = New-Object System.Windows.Forms.ToolStripMenuItem("Hide Pill")
$pillHideItem.Add_Click({
    $script:floatingBar.Hide()
    # Update tray menu item too
    $toggleBarItem.Text = "Show Bar"
})

$pillSettingsItem = New-Object System.Windows.Forms.ToolStripMenuItem("Settings...")
$pillSettingsItem.Add_Click({ Show-SettingsPanel })

$pillSeparator1 = New-Object System.Windows.Forms.ToolStripSeparator

$pillRefreshItem = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh")
$pillRefreshItem.Add_Click({ Update-TrayIcon })

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
$pillContextMenu.Items.Add($pillSeparator1) | Out-Null
$pillContextMenu.Items.Add($pillRefreshItem) | Out-Null
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

$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh")
$refreshItem.Add_Click({ Update-TrayIcon })

$separatorItem = New-Object System.Windows.Forms.ToolStripSeparator

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
$exitItem.Add_Click({
    $script:timer.Stop()
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    $script:floatingBar.Close()
    $script:mainForm.Close()
})

$contextMenu.Items.Add($toggleBarItem) | Out-Null
$contextMenu.Items.Add($settingsItem) | Out-Null
$contextMenu.Items.Add($refreshItem) | Out-Null
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
$script:pulseTimer.Interval = 50  # 50ms for smooth animation (~20 FPS)
$script:pulseTimer.Add_Tick({
    try {
        $needsRepaint = $false
        if ($script:barIsCharging) {
            # Oscillate alpha between 80 and 180
            $script:pulseAlpha += $script:pulseDirection * 4
            if ($script:pulseAlpha -ge 180) {
                $script:pulseAlpha = 180
                $script:pulseDirection = -1
            } elseif ($script:pulseAlpha -le 80) {
                $script:pulseAlpha = 80
                $script:pulseDirection = 1
            }
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
        if ($needsRepaint -and $null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
            $script:floatingBar.Invalidate()
        }
    } catch {}
})
$script:pulseTimer.Start()

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
    if ($null -ne $script:pillStringFormat) { $script:pillStringFormat.Dispose() }
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
})

# Initial update and start
Update-TrayIcon
$script:timer.Start()

# Run the application message loop
[System.Windows.Forms.Application]::Run($script:mainForm)
