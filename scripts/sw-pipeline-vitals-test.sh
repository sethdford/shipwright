#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright vitals test — Validate pipeline health scoring               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/progress"
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/optimization"
    mkdir -p "$TEST_TEMP_DIR/home/.claude/pipeline-artifacts"
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

    # Create empty state files
    echo '{"entries":[],"summary":{}}' > "$TEST_TEMP_DIR/home/.shipwright/costs.json"
    echo '{"daily_budget_usd":0,"enabled":false}' > "$TEST_TEMP_DIR/home/.shipwright/budget.json"

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
print_test_header "Shipwright Pipeline Vitals Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: --help flag ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-pipeline-vitals.sh" --help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "--help exits 0"
else
    assert_fail "--help exits 0" "exit code: $rc"
fi
assert_contains "--help shows USAGE" "$output" "USAGE"
assert_contains "--help shows OPTIONS" "$output" "OPTIONS"
assert_contains "--help mentions --json" "$output" "--json"
assert_contains "--help mentions --score" "$output" "--score"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
if grep -q '^VERSION=' "$SCRIPT_DIR/sw-pipeline-vitals.sh"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: --json outputs valid JSON ──────────────────────────────────────
echo ""
echo -e "${DIM}  json output${RESET}"

output=$(bash "$SCRIPT_DIR/sw-pipeline-vitals.sh" --json 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "--json exits 0"
else
    assert_fail "--json exits 0" "exit code: $rc"
fi

# The whole output should be valid JSON
if printf '%s\n' "$output" | jq . >/dev/null 2>&1; then
    assert_pass "--json outputs valid JSON"
else
    assert_fail "--json outputs valid JSON" "output: $output"
fi

# ─── Test 4: --score outputs a number ───────────────────────────────────────
echo ""
echo -e "${DIM}  score output${RESET}"

output=$(bash "$SCRIPT_DIR/sw-pipeline-vitals.sh" --score 2>&1) && rc=0 || rc=$?
# The score should be a number 0-100
score_val=$(printf '%s\n' "$output" | grep -oE '^[0-9]+$' | head -1)
if [[ -n "$score_val" && "$score_val" -ge 0 && "$score_val" -le 100 ]]; then
    assert_pass "--score outputs valid number (${score_val})"
else
    assert_fail "--score outputs valid number" "output: $output"
fi

# ─── Test 5: script safety ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-pipeline-vitals.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-pipeline-vitals.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ─── Test 6: signal weights defined ─────────────────────────────────────────
echo ""
echo -e "${DIM}  internals${RESET}"

if grep -q 'WEIGHT_MOMENTUM' "$SCRIPT_DIR/sw-pipeline-vitals.sh"; then
    assert_pass "WEIGHT_MOMENTUM defined"
else
    assert_fail "WEIGHT_MOMENTUM defined"
fi

if grep -q 'WEIGHT_CONVERGENCE' "$SCRIPT_DIR/sw-pipeline-vitals.sh"; then
    assert_pass "WEIGHT_CONVERGENCE defined"
else
    assert_fail "WEIGHT_CONVERGENCE defined"
fi

# ─── Test 7: Source and test _compute_momentum with known data ─────────────────
echo ""
echo -e "${DIM}  _compute_momentum${RESET}"
# Create progress file with known snapshots
progress_file="$TEST_TEMP_DIR/home/.shipwright/progress/issue-1.json"
mkdir -p "$(dirname "$progress_file")"
cat > "$progress_file" <<'PROGEOF'
{
  "snapshots": [
    {"stage": "intake", "iteration": 0, "diff_lines": 0, "ts": "2024-01-01T00:00:00Z"},
    {"stage": "build", "iteration": 1, "diff_lines": 50, "ts": "2024-01-01T00:01:00Z"},
    {"stage": "build", "iteration": 2, "diff_lines": 120, "ts": "2024-01-01T00:02:00Z"}
  ],
  "no_progress_count": 0
}
PROGEOF
# Source script and call _compute_momentum (needs SCRIPT_DIR, compat, helpers)
result=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/lib/compat.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
source "$SCRIPT_DIR/sw-pipeline-vitals.sh" 2>/dev/null || true
_compute_momentum "$HOME/.shipwright/progress/issue-1.json" "build" 3 150
' 2>/dev/null)
if [[ -n "$result" && "$result" =~ ^[0-9]+$ && "$result" -ge 0 && "$result" -le 100 ]]; then
    assert_pass "_compute_momentum returns numeric score 0-100 (got: $result)"
else
    assert_fail "_compute_momentum returns numeric score" "got: $result"
fi

# ─── Test 8: _compute_convergence with known quality data ─────────────────────
echo ""
echo -e "${DIM}  _compute_convergence${RESET}"
err_log="$TEST_TEMP_DIR/home/.shipwright/progress/issue-1-errors.log"
touch "$err_log"
conv_result=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/lib/compat.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
source "$SCRIPT_DIR/sw-pipeline-vitals.sh" 2>/dev/null || true
_compute_convergence /dev/null "$HOME/.shipwright/progress/issue-1.json"
' 2>/dev/null)
if [[ -n "$conv_result" && "$conv_result" =~ ^[0-9]+$ ]]; then
    assert_pass "_compute_convergence returns numeric score (got: $conv_result)"
else
    assert_fail "_compute_convergence returns numeric score" "got: $conv_result"
fi

# ─── Test 9: pipeline_health_verdict returns valid verdicts ──────────────────
echo ""
echo -e "${DIM}  pipeline_health_verdict${RESET}"
for score in 80 55 35 15; do
    v=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/sw-pipeline-vitals.sh" 2>/dev/null || true
    pipeline_health_verdict '"$score"'
    ' 2>/dev/null)
    if [[ "$v" == "continue" || "$v" == "warn" || "$v" == "intervene" || "$v" == "abort" ]]; then
        assert_pass "pipeline_health_verdict($score) returns valid verdict: $v"
    else
        assert_fail "pipeline_health_verdict($score) returns valid verdict" "got: $v"
    fi
done

# ─── Test 10: WEIGHT_ constants are numeric ───────────────────────────────────
for w in WEIGHT_MOMENTUM WEIGHT_CONVERGENCE WEIGHT_BUDGET WEIGHT_ERROR_MATURITY; do
    val=$(grep -E "^${w}=" "$SCRIPT_DIR/sw-pipeline-vitals.sh" | head -1 | grep -oE '[0-9]+' | head -1)
    if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
        assert_pass "$w is numeric ($val)"
    else
        assert_fail "$w is numeric"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
