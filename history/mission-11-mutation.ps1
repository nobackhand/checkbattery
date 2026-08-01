# history\mission-11-mutation.ps1 (one-off harness from mission 11; lived in tools\)
#
# Negative control for tests\Adversarial.Tests.ps1 (mission 11).
#
# A test that passes proves nothing on its own - it has to FAIL when the guard
# it covers is removed. This copies the repo into a temp dir, reverts ONE
# input-validation guard per run (back to the exact expression it replaced),
# runs the adversarial suite against the mutant, and reports which cases died.
#
# Every mutation below must kill at least one test. The repo itself is never
# touched. Exit code: 0 = every mutation was caught, 1 = a surviving mutant.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# Each mutation: a guard, and the pre-hardening code it is reverted to.
$mutations = @(
    @{
        Name = 'M1 WMI runtime fallback casts straight to [int] (pre-fix code)'
        File = 'BatteryWidget.ps1'
        From = '$runFallback = if ($wmiBattery) { Read-DeviceNumber -Raw $wmiBattery.EstimatedRunTime -Min 1 } else { $null }'
        To   = '$runFallback = if ($wmiBattery -and $wmiBattery.EstimatedRunTime) { [int]$wmiBattery.EstimatedRunTime } else { $null }'
    },
    @{
        Name = 'M2 percent is trusted without a range check'
        File = 'BatteryWidget.ps1'
        From = '$wmiPct = Read-DeviceNumber -Raw $wmiBattery.EstimatedChargeRemaining -Min 0 -Max 100'
        To   = '$wmiPct = Read-DeviceNumber -Raw $wmiBattery.EstimatedChargeRemaining -Min 0 -Max 4294967295'
    },
    @{
        Name = 'M3 an unreadable percent is allowed to read as Critical'
        File = 'BatteryWidget.ps1'
        From = '} elseif ($info.Percent -ge 0 -and $info.Percent -le 10) {'
        To   = '} elseif ($info.Percent -le 10) {'
    },
    @{
        Name = 'M4 Opacity NaN guard removed'
        File = 'BatteryWidget.ps1'
        From = 'if ([double]::IsNaN($o)) { return $null }'
        To   = 'if ($false) { return $null }'
    },
    @{
        Name = 'M5 powercfg plan id is not validated as a GUID'
        File = 'BatteryWidget.ps1'
        From = 'if (-not $PlanGUID -or $PlanGUID -notmatch $script:powerPlanGuidPattern) { return $false }'
        To   = 'if (-not $PlanGUID) { return $false }'
    },
    @{
        Name = 'M6 powercfg output rows are not filtered by GUID shape'
        File = 'BatteryWidget.ps1'
        From = 'if ($guid -notmatch $script:powerPlanGuidPattern) { continue }'
        To   = 'if ($false) { continue }'
    },
    @{
        Name = 'M7 BatteryStatus is trusted verbatim'
        File = 'BatteryWidget.ps1'
        From = '$batteryStatus = Read-DeviceNumber -Raw $wmiBattery.BatteryStatus -Min 1 -Max 11'
        To   = '$batteryStatus = $wmiBattery.BatteryStatus'
    },
    @{
        Name = 'M8 the CLI casts the dual-battery array instead of taking pack 1'
        File = 'CheckBattery.ps1'
        From = '$wmiBattery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop) | Select-Object -First 1'
        To   = '$wmiBattery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop'
    },
    @{
        Name = 'M9 Read-DeviceNumber lets NaN/Infinity through'
        File = 'BatteryWidget.ps1'
        From = 'if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return $null }'
        To   = 'if ($false) { return $null }'
    },
    @{
        Name = 'M10 Read-DeviceNumber drops the range check'
        File = 'BatteryWidget.ps1'
        From = 'if ($value -lt $Min -or $value -gt $Max) { return $null }'
        To   = 'if ($false) { return $null }'
    }
)

$survivors = 0
foreach ($m in $mutations) {
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("bp-mut-{0}-{1}" -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        Copy-Item (Join-Path $repoRoot 'BatteryWidget.ps1') $work
        Copy-Item (Join-Path $repoRoot 'CheckBattery.ps1') $work
        Copy-Item (Join-Path $repoRoot 'tests') $work -Recurse

        $target = Join-Path $work $m.File
        $text = [System.IO.File]::ReadAllText($target)
        if ($text.IndexOf($m.From, [System.StringComparison]::Ordinal) -lt 0) {
            Write-Host ("SETUP-FAIL {0}: anchor not found in {1}" -f $m.Name, $m.File)
            $survivors++
            continue
        }
        $text = $text.Replace($m.From, $m.To)
        [System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding $true))

        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $work 'tests\Adversarial.Tests.ps1') 2>&1
        $failed = @($out | Where-Object { $_ -match '^\s+FAIL\s' })
        if ($failed.Count -eq 0) {
            Write-Host ("SURVIVED  {0} - no test noticed" -f $m.Name)
            $survivors++
        } else {
            Write-Host ("KILLED    {0}" -f $m.Name)
            foreach ($line in $failed) { Write-Host ("            {0}" -f $line.ToString().Trim()) }
        }
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '---'
if ($survivors -eq 0) {
    Write-Host ("RESULT: PASS - all {0} mutation(s) killed" -f $mutations.Count)
    exit 0
}
Write-Host ("RESULT: FAIL - {0} mutation(s) survived" -f $survivors)
exit 1
