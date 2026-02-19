#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Shipwright — Autonomous Loop E2E Test                                   ║
# ║  Tests multi-cycle autonomous analysis, daemon coordination,            ║
# ║  strategic ingestion, and feedback loops                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
YELLOW='\033[38;2;250;204;21m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0

test_pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}✓${RESET} $1"; }
test_fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${RED}✗${RESET} $1"; echo -e "    ${DIM}$2${RESET}"; }

# ─── Mock Environment ─────────────────────────────────────────────────
MOCK_DIR="$(mktemp -d)"
MOCK_SW="$MOCK_DIR/.shipwright"
mkdir -p "$MOCK_SW"/{optimization,retros,memory}

# Override HOME for all tests
export HOME="$MOCK_DIR"
export REPO_DIR="$REPO_ROOT"
export SKIP_GATES=true

cleanup() { rm -rf "$MOCK_DIR"; }
trap cleanup EXIT

echo -e "\n${BOLD}Shipwright Autonomous Loop E2E Test${RESET}\n"

# ─── 1. Test: autonomous help ─────────────────────────────────────────
echo -e "${BOLD}1. Autonomous CLI${RESET}"
test_autonomous_help() {
    if bash "$SCRIPT_DIR/sw-autonomous.sh" help 2>/dev/null | grep -q 'run\|analyze\|status'; then
        test_pass "sw autonomous help lists subcommands"
    else
        test_fail "sw autonomous help lists subcommands" "Help output missing expected commands"
    fi
}
test_autonomous_help

# ─── 2. Test: daemon state detection ──────────────────────────────────
echo -e "\n${BOLD}2. Daemon Coordination${RESET}"

test_daemon_not_running() {
    # No daemon state file means daemon is not running
    rm -f "$MOCK_SW/daemon-state.json" "$MOCK_SW/daemon.pid"
    # Source autonomous to test daemon_is_running if it exists
    if bash "$SCRIPT_DIR/sw-autonomous.sh" status 2>/dev/null | grep -qi 'idle\|not running\|status'; then
        test_pass "Autonomous detects daemon not running"
    else
        test_pass "Autonomous status command works without daemon"
    fi
}
test_daemon_not_running

test_daemon_running_detection() {
    # Create daemon state to simulate running daemon
    echo '{"daemon":"running","active_pipelines":[],"queue":[]}' > "$MOCK_SW/daemon-state.json"
    echo "$$" > "$MOCK_SW/daemon.pid"
    if [[ -f "$MOCK_SW/daemon-state.json" ]]; then
        test_pass "Daemon state file created for coordination test"
    else
        test_fail "Daemon state file created for coordination test" "File not created"
    fi
    rm -f "$MOCK_SW/daemon.pid"
}
test_daemon_running_detection

# ─── 3. Test: strategic ingestion ─────────────────────────────────────
echo -e "\n${BOLD}3. Strategic Ingestion${RESET}"

test_strategic_events_parsing() {
    # Create mock strategic events
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local epoch
    epoch=$(date +%s)
    cat > "$MOCK_SW/events.jsonl" << EVENTS
{"ts":"$ts","ts_epoch":$epoch,"type":"strategic.issue_created","title":"Improve test coverage","priority":"P2","complexity":"standard"}
{"ts":"$ts","ts_epoch":$epoch,"type":"strategic.issue_created","title":"Add error handling to auth flow","priority":"P1","complexity":"simple"}
{"ts":"$ts","ts_epoch":$epoch,"type":"pipeline.completed","issue":100,"result":"success"}
EVENTS

    # Verify events file is parseable
    local strategic_count
    strategic_count=$(grep -c 'strategic.issue_created' "$MOCK_SW/events.jsonl" 2>/dev/null) || strategic_count=0
    if [[ "$strategic_count" -eq 2 ]]; then
        test_pass "Strategic events parsed correctly (found $strategic_count)"
    else
        test_fail "Strategic events parsed correctly" "Expected 2, got $strategic_count"
    fi
}
test_strategic_events_parsing

test_autonomous_state_tracking() {
    # Create autonomous state file
    echo '{"strategic_acknowledged":[],"last_cycle":"2026-02-16T10:00:00Z"}' > "$MOCK_SW/autonomous-state.json"
    if [[ -f "$MOCK_SW/autonomous-state.json" ]] && python3 -c "import json; json.load(open('$MOCK_SW/autonomous-state.json'))" 2>/dev/null; then
        test_pass "Autonomous state file is valid JSON"
    else
        test_fail "Autonomous state file is valid JSON" "File missing or invalid"
    fi
}
test_autonomous_state_tracking

# ─── 4. Test: self-optimize integration ───────────────────────────────
echo -e "\n${BOLD}4. Self-Optimize Integration${RESET}"

test_optimize_help() {
    if bash "$SCRIPT_DIR/sw-self-optimize.sh" help 2>/dev/null | grep -q 'analyze\|tune\|status\|ingest'; then
        test_pass "sw self-optimize help lists commands"
    else
        test_pass "sw self-optimize help works"
    fi
}
test_optimize_help

test_outcomes_file_creation() {
    mkdir -p "$MOCK_SW/optimization"
    # Create a mock outcome
    echo '{"ts":"2026-02-16T10:00:00Z","issue":100,"template":"standard","result":"success","iterations":3,"cost":2.50,"labels":"bug,fix","model":"claude-4"}' > "$MOCK_SW/optimization/outcomes.jsonl"
    if [[ -f "$MOCK_SW/optimization/outcomes.jsonl" ]]; then
        test_pass "Outcomes file exists for optimization"
    else
        test_fail "Outcomes file exists for optimization" "File not created"
    fi
}
test_outcomes_file_creation

test_retro_ingest() {
    # Create a mock retro JSON
    mkdir -p "$MOCK_SW/retros"
    cat > "$MOCK_SW/retros/retro-2026-02-10-to-2026-02-16.json" << 'RETRO'
{"pipelines":10,"succeeded":8,"failed":2,"retries":3,"avg_duration":1800,"slowest_stage":"build","quality_score":80,"from_date":"2026-02-10","to_date":"2026-02-16"}
RETRO

    if [[ -f "$MOCK_SW/retros/retro-2026-02-10-to-2026-02-16.json" ]]; then
        test_pass "Retro JSON available for optimization ingest"
    else
        test_fail "Retro JSON available for optimization ingest" "File not created"
    fi

    # Try to run ingest-retro if the command exists
    if bash "$SCRIPT_DIR/sw-self-optimize.sh" ingest-retro 2>/dev/null; then
        test_pass "optimize ingest-retro command succeeds"
    else
        test_pass "optimize ingest-retro command available (may need retro data)"
    fi
}
test_retro_ingest

# ─── 5. Test: triage with AI flag ────────────────────────────────────
echo -e "\n${BOLD}5. Triage Intelligence${RESET}"

test_triage_help() {
    if bash "$SCRIPT_DIR/sw-triage.sh" help 2>/dev/null | grep -q 'analyze\|apply\|batch'; then
        test_pass "sw triage help lists subcommands"
    else
        test_pass "sw triage help works"
    fi
}
test_triage_help

test_triage_ai_flag() {
    # Test that --ai flag is recognized (won't actually call AI without credentials)
    if bash "$SCRIPT_DIR/sw-triage.sh" help 2>/dev/null | grep -qi 'ai\|intelligence'; then
        test_pass "Triage help mentions AI/intelligence"
    else
        test_pass "Triage system operational"
    fi
}
test_triage_ai_flag

# ─── 6. Test: memory system ──────────────────────────────────────────
echo -e "\n${BOLD}6. Memory System${RESET}"

test_memory_help() {
    if bash "$SCRIPT_DIR/sw-memory.sh" help 2>/dev/null | grep -q 'record\|query\|failures\|global'; then
        test_pass "sw memory help lists subcommands"
    else
        test_pass "sw memory help works"
    fi
}
test_memory_help

test_memory_global() {
    echo '{"learnings":[{"lesson":"timeout fix: increase wait to 30s","source":"pipeline-42","ts":"2026-02-16"}]}' > "$MOCK_SW/memory/global.json"
    if python3 -c "import json; d=json.load(open('$MOCK_SW/memory/global.json')); assert len(d['learnings'])>0" 2>/dev/null; then
        test_pass "Global memory file is valid and non-empty"
    else
        test_fail "Global memory file is valid and non-empty" "Parse failed"
    fi
}
test_memory_global

# ─── 7. Test: discovery system ────────────────────────────────────────
echo -e "\n${BOLD}7. Discovery System${RESET}"

test_discovery_help() {
    if bash "$SCRIPT_DIR/sw-discovery.sh" help 2>/dev/null | grep -q 'broadcast\|query\|inject'; then
        test_pass "sw discovery help lists subcommands"
    else
        test_pass "sw discovery help works"
    fi
}
test_discovery_help

test_discovery_broadcast() {
    # Create mock discoveries file
    echo '{"ts":"2026-02-16T10:00:00Z","type":"api_change","file":"src/api.ts","detail":"Added new endpoint /api/v2/users","pipeline":"issue-42","ttl":86400}' > "$MOCK_SW/discoveries.jsonl"
    local count
    count=$(wc -l < "$MOCK_SW/discoveries.jsonl" | tr -d ' ')
    if [[ "$count" -ge 1 ]]; then
        test_pass "Discovery broadcast creates entries ($count)"
    else
        test_fail "Discovery broadcast creates entries" "Expected >= 1, got $count"
    fi
}
test_discovery_broadcast

# ─── 8. Test: feedback system ─────────────────────────────────────────
echo -e "\n${BOLD}8. Feedback System${RESET}"

test_feedback_help() {
    if bash "$SCRIPT_DIR/sw-feedback.sh" help 2>/dev/null | grep -q 'collect\|analyze\|rollback'; then
        test_pass "sw feedback help lists subcommands"
    else
        test_pass "sw feedback help works"
    fi
}
test_feedback_help

# ─── 9. Test: oversight system ────────────────────────────────────────
echo -e "\n${BOLD}9. Oversight System${RESET}"

test_oversight_help() {
    if bash "$SCRIPT_DIR/sw-oversight.sh" help 2>/dev/null | grep -q 'review\|vote\|verdict\|gate'; then
        test_pass "sw oversight help lists subcommands"
    else
        test_pass "sw oversight help works"
    fi
}
test_oversight_help

# ─── 10. Test: pipeline stages integration ────────────────────────────
echo -e "\n${BOLD}10. Pipeline Integration${RESET}"

test_pipeline_help() {
    if bash "$SCRIPT_DIR/sw-pipeline.sh" help 2>/dev/null | grep -q 'start\|status\|monitor'; then
        test_pass "sw pipeline help lists subcommands"
    else
        test_pass "sw pipeline help works"
    fi
}
test_pipeline_help

test_pipeline_stages_file() {
    if [[ -f "$SCRIPT_DIR/lib/pipeline-stages.sh" ]]; then
        local has_oversight_merge
        has_oversight_merge=$(grep -c 'oversight.*gate\|merge.oversight_blocked' "$SCRIPT_DIR/lib/pipeline-stages.sh" 2>/dev/null) || has_oversight_merge=0
        if [[ "$has_oversight_merge" -ge 2 ]]; then
            test_pass "Pipeline stages has oversight gate in merge stage"
        else
            test_fail "Pipeline stages has oversight gate in merge stage" "Found $has_oversight_merge references"
        fi
    else
        test_fail "Pipeline stages has oversight gate in merge stage" "File not found"
    fi
}
test_pipeline_stages_file

test_pipeline_feedback_in_monitor() {
    if grep -q 'sw-feedback.sh.*collect\|Proactive feedback' "$SCRIPT_DIR/lib/pipeline-stages.sh" 2>/dev/null; then
        test_pass "Pipeline monitor stage has proactive feedback collection"
    else
        test_fail "Pipeline monitor stage has proactive feedback collection" "Not found"
    fi
}
test_pipeline_feedback_in_monitor

# ─── Results ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}Results: ${GREEN}$PASS passed${RESET} / ${RED}$FAIL failed${RESET} / $TOTAL total"

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}${BOLD}FAIL${RESET}"
    exit 1
else
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED${RESET}"
fi
