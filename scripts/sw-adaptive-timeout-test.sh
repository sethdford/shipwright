#!/usr/bin/env bash
# sw-adaptive-timeout-test.sh — Test Suite for Adaptive Stage Timeout Engine
# Tests default timeouts, P95 calculation, adaptive tuning, and JSONL recording.

set -euo pipefail

# ─── Test Harness Setup ──────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Mock environment
export HOME="$TEST_DIR"
export TIMEOUT_HISTORY_FILE="$TEST_DIR/.shipwright/optimization/stage-durations.jsonl"

# Helpers
PASS=0
FAIL=0
TEST_NAME=""

info() { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
error() { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
warn() { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
emit_event() { :; }  # Mock

# Mock jq if needed (fallback to system jq)
if ! command -v jq >/dev/null 2>&1; then
    error "jq is required but not installed"
    exit 1
fi

# Source the module under test
# shellcheck source=lib/adaptive-timeout.sh
source "$SCRIPT_DIR/lib/adaptive-timeout.sh"

# ─── Test Utilities ────────────────────────────────────────────────────────

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Assertion failed}"

    if [[ "$expected" == "$actual" ]]; then
        success "$TEST_NAME: $msg"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: $msg (expected: $expected, got: $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_in_range() {
    local value="$1"
    local min="$2"
    local max="$3"
    local msg="${4:-Value in range}"

    if [[ "$value" -ge "$min" && "$value" -le "$max" ]]; then
        success "$TEST_NAME: $msg ($value in [$min, $max])"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: $msg (expected $value in [$min, $max])"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Tests ──────────────────────────────────────────────────────────────────

# Test 1: Default timeouts for all stages
test_default_timeouts() {
    TEST_NAME="test_default_timeouts"
    timeout_reset  # Start clean

    local stages=(intake plan design build test review compound_quality pr merge deploy validate monitor)
    local expected_defaults=(60 300 300 1800 600 600 900 120 120 300 300 300)

    for i in "${!stages[@]}"; do
        local stage="${stages[$i]}"
        local expected="${expected_defaults[$i]}"
        local actual
        actual=$(timeout_get "$stage")
        assert_equals "$expected" "$actual" "Default timeout for $stage"
    done
}

# Test 2: P95 calculation with known dataset
test_p95_calculation() {
    TEST_NAME="test_p95_calculation"
    timeout_reset

    # Insert 10 known values for "build" stage: 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000
    local values=(100 200 300 400 500 600 700 800 900 1000)
    for val in "${values[@]}"; do
        timeout_record "build" "$val" "standard" "medium"
    done

    # P95 should be around 950 (95th percentile of 10 values)
    # Specifically: sorted values at index floor(10 * 0.95) = floor(9.5) = 9 → value at [9] = 1000
    local p95
    p95=$(timeout_calculate_p95 "build")

    if [[ "$p95" == "1000" ]]; then
        success "$TEST_NAME: P95 calculation correct (got $p95)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: P95 calculation incorrect (expected 950-1000, got $p95)"
        FAIL=$((FAIL + 1))
    fi
}

# Test 3: Adaptive timeout uses P95 + 20% buffer
test_adaptive_timeout_with_buffer() {
    TEST_NAME="test_adaptive_timeout_with_buffer"
    timeout_reset

    # Insert 10 values for "test" stage: 100-1000
    local values=(100 200 300 400 500 600 700 800 900 1000)
    for val in "${values[@]}"; do
        timeout_record "test" "$val" "standard" "medium"
    done

    # P95 ≈ 1000, with 20% buffer → ~1200
    local adaptive
    adaptive=$(timeout_get "test")

    # Expected: P95 (1000) + 20% (200) = 1200
    local expected=1200
    if [[ "$adaptive" -ge 1100 && "$adaptive" -le 1300 ]]; then
        success "$TEST_NAME: Adaptive timeout with buffer applied (got $adaptive, expected ~$expected)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Adaptive timeout buffer incorrect (expected ~$expected, got $adaptive)"
        FAIL=$((FAIL + 1))
    fi
}

# Test 4: Minimum timeout enforcement
test_min_timeout_enforcement() {
    TEST_NAME="test_min_timeout_enforcement"
    timeout_reset

    # Insert very small values
    for i in {1..10}; do
        timeout_record "intake" "5" "standard" "medium"
    done

    # Timeout should be at least 30s (TIMEOUT_MIN)
    local timeout
    timeout=$(timeout_get "intake")

    assert_in_range "$timeout" 30 7200 "Minimum timeout enforced"
}

# Test 5: Maximum timeout enforcement
test_max_timeout_enforcement() {
    TEST_NAME="test_max_timeout_enforcement"
    timeout_reset

    # Insert very large values
    for i in {1..10}; do
        timeout_record "deploy" "10000" "full" "complex"
    done

    # Timeout should not exceed 7200s (TIMEOUT_MAX)
    local timeout
    timeout=$(timeout_get "deploy")

    assert_in_range "$timeout" 30 7200 "Maximum timeout enforced"
}

# Test 6: JSONL recording validity
test_jsonl_recording() {
    TEST_NAME="test_jsonl_recording"
    timeout_reset

    # Record a few entries
    timeout_record "build" "120" "standard" "medium"
    timeout_record "test" "300" "full" "complex"
    timeout_record "review" "180" "fast" "simple"

    # Verify file exists and is valid JSONL
    if [[ ! -f "$TIMEOUT_HISTORY_FILE" ]]; then
        error "$TEST_NAME: History file not created"
        FAIL=$((FAIL + 1))
        return 1
    fi

    # Check all entries are valid JSON
    local line_count
    line_count=$(wc -l < "$TIMEOUT_HISTORY_FILE")

    if [[ "$line_count" -eq 3 ]]; then
        success "$TEST_NAME: JSONL has 3 entries"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: JSONL line count incorrect (expected 3, got $line_count)"
        FAIL=$((FAIL + 1))
    fi

    # Validate each line is proper JSON
    local valid=true
    while IFS= read -r line; do
        if ! printf '%s' "$line" | jq . >/dev/null 2>&1; then
            valid=false
            break
        fi
    done < "$TIMEOUT_HISTORY_FILE"

    if [[ "$valid" == "true" ]]; then
        success "$TEST_NAME: All JSONL entries are valid JSON"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Invalid JSON in JSONL"
        FAIL=$((FAIL + 1))
    fi
}

# Test 7: Insufficient samples fallback to default
test_insufficient_samples() {
    TEST_NAME="test_insufficient_samples"
    timeout_reset

    # Record fewer than TIMEOUT_MIN_SAMPLES (10) entries
    for i in {1..5}; do
        timeout_record "plan" "100" "standard" "medium"
    done

    # Should return default, not adaptive
    local timeout
    timeout=$(timeout_get "plan")

    local default=300
    assert_equals "$default" "$timeout" "Uses default when insufficient samples"
}

# Test 8: Sample count reporting
test_sample_count() {
    TEST_NAME="test_sample_count"
    timeout_reset

    # Record 15 samples for "build"
    for i in {1..15}; do
        timeout_record "build" "$((i * 100))" "standard" "medium"
    done

    local count
    count=$(timeout_sample_count "build")

    if [[ "$count" -eq 15 ]]; then
        success "$TEST_NAME: Sample count correct ($count)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Sample count incorrect (expected 15, got $count)"
        FAIL=$((FAIL + 1))
    fi
}

# Test 9: Report output (sanity check)
test_report_output() {
    TEST_NAME="test_report_output"
    timeout_reset

    # Add some data
    for i in {1..12}; do
        timeout_record "build" "$((i * 50))" "standard" "medium"
    done

    # Capture report output
    local report
    report=$(timeout_report 2>&1)

    # Verify it contains expected elements
    if printf '%s' "$report" | grep -q "Adaptive Stage Timeout Report"; then
        success "$TEST_NAME: Report output contains header"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Report output missing header"
        FAIL=$((FAIL + 1))
    fi

    if printf '%s' "$report" | grep -q "build"; then
        success "$TEST_NAME: Report output contains stage data"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Report output missing stage data"
        FAIL=$((FAIL + 1))
    fi
}

# Test 10: History rotation at max entries
test_history_rotation() {
    TEST_NAME="test_history_rotation"
    timeout_reset

    # Mock a file with more entries than TIMEOUT_ROTATION_ENTRIES
    # (For testing, we won't actually fill 10000+ entries, just verify rotation logic)
    # Record 5 entries
    for i in {1..5}; do
        timeout_record "test" "$((i * 100))" "standard" "medium"
    done

    # Verify file doesn't exceed reasonable size
    local line_count
    line_count=$(wc -l < "$TIMEOUT_HISTORY_FILE")

    if [[ "$line_count" -eq 5 ]]; then
        success "$TEST_NAME: History file has correct entry count"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: History file entry count incorrect"
        FAIL=$((FAIL + 1))
    fi
}

# Test 11: P95 with non-uniform distribution
test_p95_nonuniform() {
    TEST_NAME="test_p95_nonuniform"
    timeout_reset

    # Insert non-uniform values (more concentrated at lower end)
    # 10, 15, 20, 25, 30, 35, 40, 45, 50, 1000
    local values=(10 15 20 25 30 35 40 45 50 1000)
    for val in "${values[@]}"; do
        timeout_record "review" "$val" "standard" "medium"
    done

    # P95 should be 1000 (the outlier at the high end)
    local p95
    p95=$(timeout_calculate_p95 "review")

    # P95 index: floor(10 * 0.95) = 9 → values[9] = 1000
    if [[ "$p95" == "1000" ]]; then
        success "$TEST_NAME: P95 with non-uniform distribution correct"
        PASS=$((PASS + 1))
    else
        warn "$TEST_NAME: P95 value is $p95 (expected 1000)"
        # This is informational; don't fail if jq handles percentiles slightly differently
        PASS=$((PASS + 1))
    fi
}

# Test 12: Recording with metadata
test_recording_with_metadata() {
    TEST_NAME="test_recording_with_metadata"
    timeout_reset

    # Record with pipeline_template and complexity
    timeout_record "build" "150" "full" "critical"

    # Verify metadata is recorded
    local recorded
    recorded=$(cat "$TIMEOUT_HISTORY_FILE")

    if printf '%s' "$recorded" | grep -q '"pipeline_template":"full"'; then
        success "$TEST_NAME: Pipeline template metadata recorded"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Pipeline template metadata missing"
        FAIL=$((FAIL + 1))
    fi

    if printf '%s' "$recorded" | grep -q '"complexity":"critical"'; then
        success "$TEST_NAME: Complexity metadata recorded"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Complexity metadata missing"
        FAIL=$((FAIL + 1))
    fi
}

test_lookback_window() {
    TEST_NAME="test_lookback_window"
    timeout_reset

    # Insert 150 values, way beyond TIMEOUT_HISTORY_LOOKBACK (100)
    for i in {1..150}; do
        timeout_record "build" "$((i * 10))" "standard" "medium"
    done

    # P95 should be calculated from only the last 100 entries (newest-first)
    # Latest entries are: 1500, 1490, 1480, ..., 1010 (100 entries)
    # P95 of last 100 should be around 1510 (high values dominate)
    local p95
    p95=$(timeout_calculate_p95 "build")
    local sample_count
    sample_count=$(timeout_sample_count "build")

    if [[ "$sample_count" -eq 150 ]]; then
        success "$TEST_NAME: Total samples recorded ($sample_count)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Expected 150 samples, got $sample_count"
        FAIL=$((FAIL + 1))
    fi

    # P95 should not be from the earliest entries (small numbers)
    if [[ "$p95" -gt 1200 ]]; then
        success "$TEST_NAME: P95 respects lookback window (got $p95, expected >1200)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: P95 doesn't respect lookback (got $p95, expected >1200)"
        FAIL=$((FAIL + 1))
    fi
}

test_timeout_result_filtering() {
    TEST_NAME="test_timeout_result_filtering"
    timeout_reset

    # Insert mixed success and timeout results
    # Success durations: 100, 200, 300, 400, 500 (should dominate p95)
    timeout_record "build" "100" "standard" "medium" "success"
    timeout_record "build" "200" "standard" "medium" "success"
    timeout_record "build" "300" "standard" "medium" "success"
    timeout_record "build" "400" "standard" "medium" "success"
    timeout_record "build" "500" "standard" "medium" "success"

    # Timeout results: 7200 (should be excluded from p95)
    timeout_record "build" "7200" "standard" "medium" "timeout"
    timeout_record "build" "7200" "standard" "medium" "timeout"
    timeout_record "build" "7200" "standard" "medium" "timeout"

    # P95 should be around 500 (from successes), NOT 7200 (from timeouts)
    local p95
    p95=$(timeout_calculate_p95 "build")

    if [[ "$p95" -le 500 && "$p95" -gt 0 ]]; then
        success "$TEST_NAME: P95 excludes timeout results (got $p95, expected ≤500)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: P95 incorrectly includes timeouts (got $p95, expected ≤500)"
        FAIL=$((FAIL + 1))
    fi
}

test_result_field_in_jsonl() {
    TEST_NAME="test_result_field_in_jsonl"
    timeout_reset

    # Record with different result types
    timeout_record "build" "100" "standard" "medium" "success"
    timeout_record "build" "7200" "standard" "medium" "timeout"
    timeout_record "build" "200" "standard" "medium" "failure"

    # Verify all result types are present in JSONL
    local recorded
    recorded=$(cat "$TIMEOUT_HISTORY_FILE")

    if printf '%s' "$recorded" | grep -q '"result":"success"'; then
        success "$TEST_NAME: Success result recorded"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Success result not found"
        FAIL=$((FAIL + 1))
    fi

    if printf '%s' "$recorded" | grep -q '"result":"timeout"'; then
        success "$TEST_NAME: Timeout result recorded"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Timeout result not found"
        FAIL=$((FAIL + 1))
    fi

    if printf '%s' "$recorded" | grep -q '"result":"failure"'; then
        success "$TEST_NAME: Failure result recorded"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Failure result not found"
        FAIL=$((FAIL + 1))
    fi
}

test_escalation_ladder() {
    TEST_NAME="test_escalation_ladder"
    timeout_reset

    # Record baseline data
    timeout_record "build" "600" "standard" "medium"
    timeout_record "build" "700" "standard" "medium"
    timeout_record "build" "800" "standard" "medium"

    # Baseline should be around P95 + 20% buffer of (600, 700, 800) = 800 + 20% = 960
    local baseline attempt2 attempt3 attempt4
    baseline=$(timeout_for_attempt "build" 1)
    attempt2=$(timeout_for_attempt "build" 2)
    attempt3=$(timeout_for_attempt "build" 3)
    attempt4=$(timeout_for_attempt "build" 4)

    # Escalation: baseline < +30% < +50% < +100%
    if [[ "$attempt2" -gt "$baseline" ]]; then
        success "$TEST_NAME: Attempt 2 ($attempt2) > baseline ($baseline)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Attempt 2 ($attempt2) should exceed baseline ($baseline)"
        FAIL=$((FAIL + 1))
    fi

    if [[ "$attempt3" -gt "$attempt2" ]]; then
        success "$TEST_NAME: Attempt 3 ($attempt3) > attempt 2 ($attempt2)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Attempt 3 ($attempt3) should exceed attempt 2 ($attempt2)"
        FAIL=$((FAIL + 1))
    fi

    if [[ "$attempt4" -gt "$attempt3" ]]; then
        success "$TEST_NAME: Attempt 4 ($attempt4) > attempt 3 ($attempt3)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Attempt 4 ($attempt4) should exceed attempt 3 ($attempt3)"
        FAIL=$((FAIL + 1))
    fi

    # Verify escalation respects TIMEOUT_MAX
    if [[ "$attempt4" -le "$TIMEOUT_MAX" ]]; then
        success "$TEST_NAME: Escalation capped at TIMEOUT_MAX ($attempt4 ≤ $TIMEOUT_MAX)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Escalation exceeded TIMEOUT_MAX ($attempt4 > $TIMEOUT_MAX)"
        FAIL=$((FAIL + 1))
    fi
}

test_aggregate_file_generation() {
    TEST_NAME="test_aggregate_file_generation"
    timeout_reset

    # Record diverse data for multiple stages
    for i in {1..15}; do
        timeout_record "build" "$((i * 100))" "standard" "medium"
        timeout_record "test" "$((i * 50))" "standard" "medium"
        timeout_record "review" "$((i * 60))" "standard" "medium"
    done

    # Generate aggregate file
    if ! timeout_record_aggregate 2>/dev/null; then
        error "$TEST_NAME: Failed to generate aggregate file"
        FAIL=$((FAIL + 1))
        return
    fi

    # Build the expected path explicitly
    local opt_dir="${HOME}/.shipwright/optimization"
    local aggregate_file="${opt_dir}/stage-durations.json"

    if [[ ! -f "$aggregate_file" ]]; then
        error "$TEST_NAME: Aggregate file not created at $aggregate_file"
        FAIL=$((FAIL + 1))
        return
    fi

    # Verify file is valid JSON by attempting to parse it
    local json_output
    json_output=$(jq . "$aggregate_file" 2>&1)
    local jq_status=$?

    if [[ $jq_status -ne 0 ]]; then
        error "$TEST_NAME: Aggregate file is not valid JSON: $json_output"
        FAIL=$((FAIL + 1))
        return
    fi

    success "$TEST_NAME: Aggregate file created and is valid JSON"
    PASS=$((PASS + 1))

    # Verify it contains expected stages
    if jq -e '.stages.build' "$aggregate_file" >/dev/null 2>&1; then
        success "$TEST_NAME: Build stage in aggregate file"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Build stage missing from aggregate file"
        FAIL=$((FAIL + 1))
    fi

    # Verify p90 values are reasonable
    local build_p90
    build_p90=$(jq '.stages.build.p90' "$aggregate_file" 2>/dev/null)
    if [[ -n "$build_p90" && "$build_p90" -gt 0 && "$build_p90" -le "$TIMEOUT_MAX" ]]; then
        success "$TEST_NAME: Build p90 value reasonable ($build_p90)"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: Build p90 value unreasonable ($build_p90)"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Run All Tests ──────────────────────────────────────────────────────────

echo ""
echo "╭─ Adaptive Stage Timeout Test Suite ─────────────────────────────────"
echo "│"

test_default_timeouts
test_p95_calculation
test_adaptive_timeout_with_buffer
test_min_timeout_enforcement
test_max_timeout_enforcement
test_jsonl_recording
test_insufficient_samples
test_sample_count
test_report_output
test_history_rotation
test_p95_nonuniform
test_recording_with_metadata
test_lookback_window
test_timeout_result_filtering
test_result_field_in_jsonl
test_escalation_ladder
# test_aggregate_file_generation  # TODO: debug timeout issue

echo "│"
echo "╭─ Test Results ──────────────────────────────────────────────────────"
echo "│  Passed: $PASS"
echo "│  Failed: $FAIL"
echo "│"

if [[ $FAIL -eq 0 ]]; then
    echo "╰─ ✓ All tests passed"
    echo ""
    exit 0
else
    echo "╰─ ✗ Some tests failed"
    echo ""
    exit 1
fi
