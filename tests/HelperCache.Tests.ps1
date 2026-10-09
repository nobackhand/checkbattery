# tests\HelperCache.Tests.ps1
#
# Import-HelperTypes (010-init): the C# helper types used to be compiled on
# EVERY launch (1-3s idle, 10-15s on a busy machine) before the pill could
# appear. They are now compiled once into %LOCALAPPDATA%\BatteryPill,
# named by a hash of the source, and loaded from there afterwards. These run
# against a throwaway cache directory, each "launch" in its own process
# (a loaded type cannot be unloaded).

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Import-HelperTypes')

Write-Host 'HelperCache.Tests.ps1'

$script:cacheDir = Join-Path $env:TEMP ('batterypill-helpercache-' + [guid]::NewGuid().ToString('N'))
$script:fnText = ([scriptblock](Import-WidgetFunction 'Import-HelperTypes')).ToString()

function Invoke-Launch {
    # One simulated launch in a fresh powershell.exe: import the helper source,
    # report which path was taken and whether the type works, and the time.
    [OutputType([string])]
    param([string]$ClassName, [string]$CacheDir)
    $src = "public static class $ClassName { public static int Answer() { return 42; } }"
    $probe = Join-Path $env:TEMP ('helpercache-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $body = $script:fnText + "`r`n" + @"
`$sw = [System.Diagnostics.Stopwatch]::StartNew()
`$how = Import-HelperTypes -Source '$src' -References @('System') -CacheDir '$CacheDir'
`$ms = `$sw.ElapsedMilliseconds
Write-Output ("{0}|{1}|{2}" -f `$how, [$ClassName]::Answer(), `$ms)
"@
    [System.IO.File]::WriteAllText($probe, $body, (New-Object System.Text.UTF8Encoding $false))
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1
        return (($out | Out-String).Trim())
    } finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
}

$cls = 'HelperCacheProbe' + [guid]::NewGuid().ToString('N').Substring(0, 8)

Test-Case 'helper cache: the first launch compiles and keeps the DLL' {
    $r = Invoke-Launch -ClassName $cls -CacheDir $script:cacheDir
    Assert-True ($r -like 'compiled|42|*') "first launch said: $r"
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $script:cacheDir -Filter 'helpers-*.dll').Count
}

Test-Case 'helper cache: the next launch loads the cached DLL instead of compiling' {
    $r = Invoke-Launch -ClassName $cls -CacheDir $script:cacheDir
    Assert-True ($r -like 'cache|42|*') "second launch said: $r"
}

Test-Case 'helper cache: changed source compiles afresh and drops the old DLL' {
    $cls2 = $cls + 'v2'
    $r = Invoke-Launch -ClassName $cls2 -CacheDir $script:cacheDir
    Assert-True ($r -like 'compiled|42|*') "changed-source launch said: $r"
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $script:cacheDir -Filter 'helpers-*.dll').Count
}

Test-Case 'helper cache: a damaged cached DLL is rebuilt, not fatal' {
    $dll = @(Get-ChildItem -LiteralPath $script:cacheDir -Filter 'helpers-*.dll')[0].FullName
    [System.IO.File]::WriteAllText($dll, 'not a real assembly')
    $r = Invoke-Launch -ClassName ($cls + 'v2') -CacheDir $script:cacheDir
    Assert-True ($r -like 'compiled|42|*') "launch over a damaged DLL said: $r"
    # ...and the launch after that is served from the rebuilt cache
    $r2 = Invoke-Launch -ClassName ($cls + 'v2') -CacheDir $script:cacheDir
    Assert-True ($r2 -like 'cache|42|*') "launch after the rebuild said: $r2"
}

Test-Case 'helper cache: an unusable cache location still runs (in-memory compile)' {
    # A FILE where the cache directory should be: nothing can be written there
    $blocker = Join-Path $env:TEMP ('batterypill-helpercache-blocker-' + [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $blocker -Value 'x'
    try {
        $r = Invoke-Launch -ClassName ($cls + 'v3') -CacheDir $blocker
        Assert-True ($r -like 'memory|42|*') "launch with an unusable cache said: $r"
    } finally { Remove-Item -LiteralPath $blocker -Force -ErrorAction SilentlyContinue }
}

Remove-Item -LiteralPath $script:cacheDir -Recurse -Force -ErrorAction SilentlyContinue

exit (Complete-Tests)
