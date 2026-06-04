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

# The pure estimation math lives in a separate dot-sourceable file so it can be
# unit-tested in isolation. The compiled exe must stay a SINGLE portable file with
# no external dependency, so we inline that file into the script we actually compile.
$estimationFile = Join-Path $scriptDir "BatteryEstimation.ps1"

# Verify source exists
if (-not (Test-Path $inputFile)) {
    Write-Host "ERROR: BatteryWidget.ps1 not found in $scriptDir" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $estimationFile)) {
    Write-Host "ERROR: BatteryEstimation.ps1 not found in $scriptDir" -ForegroundColor Red
    exit 1
}

# Ensure ps2exe module is available
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe module..." -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}

# Remove old exe(s) if present
Get-ChildItem $scriptDir -Filter "BatteryPill-*.exe" | ForEach-Object {
    Write-Host "Removing previous build: $($_.Name)..." -ForegroundColor Yellow
    Remove-Item $_.FullName -Force
}

# Build a COMBINED temp script: BatteryEstimation.ps1 inlined IN FRONT OF
# BatteryWidget.ps1. This makes the estimation functions/state defined before the
# widget code uses them, so the resulting exe is fully self-contained. The widget's
# own guarded dot-source of BatteryEstimation.ps1 no-ops at runtime because that
# file is not shipped next to the exe. We compile the temp file (not $inputFile),
# then always delete it.
$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("BatteryPill-build-{0}.ps1" -f ([System.Guid]::NewGuid().ToString('N')))

$estimationSource = Get-Content -Path $estimationFile -Raw
$widgetSource     = Get-Content -Path $inputFile -Raw
$combinedSource   = $estimationSource + [Environment]::NewLine + [Environment]::NewLine + $widgetSource
Set-Content -Path $tempFile -Value $combinedSource -Encoding UTF8

# Compile
Write-Host "Compiling BatteryEstimation.ps1 + BatteryWidget.ps1 -> BatteryPill-$appVersion.exe" -ForegroundColor Cyan

try {
    Invoke-PS2EXE -InputFile $tempFile `
                  -OutputFile $outputFile `
                  -noConsole `
                  -STA `
                  -DPIAware `
                  -title "Battery Widget" `
                  -description "System tray battery monitor" `
                  -version "$appVersion.0" `
                  -copyright "(c) 2026"
}
finally {
    # Always remove the combined temp script, even if compilation throws.
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
}

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
