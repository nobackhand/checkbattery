# Code signing (Azure Trusted Signing)

Why: unsigned PS2EXE builds are hard-blocked by Smart App Control (no "Run
anyway") and get the SmartScreen scare screen everywhere else - see
DISTRIBUTION.md, 2026-08-30 findings. Trusted Signing is Microsoft's own
signing service: $9.99/mo Basic, certificate chains to a Microsoft CA, which
is exactly what SAC checks for.

The release pipeline is already wired: `release.ps1` calls
`tools\sign-exe.ps1` after every build. Until the one-time setup below is
done, it prints a loud "releasing UNSIGNED" warning and continues; once
`signing.config.json` exists, releases sign-and-verify automatically and a
signing failure aborts the release.

## One-time setup (~20 min of clicking + a validation wait)

Steps 1-4 are yours (account + card + identity). Step 5 is filling in one
JSON file - paste the three values into chat and Claude finishes it.

1. **Azure account** - https://azure.microsoft.com/free
   Sign up (card required at signup; nothing is billed until step 3's
   resource exists - after that it's $9.99/mo).

2. **Install the Azure CLI** (for signing auth on this machine):
   `winget install Microsoft.AzureCLI`, then `az login`.

3. **Create the Trusted Signing account** - in the Azure portal, search
   "Trusted Signing Accounts" -> Create.
   - Subscription/resource group: create one, e.g. `rg-batterypill`
   - Account name: e.g. `batterypill-signing` (globally unique)
   - Region: East US (endpoint becomes https://eus.codesigning.azure.net)
   - SKU: **Basic** ($9.99/mo)

4. **Identity validation** - in the account: Identity validations -> New ->
   **Individual**. Fill in legal name/address, complete the ID check.
   Individual validation is available for the USA and Canada. This is the
   step with a wait (often 1-3 business days; can be faster).
   Then: Certificate profiles -> Create -> **Public Trust**, pick the
   validated identity, name it e.g. `batterypill-public`.

5. **Tell the repo about it** - copy `signing.config.example.json` to
   `signing.config.json` (gitignored) and fill in:
   - `Endpoint`: the region endpoint from step 3
   - `AccountName`: the Trusted Signing account name
   - `ProfileName`: the certificate profile name

6. **Prove it**: run `.\release.ps1` on the next version bump - the log
   should show `[sign] signed and verified: CN=<your name>...`. Or dry-run
   against an existing build:
   `powershell -ExecutionPolicy Bypass -File tools\sign-exe.ps1 -ExePath .\BatteryPill-<ver>.exe`

## Notes

- **RBAC**: your portal user needs the *Trusted Signing Certificate Profile
  Signer* role on the account (portal -> the account -> Access control).
  The creator/owner does not get it automatically - add it once.
- Auth is ambient (`az login`); `signing.config.json` holds no secrets.
- Signatures are RFC-3161 timestamped (`timestamp.acs.microsoft.com`), so
  shipped exes stay valid as Microsoft rotates the short-lived certs.
- Machine prereqs are handled by `tools\sign-exe.ps1` (installs the
  `TrustedSigning` PowerShell module on first use). If it complains about
  a missing .NET runtime, install ".NET 8 Desktop Runtime x64" and retry.
- SmartScreen reputation still accrues from download volume after signing;
  the SAC hard-block, however, is fixed immediately by the trusted chain.
- Cancel anytime: delete the Trusted Signing account resource in the portal
  to stop the $9.99/mo; already-shipped signatures remain valid (timestamped).
