#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright e2e-orchestrator test — Test suite registry & execution      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/e2e"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock timeout (macOS doesn't have it)
    cat > "$TEST_TEMP_DIR/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
shift  # skip timeout value
exec "$@"
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/timeout"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() {
    local desc="$1"
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

echo ""
print_test_header "Shipwright E2E Orchestrator Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-e2e-orchestrator.sh" help 2>&1) || true
assert_contains "help shows usage text" "$output" "shipwright e2e"

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-e2e-orchestrator.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-e2e-orchestrator.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "COMMANDS"

# ─── Test 4: Unknown command exits nonzero ───────────────────────────────────
if bash "$SCRIPT_DIR/sw-e2e-orchestrator.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown command exits nonzero"
else
    assert_pass "unknown command exits nonzero"
fi

# ─── Test 5: Registry initialization ─────────────────────────────────────────
# Source the script to test init_registry
(
    source "$SCRIPT_DIR/sw-e2e-orchestrator.sh"
    init_registry
    echo "DONE"
) > "$TEST_TEMP_DIR/init_output.txt" 2>&1 || true
if [[ -f "$HOME/.shipwright/e2e/suite-registry.json" ]]; then
    assert_pass "registry file created on init"
else
    assert_fail "registry file created on init"
fi

# ─── Test 6: Registry is valid JSON ──────────────────────────────────────────
if jq '.' "$HOME/.shipwright/e2e/suite-registry.json" >/dev/null 2>&1; then
    assert_pass "registry is valid JSON"
else
    assert_fail "registry is valid JSON"
fi

# ─── Test 7: Registry has default suites ──────────────────────────────────────
suite_count=$(jq '.suites | length' "$HOME/.shipwright/e2e/suite-registry.json" 2>/dev/null)
if [[ "${suite_count:-0}" -ge 3 ]]; then
    assert_pass "registry has >= 3 default suites"
else
    assert_fail "registry has >= 3 default suites" "got $suite_count"
fi

# ─── Test 8: Register new suite ──────────────────────────────────────────────
(
    source "$SCRIPT_DIR/sw-e2e-orchestrator.sh"
    init_registry
    cmd_register "my-custom" "My Custom Suite" "custom" "feat1,feat2"
) > "$TEST_TEMP_DIR/register_output.txt" 2>&1 || true
output=$(cat "$TEST_TEMP_DIR/register_output.txt")
assert_contains "register adds suite" "$output" "Registered suite"

# ─── Test 9: Duplicate registration fails ────────────────────────────────────
(
    source "$SCRIPT_DIR/sw-e2e-orchestrator.sh"
    cmd_register "my-custom" "My Custom Suite" "custom" "feat1"
) > "$TEST_TEMP_DIR/dup_output.txt" 2>&1 || true
output=$(cat "$TEST_TEMP_DIR/dup_output.txt")
assert_contains "duplicate register fails" "$output" "already registered"

# ─── Test 10: Quarantine a test ──────────────────────────────────────────────
(
    source "$SCRIPT_DIR/sw-e2e-orchestrator.sh"
    init_registry
    cmd_quarantine "flaky-test-1" "Intermittent failures" "quarantine"
) > "$TEST_TEMP_DIR/quarantine_output.txt" 2>&1 || true
output=$(cat "$TEST_TEMP_DIR/quarantine_output.txt")
assert_contains "quarantine adds test" "$output" "Quarantined"

# ─── Test 11: Quarantine appears in registry ─────────────────────────────────
quarantine_count=$(jq '.quarantine | length' "$HOME/.shipwright/e2e/suite-registry.json" 2>/dev/null)
if [[ "${quarantine_count:-0}" -ge 1 ]]; then
    assert_pass "quarantine list has entry"
else
    assert_fail "quarantine list has entry" "got $quarantine_count"
fi

# ─── Test 12: Report with no results ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-e2e-orchestrator.sh" report 2>&1) || true
assert_contains "report handles no results" "$output" "No test results"

# ─── Test 13: Flaky analysis with no history ──────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-e2e-orchestrator.sh" flaky 2>&1) || true
assert_contains "flaky handles no history" "$output" "No test history"

echo ""
echo ""
print_test_results
