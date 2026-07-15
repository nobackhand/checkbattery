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

- **`BatteryWidget.ps1` MUST be saved as UTF-8 *with BOM*** — the script contains literal em-dash (`—`) characters in display strings. Windows PowerShell 5.1 reads BOM-less `.ps1` files using the ANSI codepage (1252 on most machines), which mangles those bytes and produces a parser error (`Unexpected token '$('` around the popup title). `powershell -File BatteryWidget.ps1` then fails to launch. If an editor/tool re-saves without the BOM, re-add it (e.g. `Set-Content -Encoding utf8BOM`, or `[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $true))`).
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

### 2026-02-05 — Popup Design Audit & Visual Hierarchy
- **Hero percentage** — 18pt Semibold Bold percent below title, colored by battery status; old "Percent: XX%" row removed
- **Simplified title** — shows "Charging" / "Discharging" instead of "Charging - 90%"
- **Hidden N/A rows** — Capacity, Rate, Runtime, Wear rows skip rendering when value is "N/A"; popup shrinks automatically
- **Right-aligned values** — `Add-PopupRow` returns value label, uses fixed `Size` + `TextAlign = TopRight`
- **Font contrast** — standard rows 7.5pt, hero rows 10pt Semibold; secondary labels use `TextMuted`
- **Power source icons** — lightning bolt (U+26A1) for AC, bullet (U+2022) for battery
- **"Estimating..." pulse** — sine-wave alpha oscillation (120-200) on time label when rate unavailable
- **Sparkline improvements** — height 30→40px, current value dot (6px accent circle), guide text 7pt/120-alpha
- **Popup width** — 280→300px for breathing room; label column 70→80px to fit "Remaining:" at 10pt
- **Bug fixes** — exit error from null delegate removal; hero text clipping from insufficient row offset

### 2026-02-03 — Compact Popup & Positioning Fix
- **Compact popup layout** — reduced popup height ~40%: width 440→360, fonts 9.5→8.5pt, title 11→10pt, row height 28→22, sparkline 40→30px, progress bar 16→12px, label column 130→100, tighter gaps
- **Fixed popup clipping off-screen** — positioning was calculated using stale placeholder size (420×400) before content layout; moved positioning to after `ClientSize` is set so screen-edge clamping uses actual final dimensions
- Both `Show-HoverPopup` and `Show-BatteryPopup` updated with identical changes

### 2026-02-03 — Design Elevation (Visual, Motion, Personalization)
- **Better glass effect** — replaced flat 1px highlight with convex glass: 6px top gradient band, 4px bottom shadow band, 3px accent glow at charge boundary
- **Smooth color transitions** — accent color lerps 30% per tick instead of hard-snapping at thresholds (~15s convergence)
- **Plug/unplug flash** — 750ms white flash overlay when AC state changes for instant visual confirmation
- **Custom GDI+ progress bar** — replaced WinForms ProgressBar with dark-themed rounded rect bar, gradient fill, glass highlight (380x16)
- **Popup fade in/out** — 150ms fade-in, 100ms fade-out using 16ms opacity timers
- **Snap-to-edge dragging** — pill magnetically snaps to 8px from screen edge when dragged within 15px (multi-monitor aware)
- **Low battery warnings** — 15%: pulsing red border (4.7s cycle); 10%: opacity oscillation + notification card; 5%: critical notification card (slides in, auto-dismiss 10s)
- **Configurable display modes** — time-only (default), percent-only, or stacked (% + time); selectable in Settings
- **Pill size variants** — Compact (80x28), Normal (108x34), Expanded (140x42); selectable in Settings
- **Battery history sparkline** — 380x40 graph in popup showing last 2 hours of battery %, green bands for charging periods
- **Accent color picker** — 8 preset colors (Green, Blue, Purple, Cyan, Pink, Teal, Orange, White) in Settings; warning colors stay fixed
- **Theme system** — Dark (default), Light, Auto (follows Windows `AppsUseLightTheme` registry); pill/popup colors update via `$script:theme` refs
- **Auto-hide in fullscreen** — P/Invoke `GetForegroundWindow`/`GetWindowRect` fullscreen detection, 1-second check, toggle in Settings
- Config schema extended: `DisplayMode`, `PillSize`, `Theme`, `AccentColorIndex`, `AutoHideFullscreen`

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
