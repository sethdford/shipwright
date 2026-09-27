#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright regression test — Validate regression detection pipeline     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/baselines"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls ln readlink bc; do
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

    # Mock gh, claude, tmux
    for mock in gh claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    # Mock bash for syntax checks (always pass)
    # Note: we keep real bash but need scripts in the repo dir
    # Create a dummy script in the mock repo scripts dir
    cat > "$TEST_TEMP_DIR/repo/scripts/dummy.sh" <<'EOF'
#!/usr/bin/env bash
echo "hello"
EOF
    chmod +x "$TEST_TEMP_DIR/repo/scripts/dummy.sh"

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
print_test_header "shipwright regression test suite"
echo ""

setup_env

# ─── 1. Script safety ────────────────────────────────────────────────────────

echo -e "${BOLD}  Script Safety${RESET}"

if grep -q 'set -euo pipefail' "$SCRIPT_DIR/sw-regression.sh"; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-regression.sh"; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

if grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" == "$0" \]\]; then' "$SCRIPT_DIR/sw-regression.sh"; then
    assert_pass "Source guard uses if/then/fi pattern"
else
    assert_fail "Source guard uses if/then/fi pattern"
fi

echo ""

# ─── 2. VERSION ──────────────────────────────────────────────────────────────

echo -e "${BOLD}  Version${RESET}"

if grep -q '^VERSION=' "$SCRIPT_DIR/sw-regression.sh"; then
    assert_pass "VERSION variable defined at top"
else
    assert_fail "VERSION variable defined at top"
fi

echo ""

# ─── 3. Help ─────────────────────────────────────────────────────────────────

echo -e "${BOLD}  Help${RESET}"

output=$(bash "$SCRIPT_DIR/sw-regression.sh" help 2>&1) || true
assert_contains "help contains USAGE" "$output" "USAGE"
assert_contains "help contains baseline" "$output" "baseline"
assert_contains "help contains check" "$output" "check"
assert_contains "help contains report" "$output" "report"
assert_contains "help contains history" "$output" "history"
assert_contains "help contains METRICS TRACKED" "$output" "METRICS TRACKED"
assert_contains "help contains EXIT CODES" "$output" "EXIT CODES"

# --help flag
output=$(bash "$SCRIPT_DIR/sw-regression.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "USAGE"

echo ""

# ─── 4. Unknown command ─────────────────────────────────────────────────────

echo -e "${BOLD}  Error Handling${RESET}"

if bash "$SCRIPT_DIR/sw-regression.sh" nonexistent_cmd 2>/dev/null; then
    assert_fail "unknown command exits non-zero"
else
    assert_pass "unknown command exits non-zero"
fi

output=$(bash "$SCRIPT_DIR/sw-regression.sh" nonexistent_cmd 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

echo ""

# ─── 5. Baseline subcommand ─────────────────────────────────────────────────

echo -e "${BOLD}  Baseline Subcommand${RESET}"

output=$(cd "$TEST_TEMP_DIR/repo" && bash "$SCRIPT_DIR/sw-regression.sh" baseline 2>&1) || true
assert_contains "baseline shows metrics" "$output" "Metrics"
assert_contains "baseline shows Test Count" "$output" "Test Count"
assert_contains "baseline shows Pass Rate" "$output" "Pass Rate"
assert_contains "baseline shows saved message" "$output" "Baseline saved"

# Check baseline dir was populated
baseline_count=$(find "$TEST_TEMP_DIR/home/.shipwright/baselines" -name "baseline-*.json" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$baseline_count" -gt 0 ]]; then
    assert_pass "baseline JSON file created"
else
    assert_fail "baseline JSON file created"
fi

# Check latest symlink
if [[ -L "$TEST_TEMP_DIR/home/.shipwright/baselines/latest.json" ]]; then
    assert_pass "latest.json symlink created"
else
    assert_fail "latest.json symlink created"
fi

echo ""

# ─── 6. Thresholds file ─────────────────────────────────────────────────────

echo -e "${BOLD}  State Files${RESET}"

if [[ -f "$TEST_TEMP_DIR/home/.shipwright/regression-thresholds.json" ]]; then
    assert_pass "regression-thresholds.json created"
    threshold_content=$(cat "$TEST_TEMP_DIR/home/.shipwright/regression-thresholds.json")
    assert_contains "thresholds contain pass_rate_drop" "$threshold_content" "pass_rate_drop"
    assert_contains "thresholds contain test_count_decrease" "$threshold_content" "test_count_decrease"
else
    assert_fail "regression-thresholds.json created"
fi

echo ""

# ─── 7. Check subcommand (requires baseline) ────────────────────────────────

echo -e "${BOLD}  Check Subcommand${RESET}"

# First check without baseline should fail
rm -f "$TEST_TEMP_DIR/home/.shipwright/baselines/latest.json"
rm -f "$TEST_TEMP_DIR/home/.shipwright/baselines"/baseline-*.json
if bash "$SCRIPT_DIR/sw-regression.sh" check 2>/dev/null; then
    assert_fail "check without baseline exits non-zero"
else
    assert_pass "check without baseline exits non-zero"
fi

output=$(bash "$SCRIPT_DIR/sw-regression.sh" check 2>&1) || true
assert_contains "check without baseline shows error" "$output" "No baseline found"

echo ""

# ─── 8. History subcommand ──────────────────────────────────────────────────

echo -e "${BOLD}  History Subcommand${RESET}"

# With no baselines
output=$(bash "$SCRIPT_DIR/sw-regression.sh" history 2>&1) || true
assert_contains "history with no baselines shows warning" "$output" "No baselines found"

echo ""

# ─── 9. Events logging ─────────────────────────────────────────────────────

echo -e "${BOLD}  Events Logging${RESET}"

# Run baseline to generate events
cd "$TEST_TEMP_DIR/repo" && bash "$SCRIPT_DIR/sw-regression.sh" baseline >/dev/null 2>&1 || true
if [[ -f "$TEST_TEMP_DIR/home/.shipwright/events.jsonl" ]]; then
    assert_pass "events.jsonl created after baseline"
    events_content=$(cat "$TEST_TEMP_DIR/home/.shipwright/events.jsonl")
    assert_contains "events contain regression.baseline" "$events_content" "regression.baseline"
else
    assert_fail "events.jsonl created after baseline"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
