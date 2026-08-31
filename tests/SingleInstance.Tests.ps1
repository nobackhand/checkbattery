# tests\SingleInstance.Tests.ps1
#
# Regression suite for New-SingleInstanceMutex - the guard that decides
# whether this launch is allowed to become the running app.
#
# It is the first code that runs, so its failure mode is the worst one
# available: the app dies before it can tell anybody why. The guard used to
# be an unguarded constructor on a Global\ name, which threw
# UnauthorizedAccessException when another logon session already owned that
# name - a silent startup death on any shared PC or RDP host.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'New-SingleInstanceMutex')

Write-Host 'SingleInstance.Tests.ps1'

$script:probeName = 'Local\BatteryPillTestMutex-' + [guid]::NewGuid().ToString('N')

Test-Case 'the first launch takes the mutex and reports itself first' {
    $g = New-SingleInstanceMutex -Name $script:probeName
    try {
        Assert-Equal $true $g.IsFirst
        Assert-Equal $false $g.Failed
        if ($null -eq $g.Mutex) { throw 'no mutex handed back' }
    } finally {
        if ($null -ne $g.Mutex) { $g.Mutex.ReleaseMutex(); $g.Mutex.Dispose() }
    }
}

Test-Case 'a second launch while the first holds the mutex is told it is not first' {
    $first = New-SingleInstanceMutex -Name $script:probeName
    try {
        $second = New-SingleInstanceMutex -Name $script:probeName
        try {
            Assert-Equal $false $second.IsFirst
            Assert-Equal $false $second.Failed
        } finally {
            if ($null -ne $second.Mutex) { $second.Mutex.Dispose() }
        }
    } finally {
        if ($null -ne $first.Mutex) { $first.Mutex.ReleaseMutex(); $first.Mutex.Dispose() }
    }
}

Test-Case 'a mutex the caller may not open does not throw, and the app still runs' {
    # Models the real cross-session case: the name exists, owned by another
    # user, with a DACL that does not grant us. The .NET constructor throws
    # UnauthorizedAccessException here - unguarded, that killed the app at
    # startup with no window and no message.
    $denyName = 'Local\BatteryPillDenied-' + [guid]::NewGuid().ToString('N')
    $sec = New-Object System.Security.AccessControl.MutexSecurity
    $everyone = New-Object System.Security.Principal.SecurityIdentifier(
        [System.Security.Principal.WellKnownSidType]::WorldSid, $null)
    $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule(
                $everyone,
                [System.Security.AccessControl.MutexRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Deny)))
    $created = $false
    $blocker = New-Object System.Threading.Mutex($false, $denyName, [ref]$created, $sec)
    try {
        # Must not throw...
        $g = New-SingleInstanceMutex -Name $denyName
        # ...must report the failure honestly...
        Assert-Equal $true $g.Failed
        # ...and must still let this launch proceed. A second pill is an
        # annoyance; no app at all is a silent failure.
        Assert-Equal $true $g.IsFirst
        Assert-Equal $null $g.Mutex
    } finally {
        $blocker.Dispose()
    }
}

Test-Case 'the guard is session-scoped, not machine-wide' {
    # Global\ made the guard span logon sessions, so a second USER was refused
    # a pill they did not have. The name must live in the per-session
    # namespace.
    $src = Get-AssembledWidgetText
    if ($src.Contains('Global\BatteryWidgetSingleInstance')) {
        throw 'the single-instance mutex is back on the machine-wide Global namespace'
    }
    if (-not $src.Contains('Local\BatteryWidgetSingleInstance')) {
        throw 'expected the single-instance mutex to use the Local namespace'
    }
}

exit (Complete-Tests)
