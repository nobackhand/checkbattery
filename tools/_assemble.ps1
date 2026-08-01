# tools\_assemble.ps1
#
# Shared assembler for the widget source. The old single-file BatteryWidget.ps1
# was split into ordered modules under src\ (src\010-init.ps1 ... src\140-main.ps1);
# every consumer that needs the whole script - Build.ps1, tests\_harness.ps1,
# tools\render-states.ps1, BatteryWidget.Run.ps1 - dot-sources this file and
# concatenates the modules in filename order.
#
# The concatenation is byte-exact: each module's bytes are appended verbatim,
# the UTF-8 BOM of every module after the first is stripped, and nothing is
# inserted between modules. (A trailing-newline guard appends CRLF only if a
# module does not already end with a newline, so a future edit that drops a
# final newline cannot glue two modules onto one line.)

function Get-WidgetModulePath {
    <# Ordered list of the src\ module files that make up the widget. #>
    [OutputType([System.IO.FileInfo[]])]
    param()
    $srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    if (-not (Test-Path $srcDir)) { throw "widget source dir not found: $srcDir" }
    $files = @(Get-ChildItem -Path $srcDir -Filter '*.ps1' -File | Sort-Object Name)
    if ($files.Count -eq 0) { throw "no .ps1 modules in $srcDir" }
    return $files
}

function Write-AssembledWidget {
    <#
    .SYNOPSIS
        Writes the assembled widget script (BOM + every module, in order) to
        -OutFile at the byte level and returns that path.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$OutFile)
    $out = [System.IO.File]::Create($OutFile)
    try {
        $first = $true
        foreach ($f in (Get-WidgetModulePath)) {
            $b = [System.IO.File]::ReadAllBytes($f.FullName)
            $skip = 0
            if (-not $first -and $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $skip = 3 }
            $out.Write($b, $skip, $b.Length - $skip)
            if ($b.Length -gt 0 -and $b[$b.Length - 1] -ne 0x0A) {
                $out.WriteByte(0x0D)
                $out.WriteByte(0x0A)
            }
            $first = $false
        }
    } finally {
        $out.Close()
    }
    return $OutFile
}

function Get-AssembledWidgetText {
    <#
    .SYNOPSIS
        The assembled widget script as one string (no BOM), for consumers that
        parse or transform the source in memory instead of staging a file.
    #>
    [OutputType([string])]
    param()
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in (Get-WidgetModulePath)) {
        # ReadAllText detects and strips the BOM, so plain concatenation here
        # mirrors the byte-level assembly in Write-AssembledWidget.
        $t = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        [void]$sb.Append($t)
        if ($t.Length -gt 0 -and $t[$t.Length - 1] -ne "`n") { [void]$sb.Append("`r`n") }
    }
    return $sb.ToString()
}
