#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost test — Validate token usage & cost intelligence         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock sqlite3
    cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo ""
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/sqlite3"

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

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Cost Tests"
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
bash "$SCRIPT_DIR/sw-cost.sh" show >/dev/null 2>&1 || true
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

# ─── Test: context efficiency section in dashboard ─────────────────────────
echo ""
echo -e "${DIM}  context efficiency in cost dashboard${RESET}"

if grep -q 'CONTEXT EFFICIENCY' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Cost dashboard has CONTEXT EFFICIENCY section"
else
    assert_fail "Cost dashboard has CONTEXT EFFICIENCY section"
fi

if grep -q 'loop.context_efficiency' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Cost dashboard reads loop.context_efficiency events"
else
    assert_fail "Cost dashboard reads loop.context_efficiency events"
fi

if grep -q 'Avg budget used' "$SCRIPT_DIR/sw-cost.sh" && grep -q 'Chars discarded' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Context efficiency reports utilization and waste"
else
    assert_fail "Context efficiency reports utilization and waste"
fi

# Functional test: write mock events and verify dashboard parses them
mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
cat > "$TEST_TEMP_DIR/home/.shipwright/events.jsonl" <<'EVTEOF'
{"ts":"2026-02-27T10:00:00Z","type":"loop.context_efficiency","iteration":"1","raw_prompt_chars":"200000","trimmed_prompt_chars":"180000","trim_ratio":"10.0","budget_utilization":"100.0","budget_chars":"180000","job_id":"test-1"}
{"ts":"2026-02-27T10:01:00Z","type":"loop.context_efficiency","iteration":"2","raw_prompt_chars":"150000","trimmed_prompt_chars":"150000","trim_ratio":"0.0","budget_utilization":"83.3","budget_chars":"180000","job_id":"test-1"}
EVTEOF

# Also need cost data for the dashboard to run
cat > "$TEST_TEMP_DIR/home/.shipwright/costs.json" <<'COSTEOF'
{"entries":[{"ts":"2026-02-27T10:00:00Z","ts_epoch":1772125200,"input_tokens":50000,"output_tokens":10000,"cost_usd":1.50,"model":"opus","stage":"build","issue":"1"}],"summary":{}}
COSTEOF
cat > "$TEST_TEMP_DIR/home/.shipwright/budget.json" <<'BUDEOF'
{"daily_budget_usd":0,"enabled":false}
BUDEOF

dash_output=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" show --period 30 2>&1) || true

if echo "$dash_output" | grep -q "CONTEXT EFFICIENCY"; then
    assert_pass "Dashboard renders CONTEXT EFFICIENCY with event data"
else
    assert_fail "Dashboard renders CONTEXT EFFICIENCY with event data" "output: $(echo "$dash_output" | tail -5)"
fi

if echo "$dash_output" | grep -q "Avg budget used"; then
    assert_pass "Dashboard shows avg budget utilization"
else
    assert_fail "Dashboard shows avg budget utilization"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
