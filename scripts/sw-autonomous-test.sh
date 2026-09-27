#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright autonomous test — AI-building-AI master controller tests     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/autonomous"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock claude (not available — triggers static heuristics)
    # Intentionally NOT providing claude mock to test fallback path

    # Mock find (for static heuristics)
    cat > "$TEST_TEMP_DIR/bin/find" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/find"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() {
    local desc="$1"
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

echo ""
print_test_header "Shipwright Autonomous Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-autonomous.sh" help 2>&1) || true
assert_contains "help shows usage text" "$output" "USAGE"

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-autonomous.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-autonomous.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "COMMANDS"

# ─── Test 4: Unknown command exits 1 ─────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-autonomous.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown command exits 1"
else
    assert_pass "unknown command exits 1"
fi

# ─── Test 5: Start creates state ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-autonomous.sh" start 2>&1) || true
assert_contains "start shows running message" "$output" "Starting autonomous loop"

# ─── Test 6: State file created ──────────────────────────────────────────────
if [[ -f "$HOME/.shipwright/autonomous/state.json" ]]; then
    assert_pass "state.json created after start"
else
    assert_fail "state.json created after start"
fi

# ─── Test 7: State shows running ─────────────────────────────────────────────
status=$(jq -r '.status' "$HOME/.shipwright/autonomous/state.json" 2>/dev/null)
assert_eq "state status is running" "running" "$status"

# ─── Test 8: Config file created ─────────────────────────────────────────────
if [[ -f "$HOME/.shipwright/autonomous/config.json" ]]; then
    assert_pass "config.json created"
else
    assert_fail "config.json created"
fi

# ─── Test 9: Config is valid JSON ────────────────────────────────────────────
if jq '.' "$HOME/.shipwright/autonomous/config.json" >/dev/null 2>&1; then
    assert_pass "config is valid JSON"
else
    assert_fail "config is valid JSON"
fi

# ─── Test 10: Status shows dashboard ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-autonomous.sh" status 2>&1) || true
assert_contains "status shows dashboard" "$output" "Autonomous Loop Status"

# ─── Test 11: Pause changes state ────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-autonomous.sh" pause >/dev/null 2>&1 || true
status=$(jq -r '.status' "$HOME/.shipwright/autonomous/state.json" 2>/dev/null)
assert_eq "pause sets status to paused" "paused" "$status"

# ─── Test 12: Resume changes state ───────────────────────────────────────────
bash "$SCRIPT_DIR/sw-autonomous.sh" resume >/dev/null 2>&1 || true
status=$(jq -r '.status' "$HOME/.shipwright/autonomous/state.json" 2>/dev/null)
assert_eq "resume sets status to running" "running" "$status"

# ─── Test 13: Stop changes state ─────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-autonomous.sh" stop >/dev/null 2>&1 || true
status=$(jq -r '.status' "$HOME/.shipwright/autonomous/state.json" 2>/dev/null)
assert_eq "stop sets status to stopped" "stopped" "$status"

# ─── Test 14: Config show displays settings ───────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-autonomous.sh" config show 2>&1) || true
assert_contains "config show displays settings" "$output" "cycle_interval_minutes"

# ─── Test 15: Config set interval ────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-autonomous.sh" config set interval 30 >/dev/null 2>&1 || true
interval=$(jq -r '.cycle_interval_minutes' "$HOME/.shipwright/autonomous/config.json" 2>/dev/null)
assert_eq "config set interval works" "30" "$interval"

# ─── Test 16: History with no data ───────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-autonomous.sh" history 2>&1) || true
assert_contains "history handles no data" "$output" "No cycle history"

# ─── Test 17: Config set/show cycle (persistence) ─────────────────────────────
echo ""
echo -e "${BOLD}  Config Set/Show Cycle${RESET}"
bash "$SCRIPT_DIR/sw-autonomous.sh" config set interval 45 >/dev/null 2>&1 || true
output=$(bash "$SCRIPT_DIR/sw-autonomous.sh" config show 2>&1) || true
assert_contains "config show reflects set value" "$output" "45"
interval_val=$(jq -r '.cycle_interval_minutes' "$HOME/.shipwright/autonomous/config.json" 2>/dev/null)
assert_eq "config value persists in file" "45" "$interval_val"

# ─── Test 18: Config.json contains expected keys ─────────────────────────────
echo ""
echo -e "${BOLD}  Config Structure${RESET}"
for key in cycle_interval_minutes max_issues_per_cycle daemon_aware; do
    if jq -e ".$key" "$HOME/.shipwright/autonomous/config.json" >/dev/null 2>&1; then
        assert_pass "config contains key: $key"
    else
        assert_fail "config contains key: $key"
    fi
done

# ─── Test 19: History with fixture events ───────────────────────────────────
echo ""
echo -e "${BOLD}  History With Fixture Events${RESET}"
mkdir -p "$HOME/.shipwright/autonomous"
echo '{"ts":"2026-02-15T10:00:00Z","found":3,"created":2,"status":"success"}' >> "$HOME/.shipwright/autonomous/history.jsonl"
echo '{"ts":"2026-02-15T11:00:00Z","found":1,"created":0,"status":"success"}' >> "$HOME/.shipwright/autonomous/history.jsonl"
output=$(bash "$SCRIPT_DIR/sw-autonomous.sh" history 2>&1) || true
assert_contains "history shows recent cycles" "$output" "Recent Cycles"
assert_contains "history shows cycle entries" "$output" "2026-02-15"

# ─── Test 20: Status output includes expected fields (running vs stopped) ─────
echo ""
echo -e "${BOLD}  Status Fields${RESET}"
bash "$SCRIPT_DIR/sw-autonomous.sh" start >/dev/null 2>&1 || true
output=$(bash "$SCRIPT_DIR/sw-autonomous.sh" status 2>&1) || true
assert_contains "status when running includes Status" "$output" "Status"
assert_contains "status when running includes Cycles" "$output" "Cycles"
assert_contains "status when running includes Issues Created" "$output" "Issues Created"
assert_contains "status when running includes Pipelines" "$output" "Pipelines"
assert_contains "status when running includes Cycle Interval" "$output" "Cycle Interval"
assert_contains "status when running shows running" "$output" "running"
bash "$SCRIPT_DIR/sw-autonomous.sh" stop >/dev/null 2>&1 || true
output=$(bash "$SCRIPT_DIR/sw-autonomous.sh" status 2>&1) || true
assert_contains "status when stopped shows stopped" "$output" "stopped"

echo ""
echo ""
print_test_results
