# tests\Formatting.Tests.ps1
#
# Pure-function tests for the display formatting helpers in the widget source.
# These are the functions every visible surface (pill, popup, tray tooltip)
# routes through, and they have no UI or WMI dependencies.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Format-Duration', 'Read-ConfigField')

Write-Host 'Formatting.Tests.ps1'

# ---- Format-Duration: the one duration format in the app ("3h 8m" / "42m") ----

Test-Case 'Format-Duration writes hours and minutes without zero-padding' {
    Assert-Equal '3h 8m' (Format-Duration 188)
}

Test-Case 'Format-Duration drops the hour part below 60 minutes' {
    Assert-Equal '42m' (Format-Duration 42)
}

Test-Case 'Format-Duration renders zero as 0m' {
    Assert-Equal '0m' (Format-Duration 0)
}

Test-Case 'Format-Duration renders an exact hour as Xh 0m' {
    Assert-Equal '2h 0m' (Format-Duration 120)
}

Test-Case 'Format-Duration handles multi-day estimates' {
    Assert-Equal '25h 1m' (Format-Duration 1501)
}

# ---- Read-ConfigField: one bad value must not discard the rest ----

Test-Case 'Read-ConfigField returns the fallback when the value is absent' {
    Assert-Equal 5 (Read-ConfigField -Raw $null -Parse { param($v) [int]$v } -Fallback 5)
}

Test-Case 'Read-ConfigField returns the fallback when parsing throws' {
    Assert-Equal 5 (Read-ConfigField -Raw 'not-a-number' -Parse { param($v) [int]$v } -Fallback 5)
}

Test-Case 'Read-ConfigField returns the fallback when the parser rejects the value' {
    Assert-Equal 5 (Read-ConfigField -Raw 99 -Parse { param($v) if ($v -le 7) { $v } else { $null } } -Fallback 5)
}

Test-Case 'Read-ConfigField returns the parsed value when it is valid' {
    Assert-Equal 3 (Read-ConfigField -Raw '3' -Parse { param($v) [int]$v } -Fallback 5)
}

exit (Complete-Tests)
