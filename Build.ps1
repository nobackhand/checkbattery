#Requires -Version 5.0

<#
.SYNOPSIS
    Compiles BatteryWidget.ps1 into a standalone .exe using ps2exe.
.EXAMPLE
    .\Build.ps1
#>

$scriptDir = $PSScriptRoot
$inputFile = Join-Path $scriptDir "BatteryWidget.ps1"
$outputFile = Join-Path $scriptDir "BatteryWidget.exe"

# Verify source exists
if (-not (Test-Path $inputFile)) {
    Write-Host "ERROR: BatteryWidget.ps1 not found in $scriptDir" -ForegroundColor Red
    exit 1
}

# Ensure ps2exe module is available
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe module..." -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}

# Remove old exe if present
if (Test-Path $outputFile) {
    Write-Host "Removing previous build..." -ForegroundColor Yellow
    Remove-Item $outputFile -Force
}

# Compile
Write-Host "Compiling BatteryWidget.ps1 -> BatteryWidget.exe" -ForegroundColor Cyan

Invoke-PS2EXE -InputFile $inputFile `
              -OutputFile $outputFile `
              -noConsole `
              -STA `
              -DPIAware `
              -title "Battery Widget" `
              -description "System tray battery monitor" `
              -version "1.0.0.0" `
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
