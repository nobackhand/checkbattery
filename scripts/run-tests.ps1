# scripts\run-tests.ps1
#
# Runs the whole BatteryPill test suite: every tests\*.Tests.ps1 file, each in
# its own powershell.exe so one file cannot leak state (or a crash) into the
# next. Exit code 0 = every file green, 1 = at least one file failed.
#
#   .\scripts\run-tests.ps1
#   .\scripts\run-tests.ps1 -Filter Formatting

param([string]$Filter = '*')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testDir = Join-Path $repoRoot 'tests'

Write-Host "=== BatteryPill tests ($testDir) ==="

if (-not (Test-Path $testDir)) {
    Write-Host "FAIL: no tests directory at $testDir"
    exit 1
}

# BaseName of "Formatting.Tests.ps1" is "Formatting.Tests", so matching the
# filter against BaseName alone made the documented `-Filter Formatting` match
# nothing. Match the suite name (BaseName minus the ".Tests" suffix) as well.
$files = @(Get-ChildItem -Path $testDir -Filter '*.Tests.ps1' -File |
        Where-Object {
            $suite = $_.BaseName -replace '\.Tests$', ''
            ($_.BaseName -like $Filter) -or ($suite -like $Filter)
        } |
        Sort-Object Name)

if ($files.Count -eq 0) {
    Write-Host "FAIL: no test files matched '$Filter' in $testDir"
    exit 1
}

$failed = 0
foreach ($f in $files) {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $f.FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: $($f.Name) exited $LASTEXITCODE"
        $failed++
    }
}

Write-Host '---'
if ($failed -eq 0) {
    Write-Host "RESULT: PASS ($($files.Count) test file(s))"
    exit 0
}
Write-Host "RESULT: FAIL - $failed of $($files.Count) test file(s) failed"
exit 1
