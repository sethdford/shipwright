#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-auto-recovery-test.sh — Auto Recovery System Test Suite             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" description="${3:-}"
    if echo "$haystack" | grep -F "$needle" >/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    Actual: $haystack"
    fi
}

assert_file_exists() {
    local path="$1" description="${2:-}"
    if [[ -f "$path" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    File not found: $path"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/auto-recovery-test-XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}/auto-recovery-test-$$")
mkdir -p "$TMPDIR_TEST" 2>/dev/null || true
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Override state/log paths to temp
export RECOVERY_STATE_FILE="$TMPDIR_TEST/recovery-state.json"
export RECOVERY_PATTERNS_FILE="$TMPDIR_TEST/recovery-patterns.json"
export RECOVERY_LOG_FILE="$TMPDIR_TEST/recovery-log.jsonl"
export RECOVERY_MAX_ATTEMPTS=4

# Source the module
source "$SCRIPT_DIR/lib/auto-recovery.sh"

# ─── Test: classify syntax error ──────────────────────────────────────────
test_classify_syntax_error() {
    local result
    result=$(recovery_classify_error "SyntaxError: Unexpected token }")
    assert_equals "syntax_error" "$result" "classifies syntax error"
}

# ─── Test: classify type error ────────────────────────────────────────────
test_classify_type_error() {
    local result
    result=$(recovery_classify_error "TypeError: Cannot find name 'foo'")
    assert_equals "type_error" "$result" "classifies type error"
}

# ─── Test: classify import error ──────────────────────────────────────────
test_classify_import_error() {
    local result
    result=$(recovery_classify_error "Error: Cannot find module './missing'")
    assert_equals "import_error" "$result" "classifies import error"
}

# ─── Test: classify timeout ──────────────────────────────────────────────
test_classify_timeout() {
    local result
    result=$(recovery_classify_error "Error: Operation timed out after 30s")
    assert_equals "timeout" "$result" "classifies timeout error"
}

# ─── Test: classify permission error ─────────────────────────────────────
test_classify_permission() {
    local result
    result=$(recovery_classify_error "Error: Permission denied (EACCES)")
    assert_equals "permission_error" "$result" "classifies permission error"
}

# ─── Test: classify test assertion ────────────────────────────────────────
test_classify_assertion() {
    local result
    result=$(recovery_classify_error "AssertionError: Expected 5 to equal 10")
    assert_equals "test_assertion" "$result" "classifies test assertion"
}

# ─── Test: classify empty input returns unknown ──────────────────────────
test_classify_empty() {
    local result
    result=$(recovery_classify_error "")
    assert_equals "unknown" "$result" "empty input classified as unknown"
}

# ─── Test: classify null reference ───────────────────────────────────────
test_classify_null() {
    local result
    result=$(recovery_classify_error "ReferenceError: undefined is not a function")
    assert_equals "null_reference" "$result" "classifies null/undefined reference"
}

# ─── Test: recovery_get_strategy returns strategy for known category ─────
test_get_strategy() {
    local result
    result=$(recovery_get_strategy "syntax_error")
    assert_contains "retry_with_context" "$result" "syntax_error gets retry_with_context strategy"
}

# ─── Test: recovery_get_strategy returns flag_human for permission ───────
test_get_strategy_permission() {
    local result
    result=$(recovery_get_strategy "permission_error")
    assert_contains "flag_human" "$result" "permission_error gets flag_human strategy"
}

# ─── Test: recovery_attempt succeeds on first try ────────────────────────
test_attempt_succeeds() {
    rm -f "$RECOVERY_STATE_FILE"
    local result=0
    recovery_attempt "SyntaxError: Unexpected token" "$TMPDIR_TEST" "" >/dev/null 2>&1 || result=$?
    assert_equals "0" "$result" "recovery_attempt succeeds on retryable error"
    assert_file_exists "$RECOVERY_STATE_FILE" "recovery creates state file"
}

# ─── Test: recovery_attempt exhaustion ───────────────────────────────────
test_attempt_exhaustion() {
    # Set state to max attempts already used
    mkdir -p "$(dirname "$RECOVERY_STATE_FILE")"
    echo '{"attempts":4,"history":[],"current_model":"","escalation_level":0}' > "$RECOVERY_STATE_FILE"
    local result=0
    recovery_attempt "some error" "$TMPDIR_TEST" "" >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "recovery fails when attempts exhausted"
}

# ─── Test: recovery_reset clears state ───────────────────────────────────
test_reset() {
    # Create state with some attempts
    mkdir -p "$(dirname "$RECOVERY_STATE_FILE")"
    echo '{"attempts":3,"history":[{"attempt":1}],"current_model":"sonnet","escalation_level":1}' > "$RECOVERY_STATE_FILE"
    recovery_reset >/dev/null 2>&1
    local attempts
    attempts=$(jq -r '.attempts' "$RECOVERY_STATE_FILE" 2>/dev/null || echo "FAIL")
    assert_equals "0" "$attempts" "reset clears attempt counter to 0"
}

# ─── Test: recovery_before_circuit_breaker with error log ────────────────
test_before_circuit_breaker() {
    rm -f "$RECOVERY_STATE_FILE"
    local error_log="$TMPDIR_TEST/error-log.jsonl"
    echo '{"error":"TypeError: Cannot read property of null"}' > "$error_log"
    local result=0
    recovery_before_circuit_breaker "$error_log" "$TMPDIR_TEST" "" >/dev/null 2>&1 || result=$?
    assert_equals "0" "$result" "before_circuit_breaker recovers from error log"
}

# ─── Test: recovery_before_circuit_breaker with no error ─────────────────
test_before_circuit_breaker_no_error() {
    local result=0
    recovery_before_circuit_breaker "" "$TMPDIR_TEST" "" >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "before_circuit_breaker fails with no error context"
}

# ─── Test: module guard ──────────────────────────────────────────────────
test_module_guard() {
    assert_equals "1" "$_AUTO_RECOVERY_LOADED" "module guard variable is set"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-auto-recovery-test.sh"
test_classify_syntax_error
test_classify_type_error
test_classify_import_error
test_classify_timeout
test_classify_permission
test_classify_assertion
test_classify_empty
test_classify_null
test_get_strategy
test_get_strategy_permission
test_attempt_succeeds
test_attempt_exhaustion
test_reset
test_before_circuit_breaker
test_before_circuit_breaker_no_error
test_module_guard

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
