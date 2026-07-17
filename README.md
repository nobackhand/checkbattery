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

## Requirements

- Windows OS.
- PowerShell 5.0 or higher.
- `ps2exe` module (required for building the executable).

## Installation

To build the standalone executable:
```powershell
.\Build.ps1
```

To run the widget directly via PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File .\BatteryWidget.ps1
```

## Usage

Run the compiled executable (the version suffix comes from `$script:appVersion` in the source):
```powershell
.\BatteryPill-<version>.exe
```

Quick battery status check via CLI:
```batch
CheckBattery.bat
```
or
```powershell
.\CheckBattery.ps1
```

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
- `CheckBattery.ps1` / `.bat`: Standalone CLI scripts for battery status.
- `capture_popup.ps1`: Utility script to capture a screenshot of the popup for documentation.
- `tools/`: Dev harness - `check-source.ps1` (BOM + parse gate) and `render-states.ps1` (headless renderer of popup/pill/settings states).
- `docs/`: Website files for the project landing page.
