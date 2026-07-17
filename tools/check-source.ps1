# tools\check-source.ps1
#
# Source health gate for BatteryPill (Windows PowerShell 5.1).
# Checks, relative to the repo root (parent of this tools folder):
#   1. BatteryWidget.ps1 starts with a UTF-8 BOM (EF BB BF). PS 5.1 reads
#      BOM-less .ps1 files as ANSI, which mangles the non-ASCII display
#      strings into parser errors at launch ("powershell -File" fails).
#   2. BatteryWidget.ps1 parses with zero errors.
#      NOTE: the Parser API reads the file as UTF-8 regardless of BOM, so a
#      clean parse here does NOT prove the BOM is present - check 1 does that.
#   3. Inventory of non-ASCII characters inside string tokens (WARN only -
#      these are exactly the characters that depend on the BOM to survive).
#   4. CheckBattery.ps1 and Build.ps1 also parse cleanly.
# Exit code: 0 = all checks pass, 1 = any failure.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = 0
$warnings = 0

Write-Host "=== BatteryPill source check ($repoRoot) ==="

# ---- 1) BOM check on BatteryWidget.ps1 ----
$mainPath = Join-Path $repoRoot 'BatteryWidget.ps1'
if (-not (Test-Path $mainPath)) {
    Write-Host "FAIL: not found: $mainPath"
    Write-Host 'RESULT: FAIL'
    exit 1
}
$head = New-Object byte[] 3
$fs = [System.IO.File]::OpenRead($mainPath)
$bytesRead = $fs.Read($head, 0, 3)
$fs.Close()
if ($bytesRead -eq 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
    Write-Host 'PASS: BatteryWidget.ps1 has a UTF-8 BOM'
} else {
    Write-Host 'FAIL: BatteryWidget.ps1 is MISSING its UTF-8 BOM (first bytes must be EF BB BF).'
    Write-Host '      PS 5.1 will read the file as ANSI and mangle non-ASCII display strings into parser errors.'
    Write-Host '      Fix: [System.IO.File]::WriteAllText($p, [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8), (New-Object System.Text.UTF8Encoding $true))'
    $failures++
}

# ---- 2) Parse BatteryWidget.ps1 (keep tokens for check 3) ----
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -eq 0) {
    Write-Host 'PASS: BatteryWidget.ps1 parses with 0 errors'
} else {
    Write-Host "FAIL: BatteryWidget.ps1 has $($parseErrors.Count) parser error(s):"
    $shown = 0
    foreach ($e in $parseErrors) {
        if ($shown -ge 10) { Write-Host "      ... and $($parseErrors.Count - 10) more"; break }
        Write-Host "      line $($e.Extent.StartLineNumber): $($e.Message)"
        $shown++
    }
    $failures++
}

# ---- 3) Non-ASCII characters inside string tokens (WARN, not fail) ----
$stringKinds = @('StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable')
$hits = New-Object System.Collections.ArrayList
foreach ($tok in $tokens) {
    if ($stringKinds -notcontains $tok.Kind.ToString()) { continue }
    $text = $tok.Text
    $lineOffset = 0
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        if ($ch -eq "`n") { $lineOffset++; continue }
        if ([int]$ch -gt 127) {
            [void]$hits.Add([pscustomobject]@{
                Line = $tok.Extent.StartLineNumber + $lineOffset
                Code = [int]$ch
                Char = $ch
            })
        }
    }
}
if ($hits.Count -eq 0) {
    Write-Host 'INFO: no non-ASCII characters inside string tokens'
} else {
    Write-Host "WARN: $($hits.Count) non-ASCII character(s) inside string tokens (these REQUIRE the BOM to survive PS 5.1):"
    $shown = 0
    foreach ($hitItem in $hits) {
        if ($shown -ge 50) { Write-Host "      ... and $($hits.Count - 50) more"; break }
        Write-Host ("      line {0}: U+{1:X4} '{2}'" -f $hitItem.Line, $hitItem.Code, $hitItem.Char)
        $shown++
    }
    $warnings += $hits.Count
}

# ---- 4) Parse-check sibling scripts ----
foreach ($name in @('CheckBattery.ps1', 'Build.ps1')) {
    $p = Join-Path $repoRoot $name
    if (-not (Test-Path $p)) {
        Write-Host "FAIL: not found: $p"
        $failures++
        continue
    }
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)
    if ($errs.Count -eq 0) {
        Write-Host "PASS: $name parses with 0 errors"
    } else {
        Write-Host "FAIL: $name has $($errs.Count) parser error(s):"
        foreach ($e in $errs) { Write-Host "      line $($e.Extent.StartLineNumber): $($e.Message)" }
        $failures++
    }
}

# ---- Summary ----
Write-Host '---'
if ($failures -eq 0) {
    Write-Host "RESULT: PASS ($warnings warning(s))"
    exit 0
} else {
    Write-Host "RESULT: FAIL - $failures failing check(s), $warnings warning(s)"
    exit 1
}
