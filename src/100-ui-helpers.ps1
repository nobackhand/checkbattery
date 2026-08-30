# ============================================================
# HELPER — DOUBLE BUFFERING
# ============================================================

function Enable-DoubleBuffering {
    [OutputType([void])]
    param([System.Windows.Forms.Form]$Form)
    $Form.GetType().GetProperty("DoubleBuffered",
        [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    ).SetValue($Form, $true, $null)
}

function Set-NativeRoundedCorners {
    [OutputType([void])]
    param(
        [System.Windows.Forms.Form]$Form,
        # Radius for the Region fallback when DWM rounding is unavailable (Win10)
        [int]$FallbackRadius = 10
    )
    # Native window dressing for borderless popups/cards. Win11: real DWM
    # rounded corners - antialiased edges plus the system's own window shadow,
    # exactly what native flyouts get. Win10 (or DWM failure): CS_DROPSHADOW +
    # the old Region clip. Registered on HandleCreated so it applies whenever
    # the handle materializes, after the caller has finished sizing the form.
    # GetNewClosure is safe here: the handler touches only the captured
    # $FallbackRadius local, never $script: state (see the scoping gotcha).
    $Form.Add_HandleCreated({
            param($sender, $e)
            $ok = $false
            try { $ok = [Win32Icon]::TryRoundCorners($sender.Handle) } catch { $ok = $false }
            if (-not $ok) {
                [Win32Icon]::EnableDropShadow($sender.Handle)
                $d = $FallbackRadius * 2
                $p = New-RoundedRectPath -Right ($sender.Width - $d - 1) -Bottom ($sender.Height - $d - 1) -Diameter $d
                $oldRegion = $sender.Region
                $sender.Region = New-Object System.Drawing.Region($p)
                if ($null -ne $oldRegion) { $oldRegion.Dispose() }
                $p.Dispose()
            }
        }.GetNewClosure())
}

$script:darkMenuRenderer = $null

function Set-RoundedMenuCorners {
    # Round a drop-down's window corners on open. Registered once per drop-down
    # (guarded by Tag) because Set-DarkMenuItem re-runs on every Power Plan
    # rebuild and stacking Opened handlers would leak.
    [OutputType([void])]
    param([System.Windows.Forms.ToolStripDropDown]$DropDown)
    if ($DropDown.Tag -eq 'pill-rounded') { return }
    $DropDown.Tag = 'pill-rounded'
    $DropDown.Add_Opened({
            param($sender, $e)
            $r = 8; $d = $r * 2
            $p = New-RoundedRectPath -Right ($sender.Width - $d - 1) -Bottom ($sender.Height - $d - 1) -Diameter $d
            # Region is IDisposable and this runs on every open - free the old one
            $oldRegion = $sender.Region
            $sender.Region = New-Object System.Drawing.Region($p)
            if ($null -ne $oldRegion) { $oldRegion.Dispose() }
            $p.Dispose()
        })
}

function Set-DarkMenu {
    # Dark-theme a ContextMenuStrip (and its submenus) to match the app.
    [OutputType([void])]
    param([System.Windows.Forms.ToolStrip]$Menu)
    if ($null -eq $script:darkMenuRenderer) {
        # Accent-tinted rounded selection highlight (see PillMenuRenderer)
        $script:darkMenuRenderer = New-Object PillMenuRenderer(
            (New-Object DarkMenuColorTable),
            [System.Drawing.Color]::FromArgb(45, 212, 100))
    }
    $Menu.Renderer = $script:darkMenuRenderer
    $Menu.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
    $Menu.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
    if ($Menu -is [System.Windows.Forms.ToolStripDropDown]) {
        Set-RoundedMenuCorners -DropDown $Menu
    }
    foreach ($item in $Menu.Items) { Set-DarkMenuItem -Item $item }
}

function Set-DarkMenuItem {
    [OutputType([void])]
    param([System.Windows.Forms.ToolStripItem]$Item)
    if ($Item -is [System.Windows.Forms.ToolStripMenuItem]) {
        $Item.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
        if ($Item.HasDropDownItems) {
            $Item.DropDown.Renderer = $script:darkMenuRenderer
            $Item.DropDown.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
            Set-RoundedMenuCorners -DropDown $Item.DropDown
            foreach ($sub in $Item.DropDownItems) { Set-DarkMenuItem -Item $sub }
        }
    }
}

function New-RoundedRectPath {
    # The one rounded-rectangle primitive - every pill/popup/card region and
    # border in this file is this shape. $Right/$Bottom are the x/y of the
    # right/bottom corner arc boxes (i.e. AddArc's first two args), passed
    # explicitly because the call sites use different inset conventions
    # (-1 for regions vs -2 for cards) that must be preserved exactly.
    # Caller owns disposal.
    [OutputType([System.Drawing.Drawing2D.GraphicsPath])]
    param(
        [double]$X = 0,
        [double]$Y = 0,
        [double]$Right,
        [double]$Bottom,
        [double]$Diameter
    )
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($X, $Y, $Diameter, $Diameter, 180, 90)
    $p.AddArc($Right, $Y, $Diameter, $Diameter, 270, 90)
    $p.AddArc($Right, $Bottom, $Diameter, $Diameter, 0, 90)
    $p.AddArc($X, $Bottom, $Diameter, $Diameter, 90, 90)
    $p.CloseFigure()
    return $p
}

# ============================================================
# CACHED GDI+ BRUSHES/PENS FOR PAINT HANDLER
# ============================================================

$script:pillBgBrush = $null
$script:pillBgHoverBrush = $null
$script:pillTextBrush = $null
$script:pillBorderPen = $null
$script:pillBorderHoverPen = $null

function Initialize-PillBrushes {
    [OutputType([void])]
    param()
    # Dispose old cached objects
    if ($null -ne $script:pillBgBrush) { $script:pillBgBrush.Dispose() }
    if ($null -ne $script:pillBgHoverBrush) { $script:pillBgHoverBrush.Dispose() }
    if ($null -ne $script:pillTextBrush) { $script:pillTextBrush.Dispose() }
    if ($null -ne $script:pillBorderPen) { $script:pillBorderPen.Dispose() }
    if ($null -ne $script:pillBorderHoverPen) { $script:pillBorderHoverPen.Dispose() }
    # Create from current theme colors
    $script:pillBgBrush = New-Object System.Drawing.SolidBrush($script:theme.PillBg)
    # Hover surface: nudge the background 8% toward the text color so the pill
    # visibly "wakes up" under the cursor on both dark and light themes
    $hgB = $script:theme.PillBg; $hgT = $script:theme.TextPrimary
    $script:pillBgHoverBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,
            [int]($hgB.R + ($hgT.R - $hgB.R) * 0.08),
            [int]($hgB.G + ($hgT.G - $hgB.G) * 0.08),
            [int]($hgB.B + ($hgT.B - $hgB.B) * 0.08)))
    $script:pillTextBrush = New-Object System.Drawing.SolidBrush($script:theme.TextPrimary)
    $script:pillBorderPen = New-Object System.Drawing.Pen($script:theme.Border, 1)
    # Hover pen: blend border 50% toward TextPrimary - reads brighter on dark theme
    # and stronger on light theme (a flat brighten washes out on a light background)
    $hb = $script:theme.Border; $ht = $script:theme.TextPrimary
    $script:pillBorderHoverPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,
            [int](($hb.R + $ht.R) / 2), [int](($hb.G + $ht.G) / 2), [int](($hb.B + $ht.B) / 2)), 1)
}

