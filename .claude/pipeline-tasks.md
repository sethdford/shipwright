# Pipeline Tasks — Auto-file hygiene issue when a script exceeds 2000 lines

## Implementation Checklist
- [x] Task 1: Create `scripts/lib/hygiene-size.sh` with `_emit_script_sizes`, `check_script_sizes`, `hygiene_oversized_scripts` + load guard
- [x] Task 2: Source the lib from `sw-hygiene.sh`, delete moved bodies, update 3 call sites, bump VERSION to 3.5.0
- [x] Task 3: Add `PATROL_OVERSIZED_ENABLED` / `PATROL_OVERSIZED_THRESHOLD` defaults and lib sourcing to `daemon-patrol.sh`
- [x] Task 4: Implement `patrol_oversized_scripts()` with dedup, NO_GITHUB/dry-run guards, and decision-engine branch
- [x] Task 5: Register the check in the `daemon_patrol()` dispatch block with findings-summary bookkeeping
- [x] Task 6: Add `hygiene.oversized_issue_threshold: 2000` to `config/policy.json`
- [x] Task 7: Load `patrol.checks.oversized_scripts.*` in `sw-daemon.sh` with integer validation
- [x] Task 8: Regression-test `hygiene script-size` behavior is byte-identical after extraction
- [x] Task 9: Unit tests — detects >threshold, ignores <=threshold, honors dry-run and NO_GITHUB, respects disabled flag
- [x] Task 10: Dedup test — second patrol run with an open issue creates zero new issues
- [x] Task 11: Decision-engine test — signal written to `pending.jsonl`, no issue created
- [x] Task 12: Document the patrol check and config keys in `.claude/CLAUDE.md`
- [x] Task 13: `bash -n` + shellcheck all changed scripts
- [x] Task 14: Run `sw-hygiene-test.sh`, `sw-lib-daemon-patrol-test.sh`, then full `npm test`
- [x] `scripts/lib/hygiene-size.sh` exists with a load guard and is sourced by both `sw-hygiene.sh` and `daemon-patrol.sh`
- [x] `shipwright hygiene script-size` output is byte-identical to pre-change for the same input
- [x] `patrol_oversized_scripts()` flags scripts with `lines > 2000` and ignores those at or below
- [x] Exactly one aggregate GitHub issue is filed per detection cycle, labeled `<PATROL_LABEL>,hygiene`
- [x] A second patrol run with the issue open files **zero** new issues
- [x] `NO_GITHUB=true`, `--dry-run`, and `enabled: false` each suppress issue creation

## Context
- Pipeline: autonomous
- Branch: ci/issue-5791
- Issue: none
- Generated: 2026-09-19T17:38:10Z
