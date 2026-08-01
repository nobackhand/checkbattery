# tools\format-source.ps1
#
# Autoformatter for BatteryPill (Windows PowerShell 5.1).
#
#   powershell -ExecutionPolicy Bypass -File tools\format-source.ps1          # rewrite files in place
#   powershell -ExecutionPolicy Bypass -File tools\format-source.ps1 -Check   # verify only, exit 1 if unformatted
#
# Formats every .ps1 in the repo with PSScriptAnalyzer's Invoke-Formatter using
# the house style below (K&R braces, 4-space indent, aligned hashtable
# assignments). tools\check-source.ps1 runs the -Check mode, so an unformatted
# file fails scripts/verify.sh.
#
# Two properties this tool guarantees, because BatteryPill is unusually
# sensitive to both:
#   * BOM preservation. The widget source modules (src\*.ps1) MUST keep their
#     UTF-8 BOM (PS 5.1 reads a BOM-less .ps1 as ANSI and mangles non-ASCII
#     characters into a parser error). Each file is rewritten with the BOM
#     state it already had.
#   * Line-ending preservation. A file's dominant newline (CRLF or LF) is
#     restored after formatting so reformatting never shows up as a whole-file
#     diff.
#
# It also refuses to write a file whose token stream changed: formatting moves
# whitespace and nothing else. That check is what makes a repo-wide reformat
# mechanically safe to review.
#
# Deliberately NOT enabled: PSUseCorrectCasing. It rewrites command and
# parameter names to the casing the module declares, which turns Build.ps1's
# readable `Invoke-PS2EXE -InputFile` into `Invoke-ps2exe -inputFile` - churn
# that makes the source worse, on a language that is case-insensitive anyway.
#
# Exit code: 0 = nothing to do (or files rewritten), 1 = -Check found
#            unformatted files, or a file failed the token-equivalence guard.

[CmdletBinding()]
param(
    # Report which files would change and exit nonzero instead of rewriting them.
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# House style. Every rule here is a formatting rule (Invoke-Formatter ignores
# the rest), so this is deliberately separate from PSScriptAnalyzerSettings.psd1,
# which governs correctness findings.
$formatSettings = @{
    IncludeRules = @(
        'PSPlaceOpenBrace',
        'PSPlaceCloseBrace',
        'PSUseConsistentIndentation',
        'PSUseConsistentWhitespace',
        'PSAlignAssignmentStatement'
    )
    Rules        = @{
        # K&R: open brace stays on the statement line, close brace on its own.
        PSPlaceOpenBrace           = @{ Enable = $true; OnSameLine = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true }
        PSPlaceCloseBrace          = @{ Enable = $true; NewLineAfter = $false; IgnoreOneLineBlock = $true; NoEmptyLineBefore = $false }
        PSUseConsistentIndentation = @{ Enable = $true; Kind = 'space'; IndentationSize = 4; PipelineIndentation = 'IncreaseIndentationForFirstPipeline' }
        PSUseConsistentWhitespace  = @{ Enable = $true; CheckInnerBrace = $true; CheckOpenBrace = $true; CheckOpenParen = $true; CheckOperator = $true; CheckPipe = $true; CheckSeparator = $true }
        PSAlignAssignmentStatement = @{ Enable = $true; CheckHashtable = $true }
    }
}

# Token stream with newlines dropped, for the equivalence guard. Every
# remaining token must match byte-for-byte, casing included: with
# PSUseCorrectCasing off, formatting can only move whitespace around.
function Get-TokenSignature {
    [OutputType([string])]
    param([string]$Text)
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "parse error: line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)" }
    $sig = New-Object System.Collections.ArrayList
    foreach ($tok in $tokens) {
        $kind = $tok.Kind.ToString()
        if ($kind -eq 'NewLine' -or $kind -eq 'EndOfInput') { continue }
        [void]$sig.Add("$kind|$($tok.Text)")
    }
    return ($sig -join "`n")
}

Import-Module PSScriptAnalyzer -ErrorAction Stop

$files = @(Get-ChildItem -Path $repoRoot -Recurse -Filter '*.ps1' -File |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        Sort-Object FullName)

$changed = New-Object System.Collections.ArrayList
$failures = 0

Write-Host "=== BatteryPill format ($repoRoot)$(if ($Check) { ' [check]' }) ==="

foreach ($file in $files) {
    $relative = $file.FullName.Substring($repoRoot.Length + 1)
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $original = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $original = $original.Substring(1) }

    try {
        $formatted = Invoke-Formatter -ScriptDefinition $original -Settings $formatSettings
    } catch {
        Write-Host "FAIL: $relative could not be formatted: $($_.Exception.Message)"
        $failures++
        continue
    }

    # Restore the file's own dominant line ending (Invoke-Formatter normalises).
    $crlfCount = ([regex]::Matches($original, "`r`n")).Count
    $lfCount = ([regex]::Matches($original, "(?<!`r)`n")).Count
    $formatted = $formatted -replace "`r`n", "`n"
    if ($crlfCount -ge $lfCount) { $formatted = $formatted -replace "`n", "`r`n" }

    if ($formatted -ceq $original) { continue }

    # Guard: a reformat may not change anything but whitespace and casing.
    try {
        if ((Get-TokenSignature $original) -cne (Get-TokenSignature $formatted)) {
            Write-Host "FAIL: $relative - formatting would change the token stream, not just whitespace. Not written."
            $failures++
            continue
        }
    } catch {
        Write-Host "FAIL: $relative - token guard could not run: $($_.Exception.Message)"
        $failures++
        continue
    }

    [void]$changed.Add($relative)
    if ($Check) { continue }

    $encoding = New-Object System.Text.UTF8Encoding($hasBom)
    [System.IO.File]::WriteAllText($file.FullName, $formatted, $encoding)
}

Write-Host "---"
Write-Host "$($files.Count) file(s) scanned, $($changed.Count) $(if ($Check) { 'unformatted' } else { 'reformatted' })"
foreach ($name in $changed) { Write-Host "      $name" }

if ($failures -gt 0) {
    Write-Host "RESULT: FAIL - $failures file(s) could not be formatted safely"
    exit 1
}
if ($Check -and $changed.Count -gt 0) {
    Write-Host 'RESULT: FAIL - run: powershell -ExecutionPolicy Bypass -File tools\format-source.ps1'
    exit 1
}
Write-Host 'RESULT: PASS'
exit 0
