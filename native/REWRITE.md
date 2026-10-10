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
  - live battery reader, off the UI thread, straight from the battery class driver (the source
    Win32_Battery and root\WMI sit on; System.Management broke in the trimmed single-file exe,
    and a driver read takes ~1 ms where WMI took 20-900); OS power status
  - battery interpretation, including the status-2/255 and charge-cap rules
  - EMA estimator with capacity cross-check and charge-flip reset; power-draw ladder
  - history, draw stats and session summary
  - config read/write, compatible with the PowerShell app's file (verified against a PS 5.1-shaped file)
  - update-check decisions
  - **213 tests:** the PowerShell suites ported, plus live reads of the host's real sources
  - Not ported: the cross-process `Concurrency` stress suite. It is covered by the same atomic MoveFileEx design, plus a read-only-file test.
  - **Mutation-checked:** re-introducing the status-2, 255, charge-flip and 1%-step bugs each fails the suite
  - CI: `.github/workflows/native.yml`
  - The platform power meter (perf counter) moves to M2.
- **M2 Pill** ✅
  - live data; every display mode, size, theme and accent; gradient fill animated on the compositor
  - charging and critical pulses; drag, fling-glide and settle stepped per display frame
  - click-through shadow margin; fullscreen hide that ignores the desktop
  - DPI/display-change/resume handling; never takes focus; click cycles the mode; right-click menu
  - Core: presentation text, colors, geometry, glide physics (ported tests)
  - *Still to do:* the platform power meter (perf counter).
- **M3 Flyout** ✅ hover card on Fluent acrylic, slides in, never takes focus:
  - state, elapsed, hero %, time sentence; power line with a live meter (avg/peak); fun line
  - sparkline with charging stretches; the no-battery card
- **M4 Tray** ✅
  - live glyph at the real small-icon size (dark/light)
  - Windows 11 menu: show/hide, mode, power plans read on open, refresh, settings, update, exit
  - left-click pins the card; alerts are real Windows notifications (DND/game mode respected)
  - *Still to do:* first-run tips.
- **M5 Settings** ✅
  - Windows 11 Settings-style window on Mica, every setting
  - start with Windows via the same Startup shortcut; daily update check; version and update in About
  - first-run import of the PowerShell app's config; app icon
- **M6 Ship** (in progress) ✅ one 33 MB exe: trimmed, compressed, self-extracting; CI smoke-tests that exe.
  - *Still to do:* `release.ps1` and website wiring.
  - Code signing is deferred: Daniel's 2026-10-10 decision.
- **M7 Cutover:** parity checklist signed off, then the native build becomes the
  download and `src/` moves to maintenance.

**Verification:** `native/tools/ui-smoke.ps1` drives the published exe on the GitHub
runner with real mouse input. It covers frames, focus, click-through, click,
drag/fling/save, hover show/hide, both menus, tray, settings in both themes, the battery
reader in the trimmed build, cold and warm launch time, and every battery state rendered from `BATTERYPILL_FAKE`.

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
   signed build fixes it (M6). Since 2026-10-10 it also blocks fresh dev builds on
   CUBE04 (Code Integrity 3077).
   **Decision 2026-10-10 (Daniel): stay unsigned for now.** On-screen verification
   runs on the GitHub Windows runner, which has no SAC (`native/tools/ui-smoke.ps1`
   in `native.yml`; screenshots are uploaded as artifacts). Until the build is signed,
   neither CUBE04 nor any SAC-enabled PC can run the native app.
5. **The battery reader has not met a real battery yet.** Its mapping into the
   Win32_Battery shape is unit-tested (draining, charging, charge-cap hold, unknown
   sentinels, relative units), and it reads "no battery" correctly on CUBE04 and the
   CI runner, but no Windows laptop was online on 2026-10-10. First laptop check:
   `dotnet test` in `native/` on battery, then the measured run's `battery=ok-battery`.
