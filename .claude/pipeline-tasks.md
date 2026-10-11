# Pipeline Tasks — Detect and report thrashing (oscillating) build-loop iterations distinct from flatlining

## Implementation Checklist
- [ ] Task 1: Confirm `run_tests` ordering relative to `record_iteration_stuckness_data` and the restart decision in `sw-loop.sh` (blocks 4).
- [ ] Task 2: Create `scripts/lib/loop-thrash.sh` with module guard and `thrash_record_iteration` using `git hash-object`, `jq --arg`, and atomic trim (blocks 3, 5).
- [ ] Task 3: Implement `thrash_detect` as a pure jq function with the documented contract (blocks 5, 7, 11).
- [ ] Task 4: Add `loop.thrash_window`, `loop.thrash_min_streak`, and `loop.thrash_detection_enabled` readers (blocks 5).
- [ ] Task 5: Wire record, detect, event emission, `progress.md` section, and next-prompt hint into `sw-loop.sh` (blocks 6, 8).
- [ ] Task 6: Route restart reasons through classification, fix the hardcoded reason at `:2590` and the missing reason at `:2660`, carry `seq` across restarts (blocks 7).
- [ ] Task 7: Add the thrashing branch, remove the duplicate `iteration_limit` condition, and add the strategy case in `session-restart.sh` (blocks 11).
- [ ] Task 8: Add the `Thrashing:` line to `show_summary` (blocks 12).
- [ ] Task 9: Add thrashing counts to `daemon_metrics` text and JSON output (blocks 10).
- [ ] Task 10: Sync `config/event-schema.json` (depends on 5, 9).
- [ ] Task 11: Write `scripts/sw-thrash-test.sh` with synthetic-history, fail-open, and precedence cases (depends on 3, 7).
- [ ] Task 12: Extend `sw-loop-test.sh` grep check and daemon metrics fixture test (depends on 5, 9).
- [ ] Task 13: Update docs and run `npm test`, `shipwright docs check`, and `shipwright version check` (depends on all).
- [ ] `loop-thrash.sh` exists, is sourced by `sw-loop.sh`, and uses only jq, git, and `emit_event`.
- [ ] `thrash_detect` matches the contract, with a bounded window and no associative arrays.
- [ ] A real or mock loop run with a 3-iteration edit-revert produces a `loop.thrashing_detected` event and a `reason=thrashing` restart.
- [ ] Legitimate monotone refinement and single reverts are not flagged (tested).
- [ ] `show_summary` prints the `Thrashing:` line only when episodes > 0.
- [ ] `shipwright daemon metrics` and `--json` expose thrashing counts separately from stuckness.
- [ ] Restart reason precedence is `context_exhaustion` > `manual` > `thrashing` > `stuck_loop` > `iteration_limit` > `unknown`, and the unreachable branch is removed.

## Context
- Pipeline: standard
- Branch: feat/detect-and-report-thrashing-oscillating-8525
- Issue: #8525
- Generated: 2026-10-11T04:15:20Z
