# tests\NativeHelpers.Tests.ps1
#
# The C# helper types in 010-init's single Add-Type block. Every other suite
# stubs or skips them, so before this file nothing in CI ever compiled the
# real block: a C# error (or a C# 6 feature the PS 5.1 compiler rejects)
# would first surface as a widget that dies at launch.
#
# PowerMeterProbe is also exercised for real here, against a stand-in
# counter set every Windows machine has (Processor/_Total), because the dev
# box and CI runners have no usable "Power Meter" instance.

. (Join-Path $PSScriptRoot '_harness.ps1')

Write-Host 'NativeHelpers.Tests.ps1'

$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput((Get-AssembledWidgetText), [ref]$null, [ref]$errs)
$csharp = $null
foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    if ($cmd.GetCommandName() -ne 'Add-Type') { continue }
    foreach ($el in $cmd.CommandElements) {
        if (($el -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                $el -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
            $el.Value -match 'class Win32Icon') { $csharp = $el.Value }
    }
}

Test-Case 'native: the single Add-Type helper block is found' {
    Assert-True ($null -ne $csharp) 'no Add-Type here-string containing class Win32Icon'
    Assert-True ($csharp -notmatch '\$') 'the block is an expandable here-string: a $ in the C# would be expanded by PowerShell'
}

Test-Case 'native: the helper block compiles under Windows PowerShell 5.1' {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $csharp
    Assert-True ($null -ne ('PowerMeterProbe' -as [type])) 'PowerMeterProbe missing after compile'
    Assert-True ($null -ne ('Win32Icon' -as [type])) 'Win32Icon missing after compile'
}

# The real PowerMeterProbe source, pointed at Processor/_Total and renamed so
# it does not collide with the copy compiled above.
$probeSrc = [regex]::Match($csharp, '(?s)public static class PowerMeterProbe \{.*?\r?\n\}').Value
$standIn = $probeSrc.Replace('class PowerMeterProbe', 'class PowerMeterProbeStandIn').
Replace('"Power Meter", "Power", "_Total"', '"Processor", "% Processor Time", "_Total"').
Replace('"Power Meter"', '"Processor"')
Add-Type -TypeDefinition ("using System;`r`n" + $standIn)

function Wait-ProbeState {
    [OutputType([int])]
    param()
    # The first perf query in a process can take many seconds; poll it.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $s = [PowerMeterProbeStandIn]::State()
        if ($s -ne 0) { return $s }
        Start-Sleep -Milliseconds 100
    } while ($sw.Elapsed.TotalSeconds -lt 90)
    return 0
}

Test-Case 'meter probe: State() never blocks the caller while the probe runs' {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = [PowerMeterProbeStandIn]::State()
    Assert-True ($sw.ElapsedMilliseconds -lt 1000) "first State() call took $($sw.ElapsedMilliseconds)ms"
}

Test-Case 'meter probe: an existing counter set resolves to ready, and reads' {
    Assert-Equal 1 (Wait-ProbeState)
    $v = [PowerMeterProbeStandIn]::Read()
    Assert-True ($v -ge 0) "Read() returned $v"
}

Test-Case 'meter probe: Close() is final - State() does not hand back the disposed counter' {
    [PowerMeterProbeStandIn]::Close()
    Assert-Equal (-1) ([PowerMeterProbeStandIn]::State())
}

exit (Complete-Tests)
