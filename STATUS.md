# STATUS — checkbattery (BatteryPill) — 2026-09-04T15:50:00-05:00

## Now
v1.4.0 (live system power draw in watts + the funner pill) is on
origin/main with two follow-up fixes, but NO v1.4.0 tag or GitHub
release exists yet: the website download button still serves v1.3.3.

## Just shipped (this session — verified against git)
- v1.4.0: live system power draw (watts) + a funner pill — cbabc37
  (was local-only until today; now on origin/main via PR #2)
- Popup power-meter bar drains when the reading stops being a discharge
  (was frozen at the last draw after plugging in) — 8761167
- A full pack parked on the cable no longer carries the previous run's
  avg/peak into the next unplug: samples persist IsPluggedIn and a run
  is a contiguous same-power-source stretch; 3 new cases in
  tests/PowerDraw.Tests.ps1 — 5f7903a
- PR #2 merged to main — c1fc77e

## Next (max 3, priority order)
1. Cut the release: `powershell -File release.ps1` (refuses a dirty
   tree or an already-released version; runs scripts/verify.sh, builds,
   tags v1.4.0, uploads the versioned exe + stable BatteryPill.exe).
   Confirm `gh release view v1.4.0` lists both assets.
2. Hover-test the meter on a machine WITH a battery (Roger) while
   plugging in and unplugging: bar drains on plug-in, avg/peak reset on
   the next unplug. Not yet verified visually (dev box has no battery).
3. `Get-BatterySessionSummary` (src/, grep it) has the same missing
   plugged-in boundary as the bug fixed in 5f7903a: same fix + tests.

## Blockers / Open questions
- Smart App Control blocks unsigned builds outright (DISTRIBUTION.md);
  signing decision still open.

## Failed approaches (do not retry)

## Resume
Read STATUS + CLAUDE.md; main at c1fc77e is v1.4.0 unreleased; start at
Next 1 (cut the v1.4.0 release), then Next 2 on Roger.
