# CLAUDE.md — Project Context

## Overview

**BatteryPill** is a Windows desktop battery widget built in PowerShell with WinForms, compiled to `.exe` via PS2EXE. It shows a floating pill-shaped indicator on the desktop displaying time remaining, with a detailed popup on click and a system tray icon.

**Website**: batterypill.com (GitHub Pages from `docs/`)
**Donate**: buymeacoffee.com/nobackhand

## Architecture

- **BatteryWidget.ps1** — Main widget (~2800 lines). Creates a system tray `NotifyIcon` with context menu and a floating transparent pill bar. Uses WMI (`Win32_Battery`) for battery data with EMA-smoothed time estimates, a 3-second timer for updates, and a config file for persisting bar position. Supports dark/light/auto themes, configurable pill size and display mode, accent color presets, battery history sparkline, and fullscreen auto-hide.
- **Build.ps1** — Compiles `BatteryWidget.ps1` to `BatteryWidget.exe` using `Invoke-PS2EXE`.
- **CheckBattery.ps1** — Standalone CLI script for quick battery status checks.
- **CheckBattery.bat** — Batch launcher for `CheckBattery.ps1`.
- **docs/index.html** — Splash/landing page served via GitHub Pages at batterypill.com. Single HTML file with embedded CSS/JS, dark theme, scroll animations.
- **docs/CNAME** — Custom domain config for GitHub Pages (batterypill.com).

## Key Technical Decisions

### Floating Pill Bar
- Uses Region-based clipping with `GraphicsPath` for rounded corners (no `TransparencyKey` = no purple fringe).
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

### Detail Popup
- Hover over the pill (500ms delay) to show: percent, capacity, charge/discharge rate, time remaining with ETA, elapsed time, full runtime estimate, battery wear.
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

- **`BatteryWidget.ps1` MUST be saved as UTF-8 *with BOM*** — the script contains literal em-dash (`—`) characters. (Display *strings* are now pure ASCII — the last literal became `[char]0x2014` in v1.1.9+ and check-source.ps1 fails on any new one — but 40+ em-dashes remain in comments.) Windows PowerShell 5.1 reads BOM-less `.ps1` files using the ANSI codepage (1252 on most machines), which mangles those bytes and produces a parser error (`Unexpected token '$('` around the popup title). `powershell -File BatteryWidget.ps1` then fails to launch. If an editor/tool re-saves without the BOM, re-add it (e.g. `Set-Content -Encoding utf8BOM`, or `[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $true))`).
- **PS2EXE process and `Stop-Process`** — `Stop-Process -Force` DOES kill a widget exe launched from the same non-elevated session (verified 2026-07-15, and a hard kill releases the single-instance mutex). The historical "Access Denied" happens when the exe runs elevated or under a different token — in that case exit via the tray icon's "Exit" menu before rebuilding.
- **Build requires exit first** — The exe file is locked while running, so the widget must be closed before `Build.ps1` can overwrite it.
- **DPI label sizing** — Never use fixed `Size` on popup labels. Always use `AutoSize = $true` + `MaximumSize` to handle varying DPI/font scales.
- **`GetNewClosure()` and `$script:` don't mix** — a closure-wrapped event handler resolves `$script:` against the CLOSURE MODULE's scope, where it is `$null`. Closures suit handlers touching captured LOCALS only (the notification cards); any handler needing app state must be a plain scriptblock reading `$script:` state (the intro sequence, the first-run tip). Fails silently at fire time, not at registration.
- **Event-timer handlers must not close over function locals** — the notification animation timer referenced locals that are `$null` by the time it fires, so every card sat at `Opacity 0` forever (including the 10%/5% battery warnings). Carry per-card state explicitly; don't assume it's still in scope.
- **Comma binds tighter than minus in an argument list** — `RectangleF(..., $x - $y, ...)` parsed as an ARRAY, and array subtraction threw on every paint frame (the "both" display mode's second line never rendered). Parenthesise arithmetic inside constructor/method argument lists.
- **Editing this repo's text files from PowerShell 5.1** — `Get-Content`/`Set-Content` default to the ANSI codepage, so round-tripping a BOM-less UTF-8 file (this one, and `docs/index.html`) turns every em-dash into `â€"`. Use the Edit tool, or `[System.IO.File]::ReadAllText/WriteAllText` with an explicit `UTF8Encoding $false`.

## Dev Tools (tools\)

Three PS 5.1-safe helpers in `tools\`; all resolve repo paths via `$PSScriptRoot` and exit nonzero on failure.

- **`tools\check-source.ps1`** — source health gate. Verifies `BatteryWidget.ps1` has its UTF-8 BOM, parse-checks `BatteryWidget.ps1` / `CheckBattery.ps1` / `Build.ps1`, inventories non-ASCII characters inside string tokens (the BOM-dependent hazard), and runs PSScriptAnalyzer across the repo with `PSScriptAnalyzerSettings.psd1`. **Warnings are fatal** — the gate exits nonzero on any warning or finding, so the build log stays clean; write display characters like the em-dash as `[char]0x2014` instead of literals, and justify any new analyzer rule exclusion inline in the settings file. Needs `-ExecutionPolicy Bypass` (as verify.sh uses) or PSScriptAnalyzer's format data won't load. Run after any edit to a `.ps1` and before committing or building.
- **`tools\format-source.ps1`** — autoformatter (PSScriptAnalyzer's `Invoke-Formatter`; house style: K&R braces, 4-space indent, aligned hashtable assignments). Run it bare to fix layout in place; `-Check` is what check-source.ps1 runs, so an unformatted `.ps1` fails verify.sh. Preserves each file's UTF-8 BOM and line endings, and refuses to write a file whose token stream changed — a reformat can only move whitespace. `PSUseCorrectCasing` is deliberately off: it rewrites `Invoke-PS2EXE -InputFile` into the module's declared `Invoke-ps2exe -inputFile`.
- **`tools\check-types.ps1`** — type gate, run by `check-source.ps1` (so `verify.sh` enforces it) and standalone. AST-based, repo-wide, no allowlist: (1) every function/script parameter has an explicit type constraint, (2) every function declares `[OutputType(...)]` (`[void]` when it emits nothing), (3) `[object]` needs an `# any-typed:` justification comment on its own line or the one above, (4) a `[void]` function must not `return` a value from its own body. Add the attribute when you add a function — the gate is what keeps signatures honest.
- **`tools\render-states.ps1`** — headless state renderer. Stages a message-loop-stripped copy of the widget in a temp dir, feeds it fake battery presets, and captures PNGs of popup/pill/settings states plus a control-geometry dump (`geometry.txt` — the reliable layout oracle: type, X, Right, Width, wrapped-line count, text) to `-OutDir` (default `%TEMP%\batterypill-renders`). Subset with `-States popup-discharge,settings`; add `-DrawToBitmap` under RDP where CopyFromScreen fails. Never touches repo files; kills its child process on timeout.

## Build & Run

```powershell
# Build
.\Build.ps1

# Run
.\BatteryWidget.exe
# or directly:
powershell -ExecutionPolicy Bypass -File .\BatteryWidget.ps1
```

## Changelog

See `git log` — the release history lives in the commit messages, which carry the same detail plus the diffs.
