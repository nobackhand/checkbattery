#!/usr/bin/env bash
#
# scripts/setup.sh - the one command from a fresh clone to a running BatteryPill.
#
#   ./scripts/setup.sh             # check prereqs, install deps, build, launch
#   ./scripts/setup.sh --no-run    # everything except launching the widget
#   ./scripts/setup.sh --help
#
# Idempotent: safe to re-run. Requires Windows and Windows PowerShell 5.1
# (powershell.exe on PATH); everything else it installs itself.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# powershell.exe cannot resolve a POSIX path (e.g. /tmp/... under Git Bash), so
# keep a native Windows form of the repo root for anything we hand to it.
WIN_ROOT="$(pwd -W 2>/dev/null)" || WIN_ROOT=""
[ -n "$WIN_ROOT" ] || WIN_ROOT="$(cygpath -w "$REPO_ROOT" 2>/dev/null)" || WIN_ROOT="$REPO_ROOT"

RUN_APP=1
for arg in "$@"; do
  case "$arg" in
    --no-run) RUN_APP=0 ;;
    -h|--help)
      sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "setup: unknown option '$arg' (try --help)" >&2
      exit 2 ;;
  esac
done

step() { echo ""; echo "== $*"; }
fail() { echo "SETUP FAILED: $*" >&2; exit 1; }

# 1) Prerequisites --------------------------------------------------------
step "1/4 prerequisites"
command -v powershell.exe >/dev/null 2>&1 \
  || fail "powershell.exe not on PATH. BatteryPill is a Windows app and needs Windows PowerShell 5.1."
PS_VERSION=$(powershell.exe -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' | tr -d '\r')
echo "   Windows PowerShell $PS_VERSION"
case "$PS_VERSION" in
  1.*|2.*|3.*|4.*) fail "PowerShell 5.0+ required, found $PS_VERSION" ;;
esac

# 2) Dependencies ---------------------------------------------------------
# Stock PS 5.1 has no TLS 1.2 default and no NuGet provider, so bootstrap both
# before asking for ps2exe. All three steps are no-ops when already satisfied.
step "2/4 dependencies (ps2exe)"
timeout 300 powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
    Write-Host "   installing NuGet package provider..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
  }
  if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "   installing ps2exe module..."
    Install-Module -Name ps2exe -Scope CurrentUser -Force
  }
  $m = Get-Module -ListAvailable -Name ps2exe | Select-Object -First 1
  if (-not $m) { throw "ps2exe unavailable after install" }
  Write-Host "   ps2exe $($m.Version) ready"
' || fail "could not install ps2exe (stage exit $?)"

# Live BatteryPill processes as "pid|path", lowercased with forward slashes so
# they can be compared against this repo's root.
ROOT_KEY=$(echo "$WIN_ROOT" | tr 'A-Z' 'a-z' | tr '\\' '/')
instances() {
  powershell.exe -NoProfile -NonInteractive -Command \
    "Get-Process -Name 'BatteryPill-*' -ErrorAction SilentlyContinue | ForEach-Object { \"\$(\$_.Id)|\$(\$_.Path)\" }" \
    2>/dev/null | tr -d '\r' | tr 'A-Z' 'a-z' | tr '\\' '/'
}
ours()    { instances | grep -F "|$ROOT_KEY/" | cut -d'|' -f1; }
theirs()  { instances | grep -vF "|$ROOT_KEY/" | cut -d'|' -f1; }

# 3) Build ----------------------------------------------------------------
step "3/4 build"
# A running instance holds a lock on its own .exe. Build.ps1's overwrite then
# fails, but the stale exe still exists so it reports "Build successful" anyway
# - i.e. a silent no-op. Stop our instances first so the build is genuine.
for p in $(ours); do
  echo "   stopping this repo's running instance (PID $p) so the exe can be rebuilt"
  powershell.exe -NoProfile -NonInteractive -Command "Stop-Process -Id $p -Force" 2>/dev/null
done
if [ -n "$(ours)" ]; then
  sleep 2
  [ -z "$(ours)" ] || fail "a BatteryPill from this folder is still running (PID $(ours | tr '\n' ' ')). Exit it via the tray icon and re-run."
fi

timeout 300 powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File Build.ps1 \
  || fail "Build.ps1 failed (exit $?)"

EXE=$(ls -1 BatteryPill-*.exe 2>/dev/null | head -n 1)
[ -n "$EXE" ] || fail "build produced no BatteryPill-*.exe"

# 4) Run ------------------------------------------------------------------
step "4/4 run"
if [ "$RUN_APP" -eq 0 ]; then
  echo "   --no-run: skipping launch. Start it yourself with: ./$EXE"
  echo ""
  echo "SETUP OK: $EXE built and ready."
  exit 0
fi

FOREIGN=$(theirs | tr '\n' ' ')
if [ -n "${FOREIGN// /}" ]; then
  echo "   another BatteryPill is already running from a different folder (PID ${FOREIGN% })."
  echo "   The single-instance mutex would block this one, so the launch is skipped."
  echo "   Exit that instance from its tray icon, then run: ./$EXE"
  echo ""
  echo "SETUP OK: $EXE built; launch skipped (another instance owns the mutex)."
  exit 0
fi

APP_PID=$(powershell.exe -NoProfile -NonInteractive -Command \
  "(Start-Process -FilePath '$WIN_ROOT\\$EXE' -PassThru).Id" 2>/dev/null | tr -d '\r')
[ -n "$APP_PID" ] || fail "could not launch $EXE"

# Give the widget a moment to claim its mutex and paint the pill, then confirm
# it is genuinely still up (not a process that started and immediately died).
PID_OUT=""
for _ in 1 2 3 4 5; do
  sleep 1
  PID_OUT=$(ours | grep -Fx "$APP_PID")
  [ -n "$PID_OUT" ] && break
done
[ -n "$PID_OUT" ] || fail "$EXE started (PID $APP_PID) but is no longer running"

echo "   $EXE running (PID $PID_OUT)"
echo ""
echo "SETUP OK: BatteryPill is running."
echo "  - the pill is on your desktop; drag it anywhere, click to change what it shows"
echo "  - quit via the tray icon's Exit item (or: taskkill //PID $PID_OUT //F)"
exit 0
