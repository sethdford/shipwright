# Tasks — Add pipeline dry-run summary with stage timing estimates

## Status: In Progress
Pipeline: standard | Branch: ci/add-pipeline-dry-run-summary-with-stage-5

## Checklist
- [ ] Task 1: Fix `~/.claude-teams/` → `~/.shipwright/` in `setup_env()` backup logic
- [ ] Task 2: Fix `~/.claude-teams/` → `~/.shipwright/` in `cleanup_env()` restore logic
- [ ] Task 3: Fix `~/.claude-teams/` → `~/.shipwright/` in `test_dry_run_summary_with_history()` event seeding
- [ ] Task 4: Fix `~/.claude-teams/` → `~/.shipwright/` in `test_dry_run_summary_no_history()` cleanup
- [ ] Task 5: Fix `cct-cost.sh` → `sw-cost.sh` in `dry_run_summary()` budget check
- [ ] Task 6: Run dry-run tests to verify fixes
- [ ] Task 7: Run full pipeline test suite (no regressions)
- [ ] Task 8: Run full `npm test` (all suites pass)

## Notes
- Generated from pipeline plan at 2026-02-10T02:21:08Z
- Pipeline will update status as tasks complete
