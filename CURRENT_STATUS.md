> # ⚠️ CORRECTION — 2026-06-03: This handoff is HISTORICAL/ASPIRATIONAL, not current state
>
> A launch-readiness review found that key items in the "Popup Design Audit" below were **NOT actually shipped**. The current `BatteryWidget.ps1` refutes them:
>
> - **"Simplified title" — NOT shipped.** The code still builds the popup title **with** the percentage (e.g. `"Discharging — 72%"`), not a bare `"Charging"`/`"Discharging"`. See `BatteryWidget.ps1` lines ~1504 and ~1515.
> - **"Percent: XX% row deleted" — NOT shipped.** The popup still renders the **"Percent:"** row. See `BatteryWidget.ps1` line ~1564.
> - **"18pt hero percentage" — NOT shipped as described.** The 18pt hero treatment is applied to the **Time** row (the data users care about most), not to a percentage.
>
> Everything below this banner is preserved for history but describes **planned/intended** work — do not rely on it as a description of the current codebase. For the corrected record see the annotated 2026-02-05 changelog entry in `CLAUDE.md`.

# Session Handoff — 2026-02-05

## Changelog

### Popup Design Audit (10 steps)
All changes in `BatteryWidget.ps1`:

1. **Simplified title** — "Charging" / "Discharging" instead of "Charging - 90%". Title conveys state, hero % conveys data.
2. **Hidden N/A rows** — Capacity, Rate, Runtime, Wear rows skip rendering when value is "N/A". Popup shrinks automatically.
3. **Font contrast** — Standard rows 8pt -> 7.5pt, hero rows 9pt -> 10pt. Secondary row labels use `TextMuted` instead of `TextDim`.
4. **Large hero percentage** — 18pt Semibold Bold percent below title separator, colored with status color. Old "Percent: XX%" row deleted.
5. **Group spacing** — 1px separator line between hero/secondary rows replaced with 6px whitespace gap.
6. **Right-aligned values** — `Add-PopupRow` returns `$val`, uses `AutoSize = $false` + fixed `Size` + `TextAlign = TopRight`. All call sites updated with `-RowHeight` param; non-capturing calls prefixed with `$null =`.
7. **Sparkline improvements** — Height 30px -> 40px. Current value dot (6px accent-colored circle) at end of line. Guide text 6pt/70-alpha -> 7pt/120-alpha for readability.
8. **Skip empty close hint** — Hover popup passes `""` for CloseHintText; now wrapped in `if ($CloseHintText)` to avoid dead label and save ~16px.
9. **Power source icon** — Lightning bolt (U+26A1) for AC, bullet (U+2022) for battery, prepended to power source text.
10. **"Estimating..." text pulse** — Captures time row value label in `$script:estimatingLabel`. Pulse timer oscillates ForeColor alpha (120-200) with sine wave. Added to `$anyActive` gate. Cleanup in `Close-HoverPopup` and after modal dispose.

### Bug Fixes
- **Exit error fixed** — `remove_PowerModeChanged($null)` caused "Object reference not set" on exit. Now stores delegates in `$script:powerModeHandler` and `$script:displaySettingsHandler`, passes them to `remove_` calls.
- **Hero text clipping fixed** — Row start pushed from 68px -> 78px to clear 18pt hero percentage. Label column widened 58px -> 70px, value column shifted 68px -> 80px. Separate `$heroRh` (24px) for hero row height vs standard `$rh` (18px).

## Decisions

- **Dropped Phase 3.2 (sequential row fade)** — WinForms Labels don't support per-control opacity. Would require custom-drawn panel, not worth the complexity.
- **Right-align via fixed-size labels** — `AutoSize = $false` + `TextAlign = TopRight` is the only way to right-align in WinForms Labels. Trade-off: text clips instead of wrapping if too long, but `$vw` (popup width minus margins) is generous enough.
- **Separate hero row height** — 10pt hero font needs ~22px; standard 18px row height clips descenders. `$heroRh = 24 * $DpiScale` used only for the Time row.
- **Event delegate storage** — .NET `remove_` methods require the exact delegate reference. Storing in `$script:` vars is the standard PowerShell pattern for proper unsubscribe.

## Next Actions

1. **Visual QA at different states** — Test popup in all states: discharging (shows "Remaining:"), charging with rate (shows Rate row), fully charged, no battery (desktop PC).
2. **DPI testing** — Verify at 125% and 150% scaling — the hero label positioning (y=38) and row start (y=78) may need DPI-proportional adjustment.
3. **Discharging label width** — "Remaining:" at 10pt Semibold is ~85px. Current `$lw = 70px` may clip it. Test and potentially increase to 80px if needed.
4. **Update CLAUDE.md** — Add changelog entry for the popup design audit under the existing entries.
5. **Consider popup width** — Currently 280px. With right-aligned values and larger hero %, a bump to 300px could give more breathing room. Test first.
