#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright stream test — Live terminal output streaming                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-stream-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"
    cat > "$TEMP_DIR/bin/tmux" <<'MOCK'
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
    chmod +x "$TEMP_DIR/bin/tmux"
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Stream Tests${RESET}"
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
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
