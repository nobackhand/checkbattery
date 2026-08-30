# ============================================================
# HOVER POPUP (NON-MODAL)
# ============================================================

function Get-EaseInOutCubic {
    [OutputType([double])]
    param([double]$t)
    # Cubic ease-in-out: smooth acceleration then deceleration, $t in [0,1]
    if ($t -lt 0.5) { return 4.0 * $t * $t * $t }
    return 1.0 - [Math]::Pow(-2.0 * $t + 2.0, 3) / 2.0
}

function Clear-PopupLiveRefs {
    [OutputType([void])]
    param()
    # Forget the open popup's live rows (called on every popup teardown path)
    $script:popupTitleLabel = $null
    $script:popupPctLabel = $null
    $script:popupTimeLabel = $null
    $script:popupFunLabel = $null
    $script:popupSparkPanel = $null
}

function Update-OpenPopupContent {
    [OutputType([void])]
    param([hashtable]$BatteryInfo)
    # Rewrite the open popup's live rows with this tick's reading. Without
    # this, a popup held open showed whatever was true at open time - the
    # percent, time, fun line and graph all silently went stale.
    if ($null -eq $script:popupTimeLabel -or $script:popupTimeLabel.IsDisposed) { return }
    if ($null -ne $script:popupTitleLabel -and -not $script:popupTitleLabel.IsDisposed) {
        $title = Get-BatteryStateTitle -BatteryInfo $BatteryInfo
        if ($script:popupTitleLabel.Text -ne $title) { $script:popupTitleLabel.Text = $title }
    }
    if ($null -ne $script:popupPctLabel -and -not $script:popupPctLabel.IsDisposed -and $BatteryInfo.PercentExact -ge 0) {
        $pctText = "$([int][math]::Round($BatteryInfo.PercentExact))%"
        if ($script:popupPctLabel.Text -ne $pctText) { $script:popupPctLabel.Text = $pctText }
        $script:popupPctLabel.ForeColor = Get-HeroPercentColor -Status $BatteryInfo.StatusText
    }
    $sentence = Get-TimeSentence -BatteryInfo $BatteryInfo
    if ($script:popupTimeLabel.Text -ne $sentence) {
        $script:popupTimeLabel.Text = $sentence
        if ($sentence -eq "Estimating...") {
            # Back to the placeholder (e.g. a plug event reset the EMA) - re-arm the pulse
            $script:estimatingLabel = $script:popupTimeLabel
            Update-PulseTimerState
        } else {
            # A real value replaced the pulsing placeholder - stop the pulse
            $script:popupTimeLabel.ForeColor = $script:theme.TextPrimary
            $script:estimatingLabel = $null
        }
    }
    if ($null -ne $script:popupFunLabel -and -not $script:popupFunLabel.IsDisposed -and $script:config.FunLines) {
        $fun = Get-FunStatusLine -BatteryInfo $BatteryInfo
        if ($fun -and $script:popupFunLabel.Text -ne $fun) { $script:popupFunLabel.Text = $fun }
    }
    if ($null -ne $script:popupSparkPanel -and -not $script:popupSparkPanel.IsDisposed) {
        # New history points landed this tick - repaint the graph
        $script:popupSparkPanel.Invalidate()
    }
}

function Close-HoverPopup {
    [OutputType([void])]
    param()
    if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
        # Start eased fade-out (100ms duration) FROM the popup's current opacity -
        # interrupting a fade-in used to restart at full brightness (visible flash)
        $script:fadeOutFrom = $script:hoverPopup.Opacity
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
                            Clear-PopupLiveRefs
                            # Dispose popup fonts to prevent GDI+ handle leak
                            if ($null -ne $script:hoverPopupFonts) {
                                foreach ($f in $script:hoverPopupFonts) { if ($null -ne $f) { $f.Dispose() } }
                                $script:hoverPopupFonts = $null
                            }
                        } else {
                            $script:hoverPopup.Opacity = $script:fadeOutFrom * (1.0 - $eased)
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
    [OutputType([void])]
    param()
    # Close any existing popup immediately (no fade when reopening)
    if ($null -ne $script:fadeOutTimer) { $script:fadeOutTimer.Stop() }
    if ($null -ne $script:fadeInTimer) { $script:fadeInTimer.Stop() }
    if ($null -ne $script:hoverPopup -and -not $script:hoverPopup.IsDisposed) {
        $script:hoverPopup.Close()
        $script:hoverPopup.Dispose()
        $script:hoverPopup = $null
        Clear-PopupLiveRefs
        if ($null -ne $script:hoverPopupFonts) {
            foreach ($f in $script:hoverPopupFonts) { if ($null -ne $f) { $f.Dispose() } }
            $script:hoverPopupFonts = $null
        }
    }
    $script:hoverPopupVisible = $false

    $BatteryInfo = Get-BatteryInfo

    $popup = New-Object System.Windows.Forms.Form
    $popup.Text = "BatteryPill"
    $popup.Size = New-Object System.Drawing.Size(420, 400)
    $popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $popup.ShowInTaskbar = $false
    $popup.TopMost = $true
    $popup.BackColor = $script:theme.PopupBg
    $popup.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $popup.KeyPreview = $true
    Enable-DoubleBuffering -Form $popup

    # Rounded border
    $popup.Add_Paint({
            param($sender, $e)
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $r = 10; $rd2 = $r * 2
            $bw = $sender.Width - 1; $bh = $sender.Height - 1
            $borderPath = New-RoundedRectPath -Right ($bw - $rd2) -Bottom ($bh - $rd2) -Diameter $rd2
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

    # Native rounded corners + shadow (Region-clip fallback on Win10)
    Set-NativeRoundedCorners -Form $popup -FallbackRadius 10

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
    [OutputType([void])]
    param([hashtable]$BatteryInfo)

    $popup = New-Object System.Windows.Forms.Form
    $popup.Text = "BatteryPill"
    $popup.Size = New-Object System.Drawing.Size(420, 400)
    $popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $popup.ShowInTaskbar = $false
    $popup.TopMost = $true
    $popup.BackColor = $script:theme.PopupBg
    $popup.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $popup.KeyPreview = $true
    Enable-DoubleBuffering -Form $popup

    # Rounded border
    $popup.Add_Paint({
            param($sender, $e)
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $r = 10; $rd2 = $r * 2
            $bw = $sender.Width - 1; $bh = $sender.Height - 1
            $borderPath = New-RoundedRectPath -Right ($bw - $rd2) -Bottom ($bh - $rd2) -Diameter $rd2
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

    # Native rounded corners + shadow (Region-clip fallback on Win10)
    Set-NativeRoundedCorners -Form $popup -FallbackRadius 10

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
    Clear-PopupLiveRefs
    # Dispose popup fonts to prevent GDI+ handle leak
    foreach ($f in $content.Fonts) { if ($null -ne $f) { $f.Dispose() } }
    $popup.Dispose()
}

