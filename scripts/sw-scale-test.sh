#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright scale test — Dynamic agent team scaling                     ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-scale-test.XXXXXX")
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
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEMP_DIR/bin/git"
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
echo -e "${CYAN}${BOLD}  Shipwright Scale Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-scale.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows up" "$output" "up"
assert_contains "help shows down" "$output" "down"
assert_contains "help shows rules" "$output" "rules"
assert_contains "help shows status" "$output" "status"
assert_contains "help shows history" "$output" "history"

# ─── Test 2: Rules init and show ──────────────────────────────────────────
echo ""
echo -e "${BOLD}  Rules Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-scale.sh" rules show 2>&1) || true
assert_contains "rules show has iteration_threshold" "$output" "iteration_threshold"
assert_contains "rules show has max_team_size" "$output" "max_team_size"
rules_file="$HOME/.shipwright/scale-rules.json"
if [[ -f "$rules_file" ]]; then
    assert_pass "rules creates default file"
else
    assert_fail "rules creates default file" "file not found"
fi

# ─── Test 3: Rules set ───────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-scale.sh" rules set max_team_size 12 2>&1) || true
assert_contains "rules set confirms update" "$output" "Updated"
if [[ -f "$rules_file" ]]; then
    value=$(jq -r '.max_team_size' "$rules_file")
    assert_eq "rules set persists value" "12" "$value"
fi

# ─── Test 4: Rules reset ─────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-scale.sh" rules reset 2>&1) || true
assert_contains "rules reset confirms" "$output" "reset to defaults"
if [[ -f "$rules_file" ]]; then
    value=$(jq -r '.max_team_size' "$rules_file")
    assert_eq "rules reset restores default" "8" "$value"
fi

# ─── Test 5: Rules set without args ───────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-scale.sh" rules set 2>&1) && rc=0 || rc=$?
assert_eq "rules set without args exits non-zero" "1" "$rc"

# ─── Test 6: Up with valid role ───────────────────────────────────────────
echo ""
echo -e "${BOLD}  Up Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-scale.sh" up builder 2>&1) || true
assert_contains "up records scale event" "$output" "Scale-up event recorded"
events_file="$HOME/.shipwright/scale-events.jsonl"
if [[ -f "$events_file" ]]; then
    assert_pass "up creates scale events file"
else
    assert_fail "up creates scale events file" "file not found"
fi

# ─── Test 7: Up with invalid role ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-scale.sh" up invalidrole 2>&1) && rc=0 || rc=$?
assert_eq "up with invalid role exits non-zero" "1" "$rc"
assert_contains "up invalid role shows error" "$output" "Invalid role"

# ─── Test 8: Down without agent-id ───────────────────────────────────────
echo ""
echo -e "${BOLD}  Down Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-scale.sh" down 2>&1) && rc=0 || rc=$?
assert_eq "down without agent-id exits non-zero" "1" "$rc"
assert_contains "down shows usage" "$output" "Usage"

# ─── Test 9: Down with agent-id ──────────────────────────────────────────
# Reset cooldown by removing state file
rm -f "$HOME/.shipwright/scale-state.json"
output=$(bash "$SCRIPT_DIR/sw-scale.sh" down agent-42 2>&1) || true
assert_contains "down records scale event" "$output" "Scale-down event recorded"

# ─── Test 10: Status command ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Status Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-scale.sh" status 2>&1) || true
assert_contains "status shows header" "$output" "Scaling Status"
assert_contains "status shows team size" "$output" "Team size"
assert_contains "status shows max team size" "$output" "Max team size"

# ─── Test 11: History command ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  History Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-scale.sh" history 2>&1) || true
assert_contains "history shows header" "$output" "Scaling History"

# ─── Test 12: History with no events ──────────────────────────────────────
rm -f "$HOME/.shipwright/scale-events.jsonl"
output=$(bash "$SCRIPT_DIR/sw-scale.sh" history 2>&1) || true
assert_contains "history with no events warns" "$output" "No scaling events"

# ─── Test 13: Recommend command ───────────────────────────────────────────
echo ""
echo -e "${BOLD}  Recommend Command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-scale.sh" recommend 2>&1) || true
assert_contains "recommend shows header" "$output" "Scaling Recommendations"
assert_contains "recommend shows thresholds" "$output" "Thresholds"

# ─── Test 14: Unknown command ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-scale.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits non-zero" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
