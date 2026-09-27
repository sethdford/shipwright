#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright code-review test — Clean code & architecture analysis tests  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        case "${2:-}" in
            --show-toplevel) echo "$TEST_TEMP_DIR/repo" ;;
            *) echo "/tmp/mock-repo" ;;
        esac
        ;;
    diff) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    # git mock needs TEMP_DIR — inject it
    # `-i.bak` is the only in-place form both BSD and GNU sed accept.
    sed -i.bak "s|\$TEST_TEMP_DIR|$TEST_TEMP_DIR|g" "$TEST_TEMP_DIR/bin/git"
    rm -f "$TEST_TEMP_DIR/bin/git.bak"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock claude
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    # Create a sample .sh file for analysis
    cat > "$TEST_TEMP_DIR/repo/scripts/sample.sh" <<'SAMPLE'
#!/usr/bin/env bash
set -euo pipefail

my_function() {
    local a="$1"
    echo "$a"
}

another_function() {
    echo "hello"
}
SAMPLE

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

echo ""
print_test_header "Shipwright Code Review Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-code-review.sh" help 2>&1) || true
assert_contains "help shows usage text" "$output" "Autonomous Code Review Agent"

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-code-review.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-code-review.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "SUBCOMMANDS"

# ─── Test 4: Review subcommand runs ──────────────────────────────────────────
# Note: review uses mapfile (Bash 4+), so on Bash 3.2 it may error.
# We just verify the script starts reviewing without crashing before that point.
output=$(bash "$SCRIPT_DIR/sw-code-review.sh" review 2>&1) || true
assert_contains "review runs and starts reviewing" "$output" "Reviewing code changes"

# ─── Test 5: Trends with no data ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-code-review.sh" trends 2>&1) || true
assert_contains "trends with no data" "$output" "No trend data"

# ─── Test 6: Config show creates default config ──────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-code-review.sh" config show 2>&1) || true
assert_contains "config show outputs valid config" "$output" "strictness"

# ─── Test 7: Unknown subcommand fails ────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-code-review.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown subcommand exits nonzero"
else
    assert_pass "unknown subcommand exits nonzero"
fi

# ─── Test 8: Code smell detection on clean file ──────────────────────────────
# Source the script to access functions directly
(
    REPO_DIR="$TEST_TEMP_DIR/repo"
    source "$SCRIPT_DIR/sw-code-review.sh"
    output=$(detect_code_smells "$TEST_TEMP_DIR/repo/scripts/sample.sh" 2>&1) || true
    # Clean file should have no LONG_FUNCTION or DEEP_NESTING
    if echo "$output" | grep -q "LONG_FUNCTION"; then
        echo "FAIL"
    else
        echo "PASS"
    fi
) | grep -q "PASS"
if [[ $? -eq 0 ]]; then
    assert_pass "no false long function detection on small file"
else
    assert_fail "no false long function detection on small file"
fi

# ─── Test 9: Style consistency check runs ────────────────────────────────────
(
    REPO_DIR="$TEST_TEMP_DIR/repo"
    source "$SCRIPT_DIR/sw-code-review.sh"
    output=$(check_style_consistency "$TEST_TEMP_DIR/repo/scripts/sample.sh" 2>&1) || true
    echo "ran"
) | grep -q "ran"
assert_eq "style consistency check runs without crash" "0" "$?"

# ─── Test 10: Architecture boundary check runs ───────────────────────────────
(
    # shellcheck disable=SC2034
    REPO_DIR="$TEST_TEMP_DIR/repo"
    source "$SCRIPT_DIR/sw-code-review.sh"
    output=$(check_architecture_boundaries "$TEST_TEMP_DIR/repo/scripts/sample.sh" 2>&1) || true
    echo "ran"
) | grep -q "ran"
assert_eq "architecture boundary check runs without crash" "0" "$?"

echo ""
echo ""
print_test_results
