# tests\UpdateFlow.Tests.ps1
#
# The stateful half of the update check (src\075-update-check.ps1): what
# Complete-UpdateCheck, Show-PendingUpdateCard and Set-UpdateCheckEnabled do
# to config, the offer and the card. The download is a real Task (completed,
# faulted or still running) standing in for UpdateFetch; Save-Config, the card
# and fullscreen detection are stubs that record what happened.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Complete-UpdateCheck', 'Show-PendingUpdateCard', 'Set-UpdateCheckEnabled',
    'Clear-UpdateRequest', 'Update-UpdateMenuItems', 'Resolve-UpdateCheckResult', 'ConvertFrom-ReleaseJson',
    'ConvertTo-AppVersion', 'Test-NewerVersion', 'Restore-UpdateAvailability')
Add-Type -AssemblyName System.Drawing

Write-Host 'UpdateFlow.Tests.ps1'

# ---- stubs ----
function Save-Config { [OutputType([void])] param() $script:saves++ }
function Show-BatteryNotification {
    [OutputType([void])]
    param([string]$Message, [string]$SubMessage, [System.Drawing.Color]$Accent, [int]$HoldSeconds, [string]$ClickUrl)
    $null = $script:cards.Add(@{ Message = $Message; ClickUrl = $ClickUrl })
}
function Test-FullscreenApp { [OutputType([bool])] param() return $script:fakeFullscreen }

$releaseJson = '{"tag_name":"v1.5.0","html_url":"https://github.com/nobackhand/checkbattery/releases/tag/v1.5.0","draft":false,"prerelease":false}'
$earlier = [datetime]'2026-10-08T09:00:00'

function Reset-Flow {
    [OutputType([void])]
    param([AllowNull()][AllowEmptyString()][string]$Announced = $null)
    # ([string] turns a $null argument into '' - the app's config holds a real $null)
    $ann = if ($Announced) { $Announced } else { $null }
    $script:config = @{ CheckForUpdates = $true; LastUpdateCheck = $earlier; AnnouncedVersion = $ann }
    $script:appVersion = '1.4.0'
    $script:updateMenuItems = @()
    $script:updatePollTimer = $null
    $script:updateAvailable = $null
    $script:pendingUpdateCard = $null
    $script:updateCheckState = 'checking'
    $script:updateWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:saves = 0
    $script:cards = New-Object System.Collections.ArrayList
    $script:fakeFullscreen = $false
}

function Set-Download {
    # 'ok' = a finished download of $Json, 'offline' = faulted, 'running' = not done
    [OutputType([void])]
    param([string]$Kind, [string]$Json = '')
    $tcs = New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
    if ($Kind -eq 'ok') { $tcs.SetResult($Json) }
    elseif ($Kind -eq 'offline') { $tcs.SetException((New-Object System.Net.WebException 'The remote name could not be resolved')) }
    $script:updateTask = $tcs.Task
}

Test-Case 'flow: a newer release shows ONE card, offers it, and is recorded as announced' {
    Reset-Flow
    Set-Download -Kind ok -Json $releaseJson
    Complete-UpdateCheck
    Assert-Equal 'available' $script:updateCheckState
    Assert-Equal 1 $script:cards.Count
    Assert-Equal 'https://github.com/nobackhand/checkbattery/releases/tag/v1.5.0' $script:cards[0].ClickUrl
    Assert-Equal '1.5.0' $script:updateAvailable.Version
    Assert-Equal '1.5.0' $script:config.AnnouncedVersion
    Assert-True ($script:config.LastUpdateCheck -gt $earlier) 'today''s check was not stamped'
    Assert-Equal $null $script:updateTask
}

Test-Case 'flow: the same release on a later day is offered quietly - no second card' {
    Reset-Flow -Announced '1.5.0'
    Set-Download -Kind ok -Json $releaseJson
    Complete-UpdateCheck
    Assert-Equal 0 $script:cards.Count
    Assert-Equal '1.5.0' $script:updateAvailable.Version
}

Test-Case 'flow: during a fullscreen game the card waits, and today stays unstamped' {
    Reset-Flow
    $script:fakeFullscreen = $true
    Set-Download -Kind ok -Json $releaseJson
    Complete-UpdateCheck
    Assert-Equal 0 $script:cards.Count
    Assert-Equal $null $script:config.AnnouncedVersion
    Assert-Equal '1.5.0' $script:pendingUpdateCard.Version
    # Unstamped: a restart before the card is seen re-checks instead of
    # waiting a day with nothing on offer.
    Assert-Equal $earlier $script:config.LastUpdateCheck
}

Test-Case 'flow: the held card shows once the game is gone, and only then counts as announced' {
    Reset-Flow
    $script:fakeFullscreen = $true
    Set-Download -Kind ok -Json $releaseJson
    Complete-UpdateCheck
    $script:fakeFullscreen = $false
    Show-PendingUpdateCard
    Assert-Equal 1 $script:cards.Count
    Assert-Equal '1.5.0' $script:config.AnnouncedVersion
    Assert-Equal $null $script:pendingUpdateCard
    Show-PendingUpdateCard
    Assert-Equal 1 $script:cards.Count
}

Test-Case 'flow: an offline check changes nothing and is not stamped' {
    Reset-Flow -Announced '1.5.0'
    $script:updateAvailable = @{ Version = '1.5.0'; Url = 'u' }
    Set-Download -Kind offline
    Complete-UpdateCheck
    Assert-Equal 'failed' $script:updateCheckState
    Assert-Equal $earlier $script:config.LastUpdateCheck
    Assert-Equal '1.5.0' $script:config.AnnouncedVersion
    Assert-Equal '1.5.0' $script:updateAvailable.Version
    Assert-Equal 0 $script:saves
}

Test-Case 'flow: a download still running just waits; a stuck one is abandoned' {
    Reset-Flow
    Set-Download -Kind running
    Complete-UpdateCheck
    Assert-True ($null -ne $script:updateTask) 'a running download was dropped early'
    $script:updateWatch = $null   # stands in for "more than 30 seconds"
    Complete-UpdateCheck
    Assert-Equal 'failed' $script:updateCheckState
    Assert-Equal $null $script:updateTask
}

Test-Case 'flow: an up-to-date answer withdraws an offer the app was holding' {
    Reset-Flow -Announced '1.5.0'
    $script:updateAvailable = @{ Version = '1.5.0'; Url = 'u' }
    Set-Download -Kind ok -Json '{"tag_name":"v1.4.0","html_url":"https://github.com/nobackhand/checkbattery/releases/tag/v1.4.0","draft":false,"prerelease":false}'
    Complete-UpdateCheck
    Assert-Equal 'current' $script:updateCheckState
    Assert-Equal $null $script:updateAvailable
    Assert-Equal $null $script:config.AnnouncedVersion
}

Test-Case 'flow: switching checks off hides the offer; switching on brings it back' {
    Reset-Flow -Announced '1.5.0'
    $script:updateAvailable = @{ Version = '1.5.0'; Url = 'u' }
    $script:pendingUpdateCard = @{ Version = '1.5.0'; Url = 'u' }
    Set-UpdateCheckEnabled -Enabled $false
    Assert-Equal $false $script:config.CheckForUpdates
    Assert-Equal $null $script:updateAvailable
    Assert-Equal $null $script:pendingUpdateCard
    Set-UpdateCheckEnabled -Enabled $true
    Assert-Equal '1.5.0' $script:updateAvailable.Version
    Assert-Equal 'available' $script:updateCheckState
}

exit (Complete-Tests)
