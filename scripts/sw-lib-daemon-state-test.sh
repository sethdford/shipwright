#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon-state test — Unit tests for state management      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: daemon-state Tests"

setup_test_env "sw-lib-daemon-state-test"
trap cleanup_test_env EXIT

# Set up daemon env
export STATE_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
export LOG_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon.log"
export DAEMON_DIR="$TEST_TEMP_DIR/home/.shipwright"
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
export PAUSE_FLAG="$TEST_TEMP_DIR/home/.shipwright/daemon.pause"
export DASHBOARD_URL="http://localhost:9999"
export NO_GITHUB=true
export POLL_INTERVAL=60
export MAX_PARALLEL=2
export WATCH_LABEL="shipwright"
export WATCH_MODE="label"
export BASE_BRANCH="main"
export PRIORITY_LANE_LABELS="urgent,p0"
export SLACK_WEBHOOK=""
# shellcheck disable=SC2034
DAEMON_LOG_WRITE_COUNT=0

touch "$LOG_FILE"
mock_git
mock_gh
mock_claude

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
info() { echo -e "▸ $*"; }
success() { echo -e "✓ $*"; }
warn() { echo -e "⚠ $*"; }
error() { echo -e "✗ $*" >&2; }

# Source the lib (clear guard)
_DAEMON_STATE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-state.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# atomic_write_state
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "atomic_write_state"

atomic_write_state '{"test": true}'
assert_file_exists "State file created" "$STATE_FILE"
result=$(jq -r '.test' "$STATE_FILE")
assert_eq "State file has correct content" "true" "$result"

# Overwrite
atomic_write_state '{"test": false, "version": 1}'
result=$(jq -r '.test' "$STATE_FILE")
assert_eq "State file overwritten" "false" "$result"
result=$(jq -r '.version' "$STATE_FILE")
assert_eq "State file has new field" "1" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# locked_state_update
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "locked_state_update"

atomic_write_state '{"queued":[],"active_jobs":[],"completed":[]}'

locked_state_update '.queued += [42]'
result=$(jq -r '.queued | length' "$STATE_FILE")
assert_eq "locked_state_update adds to queue" "1" "$result"
result=$(jq -r '.queued[0]' "$STATE_FILE")
assert_eq "Queue contains issue 42" "42" "$result"

locked_state_update '.queued += [43]'
result=$(jq -r '.queued | length' "$STATE_FILE")
assert_eq "Queue now has 2 items" "2" "$result"

# With args
locked_state_update --arg key "test_key" --arg val "test_val" '.[$key] = $val'
result=$(jq -r '.test_key' "$STATE_FILE")
assert_eq "locked_state_update with --arg" "test_val" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# init_state
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "init_state"

rm -f "$STATE_FILE"
init_state

assert_file_exists "init_state creates state file" "$STATE_FILE"

result=$(jq -r '.version' "$STATE_FILE")
assert_eq "State version is 1" "1" "$result"

result=$(jq -r '.config.poll_interval' "$STATE_FILE")
assert_eq "Config poll_interval is 60" "60" "$result"

result=$(jq -r '.config.max_parallel' "$STATE_FILE")
assert_eq "Config max_parallel is 2" "2" "$result"

result=$(jq -r '.config.watch_label' "$STATE_FILE")
assert_eq "Config watch_label is shipwright" "shipwright" "$result"

result=$(jq -r '.active_jobs | length' "$STATE_FILE")
assert_eq "Active jobs initially empty" "0" "$result"

result=$(jq -r '.queued | length' "$STATE_FILE")
assert_eq "Queue initially empty" "0" "$result"

result=$(jq -r '.completed | length' "$STATE_FILE")
assert_eq "Completed initially empty" "0" "$result"

# Re-init updates PID
# shellcheck disable=SC2034
old_pid=$(jq -r '.pid' "$STATE_FILE")
init_state
new_pid=$(jq -r '.pid' "$STATE_FILE")
assert_eq "Re-init updates PID" "$$" "$new_pid"

# ═══════════════════════════════════════════════════════════════════════════════
# enqueue_issue / dequeue_next
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "enqueue_issue / dequeue_next"

rm -f "$STATE_FILE"
init_state

enqueue_issue 10
enqueue_issue 20
enqueue_issue 30

result=$(jq -r '.queued | length' "$STATE_FILE")
assert_eq "3 issues queued" "3" "$result"

# Dequeue returns first
next=$(dequeue_next)
assert_eq "Dequeue returns first item" "10" "$next"

next=$(dequeue_next)
assert_eq "Second dequeue returns 20" "20" "$next"

# Queue now has 1 item
result=$(jq -r '.queued | length' "$STATE_FILE")
assert_eq "Queue has 1 remaining" "1" "$result"

next=$(dequeue_next)
assert_eq "Third dequeue returns 30" "30" "$next"

# Empty queue returns nothing
next=$(dequeue_next)
assert_eq "Empty queue returns empty" "" "$next"

# Enqueue deduplicates
enqueue_issue 42
enqueue_issue 42
result=$(jq -r '.queued | length' "$STATE_FILE")
assert_eq "Duplicate enqueue deduplicated" "1" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_is_inflight
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_is_inflight"

rm -f "$STATE_FILE"
init_state

# Not inflight initially
if daemon_is_inflight 42; then
    assert_fail "Issue 42 not inflight initially"
else
    assert_pass "Issue 42 not inflight initially"
fi

# Add to queue
enqueue_issue 42
if daemon_is_inflight 42; then
    assert_pass "Issue 42 inflight after enqueue"
else
    assert_fail "Issue 42 inflight after enqueue"
fi

# Add to active_jobs
locked_state_update '.active_jobs += [{"issue": 99, "pid": 1234}]'
if daemon_is_inflight 99; then
    assert_pass "Issue 99 inflight (active job)"
else
    assert_fail "Issue 99 inflight (active job)"
fi

# Non-existent issue
if daemon_is_inflight 777; then
    assert_fail "Issue 777 not inflight"
else
    assert_pass "Issue 777 not inflight"
fi

# No state file
rm -f "$STATE_FILE"
if daemon_is_inflight 42; then
    assert_fail "No state file → not inflight"
else
    assert_pass "No state file → not inflight"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# get_active_count / locked_get_active_count
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "get_active_count"

rm -f "$STATE_FILE"

# No state file
result=$(get_active_count)
assert_eq "No state file → 0 active" "0" "$result"

init_state
result=$(get_active_count)
assert_eq "Empty state → 0 active" "0" "$result"

locked_state_update '.active_jobs += [{"issue": 1, "pid": 111}]'
result=$(get_active_count)
assert_eq "1 active job" "1" "$result"

locked_state_update '.active_jobs += [{"issue": 2, "pid": 222}]'
result=$(get_active_count)
assert_eq "2 active jobs" "2" "$result"

result=$(locked_get_active_count)
assert_eq "locked_get_active_count matches" "2" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# update_state_field
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "update_state_field"

rm -f "$STATE_FILE"
init_state

update_state_field "last_poll" "2026-01-01T00:00:00Z"
result=$(jq -r '.last_poll' "$STATE_FILE")
assert_eq "Field updated" "2026-01-01T00:00:00Z" "$result"

update_state_field "custom_field" "custom_value"
result=$(jq -r '.custom_field' "$STATE_FILE")
assert_eq "Custom field added" "custom_value" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_log
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_log"

: > "$LOG_FILE"
daemon_log INFO "test log message" 2>/dev/null
log_content=$(cat "$LOG_FILE")
assert_contains "Log has message" "$log_content" "test log message"
assert_contains "Log has INFO level" "$log_content" "[INFO]"
assert_contains_regex "Log has timestamp" "$log_content" '\[20[0-9]{2}-'

# ═══════════════════════════════════════════════════════════════════════════════
# gh_rate_limited / gh_record_success / gh_record_failure
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "GitHub rate limit circuit breaker"

GH_CONSECUTIVE_FAILURES=0
GH_BACKOFF_UNTIL=0

# Initially not rate limited
if gh_rate_limited; then
    assert_fail "Not rate limited initially"
else
    assert_pass "Not rate limited initially"
fi

# Record successes — still not limited
gh_record_success
assert_eq "Success resets failure count" "0" "$GH_CONSECUTIVE_FAILURES"

# 2 failures — not yet limited
gh_record_failure
gh_record_failure
if gh_rate_limited; then
    assert_fail "2 failures not yet limited"
else
    assert_pass "2 failures not yet limited"
fi

# 3rd failure triggers backoff
gh_record_failure
assert_eq "3 consecutive failures" "3" "$GH_CONSECUTIVE_FAILURES"
if [[ "$GH_BACKOFF_UNTIL" -gt 0 ]]; then
    assert_pass "Backoff set after 3 failures"
else
    assert_fail "Backoff set after 3 failures"
fi

# Record success resets everything
gh_record_success
assert_eq "Success resets failures" "0" "$GH_CONSECUTIVE_FAILURES"
assert_eq "Success resets backoff" "0" "$GH_BACKOFF_UNTIL"

# ═══════════════════════════════════════════════════════════════════════════════
# is_priority_issue
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "is_priority_issue"

PRIORITY_LANE_LABELS="urgent,p0"

if is_priority_issue "urgent,enhancement"; then
    assert_pass "urgent label is priority"
else
    assert_fail "urgent label is priority"
fi

if is_priority_issue "bug,p0"; then
    assert_pass "p0 label is priority"
else
    assert_fail "p0 label is priority"
fi

if is_priority_issue "bug,enhancement"; then
    assert_fail "non-priority labels"
else
    assert_pass "non-priority labels not flagged"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Priority lane tracking
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Priority lane tracking"

rm -f "$STATE_FILE"
init_state

result=$(get_priority_active_count)
assert_eq "Initially 0 priority jobs" "0" "$result"

track_priority_job 42
result=$(get_priority_active_count)
assert_eq "1 priority job after track" "1" "$result"

track_priority_job 42
result=$(get_priority_active_count)
assert_eq "Duplicate track still 1" "1" "$result"

track_priority_job 43
result=$(get_priority_active_count)
assert_eq "2 priority jobs" "2" "$result"

untrack_priority_job 42
result=$(get_priority_active_count)
assert_eq "1 priority job after untrack" "1" "$result"

untrack_priority_job 43
result=$(get_priority_active_count)
assert_eq "0 priority jobs after all untracked" "0" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# claim_issue / release_claim in NO_GITHUB mode
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "claim_issue (NO_GITHUB mode)"

if claim_issue 42 "my-machine"; then
    assert_pass "claim_issue succeeds in NO_GITHUB mode"
else
    assert_fail "claim_issue succeeds in NO_GITHUB mode"
fi

if release_claim 42 "my-machine"; then
    assert_pass "release_claim succeeds in NO_GITHUB mode"
else
    assert_fail "release_claim succeeds in NO_GITHUB mode"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# claim_issue / release_claim against the dashboard (fleet token, fail closed)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "claim_issue / release_claim (dashboard, fleet token)"

# Recording curl: argv one element per line in $CURL_ARGS, stdin in $CURL_STDIN when curl reads
# a file from stdin (@-). Prints $CURL_BODY (unless -o /dev/null), then the -w format with %{http_code} = $CURL_CODE.
export CURL_ARGS="$TEST_TEMP_DIR/curl.args" CURL_STDIN="$TEST_TEMP_DIR/curl.stdin"
export CURL_BODY="" CURL_CODE="200" CURL_EXIT=0
mock_binary "curl" 'printf "%s\n" "$@" > "$CURL_ARGS"
fmt=""; prev=""; to_null=""
for a in "$@"; do
    [[ "$a" == "@-" ]] && cat > "$CURL_STDIN"
    [[ "$prev" == "-w" ]] && fmt="$a"
    [[ "$prev" == "-o" && "$a" == "/dev/null" ]] && to_null=1
    prev="$a"
done
[[ -z "$to_null" ]] && printf "%s" "$CURL_BODY"
[[ -n "$fmt" ]] && printf "%b" "${fmt//%\{http_code\}/$CURL_CODE}"
exit "$CURL_EXIT"'
# Recording gh: `issue view` prints $GH_VIEW_OUT when set, else no claim before our --add-label
# and only ours after it.
export GH_LOG="$TEST_TEMP_DIR/gh.log"
mock_binary "gh" 'printf "%s " "$@" >> "$GH_LOG"; printf "\n" >> "$GH_LOG"
if [[ "${1:-} ${2:-}" == "issue view" ]]; then
    if [[ -n "${GH_VIEW_OUT:-}" ]]; then echo "$GH_VIEW_OUT"
    elif grep -q -- "--add-label" "$GH_LOG"; then echo "[\"claimed:my-machine\"]"
    else echo ""; fi
fi
exit 0'

reset_fleet() {
    rm -f "$CURL_ARGS" "$CURL_STDIN"
    : > "$GH_LOG"
    : > "$LOG_FILE"
    CURL_BODY="" CURL_CODE="200" CURL_EXIT=0 GH_VIEW_OUT=""
    export CURL_BODY CURL_CODE CURL_EXIT GH_VIEW_OUT
}
added_label() { grep -c -- "--add-label" "$GH_LOG" || true; }

export SHIPWRIGHT_FLEET_TOKEN="fleet-s3cret"

reset_fleet
CURL_BODY='{"error":"unauthorized"}' CURL_CODE=401
if NO_GITHUB=false claim_issue 42 "my-machine"; then
    assert_fail "401 from the dashboard: claim not acquired"
else
    assert_pass "401 from the dashboard: claim not acquired"
fi
assert_eq "401: no GitHub label fallback (fail closed)" "0" "$(added_label)"
assert_contains "401 is logged" "$(cat "$LOG_FILE")" "401"
assert_eq "claim sends the token on stdin" "X-Shipwright-Token: fleet-s3cret" "$(cat "$CURL_STDIN" 2>/dev/null || true)"
assert_eq "claim never puts the token in argv" "0" "$(grep -c 'fleet-s3cret' "$CURL_ARGS" || true)"
assert_eq "the token never reaches the daemon log" "0" "$(grep -c 'fleet-s3cret' "$LOG_FILE" || true)"

reset_fleet
CURL_BODY='{"error":"forbidden"}' CURL_CODE=403
if NO_GITHUB=false claim_issue 42 "my-machine"; then
    assert_fail "403 from the dashboard: claim not acquired"
else
    assert_pass "403 from the dashboard: claim not acquired"
fi
assert_eq "403: no GitHub label fallback" "0" "$(added_label)"

reset_fleet
CURL_BODY='{"approved":true,"claimed_by":"my-machine"}' CURL_CODE=200 GH_VIEW_OUT='["claimed:my-machine"]'
if NO_GITHUB=false claim_issue 42 "my-machine"; then
    assert_pass "200 approved: claim acquired"
else
    assert_fail "200 approved: claim acquired"
fi
assert_eq "200 approved: no direct GitHub label write" "0" "$(added_label)"

reset_fleet
CURL_BODY='{"approved":false,"claimed_by":"other"}' CURL_CODE=200
if NO_GITHUB=false claim_issue 42 "my-machine"; then
    assert_fail "200 not approved: claim not acquired"
else
    assert_pass "200 not approved: claim not acquired"
fi
assert_eq "200 not approved: no GitHub label write" "0" "$(added_label)"

reset_fleet
CURL_BODY='{"approved":false,"error":"boom"}' CURL_CODE=500
NO_GITHUB=false claim_issue 42 "my-machine" || true
assert_eq "5xx approved:false is a dashboard error, not 'claimed elsewhere' (GitHub fallback)" "1" "$(added_label)"
assert_contains "5xx: the dashboard error is logged" "$(cat "$LOG_FILE")" "dashboard claim error (HTTP 500): boom"
assert_contains "5xx: fallback names the status" "$(cat "$LOG_FILE")" "Dashboard unavailable (HTTP 500)"

reset_fleet
CURL_CODE=000 CURL_EXIT=7 GH_VIEW_OUT='["claimed:my-machine"]'
if NO_GITHUB=false claim_issue 42 "my-machine"; then
    assert_pass "fallback: our own existing claim label is ours"
else
    assert_fail "fallback: our own existing claim label is ours"
fi
assert_eq "fallback: own claim is not re-added" "0" "$(added_label)"

reset_fleet
CURL_CODE=000 CURL_EXIT=7 GH_VIEW_OUT='["claimed:other-machine"]'
if NO_GITHUB=false claim_issue 42 "my-machine"; then
    assert_fail "fallback: another machine's claim label blocks"
else
    assert_pass "fallback: another machine's claim label blocks"
fi
assert_eq "fallback: no label added over another claim" "0" "$(added_label)"

reset_fleet
CURL_BODY='{"approved":true}' CURL_CODE=502
NO_GITHUB=false claim_issue 42 "my-machine" || true
assert_eq "approved:true on a non-2xx is not trusted (falls back to the GitHub label claim)" "1" "$(added_label)"

reset_fleet
CURL_CODE=000 CURL_EXIT=7
if NO_GITHUB=false claim_issue 42 "my-machine"; then
    assert_pass "unreachable dashboard: GitHub label fallback claims"
else
    assert_fail "unreachable dashboard: GitHub label fallback claims"
fi
assert_eq "unreachable dashboard: label added once" "1" "$(added_label)"
assert_contains "unreachable dashboard: fallback names the status" "$(cat "$LOG_FILE")" "Dashboard unavailable (HTTP 000)"

reset_fleet
CURL_BODY='{"approved":true}' CURL_CODE=200
if SHIPWRIGHT_FLEET_TOKEN="" SHIPWRIGHT_FLEET_TOKEN_FILE="$TEST_TEMP_DIR/missing.token" \
    NO_GITHUB=false claim_issue 42 "my-machine" 2>/dev/null; then
    assert_fail "unusable token file: claim not acquired"
else
    assert_pass "unusable token file: claim not acquired"
fi
assert_file_not_exists "unusable token file: curl never runs" "$CURL_ARGS"
assert_eq "unusable token file: no GitHub label fallback" "0" "$(added_label)"

reset_fleet
CURL_BODY='{"error":"unauthorized"}' CURL_CODE=401
if NO_GITHUB=false release_claim 42 "my-machine"; then
    assert_pass "release is best-effort (401 does not fail it)"
else
    assert_fail "release is best-effort (401 does not fail it)"
fi
assert_eq "release sends the token on stdin" "X-Shipwright-Token: fleet-s3cret" "$(cat "$CURL_STDIN" 2>/dev/null || true)"
assert_eq "release never puts the token in argv" "0" "$(grep -c 'fleet-s3cret' "$CURL_ARGS" || true)"
assert_contains "release 401 is logged" "$(cat "$LOG_FILE")" "401"
assert_eq "release still removes the label directly" "1" "$(grep -c -- '--remove-label claimed:my-machine' "$GH_LOG" || true)"

reset_fleet
SHIPWRIGHT_FLEET_TOKEN="" SHIPWRIGHT_FLEET_TOKEN_FILE="$TEST_TEMP_DIR/missing.token" \
    NO_GITHUB=false release_claim 42 "my-machine" 2>/dev/null || true
assert_contains "release with an unusable token file logs it" "$(cat "$LOG_FILE")" "fleet token unusable"
assert_file_not_exists "release with an unusable token file: curl never runs" "$CURL_ARGS"
assert_eq "release with an unusable token file still removes the label" "1" "$(grep -c -- '--remove-label claimed:my-machine' "$GH_LOG" || true)"

unset SHIPWRIGHT_FLEET_TOKEN
reset_fleet
CURL_BODY='{"approved":true}' CURL_CODE=200 GH_VIEW_OUT='["claimed:my-machine"]'
NO_GITHUB=false claim_issue 42 "my-machine" || true
assert_eq "no token configured: no header on stdin" "" "$(cat "$CURL_STDIN" 2>/dev/null || true)"
assert_eq "no token configured: no -H @- in argv" "0" "$(grep -c -x '@-' "$CURL_ARGS" || true)"

print_test_results
