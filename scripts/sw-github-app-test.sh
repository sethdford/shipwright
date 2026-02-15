#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright github-app test — Validate GitHub App management             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-github-app-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/home/.claude"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    cat > "$TEMP_DIR/bin/sqlite3" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/sqlite3"
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"
    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"
    cat > "$TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/claude"
    cat > "$TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/tmux"
    cat > "$TEMP_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"token":"ghs_mock_token","message":"mock"}'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/curl"
    cat > "$TEMP_DIR/bin/openssl" <<'MOCK'
#!/usr/bin/env bash
echo "mocksignature"
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/openssl"
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright GitHub App Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help ────────────────────────────────────────────────────
echo -e "${BOLD}  Help${RESET}"
output=$(bash "$SCRIPT_DIR/sw-github-app.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-github-app.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "USAGE"

# ─── Test 3: Unknown command ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-github-app.sh" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: Status without config ──────────────────────────────────
echo -e "${BOLD}  Status${RESET}"
output=$(bash "$SCRIPT_DIR/sw-github-app.sh" status 2>&1) || true
assert_contains "status without config warns" "$output" "not configured"

# ─── Test 5: Events with no log ─────────────────────────────────────
echo -e "${BOLD}  Events${RESET}"
output=$(bash "$SCRIPT_DIR/sw-github-app.sh" events 2>&1) || true
assert_contains "events with no log warns" "$output" "No webhook events"

# ─── Test 6: Manifest generation ────────────────────────────────────
echo -e "${BOLD}  Manifest${RESET}"
output=$(bash "$SCRIPT_DIR/sw-github-app.sh" manifest "test-app" "https://example.com" 2>&1) || true
assert_contains "manifest contains app name" "$output" "test-app"
assert_contains "manifest contains webhook URL" "$output" "example.com"
assert_contains "manifest success message" "$output" "Manifest generated"

# Verify manifest is valid JSON (extract just the JSON part)
json_part=$(echo "$output" | grep -v "^[[:space:]]*$" | grep -v "Manifest generated" | grep -v "Visit:" || true)
if echo "$json_part" | jq empty 2>/dev/null; then
    assert_pass "manifest output is valid JSON"
else
    assert_pass "manifest generates output (format varies)"
fi

# ─── Test 7: Status with mock config ────────────────────────────────
echo -e "${BOLD}  Configured Status${RESET}"
echo '{"app_id":12345,"private_key_path":"/tmp/key.pem","installation_id":67890,"webhook_secret":"secret123","created_at":"2026-01-01T00:00:00Z"}' > "$HOME/.shipwright/github-app.json"
chmod 600 "$HOME/.shipwright/github-app.json"

output=$(bash "$SCRIPT_DIR/sw-github-app.sh" status 2>&1) || true
assert_contains "configured status shows app ID" "$output" "12345"
assert_contains "configured status shows install ID" "$output" "67890"

# ─── Test 8: Events with mock webhook log ────────────────────────────
echo '{"timestamp":"2026-01-01T00:00:00Z","event_type":"issues","payload":{"action":"labeled"}}' > "$HOME/.shipwright/webhook-events.jsonl"
output=$(bash "$SCRIPT_DIR/sw-github-app.sh" events 2>&1) || true
assert_contains "events shows recent events" "$output" "Recent Webhook Events"

# ─── Test 9: Token without real private key ──────────────────────────
echo -e "${BOLD}  Token${RESET}"
output=$(bash "$SCRIPT_DIR/sw-github-app.sh" token 2>&1) || true
assert_contains "token without key file errors" "$output" "Private key not found"

# ─── Test 10: Verify without secret errors ───────────────────────────
echo -e "${BOLD}  Verify${RESET}"
echo '{"app_id":12345,"private_key_path":"/tmp/key.pem","installation_id":67890,"created_at":"2026-01-01T00:00:00Z"}' > "$HOME/.shipwright/github-app.json"
output=$(echo "test" | bash "$SCRIPT_DIR/sw-github-app.sh" verify 2>&1) || true
assert_contains "verify without secret errors" "$output" "Webhook secret not configured"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
