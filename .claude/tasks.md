# Tasks — Add pipeline dry-run summary with stage timing estimates

## Status: In Progress
Pipeline: standard | Branch: ci/add-pipeline-dry-run-summary-with-stage-5

## Checklist
- [ ] Task 1: Add `dry_run_summary()` function to `cct-pipeline.sh`
- [ ] Task 2: Replace existing dry-run block with `dry_run_summary` call
- [ ] Task 3: Implement per-stage model resolution (CLI > stage config > defaults > opus)
- [ ] Task 4: Implement median duration from `events.jsonl` `stage.completed` events
- [ ] Task 5: Implement median cost from `events.jsonl` `cost.record` events
- [ ] Task 6: Add budget remaining display via `cct-cost.sh remaining-budget`
- [ ] Task 7: Add formatted table output with Unicode separators
- [ ] Task 8: Handle graceful fallback ("no data" / "—") when no history
- [ ] Task 9: Add `test_dry_run_summary_with_history` test
- [ ] Task 10: Add `test_dry_run_summary_no_history` test
- [ ] Task 11: Register both new tests in runner array
- [ ] Task 12: Add events.jsonl backup/restore in test setup/teardown
- [ ] Task 13: Run full test suite and fix failures
- [ ] `--dry-run` shows table with Stage, Est. Duration, Model, Est. Cost
- [ ] Duration uses median from historical `stage.completed` events
- [ ] Cost uses median from historical `cost.record` events
- [ ] Model resolves per-stage from template config
- [ ] "no data" / "—" shown when no history exists
- [ ] Total row with summed duration and cost
- [ ] Budget line when budget enabled

## Notes
- Generated from pipeline plan at 2026-02-09T21:05:59Z
- Pipeline will update status as tasks complete
