# BatteryPill

A floating "pill" battery widget for Windows that shows **time remaining** —
hours and minutes left, not just a percentage. Hover it for charge rate,
capacity, wear, ETA, and a 2-hour history sparkline. Single `.exe`, no
installer, no dependencies.

**Website:** [batterypill.com](https://batterypill.com) · **Download:** [Releases](https://github.com/nobackhand/checkbattery/releases)

## Features

- **Time, not percent** — see when you actually need to plug in.
- **Always on top** — floats above everything, auto-hides in fullscreen apps.
- **Hover popup** — rate, capacity, wear level, ETA, and a 2-hour sparkline.
- **DPI aware** — crisp at any display scaling.
- **Customizable** — dark / light / auto theme, 8 accent colors, 3 pill sizes.
- **Portable** — a single `.exe`; position and settings saved locally.

The displayed time is derived from an EMA-smoothed discharge/charge rate
rather than the volatile WMI `EstimatedRunTime`, so the estimate stays
steady instead of jumping when CPU load changes.

## Requirements

- Windows 10 or later
- PowerShell 5.0+ (preinstalled on Windows)
- [PS2EXE](https://github.com/MScholtes/PS2EXE) — only needed to build the `.exe`

## Run

```powershell
# Run the prebuilt executable
.\BatteryPill-<version>.exe

# Or run the source directly
powershell -ExecutionPolicy Bypass -File .\BatteryWidget.ps1
```

## Build

```powershell
.\parse_check.ps1   # quick syntax check (optional)
.\Build.ps1         # compiles BatteryWidget.ps1 -> BatteryPill-<version>.exe
```

`Build.ps1` reads the version from `$script:appVersion` in `BatteryWidget.ps1`
and names the output accordingly. The running widget locks the `.exe`, so exit
it (tray → **Exit**) before rebuilding.

## Project layout

| Path | Purpose |
| --- | --- |
| `BatteryWidget.ps1` | The widget — tray icon, floating pill, hover popup, settings. |
| `Build.ps1` | Compiles the widget to a standalone `.exe` via PS2EXE. |
| `parse_check.ps1` | Pre-build syntax check for `BatteryWidget.ps1`. |
| `CheckBattery.ps1` / `.bat` | Standalone CLI battery status report. |
| `docs/` | The marketing site (`index.html`), deployed to batterypill.com via Vercel. |

## CLI

For a quick one-shot status report without the widget:

```powershell
.\CheckBattery.ps1
```

## License

Free and open source. *(A `LICENSE` file should be added to declare the exact terms.)*
