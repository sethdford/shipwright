#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-test-holdout-test.sh — Test Holdout System Test Suite               ║
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

assert_ge() {
    local threshold="$1" actual="$2" description="${3:-}"
    if [[ "$actual" -ge "$threshold" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected >= $threshold, got: $actual"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/holdout-test-XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}/holdout-test-$$")
mkdir -p "$TMPDIR_TEST" 2>/dev/null || true
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create a mock project with test files
TEST_PROJECT="$TMPDIR_TEST/mock-project"
mkdir -p "$TEST_PROJECT/src" "$TEST_PROJECT/tests"

# Create mock test files (enough for partition to work)
for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "test('example $i', () => { expect(true).toBe(true); });" > "$TEST_PROJECT/tests/feature${i}.test.js"
done

# Override holdout dirs to use temp
export HOLDOUT_DIR="$TMPDIR_TEST/holdout"
export HOLDOUT_SEALED_DIR="$HOLDOUT_DIR/.sealed"
export HOLDOUT_MANIFEST="$HOLDOUT_DIR/manifest.json"
export HOLDOUT_RESULTS="$HOLDOUT_DIR/results.json"
export HOLDOUT_RATIO=30

# Source the module
source "$SCRIPT_DIR/lib/test-holdout.sh"

# ─── Test: holdout_discover_tests finds JS test files ──────────────────────
test_discover_js_tests() {
    local result
    result=$(holdout_discover_tests "$TEST_PROJECT" "javascript")
    local count
    count=$(echo "$result" | grep -c '.' 2>/dev/null) || count=0
    assert_equals "10" "$count" "discover finds all 10 JS test files"
}

# ─── Test: holdout_partition splits tests into visible/sealed ──────────────
test_partition_splits() {
    holdout_partition "$TEST_PROJECT" "javascript" 30 >/dev/null 2>&1
    assert_ge 1 "${HOLDOUT_SEALED_COUNT:-0}" "partition produces at least 1 holdout test"
    assert_ge 1 "${HOLDOUT_VISIBLE_COUNT:-0}" "partition produces at least 1 visible test"
}

# ─── Test: partition total equals sum of visible + sealed ──────────────────
test_partition_sum() {
    holdout_partition "$TEST_PROJECT" "javascript" 30 >/dev/null 2>&1
    local sum=$(( ${HOLDOUT_VISIBLE_COUNT:-0} + ${HOLDOUT_SEALED_COUNT:-0} ))
    assert_equals "${HOLDOUT_TOTAL:-0}" "$sum" "visible + sealed = total tests"
}

# ─── Test: partition creates visible-tests.txt ─────────────────────────────
test_partition_creates_file() {
    holdout_partition "$TEST_PROJECT" "javascript" 30 >/dev/null 2>&1
    assert_file_exists "$HOLDOUT_DIR/visible-tests.txt" "partition creates visible-tests.txt"
}

# ─── Test: holdout_seal copies tests to sealed dir ─────────────────────────
test_seal_copies_tests() {
    holdout_partition "$TEST_PROJECT" "javascript" 30 >/dev/null 2>&1
    holdout_seal "$TEST_PROJECT" >/dev/null 2>&1
    assert_file_exists "$HOLDOUT_MANIFEST" "seal creates manifest.json"
    # Verify sealed dir has files
    local sealed_count
    sealed_count=$(find "$HOLDOUT_SEALED_DIR" -name "*.test.js" 2>/dev/null | wc -l | tr -d ' ')
    assert_ge 1 "$sealed_count" "seal copies at least 1 file to sealed dir"
}

# ─── Test: manifest contains valid JSON with required fields ───────────────
test_manifest_structure() {
    holdout_partition "$TEST_PROJECT" "javascript" 30 >/dev/null 2>&1
    holdout_seal "$TEST_PROJECT" >/dev/null 2>&1
    local ratio
    ratio=$(jq -r '.ratio' "$HOLDOUT_MANIFEST" 2>/dev/null || echo "FAIL")
    assert_equals "30" "$ratio" "manifest contains correct ratio"
    local sealed
    sealed=$(jq -r '.sealed_count' "$HOLDOUT_MANIFEST" 2>/dev/null || echo "0")
    assert_ge 1 "$sealed" "manifest records sealed count >= 1"
}

# ─── Test: holdout_validate with no manifest returns success ───────────────
test_validate_no_manifest() {
    local tmp_clean="$TMPDIR_TEST/clean-project"
    mkdir -p "$tmp_clean"
    # Override manifest path to non-existent
    local old_manifest="$HOLDOUT_MANIFEST"
    HOLDOUT_MANIFEST="$tmp_clean/nonexistent.json"
    local result=0
    holdout_validate "$tmp_clean" "echo" >/dev/null 2>&1 || result=$?
    assert_equals "0" "$result" "validate with no manifest returns 0 (skip)"
    HOLDOUT_MANIFEST="$old_manifest"
}

# ─── Test: holdout_reveal with results shows pass rate ─────────────────────
test_reveal_shows_results() {
    # Create mock results
    mkdir -p "$HOLDOUT_DIR"
    cat > "$HOLDOUT_RESULTS" <<'EOF'
{"validated_at":"2026-01-01T00:00:00Z","total":3,"passed":3,"failed":0,"pass_rate":100,"failed_tests":[]}
EOF
    local output
    output=$(holdout_reveal 2>&1)
    assert_contains "3/3" "$output" "reveal shows pass count"
}

# ─── Test: holdout_reveal with no results warns ───────────────────────────
test_reveal_no_results() {
    rm -f "$HOLDOUT_RESULTS"
    local output
    output=$(holdout_reveal 2>&1)
    assert_contains "No holdout results" "$output" "reveal warns when no results"
}

# ─── Test: holdout_reveal with failures shows failed tests ─────────────────
test_reveal_failures() {
    mkdir -p "$HOLDOUT_DIR"
    cat > "$HOLDOUT_RESULTS" <<'EOF'
{"validated_at":"2026-01-01T00:00:00Z","total":3,"passed":1,"failed":2,"pass_rate":33,"failed_tests":["test_a.js","test_b.js"]}
EOF
    local output
    output=$(holdout_reveal 2>&1)
    assert_contains "1/3" "$output" "reveal shows 1/3 pass count on failure"
}

# ─── Test: module guard prevents double-source ─────────────────────────────
test_module_guard() {
    assert_equals "1" "$_TEST_HOLDOUT_LOADED" "module guard variable is set"
}

# ─── Test: partition with no tests returns error ───────────────────────────
test_partition_no_tests() {
    local empty_dir="$TMPDIR_TEST/empty-project"
    mkdir -p "$empty_dir"
    local result=0
    holdout_partition "$empty_dir" "javascript" 30 >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "partition returns 1 when no tests found"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-test-holdout-test.sh"
test_discover_js_tests
test_partition_splits
test_partition_sum
test_partition_creates_file
test_seal_copies_tests
test_manifest_structure
test_validate_no_manifest
test_reveal_shows_results
test_reveal_no_results
test_reveal_failures
test_module_guard
test_partition_no_tests

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
