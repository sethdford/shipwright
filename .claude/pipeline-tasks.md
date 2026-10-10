# Pipeline Tasks — Detect flaky test failures and exclude them from circuit-breaker/failure counts

## Implementation Checklist
- [x] Task 1: Create `scripts/lib/test-flakiness.sh` with guard and `VERSION`; add runner detection and failing-test extraction for vitest, jest, pytest, go and sw-suite
- [x] Task 2: Implement `flaky_build_rerun_cmd` with `printf %q` escaping and the `SW_FLAKY_RERUN_TEMPLATE` override
- [x] Task 3: Implement `detect_flaky_failure` (subshell `cd`, timeout, atomic result JSON, events, repeat-offender cap)
- [ ] Task 4: Hook detection into `run_test_gate` for primary and extra commands; record `flaky: true` in test evidence
- [ ] Task 5: Extend `write_error_summary` with `failure_class`, `flaky_tests`, `regression_tests`, `rerun` and `counted_toward_circuit_breaker`; stop deleting the file on a flaky rescue
- [ ] Task 6: Skip the `CONSECUTIVE_FAILURES` increment for flaky-only iterations; adjust the `compose_prompt` messaging
- [ ] Task 7: Reset flaky state on session restart; keep the history file
- [ ] Task 8: `classify_failure` returns `flaky_test`; add the retry budget; exclude it from auto-pause
- [ ] Task 9: Add the `failure_classification` block to `daemon metrics` (JSON and dashboard)
- [ ] Task 10: Add the config defaults, register events, update CLAUDE.md
- [x] Task 11: Write `scripts/sw-lib-test-flakiness-test.sh`
- [ ] Task 12: Extend `sw-lib-daemon-failure-test.sh` and `sw-daemon-test.sh`
- [ ] Task 13: Run the new suites, then `npm test`; fix any regressions
- [ ] `scripts/lib/test-flakiness.sh` exists. It reruns a single failing test in isolation and returns `flaky` when the rerun passes. **(AC1)**
- [ ] Flaky iterations don't increment `CONSECUTIVE_FAILURES`. `error-summary.json` records `failure_class`, `flaky_tests` and `regression_tests` separately. **(AC2)**
- [ ] `classify_failure` returns `flaky_test` vs `build_failure`. `daemon metrics --json` has `failure_classification.flaky_detected` and `genuine_regressions`, and the dashboard shows both. **(AC3)**
- [ ] Unit tests prove flaky→excluded and genuine→counted. **(AC4)**
- [ ] Existing `error-summary.json` consumers (`session-restart.sh`, `context-budget.sh`, `compose_prompt`) still work, with fields unchanged.
- [ ] `bash scripts/sw-lib-test-flakiness-test.sh`, `sw-lib-daemon-failure-test.sh`, `sw-daemon-test.sh`, `sw-loop-test.sh` and the full `npm test` pass on Linux. The Bash 3.2 rules are followed (no `declare -A`, `readarray` or case-modifying expansions).
- [ ] Detection can be turned off through config or env. With it off, behavior is identical to `main`.

## Context
- Pipeline: standard
- Branch: fix/detect-flaky-test-failures-and-exclude-t-8326
- Issue: #8326
- Generated: 2026-10-10T18:25:02Z
