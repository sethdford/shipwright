# Tasks — Classify and surface flatlining build-loop iterations distinct from context exhaustion

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-7689

## Checklist
- [ ] 1. Create `lib/loop-flatline.sh` with the classifier, exit-class resolver and atomic artifact writer
- [x] 2. Source and call it from `sw-loop.sh` per iteration; emit `loop.iteration_classified` and `loop.flatline` *(depends on 1)*
- [x] 3. Add `Exit class` and `Flatline streak` to `progress.md` and `show_summary` *(depends on 1)*
- [x] 4. Tag `stuck_restart` and flatline restarts with a reason and inject the flatline strategy *(depends on 2, 6)*
- [x] 5. Fix the unreachable `iteration_limit` branch and add flatline in `restart_detect_reason`
- [x] 6. Add the `flatline` strategy in `restart_suggest_strategy`
- [x] 7. Pipeline build stage: write `flatline` vs `context_exhaustion` to `failure-reason.txt` *(depends on 3)*
- [x] 8. Daemon `classify_failure`, retry limits and escalation for `flatline` without the restart boost *(depends on 3, 7)*
- [x] 9. Add the `flatline` category in `root-cause.sh`
- [x] 10. Event schema entries plus sync
- [ ] 11. New `sw-loop-flatline-test.sh`, registered in `package.json`
- [x] 12. Extend the daemon-failure, session-restart and loop tests
- [x] 13. Update the CLAUDE.md docs

## Notes
- Generated from pipeline plan at 2026-10-04T14:54:08Z
- Pipeline will update status as tasks complete
