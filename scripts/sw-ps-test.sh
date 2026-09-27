#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright ps test — Validate agent process status display             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
    done

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "abc1234"; fi ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh, claude
    for mock in gh claude; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
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

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    local _count
    _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true
    if [[ "${_count:-0}" -gt 0 ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

SRC="$SCRIPT_DIR/sw-ps.sh"

echo ""
print_test_header "Shipwright PS Test Suite"
echo ""

# ─── 1. Script Safety ─────────────────────────────────────────────────────────
echo -e "${BOLD}  Script Safety${RESET}"

if grep -q 'set -euo pipefail' "$SRC"; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -q "bootstrap.sh" "$SRC" || grep -q "trap.*ERR" "$SRC"; then
    assert_pass "ERR trap present (via bootstrap or inline)"
else
    assert_fail "ERR trap present (via bootstrap or inline)"
fi

if grep -q '^VERSION=' "$SRC"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

ver=$(grep -m1 '^VERSION=' "$SRC" | sed 's/VERSION="//' | sed 's/"//')
if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    assert_pass "VERSION is semver: $ver"
else
    assert_fail "VERSION is semver" "got: $ver"
fi

echo ""

# ─── 2. Function Definitions ─────────────────────────────────────────────────
echo -e "${BOLD}  Function Definitions${RESET}"

if grep -q 'format_idle()' "$SRC"; then
    assert_pass "format_idle() defined"
else
    assert_fail "format_idle() defined"
fi

if grep -q 'get_status()' "$SRC"; then
    assert_pass "get_status() defined"
else
    assert_fail "get_status() defined"
fi

if grep -q 'status_display()' "$SRC"; then
    assert_pass "status_display() defined"
else
    assert_fail "status_display() defined"
fi

echo ""

# ─── 3. No tmux → Graceful Output ────────────────────────────────────────────
echo -e "${BOLD}  No tmux Sessions${RESET}"

setup_env

# Mock tmux to return nothing (no agent sessions)
cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    list-panes) exit 0 ;;
    *) echo "mock tmux: $*" ;;
esac
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/tmux"

ps_output=$(bash "$SRC" 2>&1) || true
assert_contains "shows no-agents message" "$ps_output" "No Claude team windows found"
assert_contains "suggests starting session" "$ps_output" "shipwright session"

echo ""

# ─── 4. With Agent Sessions ──────────────────────────────────────────────────
echo -e "${BOLD}  With Agent Sessions${RESET}"

# Mock tmux to return agent panes
cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    list-panes)
        echo "claude-team|leader|12345|claude|1|30|0|%1"
        echo "claude-team|builder|12346|node|0|120|0|%2"
        echo "claude-team|tester|12347|bash|0|500|0|%3"
        ;;
    *) echo "mock tmux: $*" ;;
esac
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/tmux"

ps_agents_output=$(bash "$SRC" 2>&1) || true
assert_contains "shows team window name" "$ps_agents_output" "claude-team"
assert_contains "shows AGENT header" "$ps_agents_output" "AGENT"
assert_contains "shows PID header" "$ps_agents_output" "PID"
assert_contains "shows STATUS header" "$ps_agents_output" "STATUS"
assert_contains "shows summary counts" "$ps_agents_output" "running"

echo ""

# ─── 5. Filters Non-Claude Windows ───────────────────────────────────────────
echo -e "${BOLD}  Window Filtering${RESET}"

# Mock tmux with mixed windows
cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    list-panes)
        echo "other-window|pane1|99999|bash|1|10|0|%10"
        echo "claude-dev|agent1|11111|claude|1|5|0|%11"
        ;;
    *) echo "mock tmux: $*" ;;
esac
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/tmux"

filter_output=$(bash "$SRC" 2>&1) || true
assert_contains "shows claude- windows" "$filter_output" "claude-dev"

# Check that non-claude window doesn't appear as a team header
non_claude_count=$(printf '%s\n' "$filter_output" | grep -cF "other-window" 2>/dev/null) || true
if [[ "${non_claude_count:-0}" -eq 0 ]]; then
    assert_pass "filters out non-claude windows"
else
    assert_fail "filters out non-claude windows"
fi

echo ""

# ─── 6. Status Logic ─────────────────────────────────────────────────────────
echo -e "${BOLD}  Status Classification${RESET}"

# Check that the script classifies claude process as running when idle < 300
if grep -q 'claude.*node.*npm.*npx' "$SRC" || grep -q 'claude|node|npm|npx' "$SRC"; then
    assert_pass "recognizes claude/node/npm/npx as active processes"
else
    assert_fail "recognizes claude/node/npm/npx as active processes"
fi

if grep -q 'bash|zsh|fish|sh' "$SRC" || grep -q 'bash.*zsh.*fish' "$SRC"; then
    assert_pass "recognizes shell processes as idle"
else
    assert_fail "recognizes shell processes as idle"
fi

if grep -q '300' "$SRC"; then
    assert_pass "uses 300-second idle threshold"
else
    assert_fail "uses 300-second idle threshold"
fi

if grep -q 'dead' "$SRC"; then
    assert_pass "handles dead pane status"
else
    assert_fail "handles dead pane status"
fi

echo ""

# ─── 7. Format Idle ──────────────────────────────────────────────────────────
echo -e "${BOLD}  Idle Time Formatting${RESET}"

if grep -q '3600' "$SRC"; then
    assert_pass "format_idle handles hours"
else
    assert_fail "format_idle handles hours"
fi

if grep -q '"${seconds}s"' "$SRC" || grep -q 'echo.*s"' "$SRC"; then
    assert_pass "format_idle handles seconds"
else
    assert_fail "format_idle handles seconds"
fi

echo ""

# ─── 8. Header Display ───────────────────────────────────────────────────────
echo -e "${BOLD}  Header Display${RESET}"

# Run with agent sessions
cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    list-panes) echo "claude-test|leader|12345|claude|1|30|0|%1" ;;
    *) echo "mock tmux: $*" ;;
esac
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/tmux"

header_output=$(bash "$SRC" 2>&1) || true
assert_contains "shows Process Status header" "$header_output" "Process Status"
assert_contains "shows timestamp" "$header_output" "$(date '+%Y-%m-%d')"

echo ""

# ─── 9. Pane ID Usage ────────────────────────────────────────────────────────
echo -e "${BOLD}  Pane ID Usage${RESET}"

if grep -q 'pane_id' "$SRC"; then
    assert_pass "uses pane_id (not pane_index)"
else
    assert_fail "uses pane_id (not pane_index)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
