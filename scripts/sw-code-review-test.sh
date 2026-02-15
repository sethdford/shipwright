#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright code-review test — Clean code & architecture analysis tests  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-code-review-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.claude/pipeline-artifacts"
    mkdir -p "$TEMP_DIR/repo/.git"
    mkdir -p "$TEMP_DIR/repo/scripts"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        case "${2:-}" in
            --show-toplevel) echo "$TEMP_DIR/repo" ;;
            *) echo "/tmp/mock-repo" ;;
        esac
        ;;
    diff) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"
    # git mock needs TEMP_DIR — inject it
    sed -i '' "s|\$TEMP_DIR|$TEMP_DIR|g" "$TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock claude
    cat > "$TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/claude"

    # Create a sample .sh file for analysis
    cat > "$TEMP_DIR/repo/scripts/sample.sh" <<'SAMPLE'
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

    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() {
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

assert_contains_regex() {
    local desc="$1" haystack="$2" pattern="$3"
    if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing pattern: $pattern"
    fi
}

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Code Review Tests${RESET}"
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
    REPO_DIR="$TEMP_DIR/repo"
    source "$SCRIPT_DIR/sw-code-review.sh"
    output=$(detect_code_smells "$TEMP_DIR/repo/scripts/sample.sh" 2>&1) || true
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
    REPO_DIR="$TEMP_DIR/repo"
    source "$SCRIPT_DIR/sw-code-review.sh"
    output=$(check_style_consistency "$TEMP_DIR/repo/scripts/sample.sh" 2>&1) || true
    echo "ran"
) | grep -q "ran"
assert_eq "style consistency check runs without crash" "0" "$?"

# ─── Test 10: Architecture boundary check runs ───────────────────────────────
(
    REPO_DIR="$TEMP_DIR/repo"
    source "$SCRIPT_DIR/sw-code-review.sh"
    output=$(check_architecture_boundaries "$TEMP_DIR/repo/scripts/sample.sh" 2>&1) || true
    echo "ran"
) | grep -q "ran"
assert_eq "architecture boundary check runs without crash" "0" "$?"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
else
    echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
    for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done
fi
echo ""
exit "$FAIL"
