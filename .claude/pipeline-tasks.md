# Pipeline Tasks — Add pipeline dry-run summary with stage timing estimates

## Implementation Checklist

- [x] Task 1: Add `dry_run_summary()` function to `cct-pipeline.sh`
- [x] Task 2: Replace existing dry-run block with `dry_run_summary` call
- [x] Task 3: Implement per-stage model resolution (CLI > stage config > defaults > opus)
- [x] Task 4: Implement median duration from `events.jsonl` `stage.completed` events
- [x] Task 5: Implement median cost from `events.jsonl` — adapted: no per-stage cost events exist, uses pipeline.cost for total
- [x] Task 6: Add budget remaining display via `cct-cost.sh remaining-budget`
- [x] Task 7: Add formatted table output with Unicode separators
- [x] Task 8: Handle graceful fallback ("no data" / "—") when no history
- [x] Task 9: Add `test_dry_run_summary_with_history` test
- [x] Task 10: Add `test_dry_run_summary_no_history` test
- [x] Task 11: Register both new tests in runner array
- [x] Task 12: Add events.jsonl backup/restore in test setup/teardown
- [x] Task 13: Run full test suite and fix failures — all 167 tests pass
- [x] `--dry-run` shows table with Stage, Est. Duration, Model, Est. Cost
- [x] Duration uses median from historical `stage.completed` events
- [x] Cost: pipeline-level median from `pipeline.cost` events (no per-stage cost events exist)
- [x] Model resolves per-stage from template config
- [x] "no data" / "—" shown when no history exists
- [x] Total row with summed duration and cost
- [x] Budget line when budget enabled

## Context

- Pipeline: standard
- Branch: ci/add-pipeline-dry-run-summary-with-stage-5
- Issue: #5
- Generated: 2026-02-09T21:05:58Z
