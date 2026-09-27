#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright standup test — Validate daily standup automation             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/standups"
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/heartbeats"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    log)
        echo "abc1234 feat: add auth module"
        ;;
    shortlog)
        echo "     3	Author Name"
        ;;
    *)
        echo "mock git"
        ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
    echo "[]"
    exit 0
fi
if [[ "${1:-}" == "pr" ]]; then
    echo "No open PRs"
    exit 0
fi
echo "mock gh"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock curl (for webhook/notify)
    cat > "$TEST_TEMP_DIR/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "ok"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"

    # Mock crontab
    cat > "$TEST_TEMP_DIR/bin/crontab" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-l" ]]; then
    echo "# no crontab"
    exit 0
fi
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/crontab"

    # Create empty events and daemon-state files
    touch "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
    echo '{"active_jobs":[],"completed":[],"failed":[]}' > "$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT




# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Standup Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-standup.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help mentions digest" "$output" "digest"
assert_contains "help mentions yesterday" "$output" "yesterday"
assert_contains "help mentions blockers" "$output" "blockers"
assert_contains "help mentions velocity" "$output" "velocity"
assert_contains "help mentions notify" "$output" "notify"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
if grep -q '^VERSION=' "$SCRIPT_DIR/sw-standup.sh"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: unknown command exits non-zero ─────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-standup.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 4: yesterday command ───────────────────────────────────────────────
echo ""
echo -e "${DIM}  yesterday command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-standup.sh" yesterday 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "yesterday exits 0"
else
    assert_fail "yesterday exits 0" "exit code: $rc"
fi

# ─── Test 5: today command ───────────────────────────────────────────────────
echo ""
echo -e "${DIM}  today command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-standup.sh" today 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "today exits 0"
else
    assert_fail "today exits 0" "exit code: $rc"
fi

# ─── Test 6: blockers command ────────────────────────────────────────────────
echo ""
echo -e "${DIM}  blockers command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-standup.sh" blockers 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "blockers exits 0"
else
    assert_fail "blockers exits 0" "exit code: $rc"
fi

# ─── Test 7: velocity command ────────────────────────────────────────────────
echo ""
echo -e "${DIM}  velocity command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-standup.sh" velocity 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "velocity exits 0"
else
    assert_fail "velocity exits 0" "exit code: $rc"
fi

# ─── Test 8: history command ─────────────────────────────────────────────────
echo ""
echo -e "${DIM}  history command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-standup.sh" history 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "history exits 0"
else
    assert_fail "history exits 0" "exit code: $rc"
fi

# ─── Test 9: script safety ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-standup.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q 'BASH_SOURCE\[0\].*==.*\$0' "$SCRIPT_DIR/sw-standup.sh"; then
    assert_pass "Has source guard pattern"
else
    assert_fail "Has source guard pattern"
fi

# ─── Test 10: standup dir creation ───────────────────────────────────────────
echo ""
echo -e "${DIM}  state management${RESET}"

if [[ -d "$HOME/.shipwright/standups" ]]; then
    assert_pass "Standups directory exists"
else
    assert_fail "Standups directory exists"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
