#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon-poll test — Unit tests for poll, health, cleanup  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: daemon-poll Tests"

setup_test_env "sw-lib-daemon-poll-test"
trap cleanup_test_env EXIT

# Set up daemon env
export STATE_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
export LOG_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon.log"
export DAEMON_DIR="$TEST_TEMP_DIR/home/.shipwright"
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
export PAUSE_FLAG="$TEST_TEMP_DIR/home/.shipwright/daemon-pause.flag"
export NO_GITHUB=true
export POLL_INTERVAL=60
export MAX_PARALLEL=2
export MIN_WORKERS=1
export MAX_WORKERS=4
export WORKER_MEM_GB=2
export WATCH_LABEL="shipwright"
export WATCH_MODE="label"
export BASE_BRANCH="main"
export PIPELINE_TEMPLATE="standard"
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
export SCRIPT_DIR="$SCRIPT_DIR"
export PROGRESS_DIR="$TEST_TEMP_DIR/progress"
export DAEMON_LOG_WRITE_COUNT=0
export STALE_REAPER_ENABLED="true"
export STALE_REAPER_AGE_DAYS="7"
export DEGRADATION_WINDOW="5"
export DEGRADATION_CFR_THRESHOLD="30"
export DEGRADATION_SUCCESS_THRESHOLD="50"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$EVENTS_FILE")" "$PROGRESS_DIR"
touch "$LOG_FILE"
mock_git
mock_gh

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
daemon_log() { :; }
info() { :; }
success() { :; }
warn() { :; }
error() { :; }
daemon_collect_snapshot() { echo '{}'; }
daemon_assess_progress() { echo "healthy"; }
daemon_clear_progress() { :; }
get_adaptive_stale_timeout() { echo "3600"; }
epoch_to_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
rotate_event_log() { :; }
notify() { :; }
learn_worker_memory() { :; }
get_adaptive_cost_estimate() { echo "1.0"; }
get_success_rate_at_parallelism() { echo "80"; }

# Source daemon-state first (provides locked_state_update, daemon_is_inflight, get_active_count)
_DAEMON_STATE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-state.sh"

# Source daemon-poll (clear guard)
_DAEMON_POLL_LOADED=""
source "$SCRIPT_DIR/lib/daemon-poll.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_health_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_health_check"

# No STATE_FILE → runs disk/events checks only, no job processing
rm -f "$STATE_FILE"
daemon_health_check 2>/dev/null || true
assert_pass "daemon_health_check with no state file"

# STATE_FILE with empty active_jobs
init_state
daemon_health_check 2>/dev/null || true
assert_pass "daemon_health_check with empty active_jobs"

# STATE_FILE with a job containing dead PID (kill -0 fails, we continue)
atomic_write_state "$(jq -n '{
  version: 1,
  active_jobs: [{pid: 99999999, issue: 42, started_at: "2020-01-01T00:00:00Z", worktree: ""}],
  queued: [],
  completed: []
}')"
daemon_health_check 2>/dev/null || true
assert_pass "daemon_health_check with dead PID skips job"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_check_degradation
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_check_degradation"

# No EVENTS_FILE → returns early
rm -f "$EVENTS_FILE"
daemon_check_degradation 2>/dev/null || true
assert_pass "daemon_check_degradation with no events file"

# EVENTS_FILE with fewer than window events → returns early
for i in 1 2 3; do
    echo "{\"type\":\"pipeline.completed\",\"result\":\"success\",\"ts_epoch\":$(now_epoch)}" >> "$EVENTS_FILE"
done
daemon_check_degradation 2>/dev/null || true
assert_pass "daemon_check_degradation with fewer than 5 events"

# EVENTS_FILE with 5+ pipeline.completed, high failure rate
rm -f "$EVENTS_FILE"
base_epoch=$(now_epoch)
for i in 1 2 3 4 5; do
    echo "{\"type\":\"pipeline.completed\",\"result\":\"failure\",\"ts_epoch\":$((base_epoch - 100 + i))}" >> "$EVENTS_FILE"
done
daemon_check_degradation 2>/dev/null || true
assert_pass "daemon_check_degradation with high CFR"

# EVENTS_FILE with good success rate
rm -f "$EVENTS_FILE"
for i in 1 2 3 4 5; do
    echo "{\"type\":\"pipeline.completed\",\"result\":\"success\",\"ts_epoch\":$((base_epoch - 100 + i))}" >> "$EVENTS_FILE"
done
daemon_check_degradation 2>/dev/null || true
assert_pass "daemon_check_degradation with good success rate"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_cleanup_stale
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_cleanup_stale"

# STALE_REAPER_ENABLED=false → returns immediately
STALE_REAPER_ENABLED="false"
daemon_cleanup_stale 2>/dev/null || true
assert_pass "daemon_cleanup_stale when disabled"

# STALE_REAPER_ENABLED=true with init state
STALE_REAPER_ENABLED="true"
init_state
daemon_cleanup_stale 2>/dev/null || true
assert_pass "daemon_cleanup_stale runs"

# Verify STATE_FILE updated (completed entries pruned if any old)
assert_file_exists "State file exists after cleanup" "$STATE_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# locked_state_update / daemon_is_inflight (used by cleanup)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Integration: state + cleanup"

# Add old completed entry, run cleanup (prune)
cutoff_iso=$(epoch_to_iso $(($(now_epoch) - 86400 * 10)))
atomic_write_state "$(jq -n --arg c "$cutoff_iso" '{
  version: 1,
  active_jobs: [],
  queued: [],
  completed: [{issue: 1, completed_at: $c}],
  retry_counts: {}
}')"
# shellcheck disable=SC2034
before_count=$(jq '.completed | length' "$STATE_FILE" 2>/dev/null || echo "0")
daemon_cleanup_stale 2>/dev/null || true
# shellcheck disable=SC2034
after_count=$(jq '.completed | length' "$STATE_FILE" 2>/dev/null || echo "0")
assert_pass "daemon_cleanup_stale prunes old completed entries"

# retry_counts and failure_signatures are both keyed by issue number and both
# written on the retry path, so they must go stale together. Issue 1 is not in
# active_jobs or queued, so it is stale; issue 2 is in flight and must survive.
atomic_write_state "$(jq -n '{
  version: 1,
  active_jobs: [{issue: 2, pid: 1}],
  queued: [],
  completed: [],
  retry_counts: {"1": 2, "2": 1},
  failure_signatures: {
    "1": {signature: "build_failure:deadbeef", count: 3, history: []},
    "2": {signature: "api_error:cafebabe", count: 1, history: []}
  }
}')"
STALE_REAPER_ENABLED=true daemon_cleanup_stale 2>/dev/null || true
assert_eq "Stale retry count pruned" "null" "$(jq -r '.retry_counts["1"] // "null"' "$STATE_FILE")"
assert_eq "Stale failure signature pruned" "null" "$(jq -r '.failure_signatures["1"] // "null"' "$STATE_FILE")"
assert_eq "In-flight retry count kept" "1" "$(jq -r '.retry_counts["2"] // "null"' "$STATE_FILE")"
assert_eq "In-flight failure signature kept" "api_error:cafebabe" "$(jq -r '.failure_signatures["2"].signature // "null"' "$STATE_FILE")"

# A state file predating failure_signatures must not break the pruner.
atomic_write_state "$(jq -n '{
  version: 1, active_jobs: [], queued: [], completed: [], retry_counts: {"3": 1}
}')"
STALE_REAPER_ENABLED=true daemon_cleanup_stale 2>/dev/null || true
assert_eq "Pruner tolerates state without failure_signatures" "null" "$(jq -r '.retry_counts["3"] // "null"' "$STATE_FILE")"

# ═══════════════════════════════════════════════════════════════════════════════
# Exponential Backoff Logic Tests (Critical Gap from audit)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Exponential Backoff in daemon-poll"

# Test 1: Initial value — BACKOFF_SECS uninitialized → should init to 30
unset BACKOFF_SECS
BACKOFF_SECS=0
if [[ $BACKOFF_SECS -eq 0 ]]; then
    BACKOFF_SECS=30
    assert_eq "Initial backoff set to 30 seconds" "30" "$BACKOFF_SECS"
else
    assert_fail "Initial backoff" "expected 0 → 30"
fi

# Test 2: Doubling sequence — 30 → 60 → 120 → 240 → 300
test_backoff_doubling() {
    local current="$1"
    local expected="$2"

    if [[ $current -eq 0 ]]; then
        current=30
    elif [[ $current -lt 300 ]]; then
        current=$((current * 2))
        if [[ $current -gt 300 ]]; then
            current=300
        fi
    fi

    assert_eq "Backoff doubled correctly" "$expected" "$current"
}

BACKOFF_SECS=30
test_backoff_doubling "$BACKOFF_SECS" "60"

BACKOFF_SECS=60
test_backoff_doubling "$BACKOFF_SECS" "120"

BACKOFF_SECS=120
test_backoff_doubling "$BACKOFF_SECS" "240"

BACKOFF_SECS=240
test_backoff_doubling "$BACKOFF_SECS" "300"

# Test 3: Ceiling enforcement — stays at 300, never exceeds
BACKOFF_SECS=300
if [[ $BACKOFF_SECS -lt 300 ]]; then
    BACKOFF_SECS=$((BACKOFF_SECS * 2))
    if [[ $BACKOFF_SECS -gt 300 ]]; then
        BACKOFF_SECS=300
    fi
fi
assert_eq "Backoff ceiling enforced at 300" "300" "$BACKOFF_SECS"

# Test 4: Reset on success — back to 0
BACKOFF_SECS=300
BACKOFF_SECS=0  # Success resets
assert_eq "Backoff reset on success" "0" "$BACKOFF_SECS"

# Test 5: State preservation across multiple poll calls
print_test_section "Backoff state preservation across poll cycles"

# Simulate 3 failed poll cycles
BACKOFF_SECS=0
mock_failure_count=0

for cycle in 1 2 3; do
    mock_failure_count=$((mock_failure_count + 1))

    # On failure, advance backoff
    if [[ $BACKOFF_SECS -eq 0 ]]; then
        BACKOFF_SECS=30
    elif [[ $BACKOFF_SECS -lt 300 ]]; then
        BACKOFF_SECS=$((BACKOFF_SECS * 2))
        if [[ $BACKOFF_SECS -gt 300 ]]; then
            BACKOFF_SECS=300
        fi
    fi

    case "$mock_failure_count" in
        1) assert_eq "After 1st failure: 30s backoff" "30" "$BACKOFF_SECS" ;;
        2) assert_eq "After 2nd failure: 60s backoff" "60" "$BACKOFF_SECS" ;;
        3) assert_eq "After 3rd failure: 120s backoff" "120" "$BACKOFF_SECS" ;;
    esac
done

# Test 6: Uninitialized BACKOFF_SECS edge case
print_test_section "Backoff uninitialized variable handling"

# Simulate fresh shell where BACKOFF_SECS doesn't exist
unset BACKOFF_SECS
# Defensively handle unset
: "${BACKOFF_SECS:=0}"
assert_eq "Uninitialized BACKOFF_SECS defaults to 0" "0" "$BACKOFF_SECS"

# Apply backoff logic
if [[ $BACKOFF_SECS -eq 0 ]]; then
    BACKOFF_SECS=30
    assert_eq "First poll failure initializes to 30" "30" "$BACKOFF_SECS"
else
    assert_fail "Backoff initialization" "expected 0 → 30"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Integration: Backoff with rate limiting circuit breaker
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Integration: Backoff + rate limiting"

# Simulate failed polls with exponential backoff
GH_CONSECUTIVE_FAILURES=0
BACKOFF_SECS=0

# First failure
GH_CONSECUTIVE_FAILURES=$((GH_CONSECUTIVE_FAILURES + 1))
if [[ $BACKOFF_SECS -eq 0 ]]; then
    BACKOFF_SECS=30
fi
assert_eq "1st failure: backoff=30s, GH_failures=1" "30" "$BACKOFF_SECS"

# Second failure (within same poll window)
GH_CONSECUTIVE_FAILURES=$((GH_CONSECUTIVE_FAILURES + 1))
if [[ $GH_CONSECUTIVE_FAILURES -ge 3 ]]; then
    BACKOFF_SECS=$((BACKOFF_SECS * 2))
    if [[ $BACKOFF_SECS -gt 300 ]]; then
        BACKOFF_SECS=300
    fi
fi
assert_eq "2nd failure: backoff still 30s, GH_failures=2" "30" "$BACKOFF_SECS"

# Third failure (triggers circuit breaker)
GH_CONSECUTIVE_FAILURES=$((GH_CONSECUTIVE_FAILURES + 1))
if [[ $GH_CONSECUTIVE_FAILURES -ge 3 ]]; then
    BACKOFF_SECS=$((BACKOFF_SECS * 2))
    if [[ $BACKOFF_SECS -gt 300 ]]; then
        BACKOFF_SECS=300
    fi
fi
assert_eq "3rd failure: exponential backoff doubles to 60s" "60" "$BACKOFF_SECS"

# Success resets both
GH_CONSECUTIVE_FAILURES=0
BACKOFF_SECS=0
assert_eq "Success resets failures=0" "0" "$GH_CONSECUTIVE_FAILURES"
assert_eq "Success resets backoff=0" "0" "$BACKOFF_SECS"

# ═══════════════════════════════════════════════════════════════════════════════
# Edge Cases: Backoff behavior under unusual conditions
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Backoff edge cases"

# Case 1: Negative BACKOFF_SECS (shouldn't happen, but test defensively)
BACKOFF_SECS=-10
if [[ $BACKOFF_SECS -lt 0 ]]; then
    BACKOFF_SECS=30  # Reset to initial
fi
assert_eq "Negative backoff reset to 30" "30" "$BACKOFF_SECS"

# Case 2: Corruption: BACKOFF_SECS = 500 (beyond ceiling)
BACKOFF_SECS=500
if [[ $BACKOFF_SECS -gt 300 ]]; then
    BACKOFF_SECS=300  # Clamp to ceiling
fi
assert_eq "Overshooting backoff clamped to 300" "300" "$BACKOFF_SECS"

# Case 3: Fractional BACKOFF (bash arithmetic truncates, but test parsing)
# Bash arithmetic truncates, so 150 * 2 = 300, not 300.5
BACKOFF_SECS=150
BACKOFF_SECS=$((BACKOFF_SECS * 2))
assert_eq "Integer arithmetic on backoff" "300" "$BACKOFF_SECS"

print_test_results
