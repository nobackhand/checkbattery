# tests\UpdateCheck.Tests.ps1
#
# The daily "is there a newer BatteryPill?" check (src\075-update-check.ps1).
# Everything that decides what the user is told is a pure function, tested
# here; the network half is a WebClient Task polled on the UI thread, which
# the live run exercises against a file:// fixture.
#
# The failure modes worth pinning: announcing a release that is NOT newer
# (1.4 vs 1.4.0, a prerelease, a junk tag), nagging about the same release
# every day, and never re-checking after one failed attempt.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'ConvertTo-AppVersion', 'Test-NewerVersion', 'ConvertFrom-ReleaseJson',
    'Test-UpdateCheckDue', 'Resolve-UpdateCheckResult', 'Get-AboutVersionText',
    'Restore-UpdateAvailability')

Write-Host 'UpdateCheck.Tests.ps1'

function New-ReleaseJson {
    [OutputType([string])]
    param(
        [string]$Tag = 'v1.5.0',
        [string]$Url = 'https://github.com/nobackhand/checkbattery/releases/tag/v1.5.0',
        [bool]$Draft = $false,
        [bool]$Prerelease = $false
    )
    return (@{ tag_name = $Tag; html_url = $Url; draft = $Draft; prerelease = $Prerelease; name = "BatteryPill $Tag" } | ConvertTo-Json)
}

# ---- versions ----

Test-Case 'version: a v-prefixed tag parses' {
    Assert-Equal '1.4.1' (ConvertTo-AppVersion -Text 'v1.4.1').ToString(3)
}

Test-Case 'version: two parts are padded, so 1.4 is the same release as 1.4.0' {
    # [version]'1.4' -lt [version]'1.4.0' is TRUE in .NET - comparing the raw
    # forms would announce 1.4.0 as an update to a user on 1.4.
    Assert-Equal $false (Test-NewerVersion -Current '1.4' -Candidate 'v1.4.0')
    Assert-Equal $false (Test-NewerVersion -Current '1.4.0' -Candidate 'v1.4')
}

Test-Case 'version: compared as numbers, not text (1.10 is newer than 1.9)' {
    Assert-Equal $true (Test-NewerVersion -Current '1.9.0' -Candidate 'v1.10.0')
    Assert-Equal $false (Test-NewerVersion -Current '1.10.0' -Candidate 'v1.9.9')
}

Test-Case 'version: only a strictly newer release counts' {
    Assert-Equal $true (Test-NewerVersion -Current '1.4.0' -Candidate 'v1.4.1')
    Assert-Equal $false (Test-NewerVersion -Current '1.4.0' -Candidate 'v1.4.0')
    Assert-Equal $false (Test-NewerVersion -Current '1.4.0' -Candidate 'v1.3.3')
}

Test-Case 'version: a tag that is not a version is never an update' {
    foreach ($junk in @('', 'latest', 'v1.5.0-beta', '1.5.0.1.2', 'v', '1..2', '99999999999.0.0')) {
        Assert-Equal $null (ConvertTo-AppVersion -Text $junk)
        Assert-Equal $false (Test-NewerVersion -Current '1.4.0' -Candidate $junk)
    }
}

# ---- the API response ----

Test-Case 'release: a normal latest-release response yields version and page' {
    $r = ConvertFrom-ReleaseJson -Json (New-ReleaseJson)
    Assert-Equal '1.5.0' $r.Version
    Assert-Equal 'https://github.com/nobackhand/checkbattery/releases/tag/v1.5.0' $r.Url
}

Test-Case 'release: drafts and prereleases are not offered' {
    Assert-Equal $null (ConvertFrom-ReleaseJson -Json (New-ReleaseJson -Draft $true))
    Assert-Equal $null (ConvertFrom-ReleaseJson -Json (New-ReleaseJson -Prerelease $true))
}

Test-Case 'release: malformed or unexpected responses mean no answer, not a crash' {
    # An HTML error page, a rate-limit body, an empty string, a JSON array.
    foreach ($bad in @('', '<html>502</html>', '{"message":"API rate limit exceeded"}', '[1,2]', 'null', '{')) {
        Assert-Equal $null (ConvertFrom-ReleaseJson -Json $bad)
    }
}

Test-Case 'release: a link outside this repo''s releases falls back to the website' {
    # The card opens whatever Url says on a click - it must only ever be ours.
    $r = ConvertFrom-ReleaseJson -Json (New-ReleaseJson -Url 'https://example.com/totally-batterypill.exe')
    Assert-Equal 'https://batterypill.com' $r.Url
    $r2 = ConvertFrom-ReleaseJson -Json (New-ReleaseJson -Url 'http://github.com/nobackhand/checkbattery/releases/tag/v1.5.0')
    Assert-Equal 'https://batterypill.com' $r2.Url
}

# ---- when to check ----

$now = [datetime]'2026-10-09T09:00:00'

Test-Case 'schedule: never checked means check now' {
    Assert-Equal $true (Test-UpdateCheckDue -LastCheck $null -Now $now)
}

Test-Case 'schedule: once a day' {
    Assert-Equal $false (Test-UpdateCheckDue -LastCheck $now.AddHours(-23) -Now $now)
    Assert-Equal $true (Test-UpdateCheckDue -LastCheck $now.AddHours(-24) -Now $now)
}

Test-Case 'schedule: a last-check stamp in the future (clock went back) checks now' {
    Assert-Equal $true (Test-UpdateCheckDue -LastCheck $now.AddDays(3) -Now $now)
}

# ---- what to tell the user ----

Test-Case 'result: a newer release is announced once' {
    $rel = @{ Version = '1.5.0'; Url = 'u' }
    $first = Resolve-UpdateCheckResult -Release $rel -CurrentVersion '1.4.0' -AnnouncedVersion $null
    Assert-Equal 'available' $first.State
    Assert-Equal $true $first.Notify
    $again = Resolve-UpdateCheckResult -Release $rel -CurrentVersion '1.4.0' -AnnouncedVersion '1.5.0'
    Assert-Equal 'available' $again.State
    Assert-Equal $false $again.Notify
}

Test-Case 'result: a release newer than the one already announced is announced too' {
    $r = Resolve-UpdateCheckResult -Release @{ Version = '1.6.0'; Url = 'u' } -CurrentVersion '1.4.0' -AnnouncedVersion '1.5.0'
    Assert-Equal $true $r.Notify
}

Test-Case 'result: up to date, and a failed check, both stay quiet' {
    $cur = Resolve-UpdateCheckResult -Release @{ Version = '1.4.0'; Url = 'u' } -CurrentVersion '1.4.0' -AnnouncedVersion $null
    Assert-Equal 'current' $cur.State
    Assert-Equal $false $cur.Notify
    $fail = Resolve-UpdateCheckResult -Release $null -CurrentVersion '1.4.0' -AnnouncedVersion $null
    Assert-Equal 'failed' $fail.State
    Assert-Equal $false $fail.Notify
}

Test-Case 'result: an up-to-date answer withdraws an earlier announcement (a pulled release)' {
    # 1.5.0 was announced, then pulled: latest is 1.4.0 again. Keeping
    # AnnouncedVersion would re-offer the pulled release after every restart.
    $r = Resolve-UpdateCheckResult -Release @{ Version = '1.4.0'; Url = 'u' } -CurrentVersion '1.4.0' -AnnouncedVersion '1.5.0'
    Assert-Equal 'current' $r.State
    Assert-Equal $null $r.Announced
    $a = Resolve-UpdateCheckResult -Release @{ Version = '1.5.0'; Url = 'u' } -CurrentVersion '1.4.0' -AnnouncedVersion $null
    Assert-Equal '1.5.0' $a.Announced
}

Test-Case 'result: no response retries soon; an unusable response counts as checked' {
    # Offline: not stamped, so the next 30-minute tick tries again.
    $off = Resolve-UpdateCheckResult -Release $null -CurrentVersion '1.4.0' -AnnouncedVersion '1.5.0' -Received $false
    Assert-Equal $false $off.Stamp
    Assert-Equal '1.5.0' $off.Announced
    # A reply with a non-version tag: retrying every 30 minutes would not
    # change the answer, so it waits for tomorrow.
    $junk = Resolve-UpdateCheckResult -Release $null -CurrentVersion '1.4.0' -AnnouncedVersion $null -Received $true
    Assert-Equal 'failed' $junk.State
    Assert-Equal $true $junk.Stamp
}

Test-Case 'result: a dev build AHEAD of the latest release is up to date' {
    $r = Resolve-UpdateCheckResult -Release @{ Version = '1.4.0'; Url = 'u' } -CurrentVersion '1.4.1' -AnnouncedVersion $null
    Assert-Equal 'current' $r.State
}

Test-Case 'about: the version line says what the last check found' {
    Assert-Equal 'Version 1.4.0' (Get-AboutVersionText -Version '1.4.0' -State 'idle' -Available $null)
    Assert-Equal 'Version 1.4.0' (Get-AboutVersionText -Version '1.4.0' -State 'failed' -Available $null)
    Assert-Equal 'Version 1.4.0 - up to date' (Get-AboutVersionText -Version '1.4.0' -State 'current' -Available $null)
    Assert-Equal 'Version 1.4.0 - 1.5.0 is available' (Get-AboutVersionText -Version '1.4.0' -State 'available' -Available @{ Version = '1.5.0' })
}

Test-Case 'restart: an announced release still newer than this build stays on offer' {
    $r = Restore-UpdateAvailability -CurrentVersion '1.4.0' -AnnouncedVersion '1.5.0'
    Assert-Equal '1.5.0' $r.Version
    Assert-True ($r.Url -like 'https://github.com/nobackhand/checkbattery/releases/*')
}

Test-Case 'restart: once the user has upgraded, nothing is offered' {
    Assert-Equal $null (Restore-UpdateAvailability -CurrentVersion '1.5.0' -AnnouncedVersion '1.5.0')
    Assert-Equal $null (Restore-UpdateAvailability -CurrentVersion '1.4.0' -AnnouncedVersion $null)
    Assert-Equal $null (Restore-UpdateAvailability -CurrentVersion '1.4.0' -AnnouncedVersion 'garbage')
}

exit (Complete-Tests)
