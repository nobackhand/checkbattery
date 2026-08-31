# tests\PillGeometry.Tests.ps1
#
# Regression suite for Get-PillDimensions.
#
# The pill is a fixed-size window with no wrapping and no ellipsis: whatever
# does not fit is silently cut off. Its box is measured in PIXELS while its
# text is measured in POINTS, and only one of those follows the display
# scale automatically - so the two have to be kept in step deliberately.
# These cases pin that, including a direct measurement of the app's own font
# against the box it is drawn into.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Get-PillDimensions')

Add-Type -AssemblyName System.Drawing

Write-Host 'PillGeometry.Tests.ps1'

function Set-PillConfig {
    [OutputType([void])]
    param([string]$PillSize = 'normal', [string]$DisplayMode = 'time')
    $script:config = @{ PillSize = $PillSize; DisplayMode = $DisplayMode }
}

Test-Case 'at 100% the shipped pixel sizes are unchanged' {
    Set-PillConfig
    $d = Get-PillDimensions -DpiScale 1.0
    Assert-Equal 108 $d.Width
    Assert-Equal 34 $d.Height
    Set-PillConfig -PillSize 'compact'
    $c = Get-PillDimensions -DpiScale 1.0
    Assert-Equal 80 $c.Width
    Assert-Equal 28 $c.Height
    Set-PillConfig -PillSize 'expanded'
    $e = Get-PillDimensions -DpiScale 1.0
    Assert-Equal 140 $e.Width
    Assert-Equal 42 $e.Height
}

Test-Case 'the "both" display mode is taller, as it has two lines to fit' {
    Set-PillConfig -DisplayMode 'both'
    $d = Get-PillDimensions -DpiScale 1.0
    Assert-Equal 42 $d.Height
    if ($d.FontSize2 -le 0) { throw 'the second line has no font size' }
}

Test-Case 'the box scales with the display, so the text keeps its room' {
    Set-PillConfig
    $d = Get-PillDimensions -DpiScale 2.0
    Assert-Equal 216 $d.Width
    Assert-Equal 68 $d.Height
}

Test-Case 'font sizes stay in points and are NOT scaled twice' {
    # GDI+ converts points to pixels against the system DPI already.
    Set-PillConfig
    $at100 = Get-PillDimensions -DpiScale 1.0
    $at200 = Get-PillDimensions -DpiScale 2.0
    Assert-Equal $at100.FontSize $at200.FontSize
}

Test-Case 'the longest realistic reading fits the pill at every common scale' {
    # The failing case this pins: at 200%, "12h 45m" needed 116px of a fixed
    # 108px pill and rendered as "12h 45" - the widget dropping a character
    # off the one number it exists to show.
    $samples = @('12h 45m', '100%', '3h 8m', '--')
    foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
        $dpi = [int](96 * $scale)
        Set-PillConfig
        $d = Get-PillDimensions -DpiScale $scale
        $bmp = New-Object System.Drawing.Bitmap(400, 80)
        try {
            $bmp.SetResolution($dpi, $dpi)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $f = New-Object System.Drawing.Font('Segoe UI Semibold', $d.FontSize,
                [System.Drawing.FontStyle]::Bold)
            try {
                foreach ($s in $samples) {
                    $w = $g.MeasureString($s, $f).Width
                    if ($w -gt $d.Width) {
                        throw ("'{0}' needs {1:N0}px at {2}% but the pill is only {3}px" -f
                            $s, $w, [int]($scale * 100), $d.Width)
                    }
                }
            } finally { $f.Dispose(); $g.Dispose() }
        } finally { $bmp.Dispose() }
    }
}

exit (Complete-Tests)
