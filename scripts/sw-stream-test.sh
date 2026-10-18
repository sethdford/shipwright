#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright stream test — Live terminal output streaming                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions) echo "main: 1 windows" ;;
    list-panes) echo "" ;;
    list-windows) echo "" ;;
    display-message) echo "mock-agent" ;;
    capture-pane) echo "mock output line" ;;
    kill-session|kill-pane|kill-window) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap 'cleanup_test_env; sw_test_teardown' EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Stream Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-stream.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows start" "$output" "start"
assert_contains "help shows stop" "$output" "stop"
assert_contains "help shows watch" "$output" "watch"
assert_contains "help shows list" "$output" "list"
assert_contains "help shows replay" "$output" "replay"

# ─── Test 2: List with no streams ────────────────────────────────────────
echo ""
echo -e "${BOLD}  List Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-stream.sh" list 2>&1) || true
assert_contains "list shows no streams msg" "$output" "No active streams"

# ─── Test 3: Stop when not running ───────────────────────────────────────
echo ""
echo -e "${BOLD}  Stop Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-stream.sh" stop 2>&1) && rc=0 || rc=$?
assert_eq "stop when not running exits non-zero" "1" "$rc"
assert_contains "stop shows not running msg" "$output" "not running"

# ─── Test 4: Config set ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Config Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-stream.sh" config capture_interval_seconds 5 2>&1) || true
assert_contains "config set confirms update" "$output" "Config updated"
config_file="$HOME/.shipwright/stream-config.json"
if [[ -f "$config_file" ]]; then
    assert_pass "config creates config file"
    value=$(jq -r '.capture_interval_seconds' "$config_file")
    assert_eq "config persists interval value" "5" "$value"
else
    assert_fail "config creates config file" "file not found"
fi

# ─── Test 5: Config without key ──────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-stream.sh" config 2>&1) && rc=0 || rc=$?
assert_eq "config without key exits non-zero" "1" "$rc"
assert_contains "config without key shows usage" "$output" "Usage"

# ─── Test 6: Config unknown key ──────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-stream.sh" config unknown_key 42 2>&1) && rc=0 || rc=$?
assert_eq "config unknown key exits non-zero" "1" "$rc"
assert_contains "config unknown key shows error" "$output" "Unknown config key"

# ─── Test 7: Replay without args ─────────────────────────────────────────
echo ""
echo -e "${BOLD}  Replay Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-stream.sh" replay 2>&1) && rc=0 || rc=$?
assert_eq "replay without args exits non-zero" "1" "$rc"
assert_contains "replay shows usage" "$output" "Usage"

# ─── Test 8: Replay with missing stream data ─────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-stream.sh" replay myteam builder 2>&1) && rc=0 || rc=$?
assert_eq "replay missing data exits non-zero" "1" "$rc"
assert_contains "replay missing data shows error" "$output" "No stream data"

# ─── Test 9: Watch without team arg ──────────────────────────────────────
echo ""
echo -e "${BOLD}  Watch Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-stream.sh" watch 2>&1) && rc=0 || rc=$?
assert_eq "watch without team exits non-zero" "1" "$rc"
assert_contains "watch shows usage" "$output" "Usage"

# ─── Test 10: List with mock stream data ──────────────────────────────────
echo ""
echo -e "${BOLD}  List With Data${RESET}"
mkdir -p "$HOME/.shipwright/streams/myteam"
echo '{"timestamp":"2026-01-15T10:00:00Z","pane_id":"%0","agent_name":"builder","team":"myteam","content":"test"}' \
    > "$HOME/.shipwright/streams/myteam/builder.jsonl"
output=$(bash "$SCRIPT_DIR/sw-stream.sh" list 2>&1) || true
assert_contains "list shows active stream" "$output" "myteam"

# ─── Test 11: Unknown command ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-stream.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits non-zero" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

echo ""
echo ""
print_test_results
