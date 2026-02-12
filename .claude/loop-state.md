---
goal: "Add --json output flag to shipwright status command

Implementation plan (follow this exactly):
The plan has been developed. Here's the implementation plan for **adding `--json` output flag to `shipwright status`**:

---

## Files to Modify

| # | File | Action | Purpose |
|---|------|--------|---------|
| 1 | `scripts/sw-status.sh` | **Modify** | Add `--json` flag, JSON collection, `jq` output |
| 2 | `scripts/sw-status-test.sh` | **Create** | Test suite with mock environment |
| 3 | `completions/shipwright.bash` | **Modify** | Bash tab completion for `--json` |
| 4 | `completions/_shipwright` | **Modify** | Zsh tab completion for `--json` |
| 5 | `completions/shipwright.fish` | **Modify** | Fish tab completion for `--json` |
| 6 | `package.json` | **Modify** | Register test suite |

## Architecture Decision: Separate Code Path (Early Exit)

Following the pattern from `sw-cost.sh:550-670` and `sw-daemon.sh:5119-5300`, the `--json` flag triggers an **entirely separate code path** that collects data, builds JSON via `jq -n`, and exits before the display code runs. The existing 600-line display code remains **completely untouched** — zero regression risk.

## JSON Schema

```json
{
  "version": "1.10.0",
  "timestamp": "2026-02-12T...",
  "tmux_windows": [...],
  "teams": [...],
  "task_lists": [...],
  "daemon": { "running": bool, "pid": N, "active_jobs": [...], "queued": [...], "recent_completions": [...] },
  "issue_tracker": { "provider": "linear", "url": null },
  "heartbeats": [...],
  "remote_machines": [...],
  "connected_developers": { "reachable": bool, "total_online": N, "developers": [...] }
}
```

Empty/missing sections use `null` or `[]`.

## Task Checklist (15 tasks)

- [ ] Task 1: Add `--json` flag parsing to `sw-status.sh`
- [ ] Task 2: JSON collection for tmux windows
- [ ] Task 3: JSON collection for team configs
- [ ] Task 4: JSON collection for task lists
- [ ] Task 5: JSON collection for daemon pipelines (active, queued, completions)
- [ ] Task 6: JSON collection for issue tracker
- [ ] Task 7: JSON collection for heartbeats
- [ ] Task 8: JSON collection for remote machines
- [ ] Task 9: JSON collection for connected developers
- [ ] Task 10: Assemble final JSON with `jq -n` and exit
- [ ] Task 11: Update bash completions
- [ ] Task 12: Update zsh completions
- [ ] Task 13: Update fish completions
- [ ] Task 14: Create `sw-status-test.sh` (mock env, 10+ test cases)
- [ ] Task 15: Register test in `package.json`

## Definition of Done

- `shipwright status` unchanged (no regression)
- `shipwright status --json` outputs valid, ANSI-free JSON
- All 8 dashboard sections represented in JSON
- Empty state produces valid JSON with nulls/empty arrays
- `jq` required check with clear error message
- Tab completions for bash/zsh/fish
- Test suite passes, registered in `package.json`
- Bash 3.2 compatible, `set -euo pipefail`
collected data into a single JSON object:

```bash
if [[ "$JSON_OUTPUT" == "true" ]]; then
    jq -n \
        --argjson tmux_windows "$WINDOWS_JSON" \
        --argjson teams "$TEAMS_JSON" \
        --argjson tasks "$TASKS_JSON" \
        --argjson daemon "$DAEMON_JSON" \
        --argjson tracker "$TRACKER_JSON" \
        --argjson heartbeats "$HEARTBEATS_JSON" \
        --argjson machines "$MACHINES_JSON" \
        --argjson developers "$DEVELOPERS_JSON" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg version "$VERSION" \
        '{
            version: $version,
            timestamp: $timestamp,
            tmux_windows: $tmux_windows,
            teams: $teams,
            tasks: $tasks,
            daemon: $daemon,
            tracker: $tracker,
            heartbeats: $heartbeats,
            remote_machines: $machines,
            connected_developers: $developers
        }'
    exit 0
fi
```

**6. Update CLI router help text** in `scripts/sw`

Change line 70:
```
  ${CYAN}status${RESET} [--json]        Show dashboard of running teams and agents
```

**7. Create test suite `scripts/sw-status-test.sh`**

Following the existing test harness pattern (mock environment, PASS/FAIL counters, ERR trap):
- Mock `tmux`, `jq`, `curl`, `kill` binaries
- Create fixture data (daemon-state.json, team configs, task files, heartbeat files, machines.json)
- Test cases:
  - `--json` produces valid JSON
  - JSON contains all expected top-level keys
  - Human-readable output (no `--json`) contains expected section headers
  - Empty state (no teams, no daemon) produces empty arrays in JSON
  - Active daemon with jobs renders correctly in JSON
  - Heartbeat data appears in JSON output
  - `--help` shows usage

**8. Register test suite in `package.json`**

Add `&& bash scripts/sw-status-test.sh` to the npm test script.

### Task Checklist

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

### Testing Approach

1. **Unit tests** (`sw-status-test.sh`): Mock `tmux`, `curl`, `kill`, create fixture JSON files under a temp directory, override `HOME` and `DAEMON_DIR` to point at fixtures. Validate:
   - `--json` output parses as valid JSON via `jq empty`
   - All top-level keys present: `version`, `timestamp`, `tmux_windows`, `teams`, `tasks`, `daemon`, `tracker`, `heartbeats`, `remote_machines`, `connected_developers`
   - Correct counts (e.g., 2 tmux windows → JSON array length 2)
   - Empty state → empty arrays, not missing keys
   - Human-readable output contains expected section headers (`TMUX WINDOWS`, `TEAM CONFIGS`, etc.)

2. **Manual verification**: Run `shipwright status` (no flag) to confirm existing output is unchanged. Run `shipwright status --json` and pipe through `jq .` to verify valid, well-structured JSON.

3. **Integration**: Run `shipwright status --json | jq .tmux_windows` to verify subsections are independently queryable.

### Definition of Done

- [ ] `shipwright status` produces identical output to current (no regression)
- [ ] `shipwright status --json` outputs valid JSON to stdout with zero ANSI escape codes
- [ ] JSON schema includes all 8 dashboard sections as top-level keys
- [ ] Empty state (no daemon, no teams, etc.) produces `[]` / `{}` — not errors
- [ ] `shipwright status --help` shows usage with `--json` documented
- [ ] `sw` CLI help mentions `--json` for the status command
- [ ] Test suite `sw-status-test.sh` passes with all tests green
- [ ] Test suite registered in `package.json`
- [ ] Bash 3.2 compatible (no associative arrays, no `readarray`, no `${var,,}`)
- [ ] `set -euo pipefail` maintained throughout
- [ ] Pattern matches existing `--json` implementations (sw-cost.sh, sw-fleet.sh, sw-pipeline-vitals.sh)

Follow the approved design document:


# Design: Add --json output flag to shipwright status command

## Context

The `shipwright status` command (`scripts/sw-status.sh`, 605 lines) renders a rich terminal dashboard with 8 sections: tmux windows, team configs, task lists, daemon pipelines, issue tracker, heartbeats, remote machines, and connected developers. Currently it only produces ANSI-colored human-readable output.

Users and automated tooling (the web dashboard, CI scripts, `sw-connect.sh`) need machine-readable access to the same data. The codebase already has `--json` flag precedents in `sw-cost.sh`, `sw-fleet.sh`, and `sw-pipeline-vitals.sh` — all using the "early-exit separate code path" pattern where JSON collection runs before display code, assembles via `jq -n`, prints, and exits.

**Constraints:**
- Bash 3.2 compatible (no associative arrays, no `readarray`, no `${var,,}`)
- `set -euo pipefail` throughout
- `jq` is the only JSON tool available (already a dependency across the project)
- The existing 600-line display code path must remain completely untouched to avoid regression
- Output helpers (`info()`, `success()`, `warn()`, `error()`) write to stderr, which naturally keeps JSON stdout clean

## Decision

**Separate early-exit code path**, matching the established pattern from `sw-cost.sh:550-670`.

### Data Flow

1. Parse `--json` flag in the existing argument loop at the top of `sw-status.sh`
2. When `--json` is set, run a dedicated collection block that gathers each section into shell variables holding JSON strings (e.g., `WINDOWS_JSON`, `TEAMS_JSON`)
3. Each collector function reads the same files/commands the display code does (tmux list-windows, daemon-state.json, heartbeat files, etc.) but produces JSON fragments via `jq`
4. Assemble all fragments into a single object with `jq -n --argjson ...` and print to stdout
5. `exit 0` before the display code path ever executes

### JSON Schema (top-level keys)

```json
{
  "version": "string",
  "timestamp": "ISO-8601 UTC",
  "tmux_windows": [{"name": "string", "panes": N, "active": bool}],
  "teams": [{"name": "string", "template": "string", "agents": N}],
  "task_lists": [{"team": "string", "total": N, "completed": N, "tasks": [...]}],
  "daemon": {"running": bool, "pid": N|null, "active_jobs": [...], "queued": [...], "recent_completions": [...]},
  "issue_tracker": {"provider": "string|null", "url": "string|null"},
  "heartbeats": [{"agent": "string", "last_seen": "ISO-8601", "status": "string"}],
  "remote_machines": [{"name": "string", "host": "string", "status": "string"}],
  "connected_developers": {"reachable": bool, "total_online": N, "developers": [...]}
}
```

Missing/unavailable sections produce `null` or `[]` — never omitted keys. This guarantees consumers can always reference any top-level key without existence checks.

### Error Handling

- If `jq` is not installed, emit `error "jq is required for --json output"` to stderr and `exit 1` — check happens immediately after flag parsing, before any collection work
- If tmux is not running, `tmux_windows` becomes `[]` (not an error)
- If daemon-state.json is missing or malformed, `daemon.running` is `false` with remaining fields null/empty
- Each collector is wrapped in a guard: if the source data is absent, emit the empty/null default. No collector failure should abort the entire JSON output

### Flag Parsing

```bash
JSON_OUTPUT="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_OUTPUT="true"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) error "Unknown option: $1"; usage; exit 1 ;;
    esac
done
```

### CLI Router Update

The help text in `scripts/sw` line ~70 updates to: `status [--json]  Show dashboard of running teams and agents`

## Alternatives Considered

1. **Refactor into collect/render pairs** — Pros: Cleaner separation, each section gets `collect_X()` and `render_X()` functions, the JSON path calls `collect_*` only. Cons: Touching all 600 lines of existing display code to refactor into render functions creates significant regression risk. The plan initially proposed this but the "early exit" approach achieves the same result with zero changes to existing code. Refactoring can happen later as a separate PR.

2. **Inline JSON into each display section (interleaved)** — Pros: Single code path, no duplication. Cons: Mixes display and data concerns, every section gets `if $JSON; then ... fi` blocks that double the complexity of every section. Much harder to maintain. Fragile — any display change risks breaking JSON output.

3. **External wrapper script** — Pros: Zero changes to `sw-status.sh`. Cons: Would need to screen-scrape ANSI output or duplicate all the data collection logic in a new file. Not maintainable. Violates the "source of truth" principle.

## Implementation Plan

### Files to modify
- `scripts/sw-status.sh` — Add `--json` flag parsing, `jq` check, 8 collector blocks, JSON assembly, early exit
- `scripts/sw` — Update help text for `status` subcommand (~line 70)
- `completions/shipwright.bash` — Add `--json` to status completions
- `completions/_shipwright` — Add `--json` to status completions (zsh)
- `completions/shipwright.fish` — Add `--json` to status completions (fish)
- `package.json` — Register new test suite

### Files to create
- `scripts/sw-status-test.sh` — Test suite (mock environment, 10+ test cases, PASS/FAIL counters, ERR trap)

### Dependencies
- None new. `jq` is already required by the project (used in 20+ scripts)

### Risk Areas
- **`jq --argjson` with large daemon state**: If `daemon-state.json` contains hundreds of completed jobs, the assembled JSON could be large. Mitigate by limiting `recent_completions` to the last 20 entries (matching the dashboard's visual limit).
- **tmux not available**: The `tmux list-windows` call will fail if tmux isn't running. The collector must handle this gracefully (return `[]`).
- **Shell variable size**: Each JSON fragment is stored in a bash variable. Extremely large task lists could theoretically hit shell limits. In practice, shipwright task lists are small (< 100 items). No mitigation needed for v1.
- **Pipefail + jq chains**: Under `set -eo pipefail`, a `jq` parse error in a collector could abort the entire script. Each collector should use `|| echo '[]'` / `|| echo 'null'` fallbacks.

## Validation Criteria
- [ ] `shipwright status` (no flags) produces byte-identical output to the current version
- [ ] `shipwright status --json` outputs valid JSON (`jq empty` exits 0)
- [ ] JSON output contains zero ANSI escape sequences (`grep -P '\x1b\['` finds nothing)
- [ ] All 10 top-level keys present: `version`, `timestamp`, `tmux_windows`, `teams`, `task_lists`, `daemon`, `issue_tracker`, `heartbeats`, `remote_machines`, `connected_developers`
- [ ] Empty state (no tmux, no daemon, no teams) produces valid JSON with `[]`/`null` — not errors, not missing keys
- [ ] `shipwright status --json | jq .daemon.active_jobs` returns a valid array (subsections independently queryable)
- [ ] `sw-status-test.sh` passes all cases (valid JSON, key presence, empty state, active daemon, heartbeats, human-readable section headers preserved)
- [ ] Test suite registered in `package.json` and runs via `npm test`
- [ ] No Bash 3.2 incompatibilities (`shellcheck` clean, no associative arrays)
- [ ] `--json` without `jq` installed prints clear error to stderr and exits 1
- [ ] Tab completion works for `shipwright status --json` in bash, zsh, and fish

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "architecture.json",
      "relevance": 92,
      "summary": "Contains codebase architecture, patterns, conventions, and dependencies essential for implementing the --json flag in sw-status.sh correctly"
    },
    {
      "file": "failures.json",
      "relevance": 15,
      "summary": "No failure patterns recorded — empty but could contain relevant build failures if populated"
    },
    {
      "file": "decisions.json",
      "relevance": 12,
      "summary": "No architectural decisions recorded — empty but could contain relevant design decisions if populated"
    },
    {
      "file": "global.json",
      "relevance": 8,
      "summary": "No cross-repo learnings recorded — empty, minimal relevance"
    },
    {
      "file": "patterns.json",
      "relevance": 5,
      "summary": "Empty pattern file — no relevant content"
    }
  ]
}

Task tracking (check off items as you complete them):
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
- Generated: 2026-02-12T17:41:32Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-02-12T17:43:44Z
last_iteration_at: 2026-02-12T17:43:44Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/Users/sethford/Documents/shipwright/.worktrees/pipeline-issue-4/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

