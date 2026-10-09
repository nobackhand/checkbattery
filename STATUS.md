# STATUS — checkbattery (BatteryPill) — 2026-10-09T11:50:00-05:00

## Now
main at e286ace = v1.4.0 (watts + funner pill) + 11 overnight bug fixes
(PR #3) + the daily update check (PR #4). Still NO v1.4.0 tag or
release: the website download button serves v1.3.3. Seven PRs open.

## Just shipped (verified against git)
- PR #3 merged (337949d): startup freeze (perf-counter probe moved off
  the UI thread), sparkline redraw cost, opacity slider drag, card and
  first-run-tip placement, live Auto theme, tray icon sharpness, light
  swatch ring, Health card plugged-in boundary, site CSS, CI test fix.
- PR #4 merged (e286ace): once-a-day GitHub release check; card + menu
  item + About status; off switch in Settings.

## Open PRs (all CI green on verify; fresh-agent reviewed)
- #6 real battery rates from root\WMI (Win32_Battery has no
  DischargeRate/ChargeRate - the watts line never had laptop data) and
  the battery query off the UI thread. KEEP x2. Needs a laptop check.
- #5 warning cards stack above the pill. KEEP.
- #8 light-theme Health ring track. KEEP.
- #9 right-click menus no longer wait on powercfg. KEEP.
- #10 WMI BatteryStatus 2 ("on AC") no longer counts as charging, so a
  laptop at a charge cap reads Plugged In; .NET "Unknown" (255) is not
  charging either. KEEP x2. Needs a laptop check.
- #11 estimator drops the held rate when charging stops/starts while
  plugged in (was "1h 55m left" at a cap for up to 60s).
- #7 DRAFT helper-DLL cache: Smart App Control (On on CUBE04) blocks
  the freshly compiled DLL - recommend closing.

## Next (max 3, priority order)
1. Merge #6 and #10 (after a laptop check), #5, #8, #9, #11.
2. Cut the release: delete OVERNIGHT_SUMMARY.md, then
   `powershell -File release.ps1`; confirm `gh release view v1.4.0`.
3. On a Windows laptop: unplug, hover the pill - "Drawing NN W" and a
   Health card with capacity/wear (no Windows laptop online now; Roger
   is Ubuntu).

## Blockers / Open questions
- Smart App Control blocks unsigned builds and unsigned DLLs outright
  (DISTRIBUTION.md, PR #7); signing decision still open.

## Failed approaches (do not retry)
- Caching the compiled C# helpers as a DLL on disk (PR #7): SAC blocks
  loading it. Loading it from bytes instead would sidestep the policy -
  don't.

## Resume
Read STATUS + CLAUDE.md + OVERNIGHT_SUMMARY.md (untracked, root); act on
Daniel's merge decisions for #5-#11, then Next 2.
#10 also fixes CheckBattery.ps1 (the CLI) the same way.
