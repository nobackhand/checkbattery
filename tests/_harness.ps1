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
    # A non-terminating error inside a test body (a failing cmdlet, a bad path)
    # does not throw by default, so the body used to run to completion and the
    # test reported PASS while something in it had actually failed. Stop makes
    # every error terminating for the duration of the body, so the catch below
    # sees it. The assignment is function-scoped; the invoked body inherits it.
    $ErrorActionPreference = 'Stop'
    try {
        & $Body
        Write-Host "  PASS  $Name"
    } catch {
        $script:TestsFailed++
        Write-Host "  FAIL  $Name"
        Write-Host "        $($_.Exception.Message)"
    }
}

# Numeric types that Assert-Equal compares by value across widths, so that an
# [int] expectation still matches the [double] that [math]::Round returns.
$script:AssertNumericTypes = @(
    [byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64],
    [single], [double], [decimal]
)

function Format-AssertValue {
    <# Renders a value unambiguously for assertion messages. #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [string]) { return "'$Value'" }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @($Value) | ForEach-Object { Format-AssertValue $_ }
        return '@(' + ($parts -join ', ') + ')'
    }
    return "$Value [$($Value.GetType().Name)]"
}

function Test-AssertValueEqual {
    <#
    .SYNOPSIS
        Strict equality for assertions: no silent PowerShell coercion.

        `-eq` coerces its right operand to the left operand's type, so
        `$true -eq 'hello'` and `5 -eq '5'` are both true - assertions built on
        it pass against values of entirely the wrong type. This compares within
        a category (bool/string/collection/numeric) and calls a cross-category
        comparison unequal.
    #>
    param([AllowNull()]$Expected, [AllowNull()]$Actual)

    if ($null -eq $Expected -and $null -eq $Actual) { return $true }
    if ($null -eq $Expected -or  $null -eq $Actual) { return $false }

    $eBool = $Expected -is [bool]; $aBool = $Actual -is [bool]
    if ($eBool -or $aBool) { return ($eBool -and $aBool -and ($Expected -eq $Actual)) }

    $eStr = $Expected -is [string]; $aStr = $Actual -is [string]
    if ($eStr -or $aStr) { return ($eStr -and $aStr -and [string]::Equals($Expected, $Actual, 'Ordinal')) }

    $eCol = $Expected -is [System.Collections.IEnumerable]
    $aCol = $Actual   -is [System.Collections.IEnumerable]
    if ($eCol -or $aCol) {
        if (-not ($eCol -and $aCol)) { return $false }
        $e = @($Expected); $a = @($Actual)
        if ($e.Count -ne $a.Count) { return $false }
        for ($i = 0; $i -lt $e.Count; $i++) {
            if (-not (Test-AssertValueEqual $e[$i] $a[$i])) { return $false }
        }
        return $true
    }

    $eNum = $script:AssertNumericTypes -contains $Expected.GetType()
    $aNum = $script:AssertNumericTypes -contains $Actual.GetType()
    if ($eNum -or $aNum) {
        if (-not ($eNum -and $aNum)) { return $false }
        return ([decimal]$Expected -eq [decimal]$Actual)
    }

    if ($Expected.GetType() -ne $Actual.GetType()) { return $false }
    return [object]::Equals($Expected, $Actual)
}

function Assert-Equal {
    param([AllowNull()]$Expected, [AllowNull()]$Actual, [string]$Because = '')
    if (-not (Test-AssertValueEqual $Expected $Actual)) {
        throw ("expected {0} but got {1}{2}" -f (Format-AssertValue $Expected),
                                                (Format-AssertValue $Actual),
                                                $(if ($Because) { " ($Because)" } else { '' }))
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
    # A file that asserted nothing is not a passing file - it is a file whose
    # tests never ran (an early return, a bad filter, a deleted block). Reporting
    # PASS for it is how coverage silently disappears.
    if ($script:TestsRun -eq 0) {
        Write-Host '        no tests ran in this file - failing rather than reporting a hollow PASS'
        return 1
    }
    if ($script:TestsFailed -gt 0) { return 1 }
    return 0
}
