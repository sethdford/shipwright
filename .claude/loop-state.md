---
goal: "Split sw-db.sh into schema/connection, query, and migration modules

## Plan Summary
# Plan: split `scripts/sw-db.sh` into schema/connection, query, and migration modules

## Current state

`scripts/sw-db.sh` is 1,939 lines and does five jobs: it holds configuration and connection primitives, defines the DDL, runs migrations, provides about 60 query functions, and serves as the `shipwright db` CLI. It reaches the rest of the system in three ways:

- **15 callers source it as a library:** `sw-daemon`, `sw-pipeline`, `sw-loop`, `sw-cost`, `sw-memory`, `sw-heartbeat`, `sw-eventbus`, `sw-durable`, `sw-incident`, `sw-intelligence`, `sw-adaptive`, `sw-self-optimize`, `sw-retro`, `sw-replay` and `lib/daemon-state.sh`. Most use `[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source …`. `sw-cost` and `sw-loop` add `|| true`.
- **`lib/helpers.sh`'s `emit_event` calls `db_add_event`** when that function is defined.
- **`scripts/sw` runs it directly** for `shipwright db …`.
- **`sw-db-test.sh` (31 tests) copies only `sw-db.sh`** into a temp directory, then re-sources it after clearing `_SW_DB_LOADED`.

Cross-section dependencies I checked:

- The query section never calls `init_schema`, `migrate_schema` or `migrate_json_data`.
- `migrate_json_data` only uses the primitives (`_db_exec`, `ensure_db_dir`, `check_sqlite3`) plus `migrate_schema`.
- Sync push/pull only use `db_available`, `_db_exec`, `_db_query` and `curl`.

So the dependency graph has no cycles. Both the query and migration modules depend only on the schema module.

## Module boundaries (line ranges are in today's `sw-db.sh`)
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Split sw-db.sh into schema/connection, query, and migration modules
## Context
## Decision
### Component diagram
### Module contents (L = line ranges in today's file)
### Amendments to the plan
### Module rules
### Interface contracts (TS-style notation for bash functions; the exit status is the error channel)
### Data flow
### Error boundaries
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Split sw-db.sh into schema/connection, query, and migration modules

### Goals
- Split sw-db.sh into schema/connection, query, and migration modules

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{"results":[{"file":"architecture.json","relevance":35,"summary":"Only placeholder rules (rule1-3); weakly relevant as a possible architecture reference for splitting sw-db.sh into modules, but contains no real content."},{"file":"failures.json","relevance":30,"summary":"Recorded failures in the test stage involving timeouts and database connection refused; the 'database connection refused' entry touches the db layer that sw-db.sh handles."},{"file":"index.json","relevance":25,"summary":"Build-stage failure pattern with a fix recipe; general, not specific to refactoring a shell script into modules."},{"file":"success-patterns.json","relevance":20,"summary":"Build-stage success patterns for sw-daemon.sh timeout fixes; shows the repo's shell-script build pattern but for an unrelated change."},{"file":"fleet-shared-patterns.json","relevance":15,"summary":"Cross-repo 'Cannot find module' build pattern; only loosely connected to a shell-module split."}]}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Split sw-db.sh into schema/connection, query, and migration modules — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Split sw-db.sh into schema/connection, query, and migration modules

## Implementation Checklist
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

## Context
- Pipeline: autonomous
- Branch: ci/issue-8228
- Issue: none
- Generated: 2026-10-10T19:09:39Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-10-10T19:13:51Z
last_iteration_at: 2026-10-10T19:13:51Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

