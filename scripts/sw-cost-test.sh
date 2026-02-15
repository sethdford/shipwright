#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost test — Validate token usage & cost intelligence         ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-cost-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Mock sqlite3
    cat > "$TEMP_DIR/bin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo ""
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/sqlite3"

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
    if printf '%s\n' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Cost Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help shows COMMANDS" "$output" "COMMANDS"
assert_contains "help mentions show" "$output" "show"
assert_contains "help mentions budget" "$output" "budget"
assert_contains "help mentions calculate" "$output" "calculate"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep '^VERSION=' "$SCRIPT_DIR/sw-cost.sh" | head -1)
if [[ -n "$version_line" ]]; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: cost dir creation ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  state management${RESET}"

# Running 'show' should create cost files
bash "$SCRIPT_DIR/sw-cost.sh" show 2>&1 >/dev/null || true
if [[ -f "$HOME/.shipwright/costs.json" ]]; then
    assert_pass "costs.json created on first use"
else
    assert_fail "costs.json created on first use"
fi
if [[ -f "$HOME/.shipwright/budget.json" ]]; then
    assert_pass "budget.json created on first use"
else
    assert_fail "budget.json created on first use"
fi

# ─── Test 4: costs.json has valid structure ─────────────────────────────────
cost_valid=$(jq -e '.entries' "$HOME/.shipwright/costs.json" >/dev/null 2>&1&& echo "yes" || echo "no")
assert_eq "costs.json has entries array" "yes" "$cost_valid"

# ─── Test 5: budget.json has valid structure ────────────────────────────────
budget_valid=$(jq -e '.daily_budget_usd' "$HOME/.shipwright/budget.json" >/dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "budget.json has daily_budget_usd" "yes" "$budget_valid"

# ─── Test 6: budget set command ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  budget commands${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" budget set 50.00 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "budget set exits 0"
else
    assert_fail "budget set exits 0" "exit code: $rc"
fi

# Verify budget was written
budget_val=$(jq -r '.daily_budget_usd' "$HOME/.shipwright/budget.json" 2>/dev/null || echo "")
assert_eq "budget set to 50" "50.00" "$budget_val"

# ─── Test 7: budget show command ────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-cost.sh" budget show 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "budget show exits 0"
else
    assert_fail "budget show exits 0" "exit code: $rc"
fi

# ─── Test 8: unknown command exits non-zero ─────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 9: calculate command ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  calculate${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" calculate 50000 10000 opus 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "calculate exits 0"
else
    assert_fail "calculate exits 0" "exit code: $rc"
fi

# ─── Test 10: set -euo pipefail ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

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
