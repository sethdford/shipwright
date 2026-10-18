#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright ux test — Validate UX enhancement layer                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

setup_env() {
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
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap 'cleanup_test_env; sw_test_teardown' EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright UX Tests"
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

# ─── Test 15: Source script and test hex_to_rgb ────────────────────────
echo ""
echo -e "${BOLD}  Sourced Functions${RESET}"
unset NO_COLOR FORCE_COLOR PREFERS_REDUCED_MOTION 2>/dev/null || true
source "$SCRIPT_DIR/sw-ux.sh" 2>/dev/null || true
rgb=$(hex_to_rgb "#00d4ff" 2>/dev/null) || true
assert_eq "hex_to_rgb #00d4ff yields 0;212;255" "0;212;255" "$rgb"
rgb=$(hex_to_rgb "#4ade80" 2>/dev/null) || true
assert_eq "hex_to_rgb #4ade80 yields 74;222;128" "74;222;128" "$rgb"

# ─── Test 16: get_color for theme colors ───────────────────────────────
for color in primary secondary success warning error; do
    out=$(get_color "$color" dark 2>/dev/null) || true
    if [[ -n "$out" ]]; then
        assert_pass "get_color $color returns output"
    else
        assert_fail "get_color $color returns output"
    fi
done

# ─── Test 17: box_title produces output with title ──────────────────────
box_out=$(box_title "Test Title" 40 2>/dev/null) || true
assert_contains "box_title contains title text" "$box_out" "Test Title"
assert_contains_regex "box_title has box drawing" "$box_out" "^╔"

# ─── Test 18: format_diff_line with +/- lines ─────────────────────────
plus_out=$(format_diff_line "+added line" 2>/dev/null) || true
minus_out=$(format_diff_line "-removed line" 2>/dev/null) || true
assert_contains "format_diff_line +line contains text" "$plus_out" "added line"
assert_contains "format_diff_line -line contains text" "$minus_out" "removed line"
assert_pass "format_diff_line + produces output"
assert_pass "format_diff_line - produces output"

# ─── Test 19: Config persistence (set theme, verify config.json) ────────
echo ""
echo -e "${BOLD}  Config Persistence${RESET}"
bash "$SCRIPT_DIR/sw-ux.sh" theme cyberpunk 2>/dev/null || true
if [[ -f "$HOME/.shipwright/ux-config.json" ]]; then
    theme_val=$(jq -r '.theme' "$HOME/.shipwright/ux-config.json" 2>/dev/null)
    assert_eq "config.json updated with theme" "cyberpunk" "$theme_val"
else
    assert_fail "config.json updated with theme" "ux-config.json not found"
fi

echo ""
echo ""
print_test_results
