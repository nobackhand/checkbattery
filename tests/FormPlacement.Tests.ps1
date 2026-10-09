# tests\FormPlacement.Tests.ps1
#
# A WinForms Form's StartPosition defaults to WindowsDefaultLocation, which
# makes Windows IGNORE a Location set before Show() and drop the window at its
# default cascade spot. Two windows positioned themselves that way: every
# notification card (low/critical battery warnings, charging, fully charged)
# appeared near the left edge instead of bottom-right (measured X=228 vs
# 2390), and the first-run tips landed top-left (114,114) with the pill
# bottom-right. Guard: any form the widget creates and gives a Location must
# also set its StartPosition.

. (Join-Path $PSScriptRoot '_harness.ps1')

Write-Host 'FormPlacement.Tests.ps1'

$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput((Get-AssembledWidgetText), [ref]$null, [ref]$errs)

# Variables assigned a new Form / NoActivateForm: $x = New-Object <form type>
$formVars = @{}
foreach ($asg in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $rhs = $asg.Right.Extent.Text
    if ($rhs -match '^New-Object\s+(System\.Windows\.Forms\.Form|NoActivateForm)\s*$') {
        $formVars[$asg.Left.Extent.Text] = $asg.Extent.StartLineNumber
    }
}

# Property assignments on those variables: $x.Location = ... / $x.StartPosition = ...
$setLocation = @{}; $setStart = @{}
foreach ($asg in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $left = $asg.Left
    if ($left -isnot [System.Management.Automation.Language.MemberExpressionAst]) { continue }
    $owner = $left.Expression.Extent.Text
    if (-not $formVars.ContainsKey($owner)) { continue }
    $member = $left.Member.Extent.Text
    if ($member -eq 'Location') { $setLocation[$owner] = $true }
    if ($member -eq 'StartPosition') { $setStart[$owner] = $true }
}

Test-Case 'placement: the guard finds the widget''s forms' {
    Assert-True ($formVars.Count -ge 8) "found only $($formVars.Count) form variables - did the AST query break?"
}

Test-Case 'placement: every form that sets a Location also sets StartPosition' {
    $bad = @()
    foreach ($v in $setLocation.Keys) {
        if (-not $setStart.ContainsKey($v)) { $bad += ('{0} (created at line {1})' -f $v, $formVars[$v]) }
    }
    Assert-True ($bad.Count -eq 0) ('forms positioned without StartPosition: ' + ($bad -join '; '))
}

exit (Complete-Tests)
