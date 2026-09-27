#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright logs test — Validate agent pane log viewing, searching,     ║
# ║  capturing, and intelligence-enhanced semantic ranking.                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/logs"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls stat xargs; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
    done

    # Copy script under test
    cp "$SCRIPT_DIR/sw-logs.sh" "$TEST_TEMP_DIR/repo/"

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "abc1234"; fi ;;
    remote) echo "git@github.com:test/repo.git" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock tmux — simulate no running sessions for capture
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    list-panes)
        # Return empty — no panes running
        exit 0
        ;;
    capture-pane)
        echo "mock captured output"
        exit 0
        ;;
    *)
        echo "mock tmux: $*"
        exit 0
        ;;
esac
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    # Mock gh, claude
    for mock in gh claude; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    # Create sample log directory structure
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/logs/claude-myteam"
    echo "INFO: Starting build loop iteration 1" > "$TEST_TEMP_DIR/home/.shipwright/logs/claude-myteam/builder-20260215-120000.log"
    echo "ERROR: Test failed in src/auth.ts" >> "$TEST_TEMP_DIR/home/.shipwright/logs/claude-myteam/builder-20260215-120000.log"
    echo "SUCCESS: All tests passed" >> "$TEST_TEMP_DIR/home/.shipwright/logs/claude-myteam/builder-20260215-120000.log"

    echo "INFO: Reviewing PR #42" > "$TEST_TEMP_DIR/home/.shipwright/logs/claude-myteam/reviewer-20260215-120500.log"
    echo "WARN: Missing test coverage for edge case" >> "$TEST_TEMP_DIR/home/.shipwright/logs/claude-myteam/reviewer-20260215-120500.log"

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
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

setup_env

SUT="$TEST_TEMP_DIR/repo/sw-logs.sh"

echo ""
print_test_header "shipwright logs test"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── 1. Script Safety ────────────────────────────────────────────────────────
echo -e "${BOLD}Script Safety${RESET}"

_src=$(cat "$SCRIPT_DIR/sw-logs.sh")

_count=$(printf '%s\n' "$_src" | grep -cF 'set -euo pipefail' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

_count=$(printf '%s\n' "$_src" | grep -cF 'trap' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

echo ""

# ─── 2. VERSION ──────────────────────────────────────────────────────────────
echo -e "${BOLD}Version${RESET}"

_count=$(printf '%s\n' "$_src" | grep -c '^VERSION=' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

echo ""

# ─── 3. Help Output ─────────────────────────────────────────────────────────
echo -e "${BOLD}Help Output${RESET}"

help_out=$(bash "$SUT" --help 2>&1) || true
assert_contains "help contains USAGE" "$help_out" "USAGE"
assert_contains "help contains --pane option" "$help_out" "--pane"
assert_contains "help contains --follow option" "$help_out" "--follow"
assert_contains "help contains --grep option" "$help_out" "--grep"
assert_contains "help contains --capture option" "$help_out" "--capture"
assert_contains "help contains -f shorthand" "$help_out" "-f"

echo ""

# ─── 4. Help Exit Code ──────────────────────────────────────────────────────
echo -e "${BOLD}Help Exit Code${RESET}"

help_rc=0
bash "$SUT" --help >/dev/null 2>&1 || help_rc=$?
assert_eq "help exits 0" "0" "$help_rc"

help_rc2=0
bash "$SUT" -h >/dev/null 2>&1 || help_rc2=$?
assert_eq "-h exits 0" "0" "$help_rc2"

echo ""

# ─── 5. Unknown Option ──────────────────────────────────────────────────────
echo -e "${BOLD}Error Handling${RESET}"

unknown_rc=0
unknown_out=$(bash "$SUT" --badopt 2>&1) || unknown_rc=$?
assert_eq "unknown option exits non-zero" "1" "$unknown_rc"
assert_contains "unknown option error" "$unknown_out" "Unknown option"

echo ""

# ─── 6. List Logs (no team arg) ─────────────────────────────────────────────
echo -e "${BOLD}List Logs${RESET}"

list_out=$(bash "$SUT" 2>&1) || true
assert_contains "list shows Agent Logs heading" "$list_out" "Agent Logs"
assert_contains "list shows team directory" "$list_out" "claude-myteam"

echo ""

# ─── 7. Team Logs ───────────────────────────────────────────────────────────
echo -e "${BOLD}Team Logs${RESET}"

team_out=$(bash "$SUT" claude-myteam 2>&1) || true
assert_contains "team logs shows team name" "$team_out" "claude-myteam"
assert_contains "team logs lists log files" "$team_out" "log file"
assert_contains "team logs shows builder log" "$team_out" "builder"

echo ""

# ─── 8. Grep Search ─────────────────────────────────────────────────────────
echo -e "${BOLD}Grep Search${RESET}"

grep_out=$(bash "$SUT" claude-myteam --grep "ERROR" 2>&1) || true
assert_contains "grep finds ERROR pattern" "$grep_out" "ERROR"
assert_contains "grep shows file context" "$grep_out" "builder"

# Grep with no match
grep_nomatch=$(bash "$SUT" claude-myteam --grep "ZZZNOMATCH" 2>&1) || true
assert_contains "grep shows no matches warning" "$grep_nomatch" "No matches"

echo ""

# ─── 9. Pane Filter ─────────────────────────────────────────────────────────
echo -e "${BOLD}Pane Filter${RESET}"

pane_out=$(bash "$SUT" claude-myteam --pane reviewer 2>&1) || true
assert_contains "pane filter shows reviewer logs" "$pane_out" "reviewer"

# Nonexistent pane
pane_none=$(bash "$SUT" claude-myteam --pane "nonexistent" 2>&1) || true
assert_contains "nonexistent pane warns" "$pane_none" "No logs matching"

echo ""

# ─── 10. Capture Command ────────────────────────────────────────────────────
echo -e "${BOLD}Capture Command${RESET}"

capture_out=$(bash "$SUT" --capture 2>&1) || true
# With no real tmux panes, it should warn
assert_contains "capture reports status" "$capture_out" "pane"

echo ""

# ─── 11. Missing --pane Argument ────────────────────────────────────────────
echo -e "${BOLD}Missing Arguments${RESET}"

pane_missing_rc=0
pane_missing_out=$(bash "$SUT" --pane 2>&1) || pane_missing_rc=$?
assert_eq "missing --pane value exits non-zero" "1" "$pane_missing_rc"
assert_contains "missing --pane shows error" "$pane_missing_out" "--pane requires"

grep_missing_rc=0
grep_missing_out=$(bash "$SUT" --grep 2>&1) || grep_missing_rc=$?
assert_eq "missing --grep value exits non-zero" "1" "$grep_missing_rc"
assert_contains "missing --grep shows error" "$grep_missing_out" "--grep requires"

echo ""

# ─── 12. Intelligence Check ─────────────────────────────────────────────────
echo -e "${BOLD}Intelligence Integration${RESET}"

assert_contains "intelligence_available function defined" "$_src" "intelligence_available"
assert_contains "semantic_rank_results function defined" "$_src" "semantic_rank_results"

echo ""

# ─── 13. Script Structure ───────────────────────────────────────────────────
echo -e "${BOLD}Script Structure${RESET}"

# Note: sw-logs.sh uses argument-based parsing, not a case-based command router
# It doesn't have a source guard because arguments are parsed at top level
assert_contains "LOGS_DIR defined" "$_src" 'LOGS_DIR='
assert_contains "capture_logs function defined" "$_src" "capture_logs"
assert_contains "list_logs function defined" "$_src" "list_logs"
assert_contains "show_team_logs function defined" "$_src" "show_team_logs"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo ""
print_test_results
