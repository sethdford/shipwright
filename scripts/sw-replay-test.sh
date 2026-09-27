#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright replay test — Pipeline run replay & timeline viewing        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    log) echo "abc1234 fix: something" ;;
    show-ref) exit 1 ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Replay Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows list" "$output" "list"
assert_contains "help shows show" "$output" "show"
assert_contains "help shows narrative" "$output" "narrative"
assert_contains "help shows diff" "$output" "diff"
assert_contains "help shows export" "$output" "export"
assert_contains "help shows compare" "$output" "compare"

# ─── Test 2: List with no events file ────────────────────────────────────
echo ""
echo -e "${BOLD}  List Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" list 2>&1) && rc=0 || rc=$?
assert_eq "list with no events exits 0" "0" "$rc"
assert_contains "list with no events warns" "$output" "No pipeline runs"

# ─── Test 3: Show without issue ───────────────────────────────────────────
echo ""
echo -e "${BOLD}  Show Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" show 2>&1) && rc=0 || rc=$?
assert_eq "show without issue exits non-zero" "1" "$rc"
assert_contains "show shows usage" "$output" "Usage"

# ─── Test 4: Narrative without issue ──────────────────────────────────────
echo ""
echo -e "${BOLD}  Narrative Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" narrative 2>&1) && rc=0 || rc=$?
assert_eq "narrative without issue exits non-zero" "1" "$rc"
assert_contains "narrative shows usage" "$output" "Usage"

# ─── Test 5: Diff without issue ──────────────────────────────────────────
echo ""
echo -e "${BOLD}  Diff Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" diff 2>&1) && rc=0 || rc=$?
assert_eq "diff without issue exits non-zero" "1" "$rc"
assert_contains "diff shows usage" "$output" "Usage"

# ─── Test 6: Export without issue ─────────────────────────────────────────
echo ""
echo -e "${BOLD}  Export Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" export 2>&1) && rc=0 || rc=$?
assert_eq "export without issue exits non-zero" "1" "$rc"
assert_contains "export shows usage" "$output" "Usage"

# ─── Test 7: Compare without args ────────────────────────────────────────
echo ""
echo -e "${BOLD}  Compare Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" compare 2>&1) && rc=0 || rc=$?
assert_eq "compare without args exits non-zero" "1" "$rc"
assert_contains "compare shows usage" "$output" "Usage"

# ─── Test 8: Show with non-existent issue ─────────────────────────────────
echo ""
echo -e "${BOLD}  Missing Data${RESET}"
# Create events file but with no matching issue
echo '{"type":"other","issue":999}' > "$HOME/.shipwright/events.jsonl"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" show 42 2>&1) && rc=0 || rc=$?
assert_eq "show non-existent issue exits non-zero" "1" "$rc"
assert_contains "show non-existent issue says not found" "$output" "No pipeline run found"

# ─── Test 9: List with events data ───────────────────────────────────────
echo ""
echo -e "${BOLD}  List With Events${RESET}"
cat > "$HOME/.shipwright/events.jsonl" <<'EVENTS'
{"type":"pipeline.started","ts":"2026-01-15T10:00:00Z","issue":42,"pipeline":"standard","model":"opus","goal":"test goal"}
{"type":"stage.completed","ts":"2026-01-15T10:05:00Z","issue":42,"stage":"plan","duration_s":300,"result":"success"}
{"type":"pipeline.completed","ts":"2026-01-15T10:30:00Z","issue":42,"result":"success","duration_s":1800,"input_tokens":50000,"output_tokens":10000}
EVENTS
output=$(bash "$SCRIPT_DIR/sw-replay.sh" list 2>&1) || true
assert_contains "list shows pipeline runs header" "$output" "Pipeline runs"

# ─── Test 10: Unknown command ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits non-zero" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown subcommand"

# ─── Test 11: Fixture events - list, show, narrative, export for issue #42 ───
echo ""
echo -e "${BOLD}  Pipeline Events Fixture (Issue #42)${RESET}"
cat > "$HOME/.shipwright/events.jsonl" <<'EVENTS42'
{"type":"pipeline.started","ts":"2026-02-15T10:00:00Z","issue":42,"pipeline":"standard","model":"opus","goal":"Fix the replay export format"}
{"type":"stage.completed","ts":"2026-02-15T10:05:00Z","issue":42,"stage":"plan","duration_s":300,"result":"success"}
{"type":"stage.completed","ts":"2026-02-15T10:15:00Z","issue":42,"stage":"build","duration_s":600,"result":"success"}
{"type":"pipeline.completed","ts":"2026-02-15T10:30:00Z","issue":42,"result":"success","duration_s":1800,"input_tokens":50000,"output_tokens":10000}
EVENTS42
output=$(bash "$SCRIPT_DIR/sw-replay.sh" list 2>&1) || true
assert_contains "list shows issue 42" "$output" "#42"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" show 42 2>&1) || true
assert_contains "show 42 has stage information" "$output" "Stages"
assert_contains "show 42 has plan stage" "$output" "plan"
assert_contains "show 42 has build stage" "$output" "build"
assert_contains "show 42 has Pipeline Type" "$output" "Pipeline Type"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" narrative 42 2>&1) || true
assert_contains "narrative 42 produces prose" "$output" "Pipeline processed issue #42"
assert_contains "narrative 42 has stages count" "$output" "stages"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" export 42 2>&1) || true
assert_contains "export 42 produces report" "$output" "Pipeline Report"
assert_contains "export 42 has JSON-structured events" "$output" "Events"
assert_contains "export 42 has stage table" "$output" "| Stage |"

# ─── Test 12: Diff and compare error handling (missing second arg) ───────────
echo ""
echo -e "${BOLD}  Diff/Compare Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" diff 2>&1) && rc=0 || rc=$?
assert_eq "diff without issue exits non-zero" "1" "$rc"
assert_contains "diff without issue shows usage" "$output" "Usage"
output=$(bash "$SCRIPT_DIR/sw-replay.sh" compare 42 2>&1) && rc=0 || rc=$?
assert_eq "compare with missing second issue exits non-zero" "1" "$rc"
assert_contains "compare missing arg shows usage" "$output" "Usage"

echo ""
echo ""
print_test_results
