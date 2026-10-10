# STATUS — checkbattery (BatteryPill) — 2026-10-10

## Now
main = v1.4.0 (watts + funner pill) plus everything from the Oct 8-9
overnight/morning loop: PRs #3-#6 and #8-#12 merged. RELEASED as v1.4.0 on
2026-10-10 (tag v1.4.0 at 285ca1a, unsigned); the website download button
serves it.

## Just shipped (merged to main, Oct 9-10)
- #3 11 bug fixes (startup freeze, card placement, sparkline cost, slider
  drag, live Auto theme, tray icon, light swatch ring, Health card, site).
- #4 once-a-day GitHub release check (card, menu item, About, off switch).
- #6 real battery rates from root\WMI (Win32_Battery has no
  DischargeRate/ChargeRate - the watts line never had laptop data); the
  battery query runs off the UI thread (C# BatteryQuery).
- #10 WMI BatteryStatus 2 ("on AC") and .NET 255 ("Unknown") no longer
  count as charging - a laptop at a charge cap reads Plugged In (widget
  and CheckBattery.ps1).
- #11 estimator drops the held rate when charging stops/starts while
  plugged in.
- #9 power plans load when the Power Plan submenu opens, not per click.
- #5 warning cards stack above the pill. #8 light-theme Health ring.
- #7 (cache compiled helpers) CLOSED: Smart App Control blocks it.

## Next (max 3, priority order)
1. Laptop check (no Windows laptop online on Oct 10): on battery,
   root\WMI BatteryStatus DischargeRate > 0 and the pill's popup shows
   "Drawing NN W"; at a charge cap it reads "Plugged In".
2. Code signing: Smart App Control blocks the unsigned exe outright;
   needs Daniel's card for a cert (he rejected Azure Trusted Signing).
3. Follow-up: persist EmaWasCharging so a relaunch at a cap doesn't
   reuse a saved charge rate (see #11's description).

## Blockers / Open questions
- Smart App Control blocks unsigned builds and unsigned DLLs outright
  (DISTRIBUTION.md); signing decision still open.

## Failed approaches (do not retry)
- Caching the compiled C# helpers as a DLL on disk (#7): SAC blocks
  loading it. Loading it from bytes instead would sidestep the policy -
  don't.

## Resume
Read STATUS + CLAUDE.md; start at Next 1 if a Windows laptop is online.
release.ps1 needs Git's bash on PATH, and its verify.sh time limits trip
while CUBE04 is busy (e.g. gaming) - CI on the same commit is the gate.
