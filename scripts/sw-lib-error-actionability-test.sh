#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  error-actionability test suite                                          ║
# ║  Tests scoring logic, enhancement, and edge cases                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: error-actionability Tests"

setup_test_env "sw-lib-error-actionability-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

# Source the library
source "$SCRIPT_DIR/lib/error-actionability.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Assertion helpers
# ═══════════════════════════════════════════════════════════════════════════════

assert_score() {
  local desc="$1"
  local error_msg="$2"
  local expected="$3"

  local actual
  actual=$(get_error_score "$error_msg" || echo "0")

  assert_eq "score: $desc" "$expected" "$actual"
}

assert_has_component() {
  local desc="$1"
  local error_msg="$2"
  local component="$3"

  local json
  json=$(score_error_actionability "$error_msg" || echo "{}")

  local has_component
  has_component=$(echo "$json" | grep -o "\"$component\"[[:space:]]*:[[:space:]]*[01]" | grep -o "[01]$" || echo "0")

  assert_eq "component: $desc" "1" "$has_component"
}

assert_needs_enhancement() {
  local desc="$1"
  local error_msg="$2"
  local should_need="${3:-true}"

  local score
  score=$(get_error_score "$error_msg" || echo "0")

  local needs_it=false
  [[ $score -lt 70 ]] && needs_it=true

  assert_eq "enhancement: $desc" "$should_need" "$needs_it"
}

assert_contains_category() {
  local desc="$1"
  local error_msg="$2"
  local category="$3"

  local enhanced
  enhanced=$(enhance_error_message "$error_msg" || echo "")

  assert_contains "category: $desc" "$enhanced" "[$category]"
}

# ═══════════════════════════════════════════════════════════════════════════════
# File Path Detection
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "File Path Detection"
assert_has_component "absolute path" "/path/to/file.sh: error" "filepath"
assert_has_component "relative path" "./scripts/file.sh: error" "filepath"
assert_score "no path scores 0" "error with no path" "0"

# ═══════════════════════════════════════════════════════════════════════════════
# Line Number Detection
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Line Number Detection"
assert_has_component "colon format" "file.sh:42: error" "line_number"
assert_has_component "'at line' format" "error at line 123" "line_number"
assert_score "no line number scores 0" "error message" "0"

# ═══════════════════════════════════════════════════════════════════════════════
# Error Type Detection
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Error Type Detection"
assert_has_component "TypeError" "TypeError: bad property" "error_type"
assert_has_component "SyntaxError" "SyntaxError: unexpected" "error_type"
assert_has_component "ENOENT" "ENOENT: file not found" "error_type"
assert_has_component "Generic Error" "Error: something bad" "error_type"

# ═══════════════════════════════════════════════════════════════════════════════
# Actionable Detail Detection
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Actionable Detail Detection"
assert_has_component "'cannot' keyword" "cannot read file" "actionable_detail"
assert_has_component "'does not exist'" "file does not exist" "actionable_detail"
assert_has_component "'permission denied'" "permission denied" "actionable_detail"
assert_has_component "'is not a function'" "is not a function" "actionable_detail"
assert_has_component "'failed to'" "failed to initialize" "actionable_detail"

# ═══════════════════════════════════════════════════════════════════════════════
# Fix Suggestion Detection
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Fix Suggestion Detection"
assert_has_component "'try' keyword" "try installing package" "fix_suggestion"
assert_has_component "'check' keyword" "check your config" "fix_suggestion"
assert_has_component "'ensure' keyword" "ensure NODE_ENV is set" "fix_suggestion"
assert_has_component "'run' keyword" "run npm install first" "fix_suggestion"
assert_has_component "'remove' keyword" "remove the cache" "fix_suggestion"

# ═══════════════════════════════════════════════════════════════════════════════
# Score Calculations
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Score Calculations"
assert_score "all 5 components" "/path/file.sh:42: TypeError: cannot read property, try fixing" "100"
assert_score "3 components (path+line+error)" "/path/file.sh:42: TypeError" "65"
assert_score "2 components (actionable+fix)" "cannot read property, try installing" "35"
assert_score "no components" "oops" "0"

# ═══════════════════════════════════════════════════════════════════════════════
# Enhancement Thresholds
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Enhancement Thresholds"
assert_needs_enhancement "high score (>=70)" "/path/file.sh:42: TypeError: cannot read, try fixing" "false"
assert_needs_enhancement "low score (<70)" "bad error" "true"
assert_needs_enhancement "threshold at 70" "/path/file.sh:42: TypeError: cannot read property" "false"

# ═══════════════════════════════════════════════════════════════════════════════
# Error Categorization
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Error Categorization"
assert_contains_category "FILE_ACCESS" "cannot read file" "FILE_ACCESS"
assert_contains_category "FUNCTION_ERROR" "is not a function" "FUNCTION_ERROR"
assert_contains_category "SYNTAX_ERROR" "unexpected token" "SYNTAX_ERROR"
assert_contains_category "TYPE_ERROR" "is not a valid type" "TYPE_ERROR"
assert_contains_category "ASSERTION_FAILURE" "assertion failed" "ASSERTION_FAILURE"
assert_contains_category "TIMEOUT" "operation timed out" "TIMEOUT"
assert_contains_category "MEMORY_ERROR" "out of memory" "MEMORY_ERROR"
assert_contains_category "NETWORK_ERROR" "ECONNREFUSED network" "NETWORK_ERROR"

# ═══════════════════════════════════════════════════════════════════════════════
# Location Extraction
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Location Extraction"

loc_json=$(erract_extract_location "file.sh:42: error message")
assert_contains "file:line format" "$loc_json" "42"
assert_contains "file extraction" "$loc_json" "file.sh"

loc_json=$(erract_extract_location "error at line 123")
assert_contains "at line format" "$loc_json" "123"

loc_json=$(erract_extract_location 'File "test.py", line 456')
assert_contains "File format" "$loc_json" "456"

# ═══════════════════════════════════════════════════════════════════════════════
# Deduplication
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Error Deduplication"

dedup_result=$(erract_deduplicate "line 1
line 2
line 2
line 2
line 3")
assert_contains "deduplicates repeated lines" "$dedup_result" "repeated 2 times"

# ANSI codes should be stripped
dedup_result=$(erract_deduplicate $'line 1\n\x1b[32mline 2\x1b[0m\nline 3')
if [[ ! "$dedup_result" =~ $'\x1b' ]]; then
    assert_pass "ANSI codes stripped"
else
    assert_fail "ANSI codes not stripped"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Error Classification
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Error Classification"

class=$(erract_classify "SyntaxError: unexpected token")
assert_eq "classify syntax error" "syntax" "$class"

class=$(erract_classify "TypeError: is not a function")
assert_eq "classify type error" "type" "$class"

class=$(erract_classify "AssertionError: expected foo to equal bar")
assert_eq "classify assertion" "assertion" "$class"

class=$(erract_classify "Segmentation fault (core dumped)")
assert_eq "classify runtime error" "runtime" "$class"

class=$(erract_classify "Error: cannot find module 'lodash'")
assert_eq "classify dependency error" "dependency" "$class"

class=$(erract_classify "EACCES: permission denied")
assert_eq "classify permission error" "permission" "$class"

class=$(erract_classify "ECONNREFUSED: connection refused")
assert_eq "classify network error" "network" "$class"

class=$(erract_classify "Unknown strange error with no pattern")
assert_eq "classify unknown error" "unknown" "$class"

print_test_results
