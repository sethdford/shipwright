# Tasks — Add build-loop pre-flight checks for missing test/lint commands before burning iterations

## Status: In Progress
Pipeline: standard | Branch: feat/add-build-loop-pre-flight-checks-for-mis-6987

## Checklist
- [ ] T1: Create `lib/loop-preflight.sh` with the syntax and executable checks (blocks T2, T4, T6)
- [ ] T2: Add runner-specific checks for npm/yarn/pnpm, make and npx (depends on T1)
- [ ] T3: Write `preflight.json` atomically and emit `loop.preflight_failed` (depends on T1)
- [ ] T4: Load the new file in `sw-loop.sh`, add the `--no-preflight` flag and help text (depends on T1)
- [ ] T5: Call the check first in `main()`, before the single- and multi-agent branches (depends on T4)
- [ ] T6: Unit tests in `sw-loop-test.sh` that load the new file directly (depends on T1–T3)
- [ ] T7: End-to-end test: a broken command exits nonzero, the output names the command, and the mock claude is never called (depends on T5)
- [ ] T8: End-to-end test: with a working command the loop behaves exactly as before (depends on T5)
- [ ] T9: Add the `preflight_failed` branch in `pipeline-stages-build.sh` (depends on T3)
- [ ] T10: Update CLAUDE.md and confirm `package.json`/release packaging picks up the new file
- [ ] T11: Run `sw-loop-test.sh`, `sw-lib-pipeline-stages-test.sh`, `sw-pipeline-test.sh`, then `npm test`

## Notes
- Generated from pipeline plan at 2026-09-28T07:21:07Z
- Pipeline will update status as tasks complete
