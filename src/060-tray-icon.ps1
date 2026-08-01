# ============================================================
# DYNAMIC TRAY ICON
# ============================================================

function New-BatteryIcon {
    [OutputType([hashtable])]
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
    $radius = 4   # capsule: half the pill height, matching the widget

    # Create rounded rectangle path
    $d = $radius * 2
    $path = New-RoundedRectPath -X $pillX -Y $pillY -Right ($pillX + $pillW - $d) -Bottom ($pillY + $pillH - $d) -Diameter $d

    $isCharging = ($Status -eq "Charging")
    # Critical = the whole pill should scream "low" even though the charge bar
    # is a tiny sliver. Previously a 10% icon was a near-invisible dark pill.
    $isCritical = ($Percent -ge 0 -and $Percent -le 10 -and -not $isCharging)

    # Empty body: faint red when critical, otherwise a mid-dark that stays
    # visible against a dark taskbar (the old 24,24,28 vanished into it)
    $bodyColor = if ($isCritical) { [System.Drawing.Color]::FromArgb(72, 26, 28) } else { [System.Drawing.Color]::FromArgb(44, 44, 50) }
    $bgBrush = New-Object System.Drawing.SolidBrush($bodyColor)
    $g.FillPath($bgBrush, $path)
    $bgBrush.Dispose()

    # Charge fill (from left, proportional) - now vivid full-opacity
    $pct = [math]::Max(0, [math]::Min(100, $Percent))
    $fillWidth = [math]::Max(0, [int](($pct / 100) * $pillW))
    if ($fillWidth -gt 0) {
        $oldClip = $g.Clip
        $g.SetClip($path)
        $accent = Get-AccentColor -Percent $Percent -IsCharging $isCharging
        $fillBrush = New-Object System.Drawing.SolidBrush($accent)
        $g.FillRectangle($fillBrush, $pillX, $pillY, $fillWidth, $pillH)
        $fillBrush.Dispose()
        $g.Clip = $oldClip
    }

    # Charging bolt overlay so charging never looks like a plain full battery
    if ($isCharging) {
        [System.Drawing.PointF[]]$bolt = @(
            (New-Object System.Drawing.PointF(9.7, 3.8)),
            (New-Object System.Drawing.PointF(5.2, 8.9)),
            (New-Object System.Drawing.PointF(7.8, 8.9)),
            (New-Object System.Drawing.PointF(6.5, 12.2)),
            (New-Object System.Drawing.PointF(10.8, 6.8)),
            (New-Object System.Drawing.PointF(8.4, 6.8))
        )
        $boltPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(170, 0, 0, 0), 1.6)  # dark edge for contrast on amber
        $g.DrawPolygon($boltPen, $bolt); $boltPen.Dispose()
        $boltBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $g.FillPolygon($boltBrush, $bolt); $boltBrush.Dispose()
    }

    # Outline: red when critical (visible even nearly empty), otherwise a bright
    # neutral that survives both light and dark taskbars (old 80,80,86 did not)
    $outlineColor = if ($isCritical) { [System.Drawing.Color]::FromArgb(255, 80, 80) } else { [System.Drawing.Color]::FromArgb(150, 150, 160) }
    $borderPen = New-Object System.Drawing.Pen($outlineColor, 1)
    $g.DrawPath($borderPen, $path)
    $borderPen.Dispose()

    $path.Dispose()
    $g.Dispose()

    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $bmp.Dispose()

    return @{ Icon = $icon; Handle = $hIcon }
}

