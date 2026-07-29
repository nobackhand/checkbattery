# tests\_harness.ps1
#
# Minimal assertion + loading harness for the BatteryPill test suite.
# Dot-source it at the top of every tests\*.Tests.ps1 file:
#
#     . (Join-Path $PSScriptRoot '_harness.ps1')
#     . (Import-WidgetFunction 'Format-Duration')
#     Test-Case 'formats hours and minutes' { Assert-Equal '3h 8m' (Format-Duration 188) }
#     exit (Complete-Tests)
#
# BatteryWidget.ps1 cannot be dot-sourced directly: it ends in
# [Windows.Forms.Application]::Run(), so loading it would launch the widget.
# Import-WidgetFunction lifts named function definitions out of the file via
# the PowerShell AST and hands back a scriptblock the caller dot-sources into
# its own scope - no message loop, no forms, no side effects.

$script:TestsRun    = 0
$script:TestsFailed = 0

function Import-WidgetFunction {
    <#
    .SYNOPSIS
        Returns a scriptblock defining the named top-level functions from
        BatteryWidget.ps1. Dot-source the result to bring them into scope.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Name)

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $source   = Join-Path $repoRoot 'BatteryWidget.ps1'
    if (-not (Test-Path $source)) { throw "not found: $source" }

    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errs)
    if ($errs.Count -gt 0) { throw "BatteryWidget.ps1 has $($errs.Count) parser error(s)" }

    $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $text = New-Object System.Text.StringBuilder
    foreach ($wanted in $Name) {
        $def = $defs | Where-Object { $_.Name -eq $wanted } | Select-Object -First 1
        if ($null -eq $def) { throw "function not found in BatteryWidget.ps1: $wanted" }
        [void]$text.AppendLine($def.Extent.Text)
    }
    return [scriptblock]::Create($text.ToString())
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:TestsRun++
    try {
        & $Body
        Write-Host "  PASS  $Name"
    } catch {
        $script:TestsFailed++
        Write-Host "  FAIL  $Name"
        Write-Host "        $($_.Exception.Message)"
    }
}

function Assert-Equal {
    param([AllowNull()]$Expected, [AllowNull()]$Actual, [string]$Because = '')
    if ($Expected -ne $Actual) {
        throw ("expected <{0}> but got <{1}>{2}" -f $Expected, $Actual, $(if ($Because) { " ($Because)" } else { '' }))
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because = 'condition was false')
    if (-not $Condition) { throw $Because }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Because = 'expected an exception, none thrown')
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (-not $threw) { throw $Because }
}

function Complete-Tests {
    <# Prints the per-file summary and returns the exit code (0 = all green). #>
    Write-Host "  --- $script:TestsRun run, $script:TestsFailed failed"
    if ($script:TestsFailed -gt 0) { return 1 }
    return 0
}
