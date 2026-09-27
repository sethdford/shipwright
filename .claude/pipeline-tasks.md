# Pipeline Tasks — Budget-aware pipeline template selection

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/budget-template.sh` with the tier ladder, budget reader and selector
- [ ] Task 2: Add `PIPELINE_NAME_EXPLICIT` (init in `sw-pipeline.sh`, set in `pipeline-cli.sh`)
- [ ] Task 3: Replace the `== "standard"` check in `pipeline_start` and call `budget_select_template`
- [ ] Task 4: Apply the budget selection in `daemon_spawn_pipeline` using a local variable
- [ ] Task 5: Source the new lib in the pipeline and daemon entry points
- [ ] Task 6: Register `pipeline.template_budget_downgrade` via `sw-event-schema-sync.sh --write`
- [ ] Task 7: Write `scripts/sw-budget-template-test.sh` (unit plus parse-args cases)
- [ ] Task 8: Add the low-budget case to `sw-lib-daemon-dispatch-test.sh`
- [ ] Task 9: Add the suite to `package.json` `test:legacy-chain`
- [ ] Task 10: Document the config keys and override in `.claude/CLAUDE.md` and the `--help` text
- [ ] Task 11: Run `bash -n`, shellcheck, the targeted suites, then the full `npm test`
- [ ] `pipeline start` without `--template` calls `budget_select_template` before `load_pipeline_config` (criterion 1)
- [ ] Remaining budget below `budget.template_downgrade_threshold_usd` downgrades exactly one tier, emits `pipeline.template_budget_downgrade`, and logs a warning that names the override (criterion 2)
- [ ] `--template X` / `--pipeline X` is never downgraded, including `--template standard` (criterion 3)
- [ ] The daemon applies the same selection at spawn and doesn't change the global `PIPELINE_TEMPLATE`
- [ ] The new suite covers the low-budget, explicit-override and normal no-op paths plus the edge cases, and passes (criterion 4)
- [ ] `sw-event-schema-sync.sh` reports no drift, so there's no "Unknown event type" warning
- [ ] The full `npm test` is green on Linux. No bash 4+ constructs (`bash -n` passes, and `grep` finds no `declare -A`, `readarray`, `${x,,}` or `${x^^}`)
- [ ] Docs updated (CLAUDE.md config table, `--help`)

## Context
- Pipeline: standard
- Branch: feat/budget-aware-pipeline-template-selection-6924
- Issue: #6924
- Generated: 2026-09-27T20:29:45Z
