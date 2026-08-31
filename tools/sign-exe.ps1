# tools\sign-exe.ps1
#
# Signs a BatteryPill exe with Azure Trusted Signing (PS 5.1-safe).
# Configuration lives in signing.config.json at the repo root (machine-local,
# gitignored; copy signing.config.example.json and fill it in - see SIGNING.md
# for the one-time Azure setup).
#
# Exit codes (release.ps1 keys off these):
#   0  signed and verified
#   2  signing NOT CONFIGURED on this machine (no signing.config.json) -
#      caller decides whether an unsigned release is acceptable
#   1  signing was configured but FAILED - callers must treat this as fatal,
#      never ship an exe that was supposed to be signed and is not
#
# Auth: Invoke-TrustedSigning uses the ambient Azure credential (Azure CLI
# `az login`, Az PowerShell `Connect-AzAccount`, or AZURE_* env vars). The
# config file holds no secrets - it only names the signing account.

param(
    [Parameter(Mandatory = $true)][string]$ExePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repoRoot 'signing.config.json'

function Write-SignLog {
    [OutputType([void])]
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host "[sign] $Message" -ForegroundColor $Color
}

if (-not (Test-Path $ExePath)) {
    Write-SignLog "file not found: $ExePath" 'Red'
    exit 1
}

if (-not (Test-Path $configPath)) {
    Write-SignLog 'not configured (no signing.config.json at repo root) - skipping' 'Yellow'
    Write-SignLog 'see SIGNING.md to set up Azure Trusted Signing on this machine' 'Yellow'
    exit 2
}

# ---- Read and validate config ----
try {
    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
} catch {
    Write-SignLog "signing.config.json is unreadable: $($_.Exception.Message)" 'Red'
    exit 1
}
foreach ($field in @('Endpoint', 'AccountName', 'ProfileName')) {
    if (-not $cfg.$field) {
        Write-SignLog "signing.config.json is missing '$field' (see signing.config.example.json)" 'Red'
        exit 1
    }
}

# ---- Ensure the TrustedSigning module ----
if (-not (Get-Module -ListAvailable -Name TrustedSigning)) {
    Write-SignLog 'installing TrustedSigning module (CurrentUser)...' 'Yellow'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-Module -Name TrustedSigning -Scope CurrentUser -Force -ErrorAction Stop
    } catch {
        Write-SignLog "could not install the TrustedSigning module: $($_.Exception.Message)" 'Red'
        exit 1
    }
}

# ---- Preflight: ambient Azure credential ----
# Not authoritative (env-var and VS credentials also work) - this just turns
# the most common failure into a clear message instead of a deep stack trace.
$azCli = Get-Command az -ErrorAction SilentlyContinue
$azOk = $false
if ($azCli) {
    & az account show --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $azOk = $true }
}
if (-not $azOk -and -not $env:AZURE_CLIENT_ID) {
    Write-SignLog 'no Azure CLI login detected (az account show failed) and no AZURE_* env credentials' 'Yellow'
    Write-SignLog 'if signing fails with an auth error: run "az login" first (see SIGNING.md)' 'Yellow'
}

# ---- Sign ----
Write-SignLog "signing $(Split-Path -Leaf $ExePath) via $($cfg.AccountName)/$($cfg.ProfileName)..." 'Cyan'
try {
    Invoke-TrustedSigning `
        -Endpoint $cfg.Endpoint `
        -CodeSigningAccountName $cfg.AccountName `
        -CertificateProfileName $cfg.ProfileName `
        -Files $ExePath `
        -FileDigest SHA256 `
        -TimestampRfc3161 'http://timestamp.acs.microsoft.com' `
        -TimestampDigest SHA256
} catch {
    Write-SignLog "signing FAILED: $($_.Exception.Message)" 'Red'
    exit 1
}

# ---- Verify: never report success on an unverified signature ----
$sig = Get-AuthenticodeSignature -LiteralPath $ExePath
if ($sig.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    Write-SignLog "signature did not verify: status=$($sig.Status) ($($sig.StatusMessage))" 'Red'
    exit 1
}
$subject = if ($null -ne $sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '(unknown signer)' }
Write-SignLog "signed and verified: $subject" 'Green'
if ($null -ne $sig.TimeStamperCertificate) {
    Write-SignLog 'timestamped (signature outlives certificate rotation)' 'Green'
}
exit 0
