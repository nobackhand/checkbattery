# tests\FormPlacement.Tests.ps1
#
# A WinForms Form's StartPosition defaults to WindowsDefaultLocation, which
# makes Windows IGNORE a position set before Show() and drop the window at its
# default cascade spot. Two windows positioned themselves that way: every
# notification card (low/critical battery warnings, charging, fully charged)
# appeared near the left edge instead of bottom-right (measured X=228 vs
# 2390), and the first-run tips landed top-left (114,114) with the pill
# bottom-right. Guard: any form the widget creates and positions must also set
# its StartPosition - checked per function, since two functions can reuse the
# same variable name ($popup) for different forms.

. (Join-Path $PSScriptRoot '_harness.ps1')

Write-Host 'FormPlacement.Tests.ps1'

$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput((Get-AssembledWidgetText), [ref]$null, [ref]$errs)

function Get-OwnerFunction {
    # The innermost function a node sits in ('' for top-level script code)
    [OutputType([string])]
    param([System.Management.Automation.Language.Ast]$Node)
    $p = $Node.Parent
    while ($null -ne $p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }
        $p = $p.Parent
    }
    return ''
}

$formTypes = '(System\.Windows\.Forms\.Form|NoActivateForm)'
$created = @{}; $positioned = @{}; $started = @{}
foreach ($asg in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $owner = Get-OwnerFunction -Node $asg
    $rhs = $asg.Right.Extent.Text.Trim()
    if ($rhs -match "^New-Object\s+(-TypeName\s+)?$formTypes\s*$" -or $rhs -match "^\[$formTypes\]::new\(") {
        $created["$owner|$($asg.Left.Extent.Text)"] = $asg.Extent.StartLineNumber
        continue
    }
    if ($asg.Left -is [System.Management.Automation.Language.MemberExpressionAst]) {
        $key = "$owner|$($asg.Left.Expression.Extent.Text)"
        $member = $asg.Left.Member.Extent.Text
        if ($member -in @('Location', 'Left', 'Top', 'DesktopLocation', 'Bounds')) { $positioned[$key] = $true }
        if ($member -eq 'StartPosition') { $started[$key] = $true }
    }
}
foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
    if ($call.Member.Extent.Text -in @('SetBounds', 'SetDesktopLocation', 'SetDesktopBounds')) {
        $positioned["$(Get-OwnerFunction -Node $call)|$($call.Expression.Extent.Text)"] = $true
    }
}

Test-Case 'placement: the guard finds the widget''s forms' {
    Assert-True ($created.Count -ge 8) "found only $($created.Count) forms - did the AST query break?"
}

Test-Case 'placement: every form that is positioned also sets StartPosition' {
    $bad = @()
    foreach ($k in $created.Keys) {
        if ($positioned.ContainsKey($k) -and -not $started.ContainsKey($k)) {
            $bad += ('{0} (created at line {1})' -f $k, $created[$k])
        }
    }
    Assert-True ($bad.Count -eq 0) ('forms positioned without StartPosition: ' + ($bad -join '; '))
}

exit (Complete-Tests)
