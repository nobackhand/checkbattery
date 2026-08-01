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
    # Enable CS_DROPSHADOW for popup elevation
    $popup.Add_HandleCreated({ [Win32Icon]::EnableDropShadow($popup.Handle) })

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

    # Set rounded region to clip corners
    $prd = 20; $pw = $popup.ClientSize.Width; $ph = $popup.ClientSize.Height
    $popupRegionPath = New-RoundedRectPath -Right ($pw - $prd - 1) -Bottom ($ph - $prd - 1) -Diameter $prd
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
    # Enable CS_DROPSHADOW for popup elevation
    $popup.Add_HandleCreated({ [Win32Icon]::EnableDropShadow($popup.Handle) })

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

    # Set rounded region to clip corners
    $prd = 20; $pw = $popup.ClientSize.Width; $ph = $popup.ClientSize.Height
    $popupRegionPath = New-RoundedRectPath -Right ($pw - $prd - 1) -Bottom ($ph - $prd - 1) -Diameter $prd
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

