# tests\ExternalIO.Tests.ps1
#
# Failure-path tests for BatteryPill's external I/O.
#
# The app touches the outside world in a handful of places (config file, startup
# shortcut, powercfg, registry, shell links). These cover the three whose failure
# costs the user something real and used to cost it SILENTLY:
#
#   1. Config LOAD of an unreadable/corrupt file - used to be `catch {}`: every
#      setting reset with no explanation, and the next save overwrote the file.
#   2. Config SAVE to a location that cannot be written - Set-Content's errors
#      are non-terminating, so the catch never fired and every settings change
#      vanished without even the old vague card.
#   3. Auto-start DISABLE when the shortcut cannot be deleted - Remove-Item is
#      non-terminating too, so the checkbox went "off" while BatteryPill kept
#      starting with Windows, and nothing said why.
#
# Each one asserts the same contract: the operation reports failure to its
# caller, and records an actionable failure naming the PATH, the REASON Windows
# gave, and ADVICE - never an empty catch.
#
# $ErrorActionPreference is forced back to 'Continue' inside the bodies that
# exercise a cmdlet's non-terminating error, because the harness runs bodies
# under 'Stop' - which would mask the very bug the -ErrorAction Stop fixes.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction @(
        'Write-IoFailure', 'Open-ExternalLink',
        'Get-ConfigPath', 'Read-ConfigField', 'Import-Config', 'Save-Config',
        'Read-TextFileShared', 'Write-TextFileAtomic',
        'Get-StartupShortcutPath', 'Get-AutoStartEnabled', 'Get-AutoStartTarget', 'Set-AutoStart'))

# Notifications stay off (no forms in a test host); failures are recorded only.
$script:ioNotifyEnabled = $false
$script:ioFailures = @()

$script:tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bp-io-{0}" -f $PID)
if (Test-Path $script:tmpDir) { Remove-Item $script:tmpDir -Recurse -Force }
New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null

# ---------------------------------------------------------------
# The reporter itself
# ---------------------------------------------------------------

Test-Case 'Write-IoFailure records path, reason and advice in one detail line' {
    $script:ioFailures = @()
    Write-IoFailure -Operation 'Nope' -Path 'C:\x.json' -Reason 'access denied' -Advice 'try again'
    Assert-Equal 1 $script:ioFailures.Count
    Assert-Equal 'Nope' $script:ioFailures[0].Operation
    Assert-Equal 'C:\x.json - access denied - try again' $script:ioFailures[0].Detail
}

# ---------------------------------------------------------------
# 1) Config LOAD failure
# ---------------------------------------------------------------

Test-Case 'corrupt config: returns defaults instead of half-applied junk' {
    $cfg = Join-Path $script:tmpDir 'corrupt.json'
    Set-Content -LiteralPath $cfg -Value '{ "Theme": "light", "PillSize": ' -Encoding ASCII
    $script:ioFailures = @()
    $loaded = Import-Config -Path $cfg
    Assert-Equal 'dark' $loaded.Theme
    Assert-Equal 'normal' $loaded.PillSize
    Assert-Equal 3000 $loaded.RefreshInterval
}

Test-Case 'corrupt config: reports an actionable failure naming file, reason and fallout' {
    $cfg = Join-Path $script:tmpDir 'corrupt2.json'
    Set-Content -LiteralPath $cfg -Value '{ "Theme": ' -Encoding ASCII
    $script:ioFailures = @()
    $null = Import-Config -Path $cfg
    Assert-Equal 1 $script:ioFailures.Count
    $f = $script:ioFailures[0]
    Assert-Equal "Couldn't read your settings" $f.Operation
    Assert-Equal $cfg $f.Path
    Assert-True ($f.Reason.Length -gt 0) 'the reason Windows gave must be reported, not swallowed'
    Assert-True ($f.Advice -like '*reset to defaults*') "advice must say what happened to the user's settings"
}

Test-Case 'corrupt config: the unreadable file is preserved, not left to be overwritten' {
    $cfg = Join-Path $script:tmpDir 'corrupt3.json'
    $original = '{ "Theme": "light", "AccentColorIndex": 4, '
    Set-Content -LiteralPath $cfg -Value $original -Encoding ASCII
    $script:ioFailures = @()
    $null = Import-Config -Path $cfg
    $backup = "$cfg.corrupt"
    Assert-True (Test-Path $backup) 'a config we cannot parse must be kept, not silently replaced'
    Assert-Equal $original ((Get-Content -LiteralPath $backup -Raw).TrimEnd("`r", "`n"))
    Assert-True ($script:ioFailures[0].Advice -like '*corrupt*') 'advice must name the kept copy'
}

Test-Case 'readable config still loads, and records nothing' {
    $cfg = Join-Path $script:tmpDir 'good.json'
    Set-Content -LiteralPath $cfg -Value '{ "Theme": "light", "AccentColorIndex": 4 }' -Encoding ASCII
    $script:ioFailures = @()
    $loaded = Import-Config -Path $cfg
    Assert-Equal 'light' $loaded.Theme
    Assert-Equal 4 $loaded.AccentColorIndex
    Assert-Equal 0 $script:ioFailures.Count
    Assert-True (-not (Test-Path "$cfg.corrupt")) 'a healthy config must not be backed up'
}

Test-Case 'missing config is not a failure - first run just gets defaults' {
    $script:ioFailures = @()
    $loaded = Import-Config -Path (Join-Path $script:tmpDir 'never-existed.json')
    Assert-Equal 'dark' $loaded.Theme
    Assert-Equal 0 $script:ioFailures.Count
}

# ---------------------------------------------------------------
# 2) Config SAVE failure
# ---------------------------------------------------------------

# Minimal app state Save-Config serializes.
$script:config = @{
    X                  = 10
    Y                  = 20
    Opacity            = 0.85
    RefreshInterval    = 3000
    PositionLocked     = $false
    DisplayMode        = 'time'
    PillSize           = 'normal'
    Theme              = 'dark'
    AccentColorIndex   = 0
    AutoHideFullscreen = $false
    FirstRunShown      = $true
}
$script:batteryHistory = $null
$script:emaRate = -1
$script:lastValidRate = -1

Test-Case 'unwritable config: reports an actionable failure instead of losing settings quietly' {
    # Reproduce the app's real runtime: non-terminating errors do NOT throw.
    $ErrorActionPreference = 'Continue'
    $bad = Join-Path $script:tmpDir 'no-such-folder\deeper\BatteryWidget.config.json'
    $script:ioFailures = @()
    Save-Config -Path $bad
    Assert-Equal 1 $script:ioFailures.Count
    $f = $script:ioFailures[0]
    Assert-Equal "Couldn't save your settings" $f.Operation
    Assert-Equal $bad $f.Path
    Assert-True ($f.Reason.Length -gt 0) 'must report why the write failed'
    Assert-True ($f.Advice -like '*lost*') 'must warn the user their changes will not persist'
}

Test-Case 'writable config: saves and records nothing' {
    $ErrorActionPreference = 'Continue'
    $good = Join-Path $script:tmpDir 'save-ok.json'
    $script:ioFailures = @()
    Save-Config -Path $good
    Assert-Equal 0 $script:ioFailures.Count
    Assert-True (Test-Path $good)
    $round = Get-Content -LiteralPath $good -Raw | ConvertFrom-Json
    Assert-Equal 10 ([int]$round.X)
    Assert-Equal 'time' ([string]$round.DisplayMode)
}

# ---------------------------------------------------------------
# 3) Auto-start DISABLE failure
# ---------------------------------------------------------------

Test-Case 'auto-start off is honest when the shortcut cannot be deleted' {
    $ErrorActionPreference = 'Continue'
    $lnk = Join-Path $script:tmpDir 'BatteryPill.lnk'
    # A REAL shortcut pointing at a real file. Get-AutoStartEnabled now reports
    # whether BatteryPill would actually start (it reads the shortcut's target
    # and checks it exists), so a placeholder text file named .lnk would
    # correctly read as "off" and make the assertion below meaningless.
    $fakeExe = Join-Path $script:tmpDir 'BatteryPill-9.9.9.exe'
    Set-Content -LiteralPath $fakeExe -Value 'exe' -Encoding ASCII
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($lnk)
    $sc.TargetPath = $fakeExe
    $sc.Save()
    # Hold the file open with no sharing - Windows refuses the delete.
    $held = [System.IO.File]::Open($lnk, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $script:ioFailures = @()
        $result = Set-AutoStart -Enable $false -ShortcutPath $lnk
        Assert-Equal $false $result 'a blocked delete must report failure to the caller'
        Assert-True (Test-Path $lnk) 'the shortcut really did survive - that is the point'
        Assert-True (Get-AutoStartEnabled -ShortcutPath $lnk) 'auto-start is still on'
        Assert-Equal 1 $script:ioFailures.Count
        $f = $script:ioFailures[0]
        Assert-Equal "Couldn't turn off auto-start" $f.Operation
        Assert-Equal $lnk $f.Path
        Assert-True ($f.Reason.Length -gt 0) 'must report why the delete failed'
        Assert-True ($f.Advice -like '*Startup folder*') 'must tell the user how to remove it by hand'
    } finally {
        $held.Close(); $held.Dispose()
    }
}

Test-Case 'auto-start off succeeds quietly when the shortcut can be deleted' {
    $ErrorActionPreference = 'Continue'
    $lnk = Join-Path $script:tmpDir 'Removable.lnk'
    Set-Content -LiteralPath $lnk -Value 'shortcut' -Encoding ASCII
    $script:ioFailures = @()
    $result = Set-AutoStart -Enable $false -ShortcutPath $lnk
    Assert-Equal $true $result
    Assert-True (-not (Test-Path $lnk))
    Assert-Equal 0 $script:ioFailures.Count
}

Test-Case 'auto-start off with no shortcut present is a no-op success' {
    $script:ioFailures = @()
    $result = Set-AutoStart -Enable $false -ShortcutPath (Join-Path $script:tmpDir 'absent.lnk')
    Assert-Equal $true $result
    Assert-Equal 0 $script:ioFailures.Count
}

# ---------------------------------------------------------------
# Shell links (the fourth site fixed in this pass)
# ---------------------------------------------------------------

# A bogus scheme is NOT usable here: the shell accepts unknown protocols and
# hands them to the "how do you want to open this?" picker, so Start-Process
# succeeds. A target the shell cannot resolve at all is the honest stand-in for
# the broken-association case, and exercises the same catch.
Test-Case 'a link the shell cannot open reports instead of escaping the click handler' {
    $script:ioFailures = @()
    $result = Open-ExternalLink -Url (Join-Path $script:tmpDir 'no-such-target.html')
    Assert-Equal $false $result
    Assert-Equal 1 $script:ioFailures.Count
    Assert-Equal "Couldn't open the link" $script:ioFailures[0].Operation
    Assert-True ($script:ioFailures[0].Advice -like '*browser*')
}

Remove-Item $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
exit (Complete-Tests)
