<#
.SYNOPSIS
    Pester v5 tests for BatteryEstimation.ps1 (pure estimation math).
.DESCRIPTION
    Twin of tests/run-estimation-tests.ps1 — the SAME cases, expressed in
    Pester v5 (Describe/Context/It/Should). Run with:
        Invoke-Pester tests/ -Output Detailed
    For environments WITHOUT Pester, use the dependency-free runner
    tests/run-estimation-tests.ps1 instead.
#>

BeforeAll {
    $estimationPath = Join-Path $PSScriptRoot '..' 'BatteryEstimation.ps1'
    $estimationPath = (Resolve-Path -LiteralPath $estimationPath).Path
    . $estimationPath

    function Reset-EstimationState {
        # Re-initialize module-level $script: state so every case is
        # independent (mirrors BatteryEstimation.ps1's own initializers).
        $script:emaRate = -1
        $script:lastValidRate = -1
        $script:lastValidRateTime = $null
        $script:rateHistory = New-Object System.Collections.ArrayList
        $script:lastCapacityCheck = $null
        $script:capacityRateMismatchCount = 0
        $script:lastAcState = $null
        $script:stateChangeTime = $null
        $script:hysteresisSeconds = 2
    }
}

BeforeEach {
    Reset-EstimationState
}

Describe 'Get-SmoothedTimeRemaining' {

    It 'returns ~180 min discharging 10W / 50Wh / 60%' {
        # 10 W = 10000 mW, 50 Wh = 50000 mWh, 60% -> 30000 mWh / 10000 mW * 60 = 180 min.
        $result = Get-SmoothedTimeRemaining -RawRate 10000 -FullChargeCapacity 50000 `
            -PercentExact 60.0 -IsCharging $false -IsPluggedIn $false
        $result | Should -BeGreaterThan 174
        $result | Should -BeLessThan 186
    }

    It 'returns ~105 min charging 20W / 50Wh / 30% to full' {
        # 20 W = 20000 mW, 50 Wh = 50000 mWh, 30% -> 35000 mWh / 20000 mW * 60 = 105 min.
        $result = Get-SmoothedTimeRemaining -RawRate 20000 -FullChargeCapacity 50000 `
            -PercentExact 30.0 -IsCharging $true -IsPluggedIn $true
        $result | Should -BeGreaterThan 99
        $result | Should -BeLessThan 111
    }

    It 'clamps a tiny-rate underflow to <= 6000 min (100h cap)' {
        $result = Get-SmoothedTimeRemaining -RawRate 1 -FullChargeCapacity 50000 `
            -PercentExact 60.0 -IsCharging $false -IsPluggedIn $false
        $result | Should -BeLessOrEqual 6000
        $result | Should -Be 6000
    }

    It 'returns sentinel -1 for a zero rate with no prior valid rate' {
        $result = Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 50000 `
            -PercentExact 60.0 -IsCharging $false -IsPluggedIn $false
        $result | Should -Be -1
    }

    It 'returns sentinel -1 (not garbage) on the first-call / unavailable-rate path' {
        $result = Get-SmoothedTimeRemaining -RawRate 0 -FullChargeCapacity 0 `
            -PercentExact 0.0 -IsCharging $false -IsPluggedIn $false
        $result | Should -Be -1
        $result | Should -BeLessOrEqual 6000
    }
}

Describe 'Update-EMARate' {

    It 'converges to a constant input rate' {
        $last = -1
        for ($i = 0; $i -lt 20; $i++) { $last = Update-EMARate -RawRate 10000 }
        $last | Should -BeGreaterThan 9999
        $last | Should -BeLessThan 10001
    }

    It 'smooths a step change to a value strictly between old EMA and new raw' {
        $old = -1
        for ($i = 0; $i -lt 20; $i++) { $old = Update-EMARate -RawRate 10000 }
        $new = Update-EMARate -RawRate 20000
        $new | Should -BeGreaterThan $old        # moves toward the new value
        $new | Should -BeLessThan 20000          # but is NOT a hard snap
    }

    It 'initializes the first reading directly to the raw rate' {
        $first = Update-EMARate -RawRate 12345
        $first | Should -Be 12345
    }
}

Describe 'Get-CapacityDerivedRate' {

    It 'seeds a baseline and returns -1 on the first call (insufficient data)' {
        $t0 = Get-Date '2026-01-01T00:00:00'
        $r = Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 60.0 -Now $t0
        $r | Should -Be -1
    }

    It 'returns a sane positive rate for a representative drop over time' {
        # 60% -> 40% of 50000 mWh over 1h = 10000 mWh consumed => ~10000 mW.
        $t0 = Get-Date '2026-01-01T00:00:00'
        $t1 = $t0.AddHours(1)
        $null = Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 60.0 -Now $t0
        $rate = Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 40.0 -Now $t1
        $rate | Should -BeGreaterThan 0
        $rate | Should -BeGreaterThan 9950
        $rate | Should -BeLessThan 10050
    }

    It 'returns -1 (unavailable) for a too-soon resample (< 30s)' {
        $t0 = Get-Date '2026-01-01T00:00:00'
        $t1 = $t0.AddSeconds(10)
        $null = Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 60.0 -Now $t0
        $rate = Get-CapacityDerivedRate -FullChargeCapacity 50000 -PercentExact 59.0 -Now $t1
        $rate | Should -Be -1
    }
}
