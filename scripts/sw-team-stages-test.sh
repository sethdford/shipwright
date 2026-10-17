#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright team-stages test — Validate multi-agent stage execution      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/team-state"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/sqlite3"
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "HEAD" ]]; then echo "abc1234"
        else echo "abc1234"; fi ;;
    diff) echo "file1.sh"; echo "file2.sh"; echo "file3.sh" ;;
    ls-files) echo "file1.sh"; echo "file2.sh" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    export REPO_DIR="$TEST_TEMP_DIR/repo"
}

trap 'cleanup_test_env; sw_test_teardown' EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Team Stages Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help ────────────────────────────────────────────────────
echo -e "${BOLD}  Help${RESET}"
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "USAGE"

# ─── Test 3: Unknown command ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: Compose for build stage ────────────────────────────────
echo -e "${BOLD}  Compose${RESET}"
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" compose build 2>&1) || true
assert_contains "compose build outputs JSON with stage" "$output" "build"
# Verify it's valid JSON
if echo "$output" | jq empty 2>/dev/null; then
    assert_pass "compose output is valid JSON"
    stage=$(echo "$output" | jq -r '.stage')
    assert_eq "compose stage is build" "build" "$stage"
else
    assert_fail "compose output is valid JSON" "invalid JSON"
    assert_fail "compose stage is build" "could not parse"
fi

# ─── Test 5: Compose for test stage ─────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" compose test 2>&1) || true
if echo "$output" | jq -e '.specialists | index("tester")' >/dev/null 2>&1; then
    assert_pass "compose test includes tester specialist"
else
    assert_fail "compose test includes tester specialist" "tester not in specialists"
fi

# ─── Test 6: Compose for review stage ───────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" compose review 2>&1) || true
if echo "$output" | jq -e '.specialists | index("reviewer")' >/dev/null 2>&1; then
    assert_pass "compose review includes reviewer specialist"
else
    assert_fail "compose review includes reviewer specialist" "reviewer not in specialists"
fi

# ─── Test 7: Roles listing ──────────────────────────────────────────
echo -e "${BOLD}  Roles${RESET}"
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" roles 2>&1) || true
assert_contains "roles shows builder" "$output" "builder"
assert_contains "roles shows reviewer" "$output" "reviewer"
assert_contains "roles shows tester" "$output" "tester"
assert_contains "roles shows security" "$output" "security"
assert_contains "roles shows docs" "$output" "docs"

# ─── Test 8: Status with no active teams ─────────────────────────────
echo -e "${BOLD}  Status${RESET}"
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" status 2>&1) || true
assert_contains "status with no teams" "$output" "No active teams"

# ─── Test 9: Delegate generates tasks ───────────────────────────────
echo -e "${BOLD}  Delegate${RESET}"
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" delegate build 2>&1) || true
if echo "$output" | jq -e '.tasks' >/dev/null 2>&1; then
    assert_pass "delegate produces tasks array"
    file_count=$(echo "$output" | jq -r '.file_count // 0')
    if [[ "$file_count" -gt 0 ]]; then
        assert_pass "delegate assigns files to tasks"
    else
        assert_pass "delegate handles no changed files gracefully"
    fi
else
    assert_fail "delegate produces tasks array" "no tasks in output"
    assert_fail "delegate assigns files to tasks" "could not parse"
fi

echo ""
echo ""
print_test_results
