# Pipeline Tasks — Add pipeline dry-run summary with stage timing estimates

## Implementation Checklist

- [x] Task 1: Fix `~/.claude-teams/` → `~/.shipwright/` in `setup_env()` backup logic
- [x] Task 2: Fix `~/.claude-teams/` → `~/.shipwright/` in `cleanup_env()` restore logic
- [x] Task 3: Fix `~/.claude-teams/` → `~/.shipwright/` in `test_dry_run_summary_with_history()` event seeding
- [x] Task 4: Fix `~/.claude-teams/` → `~/.shipwright/` in `test_dry_run_summary_no_history()` cleanup
- [x] Task 5: Fix `cct-cost.sh` → `sw-cost.sh` in `dry_run_summary()` budget check
- [x] Task 6: Run dry-run tests to verify fixes
- [x] Task 7: Run full pipeline test suite (no regressions)
- [x] Task 8: Run full `npm test` (all suites pass)

## Context

- Pipeline: standard
- Branch: ci/add-pipeline-dry-run-summary-with-stage-5
- Issue: #5
- Generated: 2026-02-10T02:21:06Z
