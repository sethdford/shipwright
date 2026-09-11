# Pipeline Tasks — Escalate model/effort on repeated identical failure signatures during daemon retries

## Implementation Checklist
- [x] Task 1: `normalize_failure_signature()` — ANSI/timestamp/path/digit normalization, `cksum` → `<class>:<8hex>`, `:none` on empty input
- [x] Task 2: `escalate_effort_level()` and `escalate_model_tier()` — ladder with idempotent ceiling
- [x] Task 3: `record_failure_signature()` — `locked_state_update` with `--arg`, `history` capped at 5, count re-read from state
- [x] Task 4: `escalation.on_repeat_signature` / `escalation.repeat_threshold` via `_smart_int` with inline defaults
- [x] Task 5: compute signature in the retryable arm; emit `daemon.failure_signature` on every retry
- [x] Task 6: escalation decision block; emit `daemon.escalation` with `result=escalated|at_ceiling`
- [x] Task 7: clamp `--max-restarts` to `loop.hard_restart_cap` (replaces hardcoded `5`)
- [x] Task 8: save/restore `EFFORT_LEVEL` around `daemon_spawn_pipeline`
- [x] Task 9: clear `.failure_signatures[$num]` on success and in `reset_failure_tracking()`
- [x] Task 10: unit tests — normalization stability, ladder, state persistence
- [x] Task 11: integration tests — distinct sigs (no escalation), 2× identical (escalation fires), ceiling, `hard_restart_cap`, `RETRY_ESCALATION=false`
- [x] Task 12: GitHub retry comment rows for signature + effort
- [x] Task 13: `.claude/CLAUDE.md` Daemon Configuration + event contract
- [x] Task 14: `bash scripts/sw-lib-daemon-failure-test.sh` green; `bash -n` clean on both changed scripts
- [x] Task 15: `npm test` chain green (or, if the full chain is impractical in CI time, the daemon + compat + dispatch suites explicitly, with the skipped scope stated in the PR)
- [x] Failure signatures are normalized (class + file/error-type + message shape, path- and digit-independent) and compared across consecutive retries for the same issue
- [x] On the 2nd consecutive identical signature, the retry spawns with `model_routing.high_risk` and effort one rung up the `low→medium→high→xhigh→max` ladder
- [x] Escalation at the ladder ceiling is a logged no-op (`result=at_ceiling`), never an error
- [x] `daemon.escalation` and `daemon.failure_signature` events reach `events.jsonl` with issue, signature, consecutive count, and from/to model+effort
- [x] `--max-restarts` never exceeds `loop.hard_restart_cap` on any escalation path (hardcoded `5` removed)

## Context
- Pipeline: standard
- Branch: feat/escalate-model-effort-on-repeated-identi-4747
- Issue: #4747
- Generated: 2026-09-11T12:18:11Z
