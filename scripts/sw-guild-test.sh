#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright guild test — Knowledge guilds & cross-team learning tests    ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-guild-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/guilds"
    mkdir -p "$TEMP_DIR/bin"

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

    # Mock sed -i (macOS compat)
    # The guild script uses sed -i "" which works on macOS

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
echo -e "${CYAN}${BOLD}  Shipwright Guild Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-guild.sh" help 2>&1) || true
assert_contains "help shows usage text" "$output" "shipwright guild"

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-guild.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-guild.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "COMMANDS"

# ─── Test 4: No args shows help ──────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-guild.sh" 2>&1) || true
assert_contains "no args shows help" "$output" "USAGE"

# ─── Test 5: List guilds ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-guild.sh" list 2>&1) || true
assert_contains "list shows Available Guilds" "$output" "Available Guilds"

# ─── Test 6: Config file created ─────────────────────────────────────────────
if [[ -f "$HOME/.shipwright/guilds/config.json" ]]; then
    assert_pass "guild config.json created"
else
    assert_fail "guild config.json created"
fi

# ─── Test 7: Config is valid JSON ────────────────────────────────────────────
if jq '.' "$HOME/.shipwright/guilds/config.json" >/dev/null 2>&1; then
    assert_pass "guild config is valid JSON"
else
    assert_fail "guild config is valid JSON"
fi

# ─── Test 8: Data file created ───────────────────────────────────────────────
if [[ -f "$HOME/.shipwright/guilds/guilds.json" ]]; then
    assert_pass "guilds.json data file created"
else
    assert_fail "guilds.json data file created"
fi

# ─── Test 9: Show valid guild ────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-guild.sh" show security 2>&1) || true
assert_contains "show security guild" "$output" "security"

# ─── Test 10: Show invalid guild fails ───────────────────────────────────────
if bash "$SCRIPT_DIR/sw-guild.sh" show nonexistent >/dev/null 2>&1; then
    assert_fail "show invalid guild exits nonzero"
else
    assert_pass "show invalid guild exits nonzero"
fi

# ─── Test 11: Show without name fails ────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-guild.sh" show >/dev/null 2>&1; then
    assert_fail "show without name exits nonzero"
else
    assert_pass "show without name exits nonzero"
fi

# ─── Test 12: Add pattern ────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-guild.sh" add pattern security "Test pattern" "A test description" 2>&1) || true
assert_contains "add pattern succeeds" "$output" "Pattern added"

# ─── Test 13: Pattern persisted in data ───────────────────────────────────────
pattern_count=$(jq '.patterns.security | length' "$HOME/.shipwright/guilds/guilds.json" 2>/dev/null)
assert_eq "pattern saved in data file" "1" "$pattern_count"

# ─── Test 14: Report shows stats ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-guild.sh" report 2>&1) || true
assert_contains "report shows guild data" "$output" "Guild Knowledge Growth"

# ─── Test 15: Report for specific guild ───────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-guild.sh" report security 2>&1) || true
assert_contains "report for specific guild" "$output" "Guild Report"

# ─── Test 16: Inject for known task type ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-guild.sh" inject security 2>&1) || true
assert_contains "inject security shows knowledge" "$output" "Security Guild Knowledge"

# ─── Test 17: Unknown command fails ──────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-guild.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown command exits nonzero"
else
    assert_pass "unknown command exits nonzero"
fi

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
