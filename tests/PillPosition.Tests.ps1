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
. (Import-WidgetFunction 'Get-DisplayChangeAction')

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

exit (Complete-Tests)
