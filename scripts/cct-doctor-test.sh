#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright doctor test — Validate doctor checks including dashboard    ║
# ║  dependency validation, port availability, and asset verification.      ║
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
# TESTS — Doctor Script Structure
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Doctor script exists and is executable
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_exists() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    [[ -f "$doctor" && -x "$doctor" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Doctor has DASHBOARD section
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_has_dashboard_section() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "DASHBOARD" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Doctor checks for Bun runtime
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_checks_bun() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "command -v bun" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Doctor checks dashboard server.ts
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_checks_server_ts() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "server.ts" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Doctor checks dashboard public assets
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_checks_public_assets() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "index.html" "$doctor" 2>/dev/null && \
    grep -q "app.js" "$doctor" 2>/dev/null && \
    grep -q "styles.css" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Doctor checks port availability
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_checks_port() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "PORT_IN_USE" "$doctor" 2>/dev/null || \
    grep -q "port.*available" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Doctor checks dashboard PID file
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_checks_dashboard_pid() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "dashboard.pid" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Doctor uses default port 8767
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_uses_default_port() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "8767" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Doctor has HEARTBEATS section
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_has_heartbeats() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "HEARTBEATS" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Doctor has REMOTE MACHINES section
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_has_remote_machines() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "REMOTE MACHINES" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Doctor uses multiple port-check methods (lsof, ss, netstat)
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_port_check_fallbacks() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "command -v lsof" "$doctor" 2>/dev/null && \
    grep -q "command -v ss" "$doctor" 2>/dev/null && \
    grep -q "command -v netstat" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Doctor searches multiple dashboard install locations
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_searches_multiple_locations() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    grep -q "local/share/shipwright/dashboard" "$doctor" 2>/dev/null && \
    grep -q ".shipwright/dashboard" "$doctor" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Doctor script runs without errors (smoke test)
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_runs() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    # Run doctor and check it exits cleanly (exit 0 = all pass, nonzero = warnings/fails ok)
    local output
    output=$("$doctor" 2>&1) || true
    # Verify it at least produced output with the header
    echo "$output" | grep -q "Claude Code Teams" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Doctor output includes Dashboard section
# ──────────────────────────────────────────────────────────────────────────────
test_doctor_output_has_dashboard() {
    local doctor="$SCRIPT_DIR/cct-doctor.sh"
    local output
    output=$("$doctor" 2>&1) || true
    echo "$output" | grep -q "DASHBOARD" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright doctor — Test Suite                   ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Script structure tests
echo -e "${PURPLE}${BOLD}Script Structure${RESET}"
run_test "Doctor script exists and is executable" test_doctor_exists
run_test "Doctor has DASHBOARD section" test_doctor_has_dashboard_section
run_test "Doctor has HEARTBEATS section" test_doctor_has_heartbeats
run_test "Doctor has REMOTE MACHINES section" test_doctor_has_remote_machines
echo ""

# Dashboard dependency checks
echo -e "${PURPLE}${BOLD}Dashboard Dependency Checks${RESET}"
run_test "Doctor checks for Bun runtime" test_doctor_checks_bun
run_test "Doctor checks dashboard server.ts" test_doctor_checks_server_ts
run_test "Doctor checks dashboard public assets" test_doctor_checks_public_assets
echo ""

# Port availability checks
echo -e "${PURPLE}${BOLD}Port Availability Checks${RESET}"
run_test "Doctor checks port availability" test_doctor_checks_port
run_test "Doctor uses default port 8767" test_doctor_uses_default_port
run_test "Doctor checks dashboard PID file" test_doctor_checks_dashboard_pid
run_test "Doctor has port check fallbacks (lsof/ss/netstat)" test_doctor_port_check_fallbacks
run_test "Doctor searches multiple dashboard locations" test_doctor_searches_multiple_locations
echo ""

# Smoke tests (actually run the doctor)
echo -e "${PURPLE}${BOLD}Smoke Tests${RESET}"
run_test "Doctor script runs without errors" test_doctor_runs
run_test "Doctor output includes Dashboard section" test_doctor_output_has_dashboard
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
