# tests\TrayIcon.Tests.ps1
#
# The tray icon is on screen all day, next to the clock. Its charging bolt
# was outlined with a 1.6px pen using GDI+'s default MITER join, which
# extends a sharp corner up to 10x the pen width: the bolt's two tips shot a
# dark spike out above and below the battery, onto the taskbar. These render
# the real icon and check what is actually drawn.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'New-BatteryIcon', 'New-RoundedRectPath', 'Get-AccentColor')
Add-Type -AssemblyName System.Drawing

Write-Host 'TrayIcon.Tests.ps1'

$script:config = @{ AccentColorIndex = 0 }
$script:accentPresets = @([System.Drawing.Color]::FromArgb(45, 212, 100))

function Get-StrayPixelCount {
    # Visible pixels two or more rows clear of the battery body. The body
    # spans rows 4-12 of the 16px icon; the bolt's own tips reach one row
    # past it by design (rows 3 and 13). The miter spike ran through rows
    # 0-2 and 14-15.
    [OutputType([int])]
    param([int]$Percent, [string]$Status)
    $r = New-BatteryIcon -Percent $Percent -Status $Status
    $b = $r.Icon.ToBitmap()
    $n = 0
    for ($y = 0; $y -lt $b.Height; $y++) {
        if ($y -ge 3 -and $y -le 13) { continue }
        for ($x = 0; $x -lt $b.Width; $x++) { if ($b.GetPixel($x, $y).A -gt 40) { $n++ } }
    }
    $b.Dispose(); $r.Icon.Dispose()
    return $n
}

Test-Case 'tray icon: the charging bolt stays inside the battery' {
    Assert-Equal 0 (Get-StrayPixelCount -Percent 47 -Status 'Charging')
    Assert-Equal 0 (Get-StrayPixelCount -Percent 5 -Status 'Charging')
}

Test-Case 'tray icon: plain states draw nothing outside the battery either' {
    foreach ($s in @(@(72, 'Discharging'), @(8, 'Critical'), @(100, 'Fully Charged'))) {
        Assert-Equal 0 (Get-StrayPixelCount -Percent $s[0] -Status $s[1])
    }
}

Test-Case 'tray icon: charging still shows a bolt (white pixels inside the body)' {
    $r = New-BatteryIcon -Percent 47 -Status 'Charging'
    $b = $r.Icon.ToBitmap()
    $white = 0
    for ($y = 4; $y -le 11; $y++) { for ($x = 0; $x -lt 16; $x++) { $c = $b.GetPixel($x, $y); if ($c.A -gt 200 -and $c.R -gt 230 -and $c.G -gt 230 -and $c.B -gt 230) { $white++ } } }
    $b.Dispose(); $r.Icon.Dispose()
    Assert-True ($white -ge 3) "only $white white bolt pixels"
}

exit (Complete-Tests)
