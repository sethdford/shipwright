# Tasks — Add missing test suites for sw-event-schema-sync.sh, sw-test-all.sh, sw-tmux-role-color.sh, sw-tmux-status.sh, sw-tracker-github.sh

## Status: In Progress
Pipeline: standard | Branch: test/add-missing-test-suites-for-sw-event-sch-7980

## Checklist
- [ ] Task 1: Read `scripts/lib/test-helpers.sh` and confirm the helper names and summary behaviour.
- [ ] Task 2: Confirm the runner's flags (`--list`, `--jobs`, pattern, timeout) and the tmux-status subcommands.
- [ ] Task 3: Write `scripts/sw-event-schema-sync-test.sh` on a temp copy of the schema (7 cases).
- [ ] Task 4: Write `scripts/sw-test-all-test.sh` on stub suites in a temp dir, never the real runner (7 cases).
- [ ] Task 5: Write `scripts/sw-tmux-role-color-test.sh` with a mocked `tmux` that logs calls (role, case, and fallback cases).
- [ ] Task 6: Write `scripts/sw-tmux-status-test.sh` with fixture state and heartbeats (stage mapping, empty, stale, malformed).
- [ ] Task 7: Write `scripts/sw-tracker-github-test.sh` by sourcing the provider with a mock `gh` (argv, errors, NO_GITHUB guard).
- [ ] Task 8: Check the NO_GITHUB guard in the provider; record a finding or a known-failing assertion if it is missing.
- [ ] Task 9: Run each new suite alone and confirm PASS/FAIL counts.
- [ ] Task 10: Run `npm test` and confirm all new suites appear and pass, with no previously passing suite regressing.
- [ ] Task 11: Check for real side effects (checksums of schema, events log, git status) before and after.
- [ ] Task 12: Decide on the `package.json` legacy-chain entry and state the decision.
- [ ] Task 13: Run `bash -n`, `shellcheck` if present, and the Bash 3.2 grep.
- [ ] Task 14: Measure and report the scripts-with-tests count as found, not as assumed.
- [ ] Five new files exist in `scripts/`: `sw-event-schema-sync-test.sh`, `sw-test-all-test.sh`, `sw-tmux-role-color-test.sh`, `sw-tmux-status-test.sh`, `sw-tracker-github-test.sh`.
- [ ] Each suite passes when run alone and reports PASS/FAIL counts.
- [ ] Each suite uses mock binaries or temp copies, with no real Claude, GitHub, or tmux calls.
- [ ] `npm test` discovers and passes all five, with no regression in other suites.
- [ ] No real repo file changed as a side effect of running the tests.
- [ ] Bash 3.2 grep is clean and `bash -n` passes on each file.

## Notes
- Generated from pipeline plan at 2026-10-09T16:48:18Z
- Pipeline will update status as tasks complete
