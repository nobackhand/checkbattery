# Mission 10 - external I/O audit

Every site in the repo that touches the outside world, and its verdict.
"Silent" = the failure produced no user-visible signal and no record.

Scope note: the app makes **no network calls at all** (the only outbound action
is handing a URL to the shell). Network I/O exists solely in the dev/build
tooling (`Install-Module` from the PowerShell Gallery).

## Product code - `BatteryWidget.ps1`

| # | Site | Kind | Before | Verdict |
|---|------|------|--------|---------|
| 1 | `Import-Config` - `Get-Content` + `ConvertFrom-Json` | disk read | `catch {}` - every setting silently reset to defaults, and the next `Save-Config` overwrote the only copy | **FIXED** - reports file + reason + fallout; the unreadable file is kept as `*.config.json.corrupt` |
| 2 | `Save-Config` - `Set-Content` | disk write | `Set-Content` errors are **non-terminating**, so the `catch` never ran: a read-only file or missing folder lost every settings change with *no* card at all (the vague "Config Save Failed" was dead code) | **FIXED** - `-ErrorAction Stop` + a card naming the path, the reason, and that changes will be lost |
| 3 | `Set-AutoStart` (disable) - `Remove-Item` | disk delete | non-terminating too: the `catch` never ran, the function returned **`$true`**, the checkbox flipped to "off" and BatteryPill kept starting with Windows | **FIXED** - `-ErrorAction Stop`, returns `$false`, card tells the user to delete the shortcut from the Startup folder |
| 4 | `Set-AutoStart` (enable) - `WScript.Shell` COM + `.Save()` | disk write via COM | handled; showed its own card | **KEPT, unified** - routed through `Write-IoFailure` so it is recorded too |
| 5 | About dialog links - `Start-Process <url>` | shell / subprocess | **unhandled**. A broken protocol association throws inside a `LinkClicked` handler; in a PS2EXE `-noConsole` build an unhandled handler exception is a crash | **FIXED** - `Open-ExternalLink` catches and reports "type the address into your browser instead" |
| 6 | `Get-ConfigPath` - `Process.MainModule.FileName` | process image path | **unhandled** - throws when the token cannot read its own image path, killing startup before any window exists | **FIXED** - falls back to `$PWD` |
| 7 | `Get-ExePath` - `Process.MainModule.FileName` | process image path | **unhandled** - same throw, escaping into the Settings checkbox click | **FIXED** - treated as script mode (`$null`), which already has an actionable card |
| 8 | `Get-PowerPlans` - `& powercfg /list` | subprocess | `catch` + `$LASTEXITCODE` check -> `@()` | **OK as is** - the Power Plan submenu renders a visible "Not available" item; a card per menu-open would be spam |
| 9 | `Set-ActivePowerPlan` - `& powercfg /setactive` | subprocess | `catch` -> `$false`, caller shows "Admin rights needed" | **OK as is** - already actionable |
| 10 | `Get-BatteryInfo` - `Get-CimInstance Win32_Battery` | WMI | `catch` -> `$null`, falls through to the .NET `PowerStatus` source, then to the no-battery state | **OK as is** - a designed fallback chain, not a swallowed error |
| 11 | `Get-SystemTheme` - `Get-ItemPropertyValue HKCU:...\Personalize` | registry read | `catch` -> dark theme | **OK as is** - a missing value is normal on older builds; a dark default is the correct answer, not an error |
| 12 | `Import-Config` per-entry history / EMA `catch {}` | parse | skips the bad entry, keeps the rest | **OK as is** - deliberate per-entry tolerance (mission from the v1.1.1 hardening pass); the *file-level* failure is #1 |
| 13 | `Read-ConfigField` `catch` -> fallback | parse | one bad field cannot discard the others | **OK as is** - by design |
| 14 | `New-Object System.Threading.Mutex('Global\...')` | kernel object | **unhandled** - throws `UnauthorizedAccessException` when the named mutex exists under another user's session with a restrictive ACL | **NOTED, out of scope** - process synchronization, not network/disk/subprocess. Symptom: silent no-launch for a second user on a shared machine. Small, isolated follow-up. |

## Product code - `CheckBattery.ps1` (CLI)

| # | Site | Kind | Verdict |
|---|------|------|---------|
| 15 | `Get-CimInstance Win32_Battery` | WMI | **OK** - `catch` + `Write-Verbose`, falls back to .NET |
| 16 | `Add-Type -AssemblyName System.Windows.Forms` | assembly load | **OK** - `catch` + `Write-Verbose`; the no-battery banner covers both sources failing |

## Dev / build tooling (not shipped to users)

| # | Site | Kind | Verdict |
|---|------|------|---------|
| 17 | `Build.ps1` - `Install-PackageProvider` / `Install-Module ps2exe` | **network** | **OK** - failure is a loud gallery error and the run stops; the final `Test-Path $outputFile` gate prints "Build failed!" and exits 1 |
| 18 | `Build.ps1` - `Select-String -Path $inputFile` runs *before* the `Test-Path` guard | disk read | **Cosmetic only** - a missing source emits one red error, then the guard prints the clean message and exits 1. Left alone: the exit code and the actionable message are already right |
| 19 | `Build.ps1` - `Remove-Item` old exe / `Invoke-PS2EXE` | disk | **OK** - a locked exe fails loudly and the output gate exits 1 (hardened in mission 2) |
| 20 | `tools/check-source.ps1` - `Install-Module PSScriptAnalyzer`, `Test-Path` gates | network + disk | **OK** - every missing path is an explicit `FAIL:` line plus a nonzero exit |
| 21 | `tools/render-states.ps1` - stage dir, `Start-Process`, log reads | disk + subprocess | **OK** - `Test-Path` guards, timeout kills the child, stdout/stderr logs replayed, nonzero exit |
| 22 | `tools/format-source.ps1` - `WriteAllText` | disk write | **OK** - refuses to write if the token stream changed; `$ErrorActionPreference = 'Stop'` |
| 23 | `scripts/run-tests.ps1` / `scripts/verify.sh` | subprocess | **OK** - per-file exit codes, per-stage `timeout`, nonzero on any failure |

## Why these three were the tested paths

Of the 6 genuine defects (#1, #2, #3, #5, #6, #7), the three tested are the ones
whose failure **costs the user something that does not come back**:

1. **Config load** - the config file *is* the user's setup (position, theme,
   accent, size, 200 history samples). It was the only path that both lost the
   data and destroyed the evidence.
2. **Config save** - the write end of that same state. Non-terminating errors
   meant the app's one existing failure card could never fire, so *every*
   settings change could vanish with zero signal.
3. **Auto-start disable** - the only change BatteryPill makes outside its own
   folder, and the only path that returned **success** while doing nothing:
   the user turns auto-start off and it keeps launching with Windows forever.

#5 (shell link) and #6/#7 (`MainModule`) are fixed but untested: #5 needs a
broken shell association to reproduce faithfully (the test uses an unresolvable
target, which exercises the same catch), and #6/#7 need a restricted process
token that a test host cannot create.
