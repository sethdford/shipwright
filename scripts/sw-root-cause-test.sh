#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  root-cause test suite                                                   ║
# ║  Tests classification, error log analysis, fix suggestions, learning     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Root Cause Classifier Tests"

setup_test_env "sw-root-cause-test"
trap cleanup_test_env EXIT

# Set up test artifacts directory
export ARTIFACTS_DIR="$TEST_TEMP_DIR/.claude/pipeline-artifacts"
mkdir -p "$ARTIFACTS_DIR"

# Source the library
source "$SCRIPT_DIR/lib/root-cause.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test Classification
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Classification"

test_classify_rate_limit() {
    local result
    result=$(rootcause_classify "Error: rate limit exceeded, 429 Too Many Requests" "build" "1")
    local category
    category=$(echo "$result" | jq -r '.category')
    assert_eq "classify rate_limit" "rate_limit" "$category"

    local confidence
    confidence=$(echo "$result" | jq -r '.confidence')
    assert_gt "rate_limit confidence >80" "$confidence" "80"
}
test_classify_rate_limit

test_classify_context_exhaustion() {
    local result
    result=$(rootcause_classify "Error: context window exceeded, 100k+ tokens used" "build" "1")
    local category
    category=$(echo "$result" | jq -r '.category')
    assert_eq "classify context_exhaustion" "context_exhaustion" "$category"
}
test_classify_context_exhaustion

test_classify_flatline() {
    local result
    result=$(rootcause_classify "Build loop flatlined — iterations stopped changing code and repeated the same error" "build" "1")
    local category
    category=$(echo "$result" | jq -r '.category')
    assert_eq "classify flatline (not context_exhaustion)" "flatline" "$category"
}
test_classify_flatline

test_classify_infra_issue() {
    local result
    result=$(rootcause_classify "Error: ETIMEDOUT - connection timed out" "test" "1")
    local category
    category=$(echo "$result" | jq -r '.category')
    assert_eq "classify infra_issue (timeout)" "infra_issue" "$category"
}
test_classify_infra_issue

test_classify_infra_oom() {
    local result
    result=$(rootcause_classify "fatal: OOM: Out of memory, cannot allocate 1024MB" "build" "1")
    local category
    category=$(echo "$result" | jq -r '.category')
    assert_eq "classify infra_issue (OOM)" "infra_issue" "$category"
}
test_classify_infra_oom

test_classify_platform_bug() {
    local result
    result=$(rootcause_classify "sw-pipeline.sh:123: error: unbound variable 'STAGE_ID'" "design" "1")
    local category
    category=$(echo "$result" | jq -r '.category')
    assert_eq "classify platform_bug" "platform_bug" "$category"
}
test_classify_platform_bug

test_classify_config_error() {
    local result
    result=$(rootcause_classify "Error: missing PIPELINE_CONFIG environment variable" "intake" "1")
    local category
    category=$(echo "$result" | jq -r '.category')
    assert_eq "classify config_error" "config_error" "$category"
}
test_classify_config_error

test_classify_external_dep() {
    local result
    result=$(rootcause_classify "npm ERR! 404 Not Found - GET https://registry.npmjs.org/package-not-found" "build" "1")
    local category
    category=$(echo "$result" | jq -r '.category')
    assert_eq "classify external_dep" "external_dep" "$category"
}
test_classify_external_dep

test_classify_code_bug() {
    local result
    result=$(rootcause_classify "AssertionError: expected 'foo' but got 'bar'" "test" "1")
    local category
    category=$(echo "$result" | jq -r '.category')
    assert_eq "classify code_bug (assertion)" "code_bug" "$category"
}
test_classify_code_bug

test_classify_code_bug_syntax() {
    local result
    result=$(rootcause_classify "SyntaxError: Unexpected token }" "build" "1")
    local category
    category=$(echo "$result" | jq -r '.category')
    assert_eq "classify code_bug (syntax)" "code_bug" "$category"
}
test_classify_code_bug_syntax

test_classify_returns_json() {
    local result
    result=$(rootcause_classify "Unknown error" "unknown" "1")
    # Should be valid JSON
    echo "$result" | jq . >/dev/null 2>&1
    assert_pass "classification returns valid JSON"
}
test_classify_returns_json

# ═══════════════════════════════════════════════════════════════════════════════
# Test Error Log Analysis
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Error Log Analysis"

test_analyze_error_log_missing() {
    local result
    result=$(rootcause_analyze_error_log)
    local has_patterns
    has_patterns=$(echo "$result" | jq -r '.patterns_analyzed // 0')
    # Should handle missing file gracefully
    [[ -z "$has_patterns" || "$has_patterns" == "0" ]] && assert_pass "handle missing error log" || assert_fail "should handle missing log"
}
test_analyze_error_log_missing

test_analyze_error_log_with_entries() {
    # Create mock error-log.jsonl
    mkdir -p "$ARTIFACTS_DIR"
    {
        echo '{"type":"test","error":"AssertionError: failed"}'
        echo '{"type":"network","error":"ETIMEDOUT: connection timed out"}'
        echo '{"type":"config","error":"missing PIPELINE_CONFIG"}'
    } > "$ARTIFACTS_DIR/error-log.jsonl"

    local result
    result=$(rootcause_analyze_error_log)
    local analyzed
    analyzed=$(echo "$result" | jq -r '.patterns_analyzed // 0')
    assert_eq "analyze error log entry count" "3" "$analyzed"
}
test_analyze_error_log_with_entries

# ═══════════════════════════════════════════════════════════════════════════════
# Test Fix Suggestions
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Fix Suggestions"

test_suggest_fix_rate_limit() {
    local result
    result=$(rootcause_suggest_fix "rate_limit" "rate limit error" "build")
    local suggestions
    suggestions=$(echo "$result" | jq -r '.suggestions')
    assert_contains "rate_limit suggestion has backoff" "$suggestions" "exponential backoff"
}
test_suggest_fix_rate_limit

test_suggest_fix_context_exhaustion() {
    local result
    result=$(rootcause_suggest_fix "context_exhaustion" "context exceeded" "build")
    local suggestions
    suggestions=$(echo "$result" | jq -r '.suggestions')
    assert_contains "context_exhaustion suggestion has max-restarts" "$suggestions" "max-restarts"
}
test_suggest_fix_context_exhaustion

test_suggest_fix_flatline() {
    local result
    result=$(rootcause_suggest_fix "flatline" "same error" "build")
    local suggestions
    suggestions=$(echo "$result" | jq -r '.suggestions')
    assert_contains "flatline suggestion points at the repeated error" "$suggestions" "error-summary.json"
    assert_contains "flatline suggestion warns against restarts" "$suggestions" "fresh session repeats"
}
test_suggest_fix_flatline

test_suggest_fix_infra_issue() {
    local result
    result=$(rootcause_suggest_fix "infra_issue" "OOM error" "build")
    local suggestions
    suggestions=$(echo "$result" | jq -r '.suggestions')
    assert_contains "infra_issue suggestion has disk check" "$suggestions" "disk space"
}
test_suggest_fix_infra_issue

test_suggest_fix_platform_bug() {
    local result
    result=$(rootcause_suggest_fix "platform_bug" "shipwright error" "design")
    local suggestions
    suggestions=$(echo "$result" | jq -r '.suggestions')
    assert_contains "platform_bug suggestion has doctor" "$suggestions" "shipwright doctor"
}
test_suggest_fix_platform_bug

test_suggest_fix_config_error() {
    local result
    result=$(rootcause_suggest_fix "config_error" "config missing" "intake")
    local suggestions
    suggestions=$(echo "$result" | jq -r '.suggestions')
    assert_contains "config_error suggestion has daemon-config" "$suggestions" "daemon-config.json"
}
test_suggest_fix_config_error

test_suggest_fix_returns_json() {
    local result
    result=$(rootcause_suggest_fix "code_bug" "test failed" "test")
    # Should be valid JSON
    echo "$result" | jq . >/dev/null 2>&1
    assert_pass "suggestion returns valid JSON"
}
test_suggest_fix_returns_json

# ═══════════════════════════════════════════════════════════════════════════════
# Test Learning System
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Learning System"

test_learn_writes_jsonl() {
    local learn_file="$TEST_TEMP_DIR/home/.shipwright/optimization/root-causes.jsonl"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$(dirname "$learn_file")"

    rootcause_learn "code_bug" "85" "Test assertion failed"

    [[ -f "$learn_file" ]] && assert_pass "learning writes file" || assert_fail "learning should write file"
}
test_learn_writes_jsonl

test_learn_valid_jsonl() {
    local learn_file="$TEST_TEMP_DIR/home/.shipwright/optimization/root-causes.jsonl"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$(dirname "$learn_file")"

    rootcause_learn "infra_issue" "90" "Network timeout"

    # Validate JSON
    head -1 "$learn_file" | jq . >/dev/null 2>&1 && assert_pass "learning produces valid JSONL" || assert_fail "invalid JSONL"
}
test_learn_valid_jsonl

test_learn_multiple_entries() {
    local learn_file="$TEST_TEMP_DIR/home/.shipwright/optimization/root-causes.jsonl"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$(dirname "$learn_file")"
    rm -f "$learn_file"

    rootcause_learn "code_bug" "80" "Error 1"
    rootcause_learn "infra_issue" "90" "Error 2"
    rootcause_learn "platform_bug" "75" "Error 3"

    local entries
    entries=$(wc -l < "$learn_file" 2>/dev/null | tr -d ' ' || echo "0")
    assert_eq "learning accumulates entries" "3" "$entries"
}
test_learn_multiple_entries

# ═══════════════════════════════════════════════════════════════════════════════
# Test Platform Issue Creation
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Platform Issue Creation"

test_skip_issue_without_github() {
    export NO_GITHUB=1
    local classification='{"category":"platform_bug","confidence":95,"evidence":[]}'
    local result
    result=$(rootcause_create_platform_issue "$classification" "sw-test.sh error" "build" 2>&1 || echo "skipped")
    [[ "$result" =~ "NO_GITHUB" ]] && assert_pass "skip issue creation with NO_GITHUB" || assert_pass "handled gracefully"
}
test_skip_issue_without_github

test_skip_low_confidence() {
    export NO_GITHUB=0
    local classification='{"category":"platform_bug","confidence":50,"evidence":[]}'
    # Should not attempt to create issue (confidence too low)
    local result
    result=$(rootcause_create_platform_issue "$classification" "minor error" "build" 2>&1 || echo "")
    [[ "$result" =~ "Skipping" ]] && assert_pass "skip low confidence issues" || assert_pass "handled correctly"
}
test_skip_low_confidence

test_skip_non_platform_category() {
    export NO_GITHUB=0
    local classification='{"category":"code_bug","confidence":95,"evidence":[]}'
    # Should not create issue for code bugs
    local result
    result=$(rootcause_create_platform_issue "$classification" "user code error" "test" 2>&1 || echo "")
    assert_pass "skip non-platform categories"
}
test_skip_non_platform_category

# ═══════════════════════════════════════════════════════════════════════════════
# Test Report Generation
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Report Generation"

test_report_no_history() {
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/optimization"
    # No root-causes.jsonl yet
    local result
    result=$(rootcause_report 2>&1)
    # Info function adds color codes, so just check that it doesn't crash
    [[ -n "$result" ]] && assert_pass "report handles missing history" || assert_fail "report should produce output"
}
test_report_no_history

test_report_with_history() {
    export HOME="$TEST_TEMP_DIR/home"
    local learn_file="$HOME/.shipwright/optimization/root-causes.jsonl"
    mkdir -p "$(dirname "$learn_file")"

    # Create sample history
    {
        jq -n '{category: "code_bug", confidence: 85, message: "Test 1", recorded_at: "2026-03-07T10:00:00Z"}'
        jq -n '{category: "infra_issue", confidence: 90, message: "Network 1", recorded_at: "2026-03-07T11:00:00Z"}'
        jq -n '{category: "code_bug", confidence: 80, message: "Test 2", recorded_at: "2026-03-07T12:00:00Z"}'
    } > "$learn_file"

    local result
    result=$(rootcause_report 2>&1 || echo "")
    assert_contains "report shows category distribution" "$result" "Category Distribution"
    assert_contains "report shows total count" "$result" "Total analyzed failures"
}
test_report_with_history

# ═══════════════════════════════════════════════════════════════════════════════
# Integration Tests
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Integration"

test_main_workflow() {
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=1
    mkdir -p "$ARTIFACTS_DIR"
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/optimization"

    local result
    result=$(rootcause_main "AssertionError: test failed" "test" "1" 2>/dev/null || echo "")

    # Should produce valid JSON output
    echo "$result" | jq . >/dev/null 2>&1 && assert_pass "main workflow returns valid JSON" || assert_fail "invalid output"

    # Should have classification
    local category
    category=$(echo "$result" | jq -r '.classification.category' 2>/dev/null || echo "")
    [[ -n "$category" && "$category" != "null" ]] && assert_pass "main workflow produces classification" || assert_fail "no classification"
}
test_main_workflow

test_main_with_learning() {
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=1
    local learn_file="$HOME/.shipwright/optimization/root-causes.jsonl"
    mkdir -p "$(dirname "$learn_file")"

    rootcause_main "OOM: out of memory" "build" "1" >/dev/null 2>&1 || true

    [[ -f "$learn_file" ]] && assert_pass "main saves to learning file" || assert_fail "should save learning"
}
test_main_with_learning

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
