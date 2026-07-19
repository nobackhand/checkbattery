#Requires -Version 5.0

<#
.SYNOPSIS
    Compiles BatteryWidget.ps1 into a standalone .exe using ps2exe.
.EXAMPLE
    .\Build.ps1
#>

$scriptDir = $PSScriptRoot
$inputFile = Join-Path $scriptDir "BatteryWidget.ps1"

# Extract version from the script source
$versionLine = Select-String -Path $inputFile -Pattern '^\$script:appVersion\s*=\s*"(.+?)"' | Select-Object -First 1
$appVersion = if ($versionLine) { $versionLine.Matches[0].Groups[1].Value } else { "0.0.0" }
$outputFile = Join-Path $scriptDir "BatteryPill-$appVersion.exe"

# Verify source exists
if (-not (Test-Path $inputFile)) {
    Write-Host "ERROR: BatteryWidget.ps1 not found in $scriptDir" -ForegroundColor Red
    exit 1
}

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

# Remove old exe(s) if present
Get-ChildItem $scriptDir -Filter "BatteryPill-*.exe" | ForEach-Object {
    Write-Host "Removing previous build: $($_.Name)..." -ForegroundColor Yellow
    Remove-Item $_.FullName -Force
}

# Compile
Write-Host "Compiling BatteryWidget.ps1 -> BatteryPill-$appVersion.exe" -ForegroundColor Cyan

Invoke-PS2EXE -InputFile $inputFile `
              -OutputFile $outputFile `
              -noConsole `
              -STA `
              -DPIAware `
              -title "BatteryPill" `
              -description "BatteryPill - floating battery widget for Windows" `
              -version "$appVersion.0" `
              -copyright "(c) 2026"

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
