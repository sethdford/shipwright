#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright testgen test — Test generation & coverage tests              ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-testgen-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.claude/testgen"
    mkdir -p "$TEMP_DIR/repo/.git"
    mkdir -p "$TEMP_DIR/repo/scripts"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
    rev-parse)
        case "\${2:-}" in
            --show-toplevel) echo "$TEMP_DIR/repo" ;;
            *) echo "$TEMP_DIR/repo" ;;
        esac
        ;;
    diff) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"

    # Create a sample script with functions to analyze
    cat > "$TEMP_DIR/repo/scripts/sample-target.sh" <<'SAMPLE'
#!/usr/bin/env bash
set -euo pipefail

alpha_func() {
    echo "alpha"
}

beta_func() {
    echo "beta"
}

gamma_func() {
    echo "gamma"
}
SAMPLE

    # Create a mock test file that tests alpha_func
    cat > "$TEMP_DIR/repo/scripts/sample-target-test.sh" <<'TESTFILE'
#!/usr/bin/env bash
# Tests for sample-target
alpha_func  # tested
TESTFILE

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
echo -e "${CYAN}${BOLD}  Shipwright Testgen Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" help 2>&1) || true
assert_contains "help shows usage text" "$output" "shipwright testgen"

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-testgen.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "COMMANDS"

# ─── Test 4: Unknown command exits 1 ─────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-testgen.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown command exits 1"
else
    assert_pass "unknown command exits 1"
fi

# ─── Test 5: Coverage analysis on target file ────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" coverage "$TEMP_DIR/repo/scripts/sample-target.sh" 2>&1) || true
assert_contains "coverage shows analysis" "$output" "Coverage Analysis"

# ─── Test 6: Coverage JSON output ────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" coverage "$TEMP_DIR/repo/scripts/sample-target.sh" json 2>&1) || true
if echo "$output" | jq '.' >/dev/null 2>&1; then
    assert_pass "coverage JSON is valid"
else
    assert_fail "coverage JSON is valid" "output: $output"
fi

# ─── Test 7: Threshold show ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" threshold show 2>&1) || true
assert_contains "threshold show outputs value" "$output" "coverage threshold"

# ─── Test 8: Threshold set ───────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" threshold set 80 2>&1) || true
assert_contains "threshold set confirms" "$output" "set to 80"

# ─── Test 9: Quality scoring on test file ─────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" quality "$TEMP_DIR/repo/scripts/sample-target-test.sh" 2>&1) || true
assert_contains "quality scoring runs" "$output" "Scoring test quality"

# ─── Test 10: Quality on missing file ────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-testgen.sh" quality "/nonexistent/path.sh" >/dev/null 2>&1; then
    assert_fail "quality on missing file exits nonzero"
else
    assert_pass "quality on missing file exits nonzero"
fi

# ─── Test 11: Gaps detection ─────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-testgen.sh" gaps "$TEMP_DIR/repo/scripts/sample-target.sh" 2>&1) || true
assert_contains "gaps shows untested functions" "$output" "Finding test gaps"

# ─── Test 12: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep "^VERSION=" "$SCRIPT_DIR/sw-testgen.sh" | head -1)
assert_contains "VERSION is defined" "$version_line" "VERSION="

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
