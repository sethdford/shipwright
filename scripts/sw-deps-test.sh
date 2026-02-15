#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright deps test — Automated Dependency Update Management tests     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-deps-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"
    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"
    cat > "$TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/claude"
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Deps Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright deps"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-deps.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: scan with NO_GITHUB ──────────────────────────────────────────
echo ""
echo -e "  ${CYAN}scan subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" scan 2>&1) && rc=0 || rc=$?
assert_eq "scan exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "scan shows warning" "$output" "GitHub API disabled"

# ─── Test 5: classify missing args ────────────────────────────────────────
echo ""
echo -e "  ${CYAN}classify subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" classify 2>&1) && rc=0 || rc=$?
assert_eq "classify without args exits 1" "1" "$rc"
assert_contains "classify shows usage" "$output" "Usage"

# ─── Test 6: classify with NO_GITHUB ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-deps.sh" classify 123 2>&1) && rc=0 || rc=$?
assert_eq "classify exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "classify shows warning" "$output" "GitHub API disabled"

# ─── Test 7: batch with NO_GITHUB ─────────────────────────────────────────
echo ""
echo -e "  ${CYAN}batch subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" batch 2>&1) && rc=0 || rc=$?
assert_eq "batch exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "batch shows warning" "$output" "GitHub API disabled"

# ─── Test 8: report with NO_GITHUB ────────────────────────────────────────
echo ""
echo -e "  ${CYAN}report subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "report shows warning" "$output" "GitHub API disabled"

# ─── Test 9: merge missing args ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}merge subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" merge 2>&1) && rc=0 || rc=$?
assert_eq "merge without args exits 1" "1" "$rc"

# ─── Test 10: test missing args ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}test subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-deps.sh" test 2>&1) && rc=0 || rc=$?
assert_eq "test without args exits 1" "1" "$rc"

# ─── Test 11: parse_version_bump (source script) ──────────────────────────
echo ""
echo -e "  ${CYAN}internal parse_version_bump${RESET}"
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-deps.sh"

    # Patch bump
    result=$(parse_version_bump "1.2.3" "1.2.4")
    echo "PATCH:$result"

    # Minor bump
    result=$(parse_version_bump "1.2.3" "1.3.0")
    echo "MINOR:$result"

    # Major bump
    result=$(parse_version_bump "1.2.3" "2.0.0")
    echo "MAJOR:$result"
) > "$TEMP_DIR/version_output" 2>/dev/null

version_output=$(cat "$TEMP_DIR/version_output")
if echo "$version_output" | grep -qF "PATCH:patch"; then
    assert_pass "parse_version_bump detects patch"
else
    assert_fail "parse_version_bump detects patch" "got: $version_output"
fi
if echo "$version_output" | grep -qF "MINOR:minor"; then
    assert_pass "parse_version_bump detects minor"
else
    assert_fail "parse_version_bump detects minor" "got: $version_output"
fi
if echo "$version_output" | grep -qF "MAJOR:major"; then
    assert_pass "parse_version_bump detects major"
else
    assert_fail "parse_version_bump detects major" "got: $version_output"
fi

# ─── Test 12: parse_version_bump with v prefix ────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-deps.sh"
    result=$(parse_version_bump "v1.2.3" "v1.2.4")
    echo "$result"
) > "$TEMP_DIR/version_prefix" 2>/dev/null
prefix_result=$(cat "$TEMP_DIR/version_prefix")
assert_eq "parse_version_bump handles v prefix" "patch" "$prefix_result"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
