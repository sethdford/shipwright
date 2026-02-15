#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright autonomous test — AI-building-AI master controller tests     ║
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

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-autonomous-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/autonomous"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.claude"
    mkdir -p "$TEMP_DIR/repo/.git"
    mkdir -p "$TEMP_DIR/repo/scripts"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock claude (not available — triggers static heuristics)
    # Intentionally NOT providing claude mock to test fallback path

    # Mock find (for static heuristics)
    cat > "$TEMP_DIR/bin/find" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/find"

    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() {
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

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
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

assert_contains_regex() {
    local desc="$1" haystack="$2" pattern="$3"
    if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing pattern: $pattern"
    fi
}

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Autonomous Tests${RESET}"
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

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
else
    echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
    for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done
fi
echo ""
exit "$FAIL"
