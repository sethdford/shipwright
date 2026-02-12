# Pipeline Tasks — Add --json output flag to shipwright status command

## Implementation Checklist
- [ ] Task 1: Add argument parsing for `--json` and `--help` flags to `sw-status.sh`
- [ ] Task 2: Refactor tmux windows section into `collect_tmux_windows` + `render_tmux_windows`
- [ ] Task 3: Refactor team configs section into `collect_team_configs` + `render_team_configs`
- [ ] Task 4: Refactor task lists section into `collect_task_lists` + `render_task_lists`
- [ ] Task 5: Refactor daemon pipelines section into `collect_daemon` + `render_daemon`
- [ ] Task 6: Refactor issue tracker section into `collect_tracker` + `render_tracker`
- [ ] Task 7: Refactor heartbeats section into `collect_heartbeats` + `render_heartbeats`
- [ ] Task 8: Refactor remote machines section into `collect_machines` + `render_machines`
- [ ] Task 9: Refactor connected developers section into `collect_developers` + `render_developers`
- [ ] Task 10: Add JSON assembly and output when `--json` flag is set
- [ ] Task 11: Update CLI help text in `scripts/sw` for the `status` subcommand
- [ ] Task 12: Create `sw-status-test.sh` test suite with mock environment
- [ ] Task 13: Register `sw-status-test.sh` in `package.json` test script
- [ ] Task 14: Run test suite and verify all tests pass

## Context
- Pipeline: autonomous
- Branch: feat/add-json-output-flag-to-shipwright-statu-4
- Issue: #4
- Generated: 2026-02-12T17:41:32Z
