#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright mission-control test — Validate mission control dashboard    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/sqlite3"
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    log) echo "abc1234 fix: something" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) echo "main: 1 windows" ;;
    list-panes|list-windows) echo "" ;;
    new-window|split-window|send-keys) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Mission Control Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help ────────────────────────────────────────────────────
echo -e "${BOLD}  Help & Navigation${RESET}"
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "USAGE"

# ─── Test 3: Unknown command ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: Show overview with empty state ──────────────────────────
echo -e "${BOLD}  Overview${RESET}"
echo '{"active_jobs":[],"completed":[],"failed":[],"pid":0,"started_at":"","titles":{},"queued":[]}' > "$HOME/.shipwright/daemon-state.json"
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" show 2>&1) || true
assert_contains "overview shows MISSION CONTROL header" "$output" "MISSION CONTROL"
assert_contains "overview shows Summary Statistics" "$output" "Summary Statistics"
assert_contains "overview shows Active Pipelines" "$output" "Active Pipelines"

# ─── Test 5: Show with active jobs ───────────────────────────────────
echo '{"active_jobs":[{"issue":42,"title":"Test issue","worktree":"/tmp/wt","pid":12345,"started_at":"2026-01-01T00:00:00Z"}],"completed":[],"failed":[],"pid":0,"started_at":"","titles":{},"queued":[]}' > "$HOME/.shipwright/daemon-state.json"
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" show 2>&1) || true
assert_contains "overview with active job shows count" "$output" "1"

# ─── Test 6: Agents shows team hierarchy ─────────────────────────────
echo -e "${BOLD}  Agent Tree${RESET}"
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" agents 2>&1) || true
assert_contains "agents shows hierarchy" "$output" "Agent Team Hierarchy"
assert_contains "agents shows Pipeline Agent" "$output" "Pipeline Agent"

# ─── Test 7: Resources shows utilization ─────────────────────────────
echo -e "${BOLD}  Resources${RESET}"
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" resources 2>&1) || true
assert_contains "resources shows utilization" "$output" "Resource Utilization"

# ─── Test 8: Alerts with no events ───────────────────────────────────
echo -e "${BOLD}  Alerts${RESET}"
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" alerts 2>&1) || true
assert_contains "alerts shows alert feed" "$output" "Alert Feed"

# ─── Test 9: Pause without args exits nonzero ───────────────────────
echo -e "${BOLD}  Stage Commands${RESET}"
if bash "$SCRIPT_DIR/sw-mission-control.sh" pause >/dev/null 2>&1; then
    assert_fail "pause without id exits nonzero"
else
    assert_pass "pause without id exits nonzero"
fi

# ─── Test 10: Pause with valid ID ───────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" pause 42 2>&1) || true
assert_contains "pause emits success" "$output" "Pipeline paused"

# ─── Test 11: Resume without args exits nonzero ─────────────────────
if bash "$SCRIPT_DIR/sw-mission-control.sh" resume >/dev/null 2>&1; then
    assert_fail "resume without id exits nonzero"
else
    assert_pass "resume without id exits nonzero"
fi

# ─── Test 12: Resume with valid ID ──────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" resume 42 2>&1) || true
assert_contains "resume emits success" "$output" "Pipeline resumed"

# ─── Test 13: Skip requires run-id and stage ────────────────────────
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" skip 42 2>&1) || true
assert_contains "skip without stage shows usage" "$output" "Usage"

# ─── Test 14: Skip with valid args ──────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" skip 42 build 2>&1) || true
assert_contains "skip emits success" "$output" "Stage skipped"

# ─── Test 15: Retry with valid args ─────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-mission-control.sh" retry 42 build 2>&1) || true
assert_contains "retry emits success" "$output" "Stage retry scheduled"

echo ""
echo ""
print_test_results
