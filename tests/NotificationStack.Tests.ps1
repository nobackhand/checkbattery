# tests\NotificationStack.Tests.ps1
#
# Where notification cards rest. Cards stack up from the bottom-right corner
# - which is also where the pill rests by default, so a 10-second battery
# warning used to sit right on top of the pill it was about.
# Get-NotificationStackBottom lifts the stack above the pill only when the
# lowest card would cover it.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Get-NotificationStackBottom', 'Resolve-NotificationStackBottom')
Add-Type -AssemblyName System.Drawing

Write-Host 'NotificationStack.Tests.ps1'

# 2880x1800 at 150% scaling: work area above a 72px taskbar, 480x150 cards
$wa = New-Object System.Drawing.Rectangle(0, 0, 2880, 1728)
$cw = 480; $ch = 150

function New-Rect {
    [OutputType([System.Drawing.Rectangle])]
    param([int]$X, [int]$Y, [int]$W = 162, [int]$H = 51)
    return New-Object System.Drawing.Rectangle($X, $Y, $W, $H)
}

Test-Case 'cards: no pill on screen - the usual bottom-right corner' {
    Assert-Equal 1708 (Get-NotificationStackBottom -WorkingArea $wa -CardWidth $cw -CardHeight $ch)
}

Test-Case 'cards: a pill in its default bottom-right spot - the stack starts just above it' {
    $pill = New-Rect -X 2708 -Y 1667
    $bottom = Get-NotificationStackBottom -WorkingArea $wa -CardWidth $cw -CardHeight $ch -Pill $pill
    Assert-Equal 1659 $bottom
    # and the lowest card really clears the pill
    $card = New-Object System.Drawing.Rectangle(($wa.Right - $cw - 10), ($bottom - $ch), $cw, $ch)
    Assert-Equal $false $card.IntersectsWith($pill)
}

Test-Case 'cards: a pill anywhere else leaves the corner alone' {
    foreach ($p in @((New-Rect -X 40 -Y 40), (New-Rect -X 40 -Y 1667), (New-Rect -X 1200 -Y 900), (New-Rect -X 2708 -Y 200))) {
        Assert-Equal 1708 (Get-NotificationStackBottom -WorkingArea $wa -CardWidth $cw -CardHeight $ch -Pill $p)
    }
}

Test-Case 'cards: a pill just above the corner card still counts (8px breathing room)' {
    # Pill bottom 4px above the card's top edge: too close, lift the stack
    $pill = New-Rect -X 2600 -Y (1708 - 150 - 51 - 4)
    $bottom = Get-NotificationStackBottom -WorkingArea $wa -CardWidth $cw -CardHeight $ch -Pill $pill
    Assert-Equal ($pill.Top - 8) $bottom
}

Test-Case 'cards: no room above the pill - keep the corner rather than leave the screen' {
    # A tiny work area where lifting above the pill would push the card off the top
    $small = New-Object System.Drawing.Rectangle(0, 0, 800, 260)
    $pill = New-Rect -X 620 -Y 100
    Assert-Equal 240 (Get-NotificationStackBottom -WorkingArea $small -CardWidth $cw -CardHeight $ch -Pill $pill)
}

Test-Case 'cards: a non-zero work-area origin (second monitor) is respected' {
    $second = New-Object System.Drawing.Rectangle(2880, 0, 1920, 1080)
    Assert-Equal 1060 (Get-NotificationStackBottom -WorkingArea $second -CardWidth $cw -CardHeight $ch)
    $pill = New-Rect -X (2880 + 1920 - 172) -Y (1080 - 61)
    Assert-Equal ($pill.Top - 8) (Get-NotificationStackBottom -WorkingArea $second -CardWidth $cw -CardHeight $ch -Pill $pill)
}

Test-Case 'stack: a new stack takes the fresh base' {
    Assert-Equal 1708 (Resolve-NotificationStackBottom -StackWasEmpty $true -Held 1659 -Fresh 1708)
    Assert-Equal 1659 (Resolve-NotificationStackBottom -StackWasEmpty $true -Held $null -Fresh 1659)
}

Test-Case 'stack: a card joining a live stack keeps the stack''s base' {
    # The pill hid (Hide Pill shows its own card) while a lifted card was up:
    # the fresh base is the corner again, but the new card must stack on the
    # existing one, not overlap it.
    Assert-Equal 1659 (Resolve-NotificationStackBottom -StackWasEmpty $false -Held 1659 -Fresh 1708)
}

exit (Complete-Tests)
