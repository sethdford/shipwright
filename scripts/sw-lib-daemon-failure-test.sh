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

# Flatline: the loop records Exit class: flatline — must not be called context exhaustion
mkdir -p "$WORKTREE_DIR/daemon-issue-503/.claude/loop-logs"
cat > "$WORKTREE_DIR/daemon-issue-503/.claude/loop-logs/progress.md" <<'MD'
## Status
- Iteration: 6/20
- Tests passing: false
- Status: circuit_breaker
- Exit class: flatline
- Flatline streak: 3/3
MD
echo "Some general output" > "$LOG_DIR/issue-503.log"
result=$(classify_failure 503)
assert_eq "Flatline exit class classified as flatline" "flatline" "$result"

# Iteration exhaustion is its own class: no context-exhaustion restart boost
mkdir -p "$WORKTREE_DIR/daemon-issue-504/.claude/loop-logs"
cat > "$WORKTREE_DIR/daemon-issue-504/.claude/loop-logs/progress.md" <<'MD'
- Iteration: 20/20
- Tests passing: false
- Exit class: iteration_exhaustion
MD
echo "Some general output" > "$LOG_DIR/issue-504.log"
result=$(classify_failure 504)
assert_eq "Iteration exhaustion classified as iteration_exhaustion" "iteration_exhaustion" "$result"

# After a restart, the last Exit class line wins
mkdir -p "$WORKTREE_DIR/daemon-issue-506/.claude/loop-logs"
cat > "$WORKTREE_DIR/daemon-issue-506/.claude/loop-logs/progress.md" <<'MD'
- Iteration: 4/20
- Tests passing: false
- Exit class: context_exhaustion
- Iteration: 9/20
- Tests passing: false
- Exit class: flatline
MD
echo "Some general output" > "$LOG_DIR/issue-506.log"
result=$(classify_failure 506)
assert_eq "Last Exit class line wins after restart" "flatline" "$result"

# An unrecognised exit class (e.g. circuit_breaker) is a build failure, not context exhaustion
mkdir -p "$WORKTREE_DIR/daemon-issue-507/.claude/loop-logs"
cat > "$WORKTREE_DIR/daemon-issue-507/.claude/loop-logs/progress.md" <<'MD'
- Iteration: 7/20
- Tests passing: false
- Exit class: circuit_breaker
MD
echo "Some general output" > "$LOG_DIR/issue-507.log"
result=$(classify_failure 507)
assert_eq "Unrecognised exit class classified as build_failure" "build_failure" "$result"

# Flatline with passing tests is not a loop failure class
mkdir -p "$WORKTREE_DIR/daemon-issue-505/.claude/loop-logs"
cat > "$WORKTREE_DIR/daemon-issue-505/.claude/loop-logs/progress.md" <<'MD'
- Iteration: 4/20
- Tests passing: true
- Exit class: flatline
MD
echo "Some general output" > "$LOG_DIR/issue-505.log"
result=$(classify_failure 505)
assert_eq "Flatline with passing tests not classified flatline" "unknown" "$result"

# Generic unknown
echo "something happened" > "$LOG_DIR/issue-601.log"
result=$(classify_failure 601)
assert_eq "Generic failure → unknown" "unknown" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# _failure_class_from_exit_class
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_failure_class_from_exit_class"

assert_eq "flatline → flatline" "flatline" "$(_failure_class_from_exit_class flatline)"
assert_eq "context_exhaustion → context_exhaustion" "context_exhaustion" "$(_failure_class_from_exit_class context_exhaustion)"
assert_eq "iteration_exhaustion → iteration_exhaustion" "iteration_exhaustion" "$(_failure_class_from_exit_class iteration_exhaustion)"
assert_eq "missing (legacy progress.md) → context_exhaustion" "context_exhaustion" "$(_failure_class_from_exit_class "")"
assert_eq "circuit_breaker → build_failure" "build_failure" "$(_failure_class_from_exit_class circuit_breaker)"
assert_eq "garbage → build_failure" "build_failure" "$(_failure_class_from_exit_class 'not a class')"

# ═══════════════════════════════════════════════════════════════════════════════
# get_max_retries_for_class
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "get_max_retries_for_class"

assert_eq "auth_error: 0 retries" "0" "$(get_max_retries_for_class auth_error)"
assert_eq "flatline: 1 retry by default" "1" "$(get_max_retries_for_class flatline)"
assert_eq "flatline: MAX_RETRIES_FLATLINE override" "3" "$(MAX_RETRIES_FLATLINE=3 get_max_retries_for_class flatline)"
assert_eq "iteration_exhaustion: 2 retries by default" "2" "$(get_max_retries_for_class iteration_exhaustion)"
assert_eq "iteration_exhaustion: MAX_RETRIES_ITERATION_EXHAUSTION override" "1" "$(MAX_RETRIES_ITERATION_EXHAUSTION=1 get_max_retries_for_class iteration_exhaustion)"
assert_eq "invalid_issue: 0 retries" "0" "$(get_max_retries_for_class invalid_issue)"
assert_eq "api_error: default 4 retries" "4" "$(get_max_retries_for_class api_error)"
assert_eq "context_exhaustion: 2 retries" "2" "$(get_max_retries_for_class context_exhaustion)"
assert_eq "build_failure: 2 retries" "2" "$(get_max_retries_for_class build_failure)"
assert_eq "unknown: default 2 retries" "2" "$(get_max_retries_for_class unknown)"

# Custom overrides via env vars
MAX_RETRIES_API_ERROR=6 assert_eq "Custom api_error retries" "6" "$(MAX_RETRIES_API_ERROR=6 get_max_retries_for_class api_error)"
MAX_RETRIES=5 assert_eq "Custom default retries" "5" "$(MAX_RETRIES=5 get_max_retries_for_class unknown)"

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
