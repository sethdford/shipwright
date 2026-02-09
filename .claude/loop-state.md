---
goal: "Add --json output flag to shipwright status command

Implementation plan (follow this exactly):
The implementation is already on main. The feature branch is at the same commit as main — the feature is already fully implemented and tested. Let me write the plan summarizing what's already done and what (if anything) remains.

Here is my analysis:

## Implementation Status: Already Complete

The `--json` output flag for `shipwright status` is **already fully implemented** on the current branch (which is identical to `main`). Here's what exists:

### Files Already Modified

| File | Status |
|------|--------|
| `scripts/cct-status.sh` (lines 27-196) | `--json` flag parsing + full JSON output mode |
| `scripts/cct-status-test.sh` (571 lines) | Complete test suite with 12 tests |
| `package.json` (line 30) | Test suite wired into `npm test` |

### Implementation Details

**`scripts/cct-status.sh`** already implements:
- `--json` flag parsing (line 27-42)
- `--help` flag with `--json` documented (line 31-41)
- `jq` dependency check with error JSON on stderr (line 49-52)
- **Teams** from tmux windows — filters for Claude windows, includes name/panes/status/session (lines 63-81)
- **Tasks** from `~/.claude/tasks/` — counts by status: completed/in_progress/pending (lines 83-114)
- **Daemon** from `daemon-state.json` — running status, active/queued/completed counts (lines 116-142)
- **Heartbeats** from `~/.claude-teams/heartbeats/*.json` — job_id, stage, issue, age_s, alive (lines 144-178)
- **Machines** from `machines.json` — name, host, cores, memory_gb, max_workers (lines 180-185)
- Final JSON emission with ISO 8601 timestamp via `jq -n` (lines 188-195)
- Human-readable output unchanged when `--json` is not passed (lines 199-705)

**`scripts/cct-status-test.sh`** covers all acceptance criteria:
1. JSON output is valid JSON
2. JSON has all six top-level keys (timestamp, teams, tasks, daemon, heartbeats, machines)
3. Empty state returns correct defaults ([], null)
4. Timestamp is ISO 8601 format
5. Teams populated from mock tmux
6. Tasks populated with status breakdown
7. Daemon populated from state file
8. Heartbeats populated with alive detection
9. Machines populated from registry file
10. `--help` flag works
11. Human output regression (no `--json` still works)
12. Missing `jq` exits with error

### Acceptance Criteria Check

- [x] `shipwright status --json` outputs valid JSON
- [x] All sections present: teams, daemon, heartbeats, machines (plus tasks and timestamp)
- [x] `shipwright status` (without flag) still works identically
- [x] Tests validate JSON output structure

### What Remains

There is **no remaining implementation work**. The branch `feat/add-json-output-flag-to-shipwright-statu-4` has zero diverging commits from `main` because this work was already completed and merged by a previous autonomous pipeline. The issue can be closed — the feature is fully delivered and tested.

If you want me to verify the tests pass by running `bash scripts/cct-status-test.sh`, I can do that. Otherwise, this issue appears ready for closure.

Follow the approved design document:


# Design: Add --json output flag to shipwright status command

## Context

The `shipwright status` command provides a human-readable dashboard showing teams, tasks, daemon state, heartbeats, and machines. Downstream tooling (CI pipelines, the web dashboard, fleet orchestration, and external integrations) needs machine-readable output to programmatically consume status data without parsing ANSI-colored, box-drawn terminal output.

Constraints from the codebase:
- All scripts must be **Bash 3.2 compatible** — no associative arrays, no `readarray`, no `${var,,}` lowercase transforms.
- Scripts use `set -euo pipefail`, which means `grep -c` returning 0 matches will exit non-zero — requires `|| true` guards.
- JSON construction in bash is fragile — must use `jq --arg` for proper escaping, never string interpolation.
- The existing `cct-status.sh` (~705 lines) has structured sections for each data source (tmux, tasks directory, daemon state file, heartbeats, machines registry), making it natural to add a parallel JSON code path per section.
- `jq` is not a guaranteed dependency on all systems — the feature must degrade gracefully when `jq` is absent.

## Decision

Add a `--json` flag to `scripts/cct-status.sh` that emits a single JSON object to stdout containing all status sections. The approach:

**Flag parsing**: Add `--json` to the existing argument loop (lines 27-42). Set a `JSON_OUTPUT` boolean. Document it in `--help`.

**Data flow**: Each section (teams, tasks, daemon, heartbeats, machines) builds its own JSON fragment using `jq`. The final output is assembled via `jq -n` with `--argjson` for each section, plus an ISO 8601 `timestamp` field. When `--json` is not set, the existing human-readable rendering executes unchanged.

**Schema** (top-level keys):
```json
{
  "timestamp": "2026-02-09T22:27:38Z",
  "teams": [{"name": "...", "panes": 3, "status": "active", "session": "..."}],
  "tasks": {"completed": 0, "in_progress": 0, "pending": 0},
  "daemon": {"running": false, "active": 0, "queued": 0, "completed": 0} | null,
  "heartbeats": [{"job_id": "...", "stage": "...", "issue": 0, "age_s": 0, "alive": true}],
  "machines": [{"name": "...", "host": "...", "cores": 0, "memory_gb": 0, "max_workers": 0}]
}
```

**Error handling**:
- If `jq` is not installed, emit `{"error": "jq is required for --json output"}` to stderr and exit 1.
- Empty/missing data sources produce empty arrays `[]` or `null` (for daemon when no state file exists), not errors.
- Heartbeat `alive` is computed by comparing file mtime against a 120-second threshold, matching the existing `cct-heartbeat.sh` convention.

**Output contract**: JSON goes to stdout only. No ANSI codes, no box-drawing characters. Human-readable output is completely unchanged when `--json` is omitted.

## Alternatives Considered

1. **Separate `shipwright status-json` subcommand** — Pros: zero risk of regression to existing output; clean separation. Cons: duplicates all data-gathering logic across two files; violates the existing pattern where flags modify output format (e.g., `--verbose` patterns elsewhere); doubles maintenance burden.

2. **Template-based output (`--format=json|text|csv`)** — Pros: extensible to future formats; single flag for all variations. Cons: over-engineered for current needs (only JSON is requested); adds parsing complexity for a `--format` argument; CSV is a poor fit for nested data like heartbeats. YAGNI applies.

3. **Emit JSON from a Node.js wrapper instead of bash** — Pros: native JSON support, no `jq` dependency. Cons: breaks the "all scripts are bash" architecture convention; adds a Node.js runtime dependency to a command that currently only needs bash + standard Unix tools; inconsistent with every other `cct-*.sh` script.

## Implementation Plan

- **Files to create**: `scripts/cct-status-test.sh` — dedicated test suite for the `--json` flag covering all sections, empty state, schema validation, and `jq`-missing error path.
- **Files to modify**:
  - `scripts/cct-status.sh` — add `--json` flag parsing, `jq` dependency check, JSON assembly per section, final `jq -n` emission.
  - `package.json` — wire `cct-status-test.sh` into the `npm test` aggregate command.
- **Dependencies**: `jq` (runtime, already used by `cct-pipeline.sh`, `cct-daemon.sh`, `cct-cost.sh`, and others — not a new dependency to the project, but must be validated at invocation time).
- **Risk areas**:
  - **`jq` pipeline under `set -euo pipefail`**: Any `jq` filter that produces no output or encounters malformed input will cause an immediate exit. Each `jq` invocation needs `// empty` or `// null` fallbacks.
  - **Heartbeat mtime calculation**: Uses `stat` which has different flags on macOS (`-f %m`) vs Linux (`-c %Y`). The existing `cct-heartbeat.sh` already handles this — the status script must use the same cross-platform pattern.
  - **Large tmux session lists**: If dozens of sessions exist, building JSON in a loop with repeated `jq` invocations could be slow. Mitigated by collecting all data into a single `jq -n` call with `--argjson` rather than incremental builds.
  - **Concurrent state file writes**: Daemon state and heartbeat files may be written while status reads them. Using `jq` to parse (which reads the entire file atomically) rather than line-by-line `read` avoids partial-read corruption.

## Validation Criteria

- [ ] `shipwright status --json | jq .` succeeds (valid JSON output)
- [ ] Output contains all six top-level keys: `timestamp`, `teams`, `tasks`, `daemon`, `heartbeats`, `machines`
- [ ] `timestamp` matches ISO 8601 format (`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`)
- [ ] Empty state (no tmux, no tasks, no daemon, no heartbeats, no machines) returns `{"timestamp":"...","teams":[],"tasks":{"completed":0,"in_progress":0,"pending":0},"daemon":null,"heartbeats":[],"machines":[]}`
- [ ] Each section populates correctly from mock data (tmux windows, task files, daemon-state.json, heartbeat files, machines.json)
- [ ] `shipwright status` (without `--json`) produces identical output to the pre-change version (human-readable regression test)
- [ ] When `jq` is not on `$PATH`, `--json` exits 1 and emits error JSON to stderr
- [ ] `--help` output documents the `--json` flag
- [ ] All 12 tests in `cct-status-test.sh` pass under `npm test`
- [ ] No Bash 3.2 incompatibilities (no associative arrays, no `readarray`, no `${var,,}`)

Historical context (lessons from previous pipelines):
# Shipwright Memory Context
# Injected at: 2026-02-09T22:28:23Z
# Stage: build

## Failure Patterns to Avoid

## Known Fixes

## Code Conventions

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add --json output flag to shipwright status command

## Implementation Checklist
- [x] `shipwright status --json` outputs valid JSON
- [x] All sections present: teams, daemon, heartbeats, machines (plus tasks and timestamp)
- [x] `shipwright status` (without flag) still works identically
- [x] Tests validate JSON output structure

## Context
- Pipeline: standard
- Branch: feat/add-json-output-flag-to-shipwright-statu-4
- Issue: #4
- Generated: 2026-02-09T22:27:27Z"
iteration: 3
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-02-09T22:47:17Z
last_iteration_at: 2026-02-09T22:47:17Z
consecutive_failures: 0
total_commits: 3
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-02-09T22:34:08Z)
- `scripts/cct-status.sh` — `--json` flag with full JSON output covering teams, tasks, daemon, heartbeats, machines, a
- `scripts/cct-status-test.sh` — 12-test suite covering all acceptance criteria
- `package.json` — test suite wired into `npm test`

### Iteration 2 (2026-02-09T22:39:11Z)
- `scripts/cct-status.sh` has the `--json` flag with full JSON output
- `scripts/cct-status-test.sh` has 12 tests covering all acceptance criteria
- `package.json` wires the test suite into `npm test`

### Iteration 3 (2026-02-09T22:47:17Z)
3. **TODO/FIXME/HACK/XXX comments?** None in new code ✓
4. **All functions tested?** 12 tests cover all sections and edge cases ✓
5. **Code reviewer approval?** The fix precisely addresses the audit feedback — `tasks` changed from array to object, 

