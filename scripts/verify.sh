#!/usr/bin/env bash
#
# scripts/verify.sh - the single gate for BatteryPill.
#
# Runs lint, the full test suite, and a real build, in that order (cheapest
# signal first). Exits nonzero if ANY stage fails; prints per-stage timings and
# a summary. Every stage is bounded by a timeout so the whole run stays well
# under 10 minutes.
#
#   ./scripts/verify.sh          # lint + tests + build
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

run_stage() {
  local name="$1" limit="$2"; shift 2
  echo ""
  echo "=============================================================="
  echo "== $name"
  echo "=============================================================="
  local start end elapsed status
  start=$(date +%s)
  timeout "$limit" "$@"
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))

  if [ $status -eq 124 ]; then
    echo "-- $name TIMED OUT after ${limit}s"
    SUMMARY="${SUMMARY}  FAIL  ${name} (timeout after ${limit}s)\n"
    FAILED=1
  elif [ $status -ne 0 ]; then
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

TOTAL_START=$(date +%s)

# 1) Lint / source health: UTF-8 BOM gate + parse check of every .ps1 we ship.
run_stage "lint (tools/check-source.ps1)" "$LINT_TIMEOUT" "${PS_ARGS[@]}" tools/check-source.ps1

# 2) Full test suite: every tests/*.Tests.ps1.
run_stage "tests (scripts/run-tests.ps1)" "$TEST_TIMEOUT" "${PS_ARGS[@]}" scripts/run-tests.ps1

# 3) Build: compile BatteryWidget.ps1 to BatteryPill-<version>.exe via ps2exe.
run_stage "build (Build.ps1)" "$BUILD_TIMEOUT" "${PS_ARGS[@]}" Build.ps1

TOTAL_END=$(date +%s)

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
