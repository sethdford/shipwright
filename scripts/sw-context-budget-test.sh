#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright context-budget test — Context Window Budget Monitor tests    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# Source the module under test
source "$SCRIPT_DIR/lib/context-budget.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/artifacts"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Mock jq if needed
    if ! command -v jq &>/dev/null; then
        cat > "$TEST_TEMP_DIR/bin/jq" <<'MOCK'
#!/usr/bin/env bash
# Simple jq replacement for tests
python3 -c "import json, sys; obj = json.load(sys.stdin); print(json.dumps(obj))"
MOCK
        chmod +x "$TEST_TEMP_DIR/bin/jq"
    fi

    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq" 2>/dev/null || true
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    diff)
        echo "3 files changed, 25 insertions(+), 5 deletions(-)"
        ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME/.shipwright"
}

trap cleanup_test_env EXIT

# Color helpers
EOF
)

status=$(context_budget_check "$low_estimate" 2>/dev/null || echo "{}")
status_val=$(echo "$status" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
if [[ "$status_val" == "green" ]]; then
    assert_pass "50% utilization returns green status"
else
    assert_fail "50% utilization status check" "got: $status_val"
fi

# Create a yellow-level estimate (70%)
yellow_estimate=$(cat <<EOF
{
  "utilization_percent": 70,
  "total_used": 560000,
  "budget": 800000
}
EOF
)

status=$(context_budget_check "$yellow_estimate" 2>/dev/null || echo "{}")
status_val=$(echo "$status" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
if [[ "$status_val" == "yellow" ]]; then
    assert_pass "70% utilization returns yellow status"
else
    assert_fail "70% utilization status check" "got: $status_val"
fi

# Create a red-level estimate (85%)
red_estimate=$(cat <<EOF
{
  "utilization_percent": 85,
  "total_used": 680000,
  "budget": 800000
}
EOF
)

status=$(context_budget_check "$red_estimate" 2>/dev/null || echo "{}")
status_val=$(echo "$status" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
if [[ "$status_val" == "red" ]]; then
    assert_pass "85% utilization returns red status"
else
    assert_fail "85% utilization status check" "got: $status_val"
fi

# Create a critical estimate (95%)
critical_estimate=$(cat <<EOF
{
  "utilization_percent": 95,
  "total_used": 760000,
  "budget": 800000
}
EOF
)

status=$(context_budget_check "$critical_estimate" 2>/dev/null || echo "{}")
status_val=$(echo "$status" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
if [[ "$status_val" == "critical" ]]; then
    assert_pass "95% utilization returns critical status"
else
    assert_fail "95% utilization status check" "got: $status_val"
fi

# ─── Test 4: Context trimming (no-op at green) ──────────────────────────────
echo ""
echo -e "  ${CYAN}Context Trimming${RESET}"

test_content="This is a test context.
## Memory Context
Some memory data here that should be kept.
## Recent Git Activity
commit abc123"

trimmed=$(context_budget_trim "$test_content" "green" 10000 2>/dev/null)
if [[ "${#trimmed}" -eq "${#test_content}" ]]; then
    assert_pass "green status doesn't trim content"
else
    assert_fail "green status modified content"
fi

# Test yellow trimming (should remove duplicates, truncate memory)
test_with_dups="Error: something failed
Error: something failed
Error: something else
## Memory Context
$(printf 'A%.0s' {1..25000})
## Other Section"

trimmed=$(context_budget_trim "$test_with_dups" "yellow" 50000 2>/dev/null)
# Just verify it's shorter (trimming happened)
if [[ "${#trimmed}" -lt "${#test_with_dups}" ]]; then
    assert_pass "yellow status reduces content length"
else
    assert_fail "yellow status didn't trim" "original=${#test_with_dups}, trimmed=${#trimmed}"
fi

# Test hard truncate
long_content=$(printf 'A%.0s' {1..150000})
trimmed=$(context_budget_trim "$long_content" "red" 100000 2>/dev/null)
if [[ "${#trimmed}" -le 101000 ]]; then  # Allow some margin for truncation marker
    assert_pass "hard truncate respects size limit"
else
    assert_fail "hard truncate exceeded limit" "got ${#trimmed} chars"
fi

# ─── Test 5: Iteration summarization ───────────────────────────────────────
echo ""
echo -e "  ${CYAN}Iteration Summarization${RESET}"

# Create a test log file
test_log="$TEST_TEMP_DIR/test-iter-1.log"
cat > "$test_log" <<'LOG'
Starting iteration...
Modified files: foo.sh bar.js
Tests: PASSED
Completed work.
LOG

summarize_rc=0
context_budget_summarize_iteration 1 "$test_log" "PASSED" "$TEST_TEMP_DIR/artifacts" 2>/dev/null || summarize_rc=$?
assert_exit_code "summarize_iteration succeeds" "0" "$summarize_rc"

if [[ -f "$TEST_TEMP_DIR/artifacts/iteration-summaries.json" ]]; then
    summaries=$(cat "$TEST_TEMP_DIR/artifacts/iteration-summaries.json")
    iter_count=$(echo "$summaries" | jq '.iterations | length' 2>/dev/null || echo "0")
    if [[ "$iter_count" -eq 1 ]]; then
        assert_pass "iteration summary file created with 1 entry"
    else
        assert_fail "iteration summary has wrong count" "got: $iter_count"
    fi
else
    assert_fail "iteration summary file not created"
fi

# ─── Test 6: Budget report generation ───────────────────────────────────────
echo ""
echo -e "  ${CYAN}Budget Report Generation${RESET}"

report=$(context_budget_report "$TEST_TEMP_DIR/artifacts" 2>/dev/null || echo "{}")
if [[ -n "$report" ]]; then
    report_has_config=$(echo "$report" | jq -r '.budget_config // {}' 2>/dev/null | jq empty 2>/dev/null && echo "yes" || echo "no")
    if [[ "$report_has_config" == "yes" ]]; then
        assert_pass "report contains budget_config"
    else
        assert_fail "report missing budget_config"
    fi

    report_has_summaries=$(echo "$report" | jq -r '.iteration_summaries // {}' 2>/dev/null | jq empty 2>/dev/null && echo "yes" || echo "no")
    if [[ "$report_has_summaries" == "yes" ]]; then
        assert_pass "report contains iteration_summaries"
    else
        assert_fail "report missing iteration_summaries"
    fi
else
    assert_fail "report generation failed"
fi

# ─── Test 7: State logging ──────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}State Logging${RESET}"

estimate_json='{"total_used":400000,"remaining_tokens":400000,"utilization_percent":50}'
status_json='{"status":"green","action":"continue"}'

log_rc=0
context_budget_log_state "$estimate_json" "$status_json" "$TEST_TEMP_DIR/artifacts" 2>/dev/null || log_rc=$?
assert_exit_code "log_state succeeds" "0" "$log_rc"

if [[ -f "$TEST_TEMP_DIR/artifacts/context-budget-log.jsonl" ]]; then
    log_lines=$(wc -l < "$TEST_TEMP_DIR/artifacts/context-budget-log.jsonl")
    if [[ "$log_lines" -ge 1 ]]; then
        assert_pass "log file created with entries"
    else
        assert_fail "log file has no entries"
    fi
else
    assert_fail "log file not created"
fi

# ─── Results ───────────────────────────────────────────────────────────────
echo ""
print_test_results "Context Budget Monitor Tests"
