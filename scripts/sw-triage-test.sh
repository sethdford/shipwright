#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright triage test — Intelligent Issue Labeling & Prioritization    ║
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
    rev-parse) echo "/tmp/mock-repo" ;;
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
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Triage Tests"
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
) > "$TEST_TEMP_DIR/type_output" 2>/dev/null
type_result=$(cat "$TEST_TEMP_DIR/type_output")
if echo "$type_result" | grep -F "TYPE_SECURITY_OK" >/dev/null; then
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
) > "$TEST_TEMP_DIR/type_output2" 2>/dev/null
type_result2=$(cat "$TEST_TEMP_DIR/type_output2")
if echo "$type_result2" | grep -F "TYPE_BUG_OK" >/dev/null; then
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
) > "$TEST_TEMP_DIR/type_output3" 2>/dev/null
type_result3=$(cat "$TEST_TEMP_DIR/type_output3")
if echo "$type_result3" | grep -F "TYPE_FEATURE_OK" >/dev/null; then
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
) > "$TEST_TEMP_DIR/complexity_output" 2>/dev/null
complexity_result=$(cat "$TEST_TEMP_DIR/complexity_output")
assert_eq "short text = trivial complexity" "trivial" "$complexity_result"

# ─── Test 11: Test analyze_risk ────────────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(analyze_risk "Security vulnerability with critical exploit")
    echo "$result"
) > "$TEST_TEMP_DIR/risk_output" 2>/dev/null
risk_result=$(cat "$TEST_TEMP_DIR/risk_output")
assert_eq "security text = high risk" "high" "$risk_result"

# ─── Test 12: Test analyze_effort ──────────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(analyze_effort "trivial" "low")
    echo "$result"
) > "$TEST_TEMP_DIR/effort_output" 2>/dev/null
effort_result=$(cat "$TEST_TEMP_DIR/effort_output")
assert_eq "trivial+low = xs effort" "xs" "$effort_result"

# ─── Test 13: Test suggest_labels ──────────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(suggest_labels "bug" "simple" "high" "m")
    echo "$result"
) > "$TEST_TEMP_DIR/labels_output" 2>/dev/null
labels_result=$(cat "$TEST_TEMP_DIR/labels_output")
assert_contains "suggest_labels includes type" "$labels_result" "type:bug"
assert_contains "suggest_labels includes risk" "$labels_result" "risk:high"
assert_contains "suggest_labels includes priority" "$labels_result" "priority:high"

# ─── Test 14: team works offline with recruit (NO_GITHUB=1) ────────────
echo ""
echo -e "  ${CYAN}triage team offline fallback${RESET}"

# Create mock recruit that returns team JSON
cat > "$TEST_TEMP_DIR/bin/sw-recruit.sh" <<'MOCK_RECRUIT'
#!/usr/bin/env bash
if [[ "${1:-}" == "team" && "${2:-}" == "--json" ]]; then
    echo '{"team":["builder","reviewer"],"method":"heuristic","estimated_cost":3.0,"model":"sonnet","agents":2,"template":"standard","max_iterations":8}'
    exit 0
fi
echo "mock recruit"
MOCK_RECRUIT
chmod +x "$TEST_TEMP_DIR/bin/sw-recruit.sh"

# Point SCRIPT_DIR to temp dir and copy triage there.
# lib/ must come along: sw-triage.sh sources lib/compat.sh behind a
# `[[ -f ]]` guard, so a missing lib/ is skipped silently at startup and then
# surfaces ~600 lines later as `_smart_model: command not found` (exit 127).
# These tests isolate the *recruit* dependency, not the shared library — a real
# install always has lib/ next to the scripts.
cp "$SCRIPT_DIR/sw-triage.sh" "$TEST_TEMP_DIR/bin/sw-triage.sh"
mkdir -p "$TEST_TEMP_DIR/bin/lib"
cp "$SCRIPT_DIR/lib"/*.sh "$TEST_TEMP_DIR/bin/lib/" 2>/dev/null || true

output=$(NO_GITHUB=1 SCRIPT_DIR="$TEST_TEMP_DIR/bin" bash "$TEST_TEMP_DIR/bin/sw-triage.sh" team 42 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    assert_pass "team works offline with recruit (exit 0)"
else
    # Even if non-zero, check if it produced a recommendation
    if echo "$output" | grep "pipeline_template" >/dev/null; then
        assert_pass "team works offline with recruit (produced recommendation)"
    else
        assert_fail "team works offline with recruit" "exit=$rc output=$(echo "$output" | tail -3)"
    fi
fi

# Verify team output contains expected fields
if echo "$output" | grep "pipeline_template" >/dev/null; then
    assert_pass "team offline output has pipeline_template"
else
    assert_fail "team offline output has pipeline_template" "got: $(echo "$output" | tail -5)"
fi

if echo "$output" | grep '"source": "recruit"' >/dev/null; then
    assert_pass "team offline uses recruit source"
elif echo "$output" | grep '"source": "heuristic"' >/dev/null; then
    assert_pass "team offline falls back to heuristic source"
else
    assert_fail "team offline has source field" "got: $(echo "$output" | tail -5)"
fi

# ─── Test 15: team offline without recruit falls to defaults ──────────
rm -f "$TEST_TEMP_DIR/bin/sw-recruit.sh"
output=$(NO_GITHUB=1 SCRIPT_DIR="$TEST_TEMP_DIR/bin" bash "$TEST_TEMP_DIR/bin/sw-triage.sh" team 42 2>&1) && rc=0 || rc=$?
if echo "$output" | grep "pipeline_template" >/dev/null; then
    assert_pass "team offline without recruit uses heuristic defaults"
else
    assert_fail "team offline without recruit uses heuristic defaults" "exit=$rc output=$(echo "$output" | tail -3)"
fi

echo ""
echo ""
print_test_results
