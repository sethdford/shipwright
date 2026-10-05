# Tasks — Classify and surface flatlining build-loop iterations distinct from context exhaustion

## Status: In Progress
Pipeline: standard | Branch: feat/classify-and-surface-flatlining-build-lo-7689

## Checklist
- [ ] **Task 1**: Add `compute_stall_reason()` function to `scripts/lib/loop-flatline.sh` with logic for all four cases
- [ ] **Task 2**: Read `flatline.json` and error history in `compute_stall_reason()` to determine streak and error signatures
- [ ] **Task 3**: Call `compute_stall_reason()` in `scripts/sw-loop.sh` after loop termination, store in `LOOP_STALL_REASON`
- [ ] **Task 4**: Update `progress.md` write logic to include `Stall reason:` line (after `Exit class:`)
- [ ] **Task 5**: Update `error-summary.json` write logic to include `"stall_reason"` field
- [ ] **Task 6**: Create `_retry_action_for_stall_reason()` function in `scripts/sw-daemon.sh` with decision logic
- [ ] **Task 7**: Update `_should_restart()` in `scripts/sw-daemon.sh` to read stall_reason and call new function
- [ ] **Task 8**: Add max-retry config per stall_reason (optional: `loop.max_retries_by_reason` in daemon-config.json)
- [ ] **Task 9**: Write unit test for `compute_stall_reason()` in `sw-loop-test.sh` covering all cases
- [ ] **Task 10**: Write unit test for daemon retry logic in `sw-lib-daemon-failure-test.sh` covering all cases
- [ ] **Task 11**: Write backward-compatibility test (missing stall_reason field) in both test suites
- [ ] **Task 12**: Update documentation in CLAUDE.md: `loop.max_retries_by_reason` config section
- [ ] **Task 13**: Run full test suite (`npm test`) and verify no regressions
- [ ] **Task 14**: Manual smoke test: trigger loop failure, check progress.md/error-summary.json for stall_reason
- [ ] **Task 15**: Verify daemon restart logic respects stall_reason in live daemon run (or via e2e test)
- [ ] `compute_stall_reason()` function exists in loop-flatline.sh and handles all four cases
- [ ] `stall_reason` field written to progress.md and error-summary.json on loop termination
- [ ] Daemon reads `stall_reason` and uses it in retry/restart/abort decision
- [ ] No hardcoded stall_reason values (all derived from loop state)
- [ ] sw-loop-test.sh has 4+ unit tests for classification (all cases covered)

## Notes
- Generated from pipeline plan at 2026-10-05T00:57:47Z
- Pipeline will update status as tasks complete
