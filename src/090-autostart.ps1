# ============================================================
# AUTO-START WITH WINDOWS
# ============================================================

function Get-ExePath {
    [OutputType([string])]
    param()
    # Get the path of the current executable or script. MainModule throws when
    # the process cannot read its own image path; treat that as script mode
    # (no shortcut) rather than letting it escape into the Settings click.
    try {
        $process = [System.Diagnostics.Process]::GetCurrentProcess()
        $exePath = $process.MainModule.FileName
    } catch {
        return $null
    }
    # If running as script, use PowerShell with script path
    if ($exePath -like "*powershell*" -or $exePath -like "*pwsh*") {
        return $null  # Can't create shortcut for script mode
    }
    return $exePath
}

function Get-StartupShortcutPath {
    [OutputType([string])]
    param()
    return (Join-Path ([Environment]::GetFolderPath('Startup')) "BatteryPill.lnk")
}

function Get-AutoStartTarget {
    [OutputType([string])]
    param(
        # Shortcut to read. Defaults to the real Startup folder; tests override it.
        [string]$ShortcutPath = ''
    )
    # The path a startup shortcut points at, or '' when there is no shortcut
    # or it cannot be read.
    if (-not $ShortcutPath) { $ShortcutPath = Get-StartupShortcutPath }
    if (-not (Test-Path $ShortcutPath)) { return '' }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $target = $shell.CreateShortcut($ShortcutPath).TargetPath
        if ($null -eq $target) { return '' }
        return [string]$target
    } catch {
        return ''
    }
}

function Get-AutoStartEnabled {
    [OutputType([bool])]
    param(
        # Shortcut to look for. Defaults to the real Startup folder; tests override it.
        [string]$ShortcutPath = ''
    )
    # "Enabled" means BatteryPill will actually START, not merely that a .lnk
    # file exists. The old bare Test-Path reported the checkbox as ON while
    # the shortcut pointed at a deleted exe: the app ships as
    # BatteryPill-<version>.exe, so updating leaves the previous target
    # missing, auto-start silently stops working, and Settings keeps
    # insisting it is on. A checkbox that lies is worse than one that is off.
    if (-not $ShortcutPath) { $ShortcutPath = Get-StartupShortcutPath }
    if (-not (Test-Path $ShortcutPath)) { return $false }
    $target = Get-AutoStartTarget -ShortcutPath $ShortcutPath
    # An unreadable shortcut (locked by another process, or an unexpected
    # format) is still a shortcut sitting in the Startup folder, and Windows
    # will most likely act on it at logon. Only a target we can actually READ,
    # and that is GONE, proves the feature is broken - so that is the only
    # case that reports "off".
    if (-not $target) { return $true }
    return (Test-Path -LiteralPath $target)
}

function Repair-AutoStartShortcut {
    [OutputType([bool])]
    param(
        # Shortcut to repair. Defaults to the real Startup folder; tests override it.
        [string]$ShortcutPath = '',
        # Exe to point at. Defaults to the running one; tests override it.
        [string]$ExePath = ''
    )
    # Self-heal a shortcut whose target no longer exists - the update case.
    # Deliberately narrow: only a MISSING target is repaired, never one that
    # merely differs, so running an older build on purpose does not silently
    # re-point the user's shortcut. Returns $true if a repair was made.
    if (-not $ShortcutPath) { $ShortcutPath = Get-StartupShortcutPath }
    $target = Get-AutoStartTarget -ShortcutPath $ShortcutPath
    if (-not $target) { return $false }
    if (Test-Path -LiteralPath $target) { return $false }
    if (-not $ExePath) { $ExePath = Get-ExePath }
    if ($null -eq $ExePath -or -not $ExePath) { return $false }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $ExePath
        $shortcut.WorkingDirectory = Split-Path $ExePath
        $shortcut.Description = "BatteryPill - Battery Widget"
        $shortcut.Save()
        return $true
    } catch {
        return $false
    }
}

function Set-AutoStart {
    [OutputType([bool])]
    param(
        [bool]$Enable,
        # Shortcut to create/remove. Defaults to the real Startup folder; tests override it.
        [string]$ShortcutPath = ''
    )
    if (-not $ShortcutPath) { $ShortcutPath = Get-StartupShortcutPath }

    if ($Enable) {
        $exePath = Get-ExePath
        if ($null -eq $exePath) {
            Show-BatteryNotification -Message "Auto-start needs the .exe" `
                -SubMessage "This works when you run the compiled BatteryPill.exe, not the script." `
                -Accent ([System.Drawing.Color]::FromArgb(45, 212, 100))
            return $false
        }

        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($ShortcutPath)
            $shortcut.TargetPath = $exePath
            $shortcut.WorkingDirectory = Split-Path $exePath
            $shortcut.Description = "BatteryPill - Battery Widget"
            $shortcut.Save()
            return $true
        } catch {
            Write-IoFailure -Operation "Couldn't turn on auto-start" -Path $ShortcutPath `
                -Reason $_.Exception.Message `
                -Advice 'Windows blocked the startup shortcut - try launching BatteryPill once as administrator'
            return $false
        }
    } else {
        if (Test-Path $ShortcutPath) {
            try {
                # -ErrorAction Stop: Remove-Item's failures are non-terminating,
                # so the catch never fired and the checkbox flipped to "off"
                # while the shortcut survived - BatteryPill kept starting with
                # Windows and nothing ever said why.
                Remove-Item $ShortcutPath -Force -ErrorAction Stop
                return $true
            } catch {
                Write-IoFailure -Operation "Couldn't turn off auto-start" -Path $ShortcutPath `
                    -Reason $_.Exception.Message `
                    -Advice 'BatteryPill will still start with Windows - delete this shortcut from your Startup folder'
                return $false
            }
        }
        return $true
    }
}

