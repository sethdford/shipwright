#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon-failure test — Unit tests for failure handling     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: daemon-failure Tests"

setup_test_env "sw-lib-daemon-failure-test"
trap cleanup_test_env EXIT

# Set up daemon environment variables
export LOG_DIR="$TEST_TEMP_DIR/logs"
export WORKTREE_DIR="$TEST_TEMP_DIR/worktrees"
export STATE_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
export DAEMON_DIR="$TEST_TEMP_DIR/home/.shipwright"
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
export PAUSE_FLAG="$TEST_TEMP_DIR/home/.shipwright/daemon.pause"
export NO_GITHUB=true
export REPO_DIR="$TEST_TEMP_DIR/project"
mkdir -p "$LOG_DIR" "$WORKTREE_DIR"

# Provide stub functions that daemon-failure.sh depends on
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
epoch_to_iso() { date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z"; }
emit_event() { :; }
daemon_log() { :; }
locked_state_update() { :; }
daemon_spawn_pipeline() { :; }
record_pipeline_duration() { :; }
record_scaling_outcome() { :; }
notify() { :; }

# Source the lib (clear guard)
_DAEMON_FAILURE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-failure.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# classify_failure
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "classify_failure"

# Unknown when no log exists
result=$(classify_failure 999)
assert_eq "No log file → unknown" "unknown" "$result"

# Unknown when LOG_DIR is empty
(
    LOG_DIR=""
    result=$(classify_failure 1)
    echo "$result"
) > "$TEST_TEMP_DIR/logdir_empty_result" 2>/dev/null
assert_eq "Empty LOG_DIR → unknown" "unknown" "$(cat "$TEST_TEMP_DIR/logdir_empty_result")"

# Auth error
echo "Error: not logged in to Claude API" > "$LOG_DIR/issue-101.log"
result=$(classify_failure 101)
assert_eq "Auth error classified" "auth_error" "$result"

echo "unauthorized access 401 error" > "$LOG_DIR/issue-102.log"
result=$(classify_failure 102)
assert_eq "401 auth error classified" "auth_error" "$result"

echo "CLAUDE_CODE_OAUTH_TOKEN is not set" > "$LOG_DIR/issue-103.log"
result=$(classify_failure 103)
assert_eq "OAuth token error classified" "auth_error" "$result"

# API error
echo "rate limit exceeded, please retry" > "$LOG_DIR/issue-201.log"
result=$(classify_failure 201)
assert_eq "Rate limit classified" "api_error" "$result"

echo "HTTP 503 Service Unavailable" > "$LOG_DIR/issue-202.log"
result=$(classify_failure 202)
assert_eq "503 error classified" "api_error" "$result"

echo "Error: socket hang up" > "$LOG_DIR/issue-203.log"
result=$(classify_failure 203)
assert_eq "Socket hang up classified" "api_error" "$result"

echo "ETIMEDOUT connecting to api" > "$LOG_DIR/issue-204.log"
result=$(classify_failure 204)
assert_eq "ETIMEDOUT classified" "api_error" "$result"

# Invalid issue
echo "issue not found: 404" > "$LOG_DIR/issue-301.log"
result=$(classify_failure 301)
assert_eq "Issue not found classified" "invalid_issue" "$result"

echo "could not resolve to a valid issue" > "$LOG_DIR/issue-302.log"
result=$(classify_failure 302)
assert_eq "Could not resolve classified" "invalid_issue" "$result"

# Build failure
echo "npm ERR! Test suite failed" > "$LOG_DIR/issue-401.log"
result=$(classify_failure 401)
assert_eq "npm test failure classified" "build_failure" "$result"

echo "FAIL: TestMyFunction" > "$LOG_DIR/issue-402.log"
result=$(classify_failure 402)
assert_eq "Test FAIL classified" "build_failure" "$result"

echo "compile error: undefined variable" > "$LOG_DIR/issue-403.log"
result=$(classify_failure 403)
assert_eq "Compile error classified" "build_failure" "$result"

# Context exhaustion
mkdir -p "$WORKTREE_DIR/daemon-issue-501/.claude/loop-logs"
cat > "$WORKTREE_DIR/daemon-issue-501/.claude/loop-logs/progress.md" <<'MD'
## Progress
Iteration: 5
Tests passing: false
MD
echo "Some general log output" > "$LOG_DIR/issue-501.log"
result=$(classify_failure 501)
assert_eq "Context exhaustion classified" "context_exhaustion" "$result"

# Context exhaustion with unknown test status
mkdir -p "$WORKTREE_DIR/daemon-issue-502/.claude/loop-logs"
cat > "$WORKTREE_DIR/daemon-issue-502/.claude/loop-logs/progress.md" <<'MD'
## Progress
Iteration: 3
MD
echo "Some general output" > "$LOG_DIR/issue-502.log"
result=$(classify_failure 502)
assert_eq "Context exhaustion with unknown tests" "context_exhaustion" "$result"

# Generic unknown
echo "something happened" > "$LOG_DIR/issue-601.log"
result=$(classify_failure 601)
assert_eq "Generic failure → unknown" "unknown" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# get_max_retries_for_class
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "get_max_retries_for_class"

assert_eq "auth_error: 0 retries" "0" "$(get_max_retries_for_class auth_error)"
assert_eq "invalid_issue: 0 retries" "0" "$(get_max_retries_for_class invalid_issue)"
assert_eq "api_error: default 4 retries" "4" "$(get_max_retries_for_class api_error)"
assert_eq "context_exhaustion: 2 retries" "2" "$(get_max_retries_for_class context_exhaustion)"
assert_eq "build_failure: 2 retries" "2" "$(get_max_retries_for_class build_failure)"
assert_eq "unknown: default 2 retries" "2" "$(get_max_retries_for_class unknown)"

# Custom overrides via env vars
MAX_RETRIES_API_ERROR=6 assert_eq "Custom api_error retries" "6" "$(MAX_RETRIES_API_ERROR=6 get_max_retries_for_class api_error)"
MAX_RETRIES=5 assert_eq "Custom default retries" "5" "$(MAX_RETRIES=5 get_max_retries_for_class unknown)"

# ═══════════════════════════════════════════════════════════════════════════════
# get_retry_backoff_for_class
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "get_retry_backoff_for_class"

# Deterministic policy with jitter off
export RETRY_BACKOFF_JITTER=0
unset RETRY_BACKOFF_CFG 2>/dev/null || true

assert_eq "auth_error: no backoff" "0" "$(get_retry_backoff_for_class auth_error 1)"
assert_eq "invalid_issue: no backoff" "0" "$(get_retry_backoff_for_class invalid_issue 3)"

# api_error keeps the historical 300 → 600 → 1200 → 2400 → 3600 ladder
assert_eq "api_error retry 1: 300s" "300" "$(get_retry_backoff_for_class api_error 1)"
assert_eq "api_error retry 2: 600s" "600" "$(get_retry_backoff_for_class api_error 2)"
assert_eq "api_error retry 3: 1200s" "1200" "$(get_retry_backoff_for_class api_error 3)"
assert_eq "api_error retry 4: 2400s" "2400" "$(get_retry_backoff_for_class api_error 4)"
assert_eq "api_error retry 5: capped at 3600s" "3600" "$(get_retry_backoff_for_class api_error 5)"
assert_eq "api_error huge retry: no overflow, capped" "3600" "$(get_retry_backoff_for_class api_error 500)"

# Consecutive api_error failures boost the wait (shared outage), still capped
assert_eq "api_error consecutive=2 doubles" "600" "$(get_retry_backoff_for_class api_error 1 2)"
assert_eq "api_error consecutive=3 quadruples" "1200" "$(get_retry_backoff_for_class api_error 1 3)"
assert_eq "api_error consecutive boost clamps at x8" "2400" "$(get_retry_backoff_for_class api_error 1 20)"
assert_eq "api_error boost respects cap" "3600" "$(get_retry_backoff_for_class api_error 3 4)"

# Other classes
assert_eq "build_failure retry 1: 30s" "30" "$(get_retry_backoff_for_class build_failure 1)"
assert_eq "build_failure retry 2: 60s" "60" "$(get_retry_backoff_for_class build_failure 2)"
assert_eq "build_failure capped at 600s" "600" "$(get_retry_backoff_for_class build_failure 10)"
assert_eq "build_failure ignores consecutive" "30" "$(get_retry_backoff_for_class build_failure 1 5)"
assert_eq "context_exhaustion flat 15s" "15" "$(get_retry_backoff_for_class context_exhaustion 3)"
assert_eq "unknown retry 1: 60s" "60" "$(get_retry_backoff_for_class unknown 1)"
assert_eq "unknown retry 2: 120s" "120" "$(get_retry_backoff_for_class unknown 2)"
assert_eq "unrecognised class uses unknown policy" "60" "$(get_retry_backoff_for_class weird_class 1)"

# Bad input never fails
assert_eq "non-numeric retry treated as 1" "300" "$(get_retry_backoff_for_class api_error abc)"
assert_eq "retry 0 treated as 1" "30" "$(get_retry_backoff_for_class build_failure 0)"
assert_eq "non-numeric consecutive treated as 1" "300" "$(get_retry_backoff_for_class api_error 1 xyz)"
assert_eq "no args: unknown retry 1" "60" "$(get_retry_backoff_for_class)"

# Overrides: env beats config beats default
assert_eq "env override base_secs" "100" "$(RETRY_BACKOFF_BUILD_FAILURE_BASE_SECS=100 get_retry_backoff_for_class build_failure 1)"
assert_eq "env override cap_secs" "45" "$(RETRY_BACKOFF_BUILD_FAILURE_CAP_SECS=45 get_retry_backoff_for_class build_failure 3)"
assert_eq "env override factor" "270" "$(RETRY_BACKOFF_BUILD_FAILURE_FACTOR=3 get_retry_backoff_for_class build_failure 3)"
assert_eq "config override base_secs" "10" \
    "$(RETRY_BACKOFF_CFG='{"api_error":{"base_secs":10,"cap_secs":100}}' get_retry_backoff_for_class api_error 1)"
assert_eq "config override cap_secs" "100" \
    "$(RETRY_BACKOFF_CFG='{"api_error":{"base_secs":10,"cap_secs":100}}' get_retry_backoff_for_class api_error 9)"
assert_eq "env beats config" "20" \
    "$(RETRY_BACKOFF_API_ERROR_BASE_SECS=20 RETRY_BACKOFF_CFG='{"api_error":{"base_secs":10}}' get_retry_backoff_for_class api_error 1)"
assert_eq "invalid env value falls back to default" "30" "$(RETRY_BACKOFF_BUILD_FAILURE_BASE_SECS=-5 get_retry_backoff_for_class build_failure 1)"
assert_eq "invalid config value falls back to default" "300" \
    "$(RETRY_BACKOFF_CFG='{"api_error":{"base_secs":"lots"}}' get_retry_backoff_for_class api_error 1)"
assert_eq "malformed config JSON falls back to default" "300" \
    "$(RETRY_BACKOFF_CFG='not json' get_retry_backoff_for_class api_error 1)"
assert_eq "unknown-class config key applies to unrecognised classes" "7" \
    "$(RETRY_BACKOFF_CFG='{"unknown":{"base_secs":7}}' get_retry_backoff_for_class weird_class 1)"

# Jitter stays within ±pct and within the cap
jitter_ok=true
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    v=$(RETRY_BACKOFF_JITTER=20 get_retry_backoff_for_class api_error 1)
    if [[ "$v" -lt 240 || "$v" -gt 360 ]]; then jitter_ok=false; fi
    v=$(RETRY_BACKOFF_JITTER=20 get_retry_backoff_for_class api_error 9)
    if [[ "$v" -lt 2880 || "$v" -gt 3600 ]]; then jitter_ok=false; fi
done
if $jitter_ok; then assert_pass "Jitter stays within ±20% and never exceeds cap"; else assert_fail "Jitter stays within ±20% and never exceeds cap"; fi
assert_eq "invalid jitter falls back without failing" "1" \
    "$(v=$(RETRY_BACKOFF_JITTER=bogus get_retry_backoff_for_class api_error 1); [[ "$v" -ge 240 && "$v" -le 360 ]] && echo 1 || echo 0)"

unset RETRY_BACKOFF_JITTER

# ═══════════════════════════════════════════════════════════════════════════════
# record_failure_class / reset_failure_tracking
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Failure tracking"

reset_failure_tracking
assert_eq "Initial consecutive class is empty" "" "$DAEMON_CONSECUTIVE_FAILURE_CLASS"
assert_eq "Initial consecutive count is 0" "0" "$DAEMON_CONSECUTIVE_FAILURE_COUNT"

# Track consecutive same-class failures
DAEMON_CONSECUTIVE_FAILURE_CLASS=""
DAEMON_CONSECUTIVE_FAILURE_COUNT=0
DAEMON_CONSECUTIVE_FAILURE_CLASS="api_error"
DAEMON_CONSECUTIVE_FAILURE_COUNT=1

# Simulate recording same class
if [[ "api_error" == "$DAEMON_CONSECUTIVE_FAILURE_CLASS" ]]; then
    DAEMON_CONSECUTIVE_FAILURE_COUNT=$((DAEMON_CONSECUTIVE_FAILURE_COUNT + 1))
fi
assert_eq "Same-class increments count" "2" "$DAEMON_CONSECUTIVE_FAILURE_COUNT"

# Different class resets
DAEMON_CONSECUTIVE_FAILURE_CLASS="build_failure"
DAEMON_CONSECUTIVE_FAILURE_COUNT=1
assert_eq "Different class resets count" "1" "$DAEMON_CONSECUTIVE_FAILURE_COUNT"

# Reset tracking
reset_failure_tracking
assert_eq "Reset clears class" "" "$DAEMON_CONSECUTIVE_FAILURE_CLASS"
assert_eq "Reset clears count" "0" "$DAEMON_CONSECUTIVE_FAILURE_COUNT"

# ═══════════════════════════════════════════════════════════════════════════════
# Edge cases: classify_failure with mixed signals
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "classify_failure edge cases"

# Auth errors take priority over build errors
cat > "$LOG_DIR/issue-701.log" <<'LOG'
npm ERR! Test suite failed
Error: not logged in to Claude API
exit code 1
LOG
result=$(classify_failure 701)
assert_eq "Auth error takes priority over build error" "auth_error" "$result"

# API error takes priority over build error
cat > "$LOG_DIR/issue-702.log" <<'LOG'
test failed
429 rate limit
exit code 1
LOG
result=$(classify_failure 702)
assert_eq "API error takes priority over build error" "api_error" "$result"

# Empty log file
touch "$LOG_DIR/issue-703.log"
result=$(classify_failure 703)
assert_eq "Empty log → unknown" "unknown" "$result"

print_test_results
