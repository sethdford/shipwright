#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright ux test — Validate UX enhancement layer                      ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-ux-test.XXXXXX")
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
echo -e "${CYAN}${BOLD}  Shipwright UX Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help ────────────────────────────────────────────────────
echo -e "${BOLD}  Help & Basic${RESET}"
output=$(bash "$SCRIPT_DIR/sw-ux.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows subcommands" "$output" "SUBCOMMANDS"

# ─── Test 2: --help flag ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ux.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "USAGE"

# ─── Test 3: Unknown command ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ux.sh" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: Theme list ─────────────────────────────────────────────
echo -e "${BOLD}  Theme System${RESET}"
output=$(bash "$SCRIPT_DIR/sw-ux.sh" theme list 2>&1) || true
assert_contains "theme list shows dark" "$output" "dark"
assert_contains "theme list shows cyberpunk" "$output" "cyberpunk"
assert_contains "theme list shows ocean" "$output" "ocean"

# ─── Test 5: Theme set ──────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ux.sh" theme dark 2>&1) || true
assert_contains "theme set dark succeeds" "$output" "Theme set to"

# ─── Test 6: Theme preview ──────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ux.sh" theme preview cyberpunk 2>&1) || true
assert_contains "theme preview shows colors" "$output" "primary"

# ─── Test 7: Config show (creates default) ──────────────────────────
echo -e "${BOLD}  Config${RESET}"
output=$(bash "$SCRIPT_DIR/sw-ux.sh" config show 2>&1) || true
assert_contains "config show outputs theme" "$output" "theme"

# ─── Test 8: Config creates ux-config.json ──────────────────────────
if [[ -f "$HOME/.shipwright/ux-config.json" ]]; then
    content=$(cat "$HOME/.shipwright/ux-config.json")
    assert_contains "config file has theme key" "$content" "theme"
    assert_contains "config file has spinner key" "$content" "spinner"
else
    assert_fail "config file created" "ux-config.json not found"
    assert_fail "config file has spinner key" "ux-config.json not found"
fi

# ─── Test 9: Config reset ───────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ux.sh" config reset 2>&1) || true
assert_contains "config reset succeeds" "$output" "reset to defaults"

# ─── Test 10: Spinner list ──────────────────────────────────────────
echo -e "${BOLD}  Spinners${RESET}"
output=$(bash "$SCRIPT_DIR/sw-ux.sh" spinner list 2>&1) || true
assert_contains "spinner list shows spinners" "$output" "Available spinners"
assert_contains "spinner list shows spinner frames" "$output" "..."

# ─── Test 11: Shortcuts ─────────────────────────────────────────────
echo -e "${BOLD}  Shortcuts${RESET}"
output=$(bash "$SCRIPT_DIR/sw-ux.sh" shortcuts 2>&1) || true
assert_contains "shortcuts shows key bindings" "$output" "Keyboard Shortcuts"

# ─── Test 12: Accessibility high contrast ────────────────────────────
echo -e "${BOLD}  Accessibility${RESET}"
output=$(bash "$SCRIPT_DIR/sw-ux.sh" accessibility --high-contrast 2>&1) || true
assert_contains "high contrast mode enabled" "$output" "High contrast mode enabled"

# ─── Test 13: Accessibility reduced motion ──────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ux.sh" accessibility --reduced-motion 2>&1) || true
assert_contains "reduced motion mode enabled" "$output" "Reduced motion mode enabled"

# ─── Test 14: Accessibility screen reader ───────────────────────────
output=$(bash "$SCRIPT_DIR/sw-ux.sh" accessibility --screen-reader 2>&1) || true
assert_contains "screen reader mode enabled" "$output" "Screen reader mode enabled"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
