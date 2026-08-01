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

$script:darkMenuRenderer = $null

function Set-DarkMenu {
    # Dark-theme a ContextMenuStrip (and its submenus) to match the app.
    [OutputType([void])]
    param([System.Windows.Forms.ToolStrip]$Menu)
    if ($null -eq $script:darkMenuRenderer) {
        $script:darkMenuRenderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object DarkMenuColorTable))
    }
    $Menu.Renderer = $script:darkMenuRenderer
    $Menu.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
    $Menu.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
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
$script:pillTextBrush = $null
$script:pillBorderPen = $null
$script:pillBorderHoverPen = $null

function Initialize-PillBrushes {
    [OutputType([void])]
    param()
    # Dispose old cached objects
    if ($null -ne $script:pillBgBrush) { $script:pillBgBrush.Dispose() }
    if ($null -ne $script:pillTextBrush) { $script:pillTextBrush.Dispose() }
    if ($null -ne $script:pillBorderPen) { $script:pillBorderPen.Dispose() }
    if ($null -ne $script:pillBorderHoverPen) { $script:pillBorderHoverPen.Dispose() }
    # Create from current theme colors
    $script:pillBgBrush = New-Object System.Drawing.SolidBrush($script:theme.PillBg)
    $script:pillTextBrush = New-Object System.Drawing.SolidBrush($script:theme.TextPrimary)
    $script:pillBorderPen = New-Object System.Drawing.Pen($script:theme.Border, 1)
    # Hover pen: blend border 50% toward TextPrimary - reads brighter on dark theme
    # and stronger on light theme (a flat brighten washes out on a light background)
    $hb = $script:theme.Border; $ht = $script:theme.TextPrimary
    $script:pillBorderHoverPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,
            [int](($hb.R + $ht.R) / 2), [int](($hb.G + $ht.G) / 2), [int](($hb.B + $ht.B) / 2)), 1)
}

