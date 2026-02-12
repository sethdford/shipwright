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

The `shipwright status` command (`scripts/sw-status.sh`, ~605 lines) renders a human-readable dashboard showing tmux windows, team configs, task lists, daemon/pipeline state, issue tracker info, heartbeats, remote machines, and connected developers. It currently interleaves data collection (tmux queries, JSON file reads, curl calls) with ANSI-colored echo output, making it impossible to consume programmatically.

Other shipwright commands already support `--json` output: `sw-pipeline-vitals.sh`, `sw-cost.sh`, and `sw-fleet.sh` all follow a pattern of flag parsing at the top, data collection into variables, and conditional rendering. The project requires Bash 3.2 compatibility (no associative arrays, no `readarray`, no `${var,,}`), `set -euo pipefail`, and `jq --arg` for JSON construction (never string interpolation).

## Decision

**Refactor `sw-status.sh` into collect/render pairs, gated by a `--json` flag.**

**Data flow:**
1. Parse `--json` / `--help` flags at script top (after `source compat.sh`)
2. Eight `collect_*` functions each populate a `*_JSON` shell variable with a jq-constructed JSON fragment (array or object). These functions perform no stdout output.
3. When `JSON_OUTPUT=false`: eight `render_*` functions reproduce the existing human-readable output verbatim using the collected data.
4. When `JSON_OUTPUT=true`: a single `jq -n` call assembles all eight fragments plus `version` and `timestamp` into one JSON object written to stdout, then exits.

**JSON schema (top-level keys):**
```json
{
  "version": "string",
  "timestamp": "ISO-8601 UTC",
  "tmux_windows": [{"name", "session_window", "pane_count", "active"}],
  "teams": [{"name", "members", "member_names"}],
  "tasks": [{"team", "total", "completed", "in_progress", "pending", "percent_complete"}],
  "daemon": {"running", "pid", "uptime_seconds", "active_jobs", "queued", "completed", "recent_activity"},
  "tracker": {"provider", "url"},
  "heartbeats": [{"job_id", "pid", "alive", "stage", "issue", "iteration", "activity", "updated_at", "age_seconds", "memory_mb"}],
  "remote_machines": [{"name", "host", "cores", "memory_gb", "max_workers"}],
  "connected_developers": {"reachable", "dashboard_url", "total_online", "developers"}
}
```

**Error handling:** Each `collect_*` function initializes its variable to `[]` or `{}` before attempting data reads. Missing files, unreachable daemons, or failed tmux queries result in empty collections — never missing keys. All `jq` calls use `--arg` / `--argjson` for safe escaping. ANSI escape codes are never written when `JSON_OUTPUT=true` (color helpers short-circuit or are bypassed entirely).

**Pattern alignment:** Follows the same flag-parsing and `jq -n` assembly pattern used in `sw-pipeline-vitals.sh` (which the user's supermemory confirms has a `--json` flag) and `sw-cost.sh`.

## Alternatives Considered

1. **Emit JSON per-section (streaming NDJSON)** — Pros: simpler implementation, each section independently parseable. Cons: breaks `jq .` on the full output, inconsistent with `sw-pipeline-vitals.sh` and `sw-cost.sh` which emit a single JSON object. Users expect `| jq .field` to work on a single document.

2. **Separate `sw-status-json.sh` script** — Pros: zero risk of regressing human-readable output. Cons: duplicates all data-collection logic, doubles maintenance surface, diverges from the `--json` flag convention established by other sw scripts.

3. **Template-based rendering (shared data, pluggable formatters)** — Pros: cleanest separation of concerns. Cons: over-engineered for a bash script; adds abstraction layers that make the code harder to read and maintain. The collect/render pair approach achieves adequate separation without framework overhead.

## Implementation Plan

**Files to create:**
- `scripts/sw-status-test.sh` — test suite following existing harness pattern (mock binaries, PASS/FAIL counters, ERR trap, temp directory fixtures)

**Files to modify:**
- `scripts/sw-status.sh` — add flag parsing, refactor into 8 collect/render pairs, add JSON assembly
- `scripts/sw` — update help text for `status` subcommand to show `[--json]`
- `package.json` — append `&& bash scripts/sw-status-test.sh` to the npm test script

**Dependencies:** None new. `jq` is already a project dependency used throughout.

**Risk areas:**
- **Regression in human-readable output.** The render functions must reproduce the exact current output including ANSI codes, box-drawing characters, and conditional sections. Mitigation: capture a baseline snapshot of current output before refactoring; compare after.
- **`set -euo pipefail` interactions.** Commands like `tmux list-windows` or `curl` that may fail (no tmux session, daemon not running) must be guarded with `|| true` or checked via return code, not allowed to exit the script. The current code already handles some of these; refactoring must preserve all guards.
- **Large JSON assembly.** If a user has many heartbeats or team configs, the `jq -n` call receives many `--argjson` arguments. This is fine for practical team sizes but worth noting. No mitigation needed.
- **Bash 3.2 `$()` nesting.** Complex jq command substitutions must avoid nested `$()` where possible, using temp variables instead.

## Validation Criteria

- [ ] `shipwright status` (no flag) produces byte-identical output to the pre-change version in all states (active daemon, no daemon, empty teams, populated teams)
- [ ] `shipwright status --json` outputs valid JSON: `shipwright status --json | jq empty` exits 0
- [ ] JSON output contains zero ANSI escape codes: `shipwright status --json | grep -P '\x1b\[' | wc -l` returns 0
- [ ] All 10 top-level keys present in JSON output: `version`, `timestamp`, `tmux_windows`, `teams`, `tasks`, `daemon`, `tracker`, `heartbeats`, `remote_machines`, `connected_developers`
- [ ] Empty state (no daemon, no teams, no tmux) produces empty arrays/objects for all collection keys — no `null` values, no missing keys
- [ ] `shipwright status --help` prints usage including `--json` documentation
- [ ] `shipwright help` / `sw` help text shows `[--json]` for the status subcommand
- [ ] `sw-status-test.sh` passes all tests (valid JSON structure, key presence, empty-state handling, human-readable section headers, help output)
- [ ] Test suite registered in `package.json` and runs via `npm test`
- [ ] No Bash 3.2 incompatibilities: no `declare -A`, no `readarray`, no `${var,,}`, no `${var^^}`
- [ ] `set -euo pipefail` maintained; no unguarded commands that could exit on expected failures

Historical context (lessons from previous pipelines):
{
  "results": [
    {"file": "architecture.json", "relevance": 92, "summary": "Contains codebase architecture, patterns, conventions, and dependencies essential for implementing the --json flag in sw-status.sh correctly"},
    {"file": "failures.json", "relevance": 15, "summary": "No failure patterns recorded — empty but could contain relevant build failures if populated"},
    {"file": "decisions.json", "relevance": 12, "summary": "No architectural decisions recorded — empty but could contain relevant design decisions if populated"},
    {"file": "global.json", "relevance": 8, "summary": "No cross-repo learnings recorded — empty, minimal relevance"},
    {"file": "patterns.json", "relevance": 5, "summary": "Empty pattern file — no relevant content"}
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
iteration: 2
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-02-12T17:58:14Z
last_iteration_at: 2026-02-12T17:58:14Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/Users/sethford/Documents/shipwright/.worktrees/pipeline-issue-4/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-02-12T17:53:42Z)
You've hit your limit · resets 11am (America/Denver)

### Iteration 2 (2026-02-12T17:58:14Z)
You've hit your limit · resets 11am (America/Denver)

