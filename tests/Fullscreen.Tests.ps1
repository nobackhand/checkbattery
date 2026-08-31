# tests\Fullscreen.Tests.ps1
#
# Regression suite for Test-RectCoversScreen, the geometry behind
# "Auto-hide in fullscreen".
#
# The setting means "get out of the way of the fullscreen thing". The old
# check asked whether the foreground window covered ANY screen, so a
# fullscreen game or video on monitor 2 hid the pill on monitor 1 - the
# precise setup where a second monitor exists so the widget can stay
# visible. These cases pin the geometry; Test-FullscreenApp now applies it
# to the pill's own screen.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Test-RectCoversScreen')

Write-Host 'Fullscreen.Tests.ps1'

# Primary 1920x1080 at the origin; a second monitor to its LEFT, which is
# where negative coordinates come from on real desks.
$primary = @{ Left = 0; Top = 0; Right = 1920; Bottom = 1080 }
$leftMon = @{ Left = -1920; Top = 0; Right = 0; Bottom = 1080 }

function Test-Covers {
    [OutputType([bool])]
    param([hashtable]$Rect, [hashtable]$Screen)
    return (Test-RectCoversScreen -RectLeft $Rect.Left -RectTop $Rect.Top `
            -RectRight $Rect.Right -RectBottom $Rect.Bottom `
            -ScreenLeft $Screen.Left -ScreenTop $Screen.Top `
            -ScreenRight $Screen.Right -ScreenBottom $Screen.Bottom)
}

Test-Case 'an exactly-fullscreen window covers its screen' {
    Assert-Equal $true (Test-Covers -Rect @{ Left = 0; Top = 0; Right = 1920; Bottom = 1080 } -Screen $primary)
}

Test-Case 'a window larger than the screen still counts as covering it' {
    # Some games size themselves a pixel or two past the edges.
    Assert-Equal $true (Test-Covers -Rect @{ Left = -2; Top = -2; Right = 1922; Bottom = 1082 } -Screen $primary)
}

Test-Case 'a maximized-but-not-fullscreen window does not count' {
    # Taskbar still visible: the bottom edge stops short.
    Assert-Equal $false (Test-Covers -Rect @{ Left = 0; Top = 0; Right = 1920; Bottom = 1032 } -Screen $primary)
}

Test-Case 'an ordinary window does not count' {
    Assert-Equal $false (Test-Covers -Rect @{ Left = 100; Top = 100; Right = 900; Bottom = 700 } -Screen $primary)
}

Test-Case 'fullscreen on ANOTHER monitor does not cover this one' {
    # The bug: a game fullscreen on the left-hand monitor used to hide the
    # pill sitting on the primary.
    $gameOnLeft = @{ Left = -1920; Top = 0; Right = 0; Bottom = 1080 }
    Assert-Equal $true (Test-Covers -Rect $gameOnLeft -Screen $leftMon)
    Assert-Equal $false (Test-Covers -Rect $gameOnLeft -Screen $primary)
}

Test-Case 'negative screen coordinates are handled correctly' {
    # Monitors left of or above the primary are legitimately negative.
    $fullOnLeft = @{ Left = -1920; Top = 0; Right = 0; Bottom = 1080 }
    Assert-Equal $true (Test-Covers -Rect $fullOnLeft -Screen $leftMon)
    $shortOnLeft = @{ Left = -1900; Top = 0; Right = 0; Bottom = 1080 }
    Assert-Equal $false (Test-Covers -Rect $shortOnLeft -Screen $leftMon)
}

exit (Complete-Tests)
