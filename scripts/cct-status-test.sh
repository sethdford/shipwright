#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright status test — Validate --json output, empty states,         ║
# ║  data sections, --help flag, and human output regression.               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches cct theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cct-status-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.claude/tasks"
    mkdir -p "$TEMP_DIR/home/.claude/teams"
    mkdir -p "$TEMP_DIR/home/.claude-teams/heartbeats"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/scripts/lib"

    # Copy script under test
    cp "$SCRIPT_DIR/cct-status.sh" "$TEMP_DIR/scripts/"
    if [[ -f "$SCRIPT_DIR/lib/compat.sh" ]]; then
        cp "$SCRIPT_DIR/lib/compat.sh" "$TEMP_DIR/scripts/lib/"
    fi

    # Mock tmux — returns nothing by default
    cat > "$TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
# Default: no windows
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/tmux"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# Helper: run status --json with sandboxed HOME and mock PATH
run_status_json() {
    HOME="$TEMP_DIR/home" PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/cct-status.sh" --json 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. JSON output is valid JSON
# ──────────────────────────────────────────────────────────────────────────────
test_json_valid() {
    local output
    output=$(run_status_json)
    echo "$output" | jq . >/dev/null 2>&1
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. JSON has all six top-level keys
# ──────────────────────────────────────────────────────────────────────────────
test_json_top_level_keys() {
    local output
    output=$(run_status_json)

    for key in timestamp teams tasks daemon heartbeats machines; do
        if ! echo "$output" | jq -e "has(\"$key\")" >/dev/null 2>&1; then
            echo -e "    ${RED}✗${RESET} Missing key: $key"
            return 1
        fi
    done
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Empty state: teams=[], tasks=[], daemon=null, heartbeats=[], machines=[]
# ──────────────────────────────────────────────────────────────────────────────
test_json_empty_state() {
    local output
    output=$(run_status_json)

    local teams_len tasks_len hb_len machines_len daemon_val
    teams_len=$(echo "$output" | jq '.teams | length')
    tasks_len=$(echo "$output" | jq '.tasks | length')
    hb_len=$(echo "$output" | jq '.heartbeats | length')
    machines_len=$(echo "$output" | jq '.machines | length')
    daemon_val=$(echo "$output" | jq '.daemon')

    if [[ "$teams_len" != "0" ]]; then
        echo -e "    ${RED}✗${RESET} Expected teams=[], got length $teams_len"
        return 1
    fi
    if [[ "$tasks_len" != "0" ]]; then
        echo -e "    ${RED}✗${RESET} Expected tasks=[], got length $tasks_len"
        return 1
    fi
    if [[ "$hb_len" != "0" ]]; then
        echo -e "    ${RED}✗${RESET} Expected heartbeats=[], got length $hb_len"
        return 1
    fi
    if [[ "$machines_len" != "0" ]]; then
        echo -e "    ${RED}✗${RESET} Expected machines=[], got length $machines_len"
        return 1
    fi
    if [[ "$daemon_val" != "null" ]]; then
        echo -e "    ${RED}✗${RESET} Expected daemon=null, got $daemon_val"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Timestamp is ISO 8601 format
# ──────────────────────────────────────────────────────────────────────────────
test_json_timestamp_format() {
    local output
    output=$(run_status_json)

    local ts
    ts=$(echo "$output" | jq -r '.timestamp')
    # Check ISO 8601 pattern: YYYY-MM-DDTHH:MM:SSZ
    if ! echo "$ts" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
        echo -e "    ${RED}✗${RESET} Timestamp not ISO 8601: $ts"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Teams populated from mock tmux
# ──────────────────────────────────────────────────────────────────────────────
test_json_teams_populated() {
    # Create a tmux mock that returns Claude windows
    cat > "$TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "list-windows" ]]; then
    echo "work:1|claude-refactor|3|1"
    echo "work:2|claude-test|2|0"
    echo "work:3|vim-editor|1|0"
    exit 0
fi
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/tmux"

    local output
    output=$(run_status_json)

    local count
    count=$(echo "$output" | jq '.teams | length')
    if [[ "$count" != "2" ]]; then
        echo -e "    ${RED}✗${RESET} Expected 2 Claude teams, got $count"
        return 1
    fi

    # Check first team fields
    local name status panes session
    name=$(echo "$output" | jq -r '.teams[0].name')
    panes=$(echo "$output" | jq '.teams[0].panes')
    status=$(echo "$output" | jq -r '.teams[0].status')
    session=$(echo "$output" | jq -r '.teams[0].session')

    if [[ "$name" != "claude-refactor" ]]; then
        echo -e "    ${RED}✗${RESET} Expected name 'claude-refactor', got '$name'"
        return 1
    fi
    if [[ "$panes" != "3" ]]; then
        echo -e "    ${RED}✗${RESET} Expected panes=3, got $panes"
        return 1
    fi
    if [[ "$status" != "active" ]]; then
        echo -e "    ${RED}✗${RESET} Expected status 'active', got '$status'"
        return 1
    fi

    # Second team should be idle (active=0)
    local status2
    status2=$(echo "$output" | jq -r '.teams[1].status')
    if [[ "$status2" != "idle" ]]; then
        echo -e "    ${RED}✗${RESET} Expected second team status 'idle', got '$status2'"
        return 1
    fi

    # Restore empty tmux mock
    cat > "$TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/tmux"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Tasks populated from mock task files
# ──────────────────────────────────────────────────────────────────────────────
test_json_tasks_populated() {
    local team_dir="$TEMP_DIR/home/.claude/tasks/my-team"
    mkdir -p "$team_dir"

    echo '{"status": "completed"}' > "$team_dir/task-1.json"
    echo '{"status": "completed"}' > "$team_dir/task-2.json"
    echo '{"status": "in_progress"}' > "$team_dir/task-3.json"
    echo '{"status": "pending"}' > "$team_dir/task-4.json"
    echo '{"status": "pending"}' > "$team_dir/task-5.json"

    local output
    output=$(run_status_json)

    local team total completed in_progress pending
    team=$(echo "$output" | jq -r '.tasks[0].team')
    total=$(echo "$output" | jq '.tasks[0].total')
    completed=$(echo "$output" | jq '.tasks[0].completed')
    in_progress=$(echo "$output" | jq '.tasks[0].in_progress')
    pending=$(echo "$output" | jq '.tasks[0].pending')

    if [[ "$team" != "my-team" ]]; then
        echo -e "    ${RED}✗${RESET} Expected team 'my-team', got '$team'"
        return 1
    fi
    if [[ "$total" != "5" ]]; then
        echo -e "    ${RED}✗${RESET} Expected total=5, got $total"
        return 1
    fi
    if [[ "$completed" != "2" ]]; then
        echo -e "    ${RED}✗${RESET} Expected completed=2, got $completed"
        return 1
    fi
    if [[ "$in_progress" != "1" ]]; then
        echo -e "    ${RED}✗${RESET} Expected in_progress=1, got $in_progress"
        return 1
    fi
    if [[ "$pending" != "2" ]]; then
        echo -e "    ${RED}✗${RESET} Expected pending=2, got $pending"
        return 1
    fi

    # Cleanup
    rm -rf "$team_dir"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Daemon populated from mock state file
# ──────────────────────────────────────────────────────────────────────────────
test_json_daemon_populated() {
    local state_file="$TEMP_DIR/home/.claude-teams/daemon-state.json"
    cat > "$state_file" <<'EOF'
{
    "active_jobs": [{"issue": "42", "title": "Fix bug"}],
    "queued": ["43", "44"],
    "completed": [{"issue": "40", "result": "success"}, {"issue": "41", "result": "success"}]
}
EOF

    local output
    output=$(run_status_json)

    local running active queued completed
    running=$(echo "$output" | jq '.daemon.running')
    active=$(echo "$output" | jq '.daemon.active_jobs')
    queued=$(echo "$output" | jq '.daemon.queued')
    completed=$(echo "$output" | jq '.daemon.completed')

    if [[ "$running" != "false" ]]; then
        echo -e "    ${RED}✗${RESET} Expected running=false (no PID), got $running"
        return 1
    fi
    if [[ "$active" != "1" ]]; then
        echo -e "    ${RED}✗${RESET} Expected active_jobs=1, got $active"
        return 1
    fi
    if [[ "$queued" != "2" ]]; then
        echo -e "    ${RED}✗${RESET} Expected queued=2, got $queued"
        return 1
    fi
    if [[ "$completed" != "2" ]]; then
        echo -e "    ${RED}✗${RESET} Expected completed=2, got $completed"
        return 1
    fi

    # Cleanup
    rm -f "$state_file"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Heartbeats populated from mock files
# ──────────────────────────────────────────────────────────────────────────────
test_json_heartbeats_populated() {
    local hb_dir="$TEMP_DIR/home/.claude-teams/heartbeats"
    cat > "$hb_dir/pipeline-123.json" <<EOF
{"pid": $$, "stage": "build", "issue": "42", "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF

    local output
    output=$(run_status_json)

    local count job_id stage issue alive
    count=$(echo "$output" | jq '.heartbeats | length')
    job_id=$(echo "$output" | jq -r '.heartbeats[0].job_id')
    stage=$(echo "$output" | jq -r '.heartbeats[0].stage')
    issue=$(echo "$output" | jq -r '.heartbeats[0].issue')
    alive=$(echo "$output" | jq '.heartbeats[0].alive')

    if [[ "$count" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected at least 1 heartbeat, got $count"
        return 1
    fi
    if [[ "$job_id" != "pipeline-123" ]]; then
        echo -e "    ${RED}✗${RESET} Expected job_id 'pipeline-123', got '$job_id'"
        return 1
    fi
    if [[ "$stage" != "build" ]]; then
        echo -e "    ${RED}✗${RESET} Expected stage 'build', got '$stage'"
        return 1
    fi
    if [[ "$issue" != "42" ]]; then
        echo -e "    ${RED}✗${RESET} Expected issue '42', got '$issue'"
        return 1
    fi
    # Check alive is boolean
    if [[ "$alive" != "true" && "$alive" != "false" ]]; then
        echo -e "    ${RED}✗${RESET} Expected alive to be boolean, got '$alive'"
        return 1
    fi

    # Cleanup
    rm -f "$hb_dir/pipeline-123.json"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Machines populated from mock file
# ──────────────────────────────────────────────────────────────────────────────
test_json_machines_populated() {
    local machines_file="$TEMP_DIR/home/.claude-teams/machines.json"
    cat > "$machines_file" <<'EOF'
{
    "machines": [
        {"name": "localhost", "host": "127.0.0.1", "cores": 8, "memory_gb": 32, "max_workers": 4},
        {"name": "builder-1", "host": "10.0.0.5", "cores": 16, "memory_gb": 64, "max_workers": 8}
    ]
}
EOF

    local output
    output=$(run_status_json)

    local count name host cores mem workers
    count=$(echo "$output" | jq '.machines | length')
    name=$(echo "$output" | jq -r '.machines[0].name')
    host=$(echo "$output" | jq -r '.machines[0].host')
    cores=$(echo "$output" | jq '.machines[0].cores')
    mem=$(echo "$output" | jq '.machines[0].memory_gb')
    workers=$(echo "$output" | jq '.machines[0].max_workers')

    if [[ "$count" != "2" ]]; then
        echo -e "    ${RED}✗${RESET} Expected 2 machines, got $count"
        return 1
    fi
    if [[ "$name" != "localhost" ]]; then
        echo -e "    ${RED}✗${RESET} Expected name 'localhost', got '$name'"
        return 1
    fi
    if [[ "$host" != "127.0.0.1" ]]; then
        echo -e "    ${RED}✗${RESET} Expected host '127.0.0.1', got '$host'"
        return 1
    fi
    if [[ "$cores" != "8" ]]; then
        echo -e "    ${RED}✗${RESET} Expected cores=8, got $cores"
        return 1
    fi
    if [[ "$mem" != "32" ]]; then
        echo -e "    ${RED}✗${RESET} Expected memory_gb=32, got $mem"
        return 1
    fi
    if [[ "$workers" != "4" ]]; then
        echo -e "    ${RED}✗${RESET} Expected max_workers=4, got $workers"
        return 1
    fi

    # Cleanup
    rm -f "$machines_file"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. --help flag prints usage and exits 0
# ──────────────────────────────────────────────────────────────────────────────
test_help_flag() {
    local output exit_code=0
    output=$(bash "$TEMP_DIR/scripts/cct-status.sh" --help 2>/dev/null) || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} --help exited with $exit_code"
        return 1
    fi
    if ! echo "$output" | grep -q "Usage:"; then
        echo -e "    ${RED}✗${RESET} --help output missing 'Usage:'"
        return 1
    fi
    if ! echo "$output" | grep -q "\-\-json"; then
        echo -e "    ${RED}✗${RESET} --help output missing '--json' description"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Human output unchanged (no --json flag produces ANSI output)
# ──────────────────────────────────────────────────────────────────────────────
test_human_output_regression() {
    local output
    output=$(HOME="$TEMP_DIR/home" PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/cct-status.sh" 2>/dev/null)

    # Human output should contain the dashboard header
    if ! echo "$output" | grep -q "Claude Code Teams"; then
        echo -e "    ${RED}✗${RESET} Human output missing dashboard header"
        return 1
    fi
    # Should NOT be valid JSON (it's ANSI-decorated text)
    if echo "$output" | jq . >/dev/null 2>&1; then
        echo -e "    ${RED}✗${RESET} Human output should not be valid JSON"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. JSON with missing jq exits 1
# ──────────────────────────────────────────────────────────────────────────────
test_json_no_jq() {
    # Create a PATH with no jq
    local no_jq_dir="$TEMP_DIR/no-jq-bin"
    mkdir -p "$no_jq_dir"
    # Copy tmux mock
    cp "$TEMP_DIR/bin/tmux" "$no_jq_dir/"
    # Add a dummy bash so the script can run
    ln -sf "$(command -v bash)" "$no_jq_dir/bash" 2>/dev/null || true
    # Provide basic utilities
    for cmd in date grep sed cut head basename find sort kill cat tr printf; do
        local cmd_path
        cmd_path=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$cmd_path" ]]; then
            ln -sf "$cmd_path" "$no_jq_dir/$cmd" 2>/dev/null || true
        fi
    done

    local exit_code=0
    HOME="$TEMP_DIR/home" PATH="$no_jq_dir" \
        bash "$TEMP_DIR/scripts/cct-status.sh" --json >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Expected exit 1 when jq missing, got 0"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright status — Test Suite                   ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for status tests"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# JSON validity
echo -e "${PURPLE}${BOLD}JSON Output${RESET}"
run_test "JSON output is valid JSON" test_json_valid
run_test "JSON has all six top-level keys" test_json_top_level_keys
run_test "Empty state returns correct defaults" test_json_empty_state
run_test "Timestamp is ISO 8601 format" test_json_timestamp_format
echo ""

# Data sections
echo -e "${PURPLE}${BOLD}Data Sections${RESET}"
run_test "Teams populated from tmux" test_json_teams_populated
run_test "Tasks populated from mock files" test_json_tasks_populated
run_test "Daemon populated from state file" test_json_daemon_populated
run_test "Heartbeats populated from files" test_json_heartbeats_populated
run_test "Machines populated from file" test_json_machines_populated
echo ""

# Flags and regression
echo -e "${PURPLE}${BOLD}Flags & Regression${RESET}"
run_test "--help prints usage and exits 0" test_help_flag
run_test "Human output unchanged (no --json)" test_human_output_regression
run_test "JSON with missing jq exits 1" test_json_no_jq
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
else
    echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo ""

exit "$FAIL"
