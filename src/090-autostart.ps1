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

function Get-AutoStartEnabled {
    [OutputType([bool])]
    param(
        # Shortcut to look for. Defaults to the real Startup folder; tests override it.
        [string]$ShortcutPath = ''
    )
    if (-not $ShortcutPath) { $ShortcutPath = Get-StartupShortcutPath }
    return (Test-Path $ShortcutPath)
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

