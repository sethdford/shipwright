#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright auth test — Validate OAuth authentication commands           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-auth-test.XXXXXX")
    # Scripts under test read and write the intelligence cache here, not in the repo (#8609).
    export SHIPWRIGHT_INTELLIGENCE_CACHE="$TEST_TEMP_DIR/project/.claude/intelligence-cache.json"
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
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
        else echo "abc1234"; fi ;;
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
    # Mock curl that always returns mock JSON
    cat > "$TEST_TEMP_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
# Return a mock failure for all curl calls (no real network)
echo '{"message":"mock","login":"testuser","name":"Test User","email":"test@example.com","avatar_url":"https://example.com/avatar.png"}'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/curl"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap 'cleanup_test_env; sw_test_teardown' EXIT

print_test_header "Shipwright Auth Tests"
setup_env

# ─── Test 1: Help ────────────────────────────────────────────────────
echo -e "${BOLD}  Help${RESET}"
output=$(bash "$SCRIPT_DIR/sw-auth.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "Usage"
assert_contains "help shows commands" "$output" "login"

# ─── Test 2: --help flag ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-auth.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "Usage"

# ─── Test 3: Unknown command ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-auth.sh" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: Status with no user ─────────────────────────────────────
echo -e "${BOLD}  Status & Users${RESET}"
output=$(bash "$SCRIPT_DIR/sw-auth.sh" status 2>&1) || true
assert_contains "status with no login shows warning" "$output" "Not logged in"

# ─── Test 5: Users with empty list ───────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-auth.sh" users 2>&1) || true
assert_contains "users with empty shows warning" "$output" "No users authenticated"

# ─── Test 6: Token with no user ─────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-auth.sh" token 2>&1) || true
assert_contains "token with no user errors" "$output" "No user logged in"

# ─── Test 7: Switch with no user arg ────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-auth.sh" switch 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "switch without user exits non-zero"
else
    assert_fail "switch without user exits non-zero"
fi

# ─── Test 8: Auth file is created with proper structure ──────────────
echo -e "${BOLD}  Auth Storage${RESET}"
# Auth file should be created by the status/users commands above
if [[ -f "$HOME/.shipwright/auth.json" ]]; then
    content=$(cat "$HOME/.shipwright/auth.json")
    assert_contains "auth file has users array" "$content" "users"
    assert_contains "auth file has active_user" "$content" "active_user"
else
    assert_fail "auth file is created" "auth.json not found"
    assert_fail "auth file has users array" "auth.json not found"
fi

# ─── Test 9: Manual user insertion + status ──────────────────────────
echo '{"users":[{"login":"testuser","token":"ghp_test123","user":{"login":"testuser","name":"Test User","email":"test@example.com","avatar_url":""},"stored_at":"2026-01-01T00:00:00Z"}],"active_user":"testuser"}' > "$HOME/.shipwright/auth.json"
chmod 600 "$HOME/.shipwright/auth.json"

output=$(bash "$SCRIPT_DIR/sw-auth.sh" users 2>&1) || true
assert_contains "users lists stored user" "$output" "testuser"

# ─── Test 10: Token retrieval for known user ─────────────────────────
output=$(bash "$SCRIPT_DIR/sw-auth.sh" token 2>&1) || true
assert_contains "token shows stored token" "$output" "ghp_test123"

# ─── Test 11: User info for known user ──────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-auth.sh" user 2>&1) || true
assert_contains "user info shows login" "$output" "testuser"

# ─── Test 12: Switch to nonexistent user ─────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-auth.sh" switch nobody 2>&1) || true
assert_contains "switch to nonexistent errors" "$output" "User not found"

# ─── Test 13: Logout removes user ────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-auth.sh" logout testuser 2>&1) || true
assert_contains "logout succeeds" "$output" "User removed"

print_test_results
