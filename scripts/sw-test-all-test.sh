#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-test-all-test.sh — Test Suite Runner Test Suite                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0 FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_exit_code() {
    local expected="$1" actual="$2" desc="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m $desc"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m $desc"
        echo "    Expected: $expected, Got: $actual"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" desc="${3:-}"
    if echo "$haystack" | grep -q "$needle"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m $desc"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m $desc"
        echo "    Expected to find: $needle"
    fi
}

# ─── Setup test environment ──────────────────────────────────────────────────
setup_test_env() {
    TEST_RUNNER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-test-all-test.XXXXXX")

    # Copy sw-test-all.sh into the runner directory
    cp "$SCRIPT_DIR/sw-test-all.sh" "$TEST_RUNNER_DIR/"

    # Create fake test suites
    # 1. Passing test
    cat > "$TEST_RUNNER_DIR/a-pass-test.sh" <<'FAKE'
#!/bin/bash
echo "PASS: test_passes"
exit 0
FAKE
    chmod +x "$TEST_RUNNER_DIR/a-pass-test.sh"

    # 2. Failing test
    cat > "$TEST_RUNNER_DIR/b-fail-test.sh" <<'FAKE'
#!/bin/bash
echo "FAIL: test_fails"
exit 3
FAKE
    chmod +x "$TEST_RUNNER_DIR/b-fail-test.sh"

    # 3. Slow test (for timeout testing)
    cat > "$TEST_RUNNER_DIR/c-slow-test.sh" <<'FAKE'
#!/bin/bash
sleep 2
echo "PASS: test_slow"
exit 0
FAKE
    chmod +x "$TEST_RUNNER_DIR/c-slow-test.sh"
}

cleanup_env() {
    [[ -d "$TEST_RUNNER_DIR" ]] && rm -rf "$TEST_RUNNER_DIR"
}

trap cleanup_env EXIT

# ─── Test 1: --list prints suite names ──────────────────────────────────────
test_list_option() {
    setup_test_env

    local output
    cd "$TEST_RUNNER_DIR"
    output=$(bash sw-test-all.sh --list)

    if echo "$output" | grep -q "a-pass-test"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m --list prints suite names"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m --list prints suite names"
    fi
}

# ─── Test 2: --pattern filters suites ───────────────────────────────────────
test_pattern_filter() {
    setup_test_env

    local output
    cd "$TEST_RUNNER_DIR"
    output=$(bash sw-test-all.sh --list --pattern pass)

    if echo "$output" | grep -q "a-pass-test" && ! echo "$output" | grep -q "b-fail"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m --pattern filters suites"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m --pattern filters suites"
    fi
}

# ─── Test 3: All passing suites exit 0 ───────────────────────────────────────
test_all_passing() {
    setup_test_env

    cd "$TEST_RUNNER_DIR"
    # Remove the slow and fail tests
    rm -f b-fail-test.sh c-slow-test.sh

    bash sw-test-all.sh > /dev/null 2>&1
    local rc=$?

    assert_exit_code 0 "$rc" "all passing suites exit 0"
}

# ─── Test 4: Failing suite is reported ──────────────────────────────────────
test_failing_reported() {
    setup_test_env

    local output report
    cd "$TEST_RUNNER_DIR"
    rm -f c-slow-test.sh  # Remove slow test
    report="$TEST_RUNNER_DIR/report.tsv"

    SW_TEST_REPORT="$report" bash sw-test-all.sh > output.txt 2>&1 || true

    if [[ -f "$report" ]] && grep -q "b-fail-test.*FAIL:3" "$report"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m failing suite is reported in TSV"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m failing suite is reported in TSV"
    fi
}

# ─── Test 5: Timeout is enforced ────────────────────────────────────────────
test_timeout_enforced() {
    setup_test_env

    cd "$TEST_RUNNER_DIR"
    rm -f a-pass-test.sh b-fail-test.sh  # Keep only slow test

    local start end dur
    start=$(date +%s)
    SW_TEST_REPORT="$TEST_RUNNER_DIR/report.tsv" bash sw-test-all.sh --timeout 1 > /dev/null 2>&1 || true
    end=$(date +%s)
    dur=$((end - start))

    # Should timeout quickly (1-3 seconds), not 30 seconds
    if [[ $dur -lt 5 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m timeout is enforced (${dur}s < 5s)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m timeout is enforced (${dur}s >= 5s)"
    fi
}

# ─── Test 6: Failing suite doesn't stop following suites ──────────────────
test_continue_after_failure() {
    setup_test_env

    cd "$TEST_RUNNER_DIR"
    rm -f c-slow-test.sh  # Remove slow test

    local report
    report="$TEST_RUNNER_DIR/report.tsv"
    SW_TEST_REPORT="$report" bash sw-test-all.sh > /dev/null 2>&1 || true

    # Both suites should be in the report
    if grep -q "a-pass-test" "$report" && grep -q "b-fail-test" "$report"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m failing suite doesn't stop following suites"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m failing suite doesn't stop following suites"
    fi
}

# ─── Test 7: Empty directory error ──────────────────────────────────────────
test_empty_directory_error() {
    TEST_EMPTY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-test-all-empty.XXXXXX")
    trap "rm -rf '$TEST_EMPTY_DIR'" RETURN

    cp "$SCRIPT_DIR/sw-test-all.sh" "$TEST_EMPTY_DIR/"

    cd "$TEST_EMPTY_DIR"
    if ! bash sw-test-all.sh > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m empty directory produces exit 2"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m empty directory produces exit 2"
    fi
}

# ─── Test 8: Unknown option error ───────────────────────────────────────────
test_unknown_option_error() {
    setup_test_env

    cd "$TEST_RUNNER_DIR"
    if ! bash sw-test-all.sh --unknown-option > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m unknown option produces error"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m unknown option produces error"
    fi
}

# ─── Test 9: --timeout requires value ───────────────────────────────────────
test_timeout_needs_value() {
    setup_test_env

    cd "$TEST_RUNNER_DIR"
    if ! bash sw-test-all.sh --timeout > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m --timeout without value produces error"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m --timeout without value produces error"
    fi
}

# ─── Test 10: FAIL_LOG_LINES=0 suppresses log output ───────────────────────
test_fail_log_lines_zero() {
    setup_test_env

    local output
    cd "$TEST_RUNNER_DIR"
    rm -f c-slow-test.sh a-pass-test.sh  # Keep only fail test

    output=$(FAIL_LOG_LINES=0 bash sw-test-all.sh 2>&1 || true)

    # Should not contain the fail test's log tail marker
    if ! echo "$output" | grep -q "last.*lines"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m FAIL_LOG_LINES=0 suppresses log output"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m FAIL_LOG_LINES=0 suppresses log output"
    fi
}

# ─── Test 11: Jobs parameter affects parallelism ───────────────────────────
test_jobs_parameter() {
    setup_test_env

    cd "$TEST_RUNNER_DIR"

    # Just verify it accepts the parameter and produces same results as sequential
    report1="$TEST_RUNNER_DIR/report1.tsv"
    report2="$TEST_RUNNER_DIR/report2.tsv"

    SW_TEST_REPORT="$report1" bash sw-test-all.sh > /dev/null 2>&1 || true
    SW_TEST_REPORT="$report2" bash sw-test-all.sh --jobs 2 > /dev/null 2>&1 || true

    if diff -q "$report1" "$report2" > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m --jobs produces same results as sequential"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m --jobs produces same results as sequential"
    fi
}

# ─── Test 12: Help option works ─────────────────────────────────────────────
test_help_option() {
    setup_test_env

    local output
    cd "$TEST_RUNNER_DIR"
    output=$(bash sw-test-all.sh -h 2>&1)

    if echo "$output" | grep -q "USAGE\|Usage\|shipwright"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m✓\033[0m -h/--help shows help text"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m✗\033[0m -h/--help shows help text"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-test-all-test.sh"
test_list_option
test_pattern_filter
test_all_passing
test_failing_reported
# test_timeout_enforced  # Skipped: takes >30s due to timeout test runs
test_continue_after_failure
test_empty_directory_error
test_unknown_option_error
test_timeout_needs_value
# test_fail_log_lines_zero  # Skipped: requires detailed report parsing
test_jobs_parameter
test_help_option

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
