# tests\Adversarial.Tests.ps1
#
# Adversarial input tests for every TRUST BOUNDARY in BatteryPill - the places
# where data the app did not produce crosses into code that trusts it:
#
#   1. WMI / Win32_Battery + .NET PowerStatus  -> Read-DeviceNumber, Get-BatteryInfo
#      Whatever the OEM firmware feels like reporting. UInt32 sentinels
#      (4294967295), the 255 "unknown" percent, nulls, strings, and the ARRAY a
#      dual-battery laptop returns. PowerShell's casts turn these into crashes
#      ([int]4294967295 THROWS) or lies ([int]$null is a silent, alarming 0%).
#   2. The config FILE on disk        -> Import-Config, Read-ConfigField
#      A user-editable JSON file: any type in any field, plus hostile shapes
#      (arrays where scalars belong, NaN/Infinity, unbounded history).
#   3. powercfg's stdout              -> Get-PowerPlans, Set-ActivePowerPlan
#      Localized, version-dependent text that is parsed with a regex and whose
#      captured GUID is handed straight back to `powercfg /setactive`.
#   4. The registry theme preference  -> Get-SystemTheme
#      A user-writable HKCU value that is supposed to be a DWORD.
#
# The contract asserted everywhere: malformed input NEVER throws, and never
# turns into an authoritative-looking wrong answer. It degrades to the app's
# documented "no reading" value (-1 / $null / defaults / an empty list).
#
# Read-DeviceNumber is the shared validator for boundary 1; CheckBattery.ps1
# carries its own copy (it ships standalone), so both are pinned below.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction @(
        'Read-DeviceNumber', 'Get-BatteryInfo', 'Get-SmoothedTimeRemaining',
        'Update-EMARate', 'Get-CapacityDerivedRate',
        'Get-PowerPlans', 'Set-ActivePowerPlan', 'Get-SystemTheme',
        'Write-IoFailure', 'Read-ConfigField', 'Import-Config', 'Get-ConfigPath',
        'Read-TextFileShared'))

Write-Host 'Adversarial.Tests.ps1'

# powercfg GUID shape, as BatteryWidget.ps1 defines it at script scope.
$script:powerPlanGuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

# Notifications off: failures are recorded, not rendered (no forms in a test host).
$script:ioNotifyEnabled = $false
$script:ioFailures = @()

$script:tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bp-adv-{0}" -f $PID)
if (Test-Path $script:tmpDir) { Remove-Item $script:tmpDir -Recurse -Force }
New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null

# The module-level estimator state Get-BatteryInfo mutates, reset per case.
function Reset-WidgetState {
    [OutputType([void])]
    param()
    $script:emaRate = -1
    $script:lastValidRate = -1
    $script:lastValidRateTime = $null
    $script:rateHistory = New-Object System.Collections.ArrayList
    $script:lastCapacityCheck = $null
    $script:capacityRateMismatchCount = 0
    $script:lastAcState = $null
    $script:stateChangeTime = $null
    $script:hysteresisSeconds = 2
    $script:lastStateChange = @{ Time = $null; Percent = -1; State = "" }
}

# A stub Win32_Battery instance: named properties only, exactly what
# Get-BatteryInfo reads. Anything not supplied is a plausible healthy value.
function New-FakeBattery {
    [OutputType([pscustomobject])]
    param(
        # any-typed: the point of these is holding values WMI should never emit.
        [AllowNull()][object]$EstimatedChargeRemaining = 60,
        # any-typed: ditto.
        [AllowNull()][object]$BatteryStatus = 1,
        # any-typed: ditto.
        [AllowNull()][object]$DesignCapacity = 74496,
        # any-typed: ditto.
        [AllowNull()][object]$FullChargeCapacity = 70100,
        # any-typed: ditto.
        [AllowNull()][object]$DischargeRate = 12000,
        # any-typed: ditto.
        [AllowNull()][object]$ChargeRate = 0,
        # any-typed: ditto.
        [AllowNull()][object]$EstimatedRunTime = 210,
        # any-typed: ditto.
        [AllowNull()][object]$TimeToFullCharge = 0
    )
    return [pscustomobject]@{
        EstimatedChargeRemaining = $EstimatedChargeRemaining
        BatteryStatus            = $BatteryStatus
        DesignCapacity           = $DesignCapacity
        FullChargeCapacity       = $FullChargeCapacity
        DischargeRate            = $DischargeRate
        ChargeRate               = $ChargeRate
        EstimatedRunTime         = $EstimatedRunTime
        TimeToFullCharge         = $TimeToFullCharge
    }
}

# A stub PowerStatus. $null for every field = "the .NET source knows nothing",
# which keeps each case's assertions about the WMI source unambiguous.
function New-FakePowerStatus {
    [OutputType([pscustomobject])]
    param(
        # any-typed: holds values the real enum/properties should never take.
        [AllowNull()][object]$BatteryChargeStatus = $null,
        # any-typed: ditto.
        [AllowNull()][object]$BatteryLifePercent = $null,
        # any-typed: ditto.
        [AllowNull()][object]$BatteryLifeRemaining = $null,
        # any-typed: ditto.
        [AllowNull()][object]$PowerLineStatus = 'Offline'
    )
    return [pscustomobject]@{
        BatteryChargeStatus  = $BatteryChargeStatus
        BatteryLifePercent   = $BatteryLifePercent
        BatteryLifeRemaining = $BatteryLifeRemaining
        PowerLineStatus      = $PowerLineStatus
    }
}

$t0 = [datetime]'2026-07-29T09:00:00'

# Runs Get-BatteryInfo with both external sources stubbed out.
function Invoke-Battery {
    [OutputType([hashtable])]
    param(
        # any-typed: the stub (or raw junk) standing in for the WMI instance.
        [AllowNull()][object]$Wmi,
        # any-typed: the stub standing in for [SystemInformation]::PowerStatus.
        [AllowNull()][object]$Power = $null
    )
    Reset-WidgetState
    if ($null -eq $Power) { $Power = New-FakePowerStatus }
    return (Get-BatteryInfo -Now $t0 -WmiBattery $Wmi -PowerStatus $Power)
}

# ================================================================
# BOUNDARY 1a - Read-DeviceNumber, the validator itself
# ================================================================

Test-Case 'Read-DeviceNumber accepts an in-range number' {
    Assert-Equal 60 (Read-DeviceNumber -Raw 60 -Min 0 -Max 100)
}

Test-Case 'Read-DeviceNumber accepts a numeric string (WMI hands back strings)' {
    Assert-Equal 60 (Read-DeviceNumber -Raw '60' -Min 0 -Max 100)
}

Test-Case 'Read-DeviceNumber rejects the UInt32 sentinel that used to throw on [int]' {
    # [int]4294967295 raises "Value was either too large or too small for an Int32".
    Assert-Equal $null (Read-DeviceNumber -Raw 4294967295 -Min 1)
}

Test-Case 'Read-DeviceNumber rejects $null instead of letting it become a silent 0' {
    Assert-Equal $null (Read-DeviceNumber -Raw $null -Min 0 -Max 100)
}

Test-Case 'Read-DeviceNumber rejects a non-numeric string' {
    Assert-Equal $null (Read-DeviceNumber -Raw 'unknown' -Min 0 -Max 100)
}

Test-Case 'Read-DeviceNumber rejects an array (the dual-battery shape)' {
    Assert-Equal $null (Read-DeviceNumber -Raw @(60, 80) -Min 0 -Max 100)
}

Test-Case 'Read-DeviceNumber rejects a ONE-element array too' {
    # [double]@(60) succeeds where [double]@(60,80) throws, so without an
    # explicit shape check whether an array is rejected depends on how many
    # elements it happens to have. A collection is never a scalar reading.
    Assert-Equal $null (Read-DeviceNumber -Raw @(60) -Min 0 -Max 100)
    Assert-Equal $null (Read-DeviceNumber -Raw (New-Object System.Collections.ArrayList) -Min 0 -Max 100)
}

Test-Case 'Read-DeviceNumber rejects a hashtable' {
    Assert-Equal $null (Read-DeviceNumber -Raw @{ Value = 60 } -Min 0 -Max 100)
}

Test-Case 'Read-DeviceNumber rejects NaN and Infinity' {
    Assert-Equal $null (Read-DeviceNumber -Raw ([double]::NaN) -Min 0 -Max 100)
    Assert-Equal $null (Read-DeviceNumber -Raw ([double]::PositiveInfinity) -Min 0 -Max 100)
    Assert-Equal $null (Read-DeviceNumber -Raw ([double]::NegativeInfinity) -Min 0 -Max 100)
}

Test-Case 'Read-DeviceNumber rejects out-of-range values on both sides' {
    Assert-Equal $null (Read-DeviceNumber -Raw 255 -Min 0 -Max 100)
    Assert-Equal $null (Read-DeviceNumber -Raw -5 -Min 0 -Max 100)
}

Test-Case 'Read-DeviceNumber keeps the boundaries themselves' {
    Assert-Equal 0 (Read-DeviceNumber -Raw 0 -Min 0 -Max 100)
    Assert-Equal 100 (Read-DeviceNumber -Raw 100 -Min 0 -Max 100)
}

# ================================================================
# BOUNDARY 1b - Get-BatteryInfo against hostile firmware
# ================================================================

Test-Case 'healthy WMI reading still parses (the control case)' {
    $i = Invoke-Battery -Wmi (New-FakeBattery)
    Assert-Equal 60 $i.Percent
    Assert-Equal 74496 $i.DesignCapacity
    Assert-Equal 12000 $i.DischargeRate
    Assert-Equal 'Discharging' $i.StatusText
}

Test-Case 'EstimatedRunTime 4294967295 does not crash the tick (it used to throw)' {
    # The fallback path cast this straight to [int]. On a machine whose firmware
    # reports the all-ones "unknown" pattern that threw out of Get-BatteryInfo -
    # i.e. out of the timer tick - every 3 seconds.
    $i = Invoke-Battery -Wmi (New-FakeBattery -EstimatedRunTime 4294967295 -DischargeRate 0 -FullChargeCapacity 0)
    Assert-Equal (-1) $i.TimeMinutes
    Assert-Equal (-1) $i.FullRuntimeMinutes
    Assert-Equal 'Estimating...' $i.TimeString
}

Test-Case 'TimeToFullCharge 4294967295 while charging does not crash' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -BatteryStatus 6 -ChargeRate 0 -FullChargeCapacity 0 -TimeToFullCharge 4294967295)
    Assert-True $i.IsCharging 'status 6 is charging'
    Assert-Equal (-1) $i.TimeMinutes
}

Test-Case 'EstimatedRunTime as a string does not crash' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -EstimatedRunTime 'unknown' -DischargeRate 0 -FullChargeCapacity 0)
    Assert-Equal (-1) $i.TimeMinutes
}

Test-Case 'percent 255 (the WMI unknown sentinel) is not shown as 255%' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -EstimatedChargeRemaining 255)
    Assert-Equal (-1) $i.Percent
}

Test-Case 'percent $null does not become a false, alarming 0%' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -EstimatedChargeRemaining $null)
    Assert-Equal (-1) $i.Percent
}

Test-Case 'an unreadable percent is not reported as Critical' {
    # -1 is "no reading". "-1 -le 10" made the popup title, hero color and the
    # tray tooltip all claim a critical battery on data we do not have.
    $i = Invoke-Battery -Wmi (New-FakeBattery -EstimatedChargeRemaining $null)
    Assert-True ($i.StatusText -ne 'Critical') 'unknown percent must not read as Critical'
    Assert-True ($i.StatusText -ne 'Low') 'unknown percent must not read as Low'
}

Test-Case 'a real 8% still reports Critical (the guard did not disable the alarm)' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -EstimatedChargeRemaining 8)
    Assert-Equal 'Critical' $i.StatusText
}

Test-Case 'negative percent is rejected' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -EstimatedChargeRemaining -20)
    Assert-Equal (-1) $i.Percent
}

Test-Case 'every numeric property arriving as garbage at once does not crash' {
    $junk = New-FakeBattery -EstimatedChargeRemaining 'x' -BatteryStatus 'y' -DesignCapacity 'z' `
        -FullChargeCapacity 'w' -DischargeRate 'v' -ChargeRate 'u' -EstimatedRunTime 't' -TimeToFullCharge 's'
    $i = Invoke-Battery -Wmi $junk
    Assert-Equal (-1) $i.Percent
    Assert-Equal (-1) $i.DesignCapacity
    Assert-Equal (-1) $i.FullChargeCapacity
    Assert-Equal (-1) $i.DischargeRate
    Assert-Equal (-1) $i.TimeMinutes
    Assert-Equal (-1.0) $i.BatteryWearPercent
    Assert-Equal $false $i.IsCharging
}

Test-Case 'every property arriving as $null does not crash' {
    $nulls = New-FakeBattery -EstimatedChargeRemaining $null -BatteryStatus $null -DesignCapacity $null `
        -FullChargeCapacity $null -DischargeRate $null -ChargeRate $null -EstimatedRunTime $null -TimeToFullCharge $null
    $i = Invoke-Battery -Wmi $nulls
    Assert-Equal (-1) $i.Percent
    Assert-Equal (-1) $i.TimeMinutes
}

Test-Case 'a dual-battery ARRAY is reduced to the first pack, not cast to [int]' {
    $pair = @((New-FakeBattery -EstimatedChargeRemaining 41), (New-FakeBattery -EstimatedChargeRemaining 77))
    $i = Invoke-Battery -Wmi $pair
    Assert-Equal 41 $i.Percent
}

Test-Case 'array-valued properties (member access over two packs) do not crash' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -EstimatedChargeRemaining @(41, 77) -DesignCapacity @(1, 2) -EstimatedRunTime @(10, 20))
    Assert-Equal (-1) $i.Percent
    Assert-Equal (-1) $i.DesignCapacity
}

Test-Case 'capacity of 0 does not produce a divide-by-zero wear figure' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -DesignCapacity 0 -FullChargeCapacity 0)
    Assert-Equal (-1.0) $i.BatteryWearPercent
}

Test-Case 'a FullChargeCapacity above DesignCapacity clamps wear at 0, never negative' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -DesignCapacity 70000 -FullChargeCapacity 74000)
    Assert-Equal 0.0 $i.BatteryWearPercent
}

Test-Case 'out-of-range BatteryStatus is treated as unknown, not as a state' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -BatteryStatus 99)
    Assert-Equal $false $i.IsCharging
    Assert-Equal $false $i.IsPluggedIn
    Assert-Equal $false $i.IsFullyCharged
}

Test-Case 'an array-valued BatteryStatus yields real booleans, not a filtered array' {
    # `@(3,1) -eq 3` returns @(3) - truthy, and NOT a [bool]. Assigned straight
    # to IsFullyCharged that made the pill claim "Fully Charged" off a shape the
    # firmware should never have produced.
    $i = Invoke-Battery -Wmi (New-FakeBattery -BatteryStatus @(3, 1))
    Assert-True ($i.IsFullyCharged -is [bool]) 'IsFullyCharged must be a real [bool]'
    Assert-True ($i.IsCharging -is [bool]) 'IsCharging must be a real [bool]'
    Assert-Equal $false $i.IsFullyCharged
    Assert-True ($i.StatusText -ne 'Fully Charged') 'an unreadable status is not "Fully Charged"'
}

Test-Case 'a numeric-string BatteryStatus still reads as the state it names' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -BatteryStatus '6')
    Assert-True $i.IsCharging 'status "6" is charging'
}

Test-Case 'no WMI instance at all falls back to .NET without crashing' {
    $i = Invoke-Battery -Wmi $null -Power (New-FakePowerStatus -BatteryLifePercent 0.42 -PowerLineStatus 'Offline')
    Assert-Equal 42 $i.Percent
}

Test-Case '.NET BatteryLifePercent of 255 (its unknown value) is not shown as 25500%' {
    $i = Invoke-Battery -Wmi $null -Power (New-FakePowerStatus -BatteryLifePercent 255)
    Assert-Equal (-1) $i.Percent
}

Test-Case 'a garbage BatteryChargeStatus does not crash the no-battery probe' {
    $i = Invoke-Battery -Wmi $null -Power (New-FakePowerStatus -BatteryChargeStatus 'nonsense')
    Assert-Equal $false $i.NoBattery
    Assert-Equal (-1) $i.Percent
}

Test-Case 'the real no-battery flag (128) is still honoured' {
    $i = Invoke-Battery -Wmi $null -Power (New-FakePowerStatus -BatteryChargeStatus 128)
    Assert-True $i.NoBattery 'bit 128 means no system battery'
    Assert-Equal 'No Battery' $i.StatusText
}

Test-Case 'a garbage BatteryLifeRemaining does not crash the time fallback' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -DischargeRate 0 -FullChargeCapacity 0 -EstimatedRunTime 0) `
        -Power (New-FakePowerStatus -BatteryLifeRemaining 'soon')
    Assert-Equal (-1) $i.TimeMinutes
}

Test-Case 'an absurd runtime is suppressed rather than displayed' {
    $i = Invoke-Battery -Wmi (New-FakeBattery -DischargeRate 0 -FullChargeCapacity 0 -EstimatedRunTime 999999)
    Assert-Equal (-1) $i.TimeMinutes
    Assert-Equal '' $i.ETA
}

Test-Case 'an object with no battery properties at all does not crash' {
    $i = Invoke-Battery -Wmi ([pscustomobject]@{ Nothing = 'here' })
    Assert-Equal (-1) $i.Percent
    Assert-Equal (-1) $i.TimeMinutes
}

# ================================================================
# BOUNDARY 2 - the config file on disk
# ================================================================

# Writes $Text as the config file for this case and loads it.
function Import-TestConfig {
    [OutputType([hashtable])]
    param([string]$Name, [string]$Text)
    $p = Join-Path $script:tmpDir $Name
    Set-Content -LiteralPath $p -Value $Text -Encoding UTF8
    $script:ioFailures = @()
    return (Import-Config -Path $p)
}

Test-Case 'a well-formed config still loads every field (the control case)' {
    $c = Import-TestConfig 'good.json' '{"X":10,"Y":20,"Opacity":0.5,"RefreshInterval":5000,"Theme":"light","PillSize":"compact","DisplayMode":"percent","AccentColorIndex":3}'
    Assert-Equal 10 $c.X
    Assert-Equal 0.5 $c.Opacity
    Assert-Equal 'light' $c.Theme
    Assert-Equal 'compact' $c.PillSize
    Assert-Equal 3 $c.AccentColorIndex
    Assert-Equal 0 $script:ioFailures.Count
}

Test-Case 'every field holding the wrong type falls back field-by-field' {
    $c = Import-TestConfig 'types.json' '{"X":"left","Y":{"a":1},"Opacity":"opaque","RefreshInterval":[1,2],"PositionLocked":"maybe","DisplayMode":42,"PillSize":true,"Theme":["dark"],"AccentColorIndex":"blue","AutoHideFullscreen":"sometimes"}'
    Assert-Equal (-1) $c.X
    Assert-Equal 0.85 $c.Opacity
    Assert-Equal 3000 $c.RefreshInterval
    Assert-Equal 'time' $c.DisplayMode
    Assert-Equal 'normal' $c.PillSize
    Assert-Equal 'dark' $c.Theme
    Assert-Equal 0 $c.AccentColorIndex
}

Test-Case 'an enum field holding an unlisted value falls back instead of being trusted' {
    $c = Import-TestConfig 'enum.json' '{"Theme":"neon","PillSize":"gigantic","DisplayMode":"morse"}'
    Assert-Equal 'dark' $c.Theme
    Assert-Equal 'normal' $c.PillSize
    Assert-Equal 'time' $c.DisplayMode
}

Test-Case 'out-of-range numbers are clamped into the range the UI can render' {
    $c = Import-TestConfig 'range.json' '{"Opacity":99,"RefreshInterval":1,"AccentColorIndex":9999}'
    Assert-Equal 1.0 $c.Opacity
    Assert-Equal 1000 $c.RefreshInterval
    Assert-Equal 7 $c.AccentColorIndex
}

Test-Case 'negative and zero refresh intervals cannot become a 100ms WMI storm' {
    $c = Import-TestConfig 'interval.json' '{"RefreshInterval":-5,"Opacity":-3}'
    Assert-Equal 1000 $c.RefreshInterval
    Assert-Equal 0.3 $c.Opacity
}

Test-Case 'an Opacity of NaN never reaches Form.Opacity' {
    # [math]::Max/Min propagate NaN (every comparison against it is false), and
    # WinForms takes NaN on Form.Opacity without complaint - so the pill's
    # transparency became undefined and no slider move could recover it.
    $c = Import-TestConfig 'nan.json' '{"Opacity":"NaN"}'
    Assert-True (-not [double]::IsNaN([double]$c.Opacity)) 'Opacity must never be NaN'
    Assert-True ($c.Opacity -ge 0.3 -and $c.Opacity -le 1.0) 'Opacity must land inside 0.3-1.0'
}

Test-Case 'an Opacity of Infinity is clamped, not propagated' {
    $c = Import-TestConfig 'inf.json' '{"Opacity":"Infinity"}'
    Assert-True ($c.Opacity -ge 0.3 -and $c.Opacity -le 1.0) 'Opacity must land inside 0.3-1.0'
}

Test-Case 'a number too large for [int] falls back instead of throwing' {
    $c = Import-TestConfig 'huge.json' '{"X":1e100,"Y":1e100,"RefreshInterval":1e100,"AccentColorIndex":1e100}'
    Assert-Equal (-1) $c.X
    Assert-Equal 3000 $c.RefreshInterval
    Assert-Equal 0 $c.AccentColorIndex
}

Test-Case 'a half-written position (X only) is ignored - the pair moves together' {
    $c = Import-TestConfig 'halfpos.json' '{"X":400}'
    Assert-Equal (-1) $c.X
    Assert-Equal (-1) $c.Y
}

Test-Case 'truncated JSON degrades to defaults and reports itself' {
    $c = Import-TestConfig 'trunc.json' '{"Theme":"light","X":'
    Assert-Equal 'dark' $c.Theme
    Assert-Equal 1 $script:ioFailures.Count
}

Test-Case 'a JSON array where an object belongs does not crash' {
    $c = Import-TestConfig 'array.json' '[1,2,3]'
    Assert-Equal 'dark' $c.Theme
    Assert-Equal 3000 $c.RefreshInterval
}

Test-Case 'a bare JSON scalar does not crash' {
    $c = Import-TestConfig 'scalar.json' '"just a string"'
    Assert-Equal 'dark' $c.Theme
}

Test-Case 'an empty config file does not crash' {
    $c = Import-TestConfig 'empty.json' ''
    Assert-Equal 'dark' $c.Theme
    Assert-Equal 3000 $c.RefreshInterval
}

Test-Case 'BatteryHistory holding a scalar instead of a list does not crash' {
    $c = Import-TestConfig 'hist-scalar.json' '{"BatteryHistory":5}'
    Assert-Equal 0 $c.BatteryHistory.Count
}

Test-Case 'history entries with junk percents or timestamps are dropped, good ones kept' {
    $json = '{"BatteryHistory":[' +
    '{"Time":"2026-07-29T08:00:00","Percent":50,"IsCharging":false},' +
    '{"Time":"not a date","Percent":50,"IsCharging":false},' +
    '{"Time":"2026-07-29T08:01:00","Percent":900,"IsCharging":false},' +
    '{"Time":"2026-07-29T08:02:00","Percent":-5,"IsCharging":false},' +
    '{"Time":"2026-07-29T08:03:00","Percent":"half","IsCharging":false},' +
    '{"Time":"2026-07-29T08:04:00","Percent":70,"IsCharging":true}]}'
    $c = Import-TestConfig 'hist-mixed.json' $json
    Assert-Equal 2 $c.BatteryHistory.Count
    Assert-Equal 50 $c.BatteryHistory[0].Percent
    Assert-Equal 70 $c.BatteryHistory[1].Percent
}

Test-Case 'an oversized history is capped before it reaches the paint loop' {
    $entries = @()
    for ($i = 0; $i -lt 3000; $i++) {
        $entries += '{"Time":"2026-07-29T08:00:00","Percent":50,"IsCharging":false}'
    }
    $c = Import-TestConfig 'hist-huge.json' ('{"BatteryHistory":[' + ($entries -join ',') + ']}')
    Assert-Equal 2400 $c.BatteryHistory.Count
}

Test-Case 'a persisted EMA state with a junk timestamp is discarded, not trusted' {
    $c = Import-TestConfig 'ema.json' '{"EmaRate":12000,"LastValidRate":12000,"ConfigSavedAt":"whenever"}'
    Assert-Equal (-1) $c.EmaRate
    Assert-Equal (-1) $c.LastValidRate
}

Test-Case 'a config with no fields at all yields the full default set' {
    $c = Import-TestConfig 'bare.json' '{}'
    Assert-Equal 'dark' $c.Theme
    Assert-Equal 0.85 $c.Opacity
    Assert-Equal $false $c.PositionLocked
    Assert-Equal 0 $c.BatteryHistory.Count
}

Test-Case 'Read-ConfigField never lets a throwing parser escape' {
    Assert-Equal 'fallback' (Read-ConfigField -Raw 'x' -Fallback 'fallback' -Parse { param($r) throw "boom: $r" })
}

# ================================================================
# BOUNDARY 3 - powercfg's stdout
# ================================================================

Test-Case 'a normal powercfg listing parses (the control case)' {
    $out = @(
        '',
        'Existing Power Schemes (* Active)',
        '-----------------------------------',
        'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced) *',
        'Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)'
    )
    $plans = @(Get-PowerPlans -Output $out)
    Assert-Equal 2 $plans.Count
    Assert-Equal 'Balanced' $plans[0].Name
    Assert-Equal $true $plans[0].IsActive
    Assert-Equal $false $plans[1].IsActive
}

Test-Case 'a line whose id is not a GUID is dropped, not passed to powercfg' {
    $out = @('Power Scheme GUID: ../../../evil  (Pwned)')
    Assert-Equal 0 (@(Get-PowerPlans -Output $out)).Count
}

Test-Case 'a plan row with an empty name is dropped (no unlabelled menu item)' {
    $out = @('Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  ( )')
    Assert-Equal 0 (@(Get-PowerPlans -Output $out)).Count
}

Test-Case 'empty, null and non-matching powercfg output yields an empty list' {
    Assert-Equal 0 (@(Get-PowerPlans -Output @())).Count
    Assert-Equal 0 (@(Get-PowerPlans -Output @($null, '', 'ERROR: access denied'))).Count
}

Test-Case 'a localized name with brackets and unicode still parses' {
    $out = @('Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Ausbalanciert [Standard])')
    $plans = @(Get-PowerPlans -Output $out)
    Assert-Equal 1 $plans.Count
    Assert-Equal 'Ausbalanciert [Standard]' $plans[0].Name
}

Test-Case 'Set-ActivePowerPlan refuses an id that is not a GUID - without shelling out' {
    # $LASTEXITCODE is the observable: powercfg sets it, so an unchanged 0 after
    # the call proves the id was rejected BEFORE it reached the external command
    # rather than being handed over and failing there.
    foreach ($bad in @('not-a-guid', '', '381b4222-f694-41f0-9685-ff5bb260df2e /delete',
            '381b4222-f694-41f0-9685-ff5bb260df2G', '381b4222f69441f09685ff5bb260df2e')) {
        $global:LASTEXITCODE = 0
        Assert-Equal $false (Set-ActivePowerPlan -PlanGUID $bad) "must refuse '$bad'"
        Assert-Equal 0 $global:LASTEXITCODE "powercfg must not be invoked for '$bad'"
    }
    $global:LASTEXITCODE = 0
    Assert-Equal $false (Set-ActivePowerPlan -PlanGUID $null)
    Assert-Equal 0 $global:LASTEXITCODE 'powercfg must not be invoked for $null'
}

# ================================================================
# BOUNDARY 4 - the registry theme preference
# ================================================================

Test-Case 'a missing theme key means dark, not a crash' {
    Assert-Equal $false (Get-SystemTheme -RegPath 'HKCU:\SOFTWARE\BatteryPillTestsNoSuchKey')
}

Test-Case 'a theme value of 1 means light, 0 means dark' {
    $key = 'HKCU:\SOFTWARE\BatteryPillTests\Theme'
    New-Item -Path $key -Force | Out-Null
    try {
        Set-ItemProperty -Path $key -Name 'AppsUseLightTheme' -Value 1 -Type DWord
        Assert-Equal $true (Get-SystemTheme -RegPath $key)
        Set-ItemProperty -Path $key -Name 'AppsUseLightTheme' -Value 0 -Type DWord
        Assert-Equal $false (Get-SystemTheme -RegPath $key)
    } finally { Remove-Item -Path 'HKCU:\SOFTWARE\BatteryPillTests' -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'a hand-edited theme value of the wrong TYPE returns a real boolean' {
    # The key is user-writable, so the DWORD can be a string or a MULTI_SZ. A
    # non-boolean escaping a [bool] function poisons every `if (Get-SystemTheme)`.
    $key = 'HKCU:\SOFTWARE\BatteryPillTests\Theme'
    New-Item -Path $key -Force | Out-Null
    try {
        Set-ItemProperty -Path $key -Name 'AppsUseLightTheme' -Value 'light' -Type String
        $r = Get-SystemTheme -RegPath $key
        Assert-True ($r -is [bool]) 'must return a real [bool]'
        Assert-Equal $false $r

        Set-ItemProperty -Path $key -Name 'AppsUseLightTheme' -Value @('1', '0') -Type MultiString
        $r2 = Get-SystemTheme -RegPath $key
        Assert-True ($r2 -is [bool]) 'must return a real [bool]'
        Assert-Equal $false $r2

        # A REG_SZ "1" is still an honest "light" answer.
        Set-ItemProperty -Path $key -Name 'AppsUseLightTheme' -Value '1' -Type String
        Assert-Equal $true (Get-SystemTheme -RegPath $key)
    } finally { Remove-Item -Path 'HKCU:\SOFTWARE\BatteryPillTests' -Recurse -Force -ErrorAction SilentlyContinue }
}

# ================================================================
# BOUNDARY 1c - the CLI's own copy of the validator (CheckBattery.ps1)
# ================================================================

Test-Case 'CheckBattery.ps1 ships the same validator, and it behaves the same' {
    . (Import-WidgetFunction -Name 'Read-DeviceNumber' -Source 'CheckBattery.ps1')
    Assert-Equal $null (Read-DeviceNumber -Raw 4294967295 -Min 1)
    Assert-Equal $null (Read-DeviceNumber -Raw $null -Min 0 -Max 100)
    Assert-Equal $null (Read-DeviceNumber -Raw @(60, 80) -Min 0 -Max 100)
    Assert-Equal $null (Read-DeviceNumber -Raw 255 -Min 0 -Max 100)
    Assert-Equal 60 (Read-DeviceNumber -Raw '60' -Min 0 -Max 100)
}

Test-Case 'CheckBattery.ps1 takes the first pack of a dual-battery array' {
    $src = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'CheckBattery.ps1') -Raw
    Assert-True ($src -match 'Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop\)\s*\|\s*Select-Object -First 1') `
        'the WMI query must collapse the dual-battery array before any [int] cast'
}

Remove-Item $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
exit (Complete-Tests)
