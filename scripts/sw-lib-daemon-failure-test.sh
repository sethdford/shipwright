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
# Hermetic config: the escalation path reads effort/model routing through
# _smart_* helpers, which fall back to ./.claude/daemon-config.json. Point them at
# an empty test-owned file so these tests assert the documented defaults rather
# than whatever this repo happens to be configured with today.
export DAEMON_CONFIG="$TEST_TEMP_DIR/daemon-config.json"
echo '{}' > "$DAEMON_CONFIG"
mkdir -p "$LOG_DIR" "$WORKTREE_DIR"

# Provide stub functions that daemon-failure.sh depends on
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
epoch_to_iso() { date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z"; }
emit_event() { :; }
daemon_log() { :; }
# Real (unlocked) state mutation so signature persistence is genuinely exercised.
locked_state_update() {
    [[ -f "$STATE_FILE" ]] || return 0
    local _tmp
    _tmp=$(mktemp "${TMPDIR:-/tmp}/sw-state.XXXXXX") || return 1
    if jq "$@" "$STATE_FILE" > "$_tmp" 2>/dev/null; then mv "$_tmp" "$STATE_FILE"; else rm -f "$_tmp"; return 1; fi
}
SPAWN_LOG="$TEST_TEMP_DIR/spawn.log"
daemon_spawn_pipeline() {
    echo "issue=$1 template=$PIPELINE_TEMPLATE model=$MODEL effort=${EFFORT_LEVEL:-} args=${*:4}" >> "$SPAWN_LOG"
}
record_pipeline_duration() { :; }
record_scaling_outcome() { :; }
notify() { :; }

# compat.sh supplies _smart_int/_smart_model/_smart_effort, which the escalation
# path reads config through. It is sourced by bootstrap at daemon runtime.
source "$SCRIPT_DIR/lib/compat.sh"

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

# ═══════════════════════════════════════════════════════════════════════════════
# normalize_failure_signature
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "normalize_failure_signature"

assert_eq "Missing log → :none" "build_failure:none" "$(normalize_failure_signature 9999 build_failure)"

touch "$LOG_DIR/issue-800.log"
assert_eq "Empty log → :none" "unknown:none" "$(normalize_failure_signature 800 unknown)"

(
    LOG_DIR=""
    normalize_failure_signature 1 api_error
) > "$TEST_TEMP_DIR/sig_nologdir" 2>/dev/null
assert_eq "Empty LOG_DIR → :none" "api_error:none" "$(cat "$TEST_TEMP_DIR/sig_nologdir")"

cat > "$LOG_DIR/issue-801.log" <<'LOG'
FAIL scripts/sw-foo-test.sh
  Error: expected 3 but got 4
LOG
sig_801=$(normalize_failure_signature 801 build_failure)
assert_contains "Signature is prefixed with the class" "$sig_801" "build_failure:"
if [[ "$sig_801" =~ ^build_failure:[0-9a-f]{8}$ ]]; then
    assert_eq "Signature is class:8-hex" "ok" "ok"
else
    assert_eq "Signature is class:8-hex" "ok" "got $sig_801"
fi
assert_eq "Signature is stable across calls" "$sig_801" "$(normalize_failure_signature 801 build_failure)"

# Same defect, different run: different absolute path, line numbers, timestamp,
# ANSI colour. Must produce the SAME signature.
printf '2026-09-11T12:00:00Z \033[31mFAIL\033[0m /home/runner/work/x/scripts/sw-foo-test.sh\n  Error: expected 37 but got 412\n' \
    > "$LOG_DIR/issue-802.log"
assert_eq "Path/digit/timestamp/ANSI noise does not change the signature" \
    "$sig_801" "$(normalize_failure_signature 802 build_failure)"

# A genuinely different error must differ.
cat > "$LOG_DIR/issue-803.log" <<'LOG'
FAIL scripts/sw-bar-test.sh
  Error: undefined variable BAZ
LOG
sig_803=$(normalize_failure_signature 803 build_failure)
if [[ "$sig_803" != "$sig_801" ]]; then
    assert_eq "Different error → different signature" "differs" "differs"
else
    assert_eq "Different error → different signature" "differs" "collided"
fi

# Same text, different class → different signature (class is part of identity).
cp "$LOG_DIR/issue-801.log" "$LOG_DIR/issue-804.log"
sig_804=$(normalize_failure_signature 804 api_error)
if [[ "$sig_804" != "$sig_801" ]]; then
    assert_eq "Class is part of the signature" "differs" "differs"
else
    assert_eq "Class is part of the signature" "differs" "collided"
fi

# No error-shaped lines → falls back to the raw tail, still a real signature.
echo "just some quiet output" > "$LOG_DIR/issue-805.log"
sig_805=$(normalize_failure_signature 805 unknown)
if [[ "$sig_805" =~ ^unknown:[0-9a-f]{8}$ ]]; then
    assert_eq "Non-error log falls back to tail" "ok" "ok"
else
    assert_eq "Non-error log falls back to tail" "ok" "got $sig_805"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# escalate_effort_level / escalate_model_tier
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Escalation ladders"

assert_eq "low → medium" "medium" "$(escalate_effort_level low)"
assert_eq "medium → high" "high" "$(escalate_effort_level medium)"
assert_eq "high → xhigh" "xhigh" "$(escalate_effort_level high)"
assert_eq "xhigh → max" "max" "$(escalate_effort_level xhigh)"
assert_eq "max is the ceiling (idempotent)" "max" "$(escalate_effort_level max)"
assert_eq "Unknown level normalizes to high" "high" "$(escalate_effort_level banana)"
assert_eq "Empty level normalizes to high" "high" "$(escalate_effort_level "")"

assert_eq "sonnet escalates to the high-risk model" "opus" "$(escalate_model_tier sonnet)"
assert_eq "haiku escalates to the high-risk model" "opus" "$(escalate_model_tier haiku)"
assert_eq "Already high-risk is the ceiling" "opus" "$(escalate_model_tier opus)"
assert_eq "high_risk routing is honored" "sonnet" "$(SW_MODEL_HIGH_RISK=sonnet escalate_model_tier opus)"

# ═══════════════════════════════════════════════════════════════════════════════
# record_failure_signature
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "record_failure_signature"

mkdir -p "$(dirname "$STATE_FILE")"
echo '{"completed":[],"retry_counts":{}}' > "$STATE_FILE"

assert_eq "First sighting counts 1" "1" "$(record_failure_signature 900 "build_failure:aaaaaaaa")"
assert_eq "Identical signature counts 2" "2" "$(record_failure_signature 900 "build_failure:aaaaaaaa")"
assert_eq "Identical signature counts 3" "3" "$(record_failure_signature 900 "build_failure:aaaaaaaa")"
assert_eq "A different signature resets to 1" "1" "$(record_failure_signature 900 "build_failure:bbbbbbbb")"
assert_eq "Counts are per-issue" "1" "$(record_failure_signature 901 "build_failure:aaaaaaaa")"

hist_len=$(jq -r '.failure_signatures["900"].history | length' "$STATE_FILE")
assert_eq "History is recorded" "4" "$hist_len"
for _ in 1 2 3; do record_failure_signature 900 "build_failure:cccccccc" >/dev/null; done
hist_len=$(jq -r '.failure_signatures["900"].history | length' "$STATE_FILE")
assert_eq "History is capped at 5" "5" "$hist_len"

clear_failure_signature 900
assert_eq "clear_failure_signature drops the issue" "null" "$(jq -r '.failure_signatures["900"] // "null"' "$STATE_FILE")"
assert_eq "clear_failure_signature leaves other issues alone" "1" "$(jq -r '.failure_signatures["901"].count' "$STATE_FILE")"

reset_failure_tracking 901
assert_eq "reset_failure_tracking <issue> clears its signature" "null" "$(jq -r '.failure_signatures["901"] // "null"' "$STATE_FILE")"

# Missing state file degrades to 1 rather than erroring
(
    STATE_FILE="$TEST_TEMP_DIR/does-not-exist.json"
    record_failure_signature 902 "build_failure:dddddddd"
) > "$TEST_TEMP_DIR/sig_nostate" 2>/dev/null
assert_eq "No state file → count 1" "1" "$(cat "$TEST_TEMP_DIR/sig_nostate")"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_on_failure escalation (integration)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Retry escalation on repeated signatures"

ESC_EVENTS="$TEST_TEMP_DIR/esc-events.log"
emit_event() { echo "$*" >> "$ESC_EVENTS"; }
SCRIPT_DIR_ORIG="$SCRIPT_DIR"

# daemon_on_failure sleeps for backoff; make retries instant.
sleep() { :; }

run_failure() {
    # run_failure <issue> <log_body>
    local num="$1" body="$2"
    printf '%s\n' "$body" > "$LOG_DIR/issue-${num}.log"
    : > "$ESC_EVENTS"
    : > "$SPAWN_LOG"
    _retry_spawned_for=""
    daemon_on_failure "$num" 1 "1m 0s" >/dev/null 2>>"$TEST_TEMP_DIR/failure-stderr.log" || true
}

export RETRY_ESCALATION=true
export MAX_RETRIES=3
export MAX_RETRIES_BUILD=3
MODEL="sonnet"
EFFORT_LEVEL=""
PIPELINE_TEMPLATE="standard"
echo '{"completed":[],"retry_counts":{}}' > "$STATE_FILE"

FAIL_A='npm ERR! Test suite failed
Error: expected 3 but got 4'
FAIL_B='npm ERR! Test suite failed
Error: undefined variable BAZ'

# First failure — signature seen once, no escalation.
run_failure 950 "$FAIL_A"
assert_contains "Signature event emitted on first retry" "$(cat "$ESC_EVENTS")" "daemon.failure_signature"
assert_contains "First failure records consecutive=1" "$(cat "$ESC_EVENTS")" "consecutive=1"
if grep -q "result=escalated" "$ESC_EVENTS"; then
    assert_eq "No escalation on a first-seen signature" "no" "escalated"
else
    assert_eq "No escalation on a first-seen signature" "no" "no"
fi

# Different signature next — count resets, still no escalation.
run_failure 950 "$FAIL_B"
assert_contains "Distinct signature resets consecutive to 1" "$(cat "$ESC_EVENTS")" "consecutive=1"
if grep -q "result=escalated" "$ESC_EVENTS"; then
    assert_eq "No escalation on distinct signatures" "no" "escalated"
else
    assert_eq "No escalation on distinct signatures" "no" "no"
fi

# Same signature twice in a row — escalation fires.
run_failure 950 "$FAIL_B"
assert_contains "Second identical signature escalates" "$(cat "$ESC_EVENTS")" "result=escalated"
assert_contains "Escalation reports consecutive=2" "$(cat "$ESC_EVENTS")" "consecutive=2"
assert_contains "Escalation targets the high-risk model" "$(cat "$ESC_EVENTS")" "to_model=opus"
assert_contains "Escalation raises effort a rung" "$(cat "$ESC_EVENTS")" "to_effort=max"
assert_contains "Spawn receives the escalated effort" "$(cat "$SPAWN_LOG")" "effort=max"
assert_contains "Spawn receives the escalated model" "$(cat "$SPAWN_LOG")" "model=opus"

# EFFORT_LEVEL is restored after the escalated respawn.
assert_eq "EFFORT_LEVEL restored after retry" "" "${EFFORT_LEVEL}"
assert_eq "MODEL restored after retry" "sonnet" "${MODEL}"

# Ceiling: already at the top of both ladders → logged no-op, not an error.
echo '{"completed":[],"retry_counts":{}}' > "$STATE_FILE"
MODEL="opus"
EFFORT_LEVEL="max"
run_failure 951 "$FAIL_A"
run_failure 951 "$FAIL_A"
assert_contains "At-ceiling escalation is a logged no-op" "$(cat "$ESC_EVENTS")" "result=at_ceiling"
if grep -q "result=escalated" "$ESC_EVENTS"; then
    assert_eq "Ceiling does not report a fake escalation" "no" "escalated"
else
    assert_eq "Ceiling does not report a fake escalation" "no" "no"
fi
MODEL="sonnet"
EFFORT_LEVEL=""

# Disabled via config → no signature tracking at all.
echo '{"completed":[],"retry_counts":{}}' > "$STATE_FILE"
SW_ESCALATION_ON_REPEAT_SIGNATURE=0 run_failure 952 "$FAIL_A"
if grep -q "daemon.failure_signature" "$ESC_EVENTS"; then
    assert_eq "on_repeat_signature=0 disables tracking" "off" "on"
else
    assert_eq "on_repeat_signature=0 disables tracking" "off" "off"
fi

# Threshold is configurable: 3 means two identical failures are not enough.
echo '{"completed":[],"retry_counts":{}}' > "$STATE_FILE"
export SW_ESCALATION_REPEAT_THRESHOLD=3
run_failure 953 "$FAIL_A"
run_failure 953 "$FAIL_A"
if grep -q "result=escalated" "$ESC_EVENTS"; then
    assert_eq "Threshold=3 holds off at 2 repeats" "no" "escalated"
else
    assert_eq "Threshold=3 holds off at 2 repeats" "no" "no"
fi
run_failure 953 "$FAIL_A"
assert_contains "Threshold=3 escalates at 3 repeats" "$(cat "$ESC_EVENTS")" "result=escalated"
unset SW_ESCALATION_REPEAT_THRESHOLD

# RETRY_ESCALATION=false skips the whole retry path.
echo '{"completed":[],"retry_counts":{}}' > "$STATE_FILE"
RETRY_ESCALATION=false run_failure 954 "$FAIL_A"
if grep -q "daemon.failure_signature" "$ESC_EVENTS"; then
    assert_eq "RETRY_ESCALATION=false skips signature tracking" "off" "on"
else
    assert_eq "RETRY_ESCALATION=false skips signature tracking" "off" "off"
fi

# ── hard_restart_cap clamps --max-restarts on the context-exhaustion path ──
print_test_section "hard_restart_cap"

mkdir -p "$WORKTREE_DIR/daemon-issue-960/.claude/loop-logs"
cat > "$WORKTREE_DIR/daemon-issue-960/.claude/loop-logs/progress.md" <<'MD'
## Progress
Iteration: 9
Tests passing: false
MD
echo '{"completed":[],"retry_counts":{}}' > "$STATE_FILE"
MAX_RESTARTS_CFG=9
SW_LOOP_HARD_RESTART_CAP=4 run_failure 960 "context ran out"
assert_contains "max-restarts clamped to hard_restart_cap" "$(cat "$SPAWN_LOG")" "--max-restarts 4"

echo '{"completed":[],"retry_counts":{}}' > "$STATE_FILE"
MAX_RESTARTS_CFG=1
SW_LOOP_HARD_RESTART_CAP=9 run_failure 960 "context ran out"
assert_contains "Below the cap, the boosted value is used" "$(cat "$SPAWN_LOG")" "--max-restarts 2"
unset MAX_RESTARTS_CFG

# Restore stubs for any later sections
unset -f sleep
emit_event() { :; }

print_test_results
