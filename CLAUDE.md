# CLAUDE.md — Project Context

## Overview

**BatteryPill** is a Windows desktop battery widget built in PowerShell with WinForms, compiled to `.exe` via PS2EXE. It shows a floating pill-shaped indicator on the desktop displaying time remaining, with a detailed popup on click and a system tray icon.

**Website**: batterypill.com (GitHub Pages from `docs/`)
**Donate**: buymeacoffee.com/nobackhand

## Architecture

- **BatteryWidget.ps1** — Main widget (~1150 lines). Creates a system tray `NotifyIcon` with context menu and a floating transparent pill bar. Uses WMI (`Win32_Battery`) for battery data with EMA-smoothed time estimates, a 3-second timer for updates, and a config file for persisting bar position.
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
- 420px wide, positioned near the pill, auto-sized height.
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

- **PS2EXE process can't be killed via `Stop-Process`** — returns "Access Denied". Must exit via the tray icon's "Exit" menu before rebuilding.
- **Build requires exit first** — The exe file is locked while running, so the widget must be closed before `Build.ps1` can overwrite it.
- **DPI label sizing** — Never use fixed `Size` on popup labels. Always use `AutoSize = $true` + `MaximumSize` to handle varying DPI/font scales.

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

### 2026-01-29 — Hover Popup & Faster Charging Detection
- **Hover-to-show popup** — hover over pill for 500ms to show detail popup (non-modal)
- Popup stays open while mouse is over pill or popup, dismisses when mouse leaves both
- Removed click-to-popup on pill (tray icon click still works)
- **Faster charging detection** — reduced poll interval: 10s → 3s
- **Faster state transitions** — reduced hysteresis: 5s → 2s (charging state appears within ~3-5s of plug/unplug)

### 2026-01-28 — Visual Polish & Settings/UX Improvements
- **Color-coded fill** based on battery level (green 50-100%, yellow 20-50%, orange 10-20%, red 0-10%)
- **Charging pulse animation** — pulsing glow effect when charging (alpha oscillates 80-180)
- **Hover tooltip** on pill showing quick stats (e.g., "85% • 3h 12m remaining")
- **Settings panel** accessible from tray menu and pill right-click:
  - Start with Windows (creates shortcut in shell:startup)
  - Show floating pill toggle
  - Reset pill position button
- **Right-click context menu** on the pill itself (Hide, Settings, Refresh, Exit)
- Added `Get-AccentColor` helper function for consistent color-coding across pill and tray icon

### 2026-01-28 — Improved Battery Estimation Logic
- Added EMA (Exponential Moving Average) smoothing for discharge/charge rate (α=0.15)
- Added 5-second hysteresis on AC plug/unplug to ignore rate spikes during transitions
- Calculate time remaining from smoothed rate instead of volatile WMI `EstimatedRunTime`
- "Hold" logic: uses last valid rate when current rate is unavailable
- Reduced polling interval: 30s → 10s for more responsive updates
- Falls back to WMI/dotnet estimates when rate data unavailable

### 2026-01-28 — Popup Improvements & Larger Pill
- Capacity line now shows current charge / full charge (e.g., `36,099 / 74,263 mWh`) instead of full/design
- Wear line now includes design capacity (e.g., `0.3% of 74,496 mWh`)
- Enlarged floating pill 20%: 90×28 → 108×34 px, font 8.5pt → 10.2pt

### 2026-01-27 — BatteryPill Branding & Splash Page
- Created splash page at docs/index.html (GitHub Pages)
- Custom domain batterypill.com configured with CNAME
- Buy Me a Coffee integration (buymeacoffee.com/nobackhand)
- Removed all GitHub references from public-facing site

### 2026-01-27 — DPI & Popup Fixes
- Added `SetProcessDPIAware()` P/Invoke for proper high-DPI rendering
- Added `AutoScaleMode = None` to popup form
- Changed all popup labels to `AutoSize = $true` with `MaximumSize` constraints
- Widened popup to 420px, adjusted label/value column layout
- Switched from TransparencyKey to Region-based clipping (fixes purple fringe)
- Pill size increased to 90x28, custom Paint with gradient fill and glass highlight

### 2026-01-26 — Initial Release
- Fixed floating bar drag (scoping bug: `$bar` → `$script:floatingBar`)
- Changed display from percentage to time remaining
- Dark theme with accent color strip
- Git repo created, pushed to GitHub
