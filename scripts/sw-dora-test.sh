#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright dora test — Validate DORA metrics dashboard, DX metrics,    ║
# ║  AI metrics, trends, comparison, and export subcommands.               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts/lib"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls bc; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
    done

    # Copy script under test
    cp "$SCRIPT_DIR/sw-dora.sh" "$TEST_TEMP_DIR/repo/scripts/"

    # Create compat.sh stub
    touch "$TEST_TEMP_DIR/repo/scripts/lib/compat.sh"

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

    # Mock gh, claude, tmux
    for mock in gh claude tmux; do
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
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

setup_env

SUT="$TEST_TEMP_DIR/repo/scripts/sw-dora.sh"

echo ""
print_test_header "shipwright dora test"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── 1. Script Safety ────────────────────────────────────────────────────────
echo -e "${BOLD}Script Safety${RESET}"

_src=$(cat "$SCRIPT_DIR/sw-dora.sh")

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

_count=$(printf '%s\n' "$_src" | grep -c 'if \[\[ "\${BASH_SOURCE\[0\]}" == "\$0" \]\]' 2>/dev/null) || true
if [[ "${_count:-0}" -gt 0 ]]; then
    assert_pass "source guard uses if/then/fi pattern"
else
    assert_fail "source guard uses if/then/fi pattern"
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

help_out=$(bash "$SUT" help 2>&1) || true
assert_contains "help contains USAGE" "$help_out" "USAGE"
assert_contains "help contains show subcommand" "$help_out" "show"
assert_contains "help contains dx subcommand" "$help_out" "dx"
assert_contains "help contains ai subcommand" "$help_out" "ai"
assert_contains "help contains trends subcommand" "$help_out" "trends"
assert_contains "help contains compare subcommand" "$help_out" "compare"
assert_contains "help contains export subcommand" "$help_out" "export"
assert_contains "help contains DORA BANDS" "$help_out" "DORA BANDS"

# --help flag also works
help_flag_out=$(bash "$SUT" --help 2>&1) || true
assert_contains "--help flag works" "$help_flag_out" "USAGE"

echo ""

# ─── 4. Unknown Command ─────────────────────────────────────────────────────
echo -e "${BOLD}Error Handling${RESET}"

unknown_rc=0
unknown_out=$(bash "$SUT" boguscmd 2>&1) || unknown_rc=$?
assert_eq "unknown command exits non-zero" "1" "$unknown_rc"
assert_contains "unknown command error message" "$unknown_out" "Unknown command"

echo ""

# ─── 5. Show Subcommand (no events) ─────────────────────────────────────────
echo -e "${BOLD}Show Subcommand (no events)${RESET}"

# No events.jsonl exists yet — should still succeed with zeros
show_out=$(bash "$SUT" show 2>&1) || true
assert_contains "show displays DORA Metrics" "$show_out" "DORA Metrics"
assert_contains "show displays Deploy Frequency" "$show_out" "Deploy Frequency"
assert_contains "show displays Lead Time" "$show_out" "Lead Time"
assert_contains "show displays Change Failure Rate" "$show_out" "Change Failure Rate"
assert_contains "show displays MTTR" "$show_out" "MTTR"

echo ""

# ─── 6. DX Subcommand (no events) ───────────────────────────────────────────
echo -e "${BOLD}DX Subcommand${RESET}"

dx_out=$(bash "$SUT" dx 2>&1) || true
assert_contains "dx displays Developer Experience" "$dx_out" "Developer Experience"

echo ""

# ─── 7. AI Subcommand (no events) ───────────────────────────────────────────
echo -e "${BOLD}AI Subcommand${RESET}"

ai_out=$(bash "$SUT" ai 2>&1) || true
assert_contains "ai displays AI Performance Metrics" "$ai_out" "AI Performance Metrics"

echo ""

# ─── 8. Export Subcommand ────────────────────────────────────────────────────
echo -e "${BOLD}Export Subcommand${RESET}"

export_out=$(bash "$SUT" export 2>&1) || true
assert_contains "export produces JSON with timestamp" "$export_out" "timestamp"
assert_contains "export contains current_period" "$export_out" "current_period"
assert_contains "export contains previous_period" "$export_out" "previous_period"

echo ""

# ─── 9. Trends Subcommand ───────────────────────────────────────────────────
echo -e "${BOLD}Trends Subcommand${RESET}"

trends_out=$(bash "$SUT" trends 3 2>&1) || true
assert_contains "trends displays Trends heading" "$trends_out" "Trends"

echo ""

# ─── 10. Compare Subcommand ─────────────────────────────────────────────────
echo -e "${BOLD}Compare Subcommand${RESET}"

compare_out=$(bash "$SUT" compare 7 7 2>&1) || true
assert_contains "compare displays Period Comparison" "$compare_out" "Period Comparison"

echo ""

# ─── 11. DORA Band Classification ───────────────────────────────────────────
echo -e "${BOLD}DORA Band Classification${RESET}"

assert_contains "classify_band function defined" "$_src" "classify_band"
assert_contains "Elite band classification" "$_src" "Elite"
assert_contains "High band classification" "$_src" "High"
assert_contains "Medium band classification" "$_src" "Medium"
assert_contains "Low band classification" "$_src" "Low"

echo ""

# ─── 12. Trend Arrows ───────────────────────────────────────────────────────
echo -e "${BOLD}Trend Arrows${RESET}"

assert_contains "trend_arrow function defined" "$_src" "trend_arrow"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo ""
print_test_results
