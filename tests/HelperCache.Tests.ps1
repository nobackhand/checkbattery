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

# The cache directory is addressed by its 8.3 SHORT path, as it is on the
# GitHub runner (TEMP = C:\Users\RUNNER~1\...): Get-ChildItem reports long
# paths, and a cleanup that compared full paths deleted the DLL it had just
# rebuilt. Where 8.3 names are off, the short path is the long one.
$longDir = Join-Path $env:TEMP ('batterypill-helpercache-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $longDir -Force | Out-Null
$script:cacheDir = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($longDir).ShortPath
$script:fnText = ([scriptblock](Import-WidgetFunction 'Import-HelperTypes')).ToString()

function Invoke-Launch {
    # One simulated launch in a fresh powershell.exe: import the helper source,
    # report which path was taken and whether the type works, and the time.
    # The cache is used only by an unelevated process, so launches say so
    # explicitly (CI runners are elevated) unless a case is about elevation.
    [OutputType([string])]
    param([string]$ClassName, [string]$CacheDir, [string]$Elevated = '$false', [string]$Prelude = '')
    $src = "public static class $ClassName { public static int Answer() { return 42; } }"
    $probe = Join-Path $env:TEMP ('helpercache-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $body = $script:fnText + "`r`n" + $Prelude + "`r`n" + @"
`$sw = [System.Diagnostics.Stopwatch]::StartNew()
`$how = Import-HelperTypes -Source '$src' -References @('System') -CacheDir '$CacheDir' -Elevated $Elevated
`$ms = `$sw.ElapsedMilliseconds
Write-Output ("{0}|{1}|{2}" -f `$how, [$ClassName]::Answer(), `$ms)
"@
    [System.IO.File]::WriteAllText($probe, $body, (New-Object System.Text.UTF8Encoding $false))
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1
        return (($out | Out-String).Trim())
    } finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
}

function Get-CachedDll {
    [OutputType([System.IO.FileInfo[]])]
    param()
    return @(Get-ChildItem -LiteralPath $script:cacheDir -Filter 'helpers-*.dll')
}

$cls = 'HelperCacheProbe' + [guid]::NewGuid().ToString('N').Substring(0, 8)

Test-Case 'helper cache: the first launch compiles and keeps the DLL' {
    $r = Invoke-Launch -ClassName $cls -CacheDir $script:cacheDir
    Assert-True ($r -like 'compiled|42|*') "first launch said: $r"
    Assert-Equal 1 (Get-CachedDll).Count
}

Test-Case 'helper cache: the next launch loads the cached DLL instead of compiling' {
    $r = Invoke-Launch -ClassName $cls -CacheDir $script:cacheDir
    Assert-True ($r -like 'cache|42|*') "second launch said: $r"
}

Test-Case 'helper cache: changed source compiles afresh and drops the old DLL' {
    # The old build's DLL is from an earlier day, not seconds ago
    foreach ($f in (Get-CachedDll)) { $f.LastWriteTime = (Get-Date).AddHours(-2) }
    $cls2 = $cls + 'v2'
    $r = Invoke-Launch -ClassName $cls2 -CacheDir $script:cacheDir
    Assert-True ($r -like 'compiled|42|*') "changed-source launch said: $r"
    Assert-Equal 1 (Get-CachedDll).Count
}

Test-Case 'helper cache: a damaged cached DLL is rebuilt, not fatal' {
    $dll = (Get-CachedDll)[0].FullName
    [System.IO.File]::WriteAllText($dll, 'not a real assembly')
    $r = Invoke-Launch -ClassName ($cls + 'v2') -CacheDir $script:cacheDir
    Assert-True ($r -like 'compiled|42|*') "launch over a damaged DLL said: $r"
    # ...and the launch after that is served from the rebuilt cache
    $r2 = Invoke-Launch -ClassName ($cls + 'v2') -CacheDir $script:cacheDir
    Assert-True ($r2 -like 'cache|42|*') "launch after the rebuild said: $r2"
}

Test-Case 'helper cache: temp DLLs left by earlier launches are swept, a fresh one is not' {
    $stale = Join-Path $script:cacheDir 'helpers-0123456789abcdef.4242.tmp.dll'
    $fresh = Join-Path $script:cacheDir 'helpers-0123456789abcdef.4343.tmp.dll'
    Set-Content -LiteralPath $stale -Value 'x'
    Set-Content -LiteralPath $fresh -Value 'x'
    (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddHours(-2)
    $r = Invoke-Launch -ClassName ($cls + 'v2') -CacheDir $script:cacheDir
    Assert-True ($r -like 'cache|42|*') "launch said: $r"
    Assert-True (-not (Test-Path -LiteralPath $stale)) 'a two-hour-old temp DLL was left behind'
    # Under a minute old it may be another launch's compile in flight
    Assert-True (Test-Path -LiteralPath $fresh) 'a temp DLL written just now was deleted'
}

Test-Case 'helper cache: an elevated process compiles in memory and writes nothing' {
    $dir = Join-Path $env:TEMP ('batterypill-helpercache-elev-' + [guid]::NewGuid().ToString('N'))
    try {
        $r = Invoke-Launch -ClassName ($cls + 'v4') -CacheDir $dir -Elevated '$true'
        Assert-True ($r -like 'memory|42|*') "elevated launch said: $r"
        Assert-True (-not (Test-Path -LiteralPath $dir)) 'an elevated launch created the cache directory'
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'helper cache: LOCALAPPDATA unset still loads the helpers (in-memory compile)' {
    $r = Invoke-Launch -ClassName ($cls + 'v5') -CacheDir '' -Prelude 'Remove-Item Env:LOCALAPPDATA'
    Assert-True ($r -like 'memory|42|*') "launch without LOCALAPPDATA said: $r"
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

Remove-Item -LiteralPath $longDir -Recurse -Force -ErrorAction SilentlyContinue

exit (Complete-Tests)
