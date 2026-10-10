# tests\HealthRing.Tests.ps1
#
# The Battery Health ring's unfilled track used one dark grey in both themes:
# on the light card the missing part of the ring was a near-black slash. The
# track should read as a quiet groove against the card - visible, not loud -
# in either theme. (Card backgrounds are Set-Theme's PopupBg.)

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Get-HealthRingTrackColor')
Add-Type -AssemblyName System.Drawing

Write-Host 'HealthRing.Tests.ps1'

function Get-Luma {
    [OutputType([double])]
    param([System.Drawing.Color]$C)
    return ($C.R * 0.299) + ($C.G * 0.587) + ($C.B * 0.114)
}

$cards = @{
    dark  = [System.Drawing.Color]::FromArgb(26, 26, 30)
    light = [System.Drawing.Color]::FromArgb(248, 248, 252)
}

foreach ($theme in 'dark', 'light') {
    Test-Case "health ring: the track is a quiet groove on the $theme card" {
        $track = Get-HealthRingTrackColor -IsDark ($theme -eq 'dark')
        $diff = [math]::Abs((Get-Luma $track) - (Get-Luma $cards[$theme]))
        Assert-True ($diff -ge 15 -and $diff -le 60) ("track {0} on the {1} card: luma difference {2:N0} (want 15-60)" -f $track.Name, $theme, $diff)
    }
}

exit (Complete-Tests)
