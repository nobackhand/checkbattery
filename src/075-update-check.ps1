# ============================================================
# UPDATE CHECK
# ============================================================

# BatteryPill ships as a downloaded exe with no installer, so nothing told a
# user that a newer build existed - "am I on the latest version?" had no
# answer short of comparing About against the website. Once a day (opt-out
# in Settings) the app asks GitHub's public releases API for the latest
# release. Nothing about the user or the PC is sent beyond the request.
#
# Threading: a PowerShell scriptblock must run on the thread that owns its
# runspace, so there is no completion callback. The download is a Task that a
# Forms.Timer polls on the UI thread; nothing ever runs on a pool thread.

$script:updateCheckUri = 'https://api.github.com/repos/nobackhand/checkbattery/releases/latest'
$script:updateAvailable = $null    # @{ Version; Url } once a newer release is seen
$script:updateCheckState = 'idle'  # idle | checking | current | available | failed
$script:updateClient = $null
$script:updateTask = $null
$script:updateStarted = $null
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
    # Once a day. Only a SUCCESSFUL check is stamped, so a laptop that boots
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
        [AllowNull()][AllowEmptyString()][string]$NotifiedVersion
    )
    # What one finished check means. State: 'available', 'current', or
    # 'failed' (no usable release - offline, rate-limited, junk). Notify is
    # true only the FIRST time a given version is seen: the card says it
    # once, the menu item and About keep saying it quietly.
    if ($null -eq $Release) { return @{ State = 'failed'; Notify = $false } }
    if (-not (Test-NewerVersion -Current $CurrentVersion -Candidate $Release.Version)) {
        return @{ State = 'current'; Notify = $false }
    }
    return @{ State = 'available'; Notify = ($NotifiedVersion -ne $Release.Version) }
}

function Get-AboutVersionText {
    [OutputType([string])]
    param(
        [string]$Version,
        [string]$State,
        [AllowNull()][hashtable]$Available
    )
    # The About dialog's version line, saying what the last check found.
    if ($State -eq 'available' -and $null -ne $Available) {
        return "Version $Version - $($Available.Version) is available"
    }
    if ($State -eq 'current') { return "Version $Version - up to date" }
    return "Version $Version"
}

function Restore-UpdateAvailability {
    [OutputType([hashtable])]
    param(
        [string]$CurrentVersion,
        [AllowNull()][AllowEmptyString()][string]$NotifiedVersion
    )
    # After a restart the last check's answer is gone, and the next check can
    # be up to a day away. A release the card already announced that is still
    # newer than this build IS the answer - keep offering it from the menu
    # until the user upgrades.
    if (-not (Test-NewerVersion -Current $CurrentVersion -Candidate $NotifiedVersion)) { return $null }
    return @{
        Version = (ConvertTo-AppVersion -Text $NotifiedVersion).ToString(3)
        Url     = 'https://github.com/nobackhand/checkbattery/releases/latest'
    }
}

function Clear-UpdateRequest {
    [OutputType([void])]
    param()
    if ($null -ne $script:updatePollTimer) { $script:updatePollTimer.Stop() }
    if ($null -ne $script:updateClient) {
        try { $script:updateClient.Dispose() } catch {}
    }
    $script:updateClient = $null
    $script:updateTask = $null
    $script:updateStarted = $null
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

function Start-UpdateCheck {
    [OutputType([void])]
    param()
    if (-not $script:config.CheckForUpdates) { return }
    if ($null -ne $script:updateTask) { return }   # one request at a time
    try {
        # api.github.com is TLS 1.2+, which .NET Framework does not offer by
        # default on every Windows build it runs on.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        # The API refuses requests without a User-Agent
        $wc.Headers.Add('User-Agent', "BatteryPill/$script:appVersion")
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $script:updateClient = $wc
        $script:updateStarted = Get-Date
        $script:updateTask = $wc.DownloadStringTaskAsync([uri]$script:updateCheckUri)
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
        if (((Get-Date) - $script:updateStarted).TotalSeconds -gt 30) {
            try { $script:updateClient.CancelAsync() } catch {}
            $script:updateCheckState = 'failed'
            Clear-UpdateRequest
        }
        return
    }
    $json = $null
    if ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { $json = $task.Result }
    Clear-UpdateRequest
    $release = ConvertFrom-ReleaseJson -Json $json
    $result = Resolve-UpdateCheckResult -Release $release -CurrentVersion $script:appVersion `
        -NotifiedVersion $script:config.AnnouncedVersion
    $script:updateCheckState = $result.State
    if ($result.State -eq 'failed') { return }
    $script:config.LastUpdateCheck = Get-Date
    if ($result.State -eq 'available') {
        $script:updateAvailable = $release
        if ($result.Notify) { $script:config.AnnouncedVersion = $release.Version }
    } else {
        $script:updateAvailable = $null
    }
    Save-Config
    Update-UpdateMenuItems
    if ($result.Notify) {
        Show-BatteryNotification -Message "BatteryPill $($release.Version) is out" `
            -SubMessage "You have $script:appVersion. Click here to get the new one." `
            -Accent ([System.Drawing.Color]::FromArgb(45, 212, 100)) -HoldSeconds 12 -ClickUrl $release.Url
    }
}
