# tools\check-source.ps1
#
# Source health gate for BatteryPill (Windows PowerShell 5.1).
# Checks, relative to the repo root (parent of this tools folder):
#   1. Every widget source module (src\*.ps1) starts with a UTF-8 BOM
#      (EF BB BF). PS 5.1 reads BOM-less .ps1 files as ANSI, which mangles
#      non-ASCII characters into parser errors at launch.
#   2. Every src module parses with zero errors, and so does the assembled
#      whole (the byte-exact concatenation tools\_assemble.ps1 produces -
#      what actually ships).
#      NOTE: the Parser API reads files as UTF-8 regardless of BOM, so a
#      clean parse here does NOT prove the BOM is present - check 1 does that.
#   3. Inventory of non-ASCII characters inside string tokens of the assembled
#      source (WARN only - these are exactly the characters that depend on the
#      BOM to survive).
#   4. CheckBattery.ps1, Build.ps1 and BatteryWidget.Run.ps1 also parse cleanly.
#   5. PSScriptAnalyzer reports zero Error/Warning findings across every .ps1
#      in the repo, using PSScriptAnalyzerSettings.psd1 (which documents the
#      one-line justification for each rule that is switched off).
#   6. Every .ps1 is already autoformatted (tools\format-source.ps1 -Check).
#   7. Typing holds repo-wide (tools\check-types.ps1): no untyped parameter, no
#      function without a declared [OutputType], no blanket [object].
# Exit code: 0 = all checks pass, 1 = any failure OR any warning.
#            Warnings are fatal on purpose: the build log must stay clean, so a
#            new non-ASCII string literal has to be written as [char]0xNNNN.
# Run with -ExecutionPolicy Bypass (as verify.sh does) - the default policy
# blocks PSScriptAnalyzer's format data from loading.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = 0
$warnings = 0

Write-Host "=== BatteryPill source check ($repoRoot) ==="

# ---- 1) BOM check on every widget source module (src\*.ps1) ----
. (Join-Path $PSScriptRoot '_assemble.ps1')
$srcDir = Join-Path $repoRoot 'src'
$moduleFiles = @()
if (Test-Path $srcDir) {
    $moduleFiles = @(Get-ChildItem -Path $srcDir -Filter '*.ps1' -File | Sort-Object Name)
}
if ($moduleFiles.Count -eq 0) {
    Write-Host "FAIL: no widget source modules found in $srcDir"
    Write-Host 'RESULT: FAIL'
    exit 1
}
$bomMissing = 0
foreach ($moduleFile in $moduleFiles) {
    $head = New-Object byte[] 3
    $fs = [System.IO.File]::OpenRead($moduleFile.FullName)
    $bytesRead = $fs.Read($head, 0, 3)
    $fs.Close()
    if (-not ($bytesRead -eq 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)) {
        Write-Host "FAIL: src\$($moduleFile.Name) is MISSING its UTF-8 BOM (first bytes must be EF BB BF)."
        $bomMissing++
    }
}
if ($bomMissing -eq 0) {
    Write-Host "PASS: all $($moduleFiles.Count) src module(s) have a UTF-8 BOM"
} else {
    Write-Host '      PS 5.1 will read a BOM-less file as ANSI and mangle non-ASCII characters into parser errors.'
    Write-Host '      Fix: [System.IO.File]::WriteAllText($p, [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8), (New-Object System.Text.UTF8Encoding $true))'
    $failures++
}

# ---- 2) Parse every src module, then the assembled whole (tokens for check 3) ----
$moduleParseFailures = 0
foreach ($moduleFile in $moduleFiles) {
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($moduleFile.FullName, [ref]$null, [ref]$errs)
    if ($errs.Count -gt 0) {
        Write-Host "FAIL: src\$($moduleFile.Name) has $($errs.Count) parser error(s):"
        foreach ($e in $errs) { Write-Host "      line $($e.Extent.StartLineNumber): $($e.Message)" }
        $moduleParseFailures++
    }
}
if ($moduleParseFailures -eq 0) {
    Write-Host "PASS: all $($moduleFiles.Count) src module(s) parse with 0 errors"
} else {
    $failures++
}

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput((Get-AssembledWidgetText), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -eq 0) {
    Write-Host 'PASS: the assembled widget source parses with 0 errors'
} else {
    Write-Host "FAIL: the assembled widget source has $($parseErrors.Count) parser error(s):"
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
foreach ($name in @('CheckBattery.ps1', 'Build.ps1', 'BatteryWidget.Run.ps1')) {
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

# ---- 5) Static analysis: zero Error/Warning findings ----
# Bootstrap the module the same way Build.ps1 bootstraps ps2exe, so a fresh
# machine can run the gate without a manual install step.
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host 'INFO: installing PSScriptAnalyzer (one-time)...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
if (-not (Test-Path $settingsPath)) {
    Write-Host "FAIL: not found: $settingsPath"
    $failures++
} else {
    $findings = @(Invoke-ScriptAnalyzer -Path $repoRoot -Recurse -Settings $settingsPath)
    if ($findings.Count -eq 0) {
        Write-Host 'PASS: PSScriptAnalyzer reports 0 error/warning finding(s)'
    } else {
        Write-Host "FAIL: PSScriptAnalyzer reports $($findings.Count) error/warning finding(s):"
        $shown = 0
        foreach ($f in $findings) {
            if ($shown -ge 30) { Write-Host "      ... and $($findings.Count - 30) more"; break }
            Write-Host ("      {0} {1} - {2}:{3} {4}" -f $f.Severity, $f.RuleName, (Split-Path $f.ScriptName -Leaf), $f.Line, $f.Message)
            $shown++
        }
        $failures++
    }
}

# ---- 6) Formatting: every .ps1 matches the autoformatter's output ----
$formatScript = Join-Path $PSScriptRoot 'format-source.ps1'
if (-not (Test-Path $formatScript)) {
    Write-Host "FAIL: not found: $formatScript"
    $failures++
} else {
    # format-source.ps1 reports via Write-Host, so its per-file detail streams
    # straight into this log; only its exit code needs interpreting here.
    & $formatScript -Check
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'PASS: every .ps1 is autoformatted'
    } else {
        Write-Host 'FAIL: unformatted .ps1 file(s) - run: powershell -ExecutionPolicy Bypass -File tools\format-source.ps1'
        $failures++
    }
}

# ---- 7) Typing: typed parameters + declared return types, repo-wide ----
$typeScript = Join-Path $PSScriptRoot 'check-types.ps1'
if (-not (Test-Path $typeScript)) {
    Write-Host "FAIL: not found: $typeScript"
    $failures++
} else {
    & $typeScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'FAIL: typing violations - see the type check output above'
        $failures++
    }
}

# ---- Summary ----
Write-Host '---'
if ($failures -eq 0 -and $warnings -eq 0) {
    Write-Host 'RESULT: PASS (0 warning(s))'
    exit 0
} else {
    Write-Host "RESULT: FAIL - $failures failing check(s), $warnings warning(s)"
    exit 1
}
