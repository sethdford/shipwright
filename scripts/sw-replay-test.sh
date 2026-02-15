#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright replay test — Pipeline run replay & timeline viewing        ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-replay-test.XXXXXX")
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
        else echo "abc1234"; fi ;;
    log) echo "abc1234 fix: something" ;;
    show-ref) exit 1 ;;
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
echo -e "${CYAN}${BOLD}  Shipwright Replay Tests${RESET}"
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

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
