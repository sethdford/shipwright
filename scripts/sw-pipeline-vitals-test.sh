#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright vitals test — Validate pipeline health scoring               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-vitals-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/progress"
    mkdir -p "$TEMP_DIR/home/.shipwright/optimization"
    mkdir -p "$TEMP_DIR/home/.claude/pipeline-artifacts"
    mkdir -p "$TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Create empty state files
    echo '{"entries":[],"summary":{}}' > "$TEMP_DIR/home/.shipwright/costs.json"
    echo '{"daily_budget_usd":0,"enabled":false}' > "$TEMP_DIR/home/.shipwright/budget.json"

    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() {
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Pipeline Vitals Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: --help flag ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-pipeline-vitals.sh" --help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "--help exits 0"
else
    assert_fail "--help exits 0" "exit code: $rc"
fi
assert_contains "--help shows USAGE" "$output" "USAGE"
assert_contains "--help shows OPTIONS" "$output" "OPTIONS"
assert_contains "--help mentions --json" "$output" "--json"
assert_contains "--help mentions --score" "$output" "--score"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
if grep -q '^VERSION=' "$SCRIPT_DIR/sw-pipeline-vitals.sh"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: --json outputs valid JSON ──────────────────────────────────────
echo ""
echo -e "${DIM}  json output${RESET}"

output=$(bash "$SCRIPT_DIR/sw-pipeline-vitals.sh" --json 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "--json exits 0"
else
    assert_fail "--json exits 0" "exit code: $rc"
fi

# The whole output should be valid JSON
if printf '%s\n' "$output" | jq . >/dev/null 2>&1; then
    assert_pass "--json outputs valid JSON"
else
    assert_fail "--json outputs valid JSON" "output: $output"
fi

# ─── Test 4: --score outputs a number ───────────────────────────────────────
echo ""
echo -e "${DIM}  score output${RESET}"

output=$(bash "$SCRIPT_DIR/sw-pipeline-vitals.sh" --score 2>&1) && rc=0 || rc=$?
# The score should be a number 0-100
score_val=$(printf '%s\n' "$output" | grep -oE '^[0-9]+$' | head -1)
if [[ -n "$score_val" && "$score_val" -ge 0 && "$score_val" -le 100 ]]; then
    assert_pass "--score outputs valid number (${score_val})"
else
    assert_fail "--score outputs valid number" "output: $output"
fi

# ─── Test 5: script safety ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-pipeline-vitals.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-pipeline-vitals.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ─── Test 6: signal weights defined ─────────────────────────────────────────
echo ""
echo -e "${DIM}  internals${RESET}"

if grep -q 'WEIGHT_MOMENTUM' "$SCRIPT_DIR/sw-pipeline-vitals.sh"; then
    assert_pass "WEIGHT_MOMENTUM defined"
else
    assert_fail "WEIGHT_MOMENTUM defined"
fi

if grep -q 'WEIGHT_CONVERGENCE' "$SCRIPT_DIR/sw-pipeline-vitals.sh"; then
    assert_pass "WEIGHT_CONVERGENCE defined"
else
    assert_fail "WEIGHT_CONVERGENCE defined"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
else
    echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
    for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done
fi
echo ""
exit "$FAIL"
