# tests\Sparkline.Tests.ps1
#
# The popup sparkline's geometry (Get-SparklinePoints) and charging bands
# (Get-ChargingRuns). Both used to be computed inline in the paint handler,
# one New-Object per sample: on a full two-hour history (2400 samples) a
# paint cost ~150-450ms, and the graph repaints on every refresh tick, every
# frame of its draw-in and every mouse move while scrubbing. Now the line is
# thinned to about one point per pixel column and the paint caches both per
# history change. These pin the shape of what is drawn.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Get-SparklinePoints', 'Get-ChargingRuns')
Add-Type -AssemblyName System.Drawing

Write-Host 'Sparkline.Tests.ps1'

function New-History {
    [OutputType([System.Collections.ArrayList])]
    param([int]$Count, [int[]]$ChargingFrom = @(), [int[]]$ChargingTo = @())
    $h = New-Object System.Collections.ArrayList
    $t0 = [datetime]'2026-10-09T01:00:00'
    for ($i = 0; $i -lt $Count; $i++) {
        $charging = $false
        for ($r = 0; $r -lt $ChargingFrom.Count; $r++) {
            if ($i -ge $ChargingFrom[$r] -and $i -le $ChargingTo[$r]) { $charging = $true }
        }
        $null = $h.Add(@{ Time = $t0.AddSeconds($i * 3); Percent = [int](95 - $i * 60 / [math]::Max(1, $Count)); IsCharging = $charging })
    }
    return , $h
}

Test-Case 'sparkline: a full two-hour history is thinned to about one point per pixel column' {
    $pts = Get-SparklinePoints -History (New-History -Count 2400) -Width 380 -Height 40
    Assert-True ($pts.Length -ge 380 -and $pts.Length -le 402) "got $($pts.Length) points"
}

Test-Case 'sparkline: the first and last samples are always on the line' {
    $h = New-History -Count 2399
    $pts = Get-SparklinePoints -History $h -Width 380 -Height 40
    Assert-Equal 0.0 ([double]$pts[0].X)
    Assert-Equal 380.0 ([double]$pts[$pts.Length - 1].X)
    $lastY = 40 - (($h[2398].Percent / 100.0) * 36) - 2
    Assert-True ([math]::Abs($pts[$pts.Length - 1].Y - $lastY) -lt 0.01) "last Y $($pts[$pts.Length - 1].Y) vs $lastY"
}

Test-Case 'sparkline: a short history keeps every sample' {
    $pts = Get-SparklinePoints -History (New-History -Count 120) -Width 380 -Height 40
    Assert-Equal 120 $pts.Length
}

Test-Case 'sparkline: percent maps to height as the paint always did (100% top, 0% bottom)' {
    $h = New-Object System.Collections.ArrayList
    $null = $h.Add(@{ Time = (Get-Date); Percent = 100; IsCharging = $false })
    $null = $h.Add(@{ Time = (Get-Date); Percent = 0; IsCharging = $false })
    $pts = Get-SparklinePoints -History $h -Width 380 -Height 40
    Assert-Equal 2.0 ([double]$pts[0].Y)
    Assert-Equal 38.0 ([double]$pts[1].Y)
}

Test-Case 'sparkline: under two samples there is no line' {
    Assert-Equal 0 (Get-SparklinePoints -History (New-History -Count 1) -Width 380 -Height 40).Length
    Assert-Equal 0 (Get-SparklinePoints -History $null -Width 380 -Height 40).Length
}

Test-Case 'charging runs: contiguous stretches, including one still running at the end' {
    $runs = Get-ChargingRuns -History (New-History -Count 100 -ChargingFrom 10, 90 -ChargingTo 19, 99)
    Assert-Equal 2 $runs.Count
    Assert-Equal @(10, 19) $runs[0]
    Assert-Equal @(90, 99) $runs[1]
}

Test-Case 'charging runs: a single run still comes back as a list of pairs' {
    # The paint does `foreach ($run in $runs)`; a lone pair unrolled into two
    # integers would draw two bogus bands.
    $runs = Get-ChargingRuns -History (New-History -Count 50 -ChargingFrom 5 -ChargingTo 9)
    Assert-Equal 1 $runs.Count
    Assert-Equal @(5, 9) $runs[0]
}

Test-Case 'charging runs: none when the history never charged' {
    Assert-Equal 0 (Get-ChargingRuns -History (New-History -Count 50)).Count
    Assert-Equal 0 (Get-ChargingRuns -History $null).Count
}

exit (Complete-Tests)
