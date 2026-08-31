# ============================================================
# UPDATE FUNCTIONS
# ============================================================

function Add-BatteryHistorySample {
    [OutputType([void])]
    param(
        [hashtable]$Info,
        [datetime]$Now
    )
    # Record one sample for the sparkline (cap 2400 = ~2h at 3s intervals).
    #
    # The percent guard is the point. The old test was `-not $Info.NoBattery`,
    # but NoBattery only means the battery is ABSENT. A battery that is
    # present and merely unreadable this tick (CIM query throws, .NET reports
    # the 255 unknown sentinel) yields Percent = -1 with NoBattery = $false,
    # so -1 was recorded as if it were a real reading. It then plotted below
    # the sparkline's baseline, printed "-1%" in the scrub readout, and - worst
    # - was subtracted as a percentage by the session summary, which reported
    # "used 51%" for a battery that had dropped 5 points.
    # Import-Config already drops out-of-range entries on reload, so the live
    # buffer and the persisted one disagreed about the same tick.
    if ($Info.NoBattery) { return }
    if ($Info.Percent -lt 0 -or $Info.Percent -gt 100) { return }
    $null = $script:batteryHistory.Add(@{
            Time       = $Now
            Percent    = $Info.Percent
            IsCharging = $Info.IsCharging
        })
    while ($script:batteryHistory.Count -gt 2400) {
        $script:batteryHistory.RemoveAt(0)
    }
}

function Update-TrayIcon {
    [OutputType([void])]
    param()
    $now = Get-Date
    $info = Get-BatteryInfo -Now $now

    # While charging, advance a 4-step gloss phase each tick so the tray icon
    # subtly animates its fill (skipped when Windows animations are off)
    if ($info.IsCharging -and $script:animOK) {
        $script:trayAnimPhase = ($script:trayAnimPhase + 1) % 4
    }

    # Only regenerate icon when state actually changes (or every tick while the
    # charging animation is running)
    $needsNewIcon = ($info.Percent -ne $script:cachedIconPercent) -or
    ($info.IsCharging -ne $script:cachedIconCharging) -or
    ($info.IsFullyCharged -ne $script:cachedIconFullyCharged) -or
    ($info.IsCharging -and $script:animOK)

    if ($needsNewIcon) {
        # Destroy previous icon handle
        if ($script:lastIconHandle) {
            [Win32Icon]::DestroyIcon($script:lastIconHandle) | Out-Null
            $script:lastIconHandle = $null
        }

        $animPhase = if ($info.IsCharging -and $script:animOK) { $script:trayAnimPhase } else { -1 }
        $iconResult = New-BatteryIcon -Percent $info.Percent -Status $info.StatusText -AnimPhase $animPhase
        $script:lastIconHandle = $iconResult.Handle
        $script:notifyIcon.Icon = $iconResult.Icon

        $script:cachedIconPercent = $info.Percent
        $script:cachedIconCharging = $info.IsCharging
        $script:cachedIconFullyCharged = $info.IsFullyCharged
    }

    # Build tooltip (NotifyIcon.Text caps at 63 chars)
    if ($info.NoBattery) {
        $script:notifyIcon.Text = "BatteryPill - on AC power (no battery detected)"
    } else {
        $tipText = "BatteryPill: $($info.Percent)% - $($info.StatusText)"
        if ($info.TimeString -and $info.TimeString -ne "N/A (plugged in)") {
            $tipText += " | $($info.TimeString)"
        }
        # NotifyIcon.Text throws ArgumentOutOfRangeException above 63 characters
        # (verified) - the old 127 guard was the Win32 NOTIFYICONDATA size, not
        # the .NET one, so an over-long tooltip would throw out of
        # Update-TrayIcon and take the pill's whole refresh with it.
        if ($tipText.Length -gt 63) { $tipText = $tipText.Substring(0, 60) + "..." }
        $script:notifyIcon.Text = $tipText
    }

    # Update floating bar
    Update-FloatingBar -BatteryInfo $info

    # Keep any open popup's numbers honest: percent, title, time sentence,
    # fun line and sparkline all refresh with this reading (a held-open popup
    # used to freeze at whatever was true when it opened)
    Update-OpenPopupContent -BatteryInfo $info

    Add-BatteryHistorySample -Info $info -Now $now

    $script:lastBatteryInfo = $info
}

# ============================================================
# MAIN APPLICATION SETUP
# ============================================================

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:config = Import-Config
Set-Theme
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
$script:trayAnimPhase = 0

# Hidden main form (message pump owner)
$script:mainForm = New-Object System.Windows.Forms.Form
$script:mainForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$script:mainForm.ShowInTaskbar = $false
$script:mainForm.Visible = $false
$script:mainForm.Text = "BatteryPill"

# NotifyIcon
$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:notifyIcon.Visible = $true

# Floating bar. Starts invisible when animations are on - Start-IntroAnimation
# (after the first real battery read) raises it into place, sweeps the fill,
# then shows the first-run tips in sequence instead of racing them.
$script:floatingBar = New-FloatingBar
if ($script:config.Animations) {
    $script:floatingBar.Opacity = 0
}
$script:floatingBar.Show()

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
    if ($null -eq $script:floatingBar -or $script:floatingBar.IsDisposed) { return }
    $bw = $script:floatingBar.Width
    $bh = $script:floatingBar.Height
    $action = Get-DisplayChangeAction `
        -SavedPositionValid (Test-PositionOnScreen -X $script:config.X -Y $script:config.Y -Width $bw -Height $bh) `
        -CurrentPositionValid (Test-PositionOnScreen -X $script:floatingBar.Left -Y $script:floatingBar.Top -Width $bw -Height $bh) `
        -AtSavedPosition (($script:floatingBar.Left -eq $script:config.X) -and ($script:floatingBar.Top -eq $script:config.Y))
    if ($action -eq 'restore') {
        # The layout can host the user's chosen spot again (re-docked, monitor
        # woke up) - put the pill back where they left it.
        $script:floatingBar.Location = New-Object System.Drawing.Point($script:config.X, $script:config.Y)
    } elseif ($action -eq 'park') {
        # Nowhere valid: park it somewhere visible, but deliberately do NOT
        # save - see Get-DisplayChangeAction.
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $script:floatingBar.Location = New-Object System.Drawing.Point(
            ($screen.Right - $bw - 10), ($screen.Bottom - $bh - 10))
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
        # Breadcrumb so a first-timer isn't left wondering where it went
        Show-BatteryNotification -Message "Pill hidden" -SubMessage "Right-click the tray battery icon to show it again" -Accent ([System.Drawing.Color]::FromArgb(45, 212, 100)) -HoldSeconds 6
    })

$pillHealthItem = New-Object System.Windows.Forms.ToolStripMenuItem("Battery Health")
$pillHealthItem.Add_Click({ Show-BatteryHealthCard })

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
        # Close the main form and let its FormClosing handler do ALL teardown.
        # Disposing the NotifyIcon here first made FormClosing's own
        # `$script:notifyIcon.Visible = $false` throw (NotifyIcon.Visible on a
        # disposed instance NREs inside UpdateIcon), which aborted the rest of
        # that handler - so the tray icon handle, the GDI cache, the
        # SystemEvents subscriptions and the single-instance mutex were all
        # left un-released, and the exe surfaced an unhandled-exception dialog
        # on the way out. One owner for teardown, not two.
        $script:mainForm.Close()
    })

$pillContextMenu.Items.Add($pillHideItem) | Out-Null
$pillContextMenu.Items.Add($pillHealthItem) | Out-Null
$pillContextMenu.Items.Add($pillSettingsItem) | Out-Null
$pillContextMenu.Items.Add($pillPowerItem) | Out-Null
$pillContextMenu.Items.Add($pillSeparator1) | Out-Null
$pillContextMenu.Items.Add($pillRefreshItem) | Out-Null
$pillContextMenu.Items.Add($pillAboutItem) | Out-Null
$pillContextMenu.Items.Add($pillSeparator2) | Out-Null
$pillContextMenu.Items.Add($pillExitItem) | Out-Null
Set-MenuTheme -Menu $pillContextMenu

$script:floatingBar.ContextMenuStrip = $pillContextMenu

# Tray context menu
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$toggleBarItem = New-Object System.Windows.Forms.ToolStripMenuItem("Hide Bar")
$toggleBarItem.Add_Click({
        if ($script:floatingBar.Visible) {
            $script:floatingBar.Hide()
            $toggleBarItem.Text = "Show Bar"
            # Breadcrumb so a first-timer isn't left wondering where it went
            Show-BatteryNotification -Message "Pill hidden" -SubMessage "Right-click the tray battery icon to show it again" -Accent ([System.Drawing.Color]::FromArgb(45, 212, 100)) -HoldSeconds 6
        } else {
            $script:floatingBar.Show()
            $toggleBarItem.Text = "Hide Bar"
        }
    })

$healthItem = New-Object System.Windows.Forms.ToolStripMenuItem("Battery Health")
$healthItem.Add_Click({ Show-BatteryHealthCard })

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
        # Close the main form and let its FormClosing handler do ALL teardown.
        # Disposing the NotifyIcon here first made FormClosing's own
        # `$script:notifyIcon.Visible = $false` throw (NotifyIcon.Visible on a
        # disposed instance NREs inside UpdateIcon), which aborted the rest of
        # that handler - so the tray icon handle, the GDI cache, the
        # SystemEvents subscriptions and the single-instance mutex were all
        # left un-released, and the exe surfaced an unhandled-exception dialog
        # on the way out. One owner for teardown, not two.
        $script:mainForm.Close()
    })

$contextMenu.Add_Opening({
        Update-PowerPlanMenu -MenuItem $trayPowerItem
    })

$contextMenu.Items.Add($toggleBarItem) | Out-Null
$contextMenu.Items.Add($healthItem) | Out-Null
$contextMenu.Items.Add($settingsItem) | Out-Null
$contextMenu.Items.Add($trayPowerItem) | Out-Null
$contextMenu.Items.Add($refreshItem) | Out-Null
$contextMenu.Items.Add($aboutItem) | Out-Null
$contextMenu.Items.Add($separatorItem) | Out-Null
$contextMenu.Items.Add($exitItem) | Out-Null
Set-MenuTheme -Menu $contextMenu

# Registered so Set-Theme can re-theme both menus on a live theme switch
$script:appMenus = @($pillContextMenu, $contextMenu)

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
$script:pulseTickCount = 0
$script:pulseTimer.Add_Tick({
        try {
            $needsRepaint = $false
            $script:pulseTickCount++
            # True while something OTHER than the slow charging breath is
            # animating - those need the full 30fps; the 5-second breath alone
            # reads identically at 10fps, so idle charging repaints 3x less
            $fastAnim = ($script:flashAlpha -gt 0) -or
            ($null -ne $script:lowBatPulseActive -and $script:lowBatPulseActive) -or
            ($null -ne $script:shimmerStart) -or ($null -ne $script:boltPopStart) -or
            ($null -ne $script:rippleState) -or
            ($null -ne $script:themeFade) -or
            ($null -ne $script:colorFadeActive -and $script:colorFadeActive) -or
            ($script:textFadeAlpha -lt 255) -or
            ([math]::Abs($script:displayedFillPct - $script:barDisplayPercent) -gt 0.4)
            if ($script:barIsCharging) {
                # Sine-wave breathing pulse: 5-second cycle, alpha 90-120
                $t = (Get-Date).Ticks / 10000000.0
                $script:pulseAlpha = [int](105 + 15 * [Math]::Sin($t * 1.257))
                if ($fastAnim -or ($script:pulseTickCount % 3 -eq 0)) { $needsRepaint = $true }
            }
            # Plug/unplug flash decay (180→0 at 33ms tick, ~8/tick = ~750ms)
            if ($script:flashAlpha -gt 0) {
                $script:flashAlpha = [math]::Max(0, $script:flashAlpha - 12)
                $needsRepaint = $true
            }
            # Fill level eases toward the real percent (smooth transitions)
            if ([math]::Abs($script:displayedFillPct - $script:barDisplayPercent) -gt 0.4) {
                $script:displayedFillPct += ($script:barDisplayPercent - $script:displayedFillPct) * 0.18
                if ([math]::Abs($script:displayedFillPct - $script:barDisplayPercent) -le 0.4) {
                    $script:displayedFillPct = [double]$script:barDisplayPercent
                }
                $needsRepaint = $true
            }
            # Changed pill text fades back in
            if ($script:textFadeAlpha -lt 255) {
                $script:textFadeAlpha = [math]::Min(255, $script:textFadeAlpha + 22)
                $needsRepaint = $true
            }
            # Moment overlays animate purely off elapsed time - just repaint
            if ($null -ne $script:shimmerStart -or $null -ne $script:boltPopStart -or $null -ne $script:rippleState) {
                $needsRepaint = $true
            }
            # Theme switch: crossfade the pill background surface (~220ms)
            if ($null -ne $script:themeFade) {
                $tf = $script:themeFade
                $tft = [math]::Min(1.0, ((Get-Date) - $tf.Start).TotalMilliseconds / 220.0)
                if ($tft -ge 1.0) {
                    $script:themeFade = $null
                    # Land exactly on the theme palette (rebuilds all cached brushes)
                    Initialize-PillBrushes
                    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
                        $script:floatingBar.BackColor = $script:theme.PillBg
                    }
                } else {
                    $blend = [System.Drawing.Color]::FromArgb(
                        [int]($tf.From.R + ($tf.To.R - $tf.From.R) * $tft),
                        [int]($tf.From.G + ($tf.To.G - $tf.From.G) * $tft),
                        [int]($tf.From.B + ($tf.To.B - $tf.From.B) * $tft))
                    if ($null -ne $script:pillBgBrush) { $script:pillBgBrush.Dispose() }
                    $script:pillBgBrush = New-Object System.Drawing.SolidBrush($blend)
                    if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
                        $script:floatingBar.BackColor = $blend
                    }
                }
                $needsRepaint = $true
            }
            # Fast accent fade (accent swatch click): converge in ~0.3s instead
            # of riding the slow per-refresh lerp
            if ($script:colorFadeActive) {
                $cfc = $script:currentDisplayColor; $cft = $script:targetAccentColor
                if (([math]::Abs($cfc.R - $cft.R) + [math]::Abs($cfc.G - $cft.G) + [math]::Abs($cfc.B - $cft.B)) -le 6) {
                    $script:currentDisplayColor = $cft
                    $script:colorFadeActive = $false
                } else {
                    $script:currentDisplayColor = [System.Drawing.Color]::FromArgb(
                        [int]($cfc.R + ($cft.R - $cfc.R) * 0.25),
                        [int]($cfc.G + ($cft.G - $cfc.G) * 0.25),
                        [int]($cfc.B + ($cft.B - $cfc.B) * 0.25))
                }
                $script:barAccentColor = $script:currentDisplayColor
                $needsRepaint = $true
            }
            # Low battery warning animations
            if ($null -ne $script:lowBatPulseActive -and $script:lowBatPulseActive) {
                # Pulsing red border (~3.1s cycle at 33ms tick = ~94 ticks)
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
    [OutputType([void])]
    param()
    # Retire finished moments FIRST. They are the only animation states the
    # Paint handler used to own exclusively, which meant a hidden (never
    # painted) pill could hold the timer on forever - see Clear-ExpiredMoments.
    Clear-ExpiredMoments
    # Start pulse timer only when animations need it, stop when idle
    $anyActive = $script:barIsCharging -or ($script:flashAlpha -gt 0) -or
    ($null -ne $script:lowBatPulseActive -and $script:lowBatPulseActive) -or
    ($null -ne $script:estimatingLabel -and -not $script:estimatingLabel.IsDisposed) -or
    ($null -ne $script:shimmerStart) -or ($null -ne $script:boltPopStart) -or
    ($null -ne $script:rippleState) -or
    ($null -ne $script:themeFade) -or
    ($null -ne $script:colorFadeActive -and $script:colorFadeActive) -or
    ($script:textFadeAlpha -lt 255) -or
    ([math]::Abs($script:displayedFillPct - $script:barDisplayPercent) -gt 0.4)
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
        # Land an in-flight glide/settle BEFORE saving. Exiting mid-flight
        # otherwise saved the pre-fling coordinates and the pill reappeared at
        # its old spot next launch, silently undoing the move the user just
        # made. (Config is set directly rather than via Complete-PillRest,
        # which would start another animation timer during teardown.)
        if ($null -ne $script:glideTimer -or $null -ne $script:settleTimer) {
            if ($null -ne $script:glideTimer) {
                $script:glideTimer.Stop(); $script:glideTimer.Dispose(); $script:glideTimer = $null
            }
            if ($null -ne $script:settleTimer) {
                $script:settleTimer.Stop(); $script:settleTimer.Dispose(); $script:settleTimer = $null
            }
            if ($null -ne $script:floatingBar -and -not $script:floatingBar.IsDisposed) {
                $landed = Get-SnappedLocation -X $script:floatingBar.Left -Y $script:floatingBar.Top `
                    -Width $script:floatingBar.Width -Height $script:floatingBar.Height -Threshold 28
                $script:config.X = $landed.X
                $script:config.Y = $landed.Y
            }
        }
        # Save config (including battery history) on exit
        Save-Config
        $script:timer.Stop()
        $script:timer.Dispose()
        $script:pulseTimer.Stop()
        $script:pulseTimer.Dispose()
        $script:fullscreenTimer.Stop()
        $script:fullscreenTimer.Dispose()
        if ($null -ne $script:introTimer) {
            $script:introTimer.Stop()
            $script:introTimer.Dispose()
        }
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
        if ($null -ne $script:settleTimer) {
            $script:settleTimer.Stop()
            $script:settleTimer.Dispose()
            $script:settleTimer = $null
        }
        if ($null -ne $script:glideTimer) {
            $script:glideTimer.Stop()
            $script:glideTimer.Dispose()
            $script:glideTimer = $null
        }
        # Close hover popup and fade timers
        if ($null -ne $script:fadeInTimer) { $script:fadeInTimer.Stop(); $script:fadeInTimer.Dispose() }
        if ($null -ne $script:fadeOutTimer) { $script:fadeOutTimer.Stop(); $script:fadeOutTimer.Dispose() }
        if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
            $script:hoverPopup.Close(); $script:hoverPopup.Dispose(); $script:hoverPopup = $null
        }
        $script:hoverPopupVisible = $false
        # Guarded: a second pass through here (Close() re-entered, or a caller
        # that disposed it first) must not throw and strand the cleanup below.
        try {
            $script:notifyIcon.Visible = $false
            $script:notifyIcon.Dispose()
        } catch {}
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
        if ($null -ne $script:pillBgBrush) { $script:pillBgBrush.Dispose() }
        if ($null -ne $script:pillBgHoverBrush) { $script:pillBgHoverBrush.Dispose() }
        if ($null -ne $script:pillTextBrush) { $script:pillTextBrush.Dispose() }
        if ($null -ne $script:pillBorderPen) { $script:pillBorderPen.Dispose() }
        if ($null -ne $script:pillBorderHoverPen) { $script:pillBorderHoverPen.Dispose() }
        # Unregister system events to avoid leaks
        [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($script:powerModeHandler)
        [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($script:displaySettingsHandler)
        # Guarded: the guard can legitimately hold no mutex (see
        # New-SingleInstanceMutex - a mutex failure lets the app run anyway),
        # and teardown must not throw and strand the rest of this handler.
        if ($null -ne $script:mutex) {
            try { $script:mutex.ReleaseMutex() } catch {}
            try { $script:mutex.Dispose() } catch {}
        }
    })

# The UI exists now, so I/O failures can show their own card from here on. Flush
# anything recorded during startup (a config we could not read) - it happened
# before there was a window to say it in.
$script:ioNotifyEnabled = $true
if ($script:ioFailures.Count -gt 0) {
    $startupFailure = @($script:ioFailures)[-1]
    Show-BatteryNotification -Message $startupFailure.Operation -SubMessage $startupFailure.Detail `
        -Accent $script:ioFailureAccent
}

# Initial update, then the intro choreography (rise -> fill sweep -> tips)
Update-TrayIcon
Start-IntroAnimation
$script:timer.Start()

# Run the application message loop
[System.Windows.Forms.Application]::Run($script:mainForm)
