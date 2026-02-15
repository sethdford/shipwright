#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright swarm test — Dynamic agent swarm management tests            ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-swarm-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
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
    log) echo "abc1234 fix: something" ;;
    diff) echo "" ;;
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

    # Mock claude
    cat > "$TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/claude"

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
echo -e "${CYAN}${BOLD}  Shipwright Swarm Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" help 2>&1) || true
if echo "$output" | grep -q "shipwright swarm"; then
    assert_pass "help shows usage text"
else
    assert_fail "help shows usage text"
fi

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-swarm.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "COMMANDS"

# ─── Test 4: Status with empty registry ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" status 2>&1) || true
assert_contains "status shows empty swarm" "$output" "No agents in swarm"

# ─── Test 5: Spawn creates agent in registry ─────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" spawn standard 2>&1) || true
assert_contains "spawn standard creates agent" "$output" "Spawned agent"

# ─── Test 6: Registry file exists after spawn ────────────────────────────────
if [[ -f "$HOME/.shipwright/swarm/registry.json" ]]; then
    assert_pass "registry.json exists after spawn"
else
    assert_fail "registry.json exists after spawn"
fi

# ─── Test 7: Registry has active_count 1 ─────────────────────────────────────
active_count=$(jq -r '.active_count' "$HOME/.shipwright/swarm/registry.json" 2>/dev/null)
assert_eq "active_count is 1 after spawn" "1" "$active_count"

# ─── Test 8: Config file initialized ─────────────────────────────────────────
if [[ -f "$HOME/.shipwright/swarm/config.json" ]]; then
    assert_pass "config.json exists after operations"
else
    assert_fail "config.json exists after operations"
fi

# ─── Test 9: Spawn invalid type fails ────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" spawn nonexistent 2>&1) || true
assert_contains "spawn invalid type returns error" "$output" "Invalid agent type"

# ─── Test 10: Health check with agents ───────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" health 2>&1) || true
assert_contains "health shows agent status" "$output" "Agent Health Status"

# ─── Test 11: Top leaderboard ────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" top 2>&1) || true
assert_contains "top shows leaderboard" "$output" "Agent Performance Leaderboard"

# ─── Test 12: Config show ────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" config show 2>&1) || true
assert_contains "config show displays settings" "$output" "auto_scaling_enabled"

# ─── Test 13: Config set ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" config set max_agents 12 2>&1) || true
new_val=$(jq -r '.max_agents' "$HOME/.shipwright/swarm/config.json" 2>/dev/null)
assert_eq "config set updates value" "12" "$new_val"

# ─── Test 14: Config reset ───────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-swarm.sh" config reset >/dev/null 2>&1 || true
reset_val=$(jq -r '.max_agents' "$HOME/.shipwright/swarm/config.json" 2>/dev/null)
assert_eq "config reset restores defaults" "8" "$reset_val"

# ─── Test 15: Unknown command exits 1 ────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-swarm.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown command exits 1"
else
    assert_pass "unknown command exits 1"
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
