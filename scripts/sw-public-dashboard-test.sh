#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright public-dashboard test — Validate public dashboard generation ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-public-dashboard-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/home/.claude"
    mkdir -p "$TEMP_DIR/repo/.claude/pipeline-artifacts"
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
    log) echo "abc1234 fix: something" ;;
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
case "${1:-}" in
    list-sessions) echo "main: 1 windows" ;;
    list-panes|list-windows) echo "" ;;
    new-window|split-window|send-keys) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEMP_DIR/bin/tmux"
    # Mock find to avoid filesystem issues
    cat > "$TEMP_DIR/bin/find" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/find"
    # Mock openssl
    cat > "$TEMP_DIR/bin/openssl" <<'MOCK'
#!/usr/bin/env bash
echo "abcdef1234567890abcdef1234567890"
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/openssl"
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
    # Create a mock repo dir for the script
    export REPO_DIR="$TEMP_DIR/repo"
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Public Dashboard Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help flag ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" help 2>&1) || true
assert_contains "help shows usage text" "$output" "USAGE"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: Unknown command exits with error ──────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 3: Config show (creates default) ────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" config 2>&1) || true
assert_contains "config show outputs privacy" "$output" "privacy"

# ─── Test 4: Config set privacy ───────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" config privacy anonymized 2>&1) || true
assert_contains "config privacy set succeeds" "$output" "Privacy set to"

# ─── Test 5: Config set domain ────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" config domain "example.com" 2>&1) || true
assert_contains "config domain set succeeds" "$output" "Custom domain set to"

# ─── Test 6: Config set expiry ────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" config expiry 48 2>&1) || true
assert_contains "config expiry set succeeds" "$output" "Default expiry set to"

# ─── Test 7: Config unknown key ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" config badkey val 2>&1) || true
assert_contains "config unknown key errors" "$output" "Unknown config key"

# ─── Test 8: List with no links ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" list 2>&1) || true
assert_contains "list shows active links header" "$output" "Active share links"

# ─── Test 9: Cleanup with no expired ─────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" cleanup 2>&1) || true
assert_contains "cleanup handles empty" "$output" "No expired links"

# ─── Test 10: Export generates HTML ──────────────────────────────────
# Create events file for export
echo '{"ts":"2026-01-01T00:00:00Z","ts_epoch":1735689600,"type":"test"}' > "$HOME/.shipwright/events.jsonl"
echo '{"active_jobs":[],"completed":[],"failed":[]}' > "$HOME/.shipwright/daemon-state.json"
output_file="$TEMP_DIR/dashboard-out.html"
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" export "$output_file" "Test Dashboard" 2>&1) || true
if [[ -f "$output_file" ]]; then
    assert_pass "export creates HTML file"
    file_content=$(cat "$output_file")
    assert_contains "exported HTML contains title" "$file_content" "Test Dashboard"
else
    assert_fail "export creates HTML file" "file not created at $output_file"
    assert_fail "exported HTML contains title" "file not created"
fi

# ─── Test 11: Embed requires token ──────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" embed "" 2>&1) || true
assert_contains "embed without token errors" "$output" "Token required"

# ─── Test 12: Embed iframe format ───────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" embed "abc123" iframe 2>&1) || true
assert_contains "embed iframe generates iframe tag" "$output" "iframe"

# ─── Test 13: Embed markdown format ─────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" embed "abc123" markdown 2>&1) || true
assert_contains "embed markdown generates markdown" "$output" "Pipeline Status"

# ─── Test 14: Embed link format ─────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" embed "abc123" link 2>&1) || true
assert_contains "embed link outputs URL" "$output" "public-dashboard/abc123"

# ─── Test 15: Revoke requires token ─────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-public-dashboard.sh" revoke "" 2>&1) || true
assert_contains "revoke without token errors" "$output" "Token required"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
