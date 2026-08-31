# tests\AnimationScheduler.Tests.ps1
#
# Regression suite for Update-PulseTimerState - the app's animation scheduler.
#
# This one function decides whether a 33ms (30fps) timer runs. In a widget
# whose entire job is helping people conserve battery, a timer that fails to
# stop is the worst possible defect: invisible, permanent, and directly
# contrary to the product. So the contract is pinned in both directions -
# it must run when something is animating, and it must STOP when nothing is.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Update-PulseTimerState', 'Clear-ExpiredMoments')

Add-Type -AssemblyName System.Windows.Forms

Write-Host 'AnimationScheduler.Tests.ps1'

function Reset-AnimationState {
    # Idle: nothing animating, fill settled, timer stopped.
    [OutputType([void])]
    param()
    if ($null -ne $script:pulseTimer) { $script:pulseTimer.Dispose() }
    $script:pulseTimer = New-Object System.Windows.Forms.Timer
    $script:pulseTimer.Interval = 33
    # Mirrors the module-level table in src\110-floating-bar.ps1. The stale
    # cases below use +/-10 minutes, so they hold for any plausible duration.
    $script:momentDurations = @{ Shimmer = 700; BoltPop = 1200; Ripple = 350 }
    $script:barIsCharging = $false
    $script:flashAlpha = 0
    $script:lowBatPulseActive = $false
    $script:estimatingLabel = $null
    $script:shimmerStart = $null
    $script:boltPopStart = $null
    $script:rippleState = $null
    $script:themeFade = $null
    $script:colorFadeActive = $false
    $script:textFadeAlpha = 255
    $script:displayedFillPct = 50.0
    $script:barDisplayPercent = 50
}

Test-Case 'scheduler: idle state leaves the timer stopped' {
    Reset-AnimationState
    Update-PulseTimerState
    Assert-Equal $false $script:pulseTimer.Enabled
}

Test-Case 'scheduler: charging runs the timer (the breathing pulse)' {
    Reset-AnimationState
    $script:barIsCharging = $true
    Update-PulseTimerState
    Assert-Equal $true $script:pulseTimer.Enabled
}

Test-Case 'scheduler: an unsettled fill level runs the timer' {
    Reset-AnimationState
    $script:barDisplayPercent = 80
    Update-PulseTimerState
    Assert-Equal $true $script:pulseTimer.Enabled
}

Test-Case 'scheduler: a fresh moment runs the timer' {
    Reset-AnimationState
    $script:shimmerStart = Get-Date
    Update-PulseTimerState
    Assert-Equal $true $script:pulseTimer.Enabled
}

Test-Case 'scheduler: the timer stops again once state goes idle' {
    Reset-AnimationState
    $script:barIsCharging = $true
    Update-PulseTimerState
    Assert-Equal $true $script:pulseTimer.Enabled
    $script:barIsCharging = $false
    Update-PulseTimerState
    Assert-Equal $false $script:pulseTimer.Enabled
}

# ---- Stale moments: the hidden-pill defect ----
# Moment flags (shimmer / bolt pop / ripple) used to be cleared ONLY by the
# pill's Paint handler. A hidden pill never receives WM_PAINT - so plugging in
# or hitting 100% while the pill was hidden ("Hide Pill", "Hide Bar", or
# fullscreen auto-hide) raised a flag that could never clear, and the 30fps
# timer ran forever on an invisible window. The scheduler now expires moments
# by elapsed time itself, so it no longer depends on anything being painted.

Test-Case 'scheduler: a long-finished shimmer does not pin the timer on' {
    Reset-AnimationState
    $script:shimmerStart = (Get-Date).AddMinutes(-10)
    Update-PulseTimerState
    Assert-Equal $false $script:pulseTimer.Enabled
    Assert-Equal $null $script:shimmerStart
}

Test-Case 'scheduler: a long-finished bolt pop does not pin the timer on' {
    Reset-AnimationState
    $script:boltPopStart = (Get-Date).AddMinutes(-10)
    Update-PulseTimerState
    Assert-Equal $false $script:pulseTimer.Enabled
    Assert-Equal $null $script:boltPopStart
}

Test-Case 'scheduler: a long-finished ripple does not pin the timer on' {
    Reset-AnimationState
    $script:rippleState = @{ X = 10; Y = 10; Start = (Get-Date).AddMinutes(-10) }
    Update-PulseTimerState
    Assert-Equal $false $script:pulseTimer.Enabled
    Assert-Equal $null $script:rippleState
}

Test-Case 'scheduler: expiry does not cut a moment short while it is still playing' {
    # The flags drive real on-screen animation; expiring them early would
    # truncate the effect. Only elapsed-past-duration moments may be cleared.
    Reset-AnimationState
    $script:shimmerStart = Get-Date
    $script:boltPopStart = Get-Date
    $script:rippleState = @{ X = 10; Y = 10; Start = Get-Date }
    Update-PulseTimerState
    Assert-Equal $true $script:pulseTimer.Enabled
    if ($null -eq $script:shimmerStart) { throw 'shimmer was cleared while still playing' }
    if ($null -eq $script:boltPopStart) { throw 'bolt pop was cleared while still playing' }
    if ($null -eq $script:rippleState) { throw 'ripple was cleared while still playing' }
}

Test-Case 'scheduler: a stale moment alongside live animation keeps the timer running' {
    Reset-AnimationState
    $script:shimmerStart = (Get-Date).AddMinutes(-10)
    $script:barIsCharging = $true
    Update-PulseTimerState
    Assert-Equal $true $script:pulseTimer.Enabled
    Assert-Equal $null $script:shimmerStart
}

if ($null -ne $script:pulseTimer) { $script:pulseTimer.Dispose() }

exit (Complete-Tests)
