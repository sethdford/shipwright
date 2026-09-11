# Tasks — Escalate model/effort on repeated identical failure signatures during daemon retries

## Status: In Progress
Pipeline: standard | Branch: feat/escalate-model-effort-on-repeated-identi-4747

## Checklist
- [ ] Task 1: `normalize_failure_signature()` — ANSI/timestamp/path/digit normalization, `cksum` → `<class>:<8hex>`, `:none` on empty input
- [ ] Task 2: `escalate_effort_level()` and `escalate_model_tier()` — ladder with idempotent ceiling
- [ ] Task 3: `record_failure_signature()` — `locked_state_update` with `--arg`, `history` capped at 5, count re-read from state
- [ ] Task 4: `escalation.on_repeat_signature` / `escalation.repeat_threshold` via `_smart_int` with inline defaults
- [ ] Task 5: compute signature in the retryable arm; emit `daemon.failure_signature` on every retry
- [ ] Task 6: escalation decision block; emit `daemon.escalation` with `result=escalated|at_ceiling`
- [ ] Task 7: clamp `--max-restarts` to `loop.hard_restart_cap` (replaces hardcoded `5`)
- [ ] Task 8: save/restore `EFFORT_LEVEL` around `daemon_spawn_pipeline`
- [ ] Task 9: clear `.failure_signatures[$num]` on success and in `reset_failure_tracking()`
- [ ] Task 10: unit tests — normalization stability, ladder, state persistence
- [ ] Task 11: integration tests — distinct sigs (no escalation), 2× identical (escalation fires), ceiling, `hard_restart_cap`, `RETRY_ESCALATION=false`
- [ ] Task 12: GitHub retry comment rows for signature + effort
- [ ] Task 13: `.claude/CLAUDE.md` Daemon Configuration + event contract
- [ ] Task 14: `bash scripts/sw-lib-daemon-failure-test.sh` green; `bash -n` clean on both changed scripts
- [ ] Task 15: `npm test` chain green (or, if the full chain is impractical in CI time, the daemon + compat + dispatch suites explicitly, with the skipped scope stated in the PR)
- [ ] Failure signatures are normalized (class + file/error-type + message shape, path- and digit-independent) and compared across consecutive retries for the same issue
- [ ] On the 2nd consecutive identical signature, the retry spawns with `model_routing.high_risk` and effort one rung up the `low→medium→high→xhigh→max` ladder
- [ ] Escalation at the ladder ceiling is a logged no-op (`result=at_ceiling`), never an error
- [ ] `daemon.escalation` and `daemon.failure_signature` events reach `events.jsonl` with issue, signature, consecutive count, and from/to model+effort
- [ ] `--max-restarts` never exceeds `loop.hard_restart_cap` on any escalation path (hardcoded `5` removed)

## Notes
- Generated from pipeline plan at 2026-09-11T12:18:12Z
- Pipeline will update status as tasks complete
