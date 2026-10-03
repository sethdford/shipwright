# Pipeline Tasks — Add missing test suites for the 5 untested scripts

## Implementation Checklist
- [ ] Write the event-schema-sync suite with a fixture repo (9 tests)
- [ ] Write the test-all suite with an isolated runner copy and fake suites (10 tests)
- [ ] Write the tmux-role-color suite with a `tmux` mock and colour table (12 tests)
- [ ] Write the tmux-status suite covering the widgets, heartbeats and walk-up search (12 tests)
- [ ] Write the tracker-github suite with a recording `gh` mock (16 tests)
- [ ] Resolve decision 1 (status widget parsing)
- [ ] Resolve decision 2 (tracker `NO_GITHUB` guard)
- [ ] Add the suites to `package.json` `test:legacy-chain`
- [ ] Run `shipwright docs sync`
- [ ] Run each new suite alone, twice, to check it gives the same result every time
- [ ] Run `bash scripts/sw-test-all.sh --pattern -test` and check the new suites run without timeouts
- [ ] Run the full `npm test`
- [ ] All 5 `*-test.sh` files exist, can be executed, and each covers its main paths plus at least one failure or edge case.
- [ ] Each suite exits 0 when run alone and when run through `npm test`.
- [ ] The suites appear in `package.json` and in the CLAUDE.md test-suites table.
- [ ] Scripts-with-tests reaches 105/105.
- [ ] Tests never touch the real `config/event-schema.json`, `~/.shipwright`, `tmux` or GitHub.
- [ ] Tests never start the real test runner from inside itself.

## Context
- Pipeline: standard
- Branch: test/add-missing-test-suites-for-the-5-untest-7552
- Issue: #7552
- Generated: 2026-10-03T12:18:22Z
