# tests\SwatchRing.Tests.ps1
#
# The selected accent swatch in Settings gets a ring so you can see which
# accent is active. Its colour was chosen from the swatch alone, assuming the
# dark panel - on the light panel the ring was near-white on near-white
# (240,240,245 on 246,246,250) and the selection was invisible.
# Get-SwatchRingColor must contrast with the panel in both themes, for every
# preset.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Get-SwatchRingColor')
Add-Type -AssemblyName System.Drawing

Write-Host 'SwatchRing.Tests.ps1'

# The eight presets (src\050-colors.ps1) and the two panel backgrounds
# (Set-Theme's PanelBg)
$presets = @(
    @(45, 212, 100), @(60, 140, 255), @(160, 100, 255), @(0, 210, 210),
    @(255, 105, 180), @(0, 180, 160), @(255, 160, 40), @(220, 220, 230))
$panels = @{ dark = @(32, 32, 36); light = @(246, 246, 250) }

function Get-Luma {
    [OutputType([double])]
    param([int[]]$Rgb)
    return ($Rgb[0] * 0.299) + ($Rgb[1] * 0.587) + ($Rgb[2] * 0.114)
}

foreach ($theme in 'dark', 'light') {
    Test-Case "swatch ring: stands out against the $theme panel for every preset" {
        $bg = Get-Luma $panels[$theme]
        foreach ($p in $presets) {
            $c = [System.Drawing.Color]::FromArgb($p[0], $p[1], $p[2])
            $ring = Get-SwatchRingColor -Swatch $c -IsDark ($theme -eq 'dark')
            $contrast = [math]::Abs((Get-Luma @($ring.R, $ring.G, $ring.B)) - $bg)
            Assert-True ($contrast -ge 80) ("ring {0} on the {1} panel: luma contrast only {2:N0} (swatch {3})" -f $ring.Name, $theme, $contrast, ($p -join ','))
        }
    }
}

Test-Case 'swatch ring: on the dark panel the near-white preset gets a grey ring, not white-on-white' {
    $ring = Get-SwatchRingColor -Swatch ([System.Drawing.Color]::FromArgb(220, 220, 230)) -IsDark $true
    Assert-True ((Get-Luma @($ring.R, $ring.G, $ring.B)) -lt 160) "ring $($ring.Name) is too close to the white dot"
}

exit (Complete-Tests)
