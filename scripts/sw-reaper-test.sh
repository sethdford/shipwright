#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright reaper test — Validate automatic tmux pane cleanup           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls sleep kill; do
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
    remote) echo "git@github.com:test/repo.git" ;;
    log) echo "abc1234 Mock commit" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock tmux — returns no panes by default
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    list-panes) exit 0 ;;
    list-windows) exit 0 ;;
    kill-pane) exit 0 ;;
    kill-window) exit 0 ;;
    *) exit 0 ;;
esac
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    # Mock gh, claude
    for mock in gh claude; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
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

echo ""
print_test_header "shipwright reaper test suite"
echo ""

setup_env

# ─── 1. Script safety ────────────────────────────────────────────────────────

echo -e "${BOLD}  Script Safety${RESET}"

if grep -q 'set -euo pipefail' "$SCRIPT_DIR/sw-reaper.sh"; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -q "bootstrap.sh" "$SCRIPT_DIR/sw-reaper.sh" || grep -q "trap.*ERR" "$SCRIPT_DIR/sw-reaper.sh"; then
    assert_pass "ERR trap present (via bootstrap or inline)"
else
    assert_fail "ERR trap present (via bootstrap or inline)"
fi

echo ""

# ─── 2. VERSION ──────────────────────────────────────────────────────────────

echo -e "${BOLD}  Version${RESET}"

if grep -q '^VERSION=' "$SCRIPT_DIR/sw-reaper.sh"; then
    assert_pass "VERSION variable defined at top"
else
    assert_fail "VERSION variable defined at top"
fi

echo ""

# ─── 3. Help ─────────────────────────────────────────────────────────────────

echo -e "${BOLD}  Help${RESET}"

output=$(bash "$SCRIPT_DIR/sw-reaper.sh" --help 2>&1) || true
assert_contains "help contains USAGE" "$output" "USAGE"
assert_contains "help mentions --watch" "$output" "--watch"
assert_contains "help mentions --dry-run" "$output" "--dry-run"
assert_contains "help mentions --verbose" "$output" "--verbose"
assert_contains "help mentions --interval" "$output" "--interval"
assert_contains "help mentions --grace-period" "$output" "--grace-period"
assert_contains "help mentions --log-file" "$output" "--log-file"
assert_contains "help mentions DETECTION ALGORITHM" "$output" "DETECTION ALGORITHM"

# -h flag
output=$(bash "$SCRIPT_DIR/sw-reaper.sh" -h 2>&1) || true
assert_contains "-h flag works" "$output" "USAGE"

echo ""

# ─── 4. Help exits 0 ────────────────────────────────────────────────────────

echo -e "${BOLD}  Help Exit Code${RESET}"

if bash "$SCRIPT_DIR/sw-reaper.sh" --help >/dev/null 2>&1; then
    assert_pass "--help exits 0"
else
    assert_fail "--help exits 0"
fi

echo ""

# ─── 5. Unknown option ──────────────────────────────────────────────────────

echo -e "${BOLD}  Error Handling${RESET}"

if bash "$SCRIPT_DIR/sw-reaper.sh" --nonexistent 2>/dev/null; then
    assert_fail "unknown option exits non-zero"
else
    assert_pass "unknown option exits non-zero"
fi

output=$(bash "$SCRIPT_DIR/sw-reaper.sh" --nonexistent 2>&1) || true
assert_contains "unknown option shows error" "$output" "Unknown option"

echo ""

# ─── 6. One-shot mode (default) ─────────────────────────────────────────────

echo -e "${BOLD}  One-shot Mode${RESET}"

output=$(bash "$SCRIPT_DIR/sw-reaper.sh" 2>&1) || true
assert_contains "one-shot shows Agent Panes header" "$output" "Agent Panes"
assert_contains "one-shot shows Empty Windows header" "$output" "Empty Windows"
assert_contains "one-shot shows Team Directories header" "$output" "Team Directories"
assert_contains "one-shot shows healthy message" "$output" "healthy"

echo ""

# ─── 7. Dry-run mode ────────────────────────────────────────────────────────

echo -e "${BOLD}  Dry-run Mode${RESET}"

output=$(bash "$SCRIPT_DIR/sw-reaper.sh" --dry-run 2>&1) || true
assert_contains "dry-run shows scan output" "$output" "dry-run"

echo ""

# ─── 8. Log file option ─────────────────────────────────────────────────────

echo -e "${BOLD}  Log File Option${RESET}"

# --log-file with no value should error
if bash "$SCRIPT_DIR/sw-reaper.sh" --log-file 2>/dev/null; then
    assert_fail "--log-file without value exits non-zero"
else
    assert_pass "--log-file without value exits non-zero"
fi

echo ""

# ─── 9. PID file path ───────────────────────────────────────────────────────

echo -e "${BOLD}  PID File${RESET}"

if grep -q 'PID_FILE=' "$SCRIPT_DIR/sw-reaper.sh"; then
    assert_pass "PID_FILE variable defined"
else
    assert_fail "PID_FILE variable defined"
fi

if grep -q '.sw-reaper.pid' "$SCRIPT_DIR/sw-reaper.sh"; then
    assert_pass "PID file uses .sw-reaper.pid"
else
    assert_fail "PID file uses .sw-reaper.pid"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
