#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright trace test — E2E traceability (Issue → Commit → PR → Deploy)║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    MOCK_REPO_DIR="$TEST_TEMP_DIR/mock-repo"
    cat > "$TEST_TEMP_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
    rev-parse)
        if [[ "\${2:-}" == "--show-toplevel" ]]; then echo "$MOCK_REPO_DIR"
        elif [[ "\${2:-}" == "--is-inside-work-tree" ]]; then echo "true"
        else echo "abc1234"; fi ;;
    log) echo "abc1234 fix: something" ;;
    branch)
        if [[ "\${2:-}" == "-r" ]]; then echo ""
        elif [[ "\${2:-}" == "--show-current" ]]; then echo "main"
        else echo ""; fi ;;
    show-ref) exit 1 ;;
    worktree) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
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
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    mkdir -p "$MOCK_REPO_DIR/.claude/pipeline-artifacts"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap 'cleanup_test_env; sw_test_teardown' EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Trace Tests"
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
echo ""
print_test_results
