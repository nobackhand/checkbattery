# tests\BatterySource.Tests.ps1
#
# Where the battery numbers really come from.
#
# Get-BatteryInfo read DischargeRate and ChargeRate off the Win32_Battery
# instance - but that class has NO such properties, so on every real laptop
# both were $null: the watts line (v1.4.0's headline) and the rate-based time
# estimate never had input, and the capacities Win32_Battery leaves empty on
# most modern laptops starved the Health card. Every suite stubbed the WMI
# object WITH those properties, which is how it went unnoticed. BatteryQuery
# (010-init) now fills them from root\WMI, off the UI thread.

. (Join-Path $PSScriptRoot '_harness.ps1')

Write-Host 'BatterySource.Tests.ps1'

$text = Get-AssembledWidgetText
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BatteryInfo' }, $true)

# Every property Get-BatteryInfo reads off $wmiBattery
$reads = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.MemberExpressionAst] -and
            $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.Expression.VariablePath.UserPath -eq 'wmiBattery'
        }, $true) | ForEach-Object { $_.Member.Extent.Text } | Sort-Object -Unique)

# What can legitimately be on that object: the real Win32_Battery class, plus
# the values BatteryQuery fills from root\WMI
$win32 = @((Get-CimClass -ClassName Win32_Battery).CimClassProperties | ForEach-Object { $_.Name })
$filled = @([regex]::Matches($text, 'h\["(\w+)"\]\s*=\s*rates\["') | ForEach-Object { $_.Groups[1].Value })

Test-Case 'battery source: Win32_Battery really has no rate properties (the root cause)' {
    Assert-True ($win32.Count -gt 10) 'could not read the Win32_Battery class definition'
    Assert-Equal $false ($win32 -contains 'DischargeRate')
    Assert-Equal $false ($win32 -contains 'ChargeRate')
}

Test-Case 'battery source: everything Get-BatteryInfo reads actually has a source' {
    Assert-True ($reads.Count -ge 6) "found only $($reads.Count) reads - did the AST query break?"
    $missing = @($reads | Where-Object { $win32 -notcontains $_ -and $filled -notcontains $_ })
    Assert-True ($missing.Count -eq 0) ('read but never provided: ' + ($missing -join ', '))
}

# The real C# helper block, compiled as the widget compiles it
$csharp = $null
foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    if ($cmd.GetCommandName() -ne 'Add-Type') { continue }
    foreach ($el in $cmd.CommandElements) {
        if (($el -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                $el -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
            $el.Value -match 'class Win32Icon') { $csharp = $el.Value }
    }
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Management
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Management -TypeDefinition $csharp

Test-Case 'battery query: the first poll returns at once, without a reading' {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $first = [BatteryQuery]::Poll()
    Assert-True ($sw.ElapsedMilliseconds -lt 500) "Poll() blocked for $($sw.ElapsedMilliseconds)ms"
    Assert-Equal $null $first
}

Test-Case 'battery query: a later poll delivers the reading, and it matches this machine' {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $snap = $null
    while ($null -eq $snap -and $sw.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Milliseconds 100
        $snap = [BatteryQuery]::Poll()
    }
    Assert-True ($null -ne $snap) 'no reading within 60s'
    $hasBattery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
    Assert-Equal $hasBattery ([bool]$snap['Found'])
}

exit (Complete-Tests)
