# Tasks — Split sw-db.sh into schema/connection, query, and migration modules

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-8228

## Checklist
- [ ] Task 1: Record baseline test pass counts and the `declare -f` digest of every sw-db function
- [ ] Task 2: Create `scripts/lib/db-schema.sh` (config, connection helpers, `init_schema`) with a load guard
- [ ] Task 3: Create `scripts/lib/db-migrate.sh` (`migrate_schema`, `migrate_json_data`) with a schema dependency guard
- [ ] Task 4: Create `scripts/lib/db-query.sh` (all `db_*` query functions, `add_event`, pipeline-run functions)
- [ ] Task 5: Replace the moved code in `sw-db.sh` with the module loader and its graceful-degradation branch
- [ ] Task 6: Confirm the function set and bodies are identical before and after (parity script)
- [ ] Task 7: Make `sw-db-test.sh` copy `lib/db-*.sh` into its temp dir
- [ ] Task 8: Add tests for direct module sourcing, the missing-module degradation, re-source reload and the CLI smoke run
- [ ] Task 9: Run `bash -n`, shellcheck and the Bash 3.2 grep on the new files
- [ ] Task 10: Run downstream suites (daemon-state, heartbeat, cost, eventbus, memory, pipeline, loop, e2e-smoke) and `npm test`
- [ ] Task 11: Update `.claude/CLAUDE.md` and run `shipwright docs sync` / `version check`
- [ ] `scripts/lib/db-schema.sh`, `db-migrate.sh` and `db-query.sh` exist, and each has a load guard and a header comment stating its dependencies
- [ ] `sw-db.sh` contains no `CREATE TABLE`, no `migrate_*` definitions and no `db_*` query definitions, and is ≤ ~550 lines
- [ ] The set of functions defined after `source scripts/sw-db.sh` is identical to the baseline, with byte-identical bodies
- [ ] No caller file changed. `shipwright db init|status|health|migrate|sync|export|import|cleanup` behave as before.
- [ ] `sw-db-test.sh` passes with all 31 existing tests plus T1–T4
- [ ] The downstream suites and `npm test` show no new failures against baseline
- [ ] The new files pass `bash -n`, shellcheck and the Bash 3.2 checks
- [ ] `shipwright version check` passes, and `.claude/CLAUDE.md` lists the new modules

## Notes
- Generated from pipeline plan at 2026-10-10T19:09:41Z
- Pipeline will update status as tasks complete
