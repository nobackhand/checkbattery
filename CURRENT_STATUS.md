# Session Handoff — 2026-06-03

**Branch:** `claude/great-volta-eTYcC`
**Environment used:** real Windows, **Windows PowerShell 5.1 only** (no PowerShell 7), display at **200% scaling**, PS2EXE 1.0.17.

This handoff has two parts:
1. **Runtime verification + fixes** that were applied and tested this session (✅ done).
2. **Adversarial bug hunt** — a confirmed, severity-ranked bug list that is **NOT yet fixed** (👉 resume here).

---

## Part 1 — Runtime verification & fixes (DONE, committed)

The cloud "great-volta" pass (estimation extraction, popup redesign, atomic config) couldn't be runtime-verified. Verified all of it on Windows; found and fixed 4 real bugs that only surface on Windows / PS 5.1 / PS2EXE.

| Area | Result |
|---|---|
| Build → single self-contained exe (inlining) | ✅ PASS after fixes |
| Run from source (`-File BatteryWidget.ps1`) | ✅ PASS after fix |
| Popup redesign (status-only title, 18pt hero %, no "Percent:" row) | ✅ PASS (verified at 200%) |
| Atomic config (persist across restart, no stray `.tmp`/`.bak`) | ✅ PASS |
| Unit tests | ✅ 11/11 dependency-free **and** 11/11 Pester v5 |

**Fixes applied (5 files):**
- **`Build.ps1`** — inlining read/wrote BOM-less UTF-8 via `Get-Content -Raw`/`Set-Content`, which PS 5.1 decodes as ANSI → mojibaked the em-dash and produced a broken compiled script. Now reads via `[IO.File]::ReadAllText(..., UTF8)` and writes the temp **with a BOM**.
- **`BatteryWidget.ps1`** — (a) the new dot-source guard ran `Join-Path $PSScriptRoot ...` unconditionally, but `$PSScriptRoot` is `""` in the PS2EXE exe → "Cannot bind argument to parameter 'Path'". Now wrapped in `if ($PSScriptRoot)`. (b) Saved **as UTF-8 with BOM** (PS 5.1's parser also reads BOM-less files as ANSI → same mojibake when run from source).
- **`BatteryEstimation.ps1`** — saved **as UTF-8 with BOM**.
- **`tests/run-estimation-tests.ps1`**, **`tests/Estimation.Tests.ps1`** — 3-arg `Join-Path` is PS7-only (broke on 5.1 despite `#requires -Version 5.1`); the Pester twin also had a root-level `BeforeEach` (illegal in Pester v5). Fixed both.

**Notes for next time:**
- Exit the running widget via its tray **Exit** menu (or `taskkill /F /PID`) before rebuilding — the exe is locked while running.
- Source files MUST keep their UTF-8 BOM or PS 5.1 will mojibake the non-ASCII glyphs again.
- `Build.ps1:53` has a now-stale comment saying sources are "UTF-8 WITHOUT a BOM" — they now carry a BOM. Build is still lossless (ReadAllText strips the BOM); just a 1-line doc fix worth making.
- **Repo location moved** during the session to `C:\projects\claude\checkbattery` (was under `Desktop\myprojects\claude`). Remote unchanged: `github.com/nobackhand/checkbattery`.

---

## Part 2 — Adversarial bug hunt (👉 RESUME HERE — none of these are fixed)

Read-only multi-agent hunt (6 finders → dedup → 3 independent adversarial refuters per candidate → majority vote). **20 confirmed** (each survived ≥2/3 "real" votes), **10 refuted**. Line numbers refer to the current (committed) source.

### 🔴 Crash (5)
| Location | Bug | Votes | Fix direction |
|---|---|---|---|
| `BatteryWidget.ps1:352` | `EstimatedRunTime == 0xFFFFFFFF` (4294967295) overflows `[int]`; escapes **uncaught** on tray-click & hover paths (no global handler) | 3/3 | Add `-lt 4294967295` guard (match `DischargeRate`/`ChargeRate` at 309/315) |
| `CheckBattery.ps1:108` | Same sentinel overflow, top-level/no try-catch → CLI aborts before printing | 3/3 | Same guard + N/A fallback |
| `BatteryWidget.ps1:677 → 3094` | `RefreshInterval` loaded with only a null-check; a hand-edited `0` makes `Timer.Interval` throw at startup | 3/3 | Clamp to sane min at load (mirror Opacity/Accent clamps) |
| `BatteryWidget.ps1:2934` | `DisplaySettingsChanged` writes `$floatingBar.Location` from the **SystemEvents background thread** → illegal cross-thread throw on monitor disconnect | 2/3 | Marshal via `BeginInvoke` (guard `InvokeRequired`) |
| `BatteryWidget.ps1:2919` | `PowerModeChanged` calls `$rateHistory.Clear()` off-thread while the UI timer iterates that non-thread-safe `ArrayList` → race on resume | 2/3 | Marshal handler onto UI thread |

### 🟠 Data-loss (1)
| Location | Bug | Votes | Fix direction |
|---|---|---|---|
| `BatteryWidget.ps1:725` | `Load-Config` blanket empty `catch{}` → factory defaults (`FirstRunShown=false`) on any parse error → first-run tooltip triggers `Save-Config`, which atomically replaces the file and deletes `.bak`, destroying the recoverable config + history | 3/3 | On load failure set a flag and suppress `Save-Config` (or back up the bad file) |

### 🟡 Silent-wrong (7)
| Location | Bug | Votes | Fix direction |
|---|---|---|---|
| `BatteryWidget.ps1:1804` | Overlapping low-battery notifications share one set of `$script:` animation-phase vars → first card animates to the second's state | 3/3 | Per-notification phase state (or serialize) |
| `BatteryEstimation.ps1:152` | AC transition resets `emaRate` but **not** `lastValidRate`; 60s freshness check is recency-only → charging rate seeds a discharge estimate | 3/3 | Clear `lastValidRate`/time on AC change, or tag by AC state |
| `BatteryWidget.ps1:3096` | Update-tick `try{…}catch{}` swallows recurring `New-BatteryIcon`/GDI throws → UI silently freezes at stale values | 3/3 | Log + surface a degraded state |
| `BatteryEstimation.ps1:104` | `lastCapacityCheck` baseline not reset on AC change → cross-phase delta, noise-driven wrong rate or skipped validation | 3/3 | Reset baseline to `$null` on AC change |
| `BatteryWidget.ps1:296` & `:321-322` | Extended-WMI guards (`DesignCapacity`/`FullChargeCapacity`/`EstimatedRunTime`/`FullRuntimeMinutes`) miss `0xFFFFFFFF`; cast overflows, empty catch swallows → wear/runtime silently never computed (same sentinel family as the crashes) | 2/3 | Add `-lt 4294967295` before the casts; log don't swallow |
| `BatteryWidget.ps1:711` | Per-entry history parse failures (corruption/partial-write/locale/edit) silently dropped → truncated persisted sparkline | 2/3 | Log dropped entries; warn when restored < persisted |

### ⚪ Cosmetic (7)
| Location | Bug | Votes | Fix direction |
|---|---|---|---|
| `BatteryWidget.ps1:1774` | `Show-BatteryNotification` leaks two `Font` (GDI) objects per notification | 3/3 | Track + Dispose fonts on close (mirror popup `$fontsToDispose`) |
| `BatteryWidget.ps1:932` | `Update-PillSize` doesn't dispose stale `$script:pillFont2` when switching to a single-line size | 3/3 | Dispose/null unconditionally before the `FontSize2` check |
| `BatteryWidget.ps1:926` | `Update-PillSize` replaces `Form.Region` without disposing the previous one | 3/3 | Capture old Region, assign new, then Dispose old |
| `BatteryWidget.ps1:2072` | `$script:estimatingLabel` shared between hover & modal popup → one popup's "Estimating…" pulse stops | 3/3 | Per-popup label refs (scope to owning window) |
| `BatteryWidget.ps1:2836` | Managed `NotifyIcon.Icon` wrapper never disposed on reassignment (native HICON is freed) | 2/3 | Dispose previous `.Icon` before assigning new |
| `BatteryWidget.ps1:465` | `Get-PowerPlans` returns `@()` on failure, indistinguishable from "no plans" → misleading "Not available" | 2/3 | Distinguish failure from empty (return `$null` vs `@()`) |
| `BatteryWidget.ps1:268` | dotnet-fallback percent uses rounded integer for thresholds → one-step status/color misclassification at fractional boundaries | 2/3 | Compare thresholds against `PercentExact` |

### Refuted (10 — checked & cleared, do not re-chase)
`C10` timer↔Save-Config race (timer never reaches Save-Config; single-threaded pump) · `C13` EMA truncation-to-0 (real rates are thousands of mW) · `C19` config `.tmp` ANSI encoding (all JSON values are pure ASCII; read is symmetric) · `C22` PowerStatus unguarded (infallible value-type) · `C27`/`C28`/`C29` Build version/exe-cleanup (not reachable by runtime/build input) · `C30` `MainModule.FileName` (reliable for self; `$PWD` fallback) · `C31` `$PSScriptRoot` guard (supported `-File`/dot-source set it) · `C32` stale BOM comment (build is lossless — doc inaccuracy only).

### Recommended fix order (highest value first)
1. **`0xFFFFFFFF` sentinel guard** — one consistent `-lt 4294967295` pattern kills 2 crashes + 1 silent-wrong across 4 sites (`BatteryWidget.ps1:352,296,321-322` + `CheckBattery.ps1:108`).
2. **Clamp `RefreshInterval`** at load (`BatteryWidget.ps1:677`).
3. **Suppress `Save-Config` on a failed load** (`BatteryWidget.ps1:725`) — the only data-loss bug.
4. **Marshal the two `SystemEvents` handlers** onto the UI thread (`:2919`, `:2934`).
5. Then the remaining silent-wrong (AC-transition estimation state `:152`/`:104`, frozen-UI `:3096`, history `:711`, notifications `:1804`) and the cosmetic GDI leaks.

> Coverage note: all 4 files reached (36 raw → 32 deduped → 20 confirmed). No dimension genuinely dry. Residual uncertainty is probability-of-occurrence, not reachability (e.g. `C24` needs a driver emitting `0xFFFFFFFF`; `C26` needs config corruption/locale drift).
