# Distribution: signing, SmartScreen, and the DPI ceiling

Decision record for how BatteryPill is distributed. Last reviewed 2026-07-31.

## Current state

- BatteryPill ships as an **unsigned** `.exe`, compiled from PowerShell with PS2EXE,
  published via GitHub Releases (`release.ps1` uploads a versioned exe plus a
  stable-named `BatteryPill.exe` that the website's download button points at).
- What users experience:
  - **SmartScreen**: "Windows protected your PC" on first run of a downloaded copy.
    Dismissable via "More info" then "Run anyway". The website's install steps say so
    up front.
  - **AV flags**: some engines heuristically flag PS2EXE output because malware has
    abused the same packer. False positives are possible on VirusTotal and in
    stricter corporate AV.
- Why: two independent causes. (1) The exe carries no Authenticode signature, so it
  has no publisher identity and no SmartScreen reputation to inherit. (2) PS2EXE's
  packer has a poor reputation with AV heuristics regardless of signing.

## Options considered

Prices checked 2026-07 (list prices, rounded; see sources at bottom).

### (a) OV code-signing certificate

- ~$200-300/yr from Sectigo/Comodo resellers (from ~$219/yr); DigiCert ~$400/yr.
- Requires CA identity vetting of an individual or business.
- Removes the "unknown publisher" edge, but SmartScreen reputation still builds
  gradually from download volume. Does nothing for PS2EXE AV heuristics.

### (b) Azure Trusted Signing (renamed Azure Artifact Signing in 2026)

- $9.99/mo Basic tier (up to 5,000 signatures/mo).
- Cheapest legitimate signing path. Requires Azure account plus identity validation;
  individual-developer signup is generally available for individuals in the USA and
  Canada (it spent a long stretch org-only/preview, so re-verify status before
  committing). No free tier for open source.

### (c) EV code-signing certificate

- ~$300-700/yr, hardware token or cloud HSM required, strictest vetting.
- Historically bought instant SmartScreen reputation. **No longer**: since Microsoft's
  March 2024 Trusted Root Program change, EV and OV build SmartScreen reputation the
  same way, from download volume. EV's premium is now hard to justify for this
  project.

### (d) Do nothing + honest website messaging (CHOSEN)

- $0. The website and README tell users exactly what they'll see and why, with a
  link to the source so they can verify the code themselves.
- Honest about the trade-off: some users will bounce at the SmartScreen prompt, and
  AV false positives remain possible.

### (e) Longer term: native rewrite (C# / WinUI)

- Fixes the AV problem at the root: a normally compiled binary has none of PS2EXE's
  packer stigma.
- Also breaks the **DPI ceiling**: the current widget is system-DPI-aware via a
  `SetProcessDPIAware()` P/Invoke, so on mixed-DPI multi-monitor setups Windows
  bitmap-stretches it on the second monitor (blurry pill/popup). Per-Monitor-V2
  awareness needs an application manifest plus `WM_DPICHANGED` handling, both of
  which are painful to retrofit through PS2EXE and WinForms-from-PowerShell. A
  native app declares the manifest and handles the message idiomatically.

## Decision

- **Now: (d).** Free tool, small download volume; signing spend isn't justified yet,
  and signing wouldn't fix the PS2EXE AV heuristics anyway. Be honest on the website
  instead.
- **Revisit signing** (Azure Artifact Signing first, at $9.99/mo, then OV) when
  download volume makes the SmartScreen bounce rate hurt.
- **The rewrite (e) is the eventual ceiling-breaker** for both AV reputation and
  per-monitor DPI. Signing an exe that AV engines still dislike is half a fix.

## Sources

- Azure pricing: https://azure.microsoft.com/en-us/pricing/details/trusted-signing/
- Individual signup GA (USA/Canada): https://techcommunity.microsoft.com/blog/microsoft-security-blog/trusted-signing-is-now-open-for-individual-developers-to-sign-up-in-public-previ/4273554
- OV/EV price ranges: https://www.ssldragon.com/ssl-certificates/code-signing/ and https://www.ssl.com/products/software-integrity/code-signing/ev/
- EV SmartScreen change (March 2024): https://www.ssl.com/faqs/which-code-signing-certificate-do-i-need-ev-ov/
