# tests\Appearance.Tests.ps1
#
# Tests for the drawing helpers in BatteryWidget.ps1 that decide what the pill
# looks like. Get-AccentColor drives every fill/tray colour; New-RoundedRectPath
# is the single rounded-rectangle primitive behind every region and card.

Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Get-AccentColor', 'New-RoundedRectPath')

Write-Host 'Appearance.Tests.ps1'

function Assert-Color {
    param([int]$R, [int]$G, [int]$B, $Actual)
    Assert-Equal ("{0},{1},{2}" -f $R, $G, $B) ("{0},{1},{2}" -f $Actual.R, $Actual.G, $Actual.B)
}

# ---- Get-AccentColor ----

Test-Case 'no battery (-1) is neutral slate, not critical red' {
    Assert-Color 120 130 140 (Get-AccentColor -Percent -1 -IsCharging $false)
}

Test-Case 'charging is yellow at any level' {
    Assert-Color 255 200 0 (Get-AccentColor -Percent 5  -IsCharging $true)
    Assert-Color 255 200 0 (Get-AccentColor -Percent 95 -IsCharging $true)
}

Test-Case 'critical (<=10%) is red' {
    Assert-Color 255 70 70 (Get-AccentColor -Percent 10 -IsCharging $false)
    Assert-Color 255 70 70 (Get-AccentColor -Percent 1  -IsCharging $false)
}

Test-Case 'low (11-20%) is orange' {
    Assert-Color 255 140 0 (Get-AccentColor -Percent 11 -IsCharging $false)
    Assert-Color 255 140 0 (Get-AccentColor -Percent 20 -IsCharging $false)
}

Test-Case 'medium (21-50%) is yellow' {
    Assert-Color 255 200 0 (Get-AccentColor -Percent 21 -IsCharging $false)
    Assert-Color 255 200 0 (Get-AccentColor -Percent 50 -IsCharging $false)
}

# ---- New-RoundedRectPath ----

Test-Case 'New-RoundedRectPath returns a closed four-arc path' {
    $p = New-RoundedRectPath -X 0 -Y 0 -Right 100 -Bottom 30 -Diameter 8
    try {
        Assert-True ($p.PointCount -gt 0) 'path has no points'
        $b = $p.GetBounds()
        Assert-Equal 0 ([math]::Round($b.X))
        Assert-Equal 0 ([math]::Round($b.Y))
        Assert-Equal 108 ([math]::Round($b.Right))
        Assert-Equal 38  ([math]::Round($b.Bottom))
    } finally { $p.Dispose() }
}

Test-Case 'New-RoundedRectPath honours a non-zero origin' {
    $p = New-RoundedRectPath -X 5 -Y 7 -Right 45 -Bottom 27 -Diameter 6
    try {
        $b = $p.GetBounds()
        Assert-Equal 5 ([math]::Round($b.X))
        Assert-Equal 7 ([math]::Round($b.Y))
        Assert-Equal 51 ([math]::Round($b.Right))
        Assert-Equal 33 ([math]::Round($b.Bottom))
    } finally { $p.Dispose() }
}

exit (Complete-Tests)
