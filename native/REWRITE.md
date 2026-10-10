# BatteryPill native rewrite (WinUI 3)

Goal: the same app, but it *feels* like a big-company Windows 11 app. Motion runs
at the display's refresh rate, edges are smooth, the look is Fluent, the backdrops
are Mica. The PowerShell app keeps shipping from `src/` until this reaches parity.

## Why (measured 2026-10-10, CUBE04, 240 Hz display)
- The current app animates on WinForms timers asking for 16 ms. They actually deliver
  **~34 fps** (median 29.7 ms, worst 40 ms), even with the system timer at 1 ms.
- The pill is a `Region` clip, so its edges are aliased and it can't have a shadow.

## Stack decision: WinUI 3 (Windows App SDK 2.x), unpackaged, self-contained
Chosen over WPF (.NET 8 or 4.8) and a WPF/WinUI hybrid. The M0 spike retired the
main risk:

| Check | Result |
|---|---|
| Transparent, borderless, always-on-top pill, no taskbar/Alt+Tab | works (`TransparentTintBackdrop` + `AppWindow`; frame styles stripped) |
| Antialiased capsule edge + composition drop shadow | works (screenshot in PR) |
| Animations | compositor-driven (intro rise/fade, fill sweep, hover scale); UI loop not a bottleneck (400 frames/s on the UI thread) |
| Startup to pill visible | **0.53–0.66 s** (PowerShell app: 1–3 s) |
| Build output | **164 MB / 449 files**: unacceptable as-is (see M6) |

Second opinion (Qwen via `council.ps1`) preferred WPF. Its objections are below, with
the spike's answer to each:
- "the transparent pill is a hack": it works cleanly.
- "2–4 s cold start": measured at 0.55 s.
- size and tray icon: valid, and planned for below.

WinUI is the stack Windows 11's own apps use: Mica, Fluent controls and motion come
built in instead of being imitated.

## Layout
```
native/
  BatteryPill/            WinUI 3 app (windows, tray, UI)
  BatteryPill.Core/       battery data, estimator, config, update check: no UI   (M1)
  BatteryPill.Tests/      xUnit, ports of tests/*.Tests.ps1                       (M1)
```

## Milestones
Each milestone is a PR, CI-green and checked by a fresh reviewer, with measured proof.
- **M0 Spike** ✅ transparent pill, compositor animation, startup and size measured.
- **M1 Core + tests** ✅ `BatteryPill.Core`, a C# port of the PowerShell battery logic:
  - live WMI reader, off the UI thread, filling rates and capacities from root\WMI; OS power status
  - battery interpretation, including the status-2/255 and charge-cap rules
  - EMA estimator with capacity cross-check and charge-flip reset; power-draw ladder
  - history, draw stats and session summary
  - config read/write, compatible with the PowerShell app's file (verified against a PS 5.1-shaped file)
  - update-check decisions
  - **213 tests:** the PowerShell suites ported case for case, plus live reads of the host's real sources
  - **Mutation-checked:** re-introducing the status-2, 255, charge-flip and 1%-step bugs each fails the suite
  - CI: `.github/workflows/native.yml`
  - The platform power meter (perf counter) moves to M2.
- **M2 Pill** (+ platform power meter, presentation text and its tests):
  - real data; display modes and sizes; accent presets; dark/light/auto
  - native drag with edge snap and momentum glide
  - position memory across monitors and DPI changes; fullscreen auto-hide
  - charging pulse and intro; a click-through shadow margin
- **M3 Flyout:** hover flyout on Mica/Acrylic, plus:
  - hero %, time sentence and ETA; power meter
  - sparkline; Health card; session summary
- **M4 Tray:**
  - live battery tray icon and Fluent context menus
  - power plans, loaded lazily
  - notification cards: low, critical, charging, full, update available
  - first-run tips
- **M5 Settings:** settings window (NavigationView, Mica), About, update check, start
  with Windows, single instance, config migration.
- **M6 Ship:**
  - trim / NativeAOT and English-only resources: target ≤ 40 MB download
  - a single download; `release.ps1` + CI publish; website download button
  - code signing (needs Daniel's card)
- **M7 Cutover:** parity checklist signed off, then the native build becomes the
  download and `src/` moves to maintenance.

## Acceptance bar (every UI milestone)
- No motion on UI-thread timers: compositor animations only.
- Pill visible < 1 s after launch.
- Idle CPU ≈ 0.
- Correct at 100/125/150/200% DPI, and on a second monitor.
- Dark, light and auto themes.
- Windows 10 19041+ falls back gracefully: no Mica there, so Acrylic or a solid color.

## Open risks
1. **Size:** 164 MB raw. Retire in M6 with trimming/NativeAOT, measured.
2. **Tray icon:** H.NotifyIcon.WinUI (stable 2.4.1) vs. our own `Shell_NotifyIcon`
   plus a WinUI flyout. Spike in M4.
3. **Clicks in the transparent shadow margin** are caught by the pill window. Retire
   in M2: toggle `WS_EX_TRANSPARENT` outside the capsule, or a tighter margin.
4. **Smart App Control** blocks an unsigned exe exactly as it does today. Only a
   signed build fixes it (M6).
