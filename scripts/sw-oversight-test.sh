#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright oversight test — Quality oversight board tests               ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-oversight-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/oversight/history"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.claude"
    mkdir -p "$TEMP_DIR/repo/.git"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"

    # Mock bc (for verdict calculation)
    if ! command -v bc &>/dev/null; then
        cat > "$TEMP_DIR/bin/bc" <<'MOCK'
#!/usr/bin/env bash
echo "1"
MOCK
        chmod +x "$TEMP_DIR/bin/bc"
    else
        ln -sf "$(command -v bc)" "$TEMP_DIR/bin/bc"
    fi

    # Mock od (for review ID generation)
    if command -v od &>/dev/null; then
        ln -sf "$(command -v od)" "$TEMP_DIR/bin/od"
    fi

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
echo -e "${CYAN}${BOLD}  Shipwright Oversight Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-oversight.sh" help 2>&1) || true
assert_contains "help shows usage text" "$output" "shipwright oversight"

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-oversight.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-oversight.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "COMMANDS"

# ─── Test 4: Unknown command exits 1 ─────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-oversight.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown command exits 1"
else
    assert_pass "unknown command exits 1"
fi

# ─── Test 5: Members initialization ──────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-oversight.sh" members 2>&1) || true
assert_contains "members shows board" "$output" "Oversight Board Members"

# ─── Test 6: Members file created ────────────────────────────────────────────
if [[ -f "$HOME/.shipwright/oversight/members.json" ]]; then
    assert_pass "members.json created"
else
    assert_fail "members.json created"
fi

# ─── Test 7: Members file is valid JSON ──────────────────────────────────────
if jq '.' "$HOME/.shipwright/oversight/members.json" >/dev/null 2>&1; then
    assert_pass "members.json is valid JSON"
else
    assert_fail "members.json is valid JSON"
fi

# ─── Test 8: Config initialization ───────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-oversight.sh" config show 2>&1) || true
assert_contains "config show works" "$output" "quorum"

# ─── Test 9: Config file created ─────────────────────────────────────────────
if [[ -f "$HOME/.shipwright/oversight/config.json" ]]; then
    assert_pass "config.json created"
else
    assert_fail "config.json created"
fi

# ─── Test 10: Stats with empty board ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-oversight.sh" stats 2>&1) || true
assert_contains "stats shows statistics" "$output" "Oversight Board Statistics"

# ─── Test 11: History with no reviews ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-oversight.sh" history 2>&1) || true
assert_contains "history handles empty" "$output" "No reviews found"

# ─── Test 12: Review requires args ───────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-oversight.sh" review >/dev/null 2>&1; then
    assert_fail "review without args exits nonzero"
else
    assert_pass "review without args exits nonzero"
fi

# ─── Test 13: Submit a review ────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-oversight.sh" review --pr 42 --description "Test review" 2>&1) || true
assert_contains "review submission accepted" "$output" "Review submitted"

# ─── Test 14: Review creates a JSON file ──────────────────────────────────────
review_files=$(find "$HOME/.shipwright/oversight" -maxdepth 1 -name '*.json' -not -name 'config.json' -not -name 'members.json' | head -1)
if [[ -n "$review_files" ]]; then
    assert_pass "review JSON file created"
else
    assert_fail "review JSON file created"
fi

# ─── Test 15: Review file is valid JSON ───────────────────────────────────────
if [[ -n "$review_files" ]] && jq '.' "$review_files" >/dev/null 2>&1; then
    assert_pass "review file is valid JSON"
else
    assert_fail "review file is valid JSON"
fi

# ─── Test 16: Stats after review shows count ──────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-oversight.sh" stats 2>&1) || true
assert_contains_regex "stats shows total reviews >= 1" "$output" "Total Reviews: [1-9]"

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
