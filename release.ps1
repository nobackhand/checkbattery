#Requires -Version 5.0

<#
.SYNOPSIS
    One-command release for BatteryPill.
.DESCRIPTION
    Reads the version from the widget source ($script:appVersion in
    src\010-init.ps1), refuses to
    run on a dirty tree or an already-released version, runs the full verify
    gate (scripts/verify.sh via bash), builds the exe, tags v<version>, pushes
    the tag, and creates a GitHub release carrying two assets:
      - BatteryPill-<version>.exe  (versioned, immutable)
      - BatteryPill.exe            (stable name; the website's
        /releases/latest/download/BatteryPill.exe URL always serves the
        newest release without any site edit)
.EXAMPLE
    .\release.ps1
    # Bump $script:appVersion in src\010-init.ps1 first, then run this.
#>

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

function Stop-Release {
    [OutputType([void])]
    param([string]$reason)
    Write-Host "ABORT: $reason" -ForegroundColor Red
    exit 1
}

# ---- Version (same regex Build.ps1 uses) ----
$versionLine = Select-String -Path (Join-Path $repoRoot 'src\*.ps1') -Pattern '^\$script:appVersion\s*=\s*"(.+?)"' | Select-Object -First 1
if (-not $versionLine) {
    Stop-Release 'could not read $script:appVersion from src\*.ps1'
}
$appVersion = $versionLine.Matches[0].Groups[1].Value
$tag = "v$appVersion"
Write-Host "Releasing BatteryPill $tag" -ForegroundColor Cyan

# ---- Guard: tools present ----
foreach ($toolName in @('git', 'gh', 'bash')) {
    if (-not (Get-Command $toolName -ErrorAction SilentlyContinue)) {
        Stop-Release "required tool not on PATH: $toolName"
    }
}

# ---- Guard: clean working tree ----
$dirty = git -C $repoRoot status --porcelain
if ($LASTEXITCODE -ne 0) {
    Stop-Release 'git status failed'
}
if ($dirty) {
    Write-Host $dirty
    Stop-Release 'working tree is dirty - commit or stash before releasing'
}

# ---- Guard: tag must not exist (local or remote) ----
$existingLocal = git -C $repoRoot tag --list $tag
$existingRemote = git -C $repoRoot ls-remote --tags origin "refs/tags/$tag"
if ($existingLocal -or $existingRemote) {
    Stop-Release "tag $tag already exists - bump `$script:appVersion in src\010-init.ps1 first"
}

# ---- Verify gate (lint + tests + build) ----
Write-Host 'Running scripts/verify.sh...' -ForegroundColor Cyan
bash (Join-Path $repoRoot 'scripts/verify.sh')
if ($LASTEXITCODE -ne 0) {
    Stop-Release 'scripts/verify.sh failed'
}

# ---- Build the release exe ----
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'Build.ps1')
if ($LASTEXITCODE -ne 0) {
    Stop-Release 'Build.ps1 failed'
}
$versionedExe = Join-Path $repoRoot "BatteryPill-$appVersion.exe"
if (-not (Test-Path $versionedExe)) {
    Stop-Release "expected build output not found: $versionedExe"
}

# ---- Sign (Azure Trusted Signing; see SIGNING.md) ----
# Signed BEFORE the stable-named copy so both release assets carry the same
# signature. Three outcomes from tools\sign-exe.ps1:
#   exit 0 = signed + verified; exit 2 = not configured on this machine
#   (release continues UNSIGNED, loudly); anything else = configured but
#   failed - abort rather than ship an exe that was meant to be signed.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tools\sign-exe.ps1') -ExePath $versionedExe
$signExit = $LASTEXITCODE
if ($signExit -eq 0) {
    Write-Host 'Release exe signed and verified.' -ForegroundColor Green
} elseif ($signExit -eq 2) {
    Write-Host 'WARNING: releasing UNSIGNED (signing not configured on this machine - see SIGNING.md)' -ForegroundColor Yellow
} else {
    Stop-Release 'signing is configured but failed - not shipping a half-signed release'
}

# ---- Stable-named copy for the website's /releases/latest URL ----
$stageDir = Join-Path $env:TEMP "batterypill-release-$appVersion"
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
$stableExe = Join-Path $stageDir 'BatteryPill.exe'
Copy-Item $versionedExe $stableExe -Force

# ---- Tag, push, release ----
git -C $repoRoot tag $tag
if ($LASTEXITCODE -ne 0) {
    Stop-Release "git tag $tag failed"
}
git -C $repoRoot push origin $tag
if ($LASTEXITCODE -ne 0) {
    Stop-Release "git push origin $tag failed"
}
gh release create $tag --generate-notes $versionedExe $stableExe
if ($LASTEXITCODE -ne 0) {
    Stop-Release "gh release create $tag failed"
}

$releaseUrl = gh release view $tag --json url --jq '.url'
Write-Host ''
Write-Host 'Release complete.' -ForegroundColor Green
Write-Host "  Tag:     $tag" -ForegroundColor Green
Write-Host "  Assets:  BatteryPill-$appVersion.exe, BatteryPill.exe" -ForegroundColor Green
Write-Host "  URL:     $releaseUrl" -ForegroundColor Green
Write-Host '  Stable:  https://github.com/nobackhand/checkbattery/releases/latest/download/BatteryPill.exe' -ForegroundColor Green
