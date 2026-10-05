# Tasks — Classify and surface flatlining build-loop iterations distinct from context exhaustion

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-7689

## Checklist
- [ ] Task 1: Create `scripts/sw-lib-loop-classify.sh` with `fingerprint_error()`, `count_code_changes()`, `classify_iteration()` functions
- [ ] Task 2: Integrate classifier into `scripts/sw-loop.sh` iteration handler; write classifications to `flatline.json`; update `progress.md` format
- [ ] Task 3: Enhance `loop_read_exit_class()` in daemon-dispatch.sh to read `flatline.json` and return both exit class and streak count
- [ ] Task 4: Define `flatline.json` schema with iteration-level classifications and exit class summary
- [ ] Task 5: Update `progress.md` format to include `Flatline streak: X/Y` per iteration
- [ ] Task 6: Emit `loop.iteration_classified` and `loop.flatline` events to eventbus for observability
- [ ] Task 7: Update daemon retry logic in `scripts/sw-daemon.sh` to distinguish flatline from context_exhaustion
- [ ] Task 8: Add patrol function `_patrol_flatline()` to detect and alert on flatline patterns
- [ ] Task 9: Create `scripts/sw-loop-flatline-test.sh` with 6+ test cases (productive, flat, context_exhaustion, threshold, reset, fingerprinting)
- [ ] Task 10: Enhance daemon failure tests to verify flatline and context_exhaustion retry strategies
- [ ] Task 11: Add end-to-end integration test simulating 3-iteration flatline
- [ ] Task 12: Update `CLAUDE.md` with "Flatline Classification" section and examples
- [ ] Task 13: Verify no regressions in existing loop and daemon tests
- [x] Flatline classification engine created and tested
- [x] Loop integration complete (calls classifier, writes flatline.json, updates progress.md)
- [x] Daemon reads classification and applies correct retry strategy (flatline → escalate; context_exhaustion → restart boost)
- [x] `flatline.json` schema defined and documented
- [x] Events emitted: `loop.iteration_classified`, `loop.flatline`, `pipeline.flatline`
- [x] `progress.md` format updated to show `Flatline streak: X/Y`
- [x] At least 6 new test cases pass (flat, productive, context_exhaustion, threshold, reset, fingerprinting)

## Notes
- Generated from pipeline plan at 2026-10-05T10:14:11Z
- Pipeline will update status as tasks complete
