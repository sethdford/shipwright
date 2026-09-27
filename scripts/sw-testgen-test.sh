#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright testgen test — Test generation & coverage tests              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/testgen"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
    rev-parse)
        case "\${2:-}" in
            --show-toplevel) echo "$TEST_TEMP_DIR/repo" ;;
            *) echo "$TEST_TEMP_DIR/repo" ;;
        esac
        ;;
    diff) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Create a sample script with functions to analyze
    cat > "$TEST_TEMP_DIR/repo/scripts/sample-target.sh" <<'SAMPLE'
#!/usr/bin/env bash
set -euo pipefail

alpha_func() {
    echo "alpha"
}

beta_func() {
    echo "beta"
}

gamma_func() {
    echo "gamma"
}
SAMPLE

    # Create a mock test file that tests alpha_func
    cat > "$TEST_TEMP_DIR/repo/scripts/sample-target-test.sh" <<'TESTFILE'
#!/usr/bin/env bash
# Tests for sample-target
alpha_func  # tested
TESTFILE

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT



echo ""
print_test_header "Shipwright Testgen Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" help 2>&1) || true
assert_contains "help shows usage text" "$output" "shipwright testgen"

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-testgen.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "COMMANDS"

# ─── Test 4: Unknown command exits 1 ─────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-testgen.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown command exits 1"
else
    assert_pass "unknown command exits 1"
fi

# ─── Test 5: Coverage analysis on target file ────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" coverage "$TEST_TEMP_DIR/repo/scripts/sample-target.sh" 2>&1) || true
assert_contains "coverage shows analysis" "$output" "Coverage Analysis"

# ─── Test 6: Coverage JSON output ────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" coverage "$TEST_TEMP_DIR/repo/scripts/sample-target.sh" json 2>&1) || true
if echo "$output" | jq '.' >/dev/null 2>&1; then
    assert_pass "coverage JSON is valid"
else
    assert_fail "coverage JSON is valid" "output: $output"
fi

# ─── Test 7: Threshold show ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" threshold show 2>&1) || true
assert_contains "threshold show outputs value" "$output" "coverage threshold"

# ─── Test 8: Threshold set ───────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" threshold set 80 2>&1) || true
assert_contains "threshold set confirms" "$output" "set to 80"

# ─── Test 9: Quality scoring on test file ─────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" quality "$TEST_TEMP_DIR/repo/scripts/sample-target-test.sh" 2>&1) || true
assert_contains "quality scoring runs" "$output" "Scoring test quality"

# ─── Test 10: Quality on missing file ────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-testgen.sh" quality "/nonexistent/path.sh" >/dev/null 2>&1; then
    assert_fail "quality on missing file exits nonzero"
else
    assert_pass "quality on missing file exits nonzero"
fi

# ─── Test 11: Gaps detection ─────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" gaps "$TEST_TEMP_DIR/repo/scripts/sample-target.sh" 2>&1) || true
assert_contains "gaps shows untested functions" "$output" "Finding test gaps"

# ─── Test 12: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep "^VERSION=" "$SCRIPT_DIR/sw-testgen.sh" | head -1)
assert_contains "VERSION is defined" "$version_line" "VERSION="

echo ""
echo ""
print_test_results
