# ============================================================
# SETTINGS PANEL
# ============================================================

function Set-ThemedComboBox {
    # Apply owner-draw theming to a ComboBox. Colors are read from
    # $script:theme at PAINT time, so the dropdown always matches the theme
    # the panel was opened under.
    [OutputType([void])]
    param([System.Windows.Forms.ComboBox]$Combo)
    $Combo.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    $Combo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Combo.Add_DrawItem({
            param($sender, $e)
            if ($e.Index -lt 0) { return }
            $e.DrawBackground()
            $isSelected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -eq [System.Windows.Forms.DrawItemState]::Selected
            $bgColor = if ($isSelected) { $script:theme.PanelHover } else { $script:theme.PanelCtrl }
            $fgColor = if ($isSelected) { $script:theme.TextPrimary } else { $script:theme.PanelText }
            $bgBrush = New-Object System.Drawing.SolidBrush($bgColor)
            $e.Graphics.FillRectangle($bgBrush, $e.Bounds)
            $bgBrush.Dispose()
            $text = $sender.Items[$e.Index].ToString()
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $sender.Font, $e.Bounds, $fgColor, [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter)
        })
}

function Start-IntroAnimation {
    [OutputType([void])]
    param()
    # First-launch choreography: the pill rises into place (280ms ease-out),
    # its charge fill sweeps up to the real level (500ms), then the first-run
    # tips appear - in that order. Skipped entirely (instant appear, tips
    # immediately) when Windows animations are turned off, and lands instantly
    # if the user grabs the pill mid-intro.
    # NOTE: plain scriptblock + $script: state on purpose. A GetNewClosure()
    # handler resolves $script: against the CLOSURE MODULE's scope, where
    # $script:floatingBar is $null - the closure pattern only suits handlers
    # that touch captured locals exclusively (like the notification cards).
    if ($null -eq $script:floatingBar -or $script:floatingBar.IsDisposed -or -not $script:floatingBar.Visible) {
        Show-FirstRunTooltip
        return
    }
    if (-not $script:config.Animations) {
        $script:floatingBar.Opacity = $script:config.Opacity
        Show-FirstRunTooltip
        return
    }
    $script:introState = @{
        Phase         = "rise"
        Start         = Get-Date
        TargetTop     = $script:floatingBar.Top
        TargetOpacity = $script:config.Opacity
        TargetPct     = [math]::Max(0, $script:barDisplayPercent)   # unknown/no battery (-1) -> skip the sweep
    }
    $script:floatingBar.Top = $script:introState.TargetTop + 14
    $script:introTimer = New-Object System.Windows.Forms.Timer
    $script:introTimer.Interval = 16
    $script:introTimer.Add_Tick({
            if ($null -eq $script:floatingBar -or $script:floatingBar.IsDisposed) {
                $script:introTimer.Stop(); $script:introTimer.Dispose(); $script:introTimer = $null; return
            }
            $st = $script:introState
            # User grabbed it mid-intro: land everything instantly, get out of the way
            if ($script:leftPressed -or $script:isDragging) {
                $script:floatingBar.Opacity = $st.TargetOpacity
                $script:floatingBar.Top = $st.TargetTop
                $script:barDisplayPercent = $st.TargetPct
                $script:displayedFillPct = [double]$st.TargetPct
                $script:floatingBar.Invalidate()
                $script:introTimer.Stop(); $script:introTimer.Dispose(); $script:introTimer = $null
                Show-FirstRunTooltip
                return
            }
            $ms = ((Get-Date) - $st.Start).TotalMilliseconds
            if ($st.Phase -eq "rise") {
                $t = [math]::Min(1.0, $ms / 280.0)
                $eased = 1.0 - [math]::Pow(1.0 - $t, 3)
                $script:floatingBar.Opacity = $st.TargetOpacity * $eased
                $script:floatingBar.Top = [int]($st.TargetTop + 14 * (1.0 - $eased))
                if ($t -ge 1.0) {
                    $script:floatingBar.Opacity = $st.TargetOpacity
                    $script:floatingBar.Top = $st.TargetTop
                    if ($st.TargetPct -gt 0) {
                        $script:barDisplayPercent = 0
                        $script:displayedFillPct = 0.0
                        $st.Phase = "sweep"; $st.Start = Get-Date
                    } else {
                        $script:introTimer.Stop(); $script:introTimer.Dispose(); $script:introTimer = $null
                        Show-FirstRunTooltip
                    }
                }
            } elseif ($st.Phase -eq "sweep") {
                $t = [math]::Min(1.0, $ms / 500.0)
                $eased = 1.0 - [math]::Pow(1.0 - $t, 3)
                $script:barDisplayPercent = [int]($st.TargetPct * $eased)
                $script:displayedFillPct = [double]$script:barDisplayPercent
                $script:floatingBar.Invalidate()
                if ($t -ge 1.0) {
                    $script:barDisplayPercent = $st.TargetPct
                    $script:displayedFillPct = [double]$st.TargetPct
                    $script:floatingBar.Invalidate()
                    $script:introTimer.Stop(); $script:introTimer.Dispose(); $script:introTimer = $null
                    Show-FirstRunTooltip
                }
            }
        })
    $script:introTimer.Start()
}

function Show-FirstRunTooltip {
    [OutputType([void])]
    param()
    if ($script:config.FirstRunShown) { return }
    $script:config.FirstRunShown = $true
    Save-Config

    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $ds = $g.DpiX / 96.0
    $g.Dispose()
    $ttW = [int](260 * $ds); $ttH = [int](134 * $ds)   # fits 4 tips at 24px spacing

    # NoActivateForm: the tip appears unattended and must not steal focus
    $script:firstRunTip = New-Object NoActivateForm
    $script:firstRunTip.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $script:firstRunTip.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $script:firstRunTip.Size = New-Object System.Drawing.Size($ttW, $ttH)
    $script:firstRunTip.TopMost = $true
    $script:firstRunTip.ShowInTaskbar = $false
    $script:firstRunTip.BackColor = $script:theme.PopupBg
    $script:firstRunTip.Opacity = 0
    Enable-DoubleBuffering -Form $script:firstRunTip

    # Native rounded corners + shadow (Region-clip fallback on Win10)
    Set-NativeRoundedCorners -Form $script:firstRunTip -FallbackRadius 10

    $script:firstRunTip.Add_Paint({
            param($sender, $e)
            $tg = $e.Graphics
            $tg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $br = 10; $bd = $br * 2   # matches the region radius above
            $bPath = New-RoundedRectPath -Right ($sender.Width - $bd - 2) -Bottom ($sender.Height - $bd - 2) -Diameter $bd
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
        "Click to change what it shows"
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
        $lbl.ForeColor = $script:theme.TextLight  # tip card follows the theme since the parity pass
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
    [OutputType([void])]
    param()
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
    $settings.BackColor = $script:theme.PanelBg
    $settings.ForeColor = $script:theme.PanelText
    $settings.Add_HandleCreated({ [Win32Icon]::SetTitleBarTheme($settings.Handle, $script:theme.IsDark) })

    $labelFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $sectionFont = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    # Muted neutral: section headers are wayfinding, not accents
    $sectionColor = $script:theme.PanelHead
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
            $script:settingsDisplayCombo = $null   # stop click-cycle sync once the panel closes
        })

    # --- Behavior section header ---
    $bhvSep = New-Object System.Windows.Forms.Label
    $bhvSep.Location = New-Object System.Drawing.Point($m, $y)
    $bhvSep.Size = New-Object System.Drawing.Size($cw, 1)
    $bhvSep.BackColor = $script:theme.PanelCtrl
    $settings.Controls.Add($bhvSep)
    $y += [int](8 * $ds)
    $bhvHeader = New-Object System.Windows.Forms.Label
    $bhvHeader.Text = "Behavior"
    $bhvHeader.Font = $sectionFont
    $bhvHeader.ForeColor = $sectionColor
    $bhvHeader.Location = New-Object System.Drawing.Point($m, $y)
    $bhvHeader.AutoSize = $true
    $settings.Controls.Add($bhvHeader)
    $y += [int](24 * $ds)

    # Auto-start checkbox
    $autoStartCheck = New-Object DarkCheckBox
    $autoStartCheck.Text = "Start with Windows"
    $autoStartCheck.Font = $labelFont
    $autoStartCheck.ForeColor = $script:theme.PanelText
    $autoStartCheck.Location = New-Object System.Drawing.Point($m, $y)
    $autoStartCheck.AutoSize = $false
    $autoStartCheck.Size = New-Object System.Drawing.Size($cw, [int](22 * $ds))
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
    $showBarCheck = New-Object DarkCheckBox
    $showBarCheck.Text = "Show floating pill"
    $showBarCheck.Font = $labelFont
    $showBarCheck.ForeColor = $script:theme.PanelText
    $showBarCheck.Location = New-Object System.Drawing.Point($m, $y)
    $showBarCheck.AutoSize = $false
    $showBarCheck.Size = New-Object System.Drawing.Size($cw, [int](22 * $ds))
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
    $lockPosCheck = New-Object DarkCheckBox
    $lockPosCheck.Text = "Lock pill position"
    $lockPosCheck.Font = $labelFont
    $lockPosCheck.ForeColor = $script:theme.PanelText
    $lockPosCheck.Location = New-Object System.Drawing.Point($m, $y)
    $lockPosCheck.AutoSize = $false
    $lockPosCheck.Size = New-Object System.Drawing.Size($cw, [int](22 * $ds))
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
    $autoHideCheck = New-Object DarkCheckBox
    $autoHideCheck.Text = "Auto-hide in fullscreen"
    $autoHideCheck.Font = $labelFont
    $autoHideCheck.ForeColor = $script:theme.PanelText
    $autoHideCheck.Location = New-Object System.Drawing.Point($m, $y)
    $autoHideCheck.AutoSize = $false
    $autoHideCheck.Size = New-Object System.Drawing.Size($cw, [int](22 * $ds))
    $autoHideCheck.Checked = $script:config.AutoHideFullscreen
    $autoHideCheck.Add_CheckedChanged({
            $script:config.AutoHideFullscreen = $autoHideCheck.Checked
            Save-Config
        })
    $settings.Controls.Add($autoHideCheck)
    $settingsTooltip.SetToolTip($autoHideCheck, "Hide pill when fullscreen apps are active (games, videos)")
    $y += [int](30 * $ds)

    # Animations checkbox (the app's own gate - deliberately independent of
    # the Windows "animate controls" toggle; see New-FloatingBar)
    $animCheck = New-Object DarkCheckBox
    $animCheck.Text = "Animations"
    $animCheck.Font = $labelFont
    $animCheck.ForeColor = $script:theme.PanelText
    $animCheck.Location = New-Object System.Drawing.Point($m, $y)
    $animCheck.AutoSize = $false
    $animCheck.Size = New-Object System.Drawing.Size($cw, [int](22 * $ds))
    $animCheck.Checked = $script:config.Animations
    $animCheck.Add_CheckedChanged({
            $script:config.Animations = $animCheck.Checked
            $script:animOK = $animCheck.Checked
            Save-Config
            # Apply it NOW rather than at the next battery tick (up to 60s
            # away on the slowest refresh setting). Turning it OFF mid-pulse
            # would otherwise freeze the pill part-faded and its warning
            # border mid-swing; turning it ON would appear to do nothing.
            # Update-FloatingBar owns the static-warning compensation and
            # Update-PulseTimerState owns starting/stopping the 33ms timer.
            if ($null -ne $script:lastBatteryInfo) {
                Update-FloatingBar -BatteryInfo $script:lastBatteryInfo
            }
            Update-PulseTimerState
        })
    $settings.Controls.Add($animCheck)
    $settingsTooltip.SetToolTip($animCheck, "Smooth transitions, glides and little moments (off = everything is instant)")
    $y += [int](30 * $ds)

    # Fun status lines checkbox
    $funLinesCheck = New-Object DarkCheckBox
    $funLinesCheck.Text = "Fun status lines"
    $funLinesCheck.Font = $labelFont
    $funLinesCheck.ForeColor = $script:theme.PanelText
    $funLinesCheck.Location = New-Object System.Drawing.Point($m, $y)
    $funLinesCheck.AutoSize = $false
    $funLinesCheck.Size = New-Object System.Drawing.Size($cw, [int](22 * $ds))
    $funLinesCheck.Checked = $script:config.FunLines
    $funLinesCheck.Add_CheckedChanged({
            $script:config.FunLines = $funLinesCheck.Checked
            Save-Config
        })
    $settings.Controls.Add($funLinesCheck)
    $settingsTooltip.SetToolTip($funLinesCheck, "A line of personality in the battery popup")
    $y += [int](36 * $ds)

    # Light theme: brighten the checkbox boxes (the C# defaults are the dark palette)
    if (-not $script:theme.IsDark) {
        foreach ($tcb in @($autoStartCheck, $showBarCheck, $lockPosCheck, $autoHideCheck, $animCheck, $funLinesCheck)) {
            $tcb.BoxFill = [System.Drawing.Color]::FromArgb(255, 255, 255)
            $tcb.BoxBorder = [System.Drawing.Color]::FromArgb(168, 168, 178)
            $tcb.BoxBorderHot = [System.Drawing.Color]::FromArgb(120, 120, 132)
        }
    }

    # --- Appearance section header ---
    $appSep = New-Object System.Windows.Forms.Label
    $appSep.Location = New-Object System.Drawing.Point($m, $y)
    $appSep.Size = New-Object System.Drawing.Size($cw, 1)
    $appSep.BackColor = $script:theme.PanelCtrl
    $settings.Controls.Add($appSep)
    $y += [int](8 * $ds)
    $appHeader = New-Object System.Windows.Forms.Label
    $appHeader.Text = "Appearance"
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
    $displayLabel.ForeColor = $script:theme.PanelText
    $displayLabel.Location = New-Object System.Drawing.Point($m, $y)
    $displayLabel.AutoSize = $true
    $settings.Controls.Add($displayLabel)
    $y += [int](26 * $ds)

    $displayCombo = New-Object System.Windows.Forms.ComboBox
    $displayCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $displayCombo.Font = $labelFont
    $displayCombo.BackColor = $script:theme.PanelCtrl
    $displayCombo.ForeColor = $script:theme.PanelText
    $displayCombo.Location = New-Object System.Drawing.Point($m, $y)
    $displayCombo.Size = New-Object System.Drawing.Size($cw, [int](28 * $ds))
    $displayCombo.Items.AddRange(@("Time remaining", "Percentage", "Both (% + time)"))
    $displayIdx = switch ($script:config.DisplayMode) {
        "time" { 0 }
        "percent" { 1 }
        "both" { 2 }
        default { 0 }
    }
    $displayCombo.SelectedIndex = $displayIdx
    $displayCombo.Add_SelectedIndexChanged({
            $modeMap = @("time", "percent", "both")
            $script:config.DisplayMode = $modeMap[$displayCombo.SelectedIndex]
            Update-PillSize
            # Update-PillSize resizes and re-fonts the pill but does NOT rebuild
            # its text - only Update-FloatingBar does. Without this, picking
            # "Both" here grew the pill to two lines while $barDisplayText2 was
            # still empty, so it sat noticeably taller showing one stale line
            # until the next refresh tick (up to 10s on the slowest setting).
            # Invoke-CycleDisplayMode already does exactly this on pill click.
            if ($null -ne $script:lastBatteryInfo) {
                Update-FloatingBar -BatteryInfo $script:lastBatteryInfo
            }
            Save-Config
        })
    Set-ThemedComboBox -Combo $displayCombo
    $settings.Controls.Add($displayCombo)
    $settingsTooltip.SetToolTip($displayCombo, "Choose what information appears on the pill")
    $script:settingsDisplayCombo = $displayCombo   # let click-cycle keep this in sync while the panel is open
    $y += [int](36 * $ds)

    # --- Pill size section ---
    $sizeLabel = New-Object System.Windows.Forms.Label
    $sizeLabel.Text = "Pill size:"
    $sizeLabel.Font = $labelFont
    $sizeLabel.ForeColor = $script:theme.PanelText
    $sizeLabel.Location = New-Object System.Drawing.Point($m, $y)
    $sizeLabel.AutoSize = $true
    $settings.Controls.Add($sizeLabel)
    $y += [int](26 * $ds)

    $sizeCombo = New-Object System.Windows.Forms.ComboBox
    $sizeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $sizeCombo.Font = $labelFont
    $sizeCombo.BackColor = $script:theme.PanelCtrl
    $sizeCombo.ForeColor = $script:theme.PanelText
    $sizeCombo.Location = New-Object System.Drawing.Point($m, $y)
    $sizeCombo.Size = New-Object System.Drawing.Size($cw, [int](28 * $ds))
    $sizeCombo.Items.AddRange(@("Compact (80x28)", "Normal (108x34)", "Expanded (140x42)"))
    $sizeIdx = switch ($script:config.PillSize) {
        "compact" { 0 }
        "normal" { 1 }
        "expanded" { 2 }
        default { 1 }
    }
    $sizeCombo.SelectedIndex = $sizeIdx
    $sizeCombo.Add_SelectedIndexChanged({
            $sizeMap = @("compact", "normal", "expanded")
            $script:config.PillSize = $sizeMap[$sizeCombo.SelectedIndex]
            Update-PillSize
            # Same reason as the display combo: "compact" drops the second line
            # entirely (FontSize2 = 0), so the pill must re-derive its text for
            # the new geometry instead of waiting for the next tick.
            if ($null -ne $script:lastBatteryInfo) {
                Update-FloatingBar -BatteryInfo $script:lastBatteryInfo
            }
            Save-Config
        })
    Set-ThemedComboBox -Combo $sizeCombo
    $settings.Controls.Add($sizeCombo)
    $settingsTooltip.SetToolTip($sizeCombo, "Adjust the size of the floating pill")
    $y += [int](36 * $ds)

    # --- Accent color section ---
    $accentLabel = New-Object System.Windows.Forms.Label
    $accentLabel.Text = "Accent color:"
    $accentLabel.Font = $labelFont
    $accentLabel.ForeColor = $script:theme.PanelText
    $accentLabel.Location = New-Object System.Drawing.Point($m, $y)
    $accentLabel.AutoSize = $true
    $settings.Controls.Add($accentLabel)
    $y += [int](26 * $ds)

    $circleSize = [int](24 * $ds)
    $circleSpacing = [int](32 * $ds)
    for ($ci = 0; $ci -lt 8; $ci++) {
        $colorPanel = New-Object System.Windows.Forms.Panel
        $colorPanel.Size = New-Object System.Drawing.Size($circleSize, $circleSize)
        $colorPanel.Location = New-Object System.Drawing.Point(($m + $ci * $circleSpacing), $y)
        $colorPanel.BackColor = [System.Drawing.Color]::Transparent
        $colorPanel.Tag = @{ Index = $ci; Hovered = $false; Pressed = $false }
        $colorPanel.Add_Paint({
                param($sender, $e)
                $cg = $e.Graphics
                $cg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $tagData = $sender.Tag
                $idx = $tagData.Index
                $isHovered = $tagData.Hovered
                $isPressed = $tagData.Pressed
                $color = $script:accentPresets[$idx]
                $brush = New-Object System.Drawing.SolidBrush($color)
                # Tactile scale: shrink on press (0.9), grow on hover (1.15), else rest
                $scale = if ($isPressed) { 0.9 } elseif ($isHovered) { 1.15 } else { 0 }
                if ($scale -gt 0) {
                    $cw = $sender.Width - 5; $ch = $sender.Height - 5
                    $sw = [int]($cw * $scale); $sh = [int]($ch * $scale)
                    $sx = [int]((($sender.Width - $sw) / 2) - 0.5)
                    $sy = [int]((($sender.Height - $sh) / 2) - 0.5)
                    $cg.FillEllipse($brush, $sx, $sy, $sw, $sh)
                } else {
                    $cg.FillEllipse($brush, 2, 2, $sender.Width - 5, $sender.Height - 5)
                }
                $brush.Dispose()
                # Selection ring — a contrasting ring with a gap, so the active swatch
                # is unmistakable. (An accent-hued ring on an accent dot was invisible.)
                if ($idx -eq $script:config.AccentColorIndex) {
                    # Gap: punch the panel-bg between dot and ring so they read separately
                    $gapPen = New-Object System.Drawing.Pen($script:theme.PanelBg, 2)
                    $cg.DrawEllipse($gapPen, 1, 1, $sender.Width - 3, $sender.Height - 3)
                    $gapPen.Dispose()
                    # Ring: light on dark swatches, dark on light ones (e.g. the white preset)
                    $lum = ($color.R * 0.299) + ($color.G * 0.587) + ($color.B * 0.114)
                    $ringColor = if ($lum -gt 180) {
                        [System.Drawing.Color]::FromArgb(120, 120, 130)
                    } else {
                        [System.Drawing.Color]::FromArgb(240, 240, 245)
                    }
                    $ringPen = New-Object System.Drawing.Pen($ringColor, 2)
                    $cg.DrawEllipse($ringPen, 0, 0, $sender.Width - 1, $sender.Height - 1)
                    $ringPen.Dispose()
                }
            })
        $colorPanel.Add_MouseEnter({ param($sender); $sender.Tag.Hovered = $true; $sender.Invalidate() })
        $colorPanel.Add_MouseLeave({ param($sender); $sender.Tag.Hovered = $false; $sender.Tag.Pressed = $false; $sender.Invalidate() })
        $colorPanel.Add_MouseDown({ param($sender); $sender.Tag.Pressed = $true; $sender.Invalidate() })
        $colorPanel.Add_MouseUp({ param($sender); $sender.Tag.Pressed = $false; $sender.Invalidate() })
        $colorPanel.Add_Click({
                param($sender)
                $script:config.AccentColorIndex = $sender.Tag.Index
                $script:cachedIconPercent = -999   # force tray icon rebuild with the new accent
                Save-Config
                # Glide the pill to the new accent in ~0.3s (pulse timer) instead
                # of stepping there over several slow refresh-tick lerps
                if ($null -ne $script:lastBatteryInfo) {
                    Update-FloatingBar -BatteryInfo $script:lastBatteryInfo
                    if ($script:animOK) {
                        $script:colorFadeActive = $true
                        Update-PulseTimerState
                    }
                }
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
    $y += [int](30 * $ds)

    # --- Theme section ---
    $themeLabel = New-Object System.Windows.Forms.Label
    $themeLabel.Text = "Theme:"
    $themeLabel.Font = $labelFont
    $themeLabel.ForeColor = $script:theme.PanelText
    $themeLabel.Location = New-Object System.Drawing.Point($m, $y)
    $themeLabel.AutoSize = $true
    $settings.Controls.Add($themeLabel)
    $y += [int](26 * $ds)

    $themeCombo = New-Object System.Windows.Forms.ComboBox
    $themeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $themeCombo.Font = $labelFont
    $themeCombo.BackColor = $script:theme.PanelCtrl
    $themeCombo.ForeColor = $script:theme.PanelText
    $themeCombo.Location = New-Object System.Drawing.Point($m, $y)
    $themeCombo.Size = New-Object System.Drawing.Size($cw, [int](28 * $ds))
    $themeCombo.Items.AddRange(@("Dark", "Light", "Auto (follow Windows)"))
    $themeIdx = switch ($script:config.Theme) {
        "dark" { 0 }
        "light" { 1 }
        "auto" { 2 }
        default { 0 }
    }
    $themeCombo.SelectedIndex = $themeIdx
    $themeCombo.Add_SelectedIndexChanged({
            $themeMap = @("dark", "light", "auto")
            $script:config.Theme = $themeMap[$themeCombo.SelectedIndex]
            Set-Theme
            Save-Config
        })
    Set-ThemedComboBox -Combo $themeCombo
    $settings.Controls.Add($themeCombo)
    $settingsTooltip.SetToolTip($themeCombo, "Color scheme (Auto follows Windows theme)")
    $y += [int](40 * $ds)

    # --- Advanced section header ---
    $advSep = New-Object System.Windows.Forms.Label
    $advSep.Location = New-Object System.Drawing.Point($m, $y)
    $advSep.Size = New-Object System.Drawing.Size($cw, 1)
    $advSep.BackColor = $script:theme.PanelCtrl
    $settings.Controls.Add($advSep)
    $y += [int](8 * $ds)
    $advHeader = New-Object System.Windows.Forms.Label
    $advHeader.Text = "Advanced"
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
    $opacityLabel.ForeColor = $script:theme.PanelText
    $opacityLabel.Location = New-Object System.Drawing.Point($m, $y)
    $opacityLabel.AutoSize = $true
    $settings.Controls.Add($opacityLabel)

    # Opacity value label (right-aligned)
    $opacityValueLabel = New-Object System.Windows.Forms.Label
    $opacityValueLabel.Text = "{0}%" -f [int]($script:config.Opacity * 100)
    $opacityValueLabel.Font = $labelFont
    $opacityValueLabel.ForeColor = $script:theme.PanelText
    $opacityValueLabel.Location = New-Object System.Drawing.Point([int](260 * $ds), $y)
    $opacityValueLabel.AutoSize = $true
    $settings.Controls.Add($opacityValueLabel)
    $y += [int](24 * $ds)

    # Opacity slider - custom-drawn (30-100 -> 0.3-1.0). A stock WinForms
    # TrackBar can't be themed (light track, system-blue thumb, tick marks) and
    # was the one un-dark control on the panel; this one matches the app.
    $script:opacityVal = [int]($script:config.Opacity * 100)
    $script:opacityDragging = $false
    $sliderH = [int](24 * $ds)
    $opacitySlider = New-Object System.Windows.Forms.Panel
    $opacitySlider.Location = New-Object System.Drawing.Point($m, $y)
    $opacitySlider.Size = New-Object System.Drawing.Size($cw, $sliderH)
    $opacitySlider.BackColor = $script:theme.PanelBg
    $opacitySlider.Cursor = [System.Windows.Forms.Cursors]::Hand
    $sTx0 = [int](9 * $ds); $sThumbR = [int](7 * $ds)
    $opacitySlider.Add_Paint({
            param($sender, $e)
            $sg = $e.Graphics
            $sg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $tx0 = $sTx0; $tx1 = $sender.Width - $sTx0; $tw = $tx1 - $tx0
            $cy = [int]($sender.Height / 2)
            $frac = ($script:opacityVal - 30) / 70.0
            $thumbX = [int]($tx0 + $frac * $tw)
            # track
            $trkPen = New-Object System.Drawing.Pen($script:theme.PanelTrack, 3)
            $sg.DrawLine($trkPen, $tx0, $cy, $tx1, $cy); $trkPen.Dispose()
            # filled portion (accent)
            $accent = $script:accentPresets[[math]::Max(0, [math]::Min(7, [int]$script:config.AccentColorIndex))]
            $filPen = New-Object System.Drawing.Pen($accent, 3)
            $sg.DrawLine($filPen, $tx0, $cy, $thumbX, $cy); $filPen.Dispose()
            # thumb
            $thBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(238, 238, 244))
            $sg.FillEllipse($thBrush, ($thumbX - $sThumbR), ($cy - $sThumbR), ($sThumbR * 2), ($sThumbR * 2)); $thBrush.Dispose()
            $thPen = New-Object System.Drawing.Pen($script:theme.PanelHead, 1)
            $sg.DrawEllipse($thPen, ($thumbX - $sThumbR), ($cy - $sThumbR), ($sThumbR * 2), ($sThumbR * 2)); $thPen.Dispose()
        })
    $setOpacityFromX = {
        param($px)
        $tx0 = $sTx0; $tx1 = $opacitySlider.Width - $sTx0; $tw = $tx1 - $tx0
        $frac = ([math]::Max($tx0, [math]::Min($tx1, $px)) - $tx0) / [double]$tw
        $val = [int][math]::Round(30 + $frac * 70)
        $val = [math]::Max(30, [math]::Min(100, $val))
        $script:opacityVal = $val
        $script:floatingBar.Opacity = $val / 100.0
        $script:config.Opacity = $val / 100.0
        $opacityValueLabel.Text = "$val%"
        $opacitySlider.Invalidate()
    }
    $opacitySlider.Add_MouseDown({ param($s, $e) $script:opacityDragging = $true; & $setOpacityFromX $e.X }.GetNewClosure())
    $opacitySlider.Add_MouseMove({ param($s, $e) if ($script:opacityDragging) { & $setOpacityFromX $e.X } }.GetNewClosure())
    $opacitySlider.Add_MouseUp({ $script:opacityDragging = $false; Save-Config }.GetNewClosure())
    $settings.Controls.Add($opacitySlider)
    $y += [int](40 * $ds)

    # --- Refresh rate section ---

    $refreshLabel = New-Object System.Windows.Forms.Label
    $refreshLabel.Text = "Refresh rate:"
    $refreshLabel.Font = $labelFont
    $refreshLabel.ForeColor = $script:theme.PanelText
    $refreshLabel.Location = New-Object System.Drawing.Point($m, $y)
    $refreshLabel.AutoSize = $true
    $settings.Controls.Add($refreshLabel)
    $y += [int](26 * $ds)

    $refreshCombo = New-Object System.Windows.Forms.ComboBox
    $refreshCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $refreshCombo.Font = $labelFont
    $refreshCombo.BackColor = $script:theme.PanelCtrl
    $refreshCombo.ForeColor = $script:theme.PanelText
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
    Set-ThemedComboBox -Combo $refreshCombo
    $settings.Controls.Add($refreshCombo)
    $settingsTooltip.SetToolTip($refreshCombo, "How often battery data refreshes (lower = more CPU)")
    $y += [int](40 * $ds)

    # --- Buttons section ---

    # Reset position button
    $resetBtn = New-Object System.Windows.Forms.Button
    $resetBtn.Text = "Reset Pill Position"
    $resetBtn.Font = $labelFont
    $resetBtn.Size = New-Object System.Drawing.Size($cw, $bh)
    $resetBtn.Location = New-Object System.Drawing.Point($m, $y)
    $resetBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $resetBtn.FlatAppearance.BorderSize = 0
    $resetBtn.BackColor = $script:theme.PanelCtrl
    $resetBtn.ForeColor = $script:theme.PanelText
    $resetBtn.FlatAppearance.MouseOverBackColor = $script:theme.PanelHover
    $resetBtn.FlatAppearance.MouseDownBackColor = $script:theme.PanelDown
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
    $y += [int](34 * $ds)

    # Close button (accent green)
    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = "Close"
    $closeBtn.Font = $labelFont
    $closeBtn.Size = New-Object System.Drawing.Size($cw, $bh)
    $closeBtn.Location = New-Object System.Drawing.Point($m, $y)
    $closeBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeBtn.FlatAppearance.BorderSize = 0
    $closeBtn.BackColor = $script:theme.PanelCtrl
    $closeBtn.ForeColor = $script:theme.PanelText
    $closeBtn.FlatAppearance.MouseOverBackColor = $script:theme.PanelHover
    $closeBtn.FlatAppearance.MouseDownBackColor = $script:theme.PanelDown
    $closeBtn.Add_Click({ $settings.Close() })
    $settings.Controls.Add($closeBtn)

    # Auto-size form to fit content
    $settings.ClientSize = New-Object System.Drawing.Size(($cw + $m * 2), ($y + $bh + $m))

    # Never taller than the screen: on short displays (1080p at 125% scaling)
    # the panel used to run past the bottom, putting Close out of reach.
    $waHeight = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea.Height
    if ($settings.Height -gt $waHeight) {
        $settings.AutoScroll = $true
        $overflow = $settings.Height - $waHeight
        $settings.ClientSize = New-Object System.Drawing.Size(($cw + $m * 2 + 18), ($settings.ClientSize.Height - $overflow - 8))
    }

    $settings.ShowDialog() | Out-Null
    $settings.Dispose()
}

function Get-BatterySessionSummary {
    [OutputType([string])]
    param()
    # "On battery 2h 13m - used 34%" for the current discharge run, computed
    # from the sparkline history. Empty when charging, or when the run is too
    # short to say anything meaningful.
    if ($null -eq $script:batteryHistory -or $script:batteryHistory.Count -lt 2) { return "" }
    $last = $script:batteryHistory[$script:batteryHistory.Count - 1]
    if ($last.IsCharging) { return "" }
    # Walk back to the start of the continuous discharge run. A run ends at a
    # charge sample OR at a TIME GAP: samples are recorded every refresh tick
    # (1-60s), so a gap of minutes means the app was not running - the machine
    # slept, or this history was restored from config at startup. Without the
    # gap check the walk-back ran straight through an overnight sleep and told
    # the user they had been on battery for nine and a half hours.
    $maxGapMinutes = 15
    $startIdx = $script:batteryHistory.Count - 1
    while ($startIdx -gt 0) {
        $prev = $script:batteryHistory[$startIdx - 1]
        if ($prev.IsCharging) { break }
        $gap = ($script:batteryHistory[$startIdx].Time - $prev.Time).TotalMinutes
        if ($gap -gt $maxGapMinutes) { break }
        $startIdx--
    }
    $first = $script:batteryHistory[$startIdx]
    $spanMin = [int](($last.Time - $first.Time).TotalMinutes)
    $used = $first.Percent - $last.Percent
    if ($spanMin -lt 10 -or $used -lt 1) { return "" }
    return "On battery $(Format-Duration -Minutes $spanMin) - used $used%"
}

function Show-BatteryHealthCard {
    [OutputType([void])]
    param()
    # A screenshot-worthy battery-health card: a circular health ring (the
    # CoconutBattery pattern people share) surfacing wear/capacity that the
    # lean popup no longer shows.
    $info = Get-BatteryInfo
    $gDpi = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $ds = $gDpi.DpiX / 96.0
    $gDpi.Dispose()

    $hasData = (-not $info.NoBattery) -and ($info.DesignCapacity -gt 0) -and ($info.FullChargeCapacity -gt 0)
    $health = 0; $word = ""
    $hcol = [System.Drawing.Color]::FromArgb(45, 212, 100)
    if ($hasData) {
        $health = [int][math]::Round(($info.FullChargeCapacity / $info.DesignCapacity) * 100)
        $health = [math]::Max(0, [math]::Min(100, $health))
        if ($health -ge 80) { $hcol = [System.Drawing.Color]::FromArgb(45, 212, 100); $word = "Good condition" }
        elseif ($health -ge 60) { $hcol = [System.Drawing.Color]::FromArgb(255, 200, 0); $word = "Fair condition" }
        else { $hcol = [System.Drawing.Color]::FromArgb(255, 120, 45); $word = "Worn - consider replacing" }
    }
    # light theme: darken the ring/status color for contrast
    if ($script:theme.PopupBg.GetBrightness() -gt 0.5) {
        $hcol = [System.Drawing.Color]::FromArgb([int]($hcol.R * 0.62), [int]($hcol.G * 0.62), [int]($hcol.B * 0.62))
    }
    $script:hcPct = $health
    $script:hcAnimPct = [double]$health   # ring sweep animates this 0 -> health
    $script:hcColor = $hcol
    $script:hcHasData = $hasData
    $script:hcDs = $ds

    $sessionText = Get-BatterySessionSummary
    $fw = [int](300 * $ds)
    $fh = if ($hasData) {
        # Extra row when there's a current-session line to show
        if ($sessionText) { [int](356 * $ds) } else { [int](332 * $ds) }
    } else { [int](232 * $ds) }

    $card = New-Object System.Windows.Forms.Form
    $card.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $card.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $card.ShowInTaskbar = $false
    $card.TopMost = $true
    $card.BackColor = $script:theme.PopupBg
    $card.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $card.KeyPreview = $true
    $card.ClientSize = New-Object System.Drawing.Size($fw, $fh)
    Enable-DoubleBuffering -Form $card
    # Native rounded corners + shadow (Region-clip fallback on Win10)
    Set-NativeRoundedCorners -Form $card -FallbackRadius 11

    $card.Add_Paint({
            param($sender, $e)
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            $dds = $script:hcDs
            # rounded border
            $rd2 = 24
            $bw = $sender.Width - 1; $bh = $sender.Height - 1
            $bp = New-RoundedRectPath -Right ($bw - $rd2) -Bottom ($bh - $rd2) -Diameter $rd2
            $bpen = New-Object System.Drawing.Pen($script:theme.Border, 1)
            $g.DrawPath($bpen, $bp); $bpen.Dispose(); $bp.Dispose()
            if (-not $script:hcHasData) { return }
            # health ring
            $ringD = [int](144 * $dds); $thick = [int](14 * $dds)
            $ringX = [int](($sender.Width - $ringD) / 2); $ringY = [int](58 * $dds)
            $inset = [int]($thick / 2) + 1
            $rect = New-Object System.Drawing.Rectangle(($ringX + $inset), ($ringY + $inset), ($ringD - $inset * 2), ($ringD - $inset * 2))
            $tpen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(52, 52, 60), $thick)
            $tpen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $tpen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $g.DrawArc($tpen, $rect, -90, 359.9); $tpen.Dispose()
            # Sweep + center number follow the eased animation value
            $sweep = ($script:hcAnimPct / 100.0) * 360.0
            if ($sweep -gt 0.5) {
                $hpen = New-Object System.Drawing.Pen($script:hcColor, $thick)
                $hpen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $hpen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                $g.DrawArc($hpen, $rect, -90, $sweep); $hpen.Dispose()
            }
            # center: big % + HEALTH
            $fmt = New-Object System.Drawing.StringFormat
            $fmt.Alignment = [System.Drawing.StringAlignment]::Center
            $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center   # y = vertical center of text
            $cx = [single]($ringX + $ringD / 2)
            $cy = $ringY + $ringD / 2
            $pctFont = New-Object System.Drawing.Font("Segoe UI Semibold", 26, [System.Drawing.FontStyle]::Bold)
            $pctBrush = New-Object System.Drawing.SolidBrush($script:theme.TextPrimary)
            $g.DrawString(("{0}%" -f [int][math]::Round($script:hcAnimPct)), $pctFont, $pctBrush, $cx, ([single]($cy - 9 * $dds)), $fmt)
            $pctFont.Dispose(); $pctBrush.Dispose()
            $lblFont = New-Object System.Drawing.Font("Segoe UI", 8)
            $lblBrush = New-Object System.Drawing.SolidBrush($script:theme.TextDim)
            $g.DrawString("HEALTH", $lblFont, $lblBrush, $cx, ([single]($cy + 24 * $dds)), $fmt)
            $lblFont.Dispose(); $lblBrush.Dispose(); $fmt.Dispose()
        })

    # NOTE ON DPI: font sizes here are POINTS and must be passed raw. GDI+
    # already converts points to pixels against the system DPI (the process is
    # SetProcessDPIAware), so multiplying the point size by $ds scaled them
    # twice - at 150% every label rendered about 2.25x its intended size and
    # was sliced in half by its own box; at 200% the health percentage
    # overflowed the ring and the session line lost its trailing "%".
    # Box geometry, by contrast, IS in pixels and DOES need the * $ds.
    $fontsToDispose = @()
    function Add-CenterLabel {
        [OutputType([System.Windows.Forms.Label])]
        param(
            [string]$Text,
            [int]$YPos,
            [double]$FontSize,
            [bool]$Bold,
            [System.Drawing.Color]$Color
        )
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Text
        $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
        $fn = if ($Bold) { "Segoe UI Semibold" } else { "Segoe UI" }
        $lbl.Font = New-Object System.Drawing.Font($fn, $FontSize, $style)
        $lbl.ForeColor = $Color
        $lbl.AutoSize = $false
        $lbl.Size = New-Object System.Drawing.Size($fw, [int](($FontSize + 12) * $ds))
        $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $lbl.Location = New-Object System.Drawing.Point(0, [int]($YPos * $ds))
        $card.Controls.Add($lbl)
        return $lbl
    }

    $null = Add-CenterLabel -Text "Battery Health" -YPos 22 -FontSize 11 -Bold $true -Color $script:theme.TextPrimary
    if ($hasData) {
        $fontsToDispose += (Add-CenterLabel -Text $word -YPos 214 -FontSize 11 -Bold $true -Color $hcol).Font
        $fullTxt = "{0:N0} mWh of {1:N0}" -f $info.FullChargeCapacity, $info.DesignCapacity
        $fontsToDispose += (Add-CenterLabel -Text $fullTxt -YPos 250 -FontSize 8.5 -Bold $false -Color $script:theme.TextLight).Font
        $wearTxt = "{0:N1}% wear" -f $info.BatteryWearPercent
        $fontsToDispose += (Add-CenterLabel -Text $wearTxt -YPos 274 -FontSize 8.5 -Bold $false -Color $script:theme.TextDim).Font
        if ($sessionText) {
            $fontsToDispose += (Add-CenterLabel -Text $sessionText -YPos 300 -FontSize 8.5 -Bold $false -Color $script:theme.TextLight).Font
        }
    } else {
        $glyph = Add-CenterLabel -Text ([string][char]0x26A1) -YPos 60 -FontSize 26 -Bold $false -Color ([System.Drawing.Color]::FromArgb(45, 212, 100))
        # Add-CenterLabel already built a "Segoe UI" font for this label; the
        # symbol face replaces it, so the original has to be disposed here or
        # it leaks one font handle per Battery Health open on a desktop.
        $fontsToDispose += $glyph.Font
        $glyph.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 26, [System.Drawing.FontStyle]::Regular)
        $fontsToDispose += $glyph.Font
        $fontsToDispose += (Add-CenterLabel -Text "No battery to report on" -YPos 120 -FontSize 11 -Bold $true -Color $script:theme.TextPrimary).Font
        $fontsToDispose += (Add-CenterLabel -Text "This PC is running on AC power." -YPos 150 -FontSize 8.5 -Bold $false -Color $script:theme.TextDim).Font
    }

    # (corner rounding handled by Set-NativeRoundedCorners above)

    $card.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $card.Close() } })
    $card.Add_Deactivate({ $card.Close() })
    $card.Add_Click({ $card.Close() })

    # Ring sweep: 0 -> health over 650ms (ease-out), the center number counts
    # up with it. Plain scriptblock + $script: state on purpose - a closure's
    # $script: writes land in the closure module, invisible to the paint
    # handler (see the GetNewClosure gotcha). ShowDialog pumps the timer.
    if ($hasData -and $script:animOK) {
        $script:hcAnimPct = 0.0
        $script:hcAnimStart = Get-Date
        $script:hcCard = $card
        $script:hcAnimTimer = New-Object System.Windows.Forms.Timer
        $script:hcAnimTimer.Interval = 16
        $script:hcAnimTimer.Add_Tick({
                if ($null -eq $script:hcCard -or $script:hcCard.IsDisposed) {
                    $script:hcAnimTimer.Stop(); return
                }
                $t = [math]::Min(1.0, ((Get-Date) - $script:hcAnimStart).TotalMilliseconds / 650.0)
                $eased = 1.0 - [math]::Pow(1.0 - $t, 3)
                $script:hcAnimPct = $script:hcPct * $eased
                $script:hcCard.Invalidate()
                if ($t -ge 1.0) {
                    $script:hcAnimPct = [double]$script:hcPct
                    $script:hcCard.Invalidate()
                    $script:hcAnimTimer.Stop()
                }
            })
        $script:hcAnimTimer.Start()
    }

    $card.ShowDialog() | Out-Null
    if ($null -ne $script:hcAnimTimer) {
        $script:hcAnimTimer.Stop(); $script:hcAnimTimer.Dispose(); $script:hcAnimTimer = $null
    }
    $script:hcCard = $null
    # Two passes with deliberate overlap: $fontsToDispose catches fonts no
    # control still references (the glyph label's replaced original), and the
    # control sweep catches the rest. Font.Dispose() is idempotent, so a font
    # in both lists is disposed safely twice.
    foreach ($f in $fontsToDispose) { if ($null -ne $f) { $f.Dispose() } }
    foreach ($ctrl in $card.Controls) { if ($null -ne $ctrl.Font) { $ctrl.Font.Dispose() } }
    $card.Dispose()
}

function Show-AboutDialog {
    [OutputType([void])]
    param()
    $about = New-Object System.Windows.Forms.Form
    $about.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $about.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $about.ShowInTaskbar = $false
    $about.TopMost = $true
    $about.BackColor = $script:theme.PopupBg
    $about.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $about.KeyPreview = $true
    Enable-DoubleBuffering -Form $about

    # Native rounded corners + shadow (Region-clip fallback on Win10)
    Set-NativeRoundedCorners -Form $about -FallbackRadius 10

    # Rounded border paint
    $about.Add_Paint({
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
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $script:theme.TextPrimary
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point($m, $y)
    $about.Controls.Add($titleLabel)
    $y += [int](30 * $ds)

    # Version
    $versionLabel = New-Object System.Windows.Forms.Label
    $versionLabel.Text = "Version $script:appVersion"
    $versionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $versionLabel.ForeColor = $script:theme.TextDim
    $versionLabel.AutoSize = $true
    $versionLabel.Location = New-Object System.Drawing.Point($m, $y)
    $about.Controls.Add($versionLabel)
    $y += [int](24 * $ds)

    # Description
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Windows battery monitor with floating pill"
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $descLabel.ForeColor = $script:theme.TextLight
    $descLabel.AutoSize = $true
    $descLabel.MaximumSize = New-Object System.Drawing.Size(($fw - $m * 2), 0)
    $descLabel.Location = New-Object System.Drawing.Point($m, $y)
    $about.Controls.Add($descLabel)
    $y += [int](30 * $ds)

    # Website link
    $siteLink = New-Object System.Windows.Forms.LinkLabel
    $siteLink.Text = "batterypill.com"
    $siteLink.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    # Link colors adapt: About follows the theme, so light bg needs darker links for contrast
    $aboutIsLight = ($script:theme.PopupBg.R -gt 128)
    $siteLink.LinkColor = if ($aboutIsLight) { [System.Drawing.Color]::FromArgb(0, 102, 204) } else { [System.Drawing.Color]::FromArgb(100, 149, 237) }
    $siteLink.ActiveLinkColor = if ($aboutIsLight) { [System.Drawing.Color]::FromArgb(0, 82, 164) } else { [System.Drawing.Color]::FromArgb(130, 170, 255) }
    $siteLink.AutoSize = $true
    $siteLink.Location = New-Object System.Drawing.Point($m, $y)
    $siteLink.Add_LinkClicked({ [void](Open-ExternalLink -Url "https://batterypill.com") })
    $about.Controls.Add($siteLink)
    $y += [int](22 * $ds)

    # Donate link
    $donateLink = New-Object System.Windows.Forms.LinkLabel
    $donateLink.Text = "Buy me a coffee"
    $donateLink.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $donateLink.LinkColor = if ($aboutIsLight) { [System.Drawing.Color]::FromArgb(153, 102, 0) } else { [System.Drawing.Color]::FromArgb(255, 200, 60) }
    $donateLink.ActiveLinkColor = if ($aboutIsLight) { [System.Drawing.Color]::FromArgb(122, 82, 0) } else { [System.Drawing.Color]::FromArgb(255, 220, 100) }
    $donateLink.AutoSize = $true
    $donateLink.Location = New-Object System.Drawing.Point($m, $y)
    $donateLink.Add_LinkClicked({ [void](Open-ExternalLink -Url "https://buymeacoffee.com/nobackhand") })
    $about.Controls.Add($donateLink)
    $y += [int](34 * $ds)

    # Footer
    $footerLabel = New-Object System.Windows.Forms.Label
    $footerLabel.Text = "Built with PowerShell + WinForms"
    $footerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7)
    $footerLabel.ForeColor = $script:theme.TextMuted
    $footerLabel.AutoSize = $true
    $footerLabel.Location = New-Object System.Drawing.Point($m, $y)
    $about.Controls.Add($footerLabel)
    $y += [int](20 * $ds)

    # Set form size
    $fh = $y + $m
    $about.ClientSize = New-Object System.Drawing.Size($fw, $fh)

    # (corner rounding handled by Set-NativeRoundedCorners above)

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

