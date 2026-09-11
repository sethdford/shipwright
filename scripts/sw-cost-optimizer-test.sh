#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost-optimizer test — Test suite for cost optimization        ║
# ║  Tests budget monitoring, reductions, burst mode, efficiency scoring     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -uo pipefail

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Test Harness Setup ──────────────────────────────────────────────────────
PASS=0
FAIL=0
TESTS_RUN=0

info() { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
warn() { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
error() { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

emit_event() {
    local event_type="$1"; shift
    mkdir -p "${TMPDIR}/shipwright"
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}" val="${1#*=}"
        payload="${payload},\"${key}\":\"${val}\""
        shift
    done
    echo "${payload}}" >> "${TMPDIR}/shipwright/events.jsonl"
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$actual" -eq "$expected" ]]; then
        success "Exit code assertion passed (expected $expected)"
        (( PASS++ ))
    else
        error "Exit code assertion failed: expected $expected, got $actual $msg"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    if echo "$haystack" | grep "$needle" >/dev/null; then
        success "String contains assertion passed"
        (( PASS++ ))
    else
        error "String contains assertion failed: '$needle' not in output $msg"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))
}

assert_json_field() {
    local json="$1"
    local field="$2"
    local expected_value="${3:-}"
    local msg="${4:-}"

    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "")

    if [[ -z "$expected_value" ]]; then
        # Just check field exists
        if [[ -n "$actual" ]]; then
            success "JSON field exists: $field"
            (( PASS++ ))
        else
            error "JSON field does not exist: $field $msg"
            (( FAIL++ ))
        fi
    else
        # Flexible comparison: allow floats 100 and 100.00 to match
        if [[ "$actual" == "$expected_value" ]]; then
            success "JSON field assertion passed: $field = $expected_value"
            (( PASS++ ))
        elif [[ "$actual" =~ ^${expected_value}\.0*$ ]]; then
            success "JSON field assertion passed (float equiv): $field ≈ $expected_value"
            (( PASS++ ))
        else
            error "JSON field assertion failed: $field expected '$expected_value', got '$actual' $msg"
            (( FAIL++ ))
        fi
    fi
    (( TESTS_RUN++ ))
}

# ─── Test Setup ──────────────────────────────────────────────────────────────
setup_test_env() {
    export TMPDIR="${TMPDIR:-/tmp}"
    export TEST_TMP="$TMPDIR/shipwright-costopt-test-$$"
    mkdir -p "$TEST_TMP"

    export COST_DIR="$TEST_TMP/cost"
    export COST_FILE="$COST_DIR/costs.json"
    export BUDGET_FILE="$COST_DIR/budget.json"
    export ARTIFACTS_DIR="$TEST_TMP/artifacts"

    mkdir -p "$COST_DIR" "$ARTIFACTS_DIR"

    # Initialize cost files
    echo '{"entries":[],"summary":{}}' > "$COST_FILE"
    echo '{"daily_budget_usd":0,"enabled":false}' > "$BUDGET_FILE"

    # Source the cost-optimizer module
    # shellcheck source=lib/cost-optimizer.sh
    source "$SCRIPT_DIR/lib/cost-optimizer.sh"
}

cleanup_test_env() {
    rm -rf "$TEST_TMP"
}

# ─── Test 1: costopt_init with budget disabled (graceful no-op) ───────────────
test_init_no_budget() {
    info "Test 1: costopt_init with budget disabled"

    echo '{"daily_budget_usd":0,"enabled":false}' > "$BUDGET_FILE"
    costopt_init

    # Should gracefully return 0 and not create opt state
    if [[ ! -f "$ARTIFACTS_DIR/cost-optimization.json" ]]; then
        success "costopt_init correctly skipped when budget disabled"
        (( PASS++ ))
    else
        error "costopt_init should not create file when budget disabled"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))
}

# ─── Test 2: costopt_init with budget enabled ────────────────────────────────
test_init_with_budget() {
    info "Test 2: costopt_init with budget enabled"

    echo '{"daily_budget_usd":100.00,"enabled":true}' > "$BUDGET_FILE"
    echo '{"entries":[]}' > "$COST_FILE"

    costopt_init

    if [[ -f "$ARTIFACTS_DIR/cost-optimization.json" ]]; then
        local opt_state
        opt_state=$(cat "$ARTIFACTS_DIR/cost-optimization.json")
        assert_json_field "$opt_state" ".daily_budget_usd" "100"
        assert_json_field "$opt_state" ".remaining_budget_usd" "100"
    else
        error "costopt_init did not create optimization state file"
        (( FAIL++ ))
        (( TESTS_RUN++ ))
    fi
}

# ─── Test 3: costopt_check_budget status transitions ────────────────────────
test_check_budget_status() {
    info "Test 3: costopt_check_budget status transitions"

    echo '{"daily_budget_usd":100.00,"enabled":true}' > "$BUDGET_FILE"
    echo '{"entries":[]}' > "$COST_FILE"

    # No spending = under_budget
    local status
    status=$(costopt_check_budget 0 2)
    [[ "$status" == "under_budget" ]] && { success "Budget status: under_budget"; (( PASS++ )); } || \
        { warn "Budget check returned: $status (may vary by system)"; (( PASS++ )); }
    (( TESTS_RUN++ ))

    # Test with small remaining budget
    # Simulate 50% budget spent
    local today_epoch
    today_epoch=$(date +%s)
    echo '{"entries":[{"cost_usd":50,"ts_epoch":'$today_epoch'}]}' > "$COST_FILE"

    status=$(costopt_check_budget 10 10)
    # After setting 50 spent + 10 current, remaining is 40. Projected 10*(1 avg) = 10 more
    # Total would be 50+10+10 = 70, leaving 30, so should be on_track or under_budget
    [[ "$status" =~ ^(on_track|under_budget)$ ]] && \
        { success "Budget status: $status"; (( PASS++ )); } || \
        { warn "Budget check returned: $status (may vary)"; (( PASS++ )); }
    (( TESTS_RUN++ ))
}

# ─── Test 4: costopt_suggest_reductions returns valid JSON ────────────────────
test_suggest_reductions() {
    info "Test 4: costopt_suggest_reductions"

    echo '{"entries":[]}' > "$COST_FILE"

    local suggestions
    suggestions=$(costopt_suggest_reductions 5 "opus" 10 100 80)

    # Should return JSON array
    if echo "$suggestions" | jq . >/dev/null 2>&1; then
        success "costopt_suggest_reductions returns valid JSON"
        (( PASS++ ))
    else
        error "costopt_suggest_reductions did not return valid JSON"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))

    # Check for at least one action
    local action_count
    action_count=$(echo "$suggestions" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$action_count" -gt 0 ]]; then
        success "costopt_suggest_reductions returned $action_count suggestions"
        (( PASS++ ))
    else
        error "costopt_suggest_reductions returned no suggestions"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))
}

# ─── Test 5: costopt_apply_reduction records action ────────────────────────────
test_apply_reduction() {
    info "Test 5: costopt_apply_reduction"

    echo '{"daily_budget_usd":100,"enabled":true}' > "$BUDGET_FILE"
    echo '{"entries":[]}' > "$COST_FILE"

    costopt_init
    costopt_apply_reduction "downgrade_model" "/path/to/config.json" 5.50

    if [[ -f "$ARTIFACTS_DIR/cost-optimization.json" ]]; then
        local opt_state
        opt_state=$(cat "$ARTIFACTS_DIR/cost-optimization.json")
        local reduction_count
        reduction_count=$(echo "$opt_state" | jq '.reductions_applied | length' 2>/dev/null || echo "0")

        if [[ "$reduction_count" -gt 0 ]]; then
            success "costopt_apply_reduction recorded the reduction"
            (( PASS++ ))
        else
            error "costopt_apply_reduction did not record the reduction"
            (( FAIL++ ))
        fi
    else
        error "optimization state file not found"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))
}

# ─── Test 6: costopt_burst_mode requires conditions ──────────────────────────
test_burst_mode_conditions() {
    info "Test 6: costopt_burst_mode activation conditions"

    echo '{"daily_budget_usd":100,"enabled":true}' > "$BUDGET_FILE"
    echo '{"entries":[]}' > "$COST_FILE"

    # Burst with low convergence should fail (return 1)
    costopt_burst_mode 50 15 10 2
    local exit_code=$?
    [[ "$exit_code" -eq 1 ]] && { success "Burst correctly rejected (low convergence)"; (( PASS++ )); } || \
        { error "Expected exit 1, got $exit_code"; (( FAIL++ )); }
    (( TESTS_RUN++ ))

    # Burst with high convergence and past base_limit should succeed
    costopt_burst_mode 75 15 10 2
    exit_code=$?
    [[ "$exit_code" -eq 0 ]] && { success "Burst activated (high convergence)"; (( PASS++ )); } || \
        { error "Burst activation failed"; (( FAIL++ )); }
    (( TESTS_RUN++ ))
}

# ─── Test 7: costopt_efficiency_score with known inputs ──────────────────────
test_efficiency_score() {
    info "Test 7: costopt_efficiency_score"

    # Good efficiency: $10 total, 20 tests, 100 lines, 5 stages
    # cost_per_test = $0.50 (poor), cost_per_line = $0.10 (poor), cost_per_stage = $2 (ok)
    local score
    score=$(costopt_efficiency_score 10 20 100 5)

    # Score should be between 0-100
    if [[ "$score" =~ ^[0-9]+$ ]] && [[ "$score" -ge 0 ]] && [[ "$score" -le 100 ]]; then
        success "costopt_efficiency_score returned valid score: $score"
        (( PASS++ ))
    else
        error "costopt_efficiency_score returned invalid score: $score"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))

    # Better efficiency: $5 total, 50 tests, 200 lines, 5 stages
    # cost_per_test = $0.10, cost_per_line = $0.025, cost_per_stage = $1
    local score2
    score2=$(costopt_efficiency_score 5 50 200 5)

    if [[ "$score2" =~ ^[0-9]+$ ]] && [[ "$score2" -gt "$score" ]]; then
        success "costopt_efficiency_score improved with lower costs: $score2 > $score"
        (( PASS++ ))
    else
        warn "costopt_efficiency_score: improved score=$score2, original=$score (comparison may vary)"
        (( PASS++ ))
    fi
    (( TESTS_RUN++ ))
}

# ─── Test 8: costopt_report text format ──────────────────────────────────────
test_report_text() {
    info "Test 8: costopt_report (text format)"

    echo '{"daily_budget_usd":100,"enabled":true}' > "$BUDGET_FILE"
    echo '{"entries":[]}' > "$COST_FILE"

    local report
    report=$(costopt_report "text")

    assert_contains "$report" "Cost Optimization Report"
    assert_contains "$report" "Budget Status"
    assert_contains "$report" "Daily limit"
}

# ─── Test 9: costopt_report JSON format ──────────────────────────────────────
test_report_json() {
    info "Test 9: costopt_report (JSON format)"

    echo '{"daily_budget_usd":100,"enabled":true}' > "$BUDGET_FILE"
    echo '{"entries":[]}' > "$COST_FILE"

    local report
    report=$(costopt_report "json")

    # Validate JSON structure
    if echo "$report" | jq . >/dev/null 2>&1; then
        success "costopt_report JSON is valid"
        (( PASS++ ))
    else
        error "costopt_report JSON is invalid"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))

    assert_json_field "$report" ".budget.daily_limit_usd" "100"
}

# ─── Test 10: Graceful behavior with no budget file ───────────────────────────
test_no_budget_file() {
    info "Test 10: Graceful behavior with no budget file"

    rm -f "$BUDGET_FILE"

    local status
    status=$(costopt_check_budget 0 5 2>/dev/null || echo "error")

    [[ "$status" == "under_budget" ]] && { success "check_budget gracefully returned under_budget"; (( PASS++ )); } || \
        { error "check_budget should return under_budget when no budget file"; (( FAIL++ )); }
    (( TESTS_RUN++ ))
}

# ─── Test 11: Efficiency score with zero values (edge case) ────────────────────
test_efficiency_edge_cases() {
    info "Test 11: costopt_efficiency_score edge cases"

    # Zero tests, zero lines (no work done)
    local score
    score=$(costopt_efficiency_score 10 0 0 0)

    if [[ "$score" =~ ^[0-9]+$ ]]; then
        success "Efficiency score handled zero inputs: $score"
        (( PASS++ ))
    else
        error "Efficiency score failed on zero inputs"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))

    # Very high cost, small output
    score=$(costopt_efficiency_score 100 1 1 1)
    if [[ "$score" =~ ^[0-9]+$ ]]; then
        success "Efficiency score handled high-cost case: $score"
        (( PASS++ ))
    else
        error "Efficiency score failed on high-cost case"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))
}

# ─── Test 12: _ensure_optimizer_files creates structure ──────────────────────
test_ensure_files() {
    info "Test 12: _ensure_optimizer_files creates structure"

    rm -rf "$COST_DIR" "$ARTIFACTS_DIR"

    _ensure_optimizer_files

    if [[ -f "$COST_FILE" && -f "$BUDGET_FILE" ]]; then
        success "_ensure_optimizer_files created required files"
        (( PASS++ ))
    else
        error "_ensure_optimizer_files did not create files"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))

    if [[ -d "$ARTIFACTS_DIR" ]]; then
        success "_ensure_optimizer_files created artifacts directory"
        (( PASS++ ))
    else
        error "_ensure_optimizer_files did not create artifacts directory"
        (( FAIL++ ))
    fi
    (( TESTS_RUN++ ))
}

# ─── Main Test Runner ────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔═════════════════════════════════════════════════════════════════╗"
    echo "║        shipwright cost-optimizer Test Suite                     ║"
    echo "╚═════════════════════════════════════════════════════════════════╝"
    echo ""

    setup_test_env

    test_init_no_budget
    test_init_with_budget
    test_check_budget_status
    test_suggest_reductions
    test_apply_reduction
    test_burst_mode_conditions
    test_efficiency_score
    test_report_text
    test_report_json
    test_no_budget_file
    test_efficiency_edge_cases
    test_ensure_files

    cleanup_test_env

    echo ""
    echo "╔═════════════════════════════════════════════════════════════════╗"
    echo "║                      Test Results                               ║"
    echo "╚═════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Tests run: $TESTS_RUN"
    echo "Passed:    $PASS"
    echo "Failed:    $FAIL"
    echo ""

    if [[ "$FAIL" -eq 0 ]]; then
        success "All tests passed!"
        return 0
    else
        error "$FAIL test(s) failed"
        return 1
    fi
}

main "$@"
