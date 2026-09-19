# Tasks — Auto-file hygiene issue when a script exceeds 2000 lines

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-5791

## Checklist
- [ ] Task 1: Create `scripts/lib/hygiene-size.sh` with `_emit_script_sizes`, `check_script_sizes`, `hygiene_oversized_scripts` + load guard
- [ ] Task 2: Source the lib from `sw-hygiene.sh`, delete moved bodies, update 3 call sites, bump VERSION to 3.5.0
- [ ] Task 3: Add `PATROL_OVERSIZED_ENABLED` / `PATROL_OVERSIZED_THRESHOLD` defaults and lib sourcing to `daemon-patrol.sh`
- [ ] Task 4: Implement `patrol_oversized_scripts()` with dedup, NO_GITHUB/dry-run guards, and decision-engine branch
- [ ] Task 5: Register the check in the `daemon_patrol()` dispatch block with findings-summary bookkeeping
- [ ] Task 6: Add `hygiene.oversized_issue_threshold: 2000` to `config/policy.json`
- [ ] Task 7: Load `patrol.checks.oversized_scripts.*` in `sw-daemon.sh` with integer validation
- [ ] Task 8: Regression-test `hygiene script-size` behavior is byte-identical after extraction
- [ ] Task 9: Unit tests — detects >threshold, ignores <=threshold, honors dry-run and NO_GITHUB, respects disabled flag
- [ ] Task 10: Dedup test — second patrol run with an open issue creates zero new issues
- [ ] Task 11: Decision-engine test — signal written to `pending.jsonl`, no issue created
- [ ] Task 12: Document the patrol check and config keys in `.claude/CLAUDE.md`
- [ ] Task 13: `bash -n` + shellcheck all changed scripts
- [ ] Task 14: Run `sw-hygiene-test.sh`, `sw-lib-daemon-patrol-test.sh`, then full `npm test`
- [ ] `scripts/lib/hygiene-size.sh` exists with a load guard and is sourced by both `sw-hygiene.sh` and `daemon-patrol.sh`
- [ ] `shipwright hygiene script-size` output is byte-identical to pre-change for the same input
- [ ] `patrol_oversized_scripts()` flags scripts with `lines > 2000` and ignores those at or below
- [ ] Exactly one aggregate GitHub issue is filed per detection cycle, labeled `<PATROL_LABEL>,hygiene`
- [ ] A second patrol run with the issue open files **zero** new issues
- [ ] `NO_GITHUB=true`, `--dry-run`, and `enabled: false` each suppress issue creation

## Notes
- Generated from pipeline plan at 2026-09-19T17:38:11Z
- Pipeline will update status as tasks complete
