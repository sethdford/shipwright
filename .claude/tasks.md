# Tasks — Add pre-build dependency/tooling check to pipeline intake stage

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-7767

## Checklist
- [ ] **Task 6**: Implement `check_required_tools()` — check optional tools from config (git, jq, etc.)
- [ ] **Task 7**: Implement `prebuild_check()` orchestrator — call all checks, save results atomically, emit events
- [ ] **Task 8**: Create `scripts/sw-prebuild-check-test.sh` — ≥15 test cases covering all scenarios
- [ ] **Task 9**: Modify `scripts/lib/pipeline-stages-intake.sh` — call prebuild_check() early, handle results
- [ ] **Task 10**: Create `.claude/prebuild-config.json` — sensible defaults, documentation
- [ ] **Task 11**: Update `.claude/CLAUDE.md` — add to AUTO sections (core-scripts, test-suites)
- [ ] **Task 12**: Update `package.json` — add test to npm test script
- [ ] **Task 13**: Create documentation — `docs/prebuild-checks.md` with examples and recovery steps
- [ ] **Task 14**: End-to-end validation — run full pipeline, verify intake completes successfully
- [ ] Module exists at `scripts/sw-prebuild-check.sh` with all 6 check functions
- [ ] Test suite exists at `scripts/sw-prebuild-check-test.sh` with ≥15 test cases
- [ ] **All tests pass**: `bash scripts/sw-prebuild-check-test.sh` → 0 failures
- [ ] Integrated into intake stage: `pipeline-stages-intake.sh` calls `prebuild_check()`
- [ ] Configuration template exists: `.claude/prebuild-config.json`
- [ ] Backward compatible: existing pipelines run without changes
- [ ] Error messages clear and actionable
- [ ] Events emitted: `prebuild_check.completed`, `prebuild_check.failed`
- [ ] Offline support: works with `--local` flag, skips network checks when `$NO_GITHUB=true`
- [ ] Results in artifacts: `.claude/pipeline-artifacts/prebuild-check.json`
- [ ] GitHub integration: intake comment includes prebuild status

## Notes
- Generated from pipeline plan at 2026-10-05T10:15:46Z
- Pipeline will update status as tasks complete
