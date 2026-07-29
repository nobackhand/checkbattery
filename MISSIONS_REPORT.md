# Missions Report

40-mission improvement loop on branch `missions`. Orchestrator dispatches one fresh
subagent per mission, verifies independently, then advances. Started 2026-07-28 23:23 CDT.
Hard stop: 9:00am local or all 40 done/skipped.

## Standing rules (included verbatim in every dispatch)

* Missions 1–30 are behavior-preserving. Missions 31–40 add or change behavior on purpose, but existing tests and verify.sh remain the floor: nothing regresses.
* Never weaken a check to pass it: no deleted tests, lowered thresholds, skipped assertions, or bypassed hooks. Quarantining a genuinely flaky test requires a linked note in TODO.md.
* Smallest diff the outcome allows. Method and effort are your call.
* Done means `scripts/verify.sh` exits 0 AND the mission's stated proof is demonstrated with real command output, or evidence committed under `missions-evidence/` for visual work. Commit finished work as `mission NN: <summary>`. If genuinely blocked, say so plainly and stop.

## Orchestrator protocol

1. Record current HEAD. 2. Dispatch ONE fresh subagent (never parallel) with only: standing
rules verbatim + the single mission's text (+ on retry, tail of failing verify output).
3. Verify independently — run `scripts/verify.sh` myself, confirm the commit/output/evidence
is real. 4. Pass → check off with one-line proof, commit report, continue. Fail → `git reset
--hard` to recorded HEAD, clean untracked, retry fresh. After 3 failures → mark
"Skipped: <reason>" and move on. 5. Never read the codebase; report + git log are the state.

## Missions

- [x] 1. Create `scripts/verify.sh` — build + full tests + lint, nonzero exit on any failure, under 10 minutes — and document it in the README. Proof: it passes on the current tree. — **DONE** e1cfae8. Orchestrator ran `./scripts/verify.sh`: **exit 0 in 4s** (lint 0s / tests 1s / build 3s). Repo had no tests; agent added `tests/` (45 asserts) + `scripts/run-tests.ps1` + AST-based harness (can't dot-source the widget — it ends in `Application::Run()`). Orchestrator negative control: injected a bug into `Format-Duration` → **exit 1** ("1 of 2 test file(s) failed"), reverted clean. `.gitattributes` added so `*.sh` stays LF (CRLF would kill verify.sh on fresh clone).
- [ ] 2. Make setup one documented command from fresh clone to running project. Proof: execute it in a clean temp directory.
- [ ] 3. Test suite fully green — fix broken tests, quarantine truly flaky ones with linked notes. Proof: full suite passes twice consecutively.
- [ ] 4. Zero build/compiler/deprecation warnings — fix or suppress each with a one-line justification. Proof: warning-free build log.
- [ ] 5. Lint + autoformat wired up and applied repo-wide; mechanical reformat committed separately from logic fixes. Proof: linter exits 0.
- [ ] 6. Strengthen typing in the weakest-typed module — no untyped public signatures, stricter checker settings than before. Proof: type checker exits 0.
- [ ] 7. Make verify.sh at least 30% faster without deleting coverage. Proof: before/after timings in the commit message.
- [ ] 8. Find one real dormant bug by reading the code; prove it with a failing test, fix it, keep the test.
- [ ] 9. Regression-test the most business-critical module until every public function's edge cases are covered; confirm each new test fails under deliberate breakage, then revert the breakage.
- [ ] 10. Audit all external I/O (network, disk, subprocess) for unhandled failure; replace silent failures with actionable errors. Proof: tests on the top three failure paths.
- [ ] 11. Input validation at every trust boundary — malformed input yields clean errors, never crashes. Proof: adversarial tests.
- [ ] 12. Inspect shared mutable state for race conditions; fix what's unsafe. Proof: a stress test that fails against the old code.
- [ ] 13. Every acquired resource (files, sockets, locks, subprocesses, GPU memory) released on all paths including error paths. Proof: leak tooling or targeted tests.
- [ ] 14. Upgrade dependencies to latest compatible, remove unused, regenerate lockfiles. Proof: verify.sh green with zero new warnings.
- [ ] 15. Secrets sweep — move any found to env config with a committed `.env.example`; add a secret scan to verify.sh. Proof: scan reports clean.
- [ ] 16. Run dependency audit + static security analysis; fix every high/critical finding or document accepted risk beside it. Proof: scanner output shows zero high/critical.
- [ ] 17. Benchmark the hottest user-facing path, then land one optimization worth at least 20% on it. Proof: both numbers in the commit message.
- [ ] 18. Measure and materially cut cold start (app launch, server boot, or build). Proof: before/after timings in the commit message.
- [ ] 19. Eliminate the worst redundant work (repeated queries, recomputed values, N+1 patterns). Proof: a test asserting the reduced call count.
- [ ] 20. Shrink the shipped artifact (bundle, binary, or image) with zero feature loss. Proof: before/after sizes in the commit message.
- [ ] 21. Delete dead code — unreferenced files, functions, exports, stale flags, commented-out blocks. Proof: verify.sh green and searches show no remaining references.
- [ ] 22. Refactor the single most complex function in the repo for readability with identical behavior. Proof: existing tests pass unmodified.
- [ ] 23. Extract the three worst copy-paste duplication clusters into shared code. Proof: tests green, duplication measurably reduced.
- [ ] 24. Break the worst dependency tangle (circular imports, modules reaching into another's internals); add an import-boundary check to verify.sh. Proof: the check passes.
- [ ] 25. Accessibility pass on the primary user flows — labels, contrast, focus/keyboard or VoiceOver navigation. Proof: platform accessibility audit tooling or targeted checks.
- [ ] 26. Make failures diagnosable from logs alone — no swallowed exceptions, every error path logs cause and context. Proof: induce two distinct failures; logs name each cause.
- [ ] 27. Rewrite the README end to end (what it is, setup, run, test, deploy), executing every command yourself before committing it.
- [ ] 28. Write ARCHITECTURE.md, one page maximum: modules, boundaries, data flow, and the three decisions a newcomer must understand. Every path it names must exist.
- [ ] 29. Triage every TODO/FIXME/HACK — fix the five-minute ones, migrate the rest to TODO.md with context, delete the stale. Proof: marker count at or near zero.
- [ ] 30. Pin the full environment (exact toolchain versions, lockfiles, container or version-manager config). Proof: a clean-environment build using only what's pinned.
- [ ] 31. Use the product start to finish as a first-time user; fix the three worst friction points you personally hit. Proof: before/after evidence per fix.
- [ ] 32. Give every screen intentional loading, empty, and error states — no blank flashes, no raw error dumps. Proof: evidence of each state.
- [ ] 33. Visual consistency pass — spacing, alignment, typography, and color against one coherent scale; fix the worst offenders. Proof: before/after evidence.
- [ ] 34. Improve perceived performance: skeletons, optimistic updates, instant feedback on any action slower than ~100ms. Proof: before/after recordings.
- [ ] 35. Interaction polish — press states, transitions, and feedback on every interactive element, plus one detail of unexpected craft. Proof: recording or state-by-state evidence.
- [ ] 36. Copy pass: read every user-facing string; fix jargon, inconsistent tone, and unclear errors. Proof: the string diff with one-line rationales.
- [ ] 37. Onboarding: get a brand-new user from first launch to the core value in under a minute. Proof: evidence of the new first-run path.
- [ ] 38. Find something half-built in the code — stubs, TODOs, flags pointing at intent — and finish the most valuable one end to end, with tests.
- [ ] 39. Ship the three smallest quality-of-life wins with the highest daily payoff — shortcuts, remembered preferences, sensible defaults. Proof: each demonstrated.
- [ ] 40. Design and ship one small novel feature a real user would notice, chosen from your own use of the product — end to end, tested, documented. Proof: a working demo path.

## Log

(nothing yet)
