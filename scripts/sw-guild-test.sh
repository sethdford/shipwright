#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright guild test — Knowledge guilds & cross-team learning tests    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/guilds"
    mkdir -p "$TEST_TEMP_DIR/bin"

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

    # Mock sed -i (macOS compat)
    # The guild script uses sed -i "" which works on macOS

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
print_test_header "Shipwright Guild Tests"
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
echo ""
print_test_results
