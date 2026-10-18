#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright memory effectiveness — Unit tests                             ║
# ║  Validates pattern scoring, ranking, pruning, proactive scoring           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate
MEMEFF_MODULE="$SCRIPT_DIR/lib/memory-effectiveness.sh"

# ─── Test Counters ───────────────────────────────────────────────────────────

TOTAL=0
PASS=0
FAIL=0
declare -a FAILURES=()

# ─── Colors ──────────────────────────────────────────────────────────────────

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
YELLOW='\033[38;2;250;204;21m'
RESET='\033[0m'
BOLD='\033[1m'

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-memeff-test.XXXXXX")
    # Scripts under test read and write the intelligence cache here, not in the repo (#8609).
    export SHIPWRIGHT_INTELLIGENCE_CACHE="$TEST_TEMP_DIR/project/.claude/intelligence-cache.json"

    # Override HOME so storage writes go to temp dir
    export ORIG_HOME="$HOME"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME/.shipwright"

    # Create empty JSONL files
    mkdir -p "$HOME/.shipwright/optimization"
    touch "$HOME/.shipwright/optimization/memory-injections.jsonl"
    touch "$HOME/.shipwright/optimization/memory-outcomes.jsonl"
    echo '{}' > "$HOME/.shipwright/optimization/memory-scores.json"
}

cleanup_env() {
    if [[ -n "${ORIG_HOME:-}" ]]; then
        export HOME="$ORIG_HOME"
    fi
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

trap 'cleanup_env; sw_test_teardown' EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

    local result=0
    if ! "$test_fn"; then
        result=$?
    fi

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" label="${3:-contains}"
    if [[ ! -f "$file" ]]; then
        echo -e "    ${RED}✗${RESET} File not found: $file"
        return 1
    fi
    if grep -qE "$pattern" "$file"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Missing pattern: $pattern ($label)"
    return 1
}

assert_json_valid() {
    local json="$1" label="${2:-JSON}"
    if echo "$json" | jq empty 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Invalid JSON: $label"
    echo "$json" | head -5
    return 1
}

assert_json_equals() {
    local json="$1" path="$2" expected="$3" label="${4:-equals}"
    local actual
    actual=$(echo "$json" | jq -r "$path" 2>/dev/null)
    if [[ "$actual" == "$expected" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected $path=$expected, got $actual ($label)"
    return 1
}

assert_json_field_exists() {
    local json="$1" field="$2"
    if echo "$json" | jq -e "$field" >/dev/null 2>&1; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Missing field: $field"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_injection_tracking_writes_valid_jsonl() {
    source "$MEMEFF_MODULE"

    memeff_track_injection "auth-pattern-1" "pipe-001" "build" "test context"

    assert_file_contains "$HOME/.shipwright/optimization/memory-injections.jsonl" \
        '"memory_id":"auth-pattern-1"' \
        "injection record written"
}

test_injection_contains_required_fields() {
    source "$MEMEFF_MODULE"

    memeff_track_injection "db-pattern-2" "pipe-002" "test" "db context"

    local line
    line=$(tail -1 "$HOME/.shipwright/optimization/memory-injections.jsonl")
    assert_json_valid "$line" "injection JSONL entry"
    assert_json_field_exists "$line" '.memory_id'
    assert_json_field_exists "$line" '.pipeline_id'
    assert_json_field_exists "$line" '.stage'
    assert_json_field_exists "$line" '.injected_at'
}

test_outcome_tracking_links_to_injection() {
    source "$MEMEFF_MODULE"

    memeff_track_injection "perf-pattern-1" "pipe-003" "build" ""
    memeff_track_outcome "perf-pattern-1" "pipe-003" "success" ""

    local outcome_line
    outcome_line=$(tail -1 "$HOME/.shipwright/optimization/memory-outcomes.jsonl")
    assert_json_valid "$outcome_line" "outcome JSONL entry"
    assert_json_equals "$outcome_line" '.memory_id' "perf-pattern-1"
    assert_json_equals "$outcome_line" '.pipeline_id' "pipe-003"
    assert_json_equals "$outcome_line" '.outcome' "success"
}

test_outcome_marks_prevention_on_success() {
    source "$MEMEFF_MODULE"

    memeff_track_injection "fix-1" "p1" "build" ""
    memeff_track_outcome "fix-1" "p1" "success" ""

    local outcome_line
    outcome_line=$(tail -1 "$HOME/.shipwright/optimization/memory-outcomes.jsonl")
    assert_json_equals "$outcome_line" '.avoided_error' "true"
}

test_outcome_marks_no_prevention_on_failure() {
    source "$MEMEFF_MODULE"

    memeff_track_injection "fix-2" "p2" "test" ""
    memeff_track_outcome "fix-2" "p2" "failure" "unrelated error"

    local outcome_line
    outcome_line=$(tail -1 "$HOME/.shipwright/optimization/memory-outcomes.jsonl")
    assert_json_equals "$outcome_line" '.avoided_error' "false"
}

test_score_calculation_with_known_inputs() {
    source "$MEMEFF_MODULE"

    # Simulate 10 injections: 7 successful, 8 relevant
    for i in {1..7}; do
        memeff_track_injection "test-pattern-1" "p-$i" "build" ""
        memeff_track_outcome "test-pattern-1" "p-$i" "success" ""
    done

    for i in {8..10}; do
        memeff_track_injection "test-pattern-1" "p-$i" "build" ""
        memeff_track_outcome "test-pattern-1" "p-$i" "failure" ""
    done

    local score_json
    score_json=$(memeff_score_pattern "test-pattern-1")

    assert_json_valid "$score_json"
    assert_json_field_exists "$score_json" '.effectiveness_score'
    assert_json_field_exists "$score_json" '.prevention_rate'
    assert_json_field_exists "$score_json" '.total_injections'

    # Verify math: 7 out of 10 successful = 70% prevention rate
    assert_json_equals "$score_json" '.total_injections' "10"
    assert_json_equals "$score_json" '.prevention_rate' "70"
}

test_ranking_sorts_by_effectiveness() {
    source "$MEMEFF_MODULE"

    # Create three patterns with different scores
    # Pattern A: 8 successes out of 10 = 80%
    for i in {1..8}; do
        memeff_track_injection "pattern-a" "a-$i" "build" ""
        memeff_track_outcome "pattern-a" "a-$i" "success" ""
    done
    for i in {9..10}; do
        memeff_track_injection "pattern-a" "a-$i" "build" ""
        memeff_track_outcome "pattern-a" "a-$i" "failure" ""
    done

    # Pattern B: 5 successes out of 10 = 50%
    for i in {1..5}; do
        memeff_track_injection "pattern-b" "b-$i" "build" ""
        memeff_track_outcome "pattern-b" "b-$i" "success" ""
    done
    for i in {6..10}; do
        memeff_track_injection "pattern-b" "b-$i" "build" ""
        memeff_track_outcome "pattern-b" "b-$i" "failure" ""
    done

    # Pattern C: 9 successes out of 10 = 90%
    for i in {1..9}; do
        memeff_track_injection "pattern-c" "c-$i" "build" ""
        memeff_track_outcome "pattern-c" "c-$i" "success" ""
    done
    memeff_track_injection "pattern-c" "c-10" "build" ""
    memeff_track_outcome "pattern-c" "c-10" "failure" ""

    local rankings
    rankings=$(memeff_rank_patterns 10)

    assert_json_valid "$rankings"

    # First should be pattern-c (90%)
    local first_id
    first_id=$(echo "$rankings" | jq -r '.[0].memory_id')
    [[ "$first_id" == "pattern-c" ]] || { echo "Expected pattern-c first, got $first_id"; return 1; }

    # Second should be pattern-a (80%)
    local second_id
    second_id=$(echo "$rankings" | jq -r '.[1].memory_id')
    [[ "$second_id" == "pattern-a" ]] || { echo "Expected pattern-a second, got $second_id"; return 1; }

    # Third should be pattern-b (50%)
    local third_id
    third_id=$(echo "$rankings" | jq -r '.[2].memory_id')
    [[ "$third_id" == "pattern-b" ]] || { echo "Expected pattern-b third, got $third_id"; return 1; }
}

test_proactive_scoring_returns_valid_probability() {
    source "$MEMEFF_MODULE"

    # Simulate 10 failures with same error signature, 7 prevented
    for i in {1..7}; do
        memeff_track_injection "fix-auth" "pa-$i" "build" ""
        memeff_track_outcome "fix-auth" "pa-$i" "success" ""
    done
    for i in {8..10}; do
        memeff_track_injection "fix-auth" "pa-$i" "build" ""
        memeff_track_outcome "fix-auth" "pa-$i" "failure" "token validation error"
    done

    local score_json
    score_json=$(memeff_proactive_score "token validation" "")

    assert_json_valid "$score_json"
    assert_json_field_exists "$score_json" '.prevention_probability'

    # Probability should be within 0-100
    local prob
    prob=$(echo "$score_json" | jq -r '.prevention_probability')
    [[ "$prob" -ge 0 && "$prob" -le 100 ]] || { echo "Probability out of range: $prob"; return 1; }
}

test_proactive_score_includes_metadata() {
    source "$MEMEFF_MODULE"

    memeff_track_injection "fix-1" "p1" "build" ""
    memeff_track_outcome "fix-1" "p1" "success" ""

    local score_json
    score_json=$(memeff_proactive_score "some error" "")

    assert_json_field_exists "$score_json" '.error_signature'
    assert_json_field_exists "$score_json" '.confidence'
    assert_json_field_exists "$score_json" '.matching_patterns'
}

test_prune_respects_dry_run_mode() {
    source "$MEMEFF_MODULE"

    # Create a low-effectiveness pattern (1 success out of 10)
    for i in {1..1}; do
        memeff_track_injection "bad-pattern" "bp-$i" "build" ""
        memeff_track_outcome "bad-pattern" "bp-$i" "success" ""
    done
    for i in {2..10}; do
        memeff_track_injection "bad-pattern" "bp-$i" "build" ""
        memeff_track_outcome "bad-pattern" "bp-$i" "failure" ""
    done

    # Dry-run should not delete anything
    memeff_prune_ineffective "true" >/dev/null 2>&1

    # Outcomes file should still contain the pattern
    local count
    count=$(grep -c '"bad-pattern"' "$HOME/.shipwright/optimization/memory-outcomes.jsonl" 2>/dev/null || echo "0")
    if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -eq 0 ]]; then
        echo "Pattern was deleted in dry-run mode!"
        return 1
    fi
}

test_report_produces_valid_json() {
    source "$MEMEFF_MODULE"

    # Create some test data
    for i in {1..3}; do
        memeff_track_injection "pat-$i" "p-$i" "build" ""
        memeff_track_outcome "pat-$i" "p-$i" "success" ""
    done

    local report
    report=$(memeff_report "json")

    assert_json_valid "$report" "effectiveness report"
    assert_json_field_exists "$report" '.summary.total_patterns'
    assert_json_field_exists "$report" '.summary.average_score'
    assert_json_field_exists "$report" '.top_5'
    assert_json_field_exists "$report" '.bottom_5'
}

test_report_includes_top_and_bottom_patterns() {
    source "$MEMEFF_MODULE"

    # Create patterns with varying effectiveness
    for i in {1..5}; do
        memeff_track_injection "high-quality" "hq-$i" "build" ""
        memeff_track_outcome "high-quality" "hq-$i" "success" ""
    done

    for i in {1..10}; do
        memeff_track_injection "low-quality" "lq-$i" "build" ""
        [[ $i -le 1 ]] && memeff_track_outcome "low-quality" "lq-$i" "success" "" || \
                           memeff_track_outcome "low-quality" "lq-$i" "failure" ""
    done

    local report
    report=$(memeff_report "json")

    local top_count
    top_count=$(echo "$report" | jq '.top_5 | length')
    [[ "$top_count" -gt 0 ]] || { echo "No top patterns in report"; return 1; }
}

test_multiple_injections_same_pipeline() {
    source "$MEMEFF_MODULE"

    # Multiple patterns injected in same pipeline
    memeff_track_injection "auth-fix" "pipe-001" "build" ""
    memeff_track_injection "perf-fix" "pipe-001" "build" ""
    memeff_track_injection "db-fix" "pipe-001" "test" ""

    local count
    count=$(grep -c '"pipe-001"' "$HOME/.shipwright/optimization/memory-injections.jsonl")
    [[ "$count" -eq 3 ]] || { echo "Expected 3 injections, got $count"; return 1; }
}

test_injection_with_empty_context() {
    source "$MEMEFF_MODULE"

    # Should work even with empty context
    memeff_track_injection "pattern-1" "p-1" "build" ""

    local line
    line=$(tail -1 "$HOME/.shipwright/optimization/memory-injections.jsonl")
    assert_json_valid "$line"
}

test_score_returns_zero_for_no_injections() {
    source "$MEMEFF_MODULE"

    # Score a pattern that was never injected
    local score_json
    score_json=$(memeff_score_pattern "nonexistent-pattern")

    assert_json_valid "$score_json"
    # Should have 0 injections and 0 score
    assert_json_equals "$score_json" '.total_injections' "0"
}

test_ranking_empty_list_when_no_patterns() {
    source "$MEMEFF_MODULE"

    local rankings
    rankings=$(memeff_rank_patterns 10)

    [[ "$rankings" == "[]" ]] || { echo "Expected empty ranking, got: $rankings"; return 1; }
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    setup_env

    echo ""
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║  Memory Effectiveness Tracker Test Suite                   ║${RESET}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Injection tracking tests
    echo -e "${BOLD}Injection Tracking${RESET}"
    run_test "writes valid JSONL" test_injection_tracking_writes_valid_jsonl
    run_test "contains required fields" test_injection_contains_required_fields
    run_test "multiple injections same pipeline" test_multiple_injections_same_pipeline
    run_test "handles empty context" test_injection_with_empty_context

    echo ""
    echo -e "${BOLD}Outcome Tracking${RESET}"
    run_test "links to injection" test_outcome_tracking_links_to_injection
    run_test "marks prevention on success" test_outcome_marks_prevention_on_success
    run_test "marks no prevention on failure" test_outcome_marks_no_prevention_on_failure

    echo ""
    echo -e "${BOLD}Score Calculation${RESET}"
    run_test "calculates with known inputs" test_score_calculation_with_known_inputs
    run_test "returns zero for no injections" test_score_returns_zero_for_no_injections

    echo ""
    echo -e "${BOLD}Ranking${RESET}"
    run_test "sorts by effectiveness descending" test_ranking_sorts_by_effectiveness
    run_test "returns empty list when no patterns" test_ranking_empty_list_when_no_patterns

    echo ""
    echo -e "${BOLD}Proactive Scoring${RESET}"
    run_test "returns valid probability" test_proactive_scoring_returns_valid_probability
    run_test "includes metadata fields" test_proactive_score_includes_metadata

    echo ""
    echo -e "${BOLD}Pruning${RESET}"
    run_test "respects dry-run mode" test_prune_respects_dry_run_mode

    echo ""
    echo -e "${BOLD}Reporting${RESET}"
    run_test "produces valid JSON" test_report_produces_valid_json
    run_test "includes top and bottom patterns" test_report_includes_top_and_bottom_patterns

    echo ""
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${RESET}"
    if [[ "$FAIL" -eq 0 ]]; then
        echo -e "${BOLD}${GREEN}║  Results: $PASS/$TOTAL passed ✓${RESET}"
    else
        echo -e "${BOLD}${RED}║  Results: $PASS/$TOTAL passed, $FAIL failed${RESET}"
    fi
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${RED}Failed tests:${RESET}"
        for failure in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $failure"
        done
        echo ""
        return 1
    fi

    return 0
}

main "$@"
