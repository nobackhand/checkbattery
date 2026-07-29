#!/usr/bin/env bash
#
# scripts/verify.sh - the single gate for BatteryPill.
#
# Runs lint, the full test suite, and a real build. Exits nonzero if ANY stage
# fails; prints per-stage timings and a summary. Every stage is bounded by a
# timeout so the whole run stays well under 10 minutes.
#
#   ./scripts/verify.sh          # lint + tests + build
#   VERIFY_JOBS=1 ./scripts/verify.sh   # force the old one-at-a-time run
#
# SPEED: the three stages are independent - lint and tests only READ the repo,
# and the only file the build writes (BatteryPill-<version>.exe) is not an
# input to either of the others - so they run CONCURRENTLY by default. Each
# stage's output is buffered to its own log and replayed in the original
# lint -> tests -> build order, so the transcript reads exactly as it did when
# the stages ran serially; only the wall clock changes. Wall time becomes the
# slowest stage instead of the sum (~19s -> ~10s on a warm checkout).
#
# Concurrency is skipped automatically when PSScriptAnalyzer or ps2exe still
# need their one-time Install-Module bootstrap, since two stages installing
# from the gallery at once can race.
#
# Requires: Windows PowerShell 5.1 (powershell.exe on PATH) and the ps2exe
# module for the build stage (Build.ps1 installs it on first use).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Per-stage wall-clock ceilings (seconds). Sum is under the 10-minute budget.
LINT_TIMEOUT=120
TEST_TIMEOUT=240
BUILD_TIMEOUT=240

FAILED=0
SUMMARY=""

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Runs one stage to completion, capturing its output in $WORK_DIR/<slug>.log and
# "<status> <elapsed>" in $WORK_DIR/<slug>.status. Safe to background.
run_stage_to_log() {
  local slug="$1" limit="$2"; shift 2
  local start end status
  start=$(date +%s)
  timeout "$limit" "$@" >"$WORK_DIR/$slug.log" 2>&1
  status=$?
  end=$(date +%s)
  echo "$status $((end - start))" >"$WORK_DIR/$slug.status"
}

# Replays a finished stage's log and folds its result into the summary.
report_stage() {
  local slug="$1" name="$2" limit="$3"
  local status elapsed
  read -r status elapsed <"$WORK_DIR/$slug.status"

  echo ""
  echo "=============================================================="
  echo "== $name"
  echo "=============================================================="
  cat "$WORK_DIR/$slug.log"

  if [ "$status" -eq 124 ]; then
    echo "-- $name TIMED OUT after ${limit}s"
    SUMMARY="${SUMMARY}  FAIL  ${name} (timeout after ${limit}s)\n"
    FAILED=1
  elif [ "$status" -ne 0 ]; then
    echo "-- $name FAILED (exit $status) in ${elapsed}s"
    SUMMARY="${SUMMARY}  FAIL  ${name} (exit ${status}, ${elapsed}s)\n"
    FAILED=1
  else
    echo "-- $name OK in ${elapsed}s"
    SUMMARY="${SUMMARY}  ok    ${name} (${elapsed}s)\n"
  fi
}

# `timeout` execs a real binary, so stages invoke powershell.exe directly.
PS_ARGS=(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File)

if ! command -v powershell.exe >/dev/null 2>&1; then
  echo "FATAL: powershell.exe not on PATH - verify.sh requires Windows PowerShell 5.1"
  exit 1
fi

# One-time module bootstrap still pending? Then serialize, so lint and build
# don't hit the PowerShell Gallery (and the CurrentUser module dir) at once.
NEEDS_BOOTSTRAP=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \
  "if ((Get-Module -ListAvailable -Name PSScriptAnalyzer) -and (Get-Module -ListAvailable -Name ps2exe)) { 'no' } else { 'yes' }" 2>/dev/null | tr -d '\r\n')

JOBS="${VERIFY_JOBS:-3}"
if [ "$NEEDS_BOOTSTRAP" != "no" ]; then
  echo "INFO: PSScriptAnalyzer/ps2exe bootstrap pending - running stages serially this once."
  JOBS=1
fi

TOTAL_START=$(date +%s)

# 1) Lint / source health: UTF-8 BOM gate + parse check of every .ps1 we ship.
# 2) Full test suite: every tests/*.Tests.ps1.
# 3) Build: compile BatteryWidget.ps1 to BatteryPill-<version>.exe via ps2exe.
if [ "$JOBS" -gt 1 ]; then
  run_stage_to_log lint  "$LINT_TIMEOUT"  "${PS_ARGS[@]}" tools/check-source.ps1 &
  run_stage_to_log tests "$TEST_TIMEOUT"  "${PS_ARGS[@]}" scripts/run-tests.ps1 &
  run_stage_to_log build "$BUILD_TIMEOUT" "${PS_ARGS[@]}" Build.ps1 &
  wait
else
  run_stage_to_log lint  "$LINT_TIMEOUT"  "${PS_ARGS[@]}" tools/check-source.ps1
  run_stage_to_log tests "$TEST_TIMEOUT"  "${PS_ARGS[@]}" scripts/run-tests.ps1
  run_stage_to_log build "$BUILD_TIMEOUT" "${PS_ARGS[@]}" Build.ps1
fi

TOTAL_END=$(date +%s)

report_stage lint  "lint (tools/check-source.ps1)" "$LINT_TIMEOUT"
report_stage tests "tests (scripts/run-tests.ps1)" "$TEST_TIMEOUT"
report_stage build "build (Build.ps1)"             "$BUILD_TIMEOUT"

echo ""
echo "=============================================================="
echo "== verify summary"
echo "=============================================================="
printf "%b" "$SUMMARY"
echo "  total: $((TOTAL_END - TOTAL_START))s"

if [ $FAILED -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
exit 0
