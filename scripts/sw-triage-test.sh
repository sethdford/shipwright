#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright triage test — Intelligent Issue Labeling & Prioritization    ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-triage-test.XXXXXX")
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
echo -e "${CYAN}${BOLD}  Shipwright Triage Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-triage.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright triage"
assert_contains "help shows subcommands" "$output" "SUBCOMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-triage.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-triage.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown subcommand exits 1" "1" "$rc"
assert_contains "unknown shows error" "$output" "Unknown subcommand"

# ─── Test 4: analyze requires GitHub (exits with NO_GITHUB=1) ─────────────
echo ""
echo -e "  ${CYAN}GitHub guard${RESET}"
output=$(NO_GITHUB=1 bash "$SCRIPT_DIR/sw-triage.sh" analyze 42 2>&1) && rc=0 || rc=$?
assert_eq "analyze exits 1 with NO_GITHUB=1" "1" "$rc"
assert_contains "analyze shows disabled" "$output" "disabled"

# ─── Test 5: analyze missing args ─────────────────────────────────────────
output=$(NO_GITHUB=1 bash "$SCRIPT_DIR/sw-triage.sh" analyze 2>&1) && rc=0 || rc=$?
assert_eq "analyze without args exits 1" "1" "$rc"

# ─── Test 6: team missing args ────────────────────────────────────────────
output=$(NO_GITHUB=1 bash "$SCRIPT_DIR/sw-triage.sh" team 2>&1) && rc=0 || rc=$?
assert_eq "team without args exits 1" "1" "$rc"

# ─── Test 7: Test internal analyze_type function ──────────────────────────
echo ""
echo -e "  ${CYAN}internal analysis functions${RESET}"
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"

    result=$(analyze_type "Fix the security vulnerability in login")
    if [[ "$result" == "security" ]]; then
        echo "TYPE_SECURITY_OK"
    else
        echo "TYPE_SECURITY_FAIL:$result"
    fi
) > "$TEMP_DIR/type_output" 2>/dev/null
type_result=$(cat "$TEMP_DIR/type_output")
if echo "$type_result" | grep -qF "TYPE_SECURITY_OK"; then
    assert_pass "analyze_type detects security"
else
    assert_fail "analyze_type detects security" "got: $type_result"
fi

# ─── Test 8: Test analyze_type for bugs ───────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(analyze_type "Bug in the crash handler causing errors")
    if [[ "$result" == "bug" ]]; then
        echo "TYPE_BUG_OK"
    else
        echo "TYPE_BUG_FAIL:$result"
    fi
) > "$TEMP_DIR/type_output2" 2>/dev/null
type_result2=$(cat "$TEMP_DIR/type_output2")
if echo "$type_result2" | grep -qF "TYPE_BUG_OK"; then
    assert_pass "analyze_type detects bug"
else
    assert_fail "analyze_type detects bug" "got: $type_result2"
fi

# ─── Test 9: Test analyze_type for feature ────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(analyze_type "Add new payment integration")
    if [[ "$result" == "feature" ]]; then
        echo "TYPE_FEATURE_OK"
    else
        echo "TYPE_FEATURE_FAIL:$result"
    fi
) > "$TEMP_DIR/type_output3" 2>/dev/null
type_result3=$(cat "$TEMP_DIR/type_output3")
if echo "$type_result3" | grep -qF "TYPE_FEATURE_OK"; then
    assert_pass "analyze_type detects feature"
else
    assert_fail "analyze_type detects feature" "got: $type_result3"
fi

# ─── Test 10: Test analyze_complexity ──────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    # Simple short text
    result=$(analyze_complexity "Fix a typo")
    echo "$result"
) > "$TEMP_DIR/complexity_output" 2>/dev/null
complexity_result=$(cat "$TEMP_DIR/complexity_output")
assert_eq "short text = trivial complexity" "trivial" "$complexity_result"

# ─── Test 11: Test analyze_risk ────────────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(analyze_risk "Security vulnerability with critical exploit")
    echo "$result"
) > "$TEMP_DIR/risk_output" 2>/dev/null
risk_result=$(cat "$TEMP_DIR/risk_output")
assert_eq "security text = high risk" "high" "$risk_result"

# ─── Test 12: Test analyze_effort ──────────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(analyze_effort "trivial" "low")
    echo "$result"
) > "$TEMP_DIR/effort_output" 2>/dev/null
effort_result=$(cat "$TEMP_DIR/effort_output")
assert_eq "trivial+low = xs effort" "xs" "$effort_result"

# ─── Test 13: Test suggest_labels ──────────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(suggest_labels "bug" "simple" "high" "m")
    echo "$result"
) > "$TEMP_DIR/labels_output" 2>/dev/null
labels_result=$(cat "$TEMP_DIR/labels_output")
assert_contains "suggest_labels includes type" "$labels_result" "type:bug"
assert_contains "suggest_labels includes risk" "$labels_result" "risk:high"
assert_contains "suggest_labels includes priority" "$labels_result" "priority:high"

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"; else echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"; for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done; fi
echo ""
exit "$FAIL"
