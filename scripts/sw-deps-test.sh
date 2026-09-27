#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright deps test — Automated Dependency Update Management tests     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
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
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Deps Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright deps"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-deps.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: scan with NO_GITHUB ──────────────────────────────────────────
echo ""
echo -e "  ${CYAN}scan subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" scan 2>&1) && rc=0 || rc=$?
assert_eq "scan exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "scan shows warning" "$output" "GitHub API disabled"

# ─── Test 5: classify missing args ────────────────────────────────────────
echo ""
echo -e "  ${CYAN}classify subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" classify 2>&1) && rc=0 || rc=$?
assert_eq "classify without args exits 1" "1" "$rc"
assert_contains "classify shows usage" "$output" "Usage"

# ─── Test 6: classify with NO_GITHUB ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-deps.sh" classify 123 2>&1) && rc=0 || rc=$?
assert_eq "classify exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "classify shows warning" "$output" "GitHub API disabled"

# ─── Test 7: batch with NO_GITHUB ─────────────────────────────────────────
echo ""
echo -e "  ${CYAN}batch subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" batch 2>&1) && rc=0 || rc=$?
assert_eq "batch exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "batch shows warning" "$output" "GitHub API disabled"

# ─── Test 8: report with NO_GITHUB ────────────────────────────────────────
echo ""
echo -e "  ${CYAN}report subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "report shows warning" "$output" "GitHub API disabled"

# ─── Test 9: merge missing args ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}merge subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" merge 2>&1) && rc=0 || rc=$?
assert_eq "merge without args exits 1" "1" "$rc"

# ─── Test 10: test missing args ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}test subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" test 2>&1) && rc=0 || rc=$?
assert_eq "test without args exits 1" "1" "$rc"

# ─── Test 11: parse_version_bump (source script) ──────────────────────────
echo ""
echo -e "  ${CYAN}internal parse_version_bump${RESET}"
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-deps.sh"

    # Patch bump
    result=$(parse_version_bump "1.2.3" "1.2.4")
    echo "PATCH:$result"

    # Minor bump
    result=$(parse_version_bump "1.2.3" "1.3.0")
    echo "MINOR:$result"

    # Major bump
    result=$(parse_version_bump "1.2.3" "2.0.0")
    echo "MAJOR:$result"
) > "$TEST_TEMP_DIR/version_output" 2>/dev/null

version_output=$(cat "$TEST_TEMP_DIR/version_output")
if echo "$version_output" | grep -qF "PATCH:patch"; then
    assert_pass "parse_version_bump detects patch"
else
    assert_fail "parse_version_bump detects patch" "got: $version_output"
fi
if echo "$version_output" | grep -qF "MINOR:minor"; then
    assert_pass "parse_version_bump detects minor"
else
    assert_fail "parse_version_bump detects minor" "got: $version_output"
fi
if echo "$version_output" | grep -qF "MAJOR:major"; then
    assert_pass "parse_version_bump detects major"
else
    assert_fail "parse_version_bump detects major" "got: $version_output"
fi

# ─── Test 12: parse_version_bump with v prefix ────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-deps.sh"
    result=$(parse_version_bump "v1.2.3" "v1.2.4")
    echo "$result"
) > "$TEST_TEMP_DIR/version_prefix" 2>/dev/null
prefix_result=$(cat "$TEST_TEMP_DIR/version_prefix")
assert_eq "parse_version_bump handles v prefix" "patch" "$prefix_result"

echo ""
echo ""
print_test_results
