# ============================================================
# EXTERNAL I/O FAILURE REPORTING
# ============================================================

# Every external-I/O failure (disk, shell, subprocess) funnels through
# Write-IoFailure, so none of them can end as an empty catch block. A failure is
# always RECORDED (diagnostics + tests read $script:ioFailures) and, once the UI
# exists, SHOWN as a card that names the file, the reason Windows gave, and what
# the user can do about it. Notifications stay off until the tray icon is up:
# Show-BatteryNotification needs forms, and the earliest failure (config load)
# happens before there are any. Startup flushes the backlog once it enables them.
$script:ioFailures = @()
$script:ioNotifyEnabled = $false

# Warm amber: an I/O failure is a "something did not stick" warning, not the
# red reserved for a dying battery.
$script:ioFailureAccent = [System.Drawing.Color]::FromArgb(255, 170, 60)

function Write-IoFailure {
    [OutputType([void])]
    param(
        # Headline, phrased as what the user lost: "Couldn't save your settings".
        [string]$Operation,
        # The file, folder, or URL involved - so the message is actionable.
        [string]$Path = '',
        # The exception message from Windows, verbatim.
        [string]$Reason = '',
        # What the user can do next.
        [string]$Advice = ''
    )
    $parts = @()
    foreach ($p in @($Path, $Reason, $Advice)) { if ($p) { $parts += $p } }
    $detail = ($parts -join ' - ')
    $script:ioFailures += [pscustomobject]@{
        Time      = Get-Date
        Operation = $Operation
        Path      = $Path
        Reason    = $Reason
        Advice    = $Advice
        Detail    = $detail
    }
    if ($script:ioNotifyEnabled) {
        Show-BatteryNotification -Message $Operation -SubMessage $detail -Accent $script:ioFailureAccent
    }
}

function Open-ExternalLink {
    # Start-Process throws when no handler is registered for the protocol (or
    # the shell association is broken). Unhandled inside a LinkClicked handler
    # that is a hard crash of a -noConsole exe, so the click must never escape.
    [OutputType([bool])]
    param([string]$Url)
    try {
        Start-Process $Url -ErrorAction Stop
        return $true
    } catch {
        Write-IoFailure -Operation "Couldn't open the link" -Path $Url -Reason $_.Exception.Message `
            -Advice 'Type the address into your browser instead'
        return $false
    }
}

