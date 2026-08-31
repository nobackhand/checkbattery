# tests\PillPosition.Tests.ps1
#
# Regression suite for Get-DisplayChangeAction - what happens to the pill
# when the display layout changes.
#
# The saved position is the user's INTENT. The runtime position may have to
# deviate from it while a monitor is missing, but the intent must survive:
# undocking, Win+P, a sleeping monitor, an RDP session attaching or a game
# changing resolution are all transient, and the layout usually comes back a
# moment later. The old handler moved the pill to the primary corner and
# wrote that to config immediately, so a one-second blip permanently
# destroyed a position the user had deliberately chosen - and re-docking did
# not restore it, because there was nothing left to restore.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Get-DisplayChangeAction', 'Get-ClampedPosition')

Write-Host 'PillPosition.Tests.ps1'

Test-Case 'nothing to do while the pill sits at its saved spot' {
    Assert-Equal 'none' (Get-DisplayChangeAction -SavedPositionValid $true `
            -CurrentPositionValid $true -AtSavedPosition $true)
}

Test-Case 'the saved spot becoming valid again restores the pill to it' {
    # Re-docking, or the monitor waking up: the pill is parked on the primary
    # screen, and its real home is available once more.
    Assert-Equal 'restore' (Get-DisplayChangeAction -SavedPositionValid $true `
            -CurrentPositionValid $true -AtSavedPosition $false)
}

Test-Case 'a pill stranded off-screen with no valid saved spot is parked' {
    Assert-Equal 'park' (Get-DisplayChangeAction -SavedPositionValid $false `
            -CurrentPositionValid $false -AtSavedPosition $false)
}

Test-Case 'a pill already somewhere visible is left alone' {
    # Windows itself often relocates a window when its monitor disappears. If
    # that landed somewhere valid, moving it again is just churn.
    Assert-Equal 'none' (Get-DisplayChangeAction -SavedPositionValid $false `
            -CurrentPositionValid $true -AtSavedPosition $false)
}

Test-Case 'no display change ever asks to overwrite the saved position' {
    # The whole point: every outcome is a MOVE, never a save. Exhaustive over
    # the eight input combinations.
    foreach ($saved in @($true, $false)) {
        foreach ($current in @($true, $false)) {
            foreach ($atSaved in @($true, $false)) {
                $action = Get-DisplayChangeAction -SavedPositionValid $saved `
                    -CurrentPositionValid $current -AtSavedPosition $atSaved
                if ($action -notin @('none', 'restore', 'park')) {
                    throw "unexpected action '$action' for saved=$saved current=$current atSaved=$atSaved"
                }
            }
        }
    }
}

Test-Case 'the saved spot always wins when it is available' {
    # Whatever else is true, a valid saved position is never abandoned.
    foreach ($current in @($true, $false)) {
        $action = Get-DisplayChangeAction -SavedPositionValid $true `
            -CurrentPositionValid $current -AtSavedPosition $false
        Assert-Equal 'restore' $action
    }
}

# ---- Get-ClampedPosition ----
# The pill's SIZE can change under a saved position - it is DPI-scaled now,
# and Settings can change it too - so a position that was flush against the
# right edge for a 108px pill leaves a 216px one hanging off the screen.
# Test-PositionOnScreen only checks the pill's CENTRE, so it considers that
# position valid and never corrects it.

$wa = @{ Left = 0; Top = 0; Right = 1920; Bottom = 1040 }

function Get-Clamped {
    [OutputType([hashtable])]
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    return (Get-ClampedPosition -X $X -Y $Y -Width $W -Height $H `
            -AreaLeft $wa.Left -AreaTop $wa.Top -AreaRight $wa.Right -AreaBottom $wa.Bottom)
}

Test-Case 'clamp: a position that already fits is untouched' {
    $c = Get-Clamped -X 900 -Y 500 -W 216 -H 68
    Assert-Equal 900 $c.X
    Assert-Equal 500 $c.Y
}

Test-Case 'clamp: a grown pill is pulled back inside the right edge' {
    # Saved flush-right for a 108px pill (1920 - 108 - 10 = 1802); the pill is
    # now 216px, so it would run 98px off the screen.
    $c = Get-Clamped -X 1802 -Y 500 -W 216 -H 68
    Assert-Equal (1920 - 216) $c.X
    Assert-Equal 500 $c.Y
}

Test-Case 'clamp: the bottom edge behaves the same way' {
    $c = Get-Clamped -X 100 -Y 1000 -W 216 -H 68
    Assert-Equal (1040 - 68) $c.Y
}

Test-Case 'clamp: a negative position is pulled in from the left and top' {
    $c = Get-Clamped -X -50 -Y -20 -W 216 -H 68
    Assert-Equal 0 $c.X
    Assert-Equal 0 $c.Y
}

Test-Case 'clamp: a pill wider than the screen is left alone, not mangled' {
    # Nothing sensible to do; refuse rather than invent a position.
    $c = Get-Clamped -X 40 -Y 500 -W 3000 -H 68
    Assert-Equal 40 $c.X
}

exit (Complete-Tests)
