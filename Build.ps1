#Requires -Version 5.0

<#
.SYNOPSIS
    Compiles the widget source (src\ modules) into a standalone .exe using ps2exe.
.DESCRIPTION
    The widget ships as ordered modules under src\. This build concatenates
    them byte-exactly (tools\_assemble.ps1) into a temp staging file and feeds
    that single file to ps2exe - the compiled output is identical to compiling
    the old single-file BatteryWidget.ps1.
.EXAMPLE
    .\Build.ps1
#>

$scriptDir = $PSScriptRoot

# Assemble src\ modules into a per-process staging file (verify.sh runs this
# stage concurrently with the tests, so the name must not collide).
. (Join-Path $scriptDir 'tools\_assemble.ps1')
$inputFile = Write-AssembledWidget -OutFile (Join-Path $env:TEMP ("BatteryWidget-build-{0}.ps1" -f $PID))

# Extract version from the module source
$versionLine = Select-String -Path (Join-Path $scriptDir 'src\*.ps1') -Pattern '^\$script:appVersion\s*=\s*"(.+?)"' | Select-Object -First 1
$appVersion = if ($versionLine) { $versionLine.Matches[0].Groups[1].Value } else { "0.0.0" }
$outputFile = Join-Path $scriptDir "BatteryPill-$appVersion.exe"

# Ensure ps2exe module is available.
# Bootstrap first: stock Windows PowerShell 5.1 lacks a TLS 1.2 default and the
# NuGet package provider; without both, Install-Module fails with
# "NuGet provider is required to interact with NuGet-based repositories".
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
    Write-Host "Installing NuGet package provider..." -ForegroundColor Yellow
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
}
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe module..." -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}

# Remove old exe(s), KEEPING the single newest as a fallback. Deleting every
# previous build once left the dev machine with zero runnable exes when Smart
# App Control blocked the fresh (unsigned, zero-reputation) output - the
# last-known-good build is the recovery path.
$oldBuilds = Get-ChildItem $scriptDir -Filter "BatteryPill-*.exe" |
    Where-Object { $_.Name -ne (Split-Path -Leaf $outputFile) } |
    Sort-Object LastWriteTime -Descending
if ($oldBuilds.Count -gt 0) {
    Write-Host "Keeping previous build as fallback: $($oldBuilds[0].Name)" -ForegroundColor Yellow
}
$oldBuilds | Select-Object -Skip 1 | ForEach-Object {
    Write-Host "Removing old build: $($_.Name)..." -ForegroundColor Yellow
    Remove-Item $_.FullName -Force
}
# A stale exe with the CURRENT version must still go - PS2EXE can't overwrite
# a locked file, and a same-name leftover would mask a failed compile.
if (Test-Path $outputFile) {
    Write-Host "Removing stale same-version build: $(Split-Path -Leaf $outputFile)..." -ForegroundColor Yellow
    Remove-Item $outputFile -Force
}

# Compile
Write-Host "Compiling src\*.ps1 (assembled) -> BatteryPill-$appVersion.exe" -ForegroundColor Cyan

Invoke-PS2EXE -InputFile $inputFile `
    -OutputFile $outputFile `
    -noConsole `
    -STA `
    -DPIAware `
    -title "BatteryPill" `
    -description "BatteryPill - floating battery widget for Windows" `
    -version "$appVersion.0" `
    -copyright "(c) 2026"

Remove-Item $inputFile -Force -ErrorAction SilentlyContinue

if (Test-Path $outputFile) {
    $fileSize = [math]::Round((Get-Item $outputFile).Length / 1KB)
    Write-Host ""
    Write-Host "Build successful!" -ForegroundColor Green
    Write-Host "  Output: $outputFile" -ForegroundColor Green
    Write-Host "  Size:   $fileSize KB" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Build failed!" -ForegroundColor Red
    exit 1
}
