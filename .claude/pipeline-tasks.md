# Pipeline Tasks — Deduplicate identical build-loop errors across iterations to stop wasted retries

## Implementation Checklist
- [ ] T1: Create `scripts/lib/loop-error-signature.sh` with guard, `errsig_normalize_line` and `errsig_compute`
- [ ] T2: Add `errsig_update` (`TEST_PASSED=false` gate, consecutive counter, `error-signatures.txt` append, atomic enrichment of `error-summary.json`)
- [ ] T3: Add the `errsig_escalate` ladder, including the "unavailable" and "exhausted" fallbacks and `emit_event`
- [ ] T4: Add `errsig_reset` and the `ERRSIG_RESTARTED_HASHES` anti-thrash guard
- [ ] T5: In `sw-loop.sh`, source the lib and read `ERROR_DEDUP_ENABLED` / `ERROR_DEDUP_THRESHOLD`, with validation
- [ ] T6: In `sw-loop.sh`, call `errsig_update` after `write_error_summary`, add the `error_repeat_restart` break, and reset in both restart blocks
- [ ] T7: Inject the `ERRSIG_HINT` section and use 200 lines of test output in `compose_prompt` when escalated
- [ ] T8: Rotate `LOOP_SESSION_ID` on escalation when session continuity is enabled
- [ ] T9: Add the `config/defaults.json` keys and register `loop.error_signature_repeat` in `event-schema.json`
- [ ] T10: Write the unit tests in `sw-loop-test.sh` (signature extraction, repeat detection, escalation, gating)
- [ ] T11: Write the wiring tests (call order, prompt section, restart status handled)
- [ ] T12: Update the `.claude/CLAUDE.md` docs
- [ ] T13: Run `./scripts/sw-loop-test.sh`, `npm test`, `shellcheck` and `sw-event-schema-sync.sh`
- [ ] Normalized `file:line:message` signatures are hashed per failing iteration and compared with the previous iteration in the same run. Evidence: `error-signatures.txt` and the new `error-summary.json` fields.
- [ ] Two consecutive identical-signature failures emit `loop.error_signature_repeat` and change the next prompt (hint plus wider context). A third triggers `error_repeat_restart` when restarts are available.
- [ ] `sw-loop-test.sh` covers signature extraction, repeat detection and the escalation trigger, and passes.
- [ ] `loop.error_dedup_enabled` (default true) and `loop.error_dedup_threshold` (default 2) work. When disabled, the loop is behaviourally unchanged (U14).
- [ ] The code is Bash 3.2 compatible, safe under `set -euo pipefail`, uses `jq --arg` and tmp+`mv` writes, and `shellcheck` is clean.
- [ ] `npm test` is green and the event schema is in sync.

## Context
- Pipeline: standard
- Branch: fix/deduplicate-identical-build-loop-errors-8438
- Issue: #8438
- Generated: 2026-10-11T02:52:07Z
