#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-convergence-test.sh — Unit tests for convergence detection            ║
# ║                                                                           ║
# ║  Tests convergence scoring, history tracking, and detection logic.       ║
# ║  No real build loop needed — all mocked.                                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# ─── Test Harness Setup ────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-isolate.sh"
sw_test_isolate
source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || {
    info() { echo "ℹ $*"; }
    success() { echo "✓ $*"; }
    warn() { echo "⚠ $*"; }
    error() { echo "✗ $*" >&2; }
}

# Temp directory for test artifacts
TEST_ARTIFACTS_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_ARTIFACTS_DIR"; sw_test_teardown' EXIT

# Source the convergence module
source "$SCRIPT_DIR/lib/convergence.sh"

# Override ARTIFACTS_DIR for tests
ARTIFACTS_DIR="$TEST_ARTIFACTS_DIR"

# Test counters
PASS=0
FAIL=0

# ─── Test Helpers ──────────────────────────────────────────────────────────

assert_json_field() {
    local json="$1"
    local field="$2"
    local expected="$3"
    local msg="${4:-}"

    local actual
    actual=$(echo "$json" | jq -r "$field // empty" 2>/dev/null) || actual=""

    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        success "✓ $msg (got: $actual)"
    else
        FAIL=$((FAIL + 1))
        error "✗ $msg (expected: $expected, got: $actual)"
    fi
}

assert_json_number() {
    local json="$1"
    local field="$2"
    local expected="$3"
    local msg="${4:-}"

    local actual
    actual=$(echo "$json" | jq -r "$field // empty" 2>/dev/null) || actual=""

    if [[ "$actual" -eq "$expected" ]] 2>/dev/null; then
        PASS=$((PASS + 1))
        success "✓ $msg (got: $actual)"
    else
        FAIL=$((FAIL + 1))
        error "✗ $msg (expected: $expected, got: $actual)"
    fi
}

# ─── Tests ─────────────────────────────────────────────────────────────────

run_tests() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Convergence Detection Test Suite                          ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Test 1: Score calculation — tests passing
    echo "▸ Test 1: Score iteration with tests passing"
    local score1
    score1=$(convergence_score_iteration 1 true true 25 0 50)
    assert_json_field "$score1" ".score" "95" "Tests passing with code changes should score high"
    assert_json_field "$score1" ".trend" "improving" "Trend should be improving vs baseline"

    # Test 2: Score calculation — tests failing
    echo "▸ Test 2: Score iteration with tests failing"
    local score2
    score2=$(convergence_score_iteration 2 false true 10 0 95)
    assert_json_field "$score2" ".trend" "declining" "Declining from 95 to low score"

    # Test 3: Score calculation — no code changes
    echo "▸ Test 3: Score iteration with no code changes"
    local score3
    score3=$(convergence_score_iteration 3 false false 0 0 50)
    assert_json_number "$score3" ".score" "35" "No changes should decrease score"

    # Test 4: History tracking — single entry
    echo "▸ Test 4: Track single iteration in history"
    convergence_history 1 75 "improving"
    [[ -f "$ARTIFACTS_DIR/convergence-history.json" ]] && {
        PASS=$((PASS + 1))
        success "✓ History file created"
    } || {
        FAIL=$((FAIL + 1))
        error "✗ History file not created"
    }

    # Test 5: History tracking — multiple entries
    echo "▸ Test 5: Track multiple iterations"
    convergence_history 2 80 "stable"
    convergence_history 3 82 "stable"
    local hist_count
    hist_count=$(jq 'length' "$ARTIFACTS_DIR/convergence-history.json" 2>/dev/null || echo "0")
    if [[ "$hist_count" -eq 3 ]]; then
        PASS=$((PASS + 1))
        success "✓ Three entries tracked"
    else
        FAIL=$((FAIL + 1))
        error "✗ Expected 3 entries, got $hist_count"
    fi

    # Test 6: Detect converged state (high stable scores)
    echo "▸ Test 6: Detect converged state"
    convergence_clear_history
    convergence_history 1 50 "stable"
    convergence_history 2 82 "improving"
    convergence_history 3 83 "stable"
    local detect6
    detect6=$(convergence_detect)
    assert_json_field "$detect6" ".status" "converged" "High stable scores should converge"

    # Test 7: Detect diverging state
    echo "▸ Test 7: Detect diverging state"
    convergence_clear_history
    convergence_history 1 80 "stable"
    convergence_history 2 70 "declining"
    convergence_history 3 60 "declining"
    convergence_history 4 50 "declining"
    local detect7
    detect7=$(convergence_detect)
    assert_json_field "$detect7" ".status" "diverging" "Consistent decline should diverge"

    # Test 8: Detect oscillating state
    echo "▸ Test 8: Detect oscillating state"
    convergence_clear_history
    convergence_history 1 50 "stable"
    convergence_history 2 60 "improving"
    convergence_history 3 50 "declining"
    convergence_history 4 65 "improving"
    convergence_history 5 55 "declining"
    local detect8
    detect8=$(convergence_detect)
    assert_json_field "$detect8" ".status" "oscillating" "Bouncing scores should oscillate"

    # Test 9: Detect stalled state
    echo "▸ Test 9: Detect stalled state"
    convergence_clear_history
    convergence_history 1 50 "stable"
    convergence_history 2 50 "stable"
    convergence_history 3 50 "stable"
    local detect9
    detect9=$(convergence_detect)
    assert_json_field "$detect9" ".status" "stalled" "Unchanged scores should stall"

    # Test 10: Detect progressing state
    echo "▸ Test 10: Detect progressing state"
    convergence_clear_history
    convergence_history 1 50 "stable"
    convergence_history 2 55 "improving"
    convergence_history 3 60 "improving"
    local detect10
    detect10=$(convergence_detect)
    assert_json_field "$detect10" ".status" "progressing" "Rising scores should progress"

    # Test 11: Suggest action for stalled
    echo "▸ Test 11: Suggest action for stalled state"
    local action11
    action11=$(convergence_suggest_action "stalled" 5)
    assert_json_field "$action11" ".action" "change_approach" "Stalled should suggest change_approach"

    # Test 12: Suggest action for diverging
    echo "▸ Test 12: Suggest action for diverging state"
    local action12
    action12=$(convergence_suggest_action "diverging" 6)
    assert_json_field "$action12" ".action" "escalate_model" "Diverging should suggest escalate_model"

    # Test 13: Suggest action for oscillating
    echo "▸ Test 13: Suggest action for oscillating state"
    local action13
    action13=$(convergence_suggest_action "oscillating" 7)
    assert_json_field "$action13" ".action" "restart_session" "Oscillating should suggest restart"

    # Test 14: Score with large code changes (>50 lines)
    echo "▸ Test 14: Score with large code changes should cap bonus"
    local score14
    score14=$(convergence_score_iteration 5 true true 150 0 50)
    local s14
    s14=$(echo "$score14" | jq -r '.score' 2>/dev/null || echo "0")
    if [[ "$s14" -le 100 ]]; then
        PASS=$((PASS + 1))
        success "✓ Score capped at 100 (got: $s14)"
    else
        FAIL=$((FAIL + 1))
        error "✗ Score should not exceed 100 (got: $s14)"
    fi

    # Test 15: Score with repeated errors
    echo "▸ Test 15: Score with repeated errors"
    local score15
    score15=$(convergence_score_iteration 6 false true 20 5 50)
    local s15
    s15=$(echo "$score15" | jq -r '.score' 2>/dev/null || echo "0")
    if [[ "$s15" -lt 50 ]]; then
        PASS=$((PASS + 1))
        success "✓ Repeated errors decrease score (got: $s15)"
    else
        FAIL=$((FAIL + 1))
        error "✗ Repeated errors should decrease score (got: $s15)"
    fi

    # Test 16: Clear history
    echo "▸ Test 16: Clear history function"
    convergence_history 1 50 "stable"
    [[ -f "$ARTIFACTS_DIR/convergence-history.json" ]] || {
        FAIL=$((FAIL + 1))
        error "✗ History not created"
        return
    }
    convergence_clear_history
    if [[ ! -f "$ARTIFACTS_DIR/convergence-history.json" ]]; then
        PASS=$((PASS + 1))
        success "✓ History cleared"
    else
        FAIL=$((FAIL + 1))
        error "✗ History not cleared"
    fi

    # Test 17: Read status
    echo "▸ Test 17: Read convergence status"
    convergence_clear_history
    convergence_history 1 50 "stable"
    convergence_history 2 85 "improving"
    convergence_history 3 86 "stable"
    local status17
    status17=$(convergence_read_status)
    if [[ "$status17" == "converged" ]]; then
        PASS=$((PASS + 1))
        success "✓ Status read correctly: $status17"
    else
        FAIL=$((FAIL + 1))
        error "✗ Status should be converged, got: $status17"
    fi

    # Test 18: Confidence scores
    echo "▸ Test 18: Detect returns confidence field"
    convergence_clear_history
    convergence_history 1 50 "stable"
    convergence_history 2 85 "improving"
    convergence_history 3 86 "stable"
    local detect18
    detect18=$(convergence_detect)
    local conf18
    conf18=$(echo "$detect18" | jq -r '.confidence' 2>/dev/null || echo "")
    if [[ -n "$conf18" && "$conf18" != "null" ]]; then
        PASS=$((PASS + 1))
        success "✓ Confidence score present: $conf18"
    else
        FAIL=$((FAIL + 1))
        error "✗ Confidence score missing"
    fi

    # Test 19: Signals included in score
    echo "▸ Test 19: Score includes signals array"
    local score19
    score19=$(convergence_score_iteration 1 true true 25 0 50)
    local sig_count
    sig_count=$(echo "$score19" | jq '.signals | length' 2>/dev/null || echo "0")
    if [[ "$sig_count" -gt 0 ]]; then
        PASS=$((PASS + 1))
        success "✓ Signals array present with $sig_count entries"
    else
        FAIL=$((FAIL + 1))
        error "✗ Signals array missing"
    fi

    # Test 20: Minimal changes penalty
    echo "▸ Test 20: Minimal changes should penalize"
    local score20
    score20=$(convergence_score_iteration 1 false true 3 0 50)
    local s20
    s20=$(echo "$score20" | jq -r '.score' 2>/dev/null || echo "0")
    if [[ "$s20" -lt 50 ]]; then
        PASS=$((PASS + 1))
        success "✓ Minimal changes penalty applied (got: $s20)"
    else
        FAIL=$((FAIL + 1))
        error "✗ Should penalize minimal changes"
    fi

    # Summary
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    local total=$((PASS + FAIL))
    if [[ "$FAIL" -eq 0 ]]; then
        echo -e "║ ${GREEN}✓ ALL TESTS PASSED${RESET} ($PASS/$total)                    ║"
    else
        echo -e "║ ${RED}✗ SOME TESTS FAILED${RESET} ($PASS passed, $FAIL failed)     ║"
    fi
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    return "$FAIL"
}

# ─── Main ──────────────────────────────────────────────────────────────────

VERSION="4.0.0"
run_tests
exit "$?"
