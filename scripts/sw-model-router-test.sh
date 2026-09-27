#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright model-router test — Intelligent model routing & optimization ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

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
    # `chain execute` shells out to the claude CLI. Without a mock the suite
    # invoked the caller's real, authenticated CLI: it billed a live request,
    # returned prose where the test expected JSON, and blocked long enough to
    # trip the runner's per-suite timeout.
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Model Router Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows route" "$output" "route"
assert_contains "help shows escalate" "$output" "escalate"
assert_contains "help shows config" "$output" "config"

# ─── Test 2: Route model for intake (haiku stage) ────────────────────────
echo ""
echo -e "${BOLD}  Route Model${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route intake 50 2>&1)
assert_eq "route intake at 50 = haiku" "haiku" "$output"

# ─── Test 3: Route model for build (opus stage) ──────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route build 50 2>&1)
assert_eq "route build at 50 = opus" "opus" "$output"

# ─── Test 4: Route model for test (sonnet stage) ─────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route test 50 2>&1)
assert_eq "route test at 50 = sonnet" "sonnet" "$output"

# ─── Test 5: Route model with low complexity override ─────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route build 10 2>&1)
assert_eq "route build at 10 (low) = sonnet" "sonnet" "$output"

# ─── Test 6: Route model with high complexity override ────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route intake 90 2>&1)
assert_eq "route intake at 90 (high) = opus" "opus" "$output"

# ─── Test 7: Route model for unknown stage ────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route custom_stage 50 2>&1)
assert_eq "route unknown stage at 50 = sonnet" "sonnet" "$output"

# ─── Test 8: Escalate model ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Escalate Model${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate haiku 2>&1)
assert_eq "escalate haiku -> sonnet" "sonnet" "$output"

output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate sonnet 2>&1)
assert_eq "escalate sonnet -> opus" "opus" "$output"

output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate opus 2>&1)
assert_eq "escalate opus -> opus (ceiling)" "opus" "$output"

# ─── Test 9: Escalate unknown model ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate unknown 2>&1) && rc=0 || rc=$?
assert_eq "escalate unknown exits non-zero" "1" "$rc"

# ─── Test 10: Config show creates default ─────────────────────────────────
echo ""
echo -e "${BOLD}  Config${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config show 2>&1) || true
assert_contains "config show displays JSON" "$output" "default_routing"
# Unified config: canonical location is optimization dir
config_file="$HOME/.shipwright/optimization/model-routing.json"
if [[ -f "$config_file" ]]; then
    assert_pass "config creates default file"
else
    assert_fail "config creates default file" "file not found"
fi

# ─── Test 11: Config set ─────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config set cost_aware_mode true 2>&1) || true
assert_contains "config set confirms update" "$output" "Updated"
value=$(jq -r '.cost_aware_mode' "$config_file")
assert_eq "config set persists value" "true" "$value"

# ─── Test 12: Estimate cost ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Estimate${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" estimate standard 50 2>&1) || true
assert_contains "estimate shows stages" "$output" "intake"
assert_contains "estimate shows total" "$output" "Total"

# ─── Test 13: Report with no data ────────────────────────────────────────
echo ""
echo -e "${BOLD}  Report${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" report 2>&1) || true
assert_contains "report with no data warns" "$output" "No usage data"

# ─── Test 14: record_usage creates usage data file ───────────────────────
echo ""
echo -e "${BOLD}  Record Usage${RESET}"
source "$SCRIPT_DIR/sw-model-router.sh" 2>/dev/null || true
record_usage "plan" "opus" 1000 500 2>/dev/null || true
record_usage "build" "sonnet" 2000 800 2>/dev/null || true
usage_file="$HOME/.shipwright/optimization/model-usage.jsonl"
if [[ -f "$usage_file" ]]; then
    assert_pass "record_usage creates usage file"
    lines=$(wc -l < "$usage_file" 2>/dev/null | tr -d ' ' || echo "0")
    assert_eq "record_usage writes entries" "2" "$lines"
else
    assert_fail "record_usage creates usage file"
fi

# ─── Test 15: Report with usage data shows summary ───────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" report 2>&1) || true
assert_contains "report with data shows summary" "$output" "Summary"
assert_contains "report shows total runs" "$output" "Total runs"
assert_contains "report shows cost" "$output" "cost"
assert_contains_regex "report shows model counts" "$output" "(Haiku|Sonnet|Opus) runs"

# ─── Test 16: Route for all stages at all complexity levels ──────────────
echo ""
echo -e "${BOLD}  Route All Stages & Complexity${RESET}"
for stage in intake plan design build test review compound_quality validate monitor; do
    out=$(bash "$SCRIPT_DIR/sw-model-router.sh" route "$stage" 50 2>&1)
    if [[ -n "$out" && "$out" =~ ^(haiku|sonnet|opus)$ ]]; then
        assert_pass "route $stage at 50 returns model"
    else
        assert_fail "route $stage at 50 returns model" "got: $out"
    fi
done
out_low=$(bash "$SCRIPT_DIR/sw-model-router.sh" route plan 10 2>&1)
out_high=$(bash "$SCRIPT_DIR/sw-model-router.sh" route plan 95 2>&1)
assert_eq "route plan at low complexity = sonnet" "sonnet" "$out_low"
assert_eq "route plan at high complexity = opus" "opus" "$out_high"

# ─── Test 17: Config set and config show cycle ───────────────────────────
echo ""
echo -e "${BOLD}  Config Set/Show Cycle${RESET}"
bash "$SCRIPT_DIR/sw-model-router.sh" config set cost_aware_mode false 2>/dev/null || true
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config show 2>&1) || true
assert_contains "config show reflects settings" "$output" "cost_aware_mode"
val=$(jq -r '.cost_aware_mode' "$config_file" 2>/dev/null)
assert_eq "config set persists" "false" "$val"

# ─── Test 18: Estimate with specific stages and complexity ───────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" estimate standard 25 2>&1) || true
assert_contains "estimate with low complexity shows stages" "$output" "intake"
assert_contains "estimate shows Total" "$output" "Total"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" estimate standard 75 2>&1) || true
assert_contains "estimate with high complexity" "$output" "plan"

# ─── Test 19: Unknown subcommand ────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown subcommand exits non-zero" "1" "$rc"
assert_contains "unknown subcommand shows error" "$output" "Unknown subcommand"

# ─── Test 20: Chain config creates templates ──────────────────────────────
echo ""
echo -e "${BOLD}  Reasoning Chains${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" chain config 2>&1) || true
assert_contains "chain config shows templates" "$output" "explore-decide"
assert_contains "chain config shows explore-synthesize-decide" "$output" "explore-synthesize-decide"
assert_contains "chain config shows fast-verify" "$output" "fast-verify"
assert_contains "chain config shows deep-analysis" "$output" "deep-analysis"

chain_file="$HOME/.shipwright/optimization/reasoning-chains.json"
if [[ -f "$chain_file" ]]; then
    assert_pass "chain config creates templates file"
else
    assert_fail "chain config creates templates file" "file not found at $chain_file"
fi

# ─── Test 21: Define custom chain ──────────────────────────────────────────
custom_chain_json='[
  {"step": "analyze", "model": "sonnet", "max_tokens": 5000},
  {"step": "review", "model": "opus", "max_tokens": 3000}
]'
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" chain define test-chain "$custom_chain_json" 2>&1) || true
assert_contains "chain define shows success" "$output" "Defined custom chain"
if command -v jq >/dev/null 2>&1; then
    custom_exists=$(jq -r '.custom_chains["test-chain"] // empty' "$chain_file" 2>/dev/null || true)
    if [[ -n "$custom_exists" ]]; then
        assert_pass "chain define persists custom chain"
    else
        assert_fail "chain define persists custom chain"
    fi
fi

# ─── Test 22: Chain score confidence ──────────────────────────────────────
source "$SCRIPT_DIR/sw-model-router.sh" 2>/dev/null || true
output1=$(chain_score_confidence "Therefore, we concluded that the approach is correct." "general" 2>/dev/null || echo "50")
if [[ "$output1" =~ ^[0-9]+$ ]]; then
    assert_pass "chain_score_confidence returns numeric score"
    if [[ "$output1" -gt 50 ]]; then
        assert_pass "chain_score_confidence scores conclusion text higher"
    else
        assert_fail "chain_score_confidence scores conclusion text higher" "got $output1"
    fi
else
    assert_fail "chain_score_confidence returns numeric score" "got: $output1"
fi

# ─── Test 23: Chain execute returns valid JSON ─────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" chain execute explore-decide "test prompt" 2>&1) || true
if command -v jq >/dev/null 2>&1; then
    if echo "$output" | jq empty 2>/dev/null; then
        assert_pass "chain execute returns valid JSON"
        has_steps=$(echo "$output" | jq '.steps // empty' 2>/dev/null)
        if [[ -n "$has_steps" ]]; then
            assert_pass "chain execute result has steps"
        else
            assert_fail "chain execute result has steps"
        fi
    else
        assert_fail "chain execute returns valid JSON" "output not JSON"
    fi
fi

# ─── Test 24: Chain step cost calculation ─────────────────────────────────
cost_haiku=$(bash "$SCRIPT_DIR/sw-model-router.sh" chain step-cost 1000 500 haiku 2>&1) || true
cost_sonnet=$(bash "$SCRIPT_DIR/sw-model-router.sh" chain step-cost 1000 500 sonnet 2>&1) || true
cost_opus=$(bash "$SCRIPT_DIR/sw-model-router.sh" chain step-cost 1000 500 opus 2>&1) || true

if [[ "$cost_haiku" =~ ^0\.[0-9]+ ]]; then
    assert_pass "chain step-cost returns numeric cost for haiku"
else
    assert_fail "chain step-cost returns numeric cost for haiku" "got: $cost_haiku"
fi

# Verify cost ordering: haiku < sonnet < opus
if command -v awk >/dev/null 2>&1; then
    haiku_val=$(echo "$cost_haiku" | awk '{print $1}' || echo "0")
    sonnet_val=$(echo "$cost_sonnet" | awk '{print $1}' || echo "0")
    opus_val=$(echo "$cost_opus" | awk '{print $1}' || echo "0")

    if awk -v h="$haiku_val" -v s="$sonnet_val" -v o="$opus_val" 'BEGIN {exit !(h < s && s < o)}' 2>/dev/null; then
        assert_pass "chain step-cost ordering correct (haiku < sonnet < opus)"
    fi
fi

# ─── Test 25: Chain report (note: may have data from Test 23) ──────────────
# This test runs after chain execute, so the report may show data
# We just verify that the report command works without error
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" chain report 2>&1) || true
assert_contains "chain report outputs summary" "$output" "Chain Execution Report"

# ─── Test 26: Chain config with invalid JSON fails gracefully ────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" chain define bad-chain "invalid json" 2>&1) && rc=0 || rc=$?
assert_eq "chain define with invalid JSON exits non-zero" "1" "$rc"
assert_contains "chain define validates JSON" "$output" "Invalid JSON"

# ─── Test 27: Verify chain templates structure ─────────────────────────────
if command -v jq >/dev/null 2>&1; then
    explore_decide=$(jq -r '.templates["explore-decide"] // empty' "$chain_file" 2>/dev/null || true)
    if [[ -n "$explore_decide" ]]; then
        step_count=$(echo "$explore_decide" | jq 'length' 2>/dev/null || echo "0")
        assert_eq "explore-decide has 2 steps" "2" "$step_count"

        first_step=$(echo "$explore_decide" | jq -r '.[0].model' 2>/dev/null || true)
        assert_eq "explore-decide first step is haiku" "haiku" "$first_step"

        last_step=$(echo "$explore_decide" | jq -r '.[1].model' 2>/dev/null || true)
        assert_eq "explore-decide last step is opus" "opus" "$last_step"
    fi
fi

# ─── Test 28: Chain execute with non-existent chain fails ───────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" chain execute nonexistent "test" 2>&1) && rc=0 || rc=$?
assert_eq "chain execute with invalid chain exits non-zero" "1" "$rc"
assert_contains "chain execute shows error" "$output" "Chain not found"

echo ""
echo ""
print_test_results
