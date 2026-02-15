#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright model-router test — Intelligent model routing & optimization ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-model-router-test.XXXXXX")
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
echo -e "${CYAN}${BOLD}  Shipwright Model Router Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows route" "$output" "route"
assert_contains "help shows escalate" "$output" "escalate"
assert_contains "help shows config" "$output" "config"

# ─── Test 2: Route model for intake (haiku stage) ────────────────────────
echo ""
echo -e "${BOLD}  Route Model${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route intake 50 2>&1)
assert_eq "route intake at 50 = haiku" "haiku" "$output"

# ─── Test 3: Route model for build (opus stage) ──────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route build 50 2>&1)
assert_eq "route build at 50 = opus" "opus" "$output"

# ─── Test 4: Route model for test (sonnet stage) ─────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route test 50 2>&1)
assert_eq "route test at 50 = sonnet" "sonnet" "$output"

# ─── Test 5: Route model with low complexity override ─────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route build 10 2>&1)
assert_eq "route build at 10 (low) = sonnet" "sonnet" "$output"

# ─── Test 6: Route model with high complexity override ────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route intake 90 2>&1)
assert_eq "route intake at 90 (high) = opus" "opus" "$output"

# ─── Test 7: Route model for unknown stage ────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route custom_stage 50 2>&1)
assert_eq "route unknown stage at 50 = sonnet" "sonnet" "$output"

# ─── Test 8: Escalate model ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Escalate Model${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate haiku 2>&1)
assert_eq "escalate haiku -> sonnet" "sonnet" "$output"

output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate sonnet 2>&1)
assert_eq "escalate sonnet -> opus" "opus" "$output"

output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate opus 2>&1)
assert_eq "escalate opus -> opus (ceiling)" "opus" "$output"

# ─── Test 9: Escalate unknown model ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate unknown 2>&1) && rc=0 || rc=$?
assert_eq "escalate unknown exits non-zero" "1" "$rc"

# ─── Test 10: Config show creates default ─────────────────────────────────
echo ""
echo -e "${BOLD}  Config${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config show 2>&1) || true
assert_contains "config show displays JSON" "$output" "default_routing"
config_file="$HOME/.shipwright/model-routing.json"
if [[ -f "$config_file" ]]; then
    assert_pass "config creates default file"
else
    assert_fail "config creates default file" "file not found"
fi

# ─── Test 11: Config set ─────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config set cost_aware_mode true 2>&1) || true
assert_contains "config set confirms update" "$output" "Updated"
value=$(jq -r '.cost_aware_mode' "$config_file")
assert_eq "config set persists value" "true" "$value"

# ─── Test 12: Estimate cost ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Estimate${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" estimate standard 50 2>&1) || true
assert_contains "estimate shows stages" "$output" "intake"
assert_contains "estimate shows total" "$output" "Total"

# ─── Test 13: Report with no data ────────────────────────────────────────
echo ""
echo -e "${BOLD}  Report${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" report 2>&1) || true
assert_contains "report with no data warns" "$output" "No usage data"

# ─── Test 14: Unknown subcommand ─────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown subcommand exits non-zero" "1" "$rc"
assert_contains "unknown subcommand shows error" "$output" "Unknown subcommand"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
