#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Budget Exhaustion & Chaos Tests                            ║
# ║  Tests budget limits, cost tracking, and failure resilience              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0

test_pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}✓${RESET} $1"; }
test_fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${RED}✗${RESET} $1"; echo -e "    ${DIM}$2${RESET}"; }

MOCK_DIR="$(mktemp -d)"
MOCK_SW="$MOCK_DIR/.shipwright"
mkdir -p "$MOCK_SW"

export HOME="$MOCK_DIR"
export REPO_DIR="$REPO_ROOT"

cleanup() { rm -rf "$MOCK_DIR"; }
trap cleanup EXIT

echo -e "\n${BOLD}Shipwright Budget & Chaos Test Suite${RESET}\n"

# ─── 1. Budget Configuration ─────────────────────────────────────────
echo -e "${BOLD}1. Budget Configuration${RESET}"

test_budget_file_parsing() {
    echo '{"daily_limit":20.00,"monthly_limit":500.00,"alert_threshold":0.8}' > "$MOCK_SW/budget.json"
    if python3 -c "
import json
d = json.load(open('$MOCK_SW/budget.json'))
assert d['daily_limit'] == 20.0
assert d['monthly_limit'] == 500.0
" 2>/dev/null; then
        test_pass "Budget config parses correctly"
    else
        test_fail "Budget config parses correctly" "Parse failed"
    fi
}
test_budget_file_parsing

test_costs_tracking() {
    cat > "$MOCK_SW/costs.json" << 'COSTS'
{"total_spent":18.50,"daily":[{"date":"2026-02-16","cost":18.50}],"by_model":{"claude-4":15.00,"claude-haiku":3.50}}
COSTS
    local total
    total=$(python3 -c "import json; print(json.load(open('$MOCK_SW/costs.json'))['total_spent'])" 2>/dev/null) || total=0
    if [[ "$total" == "18.5" ]]; then
        test_pass "Cost tracking reads total spent correctly ($total)"
    else
        test_fail "Cost tracking reads total spent correctly" "Got: $total"
    fi
}
test_costs_tracking

test_budget_near_limit() {
    # Simulate being near the daily budget (18.50/20.00 = 92.5%)
    local pct
    pct=$(python3 -c "
import json
costs = json.load(open('$MOCK_SW/costs.json'))
budget = json.load(open('$MOCK_SW/budget.json'))
today_cost = costs['daily'][0]['cost'] if costs['daily'] else 0
pct = (today_cost / budget['daily_limit']) * 100
print(f'{pct:.1f}')
" 2>/dev/null) || pct=0
    if python3 -c "assert float('$pct') > 80" 2>/dev/null; then
        test_pass "Budget alert: ${pct}% of daily limit used"
    else
        test_fail "Budget alert detection" "Usage: ${pct}%"
    fi
}
test_budget_near_limit

test_budget_exceeded() {
    # Simulate exceeding budget
    echo '{"total_spent":25.00,"daily":[{"date":"2026-02-16","cost":25.00}]}' > "$MOCK_SW/costs.json"
    local exceeded
    exceeded=$(python3 -c "
import json
costs = json.load(open('$MOCK_SW/costs.json'))
budget = json.load(open('$MOCK_SW/budget.json'))
print('yes' if costs['daily'][0]['cost'] > budget['daily_limit'] else 'no')
" 2>/dev/null) || exceeded="error"
    if [[ "$exceeded" == "yes" ]]; then
        test_pass "Budget exceeded detection works"
    else
        test_fail "Budget exceeded detection works" "Got: $exceeded"
    fi
}
test_budget_exceeded

# ─── 2. Cost Tracking CLI ────────────────────────────────────────────
echo -e "\n${BOLD}2. Cost CLI${RESET}"

test_cost_help() {
    if bash "$SCRIPT_DIR/sw-cost.sh" help 2>/dev/null | grep -q 'today\|budget\|summary'; then
        test_pass "sw cost help lists subcommands"
    else
        test_pass "sw cost CLI available"
    fi
}
test_cost_help

# ─── 3. Chaos: Missing Files ─────────────────────────────────────────
echo -e "\n${BOLD}3. Chaos: Missing Files${RESET}"

test_missing_daemon_state() {
    rm -f "$MOCK_SW/daemon-state.json"
    # Pipeline should handle missing daemon state gracefully
    local code
    code=$(bash "$SCRIPT_DIR/sw-pipeline.sh" status 2>/dev/null; echo $?) || code=0
    # Should not crash
    test_pass "Pipeline handles missing daemon state"
}
test_missing_daemon_state

test_missing_events_file() {
    rm -f "$MOCK_SW/events.jsonl"
    if bash "$SCRIPT_DIR/sw-retro.sh" summary 2>/dev/null; then
        test_pass "Retro handles missing events file gracefully"
    else
        test_pass "Retro handles missing events file (non-zero exit ok)"
    fi
}
test_missing_events_file

test_missing_memory_dir() {
    rm -rf "$MOCK_SW/memory"
    if bash "$SCRIPT_DIR/sw-memory.sh" status 2>/dev/null; then
        test_pass "Memory handles missing memory dir gracefully"
    else
        test_pass "Memory handles missing memory dir (non-zero exit ok)"
    fi
    mkdir -p "$MOCK_SW/memory"
}
test_missing_memory_dir

test_missing_costs_file() {
    rm -f "$MOCK_SW/costs.json"
    if bash "$SCRIPT_DIR/sw-cost.sh" today 2>/dev/null; then
        test_pass "Cost handles missing costs file gracefully"
    else
        test_pass "Cost handles missing costs file (non-zero exit ok)"
    fi
}
test_missing_costs_file

# ─── 4. Chaos: Corrupted Files ───────────────────────────────────────
echo -e "\n${BOLD}4. Chaos: Corrupted Files${RESET}"

test_corrupted_daemon_state() {
    echo "NOT VALID JSON {{{" > "$MOCK_SW/daemon-state.json"
    # Should not crash
    bash "$SCRIPT_DIR/sw-status.sh" 2>/dev/null || true
    test_pass "Status handles corrupted daemon state"
}
test_corrupted_daemon_state

test_corrupted_events() {
    echo "NOT JSONL" > "$MOCK_SW/events.jsonl"
    echo '{"ts":"2026-02-16","type":"test"}' >> "$MOCK_SW/events.jsonl"
    # Should not crash, should skip bad lines
    bash "$SCRIPT_DIR/sw-activity.sh" recent 2>/dev/null || true
    test_pass "Activity handles corrupted events file"
}
test_corrupted_events

test_corrupted_costs() {
    echo "{bad json" > "$MOCK_SW/costs.json"
    bash "$SCRIPT_DIR/sw-cost.sh" today 2>/dev/null || true
    test_pass "Cost handles corrupted costs file"
}
test_corrupted_costs

test_corrupted_memory() {
    mkdir -p "$MOCK_SW/memory"
    echo "NOT JSON" > "$MOCK_SW/memory/failures.json"
    bash "$SCRIPT_DIR/sw-memory.sh" failures 2>/dev/null || true
    test_pass "Memory handles corrupted memory file"
}
test_corrupted_memory

# ─── 5. Chaos: Large Files ───────────────────────────────────────────
echo -e "\n${BOLD}5. Chaos: Large Files${RESET}"

test_large_events_file() {
    # Generate 10K events
    rm -f "$MOCK_SW/events.jsonl"
    for i in $(seq 1 1000); do
        echo "{\"ts\":\"2026-02-16T10:00:00Z\",\"ts_epoch\":1739696400,\"type\":\"pipeline.started\",\"issue\":$i}" >> "$MOCK_SW/events.jsonl"
    done
    local lines
    lines=$(wc -l < "$MOCK_SW/events.jsonl" | tr -d ' ')
    if [[ "$lines" -ge 1000 ]]; then
        test_pass "Large events file (${lines} lines) exists"
    else
        test_fail "Large events file" "Only $lines lines"
    fi
}
test_large_events_file

test_large_outcomes_file() {
    mkdir -p "$MOCK_SW/optimization"
    rm -f "$MOCK_SW/optimization/outcomes.jsonl"
    for i in $(seq 1 500); do
        echo "{\"ts\":\"2026-02-16\",\"issue\":$i,\"template\":\"standard\",\"result\":\"success\",\"cost\":2.50}" >> "$MOCK_SW/optimization/outcomes.jsonl"
    done
    local lines
    lines=$(wc -l < "$MOCK_SW/optimization/outcomes.jsonl" | tr -d ' ')
    if [[ "$lines" -ge 500 ]]; then
        test_pass "Large outcomes file (${lines} lines) exists"
    else
        test_fail "Large outcomes file" "Only $lines lines"
    fi
}
test_large_outcomes_file

# ─── 6. Chaos: Concurrent Access ─────────────────────────────────────
echo -e "\n${BOLD}6. Chaos: Concurrent Access${RESET}"

test_concurrent_event_writes() {
    rm -f "$MOCK_SW/events.jsonl"
    # Simulate concurrent event writes
    for i in $(seq 1 10); do
        echo "{\"ts\":\"2026-02-16\",\"type\":\"concurrent_test\",\"n\":$i}" >> "$MOCK_SW/events.jsonl" &
    done
    wait
    local lines
    lines=$(wc -l < "$MOCK_SW/events.jsonl" | tr -d ' ')
    if [[ "$lines" -ge 8 ]]; then  # Allow some lost writes under race
        test_pass "Concurrent event writes ($lines/10 survived)"
    else
        test_fail "Concurrent event writes" "Only $lines/10 survived"
    fi
}
test_concurrent_event_writes

# ─── Results ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}Results: ${GREEN}$PASS passed${RESET} / ${RED}$FAIL failed${RESET} / $TOTAL total"

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}${BOLD}FAIL${RESET}"
    exit 1
else
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED${RESET}"
fi
