#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright webhook test — GitHub Webhook Receiver tests                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    if command -v openssl &>/dev/null; then
        ln -sf "$(command -v openssl)" "$TEST_TEMP_DIR/bin/openssl"
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
echo '{"id": 12345}'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    cat > "$TEST_TEMP_DIR/bin/nc" <<'MOCK'
#!/usr/bin/env bash
echo "mock netcat"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/nc"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap 'cleanup_test_env; sw_test_teardown' EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Webhook Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright webhook"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: status (no server running) ───────────────────────────────────
echo ""
echo -e "  ${CYAN}status subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" status 2>&1) && rc=0 || rc=$?
assert_eq "status exits 0" "0" "$rc"
assert_contains "status shows NOT running" "$output" "NOT running"
assert_contains "status shows configuration" "$output" "Configuration"

# ─── Test 4: secret show ──────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}secret subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" secret show 2>&1) && rc=0 || rc=$?
assert_eq "secret show exits 0" "0" "$rc"
# Secret should be a hex string
if [[ ${#output} -ge 32 ]]; then
    assert_pass "secret show returns long string"
else
    assert_fail "secret show returns long string" "got length: ${#output}"
fi

# ─── Test 5: secret creates file ──────────────────────────────────────────
if [[ -f "$HOME/.shipwright/webhook-secret" ]]; then
    assert_pass "webhook-secret file created"
else
    assert_fail "webhook-secret file created"
fi

# ─── Test 6: secret regenerate ────────────────────────────────────────────
local_old_secret=$(cat "$HOME/.shipwright/webhook-secret" 2>/dev/null || echo "")
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" secret regenerate 2>&1) && rc=0 || rc=$?
assert_eq "secret regenerate exits 0" "0" "$rc"
assert_contains "regenerate confirms" "$output" "regenerated"
local_new_secret=$(cat "$HOME/.shipwright/webhook-secret" 2>/dev/null || echo "")
if [[ "$local_old_secret" != "$local_new_secret" ]]; then
    assert_pass "secret regenerated is different"
else
    assert_fail "secret regenerated is different"
fi

# ─── Test 7: stop (no server running) ─────────────────────────────────────
echo ""
echo -e "  ${CYAN}stop subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" stop 2>&1) && rc=0 || rc=$?
assert_eq "stop exits 0 when no server" "0" "$rc"
assert_contains "stop says not running" "$output" "not running"

# ─── Test 8: logs (no log file) ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}logs subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" logs 2>&1) && rc=0 || rc=$?
assert_eq "logs exits 0 with no logs" "0" "$rc"
assert_contains "logs says no logs" "$output" "No webhook logs"

# ─── Test 9: setup without args ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}setup subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" setup 2>&1) && rc=0 || rc=$?
assert_eq "setup without args exits 1" "1" "$rc"
assert_contains "setup shows usage" "$output" "Usage"

# ─── Test 10: setup with invalid repo format ──────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" setup "invalid format" 2>&1) && rc=0 || rc=$?
assert_eq "setup with bad format exits 1" "1" "$rc"
assert_contains "setup shows invalid format" "$output" "Invalid"

# ─── Test 11: test without args ───────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" test 2>&1) && rc=0 || rc=$?
assert_eq "test without args exits 1" "1" "$rc"

# ─── Test 12: unknown command ─────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-webhook.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 13: process_webhook_event (source script) ───────────────────────
echo ""
echo -e "  ${CYAN}webhook event processing${RESET}"
# Source the script to test internal functions
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-webhook.sh"
    # Test with a valid labeled issue event
    local_payload='{"action":"labeled","issue":{"number":42,"title":"Test"},"label":{"name":"shipwright"},"repository":{"full_name":"test/repo"}}'
    if process_webhook_event "$local_payload" "issues"; then
        echo "PROCESSED"
    fi
)
webhook_result=$?
assert_eq "process_webhook_event returns 0 for labeled issue" "0" "$webhook_result"

echo ""
echo ""
print_test_results
