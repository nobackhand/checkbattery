# tests\Harness.Tests.ps1
#
# Tests for the test harness itself.
#
# A suite is only worth its green light if it can go red. Four defects let this
# one report PASS over real failures (all four reproduced and fixed in mission
# 03); these tests pin the fixes so they cannot silently regress:
#
#   1. a test body that emitted a NON-TERMINATING error reported PASS
#   2. Assert-Equal used `-ne`, which coerces - $true "equalled" 'hello',
#      5 "equalled" '5', and collections rendered as System.Object[]
#   3. a file that ran ZERO tests reported PASS
#   4. run-tests.ps1 -Filter <suite> (the documented usage) matched nothing
#
# The first and third are properties of a whole test-file run, so they are
# checked by running a throwaway harness file in a child powershell.exe and
# asserting on its exit code - the same signal scripts\run-tests.ps1 consumes.

. (Join-Path $PSScriptRoot '_harness.ps1')

Write-Host 'Harness.Tests.ps1'

function Invoke-HarnessFile {
    <#
    .SYNOPSIS
        Runs $Body as a standalone harness test file in its own powershell.exe
        and returns its exit code plus stdout.

        Start-Process (rather than the call operator) keeps the child's stderr
        out of this process: PS 5.1 wraps native stderr in a NativeCommandError,
        which the harness's ErrorActionPreference=Stop would turn terminating.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Body)

    $dir = Join-Path $env:TEMP ('batterypill-harness-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        $probe = Join-Path $dir 'probe.ps1'
        $outFile = Join-Path $dir 'out.txt'
        $errFile = Join-Path $dir 'err.txt'
        $header = ". (Join-Path '$PSScriptRoot' '_harness.ps1')"
        Set-Content -LiteralPath $probe -Value ($header + "`r`n" + $Body) -Encoding UTF8

        $proc = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -NoNewWindow `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $probe) `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        $stdout = ''
        if (Test-Path $outFile) { $stdout = [string](Get-Content -LiteralPath $outFile -Raw) }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $stdout }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---- 1) a test body that errors must not report PASS ----

Test-Case 'a body that emits a non-terminating error fails the file' {
    $r = Invoke-HarnessFile @'
Test-Case 'reads a path that does not exist' {
    Get-Item 'C:\definitely\does\not\exist\zzz.txt'
}
exit (Complete-Tests)
'@
    Assert-Equal 1 $r.ExitCode 'an erroring body must fail the run'
    Assert-True ($r.Output -match 'FAIL') 'the failure must be reported as FAIL'
}

Test-Case 'a clean body still reports PASS' {
    $r = Invoke-HarnessFile @'
Test-Case 'asserts something true' { Assert-Equal 1 1 }
exit (Complete-Tests)
'@
    Assert-Equal 0 $r.ExitCode 'a clean body must still pass'
    Assert-True ($r.Output -match 'PASS') 'the success must be reported as PASS'
}

# ---- 2) Assert-Equal must not silently coerce ----

Test-Case 'Assert-Equal rejects a bool matched against a truthy non-bool' {
    Assert-Throws { Assert-Equal $true 'hello' } '$true must not equal an arbitrary truthy string'
    Assert-Throws { Assert-Equal $true 1 }       '$true must not equal 1'
}

Test-Case 'Assert-Equal rejects a number matched against its string form' {
    Assert-Throws { Assert-Equal 5 '5' } '5 must not equal the string "5"'
    Assert-Throws { Assert-Equal '5' 5 } 'the string "5" must not equal 5'
}

Test-Case 'Assert-Equal still matches equal numbers across widths' {
    # [math]::Round returns [double]; expectations are written as [int].
    Assert-Equal 108 ([math]::Round(107.6))
    Assert-Equal 0 ([double]0.0)
}

Test-Case 'Assert-Equal compares collections element-wise' {
    Assert-Equal @(1, 2, 3) @(1, 2, 3)
    Assert-Throws { Assert-Equal @(1, 2, 3) @(1, 3) }    'different lengths must not be equal'
    Assert-Throws { Assert-Equal @(1, 2) @(3, 4) }       'different elements must not be equal'
    Assert-Throws { Assert-Equal @(1, 2) 1 }             'a collection must not equal a scalar'
}

Test-Case 'Assert-Equal reports collections readably, not as System.Object[]' {
    $message = ''
    try { Assert-Equal @(1, 2) @(3, 4) } catch { $message = $_.Exception.Message }
    # The contract is that the message names the actual elements of both sides
    # (the old one printed "expected <System.Object[]> but got <System.Object[]>",
    # which told you nothing). The exact element rendering is not pinned here.
    Assert-True ($message -match '@\(') "expected a collection rendering, got: $message"
    foreach ($n in 1, 2, 3, 4) {
        Assert-True ($message -match $n) "expected element $n in the message, got: $message"
    }
    Assert-True ($message -notmatch 'System\.Object') "message must not say System.Object[]: $message"
}

Test-Case 'Assert-Equal handles null on either side' {
    Assert-Equal $null $null
    Assert-Throws { Assert-Equal $null 'x' } 'null must not equal a value'
    Assert-Throws { Assert-Equal 'x' $null } 'a value must not equal null'
}

# ---- 3) a file that asserts nothing must not report PASS ----

Test-Case 'a file that runs zero tests fails instead of reporting a hollow PASS' {
    $r = Invoke-HarnessFile 'exit (Complete-Tests)'
    Assert-Equal 1 $r.ExitCode 'zero tests run must not be a passing file'
}

# ---- 4) Import-WidgetFunction is the load path for every other suite ----

Test-Case 'Import-WidgetFunction throws for a function that does not exist' {
    Assert-Throws { Import-WidgetFunction 'No-SuchFunctionInTheWidget' } 'a missing function must be loud'
}

Test-Case 'Import-WidgetFunction returns a usable definition' {
    . (Import-WidgetFunction 'Format-Duration')
    Assert-Equal '3h 8m' (Format-Duration 188)
}

exit (Complete-Tests)
