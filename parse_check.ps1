$e = @()
$null = [System.Management.Automation.Language.Parser]::ParseFile('C:\Users\d\Desktop\myprojects\batterypill\BatteryWidget.ps1', [ref]$null, [ref]$e)
Write-Output "Error count: $($e.Count)"
foreach ($err in $e) {
    Write-Output "  Line $($err.Extent.StartLineNumber): $($err.Message)"
}
