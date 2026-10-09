# tests\ClosureScope.Tests.ps1
#
# Structural guard for the GetNewClosure gotcha (CLAUDE.md): every
# .GetNewClosure() runs in its OWN dynamic module, so a $script: variable
# inside one is that module's private variable - not the app's, and not the
# one a sibling closure sees. It fails silently at fire time. The Settings
# opacity slider shipped that way: MouseDown set $script:opacityDragging in
# one closure, MouseMove read it in another (always $null), and the slider
# could be clicked but never dragged. Closures may use captured locals (a
# shared hashtable for state they mutate together); app state belongs in
# plain scriptblocks.

. (Join-Path $PSScriptRoot '_harness.ps1')

Write-Host 'ClosureScope.Tests.ps1'

$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput((Get-AssembledWidgetText), [ref]$null, [ref]$errs)

$closures = @($ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $n.Member.Value -eq 'GetNewClosure' -and
            $n.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true))

Test-Case 'closures: the widget source still uses GetNewClosure (the guard is looking at something)' {
    Assert-True ($closures.Count -ge 5) "found only $($closures.Count) closures - did the AST query break?"
}

Test-Case 'closures: no $script: variable inside any GetNewClosure() block' {
    $hits = @()
    foreach ($c in $closures) {
        $vars = $c.Expression.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsScript
            }, $true)
        foreach ($v in $vars) { $hits += ('line {0}: {1}' -f $v.Extent.StartLineNumber, $v.Extent.Text) }
    }
    Assert-Equal @() $hits
}

exit (Complete-Tests)
