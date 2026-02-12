#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright status test — Validate status dashboard and --json output   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-status-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/home/.claude/teams"
    mkdir -p "$TEMP_DIR/home/.claude/tasks"
    mkdir -p "$TEMP_DIR/home/.shipwright/heartbeats"
    mkdir -p "$TEMP_DIR/bin"

    # Mock tmux — return test windows
    cat > "$TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list-windows" ]]; then
    echo "main:1|claude-team-alpha|3|1"
    echo "main:2|editor|1|0"
    echo "sw-test:1|claude-build|2|0"
    exit 0
fi
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/tmux"

    # Mock jq — use real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock kill — always fails (daemon not running)
    cat > "$TEMP_DIR/bin/kill" <<'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
    chmod +x "$TEMP_DIR/bin/kill"

    # Mock curl — return developer data
    cat > "$TEMP_DIR/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
echo '{"total_online":1,"developers":[{"id":"dev1","machine":"laptop","status":"online","active_jobs":1,"queued":0}]}'
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/curl"

    # Create fixture: daemon-state.json
    cat > "$TEMP_DIR/home/.shipwright/daemon-state.json" <<'FIXTURE'
{
    "active_jobs": [
        {"issue":42,"pid":12345,"worktree":".worktrees/issue-42","title":"Live terminal streaming","started_at":"2026-02-12T10:00:00Z"}
    ],
    "queued": [35, 36],
    "completed": [
        {"issue":4,"result":"success","duration":"5m 30s","completed_at":"2026-02-12T09:50:00Z"},
        {"issue":6,"result":"failed","duration":"2m","completed_at":"2026-02-12T09:40:00Z"}
    ],
    "retry_counts": {"6":1},
    "titles": {"42":"Live terminal streaming","35":"Open telemetry","36":"Autonomous PR lifecycle"},
    "started_at": "2026-02-12T08:00:00Z",
    "last_poll": "2026-02-12T10:01:00Z"
}
FIXTURE

    # Create fixture: daemon.pid (non-running process)
    echo "99999" > "$TEMP_DIR/home/.shipwright/daemon.pid"

    # Create fixture: team config
    mkdir -p "$TEMP_DIR/home/.claude/teams/alpha"
    cat > "$TEMP_DIR/home/.claude/teams/alpha/config.json" <<'FIXTURE'
{"members":[{"name":"lead"},{"name":"builder"},{"name":"tester"}]}
FIXTURE

    # Create fixture: task list
    mkdir -p "$TEMP_DIR/home/.claude/tasks/alpha"
    echo '{"status":"completed"}' > "$TEMP_DIR/home/.claude/tasks/alpha/task-1.json"
    echo '{"status":"completed"}' > "$TEMP_DIR/home/.claude/tasks/alpha/task-2.json"
    echo '{"status":"in_progress"}' > "$TEMP_DIR/home/.claude/tasks/alpha/task-3.json"
    echo '{"status":"pending"}' > "$TEMP_DIR/home/.claude/tasks/alpha/task-4.json"

    # Create fixture: heartbeat
    cat > "$TEMP_DIR/home/.shipwright/heartbeats/pipeline-42.json" <<'FIXTURE'
{"stage":"build","timestamp":"2026-02-12T10:00:30Z","iteration":3}
FIXTURE

    # Create fixture: machines
    cat > "$TEMP_DIR/home/.shipwright/machines.json" <<'FIXTURE'
{"machines":[{"name":"localhost","host":"127.0.0.1","role":"primary","workers":4}]}
FIXTURE

    # Create fixture: tracker config
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'FIXTURE'
{"provider":"linear"}
FIXTURE

    # Create fixture: team config for dashboard
    cat > "$TEMP_DIR/home/.shipwright/team-config.json" <<'FIXTURE'
{"dashboard_url":"http://localhost:3000"}
FIXTURE

    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
}

cleanup_env() {
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TEST HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Status Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: --json produces valid JSON ───────────────────────────────────────
echo -e "${BOLD}  JSON Output${RESET}"

json_output=$(bash "$SCRIPT_DIR/sw-status.sh" --json 2>/dev/null) || true
if echo "$json_output" | jq empty 2>/dev/null; then
    assert_pass "--json produces valid JSON"
else
    assert_fail "--json produces valid JSON" "output was not valid JSON"
fi

# ─── Test 2: All top-level keys present ───────────────────────────────────────
expected_keys="connected_developers daemon heartbeats issue_tracker remote_machines task_lists teams timestamp tmux_windows version"
actual_keys=$(echo "$json_output" | jq -r 'keys[]' 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "All 10 top-level keys present" "$expected_keys" "$actual_keys"

# ─── Test 3: Version field ────────────────────────────────────────────────────
version=$(echo "$json_output" | jq -r '.version' 2>/dev/null)
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    assert_pass "Version is semver format ($version)"
else
    assert_fail "Version is semver format" "got: $version"
fi

# ─── Test 4: Timestamp is ISO-8601 UTC ────────────────────────────────────────
ts=$(echo "$json_output" | jq -r '.timestamp' 2>/dev/null)
if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    assert_pass "Timestamp is ISO-8601 UTC ($ts)"
else
    assert_fail "Timestamp is ISO-8601 UTC" "got: $ts"
fi

# ─── Test 5: tmux windows contains Claude windows ────────────────────────────
claude_windows=$(echo "$json_output" | jq '[.tmux_windows[] | select(.claude == true)] | length' 2>/dev/null)
assert_eq "tmux_windows has Claude windows" "2" "$claude_windows"

# ─── Test 6: teams section has fixture data ───────────────────────────────────
team_count=$(echo "$json_output" | jq '.teams | length' 2>/dev/null)
assert_eq "teams has 1 team" "1" "$team_count"

team_members=$(echo "$json_output" | jq '.teams[0].members' 2>/dev/null)
assert_eq "team has 3 members" "3" "$team_members"

# ─── Test 7: task_lists has fixture data ──────────────────────────────────────
task_total=$(echo "$json_output" | jq '.task_lists[0].total' 2>/dev/null)
assert_eq "task_lists total is 4" "4" "$task_total"

task_completed=$(echo "$json_output" | jq '.task_lists[0].completed' 2>/dev/null)
assert_eq "task_lists completed is 2" "2" "$task_completed"

task_ip=$(echo "$json_output" | jq '.task_lists[0].in_progress' 2>/dev/null)
assert_eq "task_lists in_progress is 1" "1" "$task_ip"

# ─── Test 8: daemon section has fixture data ──────────────────────────────────
daemon_running=$(echo "$json_output" | jq '.daemon.running' 2>/dev/null)
assert_eq "daemon.running is false (mock kill fails)" "false" "$daemon_running"

active_count=$(echo "$json_output" | jq '.daemon.active_jobs | length' 2>/dev/null)
assert_eq "daemon has 1 active job" "1" "$active_count"

queued_count=$(echo "$json_output" | jq '.daemon.queued | length' 2>/dev/null)
assert_eq "daemon has 2 queued issues" "2" "$queued_count"

completed_count=$(echo "$json_output" | jq '.daemon.recent_completions | length' 2>/dev/null)
assert_eq "daemon has 2 recent completions" "2" "$completed_count"

# ─── Test 9: heartbeats has fixture data ──────────────────────────────────────
hb_count=$(echo "$json_output" | jq '.heartbeats | length' 2>/dev/null)
assert_eq "heartbeats has 1 entry" "1" "$hb_count"

hb_stage=$(echo "$json_output" | jq -r '.heartbeats[0].stage' 2>/dev/null)
assert_eq "heartbeat stage is build" "build" "$hb_stage"

# ─── Test 10: remote_machines has fixture data ────────────────────────────────
machine_count=$(echo "$json_output" | jq '.remote_machines | length' 2>/dev/null)
assert_eq "remote_machines has 1 machine" "1" "$machine_count"

# ─── Test 11: issue_tracker from fixture ──────────────────────────────────────
tracker_provider=$(echo "$json_output" | jq -r '.issue_tracker.provider' 2>/dev/null)
assert_eq "issue_tracker provider is linear" "linear" "$tracker_provider"

# ─── Test 12: connected_developers from mock curl ─────────────────────────────
dev_online=$(echo "$json_output" | jq '.connected_developers.total_online' 2>/dev/null)
assert_eq "connected_developers total_online is 1" "1" "$dev_online"

# ─── Test 13: No ANSI codes in JSON output ────────────────────────────────────
ansi_count=$(echo "$json_output" | grep -cP '\033\[' 2>/dev/null || true)
ansi_count="${ansi_count:-0}"
assert_eq "No ANSI escape codes in JSON" "0" "$ansi_count"

# ─── Test 14: --help works ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  CLI Flags${RESET}"

help_output=$(bash "$SCRIPT_DIR/sw-status.sh" --help 2>&1) || true
if echo "$help_output" | grep -q "\-\-json"; then
    assert_pass "--help mentions --json"
else
    assert_fail "--help mentions --json"
fi

# ─── Test 15: Human-readable output has section headers ───────────────────────
echo ""
echo -e "${BOLD}  Human-Readable Output${RESET}"

human_output=$(bash "$SCRIPT_DIR/sw-status.sh" 2>&1) || true
for section in "TMUX WINDOWS" "TEAM CONFIGS" "TASK LISTS" "DAEMON PIPELINES"; do
    if echo "$human_output" | grep -q "$section"; then
        assert_pass "Human output has '$section' header"
    else
        assert_fail "Human output has '$section' header"
    fi
done

# ─── Test 16: Empty state produces valid JSON ─────────────────────────────────
echo ""
echo -e "${BOLD}  Empty State${RESET}"

# Create empty home
EMPTY_HOME=$(mktemp -d "${TMPDIR:-/tmp}/sw-status-empty.XXXXXX")
mkdir -p "$EMPTY_HOME/.shipwright" "$EMPTY_HOME/.claude"
empty_json=$(HOME="$EMPTY_HOME" bash "$SCRIPT_DIR/sw-status.sh" --json 2>/dev/null) || true
rm -rf "$EMPTY_HOME"

if echo "$empty_json" | jq empty 2>/dev/null; then
    assert_pass "Empty state produces valid JSON"
else
    assert_fail "Empty state produces valid JSON"
fi

empty_daemon=$(echo "$empty_json" | jq '.daemon' 2>/dev/null)
assert_eq "Empty state daemon is null" "null" "$empty_daemon"

empty_teams=$(echo "$empty_json" | jq '.teams' 2>/dev/null)
assert_eq "Empty state teams is []" "[]" "$empty_teams"

# ─── Test 17: JSON is independently queryable ─────────────────────────────────
echo ""
echo -e "${BOLD}  Subsection Queries${RESET}"

active_issues=$(echo "$json_output" | jq -c '[.daemon.active_jobs[].issue]' 2>/dev/null)
assert_eq "daemon.active_jobs[].issue queryable" "[42]" "$active_issues"

queued_list=$(echo "$json_output" | jq '.daemon.queued' 2>/dev/null)
assert_eq "daemon.queued queryable" "[35,36]" "$(echo "$queued_list" | tr -d ' \n')"

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
else
    echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo ""

exit "$FAIL"
