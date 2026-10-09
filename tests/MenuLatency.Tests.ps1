# tests\MenuLatency.Tests.ps1
#
# Right-clicking the pill or the tray icon ran `powercfg /list` (a child
# process: 0.8-5s measured on a busy machine) inside the menu's Opening
# handler, so the menu could not appear until it finished - on every
# right-click, to fill a submenu most right-clicks never open. Power plans
# are now read when the Power Plan submenu itself opens.

. (Join-Path $PSScriptRoot '_harness.ps1')
Add-Type -AssemblyName System.Windows.Forms
. (Import-WidgetFunction 'Update-PowerPlanMenu')

Write-Host 'MenuLatency.Tests.ps1'

$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput((Get-AssembledWidgetText), [ref]$null, [ref]$errs)

function Get-HandlerRegistration {
    # Every `<target>.Add_<Event>({ ... })` in the widget source
    [OutputType([System.Management.Automation.Language.InvokeMemberExpressionAst[]])]
    param([System.Management.Automation.Language.Ast]$Root, [string]$EventName)
    return @($Root.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $n.Member.Value -eq ('Add_' + $EventName)
            }, $true))
}

function Get-CommandName {
    # Names of the commands a handler runs, including inside nested blocks
    [OutputType([string[]])]
    param([System.Management.Automation.Language.Ast]$Node)
    return @($Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
}

$slow = @('Update-PowerPlanMenu', 'Get-PowerPlans', 'powercfg')

Test-Case 'menus: no context-menu Opening handler reads the power plans' {
    $openings = Get-HandlerRegistration -Root $ast -EventName 'Opening'
    Assert-True ($openings.Count -ge 1) "found only $($openings.Count) Opening handlers - did the AST query break?"
    $hits = @()
    foreach ($o in $openings) {
        foreach ($name in (Get-CommandName -Node $o)) {
            if ($slow -contains $name) { $hits += ('line {0}: {1}.Add_Opening runs {2}' -f $o.Extent.StartLineNumber, $o.Expression.Extent.Text, $name) }
        }
    }
    Assert-True ($hits.Count -eq 0) ("a right-click waits on powercfg before the menu appears:`n  " + ($hits -join "`n  "))
}

Test-Case 'menus: both Power Plan submenus fill themselves when they open' {
    $targets = @(Get-HandlerRegistration -Root $ast -EventName 'DropDownOpening' |
            Where-Object { (Get-CommandName -Node $_) -contains 'Update-PowerPlanMenu' } |
            ForEach-Object { $_.Expression.Extent.Text })
    Assert-True ($targets -contains '$pillPowerItem') ('pill menu Power Plan has no DropDownOpening fill; found: ' + ($targets -join ', '))
    Assert-True ($targets -contains '$trayPowerItem') ('tray menu Power Plan has no DropDownOpening fill; found: ' + ($targets -join ', '))
}

Test-Case 'menus: both Power Plan items start with a placeholder (no arrow, no submenu without one)' {
    # An item with no children shows no arrow, and WinForms never opens (so
    # never fires DropDownOpening for) an empty dropdown: without the
    # placeholder the plans could not be reached at all.
    $seeded = @($ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $n.Member.Value -eq 'Add' -and
                $n.Expression -is [System.Management.Automation.Language.MemberExpressionAst] -and
                $n.Expression.Member.Extent.Text -eq 'DropDownItems'
            }, $true) | ForEach-Object { $_.Expression.Expression.Extent.Text })
    Assert-True ($seeded -contains '$pillPowerItem') 'the pill menu Power Plan item gets no placeholder'
    Assert-True ($seeded -contains '$trayPowerItem') 'the tray menu Power Plan item gets no placeholder'
}
Test-Case 'menus: the placeholder that gives the submenu its arrow is replaced by the plans' {
    function Get-PowerPlans {
        [OutputType([hashtable[]])]
        param()
        return @(
            @{ Name = 'Balanced'; GUID = '381b4222-f694-41f0-9685-ff5bb260df2e'; IsActive = $true },
            @{ Name = 'Power saver'; GUID = 'a1841308-3541-4fab-bc81-f71556f20b4a'; IsActive = $false }
        )
    }
    $item = New-Object System.Windows.Forms.ToolStripMenuItem('Power Plan')
    $placeholder = $item.DropDownItems.Add('Loading...')
    # (ToolStripItem.IsDisposed never turns true on .NET Framework - watch the event)
    $script:placeholderDisposed = $false
    $placeholder.Add_Disposed({ $script:placeholderDisposed = $true })
    Assert-True $item.HasDropDownItems 'the placeholder should give the item a submenu arrow'
    Update-PowerPlanMenu -MenuItem $item
    $names = @($item.DropDownItems | ForEach-Object { $_.Text })
    Assert-Equal 'Balanced|Power saver' ($names -join '|')
    Assert-True $script:placeholderDisposed 'the placeholder item was left undisposed'
    $item.Dispose()
}

exit (Complete-Tests)
