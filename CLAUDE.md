# CLAUDE.md — Project Context

## Overview

**BatteryWidget** is a Windows system tray battery monitor built in PowerShell with WinForms, compiled to `.exe` via PS2EXE. It shows a tray icon with battery percentage and a draggable floating "pill" bar on the desktop displaying time remaining.

## Architecture

- **BatteryWidget.ps1** — Main widget (~813 lines). Creates a system tray `NotifyIcon` with context menu and a floating transparent pill bar. Uses WMI (`Win32_Battery`) for battery data, a 30-second timer for updates, and a config file for persisting bar position.
- **Build.ps1** — Compiles `BatteryWidget.ps1` to `BatteryWidget.exe` using `Invoke-PS2EXE`.
- **CheckBattery.ps1** — Standalone CLI script for quick battery status checks.
- **CheckBattery.bat** — Batch launcher for `CheckBattery.ps1`.

## Key Technical Decisions

### Floating Pill Bar
- Uses `TransparencyKey = Magenta` with a custom `Paint` handler to draw a rounded rectangle. Areas not painted become transparent.
- `AutoScaleMode = None` set **before** `Size`, plus `MinimumSize`/`MaximumSize` constraints (80x24) to prevent WinForms DPI auto-scaling.
- Event handlers use `$script:floatingBar` (not local variables) to avoid PowerShell scriptblock scoping issues.

### Display
- Pill shows time remaining (e.g., "3h 8m") instead of percentage.
- Accent color strip on the left edge changes by battery level: green (>50%), yellow (21-50%), orange (11-20%), red (≤10%).
- Font: Segoe UI 7pt Bold.

### Single Instance
- Uses a global mutex (`Global\BatteryWidgetSingleInstance`) to prevent multiple instances.

### Position Persistence
- Bar position saved to `BatteryWidget.config.json` on drag and exit, loaded on startup.

## Known Gotchas

- **PS2EXE process can't be killed via `Stop-Process`** — returns "Access Denied". Must exit via the tray icon's "Exit" menu before rebuilding.
- **DPI scaling** — `AutoScaleMode = None` + size constraints handle this without needing `SetProcessDPIAware()`.
- **Build requires exit first** — The exe file is locked while running, so the widget must be closed before `Build.ps1` can overwrite it.

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

### 2026-01-26 — Initial Release
- Fixed floating bar drag (scoping bug: `$bar` → `$script:floatingBar`)
- Replaced Region-based rounded corners with TransparencyKey + Paint handler
- Changed display from percentage to time remaining
- Compact pill size (80x24) with DPI-safe sizing
- Dark theme: background (35,35,40), border (70,70,75), accent strip
- Git repo created, pushed to https://github.com/nobackhand/checkbattery
