#Requires -Version 5.0

<#
.SYNOPSIS
    Battery Widget - System tray battery monitor with floating desktop bar.
.DESCRIPTION
    Displays a battery icon in the Windows notification area (system tray)
    and a floating draggable bar on the desktop showing time remaining and
    battery percentage. Left-click either to see a detailed popup with
    capacity, discharge rate, ETA, elapsed time, and battery wear.
    Auto-refreshes every 30 seconds.
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

    # Time remaining
    $timeMinutes = -1
    if (-not $info.IsCharging -and -not $info.IsFullyCharged) {
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
# HELPER: STATUS COLOR
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

    $fillColor = Get-StatusColor -Status $Status

    # Battery body outline
    $outlinePen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1)
    $g.DrawRectangle($outlinePen, 1, 3, 11, 9)
    # Positive terminal nub
    $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)), 13, 5, 2, 4)

    # Fill interior proportional to percent
    $maxFill = 10
    $fillWidth = [math]::Max(0, [math]::Min($maxFill, [math]::Round(($Percent / 100) * $maxFill)))
    if ($fillWidth -gt 0) {
        $fillBrush = New-Object System.Drawing.SolidBrush($fillColor)
        $g.FillRectangle($fillBrush, 2, 4, $fillWidth, 8)
        $fillBrush.Dispose()
    }

    # Charging indicator: "+" in yellow
    if ($Status -eq "Charging") {
        $boltPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Yellow, 1)
        $g.DrawLine($boltPen, 6, 4, 6, 11)
        $g.DrawLine($boltPen, 3, 7, 10, 7)
        $boltPen.Dispose()
    }

    $outlinePen.Dispose()
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

function Load-BarPosition {
    $configPath = Get-ConfigPath
    $default = @{ X = -1; Y = -1 }
    if (Test-Path $configPath) {
        try {
            $json = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($null -ne $json.X -and $null -ne $json.Y) {
                return @{ X = [int]$json.X; Y = [int]$json.Y }
            }
        } catch {}
    }
    return $default
}

function Save-BarPosition {
    param([int]$X, [int]$Y)
    $configPath = Get-ConfigPath
    try {
        @{ X = $X; Y = $Y } | ConvertTo-Json | Set-Content $configPath -Force
    } catch {}
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

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.Size = New-Object System.Drawing.Size(90, 28)
    $form.MinimumSize = New-Object System.Drawing.Size(90, 28)
    $form.MaximumSize = New-Object System.Drawing.Size(90, 28)
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Opacity = 0.85

    # Region-based clipping for rounded corners (no TransparencyKey = no purple fringe)
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $regionPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rd = 16
    $regionPath.AddArc(0, 0, $rd, $rd, 180, 90)
    $regionPath.AddArc(90 - $rd - 1, 0, $rd, $rd, 270, 90)
    $regionPath.AddArc(90 - $rd - 1, 28 - $rd - 1, $rd, $rd, 0, 90)
    $regionPath.AddArc(0, 28 - $rd - 1, $rd, $rd, 90, 90)
    $regionPath.CloseFigure()
    $form.Region = New-Object System.Drawing.Region($regionPath)
    $regionPath.Dispose()

    # Enable double-buffering to reduce flicker
    $form.GetType().GetProperty("DoubleBuffered",
        [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    ).SetValue($form, $true, $null)

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
            $ac = $script:barAccentColor
            $fillLeft  = [System.Drawing.Color]::FromArgb(120, $ac.R, $ac.G, $ac.B)
            $fillRight = [System.Drawing.Color]::FromArgb(80, $ac.R, $ac.G, $ac.B)
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
        $textFont = New-Object System.Drawing.Font("Segoe UI Semibold", 8.5, [System.Drawing.FontStyle]::Bold)
        $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 245, 250))
        $textRect = New-Object System.Drawing.RectangleF(0, 0, $w, $h)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString($script:barDisplayText, $textFont, $textBrush, $textRect, $sf)
        $textFont.Dispose()
        $textBrush.Dispose()
        $sf.Dispose()

        # --- Border ---
        $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, 50, 56), 1)
        $g.DrawPath($borderPen, $path)
        $borderPen.Dispose()

        $path.Dispose()
    })

    # Drag handling — track if mouse actually moved to distinguish click vs drag
    $script:isDragging = $false
    $script:didDrag = $false
    $script:dragOffset = New-Object System.Drawing.Point(0, 0)

    $dragDown = {
        param($sender, $e)
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
                Save-BarPosition -X $script:floatingBar.Left -Y $script:floatingBar.Top
            } else {
                # Single click — open popup
                $currentInfo = Get-BatteryInfo
                Show-BatteryPopup -BatteryInfo $currentInfo
            }
        }
    }

    # Apply drag/click events to form only (no label — everything is paint-drawn)
    $form.Add_MouseDown($dragDown)
    $form.Add_MouseMove($dragMove)
    $form.Add_MouseUp($dragUp)

    # Set position
    $pos = Load-BarPosition
    if ($pos.X -ge 0 -and $pos.Y -ge 0) {
        $form.Location = New-Object System.Drawing.Point($pos.X, $pos.Y)
    } else {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Location = New-Object System.Drawing.Point(
            ($screen.Right - $form.Width - 10),
            ($screen.Bottom - $form.Height - 10)
        )
    }

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

    # Accent color — always green (fill level conveys charge state)
    $script:barAccentColor = [System.Drawing.Color]::FromArgb(45, 212, 100)

    # Trigger repaint
    $script:floatingBar.Invalidate()
}

# ============================================================
# DETAIL POPUP WINDOW
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

    # Position near the floating pill
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
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
        $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 60, 66), 1)
        $g.DrawRectangle($borderPen, 0, 0, $sender.Width - 1, $sender.Height - 1)
        $borderPen.Dispose()
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

    # Row 2: Capacity
    if ($BatteryInfo.FullChargeCapacity -gt 0 -and $BatteryInfo.DesignCapacity -gt 0) {
        $capText = "{0:N0} / {1:N0} mWh" -f $BatteryInfo.FullChargeCapacity, $BatteryInfo.DesignCapacity
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
        $wearText = "{0:N1}%" -f $BatteryInfo.BatteryWearPercent
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
# UPDATE FUNCTIONS
# ============================================================

function Update-TrayIcon {
    $info = Get-BatteryInfo

    # Destroy previous icon handle
    if ($script:lastIconHandle) {
        [Win32Icon]::DestroyIcon($script:lastIconHandle) | Out-Null
        $script:lastIconHandle = $null
    }

    $iconResult = New-BatteryIcon -Percent $info.Percent -Status $info.StatusText
    $script:lastIconHandle = $iconResult.Handle
    $script:notifyIcon.Icon = $iconResult.Icon

    # Build tooltip (max 127 chars)
    if ($info.NoBattery) {
        $script:notifyIcon.Text = "Battery Widget: No battery detected"
    } else {
        $tipText = "Battery: $($info.Percent)% - $($info.StatusText)"
        if ($info.TimeString -and $info.TimeString -ne "N/A (plugged in)") {
            $tipText += " | $($info.TimeString)"
        }
        if ($tipText.Length -gt 127) { $tipText = $tipText.Substring(0, 127) }
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

$script:lastIconHandle = $null
$script:lastBatteryInfo = $null

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

# Context menu
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
$script:timer.Interval = 30000
$script:timer.Add_Tick({ Update-TrayIcon })

# Cleanup on form closing
$script:mainForm.Add_FormClosing({
    $script:timer.Stop()
    $script:timer.Dispose()
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    if ($script:floatingBar -and -not $script:floatingBar.IsDisposed) {
        $script:floatingBar.Close()
        $script:floatingBar.Dispose()
    }
    if ($script:lastIconHandle) {
        [Win32Icon]::DestroyIcon($script:lastIconHandle) | Out-Null
    }
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
})

# Initial update and start
Update-TrayIcon
$script:timer.Start()

# Run the application message loop
[System.Windows.Forms.Application]::Run($script:mainForm)
