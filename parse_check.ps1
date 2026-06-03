#Requires -Version 5.0

<#
.SYNOPSIS
    Parses BatteryWidget.ps1 and reports any syntax errors.
.DESCRIPTION
    Fast pre-build sanity check — confirms the widget script tokenizes
    cleanly before compiling with Build.ps1. Resolves the script path
    relative to this file so it works from any clone location.
.EXAMPLE
    .\parse_check.ps1
#>

$target = Join-Path $PSScriptRoot 'BatteryWidget.ps1'
if (-not (Test-Path $target)) {
    Write-Error "BatteryWidget.ps1 not found next to parse_check.ps1 ($target)"
    exit 1
}

$errors = @()
$null = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$errors)

Write-Output "Error count: $($errors.Count)"
foreach ($err in $errors) {
    Write-Output "  Line $($err.Extent.StartLineNumber): $($err.Message)"
}

if ($errors.Count -gt 0) { exit 1 }
