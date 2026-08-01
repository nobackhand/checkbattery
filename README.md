# BatteryPill

BatteryPill is a Windows desktop battery widget built with PowerShell and WinForms. It displays a floating, draggable pill-shaped indicator on the desktop showing time remaining, a detailed information popup on hover (the tray icon opens a modal version on click), and a system tray icon. It is designed for Windows users who want a persistent, glanceable view of their battery status using smoothed estimates rather than just a percentage.

## Features

- **Floating Pill Bar**: Draggable indicator with snap-to-edge functionality and fullscreen auto-hide.
- **Display Modes**: Click the pill to cycle what it shows - time remaining, percentage, or both stacked.
- **Detailed Popup**: Hover over the pill (500ms delay) to see a large status-colored percentage, capacity, charge/discharge rate, ETA, elapsed time, battery wear, and a history sparkline.
- **Smart Estimates**: Uses Exponential Moving Average (EMA) smoothing to provide stable time remaining estimates that resist "jumping" caused by CPU load changes.
- **Themes & Personalization**: Supports Dark, Light, and Auto themes; 8 accent color presets; and three pill size variants (Compact, Normal, Expanded).
- **Visual Alerts**: Includes pulsing red borders and notifications for low battery states (15%, 10%, and 5%).
- **System Tray Integration**: Includes a tray icon with a context menu for settings and exiting.
- **Single Instance**: Uses a global mutex to prevent multiple instances from running.

## Setup

One command takes a fresh clone to a running widget:

```bash
./scripts/setup.sh
```

It checks prerequisites, installs the `ps2exe` dependency (bootstrapping TLS 1.2 and the NuGet provider that stock PowerShell 5.1 lacks), builds `BatteryPill-<version>.exe`, and launches it. It is idempotent — re-run it any time. Use `./scripts/setup.sh --no-run` to build without launching, and `--help` for usage.

The only prerequisites are Windows, Windows PowerShell 5.1 (`powershell.exe` on PATH), and a bash shell (Git Bash works). Everything else is installed for you.

## Usage

Quit from the tray icon's **Exit** item. To start it again afterwards, run the compiled executable (the version suffix comes from `$script:appVersion` in the source; end users grab the stable-named `BatteryPill.exe` from the [latest release](https://github.com/nobackhand/checkbattery/releases/latest/download/BatteryPill.exe) instead):
```powershell
.\BatteryPill-<version>.exe
```

To run the widget from source without building:
```powershell
powershell -ExecutionPolicy Bypass -File .\BatteryWidget.ps1
```

To rebuild the executable on its own:
```powershell
.\Build.ps1
```

Quick battery status check via CLI:
```batch
CheckBattery.bat
```
or
```powershell
.\CheckBattery.ps1
```

## Verify

`scripts/verify.sh` is the single gate for this repo: it runs lint, the full test suite, and a real build, and exits nonzero if any stage fails. Run it before committing.

```bash
./scripts/verify.sh
```

It runs (cheapest signal first, each with a wall-clock timeout so the whole run stays well under 10 minutes):

1. **Lint** — `tools/check-source.ps1`: verifies `BatteryWidget.ps1` still carries its UTF-8 BOM, parse-checks every shipped `.ps1`, runs PSScriptAnalyzer (settings in `PSScriptAnalyzerSettings.psd1`), checks that every `.ps1` is autoformatted, and runs the type gate (`tools/check-types.ps1`, below). The gate fails on **any** warning, so the build log stays warning-free — write new non-ASCII display characters as `[char]0xNNNN` rather than literals.
2. **Tests** — `scripts/run-tests.ps1`: runs every `tests/*.Tests.ps1`, each in its own `powershell.exe`.
3. **Build** — `Build.ps1`: compiles `BatteryWidget.ps1` to `BatteryPill-<version>.exe` with ps2exe.

Requires Windows PowerShell 5.1 (`powershell.exe` on PATH) and a bash shell (Git Bash works). Typical runtime on a dev machine is a few seconds.

To run just the tests, or one file:

```powershell
.\scripts\run-tests.ps1
.\scripts\run-tests.ps1 -Filter Formatting
```

Tests dot-source individual functions out of `BatteryWidget.ps1` via the PowerShell AST (`Import-WidgetFunction` in `tests/_harness.ps1`) — the script itself ends in a WinForms message loop, so it can never be dot-sourced whole.

### Formatting

House style is enforced by an autoformatter, so layout is never a review topic. If the lint stage reports unformatted files, fix them mechanically:

```powershell
.\tools\format-source.ps1           # rewrite every .ps1 in place
.\tools\format-source.ps1 -Check    # what verify.sh runs; exits 1 if anything is unformatted
```

It wraps PSScriptAnalyzer's `Invoke-Formatter` (K&R braces, 4-space indent, aligned hashtable assignments), preserves each file's UTF-8 BOM and line endings, and refuses to write a file whose token stream changed — a reformat can only move whitespace.

### Typing

PowerShell has no compiler, so signatures are held to a written standard instead:

```powershell
.\tools\check-types.ps1    # also run by the lint stage; exits 1 on any violation
```

It reads every `.ps1` with the AST and enforces four rules repo-wide, with no per-file allowlist:

1. **Typed parameters** — every parameter of every function, and of every script-level `param()` block, carries an explicit type constraint.
2. **Declared return type** — every function declares `[OutputType(...)]`; functions that emit nothing declare `[OutputType([void])]`.
3. **No blanket `[object]`** — rule 1 cannot be satisfied by typing everything `[object]`. A genuinely polymorphic parameter needs an `# any-typed: ...` comment on its own line or the line above, saying what it holds.
4. **Honest `[void]`** — a function declaring `[OutputType([void])]` must not `return` a value from its own body (returns inside nested functions and event-handler scriptblocks belong to those and are ignored). This is what keeps declared return types from drifting as the code changes.

## Release

Releases are one command. Bump `$script:appVersion` in `BatteryWidget.ps1`, commit, then:

```powershell
.\release.ps1
```

It refuses to run on a dirty tree or an already-released version, runs the full `scripts/verify.sh` gate, builds via `Build.ps1`, tags `v<version>`, pushes the tag, and creates the GitHub release with two assets: the versioned `BatteryPill-<version>.exe` and a stable-named `BatteryPill.exe`. The website's download button points at `.../releases/latest/download/BatteryPill.exe`, so it always serves the newest release without any site edit. Requires `git`, `gh` (authenticated), and bash on PATH.

## Configuration

- **Position Persistence**: The widget saves its bar position to `BatteryWidget.config.json` on drag and exit.
- **Theme Settings**: Configurable via the internal settings menu (Dark, Light, Auto).

## How it works

- **Data Retrieval**: Queries battery information using WMI (`Win32_Battery`) and .NET APIs (`System.Windows.Forms.SystemInformation`).
- **Smoothing**: Implements an EMA formula (`R_EMA_t = α × R_raw_t + (1 - α) × R_EMA_(t-1)`) with α=0.15 to stabilize discharge/charge rates.
- **UI Rendering**: Uses WinForms for the windowing system and GDI+ for custom drawing of gradients, glass highlights, and rounded corners.
- **DPI Awareness**: Uses P/Invoke to call `SetProcessDPIAware()` to ensure consistent scaling across different monitor setups.

## Project structure

- `BatteryWidget.ps1`: Main widget logic and UI code.
- `Build.ps1`: Script to compile the widget into a standalone `.exe` using `ps2exe`.
- `release.ps1`: One-command GitHub release (verify, build, tag, upload assets).
- `CheckBattery.ps1` / `.bat`: Standalone CLI scripts for battery status.
- `scripts/`: `setup.sh` (one-command setup), `verify.sh` (the lint + tests + build gate), and `run-tests.ps1` (test runner).
- `tests/`: Test suite - `_harness.ps1` (assertions + AST function loader) plus `*.Tests.ps1` files.
- `tools/`: Dev harness - `check-source.ps1` (BOM + parse + PSScriptAnalyzer + formatting + typing gate), `format-source.ps1` (autoformatter), `check-types.ps1` (type gate), and `render-states.ps1` (headless renderer of popup/pill/settings states).
- `docs/`: Website files for the project landing page.
