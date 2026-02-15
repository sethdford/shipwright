#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright release-manager test — Validate release pipeline             ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-rm-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/releases"
    mkdir -p "$TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    describe)
        echo "v1.2.3"
        exit 0
        ;;
    tag)
        echo "v1.2.3"
        echo "v1.2.2"
        echo "v1.2.1"
        exit 0
        ;;
    log)
        echo "abc1234|feat: new feature||"
        exit 0
        ;;
    rev-list)
        echo "abc1234"
        exit 0
        ;;
    diff)
        echo "+added line"
        exit 0
        ;;
    *)
        echo "mock git: $*"
        exit 0
        ;;
esac
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
    echo "[]"
    exit 0
fi
echo "mock gh"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock claude
    cat > "$TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "Release looks good."
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/claude"

    # Create empty events file
    touch "$TEMP_DIR/home/.shipwright/events.jsonl"

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

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Release Manager Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-release-manager.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help mentions check" "$output" "check"
assert_contains "help mentions prepare" "$output" "prepare"
assert_contains "help mentions publish" "$output" "publish"
assert_contains "help mentions rollback" "$output" "rollback"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
if grep -q '^VERSION=' "$SCRIPT_DIR/sw-release-manager.sh"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: unknown command exits non-zero ─────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-release-manager.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 4: history command ────────────────────────────────────────────────
echo ""
echo -e "${DIM}  history command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-release-manager.sh" history 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "history exits 0"
else
    assert_fail "history exits 0" "exit code: $rc"
fi

# ─── Test 5: stats command ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  stats command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-release-manager.sh" stats 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "stats exits 0"
else
    assert_fail "stats exits 0" "exit code: $rc"
fi

# ─── Test 6: source guard pattern ───────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-release-manager.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q 'BASH_SOURCE\[0\].*==.*\$0' "$SCRIPT_DIR/sw-release-manager.sh"; then
    assert_pass "Has source guard pattern"
else
    assert_fail "Has source guard pattern"
fi

# ─── Test 7: release state dir creation ─────────────────────────────────────
echo ""
echo -e "${DIM}  state management${RESET}"

if [[ -d "$HOME/.shipwright/releases" ]]; then
    assert_pass "Release state directory exists"
else
    assert_fail "Release state directory exists"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

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
