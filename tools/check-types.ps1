# tools\check-types.ps1
#
# Type gate for BatteryPill (Windows PowerShell 5.1).
#
# PowerShell has no compiler to lean on, so nothing stops a signature from
# saying "anything in, anything out". This is the checker that stops it. It
# reads every .ps1 in the repo with the PowerShell AST and enforces four rules,
# repo-wide, with no per-file allowlist:
#
#   1. TYPED PARAMETERS - every parameter of every function, and of every
#      script-level param() block, carries an explicit type constraint.
#   2. DECLARED RETURN TYPE - every function declares [OutputType(...)] with at
#      least one type. Functions that emit nothing declare [OutputType([void])].
#   3. NO BLANKET [object] - rule 1 must not be satisfied by typing everything
#      [object]/[psobject]. A parameter typed that way needs a comment
#      containing "any-typed:" on the parameter's own line or the line above it,
#      saying what the genuinely polymorphic value is.
#   4. HONEST [void] - a function that declares [OutputType([void])] must not
#      contain a value-returning `return <expr>` in its own body (returns inside
#      nested functions and scriptblocks belong to those, and are ignored).
#      This is what keeps a declared return type from drifting away from the
#      code as the code changes.
#
# Exit code: 0 = every rule holds, 1 = any violation.
# Run standalone, or via tools\check-source.ps1 (which verify.sh runs).

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Host "=== BatteryPill type check ($repoRoot) ==="

$anyTypeNames = @('object', 'psobject', 'system.object', 'system.management.automation.psobject')

$files = @(Get-ChildItem -Path $repoRoot -Recurse -Filter '*.ps1' -File |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        Sort-Object FullName)

$violations = New-Object System.Collections.ArrayList
$functionCount = 0
$paramCount = 0

function Add-Violation {
    [OutputType([void])]
    param([string]$File, [int]$Line, [string]$Rule, [string]$Message)
    [void]$violations.Add([pscustomobject]@{ File = $File; Line = $Line; Rule = $Rule; Message = $Message })
}

# The type constraint attached to a parameter, or $null when it has none.
function Get-ParameterTypeConstraint {
    [OutputType([System.Management.Automation.Language.TypeConstraintAst])]
    param([System.Management.Automation.Language.ParameterAst]$Parameter)
    foreach ($attr in $Parameter.Attributes) {
        if ($attr -is [System.Management.Automation.Language.TypeConstraintAst]) { return $attr }
    }
    return $null
}

# Rule 3's escape hatch: an "any-typed:" comment on the parameter's line or the
# line directly above it.
function Test-AnyTypedJustified {
    [OutputType([bool])]
    param([string[]]$Lines, [int]$ParameterLine)
    $idx = $ParameterLine - 1
    for ($i = $idx; $i -ge 0 -and $i -ge $idx - 1; $i--) {
        if ($Lines[$i] -match 'any-typed:') { return $true }
    }
    return $false
}

# Returns the FunctionDefinitionAst / ScriptBlockExpressionAst that owns $Node,
# so a `return` inside a nested function or an event handler is not counted
# against the enclosing function.
function Get-OwningScope {
    [OutputType([System.Management.Automation.Language.Ast])]
    param([System.Management.Automation.Language.Ast]$Node)
    $p = $Node.Parent
    while ($null -ne $p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            return $p
        }
        $p = $p.Parent
    }
    return $null
}

foreach ($file in $files) {
    $name = $file.FullName.Substring($repoRoot.Length + 1)
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errs)
    if ($errs.Count -gt 0) {
        Add-Violation -File $name -Line $errs[0].Extent.StartLineNumber -Rule 'parse' -Message $errs[0].Message
        continue
    }

    # --- script-level param() block: the script's own public signature ---
    $paramBlocks = @()
    if ($ast.ParamBlock) { $paramBlocks += , @{ Block = $ast.ParamBlock; Owner = "$name (script param block)" } }
    foreach ($pbi in $paramBlocks) {
        foreach ($p in $pbi.Block.Parameters) {
            $paramCount++
            if (-not (Get-ParameterTypeConstraint -Parameter $p)) {
                Add-Violation -File $name -Line $p.Extent.StartLineNumber -Rule 'untyped-parameter' `
                    -Message "$($pbi.Owner): `$$($p.Name.VariablePath.UserPath) has no type constraint"
            }
        }
    }

    # --- functions ---
    $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($fn in $fns) {
        $functionCount++
        $pb = $fn.Body.ParamBlock
        $params = if ($pb) { $pb.Parameters } elseif ($fn.Parameters) { $fn.Parameters } else { @() }

        foreach ($p in $params) {
            $paramCount++
            $tc = Get-ParameterTypeConstraint -Parameter $p
            if (-not $tc) {
                Add-Violation -File $name -Line $p.Extent.StartLineNumber -Rule 'untyped-parameter' `
                    -Message "$($fn.Name): `$$($p.Name.VariablePath.UserPath) has no type constraint"
                continue
            }
            $tn = $tc.TypeName.FullName.ToLowerInvariant()
            if ($anyTypeNames -contains $tn) {
                if (-not (Test-AnyTypedJustified -Lines $lines -ParameterLine $p.Extent.StartLineNumber)) {
                    Add-Violation -File $name -Line $p.Extent.StartLineNumber -Rule 'unjustified-object' `
                        -Message "$($fn.Name): `$$($p.Name.VariablePath.UserPath) is [$($tc.TypeName.Name)] with no 'any-typed:' justification comment"
                }
            }
        }

        # OutputType must be present, on the param block, with at least one type
        $outputTypes = @()
        if ($pb) {
            foreach ($a in $pb.Attributes) {
                if ($a.TypeName.Name -eq 'OutputType') {
                    foreach ($arg in $a.PositionalArguments) { $outputTypes += $arg.Extent.Text }
                }
            }
        }
        if ($outputTypes.Count -eq 0) {
            Add-Violation -File $name -Line $fn.Extent.StartLineNumber -Rule 'missing-outputtype' `
                -Message "$($fn.Name): no [OutputType(...)] declared (use [OutputType([void])] if it emits nothing)"
            continue
        }

        # Rule 4: [void] must mean void
        if ($outputTypes.Count -eq 1 -and $outputTypes[0] -match '^\[\s*void\s*\]$') {
            $rets = $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)
            foreach ($r in $rets) {
                if ($null -eq $r.Pipeline) { continue }   # bare `return` is fine
                $owner = Get-OwningScope -Node $r
                if ($owner -ne $fn) { continue }          # belongs to a nested function/scriptblock
                Add-Violation -File $name -Line $r.Extent.StartLineNumber -Rule 'void-returns-value' `
                    -Message "$($fn.Name): declared [OutputType([void])] but returns a value: $($r.Extent.Text)"
            }
        }
    }
}

Write-Host ("INFO: checked {0} file(s), {1} function(s), {2} parameter(s)" -f $files.Count, $functionCount, $paramCount)

if ($violations.Count -eq 0) {
    Write-Host 'PASS: every function has typed parameters and a declared [OutputType]'
    Write-Host 'RESULT: PASS'
    exit 0
}

Write-Host "FAIL: $($violations.Count) typing violation(s):"
foreach ($v in $violations) {
    Write-Host ("      {0} {1}:{2} {3}" -f $v.Rule, $v.File, $v.Line, $v.Message)
}
Write-Host 'RESULT: FAIL'
exit 1
