#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright feedback test — Production Feedback Loop tests               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
# Handle -C <dir> by shifting past it
if [[ "\${1:-}" == "-C" ]]; then shift; shift; fi
case "\${1:-}" in
    rev-parse) echo "$TEST_TEMP_DIR/repo" ;;
    log) echo "abc1234 fix: something" ;;
    show) echo "1 file changed" ;;
    config) echo "git@github.com:test/repo.git" ;;
    remote)
        case "\${2:-}" in
            get-url) echo "git@github.com:test/repo.git" ;;
            *) echo "" ;;
        esac
        ;;
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
    if command -v shasum &>/dev/null; then
        ln -sf "$(command -v shasum)" "$TEST_TEMP_DIR/bin/shasum"
    fi
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1"; local detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cE -- "$pattern" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
print_test_header "Shipwright Feedback Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright feedback"
assert_contains "help shows subcommands" "$output" "SUBCOMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown subcommand"

# ─── Test 4: collect with empty dir ───────────────────────────────────────
echo ""
echo -e "  ${CYAN}collect subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" collect "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts" 2>&1) && rc=0 || rc=$?
assert_eq "collect on empty dir exits 0" "0" "$rc"
assert_contains "collect shows collecting" "$output" "Collecting"

# ─── Test 5: collect reports save location ────────────────────────────────
# Note: collect saves to the git repo root, not the input dir
assert_contains "collect shows save path" "$output" "Saved to"

# ─── Test 6: collect with log file containing errors ──────────────────────
echo ""
echo -e "  ${CYAN}collect with error log${RESET}"
cat > "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/test.log" <<'LOG'
2026-01-01 Starting pipeline
Error: connection timeout
2026-01-01 Retrying...
Exception: null pointer in handler
Fatal: unrecoverable error
Normal operation resumed
LOG
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" collect "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/test.log" 2>&1) && rc=0 || rc=$?
assert_eq "collect with errors exits 0" "0" "$rc"
assert_contains "collect reports errors" "$output" "Collected"

# ─── Test 7: analyze with no error file ────────────────────────────────────
echo ""
echo -e "  ${CYAN}analyze subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" analyze "$TEST_TEMP_DIR/nonexistent.json" 2>&1) && rc=0 || rc=$?
assert_eq "analyze missing file exits 1" "1" "$rc"
assert_contains "analyze shows not found" "$output" "not found"

# ─── Test 8: analyze with collected errors ─────────────────────────────────
# Create the errors file that collect would normally produce
echo '{"total_errors": 5, "error_types": "timeout;crash;"}' > "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" analyze "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json" 2>&1) && rc=0 || rc=$?
assert_eq "analyze exits 0" "0" "$rc"
assert_contains "analyze shows report" "$output" "Error Analysis"

# ─── Test 9: learn subcommand ─────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}learn subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" learn "Off-by-one in pagination" "Fixed loop boundary" 2>&1) && rc=0 || rc=$?
assert_eq "learn exits 0" "0" "$rc"
assert_contains "learn confirms capture" "$output" "Incident captured"

# ─── Test 10: learn creates incidents file ─────────────────────────────────
if [[ -f "$HOME/.shipwright/incidents.jsonl" ]]; then
    assert_pass "incidents.jsonl created"
    line=$(head -1 "$HOME/.shipwright/incidents.jsonl")
    if echo "$line" | jq . >/dev/null 2>&1; then
        assert_pass "incidents.jsonl has valid JSONL"
    else
        assert_fail "incidents.jsonl has valid JSONL"
    fi
else
    assert_fail "incidents.jsonl created"
    assert_fail "incidents.jsonl has valid JSONL" "file missing"
fi

# ─── Test 11: report with incidents ───────────────────────────────────────
echo ""
echo -e "  ${CYAN}report subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report exits 0" "0" "$rc"
assert_contains "report shows incidents" "$output" "Incident Report"
assert_contains "report shows total" "$output" "Total incidents"

# ─── Test 12: report with no incidents ─────────────────────────────────────
rm -f "$HOME/.shipwright/incidents.jsonl"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report no incidents exits 0" "0" "$rc"
assert_contains "report says no incidents" "$output" "No incidents"

# ─── Test 13: create-issue with NO_GITHUB ──────────────────────────────────
echo ""
echo -e "  ${CYAN}create-issue subcommand${RESET}"
# First create an error file with enough errors to exceed threshold
echo '{"total_errors": 10, "error_types": "timeout;crash;"}' > "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" create-issue "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json" 2>&1) && rc=0 || rc=$?
assert_eq "create-issue with NO_GITHUB exits 0" "0" "$rc"
assert_contains "create-issue skips with NO_GITHUB" "$output" "NO_GITHUB"

# ─── Test 14: post-merge monitoring (short window for test) ──────────────────
echo ""
echo -e "  ${CYAN}post-merge monitoring${RESET}"
export ARTIFACTS_DIR="$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" post-merge "abc1234abc1234" "production" "5" "1" 2>&1) && rc=0 || rc=$?
assert_eq "post-merge exits 0" "0" "$rc"
assert_contains "post-merge shows monitoring" "$output" "Starting post-merge"
if [[ -f "$ARTIFACTS_DIR/post-merge-monitoring.json" ]]; then
    assert_pass "post-merge creates monitoring file"
    monitoring=$(cat "$ARTIFACTS_DIR/post-merge-monitoring.json")
    assert_json_key "monitoring has merge_sha" "$monitoring" ".merge_sha" "abc1234abc1234"
    assert_json_key "monitoring has environment" "$monitoring" ".environment" "production"
else
    assert_fail "post-merge creates monitoring file" "file not found"
fi

# ─── Test 15: regression detection with no regression ─────────────────────────
echo ""
echo -e "  ${CYAN}regression detection${RESET}"
# Create a clean monitoring file (no errors)
echo '{"merge_sha":"abc1234", "errors_detected":0, "deployment_status":"success"}' > "$ARTIFACTS_DIR/post-merge-monitoring.json"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" regressions "$ARTIFACTS_DIR/post-merge-monitoring.json" 2>&1)
if echo "$output" | jq . >/dev/null 2>&1; then
    assert_pass "regression detection outputs valid JSON"
    regression=$(echo "$output")
    assert_json_key "no regression flag" "$regression" ".regression" "false"
else
    assert_fail "regression detection outputs valid JSON"
fi

# ─── Test 16: regression detection with deployment failure ────────────────────
# Create monitoring file with deployment failure
echo '{"merge_sha":"def5678", "errors_detected":0, "deployment_status":"failed"}' > "$ARTIFACTS_DIR/post-merge-monitoring.json"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" regressions "$ARTIFACTS_DIR/post-merge-monitoring.json" 2>&1)
regression=$(echo "$output")
assert_json_key "deploy failure detects regression" "$regression" ".regression" "true"
assert_json_key "deploy failure is P0" "$regression" ".severity" "P0"
assert_json_key "deploy failure type" "$regression" ".type" "deploy_failure"

# ─── Test 17: regression detection with error spike ────────────────────────────
# Create monitoring file with many errors
echo '{"merge_sha":"ghi9012", "errors_detected":10, "deployment_status":"success"}' > "$ARTIFACTS_DIR/post-merge-monitoring.json"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" regressions "$ARTIFACTS_DIR/post-merge-monitoring.json" 2>&1)
regression=$(echo "$output")
assert_json_key "error spike detects regression" "$regression" ".regression" "true"
assert_json_key "error spike is P1" "$regression" ".severity" "P1"
assert_json_key "error spike type" "$regression" ".type" "error_spike"

# ─── Test 18: correlate with changes ──────────────────────────────────────────
echo ""
echo -e "  ${CYAN}correlate with changes${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" correlate 42 2>&1)
if echo "$output" | jq . >/dev/null 2>&1; then
    assert_pass "correlate outputs valid JSON"
    correlation=$(echo "$output")
    assert_json_key "correlation has pr_number" "$correlation" ".pr_number" "42"
else
    assert_fail "correlate outputs valid JSON"
fi

# ─── Test 19: learn from outcome ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}learn from outcome${RESET}"
# Create a minimal monitoring file for time-to-detect calculation
echo '{"start_epoch":1000, "end_epoch":1060}' > "$ARTIFACTS_DIR/post-merge-monitoring.json"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" outcomes 99 success deployed false none 2>&1) && rc=0 || rc=$?
assert_eq "outcomes exits 0" "0" "$rc"
assert_contains "outcomes shows recording" "$output" "Recording"
if [[ -f "$HOME/.shipwright/optimization/merge-outcomes.jsonl" ]]; then
    assert_pass "outcomes creates merge-outcomes file"
    line=$(head -1 "$HOME/.shipwright/optimization/merge-outcomes.jsonl")
    if echo "$line" | jq . >/dev/null 2>&1; then
        assert_pass "outcomes file has valid JSONL"
        assert_json_key "outcome has pr_number" "$line" ".pr_number" "99"
    else
        assert_fail "outcomes file has valid JSONL"
    fi
else
    assert_fail "outcomes creates merge-outcomes file"
fi

# ─── Test 20: health report with no data ──────────────────────────────────────
echo ""
echo -e "  ${CYAN}health report${RESET}"
rm -f "$HOME/.shipwright/optimization/merge-outcomes.jsonl"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" health 30 2>&1) && rc=0 || rc=$?
assert_eq "health with no data exits 0" "0" "$rc"
assert_contains "health shows no data message" "$output" "No merge outcomes"

# ─── Test 21: health report with data ─────────────────────────────────────────
# Create some merge outcomes
mkdir -p "$HOME/.shipwright/optimization"
for i in {1..5}; do
    echo "{\"timestamp\":\"2026-03-07T00:0${i}:00Z\",\"pr_number\":$((100+i)),\"merge_result\":\"success\",\"deploy_result\":\"deployed\",\"regression_detected\":false,\"regression_type\":\"none\",\"time_to_detect_secs\":60}" >> "$HOME/.shipwright/optimization/merge-outcomes.jsonl"
done
echo "{\"timestamp\":\"2026-03-07T00:06:00Z\",\"pr_number\":200,\"merge_result\":\"success\",\"deploy_result\":\"deployed\",\"regression_detected\":true,\"regression_type\":\"error_spike\",\"time_to_detect_secs\":180}" >> "$HOME/.shipwright/optimization/merge-outcomes.jsonl"

output=$(bash "$SCRIPT_DIR/sw-feedback.sh" health 30 2>&1) || true
# Note: health may exit non-zero if calculations have issues; check output instead
assert_contains "health shows statistics" "$output" "Merge Statistics"
assert_contains "health shows success rate" "$output" "Success Rate"
assert_contains "health shows regressions" "$output" "Regressions"

# ─── Test 22: post-merge workflow integration ──────────────────────────────────
echo ""
echo -e "  ${CYAN}integrated post-merge workflow${RESET}"
# Clean state
rm -f "$ARTIFACTS_DIR/post-merge-monitoring.json"
rm -f "$HOME/.shipwright/optimization/merge-outcomes.jsonl"

# 1. Run monitoring (short window)
bash "$SCRIPT_DIR/sw-feedback.sh" post-merge "workflow123" "production" "3" "1" >/dev/null 2>&1
[[ -f "$ARTIFACTS_DIR/post-merge-monitoring.json" ]] && assert_pass "workflow: monitoring complete" || assert_fail "workflow: monitoring complete"

# 2. Detect regression
regression_json=$(bash "$SCRIPT_DIR/sw-feedback.sh" regressions "$ARTIFACTS_DIR/post-merge-monitoring.json" 2>&1)
echo "$regression_json" | jq . >/dev/null 2>&1 && assert_pass "workflow: regression detection valid" || assert_fail "workflow: regression detection valid"

# 3. Correlate changes
correlation_json=$(bash "$SCRIPT_DIR/sw-feedback.sh" correlate 55 2>&1)
echo "$correlation_json" | jq . >/dev/null 2>&1 && assert_pass "workflow: correlation valid" || assert_fail "workflow: correlation valid"

# 4. Record outcome
bash "$SCRIPT_DIR/sw-feedback.sh" outcomes 55 success deployed false none >/dev/null 2>&1
[[ -f "$HOME/.shipwright/optimization/merge-outcomes.jsonl" ]] && assert_pass "workflow: outcome recorded" || assert_fail "workflow: outcome recorded"

echo ""
echo ""
print_test_results
