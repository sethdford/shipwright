#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright instrument test — Pipeline instrumentation & feedback loops  ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-instrument-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi
    if command -v bc &>/dev/null; then
        ln -sf "$(command -v bc)" "$TEMP_DIR/bin/bc"
    fi
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
echo '[]'
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/gh"
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
echo -e "${CYAN}${BOLD}  Shipwright Instrument Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows commands" "$output" "COMMANDS"
assert_contains "help shows start" "$output" "start"
assert_contains "help shows record" "$output" "record"

# ─── Test 2: VERSION presence ─────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" help 2>&1) || true
assert_contains_regex "help shows version" "$output" "v[0-9]+\.[0-9]+\.[0-9]+"

# ─── Test 3: Start without --run-id errors ────────────────────────────────
echo ""
echo -e "${BOLD}  Start Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" start 2>&1) && rc=0 || rc=$?
assert_eq "start without --run-id exits non-zero" "1" "$rc"
assert_contains "start without --run-id shows error" "$output" "Usage"

# ─── Test 4: Start with --run-id creates run file ─────────────────────────
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" start --run-id test-run-1 --issue 42 2>&1) && rc=0 || rc=$?
assert_eq "start with --run-id exits 0" "0" "$rc"
assert_contains "start confirms run ID" "$output" "test-run-1"
run_file="$HOME/.shipwright/instrumentation/active/test-run-1.json"
if [[ -f "$run_file" ]]; then
    assert_pass "start creates run file"
    run_id_in_file=$(jq -r '.run_id' "$run_file")
    assert_eq "run file contains correct run_id" "test-run-1" "$run_id_in_file"
    issue_in_file=$(jq -r '.issue' "$run_file")
    assert_eq "run file contains correct issue" "42" "$issue_in_file"
else
    assert_fail "start creates run file" "file not found: $run_file"
fi

# ─── Test 5: Record metric ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Record Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" record --run-id test-run-1 --stage build --metric iterations --value 5 2>&1) && rc=0 || rc=$?
assert_eq "record exits 0" "0" "$rc"
assert_contains "record confirms metric" "$output" "iterations"
# Verify metric in run file
if [[ -f "$run_file" ]]; then
    metric_count=$(jq '.metrics | length' "$run_file")
    assert_eq "run file has 1 metric" "1" "$metric_count"
fi

# ─── Test 6: Record without required args ─────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" record --run-id test-run-1 2>&1) && rc=0 || rc=$?
assert_eq "record without all args exits non-zero" "1" "$rc"

# ─── Test 7: Record on non-existent run ───────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" record --run-id nonexistent --stage x --metric y --value 1 2>&1) && rc=0 || rc=$?
assert_eq "record on missing run exits non-zero" "1" "$rc"
assert_contains "record on missing run shows error" "$output" "Run not found"

# ─── Test 8: Stage start/end ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Stage Start/End${RESET}"
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" stage-start --run-id test-run-1 --stage plan 2>&1) && rc=0 || rc=$?
assert_eq "stage-start exits 0" "0" "$rc"
assert_contains "stage-start confirms stage" "$output" "plan"

output=$(bash "$SCRIPT_DIR/sw-instrument.sh" stage-end --run-id test-run-1 --stage plan --result success 2>&1) && rc=0 || rc=$?
assert_eq "stage-end exits 0" "0" "$rc"
if [[ -f "$run_file" ]]; then
    stage_result=$(jq -r '.stages.plan.result' "$run_file")
    assert_eq "stage result recorded" "success" "$stage_result"
fi

# ─── Test 9: Finish run ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Finish Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" finish --run-id test-run-1 --result success 2>&1) && rc=0 || rc=$?
assert_eq "finish exits 0" "0" "$rc"
assert_contains "finish confirms completion" "$output" "test-run-1"
# Active file should be removed
if [[ ! -f "$run_file" ]]; then
    assert_pass "finish removes active run file"
else
    assert_fail "finish removes active run file" "file still exists"
fi
# Completed JSONL should exist
completed_file="$HOME/.shipwright/instrumentation.jsonl"
if [[ -f "$completed_file" ]]; then
    assert_pass "finish writes to completed JSONL"
else
    assert_fail "finish writes to completed JSONL" "file not found"
fi

# ─── Test 10: Trends with no data ────────────────────────────────────────
echo ""
echo -e "${BOLD}  Trends & Export${RESET}"
# Remove completed file for clean test
rm -f "$HOME/.shipwright/instrumentation.jsonl"
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" trends 2>&1) && rc=0 || rc=$?
assert_eq "trends with no data exits 0" "0" "$rc"
assert_contains "trends with no data warns" "$output" "No completed runs"

# ─── Test 11: Export with no data ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" export 2>&1) && rc=0 || rc=$?
assert_eq "export with no data exits 0" "0" "$rc"
assert_contains "export with no data warns" "$output" "No completed runs"

# ─── Test 12: Unknown command ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-instrument.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits non-zero" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 13: Events file written ─────────────────────────────────────────
events_file="$HOME/.shipwright/events.jsonl"
if [[ -f "$events_file" ]]; then
    assert_pass "events.jsonl created from instrument operations"
else
    assert_fail "events.jsonl created from instrument operations" "file not found"
fi

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
