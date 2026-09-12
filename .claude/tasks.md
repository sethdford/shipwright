# Tasks — Add a pipeline-stage timeout escalation policy driven by historical stage duration, not fixed constants

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-4854

## Checklist
- [ ] Task 1: Fix lookback no-op in `timeout_calculate_p95` (use `head`, newest-first ordering)
- [ ] Task 2: Route `TIMEOUT_*` knobs through `_smart_int` with guarded fallback
- [ ] Task 3: Implement `timeout_for_attempt` escalation ladder (integer-percent math)
- [ ] Task 4: Add `result` field to JSONL; exclude timeout-killed rows from p95
- [ ] Task 5: Implement watchdog start/stop + `timeout_classify_overrun`
- [ ] Task 6: Implement `timeout_record_aggregate` → `stage-durations.json` (atomic, `jq --arg`)
- [ ] Task 7: Call `timeout_record` on success *and* failure paths in `run_pipeline`
- [ ] Task 8: Wire budget export, watchdog, and `timeout` escalation case into `run_stage_with_retry`
- [ ] Task 9: Repoint `daemon-adaptive.sh` at the aggregate file with `.jsonl` fallback
- [ ] Task 10: Add `pipeline.timeout_escalation` to `config/policy.json`
- [ ] Task 11: Register `shipwright timeout report|reset` CLI subcommand
- [ ] Task 12: Add ~14 tests to `sw-adaptive-timeout-test.sh`
- [ ] Task 13: Sync `VERSION` vars; add suite to `test:legacy-chain`
- [ ] Task 14: Update `.claude/CLAUDE.md`; `docs sync` + `version check`
- [ ] Task 15: Full `npm test` green vs. baseline
- [ ] `timeout_get`/`timeout_record` have production callers — `grep -rn` shows hits in
- [ ] Two consecutive pipeline runs leave one `stage-durations.jsonl` row per executed
- [ ] A stage retried after a timeout receives a **strictly larger** budget than its
- [ ] Escalation is capped: no budget exceeds `TIMEOUT_MAX`, and no stage escalates more
- [ ] Escalation is class-aware: `logic` and `configuration` failures do **not** escalate

## Notes
- Generated from pipeline plan at 2026-09-12T18:14:05Z
- Pipeline will update status as tasks complete
