# ============================================================
# FLOATING BAR — FORM
# ============================================================

function Get-PillDimensions {
    [OutputType([hashtable])]
    param()
    # Returns @{ Width, Height, FontSize } based on PillSize and DisplayMode
    $mode = $script:config.DisplayMode
    $size = $script:config.PillSize
    switch ($size) {
        "compact" { return @{ Width = 80; Height = 28; FontSize = 9.0; FontSize2 = 0 } }
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
    [OutputType([void])]
    param()
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
    # True capsule: radius = half the height (minus the path helper's -1 inset).
    # The app is named after this shape - it should draw it.
    $script:pillRadius = [int](($dims.Height - 2) / 2)
    $rd = $script:pillRadius * 2
    $rPath = New-RoundedRectPath -Right ($dims.Width - $rd - 1) -Bottom ($dims.Height - $rd - 1) -Diameter $rd
    $script:floatingBar.Region = New-Object System.Drawing.Region($rPath)
    $rPath.Dispose()
    # Update font
    if ($null -ne $script:pillFont) { $script:pillFont.Dispose() }
    $script:pillFont = New-Object System.Drawing.Font("Segoe UI Semibold", $dims.FontSize, [System.Drawing.FontStyle]::Bold)
    if ($dims.FontSize2 -gt 0) {
        if ($null -ne $script:pillFont2) { $script:pillFont2.Dispose() }
        $script:pillFont2 = New-Object System.Drawing.Font("Segoe UI", $dims.FontSize2, [System.Drawing.FontStyle]::Regular)
    } else {
        # No room for a second line at this size (e.g. compact) - clear the font so the
        # paint handler deterministically takes the single-line branch instead of
        # depending on which size the user visited previously
        if ($null -ne $script:pillFont2) { $script:pillFont2.Dispose() }
        $script:pillFont2 = $null
    }
    $script:floatingBar.Invalidate()
}

function Invoke-CycleDisplayMode {
    [OutputType([void])]
    param()
    # Left-click on the pill cycles what it shows: time -> percent -> both -> time
    $order = @("time", "percent", "both")
    $idx = [array]::IndexOf($order, [string]$script:config.DisplayMode)
    if ($idx -lt 0) { $idx = 0 }
    $newIdx = ($idx + 1) % $order.Count
    $script:config.DisplayMode = $order[$newIdx]
    Update-PillSize
    if ($null -ne $script:lastBatteryInfo) {
        Update-FloatingBar -BatteryInfo $script:lastBatteryInfo
    }
    # Keep an open Settings panel's Display combo in sync so touching it later
    # can't write a stale mode back over this one
    if ($null -ne $script:settingsDisplayCombo -and -not $script:settingsDisplayCombo.IsDisposed) {
        if ($script:settingsDisplayCombo.SelectedIndex -ne $newIdx) {
            $script:settingsDisplayCombo.SelectedIndex = $newIdx
        }
    }
    Save-Config
}

function Test-PositionOnScreen {
    [OutputType([bool])]
    param([int]$X, [int]$Y, [int]$Width, [int]$Height)
    # Check if the center of the pill falls within any connected screen's working area
    $centerX = $X + [int]($Width / 2)
    $centerY = $Y + [int]($Height / 2)
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        if ($scr.WorkingArea.Contains($centerX, $centerY)) { return $true }
    }
    return $false
}

function Start-PillSettle {
    [OutputType([void])]
    param([int]$TargetX, [int]$TargetY)
    # Short eased glide (160ms) from the pill's current spot to a snapped
    # resting position after a drag release. Cosmetic only - the caller has
    # already written the target to config. Instant when animations are off.
    if ($null -eq $script:floatingBar -or $script:floatingBar.IsDisposed) { return }
    if (-not $script:animOK) {
        $script:floatingBar.Location = New-Object System.Drawing.Point($TargetX, $TargetY)
        return
    }
    if ($null -ne $script:settleTimer) { $script:settleTimer.Stop(); $script:settleTimer.Dispose(); $script:settleTimer = $null }
    $script:settleState = @{
        Start = Get-Date
        FromX = $script:floatingBar.Left
        FromY = $script:floatingBar.Top
        ToX   = $TargetX
        ToY   = $TargetY
    }
    $script:settleTimer = New-Object System.Windows.Forms.Timer
    $script:settleTimer.Interval = 16
    $script:settleTimer.Add_Tick({
            # Plain scriptblock + $script: state on purpose (GetNewClosure would
            # resolve $script: against the closure module - see CLAUDE.md)
            if ($null -eq $script:floatingBar -or $script:floatingBar.IsDisposed -or $script:isDragging) {
                $script:settleTimer.Stop(); $script:settleTimer.Dispose(); $script:settleTimer = $null
                return
            }
            $st = $script:settleState
            $t = [math]::Min(1.0, ((Get-Date) - $st.Start).TotalMilliseconds / 160.0)
            $eased = 1.0 - [math]::Pow(1.0 - $t, 3)
            $nx = [int]($st.FromX + ($st.ToX - $st.FromX) * $eased)
            $ny = [int]($st.FromY + ($st.ToY - $st.FromY) * $eased)
            $script:floatingBar.Location = New-Object System.Drawing.Point($nx, $ny)
            if ($t -ge 1.0) {
                $script:floatingBar.Location = New-Object System.Drawing.Point($st.ToX, $st.ToY)
                $script:settleTimer.Stop(); $script:settleTimer.Dispose(); $script:settleTimer = $null
            }
        })
    $script:settleTimer.Start()
}

function New-FloatingBar {
    [OutputType([System.Windows.Forms.Form])]
    param()
    # Paint state — updated by Update-FloatingBar, read by Paint handler
    $script:barAccentColor = [System.Drawing.Color]::FromArgb(45, 212, 100)
    $script:barDisplayText = "..."
    $script:barDisplayPercent = 50
    $script:barIsCharging = $false

    # Pulse animation state for charging effect
    $script:pulseAlpha = 105
    $script:wasChargingLastUpdate = $false

    # One gate for every animation this file starts: respect the user's
    # Windows "show animations" setting, sampled once at startup
    $script:animOK = [Win32Icon]::AnimationsEnabled()

    # Smooth value transitions: the painted fill level eases toward the real
    # percent (pulse timer), and the pill text fades back in when it changes
    $script:displayedFillPct = 50.0
    $script:textFadeAlpha = 255
    $script:prevDisplayText = ""

    # Moment animations: full-charge shimmer sweep, plug-in bolt pop
    $script:shimmerStart = $null
    $script:boltPopStart = $null
    $script:wasFullyCharged = $false
    $script:fullChargeShown = $false

    # Theme crossfade + fast accent fade (driven by the pulse timer)
    $script:themeFade = $null
    $script:colorFadeActive = $false

    # Eased edge-settle after a drag release
    $script:settleState = $null

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
    $form.BackColor = $script:theme.PillBg  # themed: hardcoded dark left a fringe ring around the pill in Light theme
    # $script:pillRadius is what the Paint handler measures its own path from.
    # It used to be set ONLY by Update-PillSize, which nothing calls at startup:
    # every fresh launch painted the fill/border as a radius-8 rounded rect
    # inside a radius-16 capsule Region, so the pill's ends looked clipped flat
    # until the user happened to change pill size or display mode.
    $script:pillRadius = [int](($dims.Height - 2) / 2)
    $rd = $script:pillRadius * 2   # capsule: corner diameter spans the pill height
    $regionPath = New-RoundedRectPath -Right ($dims.Width - $rd - 1) -Bottom ($dims.Height - $rd - 1) -Diameter $rd
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
            $d = ($radius - 1) * 2
            $path = New-RoundedRectPath -Right ($w - $d - 1) -Bottom ($h - $d - 1) -Diameter $d

            # --- Background (entire pill, theme-aware — cached brush) ---
            # Hover: slightly lifted surface so the pill reads as touchable
            if ($script:pillHovered -and $null -ne $script:pillBgHoverBrush) {
                $g.FillPath($script:pillBgHoverBrush, $path)
            } else {
                $g.FillPath($script:pillBgBrush, $path)
            }

            # --- Battery charge fill (left-to-right, clipped to pill shape) ---
            # Painted from the EASED level, not the raw one - the pulse timer
            # glides displayedFillPct toward barDisplayPercent so level changes
            # slide instead of snapping
            $pct = [math]::Max(0, [math]::Min(100, $script:displayedFillPct))
            $fillWidth = [math]::Max(0, [math]::Round(($pct / 100) * $w))
            if ($fillWidth -gt 0) {
                # Clip to the rounded pill shape
                $oldClip = $g.Clip
                $g.SetClip($path)

                # Semi-transparent accent gradient fill (left brighter, right slightly darker)
                # Use pulse alpha when charging for animated glow effect
                $ac = $script:barAccentColor
                $baseAlpha = if ($script:barIsCharging) { $script:pulseAlpha } else { 100 }
                $fillLeft = [System.Drawing.Color]::FromArgb([math]::Min(255, $baseAlpha + 20), $ac.R, $ac.G, $ac.B)
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
            # Press feedback: text sinks 1px while the button is held (not dragging)
            $pressY = if ($script:leftPressed -and -not $script:isDragging) { 1 } else { 0 }
            # Text crossfade: when the value changes, the new text fades in
            # (pulse timer ramps textFadeAlpha back to 255)
            $txA = [int][math]::Max(0, [math]::Min(255, $script:textFadeAlpha))
            if ($script:barDisplayText2 -and $script:barDisplayText2.Length -gt 0 -and $null -ne $script:pillFont2) {
                # Dual-line mode: top = accent-colored primary, bottom = dim secondary
                $ac3 = $script:barAccentColor
                $topBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($txA, $ac3.R, $ac3.G, $ac3.B))
                $topRect = New-Object System.Drawing.RectangleF(0, (2 + $pressY), $w, ($h / 2))
                $g.DrawString($script:barDisplayText, $script:pillFont, $topBrush, $topRect, $script:pillStringFormat)
                $topBrush.Dispose()
                $td = $script:theme.TextDim
                $botBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($txA, $td.R, $td.G, $td.B))
                # NOTE: the inner subtraction MUST be fully parenthesized - in an argument list the
                # comma binds tighter than minus, so "($h / 2) - 2, $w" parses as array subtraction
                # and throws op_Subtraction every paint, silently killing this second line.
                $botRect = New-Object System.Drawing.RectangleF(0, ((($h / 2) - 2) + $pressY), $w, ($h / 2))
                $g.DrawString($script:barDisplayText2, $script:pillFont2, $botBrush, $botRect, $script:pillStringFormat)
                $botBrush.Dispose()
            } elseif ($txA -lt 255) {
                $tp = $script:theme.TextPrimary
                $fadeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($txA, $tp.R, $tp.G, $tp.B))
                $textRect = New-Object System.Drawing.RectangleF(0, $pressY, $w, $h)
                $g.DrawString($script:barDisplayText, $script:pillFont, $fadeBrush, $textRect, $script:pillStringFormat)
                $fadeBrush.Dispose()
            } else {
                # Single-line mode (centered — cached brush)
                $textRect = New-Object System.Drawing.RectangleF(0, $pressY, $w, $h)
                $g.DrawString($script:barDisplayText, $script:pillFont, $script:pillTextBrush, $textRect, $script:pillStringFormat)
            }

            # --- Press feedback: gentle darkening while held ---
            if ($pressY -gt 0) {
                $pressBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(26, 0, 0, 0))
                $g.FillPath($pressBrush, $path)
                $pressBrush.Dispose()
            }

            # --- Full-charge shimmer: one bright band sweeps left-to-right ---
            if ($null -ne $script:shimmerStart) {
                $smMs = ((Get-Date) - $script:shimmerStart).TotalMilliseconds
                $smT = $smMs / 700.0
                if ($smT -ge 1.0) {
                    $script:shimmerStart = $null
                } else {
                    $bandW = [math]::Max(10, [int]($w * 0.45))
                    $bandX = [int]( - $bandW + (($w + 2 * $bandW) * $smT))
                    $shimClip = $g.Clip
                    $g.SetClip($path)
                    $bandRect = New-Object System.Drawing.Rectangle($bandX, 0, $bandW, $h)
                    $shimBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                        $bandRect,
                        [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
                        [System.Drawing.Color]::FromArgb(110, 255, 255, 255),
                        [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
                    # Triangular blend: transparent -> bright at the middle -> transparent
                    $shimBrush.SetBlendTriangularShape(0.5)
                    $g.FillRectangle($shimBrush, $bandRect)
                    $shimBrush.Dispose()
                    $g.Clip = $shimClip
                }
            }

            # --- Plug-in moment: a bolt pops in with overshoot, then fades ---
            if ($null -ne $script:boltPopStart) {
                $bpMs = ((Get-Date) - $script:boltPopStart).TotalMilliseconds
                if ($bpMs -ge 1200) {
                    $script:boltPopStart = $null
                } else {
                    # Ease-out-back over the first 280ms (slight overshoot = "pop")
                    $bpT = [math]::Min(1.0, $bpMs / 280.0)
                    $c1 = 1.70158; $c3 = $c1 + 1.0
                    $bpScale = 1.0 + $c3 * [math]::Pow($bpT - 1.0, 3) + $c1 * [math]::Pow($bpT - 1.0, 2)
                    $bpAlpha = if ($bpMs -gt 900) { [int](255 * (1.0 - (($bpMs - 900) / 300.0))) } else { 255 }
                    $bpAlpha = [math]::Max(0, [math]::Min(255, $bpAlpha))
                    if ($bpScale -gt 0.05) {
                        # Bolt sized from pill height, centered
                        $bu = ($h * 0.62) * $bpScale
                        $bcx = $w / 2.0; $bcy = $h / 2.0
                        [System.Drawing.PointF[]]$boltPts = @(
                            (New-Object System.Drawing.PointF(($bcx + 0.12 * $bu), ($bcy - 0.50 * $bu))),
                            (New-Object System.Drawing.PointF(($bcx - 0.28 * $bu), ($bcy + 0.10 * $bu))),
                            (New-Object System.Drawing.PointF(($bcx - 0.02 * $bu), ($bcy + 0.10 * $bu))),
                            (New-Object System.Drawing.PointF(($bcx - 0.12 * $bu), ($bcy + 0.50 * $bu))),
                            (New-Object System.Drawing.PointF(($bcx + 0.28 * $bu), ($bcy - 0.12 * $bu))),
                            (New-Object System.Drawing.PointF(($bcx + 0.02 * $bu), ($bcy - 0.12 * $bu)))
                        )
                        $boltEdge = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int]($bpAlpha * 0.6), 0, 0, 0), 1.6)
                        $g.DrawPolygon($boltEdge, $boltPts); $boltEdge.Dispose()
                        $boltFill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($bpAlpha, 255, 255, 255))
                        $g.FillPolygon($boltFill, $boltPts); $boltFill.Dispose()
                    }
                }
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
            } elseif ($script:pillHovered -and $null -ne $script:pillBorderHoverPen) {
                # --- Hover affordance: stronger border while the cursor is on the pill (cached pen) ---
                $g.DrawPath($script:pillBorderHoverPen, $path)
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
            if (-not $script:hoverPopupVisible -and -not $script:floatingBar.ContextMenuStrip.Visible -and
                -not $script:isDragging -and -not $script:leftPressed) {
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

    # Mouse enter - start hover timer + hover affordance
    $form.Add_MouseEnter({
            $script:pillHovered = $true
            $script:floatingBar.Invalidate()
            if (-not $script:hoverPopupVisible -and -not $script:isDragging) {
                $script:hoverTimer.Start()
            }
        })

    # Mouse leave - stop timer, start dismiss check, clear hover affordance
    $form.Add_MouseLeave({
            $script:pillHovered = $false
            $script:floatingBar.Invalidate()
            $script:hoverTimer.Stop()
            if ($script:hoverPopupVisible) {
                $script:dismissTimer.Start()
            }
        })

    # Drag handling — track if mouse actually moved to distinguish click vs drag
    $script:isDragging = $false
    $script:didDrag = $false
    $script:leftPressed = $false
    $script:pillHovered = $false
    $script:dragOffset = New-Object System.Drawing.Point(0, 0)

    $dragDown = {
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            # Track the press even when position is locked - click-to-cycle must still work
            $script:leftPressed = $true
            $script:didDrag = $false
            $script:dragOffset = $e.Location
            # Repaint for the press-down visual (text sinks, slight darkening)
            $script:floatingBar.Invalidate()
            # A press is manipulation, not a hover - never let the popup interrupt a drag
            $script:hoverTimer.Stop()
            if (-not $script:positionLocked) {
                $script:isDragging = $true
                $script:floatingBar.Cursor = [System.Windows.Forms.Cursors]::SizeAll
            }
        }
    }
    $dragMove = {
        param($sender, $e)
        if (-not $script:isDragging -and $script:leftPressed -and $script:positionLocked) {
            # Locked: the pill never moves, but still track cursor travel so a
            # held-and-dragged press is not treated as a click on release
            $ldx = [math]::Abs($e.X - $script:dragOffset.X)
            $ldy = [math]::Abs($e.Y - $script:dragOffset.Y)
            if ($ldx -gt 3 -or $ldy -gt 3) { $script:didDrag = $true }
        }
        if ($script:isDragging) {
            $dx = [math]::Abs($e.X - $script:dragOffset.X)
            $dy = [math]::Abs($e.Y - $script:dragOffset.Y)
            if ($dx -gt 3 -or $dy -gt 3) {
                $script:didDrag = $true
                $newX = $script:floatingBar.Left + $e.X - $script:dragOffset.X
                $newY = $script:floatingBar.Top + $e.Y - $script:dragOffset.Y

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
                # Released within reach of a screen edge (a wider band than the
                # hard mid-drag snap): glide the last stretch instead of leaving
                # the pill hanging just off the margin. Config records the FINAL
                # resting spot either way.
                $relScreen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
                $settleT = 28; $settleM = 8
                $sx = $script:floatingBar.Left; $sy = $script:floatingBar.Top
                $sw2 = $script:floatingBar.Width; $sh2 = $script:floatingBar.Height
                if ([math]::Abs($sx - $relScreen.Left) -lt $settleT) { $sx = $relScreen.Left + $settleM }
                if ([math]::Abs(($sx + $sw2) - $relScreen.Right) -lt $settleT) { $sx = $relScreen.Right - $sw2 - $settleM }
                if ([math]::Abs($sy - $relScreen.Top) -lt $settleT) { $sy = $relScreen.Top + $settleM }
                if ([math]::Abs(($sy + $sh2) - $relScreen.Bottom) -lt $settleT) { $sy = $relScreen.Bottom - $sh2 - $settleM }
                $script:config.X = $sx
                $script:config.Y = $sy
                Save-Config
                if ($sx -ne $script:floatingBar.Left -or $sy -ne $script:floatingBar.Top) {
                    Start-PillSettle -TargetX $sx -TargetY $sy
                }
            }
        }
        # Left-click without drag cycles the display mode (works even when position is locked)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:leftPressed -and -not $script:didDrag) {
            Invoke-CycleDisplayMode
        }
        $script:leftPressed = $false
        $script:floatingBar.Invalidate()
    }

    # Apply drag/click events to form only (no label — everything is paint-drawn)
    $form.Add_MouseDown($dragDown)
    $form.Add_MouseMove($dragMove)
    $form.Add_MouseUp($dragUp)

    # Set position from config (validate against current screens).
    # Only the exact (-1,-1) pair means "never saved" - monitors left of or above
    # the primary have legitimate negative coordinates, and Test-PositionOnScreen
    # is the real validity check.
    $useDefault = $true
    if (-not ($script:config.X -eq -1 -and $script:config.Y -eq -1)) {
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
    [OutputType([System.Windows.Forms.Panel])]
    param([int]$Y, [System.Drawing.Color]$AccentColor)
    # Creates a 380x40 panel that draws battery history sparkline
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(20, $Y)
    $panel.Size = New-Object System.Drawing.Size(380, 40)
    $panel.BackColor = [System.Drawing.Color]::Transparent
    # Reveal: 0..1 fraction of the line drawn so far - animated below so the
    # graph draws itself left-to-right when the popup opens
    $panel.Tag = @{ AccentColor = $AccentColor; Reveal = 1.0 }
    $panel.Add_Paint({
            param($sender, $e)
            $sg = $e.Graphics
            $sg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $sw = $sender.Width
            $sh = $sender.Height

            # Rounded background — the sparkline was the one sharp-cornered box in an
            # app built on rounded corners. Round it with the shared primitive and
            # clip the graph inside so nothing squares off the corners.
            $d = 6
            $rPath = New-RoundedRectPath -Right ($sw - $d - 1) -Bottom ($sh - $d - 1) -Diameter $d
            $bgBrush = New-Object System.Drawing.SolidBrush($script:theme.SparkBg)
            $sg.FillPath($bgBrush, $rPath)
            $bgBrush.Dispose()

            $clipState = $sg.Save()
            $sg.SetClip($rPath)

            $guide = $script:theme.SparkGuide

            $history = $script:batteryHistory
            if ($null -eq $history -or $history.Count -lt 2) {
                # Not enough data yet — a friendly, centered placeholder with a faint baseline
                $baseY = $sh - 9
                $basePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(45, $guide.R, $guide.G, $guide.B), 1)
                $basePen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
                $sg.DrawLine($basePen, 8, $baseY, $sw - 8, $baseY)
                $basePen.Dispose()
                $noDataFont = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)
                $noDataBrush = New-Object System.Drawing.SolidBrush($script:theme.TextDim)
                $noDataFmt = New-Object System.Drawing.StringFormat
                $noDataFmt.Alignment = [System.Drawing.StringAlignment]::Center
                $noDataFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
                $sg.DrawString("Charting your battery...", $noDataFont, $noDataBrush, (New-Object System.Drawing.RectangleF(0, 0, $sw, ($sh - 6))), $noDataFmt)
                $noDataFmt.Dispose(); $noDataBrush.Dispose(); $noDataFont.Dispose()
            } else {
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

                # Draw sparkline - only the revealed prefix, so the line draws
                # itself left-to-right when the popup opens
                $reveal = [double]$sender.Tag.Reveal
                $drawCount = [int][math]::Ceiling($count * $reveal)
                $drawCount = [math]::Max(0, [math]::Min($count, $drawCount))
                $linePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, $acColor.R, $acColor.G, $acColor.B), 1.5)
                $points = New-Object System.Drawing.PointF[] $count
                for ($i = 0; $i -lt $count; $i++) {
                    $px = ($i / [math]::Max(1, $count - 1)) * $sw
                    $py = $sh - (($history[$i].Percent / 100.0) * ($sh - 4)) - 2
                    $points[$i] = New-Object System.Drawing.PointF($px, $py)
                }
                if ($drawCount -ge 2) {
                    $sg.DrawLines($linePen, $points[0..($drawCount - 1)])
                }
                $linePen.Dispose()

                # Current value dot at the end of the sparkline (once fully drawn)
                if ($count -ge 2 -and $reveal -ge 1.0) {
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
                $sg.DrawString("50%", $guideFont, $guideBrush, 4, [int]$halfY - 12)
                $guideBrush.Dispose()

                # Time range label (right edge)
                if ($count -ge 2) {
                    $firstTime = $history[0].Time
                    $lastTime = $history[$count - 1].Time
                    $spanMin = [int](($lastTime - $firstTime).TotalMinutes)
                    $spanText = if ($spanMin -ge 60) { "{0}h" -f [math]::Round($spanMin / 60.0, 1) } else { "{0} min" -f $spanMin }
                    $spanSize = $sg.MeasureString($spanText, $guideFont)
                    $spanBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, $guide.R, $guide.G, $guide.B))
                    $sg.DrawString($spanText, $guideFont, $spanBrush, ($sw - $spanSize.Width - 5), ($sh - $spanSize.Height - 2))
                    $spanBrush.Dispose()
                }
                $guideFont.Dispose()
            }

            # Restore clip and stroke a soft rounded border on top
            $sg.Restore($clipState)
            $bdrPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, $script:theme.Border.R, $script:theme.Border.G, $script:theme.Border.B), 1)
            $sg.DrawPath($bdrPen, $rPath)
            $bdrPen.Dispose()
            $rPath.Dispose()
        })

    # Draw-on animation: reveal the line over 450ms (eased). Closure over the
    # panel + timer LOCALS is the correct pattern here (same as the
    # notification cards) - no $script: state is touched at fire time.
    if ($script:animOK -and $null -ne $script:batteryHistory -and $script:batteryHistory.Count -ge 2) {
        $panel.Tag.Reveal = 0.0
        $revStart = Get-Date
        $revTimer = New-Object System.Windows.Forms.Timer
        $revTimer.Interval = 16
        $revTimer.Add_Tick({
                if ($null -eq $panel -or $panel.IsDisposed) {
                    $revTimer.Stop(); $revTimer.Dispose(); return
                }
                $t = [math]::Min(1.0, ((Get-Date) - $revStart).TotalMilliseconds / 450.0)
                $panel.Tag.Reveal = 1.0 - [math]::Pow(1.0 - $t, 3)
                $panel.Invalidate()
                if ($t -ge 1.0) {
                    $panel.Tag.Reveal = 1.0
                    $revTimer.Stop(); $revTimer.Dispose()
                }
            }.GetNewClosure())
        $revTimer.Start()
    }
    return $panel
}

function Format-Duration {
    # The one way a duration is written anywhere in the app: "3h 8m" / "42m".
    # No zero-padding - the pill and popup previously formatted the same
    # value two different ways ("3h 8m" vs "3h 08m").
    [OutputType([string])]
    param([int]$Minutes)
    $h = [math]::Floor($Minutes / 60)
    $m = $Minutes % 60
    if ($h -gt 0) { return "{0}h {1}m" -f $h, $m }
    return "{0}m" -f $m
}

function Get-FunStatusLine {
    [OutputType([string])]
    param([hashtable]$BatteryInfo)
    # One context-aware line of personality for the popup. Deterministic per
    # state (no random churn between refreshes); togglable via config.FunLines.
    if ($BatteryInfo.NoBattery) { return "Mains-powered and unbothered." }
    if ($BatteryInfo.IsFullyCharged) { return "Topped off. Free to roam." }
    if ($BatteryInfo.IsCharging) {
        if ($BatteryInfo.Percent -ge 90) { return "Almost there." }
        return "Refueling."
    }
    $mins = $BatteryInfo.TimeMinutes
    if ($mins -gt 0) {
        if ($mins -le 20) { return "Find an outlet. Now-ish." }
        if ($mins -le 45) { return "Wrapping-up territory." }
        if ($mins -ge 480) { return "All-day battery. Go do things." }
        if ($mins -ge 300) { return "Hours of runway left." }
    } elseif ($BatteryInfo.Percent -ge 0 -and $BatteryInfo.Percent -le 20) {
        return "Running on fumes."
    }
    return ""
}

function New-BatteryPopupContent {
    [OutputType([hashtable])]
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
    $labelFont = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Regular)
    # Hero fonts for top section (Time — the data users care about most)
    $heroValueFont = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Regular)

    # --- Title: status only (the hero percent below carries the number) ---
    if ($BatteryInfo.IsFullyCharged) {
        $titleText = "Fully Charged"
    } elseif ($BatteryInfo.IsCharging) {
        $titleText = "Charging"
    } elseif ($BatteryInfo.NoBattery) {
        $titleText = "No Battery"
    } else {
        $titleText = "Discharging"
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

    # --- No-battery: a friendly empty state instead of a wall of N/A rows ---
    if ($BatteryInfo.NoBattery) {
        $emptyFonts = @()
        $ny = [int](50 * $DpiScale)

        # Big accent lightning glyph, centered
        $glyphFont = New-Object System.Drawing.Font("Segoe UI Symbol", 26, [System.Drawing.FontStyle]::Regular)
        $emptyFonts += $glyphFont
        $glyph = New-Object System.Windows.Forms.Label
        $glyph.Text = [string][char]0x26A1
        $glyph.Font = $glyphFont
        # Darker green on the light popup background for contrast
        $glyph.ForeColor = if ($script:theme.PopupBg.GetBrightness() -gt 0.5) {
            [System.Drawing.Color]::FromArgb(27, 131, 62)
        } else {
            [System.Drawing.Color]::FromArgb(45, 212, 100)
        }
        $glyph.AutoSize = $false
        $glyph.Size = New-Object System.Drawing.Size($PopupWidth, [int](44 * $DpiScale))
        $glyph.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $glyph.Location = New-Object System.Drawing.Point(0, $ny)
        $Form.Controls.Add($glyph)
        $ny += [int](50 * $DpiScale)

        # Headline
        $mainFont = New-Object System.Drawing.Font("Segoe UI Semibold", 11, [System.Drawing.FontStyle]::Regular)
        $emptyFonts += $mainFont
        $mainLbl = New-Object System.Windows.Forms.Label
        $mainLbl.Text = "Running on AC power"
        $mainLbl.Font = $mainFont
        $mainLbl.ForeColor = $script:theme.TextPrimary
        $mainLbl.AutoSize = $false
        $mainLbl.Size = New-Object System.Drawing.Size($PopupWidth, [int](24 * $DpiScale))
        $mainLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $mainLbl.Location = New-Object System.Drawing.Point(0, $ny)
        $Form.Controls.Add($mainLbl)
        $ny += [int](26 * $DpiScale)

        # Subtitle
        $subLbl = New-Object System.Windows.Forms.Label
        $subLbl.Text = "No battery to monitor on this PC."
        $subLbl.Font = $labelFont
        $subLbl.ForeColor = $script:theme.TextDim
        $subLbl.AutoSize = $false
        $subLbl.Size = New-Object System.Drawing.Size(($PopupWidth - [int](40 * $DpiScale)), [int](22 * $DpiScale))
        $subLbl.TextAlign = [System.Drawing.ContentAlignment]::TopCenter
        $subLbl.Location = New-Object System.Drawing.Point([int](20 * $DpiScale), $ny)
        $Form.Controls.Add($subLbl)
        $ny += [int](26 * $DpiScale)

        return @{
            TotalHeight = $ny + [int](8 * $DpiScale)
            Fonts       = @($labelFont, $heroValueFont, $titleLabel.Font) + $emptyFonts
        }
    }

    # --- Layout (DPI-aware) ---
    $heroRh = [int](24 * $DpiScale)
    $lx = 20
    $y = [int](40 * $DpiScale)

    # --- Hero percent: the number users came for, big and status-colored ---
    # Light theme: Get-StatusColor's palette is tuned for the dark popup; darken it
    # so 18pt text stays readable on the light background (248,248,252).
    $heroPctColor = $statusColor
    if ($script:theme.PopupBg.GetBrightness() -gt 0.5) {
        $heroPctColor = [System.Drawing.Color]::FromArgb(
            [int]($statusColor.R * 0.62),
            [int]($statusColor.G * 0.62),
            [int]($statusColor.B * 0.62))
    }
    $heroPctFont = New-Object System.Drawing.Font("Segoe UI Semibold", 18, [System.Drawing.FontStyle]::Bold)
    if ($BatteryInfo.PercentExact -ge 0) {
        $heroPctLabel = New-Object System.Windows.Forms.Label
        $heroPctLabel.Text = "$([int][math]::Round($BatteryInfo.PercentExact))%"
        $heroPctLabel.Font = $heroPctFont
        $heroPctLabel.ForeColor = $heroPctColor
        $heroPctLabel.Location = New-Object System.Drawing.Point($lx, $y)
        $heroPctLabel.AutoSize = $true
        $heroPctLabel.MaximumSize = New-Object System.Drawing.Size(($PopupWidth - 40), 0)
        $Form.Controls.Add($heroPctLabel)
        $y += [int](40 * $DpiScale)
    }

    # Time - a sentence under the hero, not a labeled form row.
    # "3h 8m left — 6:42 PM" / "1h 3m to full — 5:10 PM" / "Fully charged"
    if ($BatteryInfo.IsFullyCharged) {
        $timeText = "Fully charged"
    } elseif ($BatteryInfo.TimeMinutes -gt 0) {
        $dur = Format-Duration -Minutes $BatteryInfo.TimeMinutes
        $suffix = if ($BatteryInfo.IsCharging) { "to full" } else { "left" }
        if ($BatteryInfo.ETA) {
            $timeText = "$dur $suffix $([char]0x2014) $($BatteryInfo.ETA)"
        } else {
            $timeText = "$dur $suffix"
        }
    } else {
        $timeText = "Estimating..."
    }
    $y += [int](4 * $DpiScale)
    $timeValLabel = New-Object System.Windows.Forms.Label
    $timeValLabel.Text = $timeText
    $timeValLabel.Font = $heroValueFont
    $timeValLabel.ForeColor = $script:theme.TextPrimary
    $timeValLabel.Location = New-Object System.Drawing.Point($lx, $y)
    $timeValLabel.AutoSize = $true
    $timeValLabel.MaximumSize = New-Object System.Drawing.Size(($PopupWidth - 40), 0)
    $Form.Controls.Add($timeValLabel)
    if ($timeText -eq "Estimating...") { $script:estimatingLabel = $timeValLabel }
    $y += $heroRh

    # A line of personality under the facts (optional - Settings toggle)
    $funFont = $null
    $funText = if ($script:config.FunLines) { Get-FunStatusLine -BatteryInfo $BatteryInfo } else { "" }
    if ($funText) {
        $funFont = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
        $funLabel = New-Object System.Windows.Forms.Label
        $funLabel.Text = $funText
        $funLabel.Font = $funFont
        $funLabel.ForeColor = $script:theme.TextDim
        $funLabel.Location = New-Object System.Drawing.Point($lx, $y)
        $funLabel.AutoSize = $true
        $funLabel.MaximumSize = New-Object System.Drawing.Size(($PopupWidth - 40), 0)
        $Form.Controls.Add($funLabel)
        $y += [int](18 * $DpiScale)
    }

    # Spacer before sparkline
    $y += [int](10 * $DpiScale)

    # Battery history sparkline (40px tall)
    $sparkAccent = Get-AccentColor -Percent $BatteryInfo.Percent -IsCharging $BatteryInfo.IsCharging
    $sparkPanel = New-SparklinePanel -Y $y -AccentColor $sparkAccent
    $sparkPanel.Size = New-Object System.Drawing.Size(($PopupWidth - 40), 40)
    $Form.Controls.Add($sparkPanel)
    $y += 40

    # Spacer after sparkline
    $y += [int](6 * $DpiScale)

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
        $y += [int](14 * $DpiScale)   # account for the hint's height so it doesn't clip the bottom edge
    }

    $fontsToDispose = @($labelFont, $heroValueFont, $heroPctFont, $titleLabel.Font)
    if ($null -ne $funFont) { $fontsToDispose += $funFont }
    if ($CloseHintText) { $fontsToDispose += $hintLabel.Font }
    return @{
        TotalHeight = $y + 8
        Fonts       = $fontsToDispose
    }
}

function Show-BatteryNotification {
    [OutputType([void])]
    param(
        [string]$Message,
        [string]$SubMessage,
        # Accent tints the left bar, border, and title. Default red suits the
        # battery warnings; pass a calmer color for informational cards.
        [System.Drawing.Color]$Accent = [System.Drawing.Color]::FromArgb(255, 70, 70)
    )
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

    # Escape-to-dismiss is wired below, once the per-notification state exists
    $notif.KeyPreview = $true

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
    $nPath = New-RoundedRectPath -Right $nrW -Bottom $nrH -Diameter $nd
    $notif.Region = New-Object System.Drawing.Region($nPath)
    $nPath.Dispose()

    # Closure captures $Accent per-card (Add_* handlers resolve at fire time)
    $notif.Add_Paint({
            param($sender, $e)
            $ng = $e.Graphics
            $ng.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $ng.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            # Accent bar on left
            $accentBrush = New-Object System.Drawing.SolidBrush($Accent)
            $ng.FillRectangle($accentBrush, 0, 0, 4, $sender.Height)
            $accentBrush.Dispose()
            # Border
            $br = 10; $bd = $br * 2
            $brW = $sender.Width - 2; $brH = $sender.Height - 2
            $bPath = New-RoundedRectPath -Right $brW -Bottom $brH -Diameter $bd
            $bPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, $Accent.R, $Accent.G, $Accent.B), 1)
            $ng.DrawPath($bPen, $bPath)
            $bPen.Dispose(); $bPath.Dispose()
        }.GetNewClosure())

    # Title
    $nPad = [int](16 * $nDs)
    $nTitle = New-Object System.Windows.Forms.Label
    $nTitle.Text = $Message
    $nTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
    # Title tint: lighten the accent so it reads on the dark card
    $nTitle.ForeColor = [System.Drawing.Color]::FromArgb(
        [math]::Min(255, $Accent.R + 30), [math]::Min(255, $Accent.G + 30), [math]::Min(255, $Accent.B + 30))
    $nTitle.Location = New-Object System.Drawing.Point($nPad, $nPad)
    $nTitle.AutoSize = $true
    $nTitle.MaximumSize = New-Object System.Drawing.Size(($nW - $nPad * 2), 0)
    $notif.Controls.Add($nTitle)

    # Sub-message
    $nSub = New-Object System.Windows.Forms.Label
    $nSub.Text = $SubMessage
    $nSub.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
    $nSub.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 225)  # fixed: card is always dark; theme.TextLight goes dark in Light theme and vanished here
    $nSub.Location = New-Object System.Drawing.Point($nPad, [int](48 * $nDs))
    $nSub.AutoSize = $true
    $nSub.MaximumSize = New-Object System.Drawing.Size(($nW - $nPad * 2), 0)
    $notif.Controls.Add($nSub)

    $notif.Show()

    # Per-notification animation state, captured into every handler with
    # GetNewClosure(). CRITICAL: Add_* scriptblocks resolve variables at FIRE
    # time - after this function returns, its locals are gone, so without the
    # closures the tick handler saw $notif/$notifTimer as $null, threw every
    # 16ms, and the card stayed at Opacity 0 forever (notifications were
    # invisible). The per-card hashtable also lets two live cards animate
    # independently instead of fighting over shared script-scope state.
    $nState = @{
        Phase       = "in"      # "in", "hold", "out"
        AnimStart   = Get-Date
        HoldStart   = $null
        SlideStart  = $notif.Top
        SlideTarget = $screen.Bottom - $nH - 20
        Fonts       = @($nTitle.Font, $nSub.Font)
    }

    # Dismissers: click anywhere on the card, or Escape
    $dismissClick = { $nState.Phase = "out" }.GetNewClosure()
    $notif.Add_Click($dismissClick)
    $nTitle.Add_Click($dismissClick)
    $nSub.Add_Click($dismissClick)
    $notif.Add_KeyDown({
            if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $nState.Phase = "out" }
        }.GetNewClosure())

    # Slide-in with cubic ease-out, hold 10s, fade out
    $notifTimer = New-Object System.Windows.Forms.Timer
    $notifTimer.Interval = 16
    $notifTimer.Add_Tick({
            if ($null -eq $notif -or $notif.IsDisposed) { $notifTimer.Stop(); $notifTimer.Dispose(); return }
            if ($nState.Phase -eq "in") {
                $elapsed = ((Get-Date) - $nState.AnimStart).TotalMilliseconds
                $t = [math]::Min(1.0, $elapsed / 300.0)
                # Cubic ease-out: 1 - (1 - t)^3
                $eased = 1.0 - [math]::Pow(1.0 - $t, 3)
                $notif.Opacity = $eased
                $notif.Top = [int]($nState.SlideStart + ($nState.SlideTarget - $nState.SlideStart) * $eased)
                if ($t -ge 1.0) {
                    $notif.Opacity = 1.0
                    $notif.Top = $nState.SlideTarget
                    $nState.Phase = "hold"
                    $nState.HoldStart = Get-Date
                }
            } elseif ($nState.Phase -eq "hold") {
                if (((Get-Date) - $nState.HoldStart).TotalSeconds -ge 10) {
                    $nState.Phase = "out"
                }
            } elseif ($nState.Phase -eq "out") {
                $notif.Opacity -= 0.06
                if ($notif.Opacity -le 0) {
                    $notifTimer.Stop(); $notifTimer.Dispose()
                    foreach ($nf in $nState.Fonts) { if ($null -ne $nf) { $nf.Dispose() } }
                    $notif.Close(); $notif.Dispose()
                }
            }
        }.GetNewClosure())
    $notifTimer.Start()
}

function Update-FloatingBar {
    [OutputType([void])]
    param([hashtable]$BatteryInfo)

    if ($null -eq $script:floatingBar -or $script:floatingBar.IsDisposed) { return }

    # Update display text based on DisplayMode
    $timeStr = ""
    $pctStr = ""
    if ($BatteryInfo.NoBattery) {
        # Desktop / no battery: show "AC" rather than a dead "N/A"
        $timeStr = "AC"
        $pctStr = "AC"
    } elseif ($BatteryInfo.IsFullyCharged) {
        $timeStr = "Full"
        $pctStr = "100%"
    } elseif ($BatteryInfo.TimeMinutes -gt 0) {
        $timeStr = Format-Duration -Minutes $BatteryInfo.TimeMinutes
        # A rejected/unknown percent stays -1: show "--" rather than "-1%"
        $pctStr = if ($BatteryInfo.Percent -ge 0) { "$($BatteryInfo.Percent)%" } else { "--" }
    } else {
        # Time not computed yet — fall back to the (real) percent instead of dead dashes
        $pctStr = if ($BatteryInfo.Percent -ge 0) { "$($BatteryInfo.Percent)%" } else { "--" }
        $timeStr = $pctStr
    }

    $displayMode = $script:config.DisplayMode
    switch ($displayMode) {
        "percent" {
            $script:barDisplayText = $pctStr
            $script:barDisplayText2 = ""
        }
        "both" {
            $script:barDisplayText = $pctStr
            # No battery: both lines would read "AC"/"AC" - show it once
            $script:barDisplayText2 = if ($BatteryInfo.NoBattery) { "" } else { $timeStr }
        }
        default {
            # "time" mode (default)
            $script:barDisplayText = $timeStr
            $script:barDisplayText2 = ""
        }
    }

    # Text crossfade: a changed value fades back in (skip while the intro
    # sweep owns the pill, and skip entirely when animations are off)
    if ($script:animOK -and $script:barDisplayText -ne $script:prevDisplayText -and $script:prevDisplayText -ne "") {
        $script:textFadeAlpha = 80
    }
    $script:prevDisplayText = $script:barDisplayText

    # Update battery percent and charging state for the mini icon
    $script:barDisplayPercent = $BatteryInfo.Percent
    if (-not $script:animOK -or $null -eq $script:lastBatteryInfo) {
        # No animations, or the very first reading: the painted level tracks
        # the raw value directly (never glide up from the placeholder 50)
        $script:displayedFillPct = [double]$BatteryInfo.Percent
    }
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
        if ($BatteryInfo.IsPluggedIn -and -not $BatteryInfo.NoBattery) {
            # Plug-in moment: bolt pops on the pill, and a card answers the
            # question the user actually has - "when will it be full?"
            if ($script:animOK) { $script:boltPopStart = Get-Date }
            if (-not $BatteryInfo.IsFullyCharged) {
                $plugSub = if ($BatteryInfo.TimeMinutes -gt 0 -and $BatteryInfo.ETA) {
                    "Full by $($BatteryInfo.ETA)"
                } else {
                    "Battery charging"
                }
                Show-BatteryNotification -Message "Plugged in" -SubMessage $plugSub `
                    -Accent ([System.Drawing.Color]::FromArgb(255, 200, 0))
            }
        }
        Update-PulseTimerState
    }
    $script:lastPluggedState = $BatteryInfo.IsPluggedIn

    # Full-charge moment: one shimmer sweep + a card, once per plug session.
    # Requires a PREVIOUS reading (no celebration when the app merely launches
    # on an already-full battery).
    if ($BatteryInfo.IsFullyCharged -and $BatteryInfo.IsPluggedIn -and
        -not $script:wasFullyCharged -and $null -ne $script:lastBatteryInfo -and
        -not $script:fullChargeShown) {
        $script:fullChargeShown = $true
        if ($script:animOK) { $script:shimmerStart = Get-Date; Update-PulseTimerState }
        Show-BatteryNotification -Message "Fully charged" -SubMessage "Battery at 100% - free to unplug" `
            -Accent ([System.Drawing.Color]::FromArgb(45, 212, 100))
    }
    $script:wasFullyCharged = $BatteryInfo.IsFullyCharged
    if (-not $BatteryInfo.IsPluggedIn) { $script:fullChargeShown = $false }

    # Low battery warning logic — show once per threshold per discharge cycle
    if ($BatteryInfo.IsPluggedIn -or $BatteryInfo.IsCharging) {
        # Reset warning flags when plugged in
        $script:lowBatShown10 = $false
        $script:lowBatShown5 = $false
        $script:lowBatPulseActive = $false
        $script:lowBatBorderAlpha = 0
        if ($script:lowBatOpacityPulse) {
            # Restore configured opacity - the oscillation may have left it mid-swing
            $script:lowBatOpacityPulse = $false
            $script:floatingBar.Opacity = $script:config.Opacity
        }
    } elseif ($BatteryInfo.Percent -lt 0) {
        # No source gave a percent this tick. That is not "the battery is at 0",
        # so it must not raise an alarm - and it must not silently HOLD one
        # either: every band below is a `-le`/`-gt` test that -1 falls through,
        # so a pill already pulsing red kept pulsing (and oscillating its
        # opacity) for as long as the reading stayed unavailable.
        $script:lowBatPulseActive = $false
        $script:lowBatBorderAlpha = 0
        if ($script:lowBatOpacityPulse) {
            $script:lowBatOpacityPulse = $false
            $script:floatingBar.Opacity = $script:config.Opacity
        }
    } else {
        $pct = $BatteryInfo.Percent
        if ($pct -gt 15) {
            # Recovered above the warning band (e.g. percent bounced 15<->16):
            # clear the pulse state or the red border/opacity swing sticks forever
            $script:lowBatPulseActive = $false
            $script:lowBatBorderAlpha = 0
            if ($script:lowBatOpacityPulse) {
                $script:lowBatOpacityPulse = $false
                $script:floatingBar.Opacity = $script:config.Opacity
            }
        }
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
        # 5% and below — critical notification. `-ge 0`, not `-gt 0`: a battery
        # reporting a hard 0% fell through EVERY band, so the one moment the
        # user most needs the critical card was the one moment it never fired.
        # (-1 "no reading" is handled by the branch above, not here.)
        if ($pct -le 5 -and $pct -ge 0) {
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

