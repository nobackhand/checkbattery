# ============================================================
# UPDATE FUNCTIONS
# ============================================================

function Update-TrayIcon {
    [OutputType([void])]
    param()
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

    # Record history for sparkline (cap at 2400 entries = ~2h at 3s intervals).
    # Skip when there's no battery so we don't fill the graph with junk -1 readings.
    if (-not $info.NoBattery) {
        $script:batteryHistory.Add(@{
                Time       = $now
                Percent    = $info.Percent
                IsCharging = $info.IsCharging
            }) | Out-Null
        if ($script:batteryHistory.Count -gt 2400) {
            $script:batteryHistory.RemoveAt(0)
        }
    }

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
if ([Win32Icon]::AnimationsEnabled()) {
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
        # Breadcrumb so a first-timer isn't left wondering where it went
        Show-BatteryNotification -Message "Pill hidden" -SubMessage "Right-click the tray battery icon to show it again" -Accent ([System.Drawing.Color]::FromArgb(45, 212, 100))
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
Set-DarkMenu -Menu $pillContextMenu

$script:floatingBar.ContextMenuStrip = $pillContextMenu

# Tray context menu
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$toggleBarItem = New-Object System.Windows.Forms.ToolStripMenuItem("Hide Bar")
$toggleBarItem.Add_Click({
        if ($script:floatingBar.Visible) {
            $script:floatingBar.Hide()
            $toggleBarItem.Text = "Show Bar"
            # Breadcrumb so a first-timer isn't left wondering where it went
            Show-BatteryNotification -Message "Pill hidden" -SubMessage "Right-click the tray battery icon to show it again" -Accent ([System.Drawing.Color]::FromArgb(45, 212, 100))
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
Set-DarkMenu -Menu $contextMenu

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
            # Plug/unplug flash decay (180→0 at 33ms tick, ~8/tick = ~750ms)
            if ($script:flashAlpha -gt 0) {
                $script:flashAlpha = [math]::Max(0, $script:flashAlpha - 12)
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
        if ($null -ne $script:pillTextBrush) { $script:pillTextBrush.Dispose() }
        if ($null -ne $script:pillBorderPen) { $script:pillBorderPen.Dispose() }
        if ($null -ne $script:pillBorderHoverPen) { $script:pillBorderHoverPen.Dispose() }
        # Unregister system events to avoid leaks
        [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($script:powerModeHandler)
        [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($script:displaySettingsHandler)
        $script:mutex.ReleaseMutex()
        $script:mutex.Dispose()
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
