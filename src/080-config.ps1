# ============================================================
# FLOATING BAR — POSITION PERSISTENCE
# ============================================================

function Get-ConfigPath {
    [OutputType([string])]
    param()
    $dir = $PSScriptRoot
    # MainModule throws (Win32Exception/InvalidOperation) when the process token
    # cannot read its own image path. Unguarded that killed startup outright,
    # before any window existed to report it.
    if (-not $dir) {
        try { $dir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
        catch { $dir = '' }
    }
    if (-not $dir) { $dir = $PWD.Path }
    return Join-Path $dir "BatteryWidget.config.json"
}

function Read-ConfigField {
    # Parse ONE config field in isolation. Previously every field was parsed
    # inside a single try block, so one malformed value (a string where a
    # number belongs, a hand-edit typo) threw and silently discarded every
    # field after it - the user's theme, accent, and size quietly reset.
    # $Parse returning $null means "present but invalid" -> use the fallback.
    [OutputType([object])]
    param(
        # any-typed: one raw JSON field - string, number, bool or $null.
        [AllowNull()][object]$Raw,
        [scriptblock]$Parse,
        # any-typed: the caller's default for this field, whatever its type.
        [AllowNull()][object]$Fallback
    )
    if ($null -eq $Raw) { return $Fallback }
    try {
        $parsed = & $Parse $Raw
        if ($null -eq $parsed) { return $Fallback }
        return $parsed
    } catch {
        return $Fallback
    }
}

function Read-TextFileShared {
    <#
    .SYNOPSIS
        Reads a whole text file, tolerating a writer that is mid-swap.

    .DESCRIPTION
        The other half of Write-TextFileAtomic. Swapping the new file in is a
        rename, and a rename briefly cannot happen while someone holds the old
        file open - so both sides can lose the coin toss: the reader gets
        "the process cannot access the file", the writer gets a sharing
        violation. Import-Config could not tell that transient collision apart
        from a corrupt file: it reset every setting to defaults and quarantined
        a perfectly good config as .corrupt.

        So: open with FileShare.Delete (so a pending rename is not blocked BY
        this read) and retry a locked file a few times. Only a file we still
        cannot open after that, or one that will not parse, is a real failure.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Attempts = 12
    )
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $lastErr = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            try {
                $reader = New-Object System.IO.StreamReader($stream, $true)
                return $reader.ReadToEnd()
            } finally { $stream.Dispose() }
        } catch [System.IO.IOException] {
            $lastErr = $_
            Start-Sleep -Milliseconds (5 * $attempt)
        }
    }
    throw $lastErr
}

function ConvertTo-ConfigBool {
    <#
    .SYNOPSIS
        Reads one JSON boolean field, tolerating the string spellings.

    .DESCRIPTION
        [bool]"false" is $true in PowerShell - every non-empty string is - so a
        config holding "false" (a hand edit, or another tool's writer) turned
        the setting ON. Accept real booleans and numbers, accept the obvious
        string spellings case-insensitively, and return $null ("no reading",
        which Read-ConfigField turns into the caller's default) for the rest
        rather than guessing.
    #>
    [OutputType([object])]
    param(
        # any-typed: one raw JSON field - bool, string, number, or $null.
        [AllowNull()][object]$Raw
    )
    if ($null -eq $Raw) { return $null }
    if ($Raw -is [bool]) { return $Raw }
    if ($Raw -is [string]) {
        switch -Regex ($Raw.Trim()) {
            '^(?i:true|yes|1)$' { return $true }
            '^(?i:false|no|0)$' { return $false }
            default { return $null }
        }
    }
    $num = 0.0
    try { $num = [double]$Raw } catch { return $null }
    if ([double]::IsNaN($num)) { return $null }
    return ($num -ne 0)
}

function Import-Config {
    [OutputType([hashtable])]
    param(
        # Config file to read. Defaults to the app's own file; tests override it.
        [string]$Path = ''
    )
    $configPath = if ($Path) { $Path } else { Get-ConfigPath }
    $default = @{
        X                  = -1
        Y                  = -1
        Opacity            = 0.85
        RefreshInterval    = 3000
        PositionLocked     = $false
        DisplayMode        = "time"
        PillSize           = "normal"
        Theme              = "dark"
        AccentColorIndex   = 0
        AutoHideFullscreen = $false
        FirstRunShown      = $false
        BatteryHistory     = @()
        EmaRate            = -1
        LastValidRate      = -1
        ConfigSavedAt      = $null
    }
    if (Test-Path $configPath) {
        try {
            $raw = Read-TextFileShared -Path $configPath
            # An empty file yields $null, exactly as `Get-Content -Raw` did:
            # every field then falls back, with nothing reported.
            $json = if ([string]::IsNullOrWhiteSpace($raw)) { $null } else { $raw | ConvertFrom-Json -ErrorAction Stop }

            # Position is a pair: take it only if BOTH coordinates parse
            $xv = Read-ConfigField -Raw $json.X -Fallback $null -Parse { param($r) [int]$r }
            $yv = Read-ConfigField -Raw $json.Y -Fallback $null -Parse { param($r) [int]$r }
            if ($null -ne $xv -and $null -ne $yv) { $default.X = $xv; $default.Y = $yv }

            # NaN survives the clamp - [math]::Max/Min propagate it, because
            # every comparison against NaN is false - and WinForms accepts it
            # on Form.Opacity without complaint (verified: the property keeps
            # NaN). From there nothing recovers it: the slider's arithmetic and
            # the low-battery opacity oscillation all stay NaN, and the config
            # is saved back as NaN. Reject it before the clamp.
            $default.Opacity = Read-ConfigField -Raw $json.Opacity -Fallback $default.Opacity -Parse {
                param($r)
                $o = [double]$r
                if ([double]::IsNaN($o)) { return $null }
                [math]::Max(0.3, [math]::Min(1.0, $o)) }
            # Clamp: 0/negative would throw at Timer.Interval assignment and leave
            # the WinForms default of 100ms - a WMI query 10x/second
            $default.RefreshInterval = Read-ConfigField -Raw $json.RefreshInterval -Fallback $default.RefreshInterval -Parse {
                param($r) [math]::Max(1000, [math]::Min(60000, [int]$r)) }
            # ConvertTo-Json writes real JSON booleans, but a hand-edited file
            # (or one written by another tool) can hold the STRING "false" -
            # and in PowerShell [bool]"false" is $true, because any non-empty
            # string is truthy. That silently inverted the setting. Parse the
            # string form explicitly and reject anything else as "no reading".
            $default.PositionLocked = Read-ConfigField -Raw $json.PositionLocked -Fallback $default.PositionLocked -Parse {
                param($r) ConvertTo-ConfigBool -Raw $r }
            $default.DisplayMode = Read-ConfigField -Raw $json.DisplayMode -Fallback $default.DisplayMode -Parse {
                param($r) if ([string]$r -in @("time", "percent", "both")) { [string]$r } else { $null } }
            $default.PillSize = Read-ConfigField -Raw $json.PillSize -Fallback $default.PillSize -Parse {
                param($r) if ([string]$r -in @("compact", "normal", "expanded")) { [string]$r } else { $null } }
            $default.Theme = Read-ConfigField -Raw $json.Theme -Fallback $default.Theme -Parse {
                param($r) if ([string]$r -in @("dark", "light", "auto")) { [string]$r } else { $null } }
            $default.AccentColorIndex = Read-ConfigField -Raw $json.AccentColorIndex -Fallback $default.AccentColorIndex -Parse {
                param($r) [math]::Max(0, [math]::Min(7, [int]$r)) }
            $default.AutoHideFullscreen = Read-ConfigField -Raw $json.AutoHideFullscreen -Fallback $default.AutoHideFullscreen -Parse {
                param($r) ConvertTo-ConfigBool -Raw $r }
            $default.FirstRunShown = Read-ConfigField -Raw $json.FirstRunShown -Fallback $default.FirstRunShown -Parse {
                param($r) ConvertTo-ConfigBool -Raw $r }

            # Battery history: per-entry validation, percent range-checked, and
            # capped at the same 2400 the recorder enforces - a corrupt or
            # hand-grown file must not load an unbounded series into the
            # sparkline's per-point paint loop.
            if ($null -ne $json.BatteryHistory -and $json.BatteryHistory.Count -gt 0) {
                $loadedHistory = @()
                foreach ($entry in $json.BatteryHistory) {
                    try {
                        $pct = [int]$entry.Percent
                        if ($pct -lt 0 -or $pct -gt 100) { continue }
                        $loadedHistory += @{
                            Time       = [DateTime]::Parse($entry.Time)
                            Percent    = $pct
                            IsCharging = [bool]$entry.IsCharging
                        }
                    } catch {}
                }
                if ($loadedHistory.Count -gt 2400) {
                    $loadedHistory = $loadedHistory[($loadedHistory.Count - 2400)..($loadedHistory.Count - 1)]
                }
                $default.BatteryHistory = $loadedHistory
            }
            # Restore persisted EMA state (expire if config older than 10 minutes)
            if ($null -ne $json.EmaRate -and $null -ne $json.ConfigSavedAt) {
                try {
                    $savedAge = ((Get-Date) - [DateTime]::Parse($json.ConfigSavedAt)).TotalMinutes
                    if ($savedAge -lt 10) {
                        $default.EmaRate = [double]$json.EmaRate
                        $default.LastValidRate = [int]$json.LastValidRate
                    }
                } catch {}
            }
        } catch {
            # This file IS the user's setup - position, theme, accent, history.
            # Swallowing the failure reset all of it with no explanation, and the
            # next Save-Config then overwrote the only copy. Keep a copy of what
            # we could not read, and say so.
            $backupPath = "$configPath.corrupt"
            $backedUp = $false
            try {
                Copy-Item -LiteralPath $configPath -Destination $backupPath -Force -ErrorAction Stop
                $backedUp = $true
            } catch { $backedUp = $false }
            $advice = if ($backedUp) {
                "Settings reset to defaults; the unreadable file was kept as $(Split-Path -Leaf $backupPath)"
            } else {
                'Settings reset to defaults'
            }
            Write-IoFailure -Operation "Couldn't read your settings" -Path $configPath `
                -Reason $_.Exception.Message -Advice $advice
        }
    }
    return $default
}

function Write-TextFileAtomic {
    <#
    .SYNOPSIS
        Writes $Content to $Path so that readers only ever see the complete old
        file or the complete new one - never a half-written one.

    .DESCRIPTION
        Set-Content truncates the target and then streams into it. The config
        file is the one piece of BatteryPill state shared BETWEEN processes
        (a launching instance loads it while the running one saves), so that
        truncate leaves a window in which the file on disk is empty or half a
        JSON document. Import-Config cannot tell that apart from corruption:
        it resets position, theme, accent, size and history to defaults. The
        same window loses the file outright if the process dies mid-write -
        which the documented "Stop-Process the widget, then rebuild" loop does
        on purpose.

        Instead: write a sibling temp file, then swap it in with one
        MoveFileEx(MOVEFILE_REPLACE_EXISTING) - a single superseding rename,
        so the directory entry always points at one complete file or the
        other. File.Replace (Win32 ReplaceFile) is NOT that: with or without a
        backup name it detaches the old file before attaching the new one, and
        a concurrent Test-Path in that window sees no config at all - which
        Import-Config reads as first-run and silently resets every setting.
        Measured: ~1 in 9 existence checks against a looping ReplaceFile
        writer saw the name missing; 0 in 26k+ with MoveFileEx. The rename can
        still fail transiently - a sharing violation from a mid-open reader,
        ACCESS_DENIED from an AV/indexer scan holding the file - so it is
        retried before giving up.
    #>
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [int]$Attempts = 12
    )
    # Defined inside the function (not at script top) so the test harness can
    # lift Write-TextFileAtomic on its own and still have the native call.
    if (-not ('BatteryPill.NativeFile' -as [type])) {
        Add-Type -Namespace BatteryPill -Name NativeFile -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, uint dwFlags);
'@
    }
    $dir = Split-Path -Parent $Path
    if (-not $dir) { $dir = '.' }
    # Same directory as the target: a rename is only atomic within one volume.
    $tmp = Join-Path $dir ('.{0}.{1}.tmp' -f (Split-Path -Leaf $Path), [guid]::NewGuid().ToString('N').Substring(0, 8))
    # No BOM: matches what Set-Content wrote before, so an existing config file
    # keeps parsing byte-for-byte the same way.
    [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding $false))
    try {
        $lastErr = $null
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            # 0x1 = MOVEFILE_REPLACE_EXISTING. Works whether or not the target
            # exists yet, which also removes the old Exists-then-Move race.
            if ([BatteryPill.NativeFile]::MoveFileEx($tmp, $Path, 0x1)) { return }
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $lastErr = New-Object System.ComponentModel.Win32Exception($code)
            Start-Sleep -Milliseconds (5 * $attempt)
        }
        throw $lastErr
    } finally {
        # Never leave debris next to the user's config.
        if ([System.IO.File]::Exists($tmp)) {
            try { [System.IO.File]::Delete($tmp) } catch { }
        }
    }
}

function Save-Config {
    [OutputType([void])]
    param(
        # Config file to write. Defaults to the app's own file; tests override it.
        [string]$Path = ''
    )
    $configPath = if ($Path) { $Path } else { Get-ConfigPath }
    try {
        # Serialize last 200 history entries (timestamps as ISO8601)
        $historyToSave = @()
        if ($null -ne $script:batteryHistory -and $script:batteryHistory.Count -gt 0) {
            $startIdx = [math]::Max(0, $script:batteryHistory.Count - 200)
            for ($hi = $startIdx; $hi -lt $script:batteryHistory.Count; $hi++) {
                $h = $script:batteryHistory[$hi]
                $historyToSave += @{
                    Time       = $h.Time.ToString("o")
                    Percent    = $h.Percent
                    IsCharging = $h.IsCharging
                }
            }
        }
        $json = @{
            X                  = $script:config.X
            Y                  = $script:config.Y
            Opacity            = $script:config.Opacity
            RefreshInterval    = $script:config.RefreshInterval
            PositionLocked     = $script:config.PositionLocked
            DisplayMode        = $script:config.DisplayMode
            PillSize           = $script:config.PillSize
            Theme              = $script:config.Theme
            AccentColorIndex   = $script:config.AccentColorIndex
            AutoHideFullscreen = $script:config.AutoHideFullscreen
            FirstRunShown      = $script:config.FirstRunShown
            BatteryHistory     = $historyToSave
            EmaRate            = $script:emaRate
            LastValidRate      = $script:lastValidRate
            ConfigSavedAt      = (Get-Date).ToString("o")
        } | ConvertTo-Json -Depth 3
        Write-TextFileAtomic -Path $configPath -Content $json
        # Write-TextFileAtomic replaced `Set-Content $configPath -ErrorAction
        # Stop`. -ErrorAction Stop was load-bearing (Set-Content's write errors
        # are non-terminating, so the catch below never ran and a read-only file
        # lost every setting change silently); the helper throws outright, so
        # the catch still fires. What it adds is that the write is all-or-
        # nothing: no reader, and no crash, can catch the config half-written.
    } catch {
        Write-IoFailure -Operation "Couldn't save your settings" -Path $configPath `
            -Reason $_.Exception.Message `
            -Advice 'Changes will be lost when BatteryPill closes - check the folder is writable'
    }
}

