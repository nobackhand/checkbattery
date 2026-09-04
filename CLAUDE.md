# CLAUDE.md — Project Context

## Overview

**BatteryPill** is a Windows desktop battery widget built in PowerShell with WinForms, compiled to `.exe` via PS2EXE. It shows a floating pill-shaped indicator on the desktop displaying time remaining, with a detailed popup on click and a system tray icon.

**Website**: batterypill.com (GitHub Pages from `docs/`)
**Donate**: buymeacoffee.com/nobackhand

## Architecture

- **src/** — The widget source, split into 14 ordered modules (`010-init.ps1` … `140-main.ps1`) that concatenate byte-exactly, in filename order, into the single script that ships (`tools\_assemble.ps1` is the shared assembler; dot-source it and call `Write-AssembledWidget`/`Get-AssembledWidgetText`). The widget creates a system tray `NotifyIcon` with context menu and a floating transparent pill bar. Uses WMI (`Win32_Battery`) for battery data with EMA-smoothed time estimates, a 3-second timer for updates, and a config file for persisting bar position. Supports dark/light/auto themes, configurable pill size and display mode, accent color presets, battery history sparkline, and fullscreen auto-hide. `$script:appVersion` lives in `src\010-init.ps1`.
- **BatteryWidget.Run.ps1** — Source-run wrapper: assembles `src\` to `%TEMP%\BatteryPill-source-run\BatteryWidget.ps1`, carries the repo-root config json to/from the staging dir, and runs it via `powershell -STA -File`.
- **Build.ps1** — Assembles `src\` to a temp staging file and compiles it to `BatteryPill-<version>.exe` using `Invoke-PS2EXE`.
- **release.ps1** — One-command GitHub release: refuses a dirty tree or already-released version, runs `scripts/verify.sh`, builds, tags `v<version>`, and uploads two assets (versioned exe + stable-named `BatteryPill.exe` that the website's download button always points at).
- **.github/workflows/verify.yml** — CI: runs `scripts/verify.sh` on windows-latest for every push and PR.
- **tests/** — `scripts/run-tests.ps1` runs every `tests\*.Tests.ps1`. The suite loads functions out of the assembled source via `tests\_harness.ps1`'s `Import-WidgetFunction` (AST lift — no message loop, no forms), so **anything you want tested has to be a named function**; that constraint is why presentation and lifecycle logic keeps getting extracted out of the big handlers (`Get-PillText`, `Get-TimeSentence`, `Get-PillDimensions`, `Get-DisplayChangeAction`, `Clear-ExpiredMoments`, `Add-BatteryHistorySample`, `Restore-EstimatorState`, `New-SingleInstanceMutex`, `Test-RectCoversScreen`, `Get-PowerDraw`, `Get-PowerText`, `Get-PowerSentence`, `Get-PowerDrawStats`). Extract, don't test-through-the-form.
- **CheckBattery.ps1** — Standalone CLI script for quick battery status checks.
- **CheckBattery.bat** — Batch launcher for `CheckBattery.ps1`.
- **DISTRIBUTION.md** — What users hit installing an unsigned PS2EXE exe (SmartScreen, AV flags) and the signing/rewrite decision record.
- **docs/index.html** — Splash/landing page served via GitHub Pages at batterypill.com. Single HTML file with embedded CSS/JS, dark theme, scroll animations.
- **docs/CNAME** — Custom domain config for GitHub Pages (batterypill.com).
- **history/** — Archived mission records and evidence from past improvement loops; historical reference only, never load-bearing.

## Key Technical Decisions

### Rounded Corners (two mechanisms)
- **The pill** uses Region-based clipping with `GraphicsPath` (no `TransparencyKey` = no purple fringe) — it's a capsule, which DWM can't produce.
- **Popups/cards/notifications/tips** use native Win11 DWM rounded corners (`Set-NativeRoundedCorners` → `Win32Icon.TryRoundCorners`, DWMWA 33 = DWMWCP_ROUND): antialiased edges + the system window shadow. On Win10 (DWM call fails) they fall back to CS_DROPSHADOW + the old Region clip inside the same helper.
- All C# helper types (`Win32Icon`, `DarkMenuColorTable`, `DarkCheckBox`, `PillMenuRenderer`) compile in ONE `Add-Type` call in `010-init.ps1` — splitting them back into separate calls costs ~1s of launch time (measured).

### Floating Pill Bar
- `AutoScaleMode = None` set **before** `Size`, plus `MinimumSize`/`MaximumSize` constraints (108x34) to prevent WinForms DPI auto-scaling.
- Custom `Paint` handler draws gradient battery fill, glass highlight, centered text, and border using GDI+.
- Double-buffered via reflection for flicker-free rendering.
- Event handlers use `$script:floatingBar` (not local variables) to avoid PowerShell scriptblock scoping issues.

### DPI Awareness
- `SetProcessDPIAware()` P/Invoke called before any forms are created.
- `AutoScaleMode = None` on both floating bar and popup forms.
- All popup labels use `AutoSize = $true` with `MaximumSize` width constraints — lets WinForms measure actual rendered text at any DPI scale.

### Display
- Pill shows time remaining (e.g., "3h 8m") instead of percentage.
- Green accent fill (left-to-right gradient, semi-transparent) conveys charge level.
- Font: Segoe UI Semibold 10.2pt Bold.

### Power Draw (watts) — v1.4.0
- `Get-PowerDraw` (020) is the source ladder: the platform power meter (`\Power Meter(_Total)\Power`, ACPI EMI — read via a cached `PerformanceCounter` in `Read-PowerMeterMilliwatts`, probed once and remembered as unavailable) wins when it reports; otherwise the pack: `DischargeRate` while draining IS the system draw. Plugged in and not charging there is no number, and every consumer treats that as "say nothing" — the popup omits the line, the pill's `power` mode reads `AC`.
- **A charge rate is never shown as consumption.** `PowerDrawKind` is `draw` or `charge`; charging renders as `+45 W` / "Charging at 45 W", and `Add-BatteryHistorySample` records `Watts = -1` for it so `Get-PowerDrawStats` (avg/peak over the current discharge run, same walk-back rules as `Get-BatterySessionSummary`) never averages inflow into draw.
- Verified on a real laptop (ZBook Ultra G1A, plugged in at a charge cap): Power Meter instances exist but read 0, and both `Win32_Battery` rates are null — so 0 and null both mean "no reading". Firmware rates above 300 W are dropped as glitches.
- `Get-PowerDrawStats` returns a `Samples` key, not `Count`: a hashtable's own `.Count` property shadows a key of that name (`@{Count=0}.Count` is 1).

### Detail Popup
- Hover over the pill (350ms delay) to show: percent, capacity, charge/discharge rate, time remaining with ETA, elapsed time, full runtime estimate, battery wear.
- Non-modal popup stays open while mouse is over pill or popup, dismisses when mouse leaves both.
- 360px wide (DPI-scaled), positioned near the pill, auto-sized height. Positioning is deferred until after content layout for accurate screen-edge clamping.
- Tray icon left-click still uses modal popup (closes on deactivate or Escape).

### Single Instance
- Uses a global mutex (`Global\BatteryWidgetSingleInstance`) to prevent multiple instances.

### Position Persistence
- Bar position saved to `BatteryWidget.config.json` on drag and exit, loaded on startup.

### Battery Estimation (EMA Smoothing)
- Raw WMI `EstimatedRunTime` is volatile — causes "time remaining jumps" when CPU load changes.
- Solution: Calculate time from EMA-smoothed discharge/charge rate instead.
- EMA formula: `R_EMA_t = α × R_raw_t + (1 - α) × R_EMA_(t-1)` with α=0.15 (lower = more stable).
- 2-second hysteresis after AC plug/unplug ignores rate spikes during transitions.
- Falls back to WMI/dotnet when rate data unavailable (first run, desktop PCs without battery).

## Known Gotchas

- **Every `src\*.ps1` module MUST be saved as UTF-8 *with BOM*** — the source contains literal em-dash (`—`) characters. (Display *strings* are now pure ASCII — the last literal became `[char]0x2014` in v1.1.9+ and check-source.ps1 fails on any new one — but 40+ em-dashes remain in comments.) Windows PowerShell 5.1 reads BOM-less `.ps1` files using the ANSI codepage (1252 on most machines), which mangles those bytes and produces a parser error (`Unexpected token '$('` around the popup title), so the assembled script fails to launch. If an editor/tool re-saves without the BOM, re-add it (e.g. `Set-Content -Encoding utf8BOM`, or `[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $true))`).
- **PS2EXE process and `Stop-Process`** — `Stop-Process -Force` DOES kill a widget exe launched from the same non-elevated session (verified 2026-07-15, and a hard kill releases the single-instance mutex). The historical "Access Denied" happens when the exe runs elevated or under a different token — in that case exit via the tray icon's "Exit" menu before rebuilding.
- **Build requires exit first** — The exe file is locked while running, so the widget must be closed before `Build.ps1` can overwrite it.
- **DPI label sizing** — Never use fixed `Size` on popup labels. Always use `AutoSize = $true` + `MaximumSize` to handle varying DPI/font scales.
- **`GetNewClosure()` and `$script:` don't mix** — a closure-wrapped event handler resolves `$script:` against the CLOSURE MODULE's scope, where it is `$null`. Closures suit handlers touching captured LOCALS only (the notification cards); any handler needing app state must be a plain scriptblock reading `$script:` state (the intro sequence, the first-run tip). Fails silently at fire time, not at registration.
- **Event-timer handlers must not close over function locals** — the notification animation timer referenced locals that are `$null` by the time it fires, so every card sat at `Opacity 0` forever (including the 10%/5% battery warnings). Carry per-card state explicitly; don't assume it's still in scope.
- **Comma binds tighter than minus in an argument list** — `RectangleF(..., $x - $y, ...)` parsed as an ARRAY, and array subtraction threw on every paint frame (the "both" display mode's second line never rendered). Parenthesise arithmetic inside constructor/method argument lists.
- **Editing this repo's text files from PowerShell 5.1** — `Get-Content`/`Set-Content` default to the ANSI codepage, so round-tripping a BOM-less UTF-8 file (this one, and `docs/index.html`) turns every em-dash into `â€"`. Use the Edit tool, or `[System.IO.File]::ReadAllText/WriteAllText` with an explicit `UTF8Encoding $false`.
- **Scripted edits must not mix line endings** — the repo is CRLF, and a `.Replace()` whose replacement string came from a PowerShell here-string inserts LF-only lines. `Invoke-Formatter` then refuses the file outright ("Cannot determine line endings…") and `format-source.ps1 -Check` fails the build. After any scripted multi-line edit, normalize: `$t = $t -replace "\`r\`n","\`n" -replace "\`n","\`r\`n"`.
- **Point sizes are already DPI-scaled; pixel geometry is not.** GDI+ converts a font's POINT size against the system DPI (the process is `SetProcessDPIAware`), so multiplying a point size by the DPI scale renders it twice-scaled — that bug clipped every label on the Battery Health card at 125%+. Box/offset PIXELS *do* need the `* $ds`. Rule: `New-Object Font(..., 11, ...)` raw; `Size(..., [int](40 * $DpiScale))` scaled.
- **The render harness rewrites the widget's single-instance mutex name** so a running BatteryPill can't block a render on the modal "Already running" dialog. If that name ever changes, `tools\render-states.ps1` must change with it — it now asserts the token is present and fails loudly rather than hanging until the timeout.

## Dev Tools (tools\)

Three PS 5.1-safe helpers in `tools\`; all resolve repo paths via `$PSScriptRoot` and exit nonzero on failure.

- **`tools\check-source.ps1`** — source health gate. Verifies every `src\*.ps1` module has its UTF-8 BOM, parse-checks each module plus the assembled whole plus `CheckBattery.ps1` / `Build.ps1` / `BatteryWidget.Run.ps1`, inventories non-ASCII characters inside string tokens (the BOM-dependent hazard), and runs PSScriptAnalyzer across the repo with `PSScriptAnalyzerSettings.psd1`. **Warnings are fatal** — the gate exits nonzero on any warning or finding, so the build log stays clean; write display characters like the em-dash as `[char]0x2014` instead of literals, and justify any new analyzer rule exclusion inline in the settings file. Needs `-ExecutionPolicy Bypass` (as verify.sh uses) or PSScriptAnalyzer's format data won't load. Run after any edit to a `.ps1` and before committing or building.
- **`tools\format-source.ps1`** — autoformatter (PSScriptAnalyzer's `Invoke-Formatter`; house style: K&R braces, 4-space indent, aligned hashtable assignments). Run it bare to fix layout in place; `-Check` is what check-source.ps1 runs, so an unformatted `.ps1` fails verify.sh. Preserves each file's UTF-8 BOM and line endings, and refuses to write a file whose token stream changed — a reformat can only move whitespace. `PSUseCorrectCasing` is deliberately off: it rewrites `Invoke-PS2EXE -InputFile` into the module's declared `Invoke-ps2exe -inputFile`.
- **`tools\check-types.ps1`** — type gate, run by `check-source.ps1` (so `verify.sh` enforces it) and standalone. AST-based, repo-wide, no allowlist: (1) every function/script parameter has an explicit type constraint, (2) every function declares `[OutputType(...)]` (`[void]` when it emits nothing), (3) `[object]` needs an `# any-typed:` justification comment on its own line or the one above, (4) a `[void]` function must not `return` a value from its own body. Add the attribute when you add a function — the gate is what keeps signatures honest.
- **`tools\render-states.ps1`** — headless state renderer. Stages a message-loop-stripped copy of the widget in a temp dir, feeds it fake battery presets, and captures PNGs of popup/pill/settings states plus a control-geometry dump (`geometry.txt` — the reliable layout oracle: type, X, Right, Width, wrapped-line count, text) to `-OutDir` (default `%TEMP%\batterypill-renders`). Subset with `-States popup-discharge,settings`; add `-DrawToBitmap` under RDP, or from an agent's non-interactive shell (the desktop app's Bash tool), where CopyFromScreen never completes and the harness hits its 180s timeout with only geometry.txt written. Never touches repo files; kills its child process on timeout.

## Build & Run

```powershell
# Build
.\Build.ps1

# Run
.\BatteryPill-<version>.exe
# or straight from source (assembles src\ to a temp staging file):
powershell -ExecutionPolicy Bypass -File .\BatteryWidget.Run.ps1
```

## Changelog

See `git log` — the release history lives in the commit messages, which carry the same detail plus the diffs.
