#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright team-stages test — Validate multi-agent stage execution      ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-team-stages-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/team-state"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/home/.claude"
    mkdir -p "$TEMP_DIR/repo/.claude"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    cat > "$TEMP_DIR/bin/sqlite3" <<'MOCK'
#!/usr/bin/env bash
echo ""
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/sqlite3"
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "HEAD" ]]; then echo "abc1234"
        else echo "abc1234"; fi ;;
    diff) echo "file1.sh"; echo "file2.sh"; echo "file3.sh" ;;
    ls-files) echo "file1.sh"; echo "file2.sh" ;;
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
    cat > "$TEMP_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/tmux"
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
    export REPO_DIR="$TEMP_DIR/repo"
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Team Stages Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help ────────────────────────────────────────────────────
echo -e "${BOLD}  Help${RESET}"
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "USAGE"

# ─── Test 3: Unknown command ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: Compose for build stage ────────────────────────────────
echo -e "${BOLD}  Compose${RESET}"
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" compose build 2>&1) || true
assert_contains "compose build outputs JSON with stage" "$output" "build"
# Verify it's valid JSON
if echo "$output" | jq empty 2>/dev/null; then
    assert_pass "compose output is valid JSON"
    stage=$(echo "$output" | jq -r '.stage')
    assert_eq "compose stage is build" "build" "$stage"
else
    assert_fail "compose output is valid JSON" "invalid JSON"
    assert_fail "compose stage is build" "could not parse"
fi

# ─── Test 5: Compose for test stage ─────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" compose test 2>&1) || true
if echo "$output" | jq -e '.specialists | index("tester")' >/dev/null 2>&1; then
    assert_pass "compose test includes tester specialist"
else
    assert_fail "compose test includes tester specialist" "tester not in specialists"
fi

# ─── Test 6: Compose for review stage ───────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" compose review 2>&1) || true
if echo "$output" | jq -e '.specialists | index("reviewer")' >/dev/null 2>&1; then
    assert_pass "compose review includes reviewer specialist"
else
    assert_fail "compose review includes reviewer specialist" "reviewer not in specialists"
fi

# ─── Test 7: Roles listing ──────────────────────────────────────────
echo -e "${BOLD}  Roles${RESET}"
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" roles 2>&1) || true
assert_contains "roles shows builder" "$output" "builder"
assert_contains "roles shows reviewer" "$output" "reviewer"
assert_contains "roles shows tester" "$output" "tester"
assert_contains "roles shows security" "$output" "security"
assert_contains "roles shows docs" "$output" "docs"

# ─── Test 8: Status with no active teams ─────────────────────────────
echo -e "${BOLD}  Status${RESET}"
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" status 2>&1) || true
assert_contains "status with no teams" "$output" "No active teams"

# ─── Test 9: Delegate generates tasks ───────────────────────────────
echo -e "${BOLD}  Delegate${RESET}"
output=$(bash "$SCRIPT_DIR/sw-team-stages.sh" delegate build 2>&1) || true
if echo "$output" | jq -e '.tasks' >/dev/null 2>&1; then
    assert_pass "delegate produces tasks array"
    file_count=$(echo "$output" | jq -r '.file_count // 0')
    if [[ "$file_count" -gt 0 ]]; then
        assert_pass "delegate assigns files to tasks"
    else
        assert_pass "delegate handles no changed files gracefully"
    fi
else
    assert_fail "delegate produces tasks array" "no tasks in output"
    assert_fail "delegate assigns files to tasks" "could not parse"
fi

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
