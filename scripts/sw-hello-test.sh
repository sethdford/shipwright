#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-hello-test.sh — Hello Command Test Suite                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-isolate.sh"
sw_test_isolate
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

assert_exit_code() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected exit code: $expected"
        echo "    Actual exit code:   $actual"
    fi
}

# ─── Test: hello command outputs "hello world" ──────────────────────────────
test_hello_output() {
    local output
    output=$("$SCRIPT_DIR/sw-hello.sh")
    assert_equals "hello world" "$output" "hello command outputs 'hello world'"
}

# ─── Test: hello command exits with 0 ───────────────────────────────────────
test_hello_exit_code() {
    "$SCRIPT_DIR/sw-hello.sh" > /dev/null 2>&1
    assert_exit_code 0 $? "hello command exits with code 0"
}

# ─── Test: hello --help shows help text ─────────────────────────────────────
test_hello_help() {
    local output
    output=$("$SCRIPT_DIR/sw-hello.sh" --help)
    if [[ "$output" =~ "USAGE" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m hello --help displays help text"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m hello --help displays help text"
    fi
}

# ─── Test: hello -h shows help text ──────────────────────────────────────────
test_hello_short_help() {
    local output
    output=$("$SCRIPT_DIR/sw-hello.sh" -h)
    if [[ "$output" =~ "USAGE" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m hello -h displays help text"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m hello -h displays help text"
    fi
}

# ─── Test: hello --version shows version ────────────────────────────────────
test_hello_version() {
    local output
    output=$("$SCRIPT_DIR/sw-hello.sh" --version)
    if [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m hello --version displays version"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m hello --version displays version"
    fi
}

# ─── Test: hello with invalid option exits non-zero ────────────────────────
test_hello_invalid_option() {
    "$SCRIPT_DIR/sw-hello.sh" --invalid > /dev/null 2>&1 || local exit_code=$?
    assert_exit_code 1 "${exit_code:-1}" "hello with invalid option exits with code 1"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-hello-test.sh"
test_hello_output
test_hello_exit_code
test_hello_help
test_hello_short_help
test_hello_version
test_hello_invalid_option

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
