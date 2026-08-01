#Requires -Version 5.0

<#
.SYNOPSIS
    Runs BatteryPill straight from source (no build step).
.DESCRIPTION
    The widget source lives in src\ as ordered modules; this wrapper replaces
    the old "powershell -File .\BatteryWidget.ps1". It concatenates the
    modules byte-exactly (tools\_assemble.ps1) into a staging file under
    %TEMP%\BatteryPill-source-run and runs that in a child
    "powershell -STA -File" process - the exact text ps2exe compiles.

    The widget keeps its config next to its own script file, so the repo-root
    BatteryWidget.config.json is copied into the staging dir before launch and
    copied back after exit. Position/theme/size therefore persist across
    source runs and stay shared with a repo-built exe.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\BatteryWidget.Run.ps1
#>

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
. (Join-Path $repoRoot 'tools\_assemble.ps1')

$stageDir = Join-Path $env:TEMP 'BatteryPill-source-run'
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
$staged = Write-AssembledWidget -OutFile (Join-Path $stageDir 'BatteryWidget.ps1')

# Share the repo-root config with the staged run (position, theme, size).
$repoConfig = Join-Path $repoRoot 'BatteryWidget.config.json'
$stageConfig = Join-Path $stageDir 'BatteryWidget.config.json'
if (Test-Path $repoConfig) { Copy-Item -Path $repoConfig -Destination $stageConfig -Force }

$psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $staged + '"'))
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -PassThru
Write-Host "BatteryPill running from source (PID $($proc.Id)). Exit via the tray icon."
$proc.WaitForExit()

# Persist whatever the widget saved (position, settings) back to the repo.
if (Test-Path $stageConfig) { Copy-Item -Path $stageConfig -Destination $repoConfig -Force }
