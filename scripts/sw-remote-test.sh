#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright remote test — Validate machine registry, atomic writes,     ║
# ║  remote status mock, and distributed fleet rebalancer logic.            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches shipwright theme) ──────────────────────────────────────────────
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-remote-test.XXXXXX")
    mkdir -p "$TEMP_DIR/scripts"
    mkdir -p "$TEMP_DIR/home/.shipwright"

    # Copy remote script and helpers for color/output
    cp "$SCRIPT_DIR/sw-remote.sh" "$TEMP_DIR/scripts/"
    mkdir -p "$TEMP_DIR/scripts/lib"
    [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEMP_DIR/scripts/lib/"

    # Create a mock shipwright installation structure for localhost checks
    mkdir -p "$TEMP_DIR/mock-install/scripts"
    touch "$TEMP_DIR/mock-install/scripts/sw"

    # Mock binaries directory
    mkdir -p "$TEMP_DIR/bin"

    # Mock ssh — always succeeds
    cat > "$TEMP_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Mock ssh — log call and return success
echo "$@" >> "${MOCK_SSH_LOG:-/dev/null}"
# If asked for uptime, return mock data
if echo "$@" | grep -q "uptime"; then
    echo " 10:00  up 5 days, 12:30, 2 users, load averages: 1.50 2.00 1.75"
    exit 0
fi
# If asked for nproc, return mock data
if echo "$@" | grep -q "nproc\|sysctl"; then
    echo "8"
    exit 0
fi
# If asked for free/memory, return mock data
if echo "$@" | grep -q "free\|vm_stat\|sysctl.*memsize"; then
    echo "34359738368"
    exit 0
fi
exit 0
EOF
    chmod +x "$TEMP_DIR/bin/ssh"

    # Mock jq — use real jq
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}${BOLD}✗${RESET} jq is required for remote tests"
        exit 1
    fi
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

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
# 1. Add machine creates machines.json
# ──────────────────────────────────────────────────────────────────────────────
test_add_machine() {
    rm -f "$TEMP_DIR/home/.shipwright/machines.json"

    HOME="$TEMP_DIR/home" \
    PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/sw-remote.sh" add "builder-1" \
            --host "localhost" \
            --path "$TEMP_DIR/mock-install" \
            --user "deploy" \
            --max-workers 4 2>/dev/null

    local machines_file="$TEMP_DIR/home/.shipwright/machines.json"
    if [[ ! -f "$machines_file" ]]; then
        echo -e "    ${RED}✗${RESET} machines.json not created"
        return 1
    fi

    local name
    name=$(jq -r '.machines[0].name' "$machines_file")
    if [[ "$name" != "builder-1" ]]; then
        echo -e "    ${RED}✗${RESET} Expected name 'builder-1', got: '$name'"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Add second machine appends to array
# ──────────────────────────────────────────────────────────────────────────────
test_add_second_machine() {
    # First machine should still be there
    HOME="$TEMP_DIR/home" \
    PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/sw-remote.sh" add "builder-2" \
            --host "localhost" \
            --path "$TEMP_DIR/mock-install" \
            --max-workers 8 2>/dev/null

    local machines_file="$TEMP_DIR/home/.shipwright/machines.json"
    local count
    count=$(jq '.machines | length' "$machines_file")
    if [[ "$count" -ne 2 ]]; then
        echo -e "    ${RED}✗${RESET} Expected 2 machines, got: $count"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Remove machine by name
# ──────────────────────────────────────────────────────────────────────────────
test_remove_machine() {
    HOME="$TEMP_DIR/home" \
    PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/sw-remote.sh" remove "builder-2" 2>/dev/null

    local machines_file="$TEMP_DIR/home/.shipwright/machines.json"
    local count
    count=$(jq '.machines | length' "$machines_file")
    if [[ "$count" -ne 1 ]]; then
        echo -e "    ${RED}✗${RESET} Expected 1 machine after remove, got: $count"
        return 1
    fi

    # Remaining machine should be builder-1
    local remaining
    remaining=$(jq -r '.machines[0].name' "$machines_file")
    if [[ "$remaining" != "builder-1" ]]; then
        echo -e "    ${RED}✗${RESET} Wrong machine remaining: $remaining"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. List machines returns valid JSON
# ──────────────────────────────────────────────────────────────────────────────
test_list_machines() {
    local output
    output=$(HOME="$TEMP_DIR/home" \
        bash "$TEMP_DIR/scripts/sw-remote.sh" list 2>/dev/null)

    # Should contain machine info
    if printf '%s\n' "$output" | grep -q "builder-1" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} List output missing machine info"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. machines.json atomic write (tmp + mv)
# ──────────────────────────────────────────────────────────────────────────────
test_atomic_write() {
    # The remote script should use atomic writes (look for tmp_file + mv pattern)
    local script="$TEMP_DIR/scripts/sw-remote.sh"
    if grep -q "tmp_file" "$script" 2>/dev/null && grep -q "mv " "$script" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Remote script doesn't appear to use atomic writes"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Duplicate machine name prevented
# ──────────────────────────────────────────────────────────────────────────────
test_duplicate_machine_prevented() {
    local exit_code=0
    HOME="$TEMP_DIR/home" \
    PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/sw-remote.sh" add "builder-1" \
            --host "localhost" \
            --path "$TEMP_DIR/mock-install" 2>/dev/null || exit_code=$?

    # Should fail because builder-1 already exists
    if [[ "$exit_code" -eq 0 ]]; then
        # Check that it didn't add a duplicate
        local machines_file="$TEMP_DIR/home/.shipwright/machines.json"
        local count
        count=$(jq '[.machines[] | select(.name == "builder-1")] | length' "$machines_file" 2>/dev/null || echo 0)
        if [[ "$count" -gt 1 ]]; then
            echo -e "    ${RED}✗${RESET} Duplicate machine added"
            return 1
        fi
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Remote script has help command
# ──────────────────────────────────────────────────────────────────────────────
test_remote_help() {
    local exit_code=0
    local output
    output=$(bash "$TEMP_DIR/scripts/sw-remote.sh" help 2>&1) || exit_code=$?

    if printf '%s\n' "$output" | grep -qi "usage\|remote\|machine" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Help output missing expected content"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. CLI router includes remote command
# ──────────────────────────────────────────────────────────────────────────────
test_cli_router_remote() {
    local router="$SCRIPT_DIR/sw"
    if grep -q 'remote)' "$router" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} CLI router missing 'remote' command"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. CLI router includes heartbeat command
# ──────────────────────────────────────────────────────────────────────────────
test_cli_router_heartbeat() {
    local router="$SCRIPT_DIR/sw"
    if grep -q 'heartbeat)' "$router" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} CLI router missing 'heartbeat' command"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. CLI router includes checkpoint command
# ──────────────────────────────────────────────────────────────────────────────
test_cli_router_checkpoint() {
    local router="$SCRIPT_DIR/sw"
    if grep -q 'checkpoint)' "$router" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} CLI router missing 'checkpoint' command"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Doctor has heartbeat health check
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_heartbeat_check() {
    local doctor="$SCRIPT_DIR/sw-doctor.sh"
    if grep -q "HEARTBEATS" "$doctor" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Doctor missing heartbeat health check"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Doctor has remote machine checks
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_remote_check() {
    local doctor="$SCRIPT_DIR/sw-doctor.sh"
    if grep -q "REMOTE MACHINES" "$doctor" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Doctor missing remote machine health checks"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Status shows heartbeat section
# ──────────────────────────────────────────────────────────────────────────────
test_status_heartbeat_section() {
    local status="$SCRIPT_DIR/sw-status.sh"
    if grep -q "AGENT HEARTBEATS" "$status" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Status missing heartbeat section"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Status shows remote machines section
# ──────────────────────────────────────────────────────────────────────────────
test_status_remote_section() {
    local status="$SCRIPT_DIR/sw-status.sh"
    if grep -q "REMOTE MACHINES" "$status" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Status missing remote machines section"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright remote — Test Suite                   ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for remote tests"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# Machine registry tests
echo -e "${PURPLE}${BOLD}Machine Registry${RESET}"
run_test "Add machine creates machines.json" test_add_machine
run_test "Add second machine appends to array" test_add_second_machine
run_test "Remove machine by name" test_remove_machine
run_test "List machines returns output" test_list_machines
run_test "machines.json uses atomic writes" test_atomic_write
run_test "Duplicate machine name prevented" test_duplicate_machine_prevented
run_test "Remote script has help command" test_remote_help
echo ""

# Integration tests
echo -e "${PURPLE}${BOLD}CLI & Dashboard Integration${RESET}"
run_test "CLI router includes remote command" test_cli_router_remote
run_test "CLI router includes heartbeat command" test_cli_router_heartbeat
run_test "CLI router includes checkpoint command" test_cli_router_checkpoint
run_test "Doctor has heartbeat health check" test_doctor_heartbeat_check
run_test "Doctor has remote machine checks" test_doctor_remote_check
run_test "Status shows heartbeat section" test_status_heartbeat_section
run_test "Status shows remote machines section" test_status_remote_section
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
