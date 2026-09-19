# Tasks — Auto-file hygiene issue when a script exceeds 2000 lines

## Status: In Progress
Pipeline: standard | Branch: feat/auto-file-hygiene-issue-when-a-script-ex-5791

## Checklist
- [ ] Task 1: Add `MAX_SCRIPT_LINES` via `_config_get_int` with numeric-validation guard
- [ ] Task 2: Add `--max-script-lines` to `main()` option parsing
- [ ] Task 3: Add `_emit_script_sizes()` helper (process substitution, digit-stripped counts)
- [ ] Task 4: Add `check_script_sizes()` returning threshold-filtered, descending-sorted JSON
- [ ] Task 5: Add `report_script_sizes()` human/JSON printer, always exit 0, `emit_event`
- [ ] Task 6: Refactor `scan_platform_refactor` sizes block to use `_emit_script_sizes` (no behavior change to `script_size_hotspots`)
- [ ] Task 7: Add `oversized_scripts`, `counts.oversized_scripts`, `thresholds.max_script_lines` to the report JSON
- [ ] Task 8: Register `script-size` subcommand + add to `run_full_scan`
- [ ] Task 9: Update `show_help`; bump `VERSION` to 3.4.0
- [ ] Task 10: Add `hygiene.max_script_lines: 1500` to `config/policy.json`
- [ ] Task 11: Surface oversized count/list in `sw-strategic.sh` platform-health section
- [ ] Task 12: Surface oversized count in `sw-doctor.sh` PLATFORM HEALTH
- [ ] Task 13: Tests 13–17 in `sw-hygiene-test.sh`
- [ ] Task 14: Document in `.claude/CLAUDE.md` (config table + subcommand)
- [ ] Task 15: Run `shellcheck`, `./scripts/sw-hygiene-test.sh`, `./scripts/sw-doctor-test.sh`, `./scripts/sw-strategic-test.sh`
- [ ] `shipwright hygiene script-size` lists scripts over the threshold with line
- [ ] Threshold honored from `.claude/daemon-config.json` `hygiene.max_script_lines`,
- [ ] `.claude/platform-hygiene.json` contains `oversized_scripts` (array),
- [ ] `scripts/sw-hygiene-test.sh` covers threshold filtering, sort order, config
- [ ] `shipwright hygiene scan` runs the new check and still completes

## Notes
- Generated from pipeline plan at 2026-09-19T16:13:55Z
- Pipeline will update status as tasks complete
