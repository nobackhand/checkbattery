# tests\Presentation.Tests.ps1
#
# Regression suite for the presentation layer - the pure functions that turn a
# battery reading into the WORDS the user reads:
#
#     Get-BatteryStateTitle      popup title ("Charging" / "Discharging" / ...)
#     Get-TimeSentence           "3h 8m left - 6:42 PM" / "Fully charged"
#     Get-FunStatusLine          the optional personality line
#     Get-BatterySessionSummary  "On battery 2h 13m - used 34%" (health card)
#
# These shipped with no coverage. They are worth pinning for the same reason
# the estimator is: they are the app's voice, and a wrong sentence is a wrong
# answer even when every number behind it is right.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Get-BatteryStateTitle', 'Get-TimeSentence', 'Get-FunStatusLine',
    'Get-BatterySessionSummary', 'Get-PillText', 'Format-Duration')

Write-Host 'Presentation.Tests.ps1'

# A healthy discharging reading; tests clone and mutate what they need.
function New-Reading {
    [OutputType([hashtable])]
    param(
        [int]$Percent = 72,
        [bool]$IsCharging = $false,
        [bool]$IsFullyCharged = $false,
        [bool]$NoBattery = $false,
        [int]$TimeMinutes = 188,
        [string]$ETA = '6:42 PM',
        # Plugged in but NOT charging and NOT full - a firmware charge cap
        # holding the pack (WMI BatteryStatus 11).
        [bool]$PluggedHolding = $false
    )
    return @{
        Percent        = $Percent
        PercentExact   = [double]$Percent
        IsCharging     = $IsCharging
        IsPluggedIn    = ($IsCharging -or $IsFullyCharged -or $PluggedHolding)
        IsFullyCharged = $IsFullyCharged
        NoBattery      = $NoBattery
        StatusText     = 'Discharging'
        TimeMinutes    = $TimeMinutes
        ETA            = $ETA
    }
}

# ---- Get-BatteryStateTitle ----

Test-Case 'title: discharging is the default state' {
    Assert-Equal 'Discharging' (Get-BatteryStateTitle -BatteryInfo (New-Reading))
}

Test-Case 'title: charging' {
    Assert-Equal 'Charging' (Get-BatteryStateTitle -BatteryInfo (New-Reading -IsCharging $true))
}

Test-Case 'title: fully charged outranks charging' {
    # Windows reports IsCharging alongside IsFullyCharged on some packs; "Fully
    # Charged" is the more useful of the two, so it must win.
    $info = New-Reading -IsCharging $true -IsFullyCharged $true
    Assert-Equal 'Fully Charged' (Get-BatteryStateTitle -BatteryInfo $info)
}

Test-Case 'title: no battery' {
    Assert-Equal 'No Battery' (Get-BatteryStateTitle -BatteryInfo (New-Reading -NoBattery $true))
}

Test-Case 'title: plugged in and holding is not called Discharging' {
    # A charge-capped laptop parks here for hours. Titling it "Discharging"
    # contradicted the popup's own "AC Power (plugged in)" line below it.
    $info = New-Reading -Percent 60 -PluggedHolding $true -TimeMinutes -1 -ETA ''
    Assert-Equal 'Plugged In' (Get-BatteryStateTitle -BatteryInfo $info)
}

# ---- Get-TimeSentence ----

Test-Case 'time sentence: discharging reads "left" with the ETA' {
    Assert-Equal "3h 8m left $([char]0x2014) 6:42 PM" (Get-TimeSentence -BatteryInfo (New-Reading))
}

Test-Case 'time sentence: charging reads "to full"' {
    $info = New-Reading -IsCharging $true -TimeMinutes 63 -ETA '5:10 PM'
    Assert-Equal "1h 3m to full $([char]0x2014) 5:10 PM" (Get-TimeSentence -BatteryInfo $info)
}

Test-Case 'time sentence: no ETA drops the dash instead of trailing it' {
    Assert-Equal '3h 8m left' (Get-TimeSentence -BatteryInfo (New-Reading -ETA ''))
}

Test-Case 'time sentence: fully charged says so, with no time' {
    $info = New-Reading -IsFullyCharged $true -TimeMinutes 0 -ETA ''
    Assert-Equal 'Fully charged' (Get-TimeSentence -BatteryInfo $info)
}

Test-Case 'time sentence: an uncomputed estimate is the placeholder the pulse animates' {
    # The literal string is load-bearing: Update-OpenPopupContent compares
    # against it to decide whether to re-arm the "Estimating..." pulse.
    Assert-Equal 'Estimating...' (Get-TimeSentence -BatteryInfo (New-Reading -TimeMinutes -1))
}

# ---- Get-FunStatusLine ----

Test-Case 'fun line: every ordinary discharge band produces a line' {
    # The whole point of the feature is that the common case speaks. A silent
    # midrange (the v1.2.0 bug) makes the setting look broken.
    foreach ($mins in @(15, 30, 90, 200, 330, 600)) {
        $line = Get-FunStatusLine -BatteryInfo (New-Reading -TimeMinutes $mins)
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw "no fun line for a $mins-minute estimate"
        }
    }
}

Test-Case 'fun line: charging and full states speak too' {
    $charging = Get-FunStatusLine -BatteryInfo (New-Reading -IsCharging $true -TimeMinutes 63)
    if ([string]::IsNullOrWhiteSpace($charging)) { throw 'no fun line while charging' }
    $full = Get-FunStatusLine -BatteryInfo (New-Reading -IsFullyCharged $true -TimeMinutes 0)
    if ([string]::IsNullOrWhiteSpace($full)) { throw 'no fun line when fully charged' }
}

Test-Case 'fun line: urgency is reserved for actually-low estimates' {
    $urgent = Get-FunStatusLine -BatteryInfo (New-Reading -Percent 8 -TimeMinutes 12)
    $calm = Get-FunStatusLine -BatteryInfo (New-Reading -Percent 95 -TimeMinutes 600)
    if ($urgent -eq $calm) { throw 'a 12-minute battery says the same thing as a 10-hour one' }
}

Test-Case 'fun line: a low charge outranks a long time estimate' {
    # An idle machine (lid shut, screen off) can read 6% with ten hours
    # remaining. The line used to key only off minutes and cheerfully said
    # "All-day battery. Go do things." while the pill pulsed red and a
    # "Critical Battery - 6%" card sat on the screen.
    $line = Get-FunStatusLine -BatteryInfo (New-Reading -Percent 6 -TimeMinutes 600)
    if ($line -match 'All-day|runway|Plenty') {
        throw "a 6% battery got a relaxed line: '$line'"
    }
}

Test-Case 'fun line: plugged in and holding has no runtime anxiety' {
    $info = New-Reading -Percent 18 -PluggedHolding $true -TimeMinutes -1 -ETA ''
    $line = Get-FunStatusLine -BatteryInfo $info
    if ([string]::IsNullOrWhiteSpace($line)) { throw 'no fun line while plugged in and holding' }
    if ($line -match 'outlet|fumes|Critically') {
        throw "a plugged-in battery got a panic line: '$line'"
    }
}

Test-Case 'fun line: no battery does not claim runtime' {
    $line = Get-FunStatusLine -BatteryInfo (New-Reading -NoBattery $true -TimeMinutes -1)
    if ([string]::IsNullOrWhiteSpace($line)) { throw 'no fun line on a desktop' }
    if ($line -match 'outlet|fumes') { throw "desktop got a battery-anxiety line: '$line'" }
}

# ---- Get-PillText ----
# The pill itself: the one surface the user glances at without opening
# anything, so a wrong string here is the most-seen error the app can make.

Test-Case 'pill: time mode shows the duration, percent mode the percent' {
    $info = New-Reading
    Assert-Equal '3h 8m' (Get-PillText -BatteryInfo $info -DisplayMode 'time').Primary
    Assert-Equal '72%' (Get-PillText -BatteryInfo $info -DisplayMode 'percent').Primary
}

Test-Case 'pill: both mode stacks percent over time' {
    $both = Get-PillText -BatteryInfo (New-Reading) -DisplayMode 'both'
    Assert-Equal '72%' $both.Primary
    Assert-Equal '3h 8m' $both.Secondary
}

Test-Case 'pill: an unknown display mode falls back to time' {
    Assert-Equal '3h 8m' (Get-PillText -BatteryInfo (New-Reading) -DisplayMode 'nonsense').Primary
}

Test-Case 'pill: a desktop with no battery reads AC, once' {
    $info = New-Reading -NoBattery $true -TimeMinutes -1
    Assert-Equal 'AC' (Get-PillText -BatteryInfo $info -DisplayMode 'time').Primary
    $both = Get-PillText -BatteryInfo $info -DisplayMode 'both'
    Assert-Equal 'AC' $both.Primary
    Assert-Equal '' $both.Secondary
}

Test-Case 'pill: an unreadable percent shows dashes, never a made-up number' {
    $info = New-Reading -Percent -1 -TimeMinutes -1
    Assert-Equal '--' (Get-PillText -BatteryInfo $info -DisplayMode 'percent').Primary
    Assert-Equal '--' (Get-PillText -BatteryInfo $info -DisplayMode 'time').Primary
}

Test-Case 'pill: a charge-capped laptop at "fully charged" shows its real percent' {
    # Firmware charge caps (ThinkPad conservation mode, Dell Primary AC Use,
    # ASUS 60% mode) make Windows report WMI BatteryStatus 3 "Fully Charged"
    # while the battery sits at 60%. The pill used to hardcode "100%" here -
    # disagreeing with the tray tooltip ("60% - Fully Charged") and the tray
    # icon (a 60% fill) on the very same tick.
    $info = New-Reading -Percent 60 -IsFullyCharged $true -TimeMinutes -1 -ETA ''
    Assert-Equal '60%' (Get-PillText -BatteryInfo $info -DisplayMode 'percent').Primary
    Assert-Equal 'Full' (Get-PillText -BatteryInfo $info -DisplayMode 'time').Primary
    $both = Get-PillText -BatteryInfo $info -DisplayMode 'both'
    Assert-Equal '60%' $both.Primary
    Assert-Equal 'Full' $both.Secondary
}

Test-Case 'pill: fully charged with no percent reading shows dashes, not 100%' {
    $info = New-Reading -Percent -1 -IsFullyCharged $true -TimeMinutes -1 -ETA ''
    Assert-Equal '--' (Get-PillText -BatteryInfo $info -DisplayMode 'percent').Primary
}

Test-Case 'pill: a genuinely full battery still reads 100%' {
    $info = New-Reading -Percent 100 -IsFullyCharged $true -TimeMinutes -1 -ETA ''
    Assert-Equal '100%' (Get-PillText -BatteryInfo $info -DisplayMode 'percent').Primary
    Assert-Equal 'Full' (Get-PillText -BatteryInfo $info -DisplayMode 'time').Primary
}

# ---- Get-BatterySessionSummary ----

$sessT0 = [datetime]'2026-08-30T22:00:00'

$script:sessSamples = @()

function Add-Run {
    # Appends a CONTIGUOUS run of samples at 1-minute spacing. The widget
    # samples every refresh tick (1-60s), so consecutive samples are always
    # close together in time - fixtures have to reflect that, because the gap
    # between samples is exactly what separates one session from the next.
    [OutputType([void])]
    param([int]$StartMin, [int]$Minutes, [int]$FromPct, [int]$ToPct, [bool]$Charging = $false)
    for ($i = 0; $i -le $Minutes; $i++) {
        $pct = [int][math]::Round($FromPct + (($ToPct - $FromPct) * ($i / [double]$Minutes)))
        $script:sessSamples += , @(($StartMin + $i), $pct, $Charging)
    }
}

function Set-History {
    # Commits the accumulated runs to $script:batteryHistory.
    [OutputType([void])]
    param()
    $script:batteryHistory = New-Object System.Collections.ArrayList
    foreach ($s in $script:sessSamples) {
        $null = $script:batteryHistory.Add(@{
                Time       = $sessT0.AddMinutes($s[0])
                Percent    = [int]$s[1]
                IsCharging = [bool]$s[2]
            })
    }
    $script:sessSamples = @()
}

Test-Case 'session: a plain discharge run reports its span and drain' {
    Add-Run -StartMin 0 -Minutes 90 -FromPct 95 -ToPct 74
    Set-History
    Assert-Equal 'On battery 1h 30m - used 21%' (Get-BatterySessionSummary)
}

Test-Case 'session: silent while charging' {
    Add-Run -StartMin 0 -Minutes 30 -FromPct 60 -ToPct 58
    Add-Run -StartMin 31 -Minutes 60 -FromPct 58 -ToPct 88 -Charging $true
    Set-History
    Assert-Equal '' (Get-BatterySessionSummary)
}

Test-Case 'session: the run starts after the last charge, not at history start' {
    Add-Run -StartMin 0 -Minutes 40 -FromPct 55 -ToPct 40
    Add-Run -StartMin 41 -Minutes 30 -FromPct 40 -ToPct 99 -Charging $true
    Add-Run -StartMin 72 -Minutes 60 -FromPct 95 -ToPct 80
    Set-History
    Assert-Equal 'On battery 1h 0m - used 15%' (Get-BatterySessionSummary)
}

Test-Case 'session: too short to be meaningful stays quiet' {
    Add-Run -StartMin 0 -Minutes 5 -FromPct 95 -ToPct 94
    Set-History
    Assert-Equal '' (Get-BatterySessionSummary)
}

Test-Case 'session: a sleep gap is not counted as time on battery' {
    # The laptop discharges for half an hour, sleeps overnight, and resumes.
    # Both sides of the gap are IsCharging=$false, so a walk-back that only
    # looks at the charge flag runs straight through 8 hours of sleep and
    # tells the user they have been on battery all night.
    Add-Run -StartMin 0 -Minutes 30 -FromPct 95 -ToPct 90
    # ---- 8h asleep: no samples recorded ----
    Add-Run -StartMin 510 -Minutes 60 -FromPct 88 -ToPct 82
    Set-History
    Assert-Equal 'On battery 1h 0m - used 6%' (Get-BatterySessionSummary)
}

Test-Case 'session: history restored from an old config does not resurrect a stale run' {
    # BatteryHistory is persisted and reloaded at startup, so a fresh launch
    # can begin with samples from days ago - and a charge that happened while
    # the app was closed leaves no charging sample to break the run.
    Add-Run -StartMin 0 -Minutes 30 -FromPct 80 -ToPct 72
    # ---- app closed for three days ----
    Add-Run -StartMin 4350 -Minutes 60 -FromPct 99 -ToPct 93
    Set-History
    Assert-Equal 'On battery 1h 0m - used 6%' (Get-BatterySessionSummary)
}

exit (Complete-Tests)
