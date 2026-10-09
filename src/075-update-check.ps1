# ============================================================
# UPDATE CHECK
# ============================================================

# BatteryPill ships as a downloaded exe with no installer, so nothing told a
# user that a newer build existed - "am I on the latest version?" had no
# answer short of comparing About against the website. Once a day (opt-out
# in Settings) the app asks GitHub's public releases API for the latest
# release. GitHub sees that request like any web visit; nothing else is sent.
#
# Threading: a PowerShell scriptblock must run on the thread that owns its
# runspace, so there is no completion callback. The download runs entirely
# on a pool thread in C# (UpdateFetch, 010-init) and a Forms.Timer polls its
# Task on the UI thread.

$script:updateCheckUri = 'https://api.github.com/repos/nobackhand/checkbattery/releases/latest'
$script:updateAvailable = $null    # @{ Version; Url } once a newer release is seen
$script:updateCheckState = 'idle'  # idle | checking | current | available | failed
$script:updateTask = $null
$script:updateWatch = $null        # Stopwatch: the timeout must survive a clock change
$script:pendingUpdateCard = $null  # a release to announce once no game is fullscreen
$script:updateMenuItems = @()

function ConvertTo-AppVersion {
    [OutputType([version])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    # "v1.4.1", "1.4.1", "1.4" -> a three-part [version]; $null for anything
    # that is not a plain dotted version. Normalised to three parts because
    # [version]'1.4' -lt [version]'1.4.0' is TRUE (an unset Build is -1), so
    # comparing the raw forms would call 1.4.0 an update to 1.4.
    if (-not $Text) { return $null }
    $t = $Text.Trim()
    if ($t -match '^[vV]') { $t = $t.Substring(1) }
    if ($t -notmatch '^\d{1,9}(\.\d{1,9}){0,2}$') { return $null }
    $parts = @($t.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 3) { $parts += 0 }
    return (New-Object System.Version($parts[0], $parts[1], $parts[2]))
}

function Test-NewerVersion {
    [OutputType([bool])]
    param([string]$Current, [string]$Candidate)
    # True only when BOTH parse and the candidate is strictly newer: a tag we
    # cannot read is never announced as an update.
    $c = ConvertTo-AppVersion -Text $Current
    $n = ConvertTo-AppVersion -Text $Candidate
    if ($null -eq $c -or $null -eq $n) { return $false }
    return ($n -gt $c)
}

function ConvertFrom-ReleaseJson {
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyString()][string]$Json)
    # The latest-release response reduced to what the app acts on:
    # @{ Version = '1.4.1'; Url = <release page> }, or $null when it is not a
    # usable stable release (malformed, a draft or prerelease, or a tag that
    # is not a version). Url is only ever this repo's own release page or the
    # website - never an arbitrary link taken from the response.
    if (-not $Json) { return $null }
    try { $r = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $r -or $r -is [array]) { return $null }
    if ($r.draft -eq $true -or $r.prerelease -eq $true) { return $null }
    $v = ConvertTo-AppVersion -Text ([string]$r.tag_name)
    if ($null -eq $v) { return $null }
    $url = [string]$r.html_url
    if ($url -notmatch '^https://github\.com/nobackhand/checkbattery/releases/') { $url = 'https://batterypill.com' }
    return @{ Version = $v.ToString(3); Url = $url }
}

function Test-UpdateCheckDue {
    [OutputType([bool])]
    param(
        [AllowNull()][Nullable[datetime]]$LastCheck,
        [datetime]$Now,
        [double]$IntervalHours = 24
    )
    # Once a day. A failed DOWNLOAD is not stamped, so a laptop that boots
    # before its Wi-Fi is up retries on the next schedule tick instead of
    # waiting a day. A stamp in the future means the clock moved backwards
    # (or the stamp is junk) - check rather than wait it out.
    if ($null -eq $LastCheck) { return $true }
    # (PowerShell unwraps Nullable[datetime]: $LastCheck is a plain DateTime
    # here, with no .Value)
    $age = ($Now - [datetime]$LastCheck).TotalHours
    if ($age -lt 0) { return $true }
    return ($age -ge $IntervalHours)
}

function Resolve-UpdateCheckResult {
    [OutputType([hashtable])]
    param(
        [AllowNull()][hashtable]$Release,
        [string]$CurrentVersion,
        [AllowNull()][AllowEmptyString()][string]$AnnouncedVersion,
        # Whether a response arrived at all (vs. offline / timed out / HTTP error)
        [bool]$Received = $true
    )
    # What one finished check means:
    #   State     'available' | 'current' | 'failed'
    #   Notify    true only the FIRST time a given version is seen - the card
    #             says it once; the menu item and About keep saying it quietly
    #   Announced what AnnouncedVersion should hold afterwards. A 'current'
    #             answer clears it: a release that was announced and then
    #             pulled must stop being offered after a restart.
    #   Stamp     whether this counts as today's check. A response that
    #             arrived but held no usable release (a non-version tag) is
    #             stamped too - retrying it every 30 minutes forever would
    #             not change the answer. Only no-response retries soon.
    if ($null -eq $Release) {
        return @{ State = 'failed'; Notify = $false; Announced = $AnnouncedVersion; Stamp = $Received }
    }
    if (-not (Test-NewerVersion -Current $CurrentVersion -Candidate $Release.Version)) {
        return @{ State = 'current'; Notify = $false; Announced = $null; Stamp = $true }
    }
    $notify = ($AnnouncedVersion -ne $Release.Version)
    return @{ State = 'available'; Notify = $notify; Announced = $Release.Version; Stamp = $true }
}

function Get-AboutVersionText {
    [OutputType([string])]
    param(
        [string]$Version,
        [string]$State,
        [AllowNull()][hashtable]$Available
    )
    # The About dialog's version line. An offer on hand wins whatever the
    # LAST check did: an offline check must not make About forget a release
    # the menus are still offering.
    if ($null -ne $Available) {
        return "Version $Version - $($Available.Version) is available"
    }
    if ($State -eq 'current') { return "Version $Version - up to date" }
    return "Version $Version"
}

function Restore-UpdateAvailability {
    [OutputType([hashtable])]
    param(
        [string]$CurrentVersion,
        [AllowNull()][AllowEmptyString()][string]$AnnouncedVersion
    )
    # After a restart the last check's answer is gone, and the next check can
    # be up to a day away. A release the card already announced that is still
    # newer than this build IS the answer - keep offering it from the menu
    # until the user upgrades.
    if (-not (Test-NewerVersion -Current $CurrentVersion -Candidate $AnnouncedVersion)) { return $null }
    return @{
        Version = (ConvertTo-AppVersion -Text $AnnouncedVersion).ToString(3)
        Url     = 'https://github.com/nobackhand/checkbattery/releases/latest'
    }
}

function Clear-UpdateRequest {
    [OutputType([void])]
    param()
    # Drops the in-flight request. The pool-thread download cannot be
    # cancelled, but nothing reads its result once this reference is gone.
    if ($null -ne $script:updatePollTimer) { $script:updatePollTimer.Stop() }
    $script:updateTask = $null
    $script:updateWatch = $null
}

function Update-UpdateMenuItems {
    [OutputType([void])]
    param()
    # The "Get BatteryPill x.y.z" entries in both context menus: hidden until
    # a check has found something newer.
    foreach ($item in $script:updateMenuItems) {
        if ($null -eq $item) { continue }
        if ($null -ne $script:updateAvailable) {
            $item.Text = "Get BatteryPill $($script:updateAvailable.Version)"
            $item.Visible = $true
        } else {
            $item.Visible = $false
        }
    }
}

function Set-UpdateCheckEnabled {
    [OutputType([void])]
    param([bool]$Enabled)
    # The Settings toggle. Off means off: no checks, and no "update
    # available" anywhere - not even an offer an earlier check already found.
    $script:config.CheckForUpdates = $Enabled
    if ($Enabled) {
        $script:updateAvailable = Restore-UpdateAvailability -CurrentVersion $script:appVersion `
            -AnnouncedVersion $script:config.AnnouncedVersion
        $script:updateCheckState = if ($null -ne $script:updateAvailable) { 'available' } else { 'idle' }
    } else {
        Clear-UpdateRequest
        $script:updateAvailable = $null
        $script:pendingUpdateCard = $null
        $script:updateCheckState = 'idle'
    }
    Update-UpdateMenuItems
    Save-Config
}

function Show-PendingUpdateCard {
    [OutputType([void])]
    param()
    # Announce a found release - but not over a fullscreen game or video,
    # where nobody would see it and it would still count as said. It waits
    # for the next schedule tick instead.
    $rel = $script:pendingUpdateCard
    if ($null -eq $rel) { return }
    $fullscreen = $false
    try { $fullscreen = Test-FullscreenApp } catch { $fullscreen = $false }
    if ($fullscreen) { return }
    $script:pendingUpdateCard = $null
    $script:config.AnnouncedVersion = $rel.Version
    Save-Config
    Show-BatteryNotification -Message "BatteryPill $($rel.Version) is out" `
        -SubMessage "You have $script:appVersion. Click here to get the new one." `
        -Accent ([System.Drawing.Color]::FromArgb(45, 212, 100)) -HoldSeconds 12 -ClickUrl $rel.Url
}

function Start-UpdateCheck {
    [OutputType([void])]
    param()
    if (-not $script:config.CheckForUpdates) { return }
    if ($null -ne $script:updateTask) { return }   # one request at a time
    try {
        # api.github.com is TLS 1.2+, which .NET Framework does not offer by
        # default on every Windows build it runs on.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $script:updateWatch = [System.Diagnostics.Stopwatch]::StartNew()
        # The API refuses requests without a User-Agent
        $script:updateTask = [UpdateFetch]::Start($script:updateCheckUri, "BatteryPill/$script:appVersion")
        $script:updateCheckState = 'checking'
        $script:updatePollTimer.Start()
    } catch {
        $script:updateCheckState = 'failed'
        Clear-UpdateRequest
    }
}

function Complete-UpdateCheck {
    [OutputType([void])]
    param()
    # Poll-timer tick: nothing to do until the download finishes (or takes
    # too long). A failure is deliberately silent - being offline is normal,
    # and the next schedule tick simply tries again.
    $task = $script:updateTask
    if ($null -eq $task) { Clear-UpdateRequest; return }
    if (-not $task.IsCompleted) {
        if ($null -eq $script:updateWatch -or $script:updateWatch.Elapsed.TotalSeconds -gt 30) {
            $script:updateCheckState = 'failed'
            Clear-UpdateRequest
        }
        return
    }
    $received = ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion)
    $json = if ($received) { $task.Result } else { $null }
    Clear-UpdateRequest
    $release = ConvertFrom-ReleaseJson -Json $json
    $result = Resolve-UpdateCheckResult -Release $release -CurrentVersion $script:appVersion `
        -AnnouncedVersion $script:config.AnnouncedVersion -Received $received
    $script:updateCheckState = $result.State
    if (-not $result.Stamp) { return }
    $script:config.LastUpdateCheck = Get-Date
    if ($result.State -eq 'available') {
        $script:updateAvailable = $release
    } elseif ($result.State -eq 'current') {
        $script:updateAvailable = $null
        $script:pendingUpdateCard = $null
        $script:config.AnnouncedVersion = $result.Announced
    }
    Save-Config
    Update-UpdateMenuItems
    if ($result.Notify) {
        # AnnouncedVersion is written when the card is actually SHOWN
        $script:pendingUpdateCard = $release
        Show-PendingUpdateCard
    }
}
