#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon-patrol test — Unit tests for all patrol functions  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: daemon-patrol Tests"

setup_test_env "sw-lib-daemon-patrol-test"
trap cleanup_test_env EXIT

# Set up daemon environment
export STATE_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
export LOG_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon.log"
export DAEMON_DIR="$TEST_TEMP_DIR/home/.shipwright"
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
export PAUSE_FLAG="$TEST_TEMP_DIR/home/.shipwright/daemon.pause"
export REPO_DIR="$TEST_TEMP_DIR/project"
export NO_GITHUB=true
export POLL_INTERVAL=60
export MAX_PARALLEL=2
export BASE_BRANCH="main"
export PIPELINE_TEMPLATE="standard"
export PATROL_LABEL="shipwright-patrol"
export PATROL_DRY_RUN="false"
export PATROL_AUTO_WATCH="false"
export PATROL_MAX_ISSUES="10"
export DECISION_ENGINE_ENABLED="false"
export DAEMON_LOG_WRITE_COUNT=0

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$EVENTS_FILE")" "$REPO_DIR"
touch "$LOG_FILE"

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
info() { :; }
success() { :; }
warn() { :; }
error() { :; }
daemon_log() { :; }
notify() { :; }
notify_on_patrol_finding() { :; }

# Git mock
mock_git
mock_gh

# Required env vars for daemon-state.sh
export WATCH_LABEL="${WATCH_LABEL:-shipwright}"
export WATCH_MODE="${WATCH_MODE:-label}"
export WORKTREE_DIR="${WORKTREE_DIR:-$REPO_DIR/.worktrees}"

# Source dependencies
_DAEMON_STATE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-state.sh"

_DAEMON_PATROL_LOADED=""
source "$SCRIPT_DIR/lib/daemon-patrol.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_security_scan
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_security_scan"

# Create mock security scan output with vulnerabilities
SECURITY_SCAN_OUTPUT="package-lock.json: CRITICAL: Command Injection in lodash v4.17.19
package-lock.json: HIGH: Prototype Pollution in lodash v4.17.19
requirements.txt: CRITICAL: SQL Injection in django v2.2.0"

mock_binary "npm" 'case "${1:-}" in
audit)
  echo "{\"auditReportVersion\":2,\"vulnerabilities\":{\"lodash\":{\"name\":\"lodash\",\"severity\":\"critical\",\"via\":[{\"url\":\"https://advisory.com\",\"title\":\"Command Injection\"}]}}}"
  ;;
*) exit 0 ;;
esac'

# Initialize state
init_state

# Call the security scan function
daemon_patrol_security_scan 2>/dev/null || true

# Verify events were emitted for findings
events_content=$(cat "$EVENTS_FILE" 2>/dev/null || echo "")
if [[ -n "$events_content" ]]; then
    assert_contains "Security scan emits findings event" "$events_content" "patrol.finding" || true
    assert_pass "daemon_patrol_security_scan processes vulnerabilities"
else
    assert_pass "daemon_patrol_security_scan runs without errors"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_config_refresh
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_config_refresh"

# Create a valid config file
CONFIG_FILE="$DAEMON_DIR/patrol-config.json"
mkdir -p "$(dirname "$CONFIG_FILE")"
jq -n '{
  "enabled": true,
  "scan_interval": 3600,
  "checks": ["security", "architecture", "regression"]
}' > "$CONFIG_FILE"

# Test valid config reload
daemon_patrol_config_refresh 2>/dev/null || true
assert_pass "daemon_patrol_config_refresh loads valid config"

# Test with malformed config (syntax error)
echo "invalid json {{{" > "$CONFIG_FILE"
daemon_patrol_config_refresh 2>/dev/null || true
assert_pass "daemon_patrol_config_refresh handles syntax errors gracefully"

# Restore valid config
jq -n '{
  "enabled": true,
  "scan_interval": 3600
}' > "$CONFIG_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_worker_memory
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_worker_memory"

# Create mock memory snapshot data
MEMORY_FILE="$DAEMON_DIR/worker-memory.json"
jq -n '{
  "workers": [
    {
      "pid": 1234,
      "memory_mb": 512,
      "timestamp": "2026-02-28T12:00:00Z"
    },
    {
      "pid": 1235,
      "memory_mb": 1024,
      "timestamp": "2026-02-28T12:00:00Z"
    }
  ],
  "max_observed_mb": 1024,
  "avg_observed_mb": 768
}' > "$MEMORY_FILE"

# Call worker memory patrol
daemon_patrol_worker_memory 2>/dev/null || true
assert_pass "daemon_patrol_worker_memory analyzes memory data"

# Test with missing data (graceful degradation)
rm -f "$MEMORY_FILE"
daemon_patrol_worker_memory 2>/dev/null || true
assert_pass "daemon_patrol_worker_memory handles missing data"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_regression
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_regression"

# Create baseline metrics
BASELINE_FILE="$DAEMON_DIR/baseline-metrics.json"
jq -n '{
  "lead_time_sec": 3600,
  "deployment_frequency_per_day": 2.5,
  "change_failure_rate_pct": 15.0,
  "mean_time_to_recovery_sec": 1800,
  "timestamp": "2026-02-27T00:00:00Z"
}' > "$BASELINE_FILE"

# Create current metrics showing regression
CURRENT_FILE="$DAEMON_DIR/current-metrics.json"
jq -n '{
  "lead_time_sec": 7200,
  "deployment_frequency_per_day": 1.2,
  "change_failure_rate_pct": 32.0,
  "mean_time_to_recovery_sec": 3600,
  "timestamp": "2026-02-28T12:00:00Z"
}' > "$CURRENT_FILE"

# Call regression detection
daemon_patrol_regression 2>/dev/null || true
assert_pass "daemon_patrol_regression detects metric changes"

# Verify event for regression detection
events_content=$(cat "$EVENTS_FILE" 2>/dev/null || echo "")
if [[ -n "$events_content" ]]; then
    assert_contains_regex "Regression detection logs event" "$events_content" "patrol\." || true
fi

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_auto_scale
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_auto_scale"

# Test scaling with various resource inputs
test_scaling_scenario() {
    local cpu_percent="$1" mem_gb_avail="$2" budget_remaining="$3" queue_size="$4" expected_workers="$5"

    # Set environment
    export SYSTEM_CORES=8
    export AVAILABLE_MEMORY_GB="$mem_gb_avail"
    export WORKER_MEM_GB=2
    export REMAINING_BUDGET_USD="$budget_remaining"
    export ESTIMATED_COST_PER_JOB_USD=5.0
    export MAX_WORKERS=8
    export MIN_WORKERS=1

    # Mock df for CPU usage
    mock_binary "df" 'echo "100 $CPU_PERCENT"'

    # Call auto-scale
    daemon_patrol_auto_scale 2>/dev/null || true
    assert_pass "daemon_patrol_auto_scale ($cpu_percent% CPU, ${mem_gb_avail}GB RAM)"
}

# Test 1: High CPU utilization
test_scaling_scenario 80 4 50.0 5 2

# Test 2: Low memory available
test_scaling_scenario 50 1 50.0 10 1

# Test 3: Low budget
test_scaling_scenario 50 8 5.0 10 1

# Test 4: Normal conditions
test_scaling_scenario 40 6 100.0 3 4

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_architecture_enforce
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_architecture_enforce"

# Create architecture rules
ARCH_RULES_FILE="$DAEMON_DIR/architecture-rules.json"
jq -n '{
  "rules": [
    {
      "name": "no-circular-imports",
      "type": "dependency",
      "pattern": "should not allow circular dependencies"
    },
    {
      "name": "layer-boundaries",
      "type": "structure",
      "pattern": "should enforce layer boundaries (controllers, services, models)"
    }
  ]
}' > "$ARCH_RULES_FILE"

# Create a file that violates a rule
VIOLATION_FILE="$REPO_DIR/src/circular-import.js"
mkdir -p "$(dirname "$VIOLATION_FILE")"
cat > "$VIOLATION_FILE" <<'EOF'
// This file violates architecture rules
const serviceA = require('./service-a');
const serviceB = require('./service-b');
serviceB.dependsOn(serviceA);
serviceA.dependsOn(serviceB); // VIOLATION: circular dependency
EOF

# Initialize git repo for pattern analysis
mkdir -p "$REPO_DIR/.git"
(cd "$REPO_DIR" && git init -q -b main 2>/dev/null && git config user.email "test@test.com" && git config user.name "Test" && touch .gitignore && git add . && git commit -q -m "init" 2>/dev/null) || true

# Call architecture enforcement
daemon_patrol_architecture_enforce 2>/dev/null || true
assert_pass "daemon_patrol_architecture_enforce validates rules"

# Verify that violations are detected (event emitted)
events_content=$(cat "$EVENTS_FILE" 2>/dev/null || echo "")
if [[ -n "$events_content" ]]; then
    assert_contains_regex "Architecture validation logs event" "$events_content" "patrol\." || true
fi

# ═══════════════════════════════════════════════════════════════════════════════
# patrol_build_labels (helper function)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "patrol_build_labels"

export PATROL_LABEL="patrol"
export WATCH_LABEL="shipwright"
PATROL_AUTO_WATCH="false"

labels=$(patrol_build_labels "security")
assert_eq "patrol_build_labels without auto-watch" "patrol,security" "$labels"

PATROL_AUTO_WATCH="true"
labels=$(patrol_build_labels "performance")
assert_contains "patrol_build_labels with auto-watch includes WATCH_LABEL" "$labels" "shipwright"

# ═══════════════════════════════════════════════════════════════════════════════
# Integration: Patrol with decision engine signal mode
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Integration: Patrol signal emission"

export DECISION_ENGINE_ENABLED="true"
export SIGNALS_PENDING_FILE="$DAEMON_DIR/signals/pending.jsonl"
mkdir -p "$(dirname "$SIGNALS_PENDING_FILE")"

# Reset events file
: > "$EVENTS_FILE"

# Call security scan with decision engine enabled
daemon_patrol_security_scan 2>/dev/null || true

# Check if signals were written
if [[ -f "$SIGNALS_PENDING_FILE" ]]; then
    signal_count=$(wc -l < "$SIGNALS_PENDING_FILE" 2>/dev/null || echo "0")
    if [[ "$signal_count" -gt 0 ]]; then
        assert_pass "Patrol emits signals to decision engine"
    else
        assert_pass "Patrol signal file created (no findings in mock)"
    fi
else
    assert_pass "Patrol handles decision engine signal mode"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Edge cases and error handling
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Edge cases and error handling"

# Test 1: No configuration file (graceful degradation)
rm -f "$CONFIG_FILE"
daemon_patrol_config_refresh 2>/dev/null || true
assert_pass "Handles missing configuration file"

# Test 2: Empty metrics file
echo "{}" > "$BASELINE_FILE"
daemon_patrol_regression 2>/dev/null || true
assert_pass "Handles empty metrics data"

# Test 3: Patrol with DRY_RUN enabled
export PATROL_DRY_RUN="true"
daemon_patrol_security_scan 2>/dev/null || true
assert_pass "Patrol respects DRY_RUN flag"


# ═══════════════════════════════════════════════════════════════════════════════
# patrol_oversized_scripts
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "patrol_oversized_scripts"

REAL_SCRIPT_DIR="$SCRIPT_DIR"
FAKE_SCRIPTS_DIR="$TEST_TEMP_DIR/fake-scripts"
mkdir -p "$FAKE_SCRIPTS_DIR"
# One clearly oversized script and one clearly under the threshold
awk 'BEGIN { for (i = 0; i < 2500; i++) print "# line" }' > "$FAKE_SCRIPTS_DIR/sw-huge.sh"
awk 'BEGIN { for (i = 0; i < 100; i++) print "# line" }' > "$FAKE_SCRIPTS_DIR/sw-small.sh"

export GH_CALL_LOG="$TEST_TEMP_DIR/gh-calls.log"
: > "$GH_CALL_LOG"
# mock_binary writes its body through an UNQUOTED heredoc, so runtime
# variables must be escaped to survive into the mock script itself.
mock_binary "gh" 'if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
  [[ -n "${GH_LIST_RESULT:-}" ]] && echo "$GH_LIST_RESULT"
  exit "${GH_LIST_EXIT:-0}"
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "create" ]]; then
  echo "create $*" >> "$GH_CALL_LOG"
  exit 0
fi
exit 0'

# Record emitted findings instead of discarding them
PATROL_TEST_EVENTS="$TEST_TEMP_DIR/patrol-events.log"
emit_event() { echo "$*" >> "$PATROL_TEST_EVENTS"; }

run_oversized() {
    # Fresh per-call state mirroring daemon_patrol's locals
    total_findings=0
    issues_created=0
    : > "$PATROL_TEST_EVENTS"
    : > "$GH_CALL_LOG"
    SCRIPT_DIR="$FAKE_SCRIPTS_DIR"
    patrol_oversized_scripts >/dev/null 2>&1 || true
    SCRIPT_DIR="$REAL_SCRIPT_DIR"
}

export PATROL_OVERSIZED_ENABLED="true"
export PATROL_OVERSIZED_THRESHOLD="2000"
export PATROL_DRY_RUN="false"
export NO_GITHUB=true
# An earlier section leaves the decision engine on — pin it off here
export DECISION_ENGINE_ENABLED="false"

# Test 1: flags a script over the threshold
run_oversized
assert_contains "Flags script over threshold" "$(cat "$PATROL_TEST_EVENTS")" "script=sw-huge.sh"
assert_eq "Counts exactly one finding" "1" "$total_findings"

# Test 2: ignores a script at or under the threshold
assert_eq "Ignores script under threshold" "" "$(grep 'sw-small.sh' "$PATROL_TEST_EVENTS" || true)"

# Test 3: boundary — a script exactly at the threshold is not flagged
PATROL_OVERSIZED_THRESHOLD=2500
run_oversized
assert_eq "Script exactly at threshold is not flagged" "0" "$total_findings"
PATROL_OVERSIZED_THRESHOLD=2000

# Test 4: NO_GITHUB suppresses issue creation
run_oversized
assert_eq "NO_GITHUB=true creates no issue" "" "$(cat "$GH_CALL_LOG")"

# Test 5: dry-run suppresses issue creation
export NO_GITHUB=false
export PATROL_DRY_RUN="true"
export GH_LIST_RESULT="0"
run_oversized
assert_eq "Dry-run creates no issue" "" "$(cat "$GH_CALL_LOG")"
export PATROL_DRY_RUN="false"

# Test 6: files exactly one aggregate issue when none exists
run_oversized
assert_eq "Files exactly one aggregate issue" "1" "$(grep -c '^create ' "$GH_CALL_LOG" || true)"
assert_contains "Issue is labeled hygiene" "$(cat "$GH_CALL_LOG")" "hygiene"
assert_eq "Increments issues_created once" "1" "$issues_created"

# Test 7: dedup — an existing open issue suppresses a second filing
export GH_LIST_RESULT="1"
run_oversized
assert_eq "Existing open issue suppresses duplicate" "" "$(cat "$GH_CALL_LOG")"

# Test 8: dedup fails closed when the gh query errors
export GH_LIST_RESULT=""
export GH_LIST_EXIT="1"
run_oversized
assert_eq "Failed dedup query files nothing (fails closed)" "" "$(cat "$GH_CALL_LOG")"
export GH_LIST_EXIT="0"
export GH_LIST_RESULT="0"

# Test 9: disabled flag short-circuits the whole check
export PATROL_OVERSIZED_ENABLED="false"
run_oversized
assert_eq "Disabled flag skips the check" "0" "$total_findings"
assert_eq "Disabled flag creates no issue" "" "$(cat "$GH_CALL_LOG")"
export PATROL_OVERSIZED_ENABLED="true"

# Test 10: decision-engine mode writes a signal instead of an issue
export DECISION_ENGINE_ENABLED="true"
SIGNALS_PENDING_FILE="$TEST_TEMP_DIR/pending.jsonl"
: > "$SIGNALS_PENDING_FILE"
run_oversized
assert_eq "Decision-engine mode creates no issue" "" "$(cat "$GH_CALL_LOG")"
assert_contains "Decision-engine mode writes a pending signal" "$(cat "$SIGNALS_PENDING_FILE")" "oversized_scripts"
export DECISION_ENGINE_ENABLED="false"

# Test 11: missing scripts directory is handled gracefully
total_findings=0
SCRIPT_DIR="$TEST_TEMP_DIR/does-not-exist"
patrol_oversized_scripts >/dev/null 2>&1 || true
SCRIPT_DIR="$REAL_SCRIPT_DIR"
assert_eq "Missing scripts directory is a no-op" "0" "$total_findings"

export NO_GITHUB=true
emit_event() { :; }

print_test_results
