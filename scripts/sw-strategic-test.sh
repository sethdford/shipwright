#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright strategic test — Validate strategic intelligence agent       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

REAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-strategic-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/home/.claude"
    mkdir -p "$TEMP_DIR/repo/scripts"
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
        else echo "abc1234"; fi ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"
    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    issue)
        case "${2:-}" in
            list) echo '[]' ;;
            create) echo "https://github.com/test/repo/issues/99" ;;
            *) echo '[]' ;;
        esac ;;
    label) exit 0 ;;
    *) echo '[]' ;;
esac
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
    export SCRIPT_DIR="$TEMP_DIR/repo/scripts"
    export EVENTS_FILE="$TEMP_DIR/home/.shipwright/events.jsonl"

    # Create mock scripts to count
    for i in 1 2 3 4 5; do
        echo '#!/usr/bin/env bash' > "$TEMP_DIR/repo/scripts/sw-test${i}.sh"
    done
    # Create one test file
    echo '#!/usr/bin/env bash' > "$TEMP_DIR/repo/scripts/sw-test1-test.sh"

    # Create STRATEGY.md
    echo "# Strategy" > "$TEMP_DIR/repo/STRATEGY.md"
    echo "P0: Reliability" >> "$TEMP_DIR/repo/STRATEGY.md"
}

cleanup_env() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Strategic Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help ────────────────────────────────────────────────────
echo -e "${BOLD}  Help${RESET}"
output=$(bash "$REAL_SCRIPT_DIR/sw-strategic.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "Usage"
assert_contains "help shows commands" "$output" "Commands"

# ─── Test 2: Unknown command ─────────────────────────────────────────
output=$(bash "$REAL_SCRIPT_DIR/sw-strategic.sh" nonexistent 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 3: Source the script for function testing ──────────────────
echo -e "${BOLD}  Sourced Functions${RESET}"
# Source the strategic script for function testing
source "$REAL_SCRIPT_DIR/sw-strategic.sh" 2>/dev/null || true

# ─── Test 4: strategic_check_cooldown with no events ────────────────
if strategic_check_cooldown 2>/dev/null; then
    assert_pass "cooldown passes with no events file"
else
    assert_fail "cooldown passes with no events file" "returned non-zero"
fi

# ─── Test 5: strategic_check_cooldown with recent event ─────────────
local_epoch=$(date +%s)
echo "{\"ts\":\"2026-01-01T00:00:00Z\",\"ts_epoch\":${local_epoch},\"type\":\"strategic.cycle_complete\"}" > "$EVENTS_FILE"
if strategic_check_cooldown 2>/dev/null; then
    assert_fail "cooldown blocks after recent cycle" "should have returned non-zero"
else
    assert_pass "cooldown blocks after recent cycle"
fi

# ─── Test 6: strategic_check_cooldown with old event ────────────────
old_epoch=$((local_epoch - 20000))
echo "{\"ts\":\"2026-01-01T00:00:00Z\",\"ts_epoch\":${old_epoch},\"type\":\"strategic.cycle_complete\"}" > "$EVENTS_FILE"
if strategic_check_cooldown 2>/dev/null; then
    assert_pass "cooldown passes after old cycle"
else
    assert_fail "cooldown passes after old cycle" "should have returned zero"
fi

# ─── Test 7: strategic_gather_context produces output ────────────────
echo -e "${BOLD}  Context Gathering${RESET}"
context_output=$(strategic_gather_context 2>/dev/null) || true
assert_contains "gather_context includes TOTAL_SCRIPTS" "$context_output" "TOTAL_SCRIPTS="
assert_contains "gather_context includes TOTAL_TESTS" "$context_output" "TOTAL_TESTS="
assert_contains "gather_context includes UNTESTED_COUNT" "$context_output" "UNTESTED_COUNT="
assert_contains "gather_context includes SUCCESS_RATE" "$context_output" "SUCCESS_RATE="

# ─── Test 8: strategic_build_prompt produces prompt ──────────────────
echo -e "${BOLD}  Prompt Building${RESET}"
prompt_output=$(strategic_build_prompt 2>/dev/null) || true
assert_contains "build_prompt includes strategy content" "$prompt_output" "Strategy"
assert_contains "build_prompt includes format instructions" "$prompt_output" "ISSUE_TITLE"
assert_contains "build_prompt includes rules" "$prompt_output" "Rules"

# ─── Test 9: strategic_parse_and_create with mock response ───────────
echo -e "${BOLD}  Parse & Create${RESET}"
mock_response="ISSUE_TITLE: Test improvement
PRIORITY: P1
COMPLEXITY: standard
STRATEGY_AREA: P0: Reliability
DESCRIPTION: This is a test improvement for reliability.
ACCEPTANCE: - Tests pass
- Coverage above 80%
---"
# NO_GITHUB=true means it will do dry-run
result=$(strategic_parse_and_create "$mock_response" 2>/dev/null) || true
created="${result%%:*}"
skipped="${result##*:}"
assert_eq "parse creates 1 issue (dry-run)" "1" "$created"

# ─── Test 10: Status with no events ─────────────────────────────────
echo -e "${BOLD}  Status${RESET}"
echo "" > "$EVENTS_FILE"
output=$(strategic_status 2>&1) || true
assert_contains "status shows header" "$output" "Strategic Agent Status"

# ─── Test 11: Status with cycle events ──────────────────────────────
echo "{\"ts\":\"2026-02-15T10:00:00Z\",\"ts_epoch\":${local_epoch},\"type\":\"strategic.cycle_complete\",\"issues_created\":2,\"issues_skipped\":1}" > "$EVENTS_FILE"
output=$(strategic_status 2>&1) || true
assert_contains "status shows last run" "$output" "Last run"

# ─── Test 12: Run without CLAUDE_CODE_OAUTH_TOKEN ────────────────────
echo -e "${BOLD}  Run Guard${RESET}"
echo "" > "$EVENTS_FILE"  # Clear cooldown so token check is reached
unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
output=$(bash "$REAL_SCRIPT_DIR/sw-strategic.sh" run 2>&1) || true
assert_contains "run without token shows error" "$output" "CLAUDE_CODE_OAUTH_TOKEN"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
