#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright trace test — E2E traceability (Issue → Commit → PR → Deploy)║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-trace-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    cat > "$TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--is-inside-work-tree" ]]; then echo "true"
        else echo "abc1234"; fi ;;
    log) echo "abc1234 fix: something" ;;
    branch)
        if [[ "${2:-}" == "-r" ]]; then echo ""
        elif [[ "${2:-}" == "--show-current" ]]; then echo "main"
        else echo ""; fi ;;
    show-ref) exit 1 ;;
    worktree) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"
    cat > "$TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    issue)
        echo '{"title":"Test Issue","state":"OPEN","assignees":[],"labels":[],"url":"https://github.com/test/repo/issues/42","createdAt":"2026-01-15T10:00:00Z","closedAt":null}'
        ;;
    pr)
        echo '[]'
        ;;
    repo)
        echo "test/repo"
        ;;
    *)
        echo '[]'
        ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"
    # Create mock .claude directory
    mkdir -p "/tmp/mock-repo/.claude/pipeline-artifacts"
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() {
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    rm -rf "/tmp/mock-repo" 2>/dev/null || true
}
trap cleanup_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected: $expected, got: $actual"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if echo "$haystack" | grep -qE "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Trace Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-trace.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows show" "$output" "show"
assert_contains "help shows list" "$output" "list"
assert_contains "help shows search" "$output" "search"
assert_contains "help shows export" "$output" "export"

# ─── Test 2: Show without issue number ────────────────────────────────────
echo ""
echo -e "${BOLD}  Show Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-trace.sh" show 2>&1) && rc=0 || rc=$?
assert_eq "show without issue exits non-zero" "1" "$rc"
assert_contains "show without issue shows error" "$output" "Issue number required"

# ─── Test 3: Show with issue (uses gh mock) ───────────────────────────────
# Create events file with matching data
cat > "$HOME/.shipwright/events.jsonl" <<'EVENTS'
{"ts":"2026-01-15T10:00:00Z","type":"pipeline_start","issue":42,"job_id":"job-001","stage":"intake"}
{"ts":"2026-01-15T10:05:00Z","type":"stage_complete","issue":42,"job_id":"job-001","stage":"plan","duration_seconds":300}
EVENTS
output=$(bash "$SCRIPT_DIR/sw-trace.sh" show 42 2>&1) || true
assert_contains "show displays ISSUE section" "$output" "ISSUE"
assert_contains "show displays issue title" "$output" "Test Issue"
assert_contains "show displays PIPELINE section" "$output" "PIPELINE"
assert_contains "show displays PULL REQUEST section" "$output" "PULL REQUEST"
assert_contains "show displays DEPLOYMENT section" "$output" "DEPLOYMENT"

# ─── Test 4: List with no events ─────────────────────────────────────────
echo ""
echo -e "${BOLD}  List Command${RESET}"
rm -f "$HOME/.shipwright/events.jsonl"
output=$(bash "$SCRIPT_DIR/sw-trace.sh" list 2>&1) && rc=0 || rc=$?
assert_eq "list with no events exits non-zero" "1" "$rc"
assert_contains "list with no events warns" "$output" "No events log"

# ─── Test 5: List with events ────────────────────────────────────────────
cat > "$HOME/.shipwright/events.jsonl" <<'EVENTS'
{"ts":"2026-01-15T10:00:00Z","type":"pipeline_start","issue":42,"job_id":"job-001","stage":"intake","status":"running","duration_secs":0}
{"ts":"2026-01-15T10:30:00Z","type":"pipeline_complete","issue":42,"job_id":"job-001","stage":"monitor","status":"completed","duration_secs":1800}
EVENTS
output=$(bash "$SCRIPT_DIR/sw-trace.sh" list 2>&1) || true
assert_contains "list shows header" "$output" "Recent pipeline runs"

# ─── Test 6: Search without proper args ───────────────────────────────────
echo ""
echo -e "${BOLD}  Search Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-trace.sh" search 2>&1) && rc=0 || rc=$?
assert_eq "search without --commit exits non-zero" "1" "$rc"
assert_contains "search shows usage" "$output" "Usage"

output=$(bash "$SCRIPT_DIR/sw-trace.sh" search --commit 2>&1) && rc=0 || rc=$?
assert_eq "search --commit without sha exits non-zero" "1" "$rc"

# ─── Test 7: Export without issue ─────────────────────────────────────────
echo ""
echo -e "${BOLD}  Export Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-trace.sh" export 2>&1) && rc=0 || rc=$?
assert_eq "export without issue exits non-zero" "1" "$rc"
assert_contains "export without issue shows error" "$output" "Issue number required"

# ─── Test 8: Unknown command ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-trace.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits non-zero" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
