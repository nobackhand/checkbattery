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

# P/Invoke for proper icon handle cleanup and DPI awareness
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Icon {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public extern static bool DestroyIcon(IntPtr handle);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
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

# --- Elapsed time tracking state ---
$script:lastStateChange = @{
    Time    = Get-Date
    Percent = -1
    State   = ""
}

# --- EMA smoothing state for stable battery estimates ---
$script:emaRate = -1           # Smoothed rate (mW) using Exponential Moving Average
$script:lastValidRate = -1     # Last known good rate (for "hold" logic when rate unavailable)

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

function Get-AccentColor {
    param(
        [int]$Percent,
        [bool]$IsCharging
    )
    # Yellow when charging (any level)
    if ($IsCharging) {
        return [System.Drawing.Color]::FromArgb(255, 200, 0)
    }
    # Color-coded by battery level
    if ($Percent -le 10) {
        return [System.Drawing.Color]::FromArgb(255, 70, 70)   # Red - critical
    }
    if ($Percent -le 20) {
        return [System.Drawing.Color]::FromArgb(255, 140, 0)   # Orange - low
    }
    if ($Percent -le 50) {
        return [System.Drawing.Color]::FromArgb(255, 200, 0)   # Yellow - medium
    }
    return [System.Drawing.Color]::FromArgb(45, 212, 100)      # Green - good
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

    # Cached GDI objects for paint handler (avoid per-frame allocation)
    $script:pillFont = New-Object System.Drawing.Font("Segoe UI Semibold", 10.2, [System.Drawing.FontStyle]::Bold)
    $script:pillStringFormat = New-Object System.Drawing.StringFormat
    $script:pillStringFormat.Alignment = [System.Drawing.StringAlignment]::Center
    $script:pillStringFormat.LineAlignment = [System.Drawing.StringAlignment]::Center

    # Hover popup state
    $script:hoverPopup = $null
    $script:hoverPopupVisible = $false

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.Size = New-Object System.Drawing.Size(108, 34)
    $form.MinimumSize = New-Object System.Drawing.Size(108, 34)
    $form.MaximumSize = New-Object System.Drawing.Size(108, 34)
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Opacity = $script:config.Opacity

    # Region-based clipping for rounded corners (no TransparencyKey = no purple fringe)
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $regionPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rd = 16
    $regionPath.AddArc(0, 0, $rd, $rd, 180, 90)
    $regionPath.AddArc(108 - $rd - 1, 0, $rd, $rd, 270, 90)
    $regionPath.AddArc(108 - $rd - 1, 34 - $rd - 1, $rd, $rd, 0, 90)
    $regionPath.AddArc(0, 34 - $rd - 1, $rd, $rd, 90, 90)
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

        # --- Dark background (entire pill) ---
        $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(24, 24, 28))
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

        # --- Top highlight (glass edge) ---
        $highlightPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(30, 255, 255, 255), 1)
        $g.DrawLine($highlightPen, $radius, 1, $w - $radius - 1, 1)
        $highlightPen.Dispose()

        # --- Time text (centered in full pill) ---
        $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 245, 250))
        $textRect = New-Object System.Drawing.RectangleF(0, 0, $w, $h)
        $g.DrawString($script:barDisplayText, $script:pillFont, $textBrush, $textRect, $script:pillStringFormat)
        $textBrush.Dispose()

        # --- Border ---
        $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, 50, 56), 1)
        $g.DrawPath($borderPen, $path)
        $borderPen.Dispose()

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

function Update-FloatingBar {
    param([hashtable]$BatteryInfo)

    if ($null -eq $script:floatingBar -or $script:floatingBar.IsDisposed) { return }

    # Update display text — time remaining
    if ($BatteryInfo.NoBattery) {
        $script:barDisplayText = "N/A"
    } elseif ($BatteryInfo.IsFullyCharged) {
        $script:barDisplayText = "Full"
    } elseif ($BatteryInfo.TimeMinutes -gt 0) {
        $h = [math]::Floor($BatteryInfo.TimeMinutes / 60)
        $m = $BatteryInfo.TimeMinutes % 60
        if ($h -gt 0) {
            $script:barDisplayText = "${h}h ${m}m"
        } else {
            $script:barDisplayText = "${m}m"
        }
    } else {
        $script:barDisplayText = "--:--"
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

    # Accent color — color-coded by battery level
    $script:barAccentColor = Get-AccentColor -Percent $BatteryInfo.Percent -IsCharging $BatteryInfo.IsCharging

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
        $script:hoverPopup.Close()
        $script:hoverPopup.Dispose()
        $script:hoverPopup = $null
    }
    $script:hoverPopupVisible = $false
}

function Show-HoverPopup {
    # Close any existing popup first
    Close-HoverPopup

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

    # Position near the floating pill (use correct screen for multi-monitor)
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $screen = [System.Windows.Forms.Screen]::FromPoint($script:floatingBar.Location).WorkingArea
    } else {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    }
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $barLoc = $script:floatingBar.Location
        $barSize = $script:floatingBar.Size
        # Place popup above the pill, centered horizontally
        $popX = $barLoc.X + ($barSize.Width / 2) - ($popup.Width / 2)
        $popY = $barLoc.Y - $popup.Height - 8
        # If above doesn't fit, place below
        if ($popY -lt $screen.Top) {
            $popY = $barLoc.Y + $barSize.Height + 8
        }
        # Clamp to screen bounds
        $popX = [math]::Max($screen.Left, [math]::Min($popX, $screen.Right - $popup.Width))
        $popY = [math]::Max($screen.Top, [math]::Min($popY, $screen.Bottom - $popup.Height))
        $popup.Location = New-Object System.Drawing.Point([int]$popX, [int]$popY)
    } else {
        $popup.Location = New-Object System.Drawing.Point(
            ($screen.Right - $popup.Width - 10),
            ($screen.Bottom - $popup.Height - 10)
        )
    }

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

    $statusColor = Get-StatusColor -Status $BatteryInfo.StatusText
    $lightGray = [System.Drawing.Color]::FromArgb(220, 220, 225)
    $dimGray   = [System.Drawing.Color]::FromArgb(145, 145, 155)
    $labelFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $valueFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)

    # --- Title ---
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Battery Details"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $titleLabel.Location = New-Object System.Drawing.Point(20, 14)
    $titleLabel.AutoSize = $true
    $titleLabel.MaximumSize = New-Object System.Drawing.Size(380, 0)
    $popup.Controls.Add($titleLabel)

    # Separator line under title
    $sepLabel = New-Object System.Windows.Forms.Label
    $sepLabel.Location = New-Object System.Drawing.Point(20, 42)
    $sepLabel.Size = New-Object System.Drawing.Size(380, 1)
    $sepLabel.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $popup.Controls.Add($sepLabel)

    # --- Row layout ---
    $rh = 34
    $lx = 20
    $vx = 175
    $lw = 150
    $vw = 225
    $y = 56

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
    $timeRowLabel = if ($BatteryInfo.IsCharging) { "Time to Full:" } else { "Remaining:" }
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
    Add-PopupRow -Form $popup -Y $y -Label "Full Runtime:" -Value $fullRtText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
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
    $y += 14

    # Progress bar
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(20, $y)
    $progressBar.Size = New-Object System.Drawing.Size(380, 22)
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Value = [math]::Max(0, [math]::Min(100, $BatteryInfo.Percent))
    $popup.Controls.Add($progressBar)

    $y += 34

    # Power source
    $powerLabel = New-Object System.Windows.Forms.Label
    $powerLabel.Text = $BatteryInfo.PowerSource
    $powerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
    $powerLabel.ForeColor = $dimGray
    $powerLabel.Location = New-Object System.Drawing.Point(20, $y)
    $powerLabel.AutoSize = $true
    $powerLabel.MaximumSize = New-Object System.Drawing.Size(380, 0)
    $popup.Controls.Add($powerLabel)

    $y += 24

    # Close hint
    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Text = "Move mouse away to close"
    $hintLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)
    $hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 86)
    $hintLabel.Location = New-Object System.Drawing.Point(20, $y)
    $hintLabel.AutoSize = $true
    $hintLabel.MaximumSize = New-Object System.Drawing.Size(380, 0)
    $popup.Controls.Add($hintLabel)

    # Resize form to fit content
    $popup.ClientSize = New-Object System.Drawing.Size(420, ($y + 24))

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

    # Store reference and show (non-modal)
    $script:hoverPopup = $popup
    $script:hoverPopupVisible = $true
    $popup.Show()
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

    # Position near the floating pill (use correct screen for multi-monitor)
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $screen = [System.Windows.Forms.Screen]::FromPoint($script:floatingBar.Location).WorkingArea
    } else {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    }
    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $barLoc = $script:floatingBar.Location
        $barSize = $script:floatingBar.Size
        # Place popup above the pill, centered horizontally
        $popX = $barLoc.X + ($barSize.Width / 2) - ($popup.Width / 2)
        $popY = $barLoc.Y - $popup.Height - 8
        # If above doesn't fit, place below
        if ($popY -lt $screen.Top) {
            $popY = $barLoc.Y + $barSize.Height + 8
        }
        # Clamp to screen bounds
        $popX = [math]::Max($screen.Left, [math]::Min($popX, $screen.Right - $popup.Width))
        $popY = [math]::Max($screen.Top, [math]::Min($popY, $screen.Bottom - $popup.Height))
        $popup.Location = New-Object System.Drawing.Point([int]$popX, [int]$popY)
    } else {
        $popup.Location = New-Object System.Drawing.Point(
            ($screen.Right - $popup.Width - 10),
            ($screen.Bottom - $popup.Height - 10)
        )
    }

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

    $statusColor = Get-StatusColor -Status $BatteryInfo.StatusText
    $lightGray = [System.Drawing.Color]::FromArgb(220, 220, 225)
    $dimGray   = [System.Drawing.Color]::FromArgb(145, 145, 155)
    $labelFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $valueFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)

    # --- Title ---
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Battery Details"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    $titleLabel.Location = New-Object System.Drawing.Point(20, 14)
    $titleLabel.AutoSize = $true
    $titleLabel.MaximumSize = New-Object System.Drawing.Size(380, 0)
    $popup.Controls.Add($titleLabel)

    # Separator line under title
    $sepLabel = New-Object System.Windows.Forms.Label
    $sepLabel.Location = New-Object System.Drawing.Point(20, 42)
    $sepLabel.Size = New-Object System.Drawing.Size(380, 1)
    $sepLabel.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $popup.Controls.Add($sepLabel)

    # --- Row layout: explicit Y positions (no scriptblock scoping issues) ---
    $rh = 34       # row height
    $lx = 20       # label x
    $vx = 175      # value x
    $lw = 150      # label width
    $vw = 225      # value width
    $y = 56        # starting y

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
    $timeRowLabel = if ($BatteryInfo.IsCharging) { "Time to Full:" } else { "Remaining:" }
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
    Add-PopupRow -Form $popup -Y $y -Label "Full Runtime:" -Value $fullRtText -LabelFont $labelFont -ValueFont $valueFont -DimColor $dimGray -ValueColor $lightGray -Lx $lx -Vx $vx -Lw $lw -Vw $vw
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
    $y += 14

    # Progress bar
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(20, $y)
    $progressBar.Size = New-Object System.Drawing.Size(380, 22)
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Value = [math]::Max(0, [math]::Min(100, $BatteryInfo.Percent))
    $popup.Controls.Add($progressBar)

    $y += 34

    # Power source
    $powerLabel = New-Object System.Windows.Forms.Label
    $powerLabel.Text = $BatteryInfo.PowerSource
    $powerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
    $powerLabel.ForeColor = $dimGray
    $powerLabel.Location = New-Object System.Drawing.Point(20, $y)
    $powerLabel.AutoSize = $true
    $powerLabel.MaximumSize = New-Object System.Drawing.Size(380, 0)
    $popup.Controls.Add($powerLabel)

    $y += 24

    # Close hint
    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Text = "Click outside or press Esc to close"
    $hintLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)
    $hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 86)
    $hintLabel.Location = New-Object System.Drawing.Point(20, $y)
    $hintLabel.AutoSize = $true
    $hintLabel.MaximumSize = New-Object System.Drawing.Size(380, 0)
    $popup.Controls.Add($hintLabel)

    # Resize form to fit content
    $popup.ClientSize = New-Object System.Drawing.Size(420, ($y + 24))

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
    $y += [int](46 * $ds)

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

    $script:lastBatteryInfo = $info
}

# ============================================================
# MAIN APPLICATION SETUP
# ============================================================

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:config = Load-Config
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
            # Trigger repaint
            if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
                $script:floatingBar.Invalidate()
            }
        }
    } catch {}
})
$script:pulseTimer.Start()

# Cleanup on form closing
$script:mainForm.Add_FormClosing({
    $script:timer.Stop()
    $script:timer.Dispose()
    $script:pulseTimer.Stop()
    $script:pulseTimer.Dispose()
    # Clean up hover timers
    if ($null -ne $script:hoverTimer) {
        $script:hoverTimer.Stop()
        $script:hoverTimer.Dispose()
    }
    if ($null -ne $script:dismissTimer) {
        $script:dismissTimer.Stop()
        $script:dismissTimer.Dispose()
    }
    # Close hover popup if open
    Close-HoverPopup
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
