#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-quality-checks test — Unit tests for quality     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: pipeline-quality-checks Tests"

setup_test_env "sw-lib-pipeline-quality-checks-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

# Set up quality checks env
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export SCRIPT_DIR="$SCRIPT_DIR"
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
export BASE_BRANCH="main"
export ISSUE_NUMBER="42"
export PIPELINE_CONFIG="$TEST_TEMP_DIR/pipeline-config.json"
export TEST_CMD=""
export GOAL="Test goal"

mkdir -p "$ARTIFACTS_DIR"
mkdir -p "$PROJECT_ROOT"

# Provide stubs (redirect to /dev/null so result=$(...) captures only the echoed value)
info() { :; }
success() { :; }
warn() { :; }
error() { :; }
emit_event() { :; }

# parse_coverage_from_output is used by quality_check_coverage - stub it
parse_coverage_from_output() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return
    grep -oE '[0-9]{1,3}\.[0-9]*|[0-9]{1,3}' "$log_file" 2>/dev/null | head -1 || true
}

# detect_test_cmd used by run_e2e_validation
detect_test_cmd() { echo ""; }

# Minimal pipeline config
echo '{"stages":[{"id":"test","config":{"coverage_min":0}}]}' > "$PIPELINE_CONFIG"

# Source the lib (clear guard)
_PIPELINE_QUALITY_CHECKS_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-quality-checks.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# run_test_coverage_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_test_coverage_check"

# No TEST_CMD → skip
unset TEST_CMD
result=$(run_test_coverage_check 2>/dev/null)
assert_eq "No TEST_CMD returns skip" "skip" "$result"

# TEST_CMD that outputs coverage (function echoes the percentage at end)
export TEST_CMD="echo 'Statements : 85% coverage'"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Extracts coverage from Jest/Istanbul format" "85" "$result"

# Alternative format - coverage: XX%
export TEST_CMD="echo 'coverage: 90%'"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Extracts coverage from coverage format" "90" "$result"

# Failing test command
export TEST_CMD="false"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Failing test returns 0" "0" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# run_bash_compat_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_bash_compat_check"

mock_git
# With mock_git (no changed .sh files), returns 0
cd "$PROJECT_ROOT"
result=$(run_bash_compat_check 2>/dev/null | tail -1)
cd - >/dev/null
assert_eq "No changed .sh files returns 0" "0" "${result:-0}"

# ═══════════════════════════════════════════════════════════════════════════════
# run_new_function_test_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_new_function_test_check"

cd "$PROJECT_ROOT"
result=$(run_new_function_test_check 2>/dev/null)
assert_eq "No new functions in diff returns 0" "0" "$result"
cd - >/dev/null

# ═══════════════════════════════════════════════════════════════════════════════
# run_atomic_write_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_atomic_write_check"

cd "$PROJECT_ROOT"
result=$(run_atomic_write_check 2>/dev/null)
assert_eq "No state/config changes returns 0" "0" "$result"
cd - >/dev/null

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_coverage
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_coverage"

# No test-results.log → skip (returns 0)
rm -f "$ARTIFACTS_DIR/test-results.log"
if quality_check_coverage 2>/dev/null; then
    assert_pass "quality_check_coverage passes when no test log"
else
    assert_fail "quality_check_coverage"
fi

# Create test-results.log with coverage
echo "Statements : 82.5%
Lines : 80%
Test Results: 10 passed" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_coverage 2>/dev/null; then
    assert_pass "quality_check_coverage passes with coverage data"
else
    assert_fail "quality_check_coverage"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_security
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_security"

cd "$PROJECT_ROOT"
rm -f package.json requirements.txt Cargo.toml pyproject.toml
if quality_check_security 2>/dev/null; then
    assert_pass "quality_check_security skips when no audit tool"
else
    assert_fail "quality_check_security"
fi
assert_file_exists "Creates security-audit.log" "$ARTIFACTS_DIR/security-audit.log"
content=$(cat "$ARTIFACTS_DIR/security-audit.log")
assert_contains "Audit log has content" "$content" "No audit tool"
cd - >/dev/null

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_bundle_size
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_bundle_size"

cd "$PROJECT_ROOT"
rm -rf dist build out .next target
if quality_check_bundle_size 2>/dev/null; then
    assert_pass "quality_check_bundle_size skips when no build dir"
else
    assert_fail "quality_check_bundle_size"
fi
cd - >/dev/null

# With build dir
mkdir -p "$PROJECT_ROOT/dist"
echo "mock bundle content" > "$PROJECT_ROOT/dist/bundle.js"
if quality_check_bundle_size 2>/dev/null; then
    assert_pass "quality_check_bundle_size passes with build dir"
else
    assert_fail "quality_check_bundle_size"
fi
assert_file_exists "Creates bundle-metrics.log" "$ARTIFACTS_DIR/bundle-metrics.log"

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_perf_regression
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_perf_regression"

rm -f "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression skips without test log"
else
    assert_fail "quality_check_perf_regression"
fi

echo "passed in 12.34s" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression with duration"
else
    assert_fail "quality_check_perf_regression"
fi

print_test_results
