#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright changelog test — Validate release notes generation           ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-changelog-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.git"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git with conventional commit log
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    -C)
        shift
        shift
        case "${1:-}" in
            describe)
                echo "v1.0.0"
                ;;
            log)
                echo "abc1234|Author|author@test.com|2026-01-15|feat: add new auth module|"
                echo "def5678|Author|author@test.com|2026-01-14|fix: resolve login bug|"
                echo "ghi9012|Author|author@test.com|2026-01-13|docs: update README|"
                ;;
            rev-list)
                echo "abc1234"
                ;;
            *)
                echo "mock git -C"
                ;;
        esac
        ;;
    describe)
        echo "v1.0.0"
        ;;
    log)
        echo "abc1234|Author|author@test.com|2026-01-15|feat: add new auth module|"
        echo "def5678|Author|author@test.com|2026-01-14|fix: resolve login bug|"
        ;;
    rev-list)
        echo "abc1234"
        ;;
    *)
        echo "mock git"
        ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Mock claude
    cat > "$TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "Migration guide: No breaking changes detected."
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/claude"

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
echo -e "${CYAN}${BOLD}  Shipwright Changelog Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-changelog.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help mentions generate" "$output" "generate"
assert_contains "help mentions preview" "$output" "preview"
assert_contains "help mentions version" "$output" "version"
assert_contains "help mentions migrate" "$output" "migrate"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
if grep -q '^VERSION=' "$SCRIPT_DIR/sw-changelog.sh"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: unknown command ────────────────────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-changelog.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 4: formats command ────────────────────────────────────────────────
echo ""
echo -e "${DIM}  formats command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-changelog.sh" formats 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "formats exits 0"
else
    assert_fail "formats exits 0" "exit code: $rc"
fi

# ─── Test 5: generate command ───────────────────────────────────────────────
echo ""
echo -e "${DIM}  generate command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-changelog.sh" generate 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "generate exits 0"
else
    assert_fail "generate exits 0" "exit code: $rc"
fi

# ─── Test 6: version command recommends semver ──────────────────────────────
echo ""
echo -e "${DIM}  version command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-changelog.sh" version 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "version recommendation exits 0"
else
    assert_fail "version recommendation exits 0" "exit code: $rc"
fi

# ─── Test 7: source guard pattern ───────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-changelog.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q 'BASH_SOURCE\[0\].*==.*\$0' "$SCRIPT_DIR/sw-changelog.sh"; then
    assert_pass "Has source guard pattern"
else
    assert_fail "Has source guard pattern"
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
