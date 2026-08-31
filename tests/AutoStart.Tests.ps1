# tests\AutoStart.Tests.ps1
#
# Regression suite for the "Start with Windows" shortcut.
#
# BatteryPill ships as BatteryPill-<version>.exe, so every update leaves the
# previous target missing. That makes the shortcut's TARGET, not its mere
# existence, the thing that decides whether the app actually starts - and the
# thing the Settings checkbox has to report honestly. A checkbox that says
# "on" while nothing starts is worse than one that says "off".

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Get-AutoStartEnabled', 'Get-AutoStartTarget',
    'Repair-AutoStartShortcut', 'Set-AutoStart', 'Get-StartupShortcutPath', 'Get-ExePath',
    'Write-IoFailure', 'Show-BatteryNotification')

Write-Host 'AutoStart.Tests.ps1'

# Write-IoFailure's module state
$script:ioFailures = New-Object System.Collections.ArrayList
$script:ioNotifyEnabled = $false
$script:ioFailureAccent = $null

$script:asDir = Join-Path $env:TEMP ("batterypill-autostart-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:asDir
$script:lnk = Join-Path $script:asDir 'BatteryPill.lnk'

function New-FakeExe {
    [OutputType([string])]
    param([string]$Name)
    $p = Join-Path $script:asDir $Name
    Set-Content -LiteralPath $p -Value 'not really an exe' -Encoding Ascii
    return $p
}

function New-ShortcutTo {
    [OutputType([void])]
    param([string]$Target)
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($script:lnk)
    $sc.TargetPath = $Target
    $sc.Save()
}

function Remove-Shortcut {
    [OutputType([void])]
    param()
    if (Test-Path $script:lnk) { Remove-Item $script:lnk -Force }
}

Test-Case 'no shortcut means auto-start is off' {
    Remove-Shortcut
    Assert-Equal $false (Get-AutoStartEnabled -ShortcutPath $script:lnk)
    Assert-Equal '' (Get-AutoStartTarget -ShortcutPath $script:lnk)
}

Test-Case 'a shortcut pointing at a real exe means auto-start is on' {
    $exe = New-FakeExe -Name 'BatteryPill-1.3.2.exe'
    New-ShortcutTo -Target $exe
    Assert-Equal $true (Get-AutoStartEnabled -ShortcutPath $script:lnk)
    Assert-Equal $exe (Get-AutoStartTarget -ShortcutPath $script:lnk)
}

Test-Case 'a shortcut pointing at a DELETED exe does not count as on' {
    # The update case: BatteryPill-1.3.2.exe is replaced by 1.3.3 and the old
    # file goes away. The .lnk survives, so a bare Test-Path reported the
    # checkbox as ON while nothing started with Windows any more.
    $exe = New-FakeExe -Name 'BatteryPill-1.3.2.exe'
    New-ShortcutTo -Target $exe
    Remove-Item -LiteralPath $exe -Force
    Assert-Equal $false (Get-AutoStartEnabled -ShortcutPath $script:lnk)
}

Test-Case 'an orphaned shortcut is repaired to the running exe' {
    $old = New-FakeExe -Name 'BatteryPill-1.3.2.exe'
    New-ShortcutTo -Target $old
    Remove-Item -LiteralPath $old -Force
    $new = New-FakeExe -Name 'BatteryPill-1.3.3.exe'
    Assert-Equal $true (Repair-AutoStartShortcut -ShortcutPath $script:lnk -ExePath $new)
    Assert-Equal $new (Get-AutoStartTarget -ShortcutPath $script:lnk)
    Assert-Equal $true (Get-AutoStartEnabled -ShortcutPath $script:lnk)
}

Test-Case 'a healthy shortcut is left alone, even pointing at another build' {
    # Deliberately narrow: running an older build on purpose must not
    # silently re-point the user's shortcut. Only a MISSING target is
    # repaired.
    $keep = New-FakeExe -Name 'BatteryPill-1.3.2.exe'
    New-ShortcutTo -Target $keep
    $other = New-FakeExe -Name 'BatteryPill-1.3.3.exe'
    Assert-Equal $false (Repair-AutoStartShortcut -ShortcutPath $script:lnk -ExePath $other)
    Assert-Equal $keep (Get-AutoStartTarget -ShortcutPath $script:lnk)
}

Test-Case 'repairing when there is no shortcut at all does nothing' {
    Remove-Shortcut
    $exe = New-FakeExe -Name 'BatteryPill-1.3.3.exe'
    Assert-Equal $false (Repair-AutoStartShortcut -ShortcutPath $script:lnk -ExePath $exe)
    Assert-Equal $false (Test-Path $script:lnk)
}

Test-Case 'an unreadable shortcut is not reported as off' {
    # A shortcut we cannot inspect (locked by another process, odd format) is
    # still sitting in the Startup folder and Windows will most likely run it.
    # Claiming "off" would be the same lie in the other direction.
    Remove-Shortcut
    Set-Content -LiteralPath $script:lnk -Value 'not a real shortcut' -Encoding Ascii
    Assert-Equal '' (Get-AutoStartTarget -ShortcutPath $script:lnk)
    Assert-Equal $true (Get-AutoStartEnabled -ShortcutPath $script:lnk)
    # ...and it must not be "repaired" either - we cannot know what it meant.
    $exe = New-FakeExe -Name 'BatteryPill-1.3.3.exe'
    Assert-Equal $false (Repair-AutoStartShortcut -ShortcutPath $script:lnk -ExePath $exe)
    Remove-Shortcut
}

Test-Case 'turning auto-start off removes the shortcut' {
    $exe = New-FakeExe -Name 'BatteryPill-1.3.3.exe'
    New-ShortcutTo -Target $exe
    Assert-Equal $true (Set-AutoStart -Enable $false -ShortcutPath $script:lnk)
    Assert-Equal $false (Get-AutoStartEnabled -ShortcutPath $script:lnk)
}

Remove-Item -LiteralPath $script:asDir -Recurse -Force -ErrorAction SilentlyContinue

exit (Complete-Tests)
