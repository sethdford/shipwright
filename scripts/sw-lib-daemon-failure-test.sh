#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon-failure test — Unit tests for failure handling     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: daemon-failure Tests"

setup_test_env "sw-lib-daemon-failure-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

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
source "$SCRIPT_DIR/lib/compat.sh"
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

echo "gh: Could not resolve to an Issue with the number 302" > "$LOG_DIR/issue-302.log"
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
# Auto-retry passes its retry number to the safety gates (fix-loop cap)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Auto-retry passes its retry number"

(
    SPAWN_LOG="$TEST_TEMP_DIR/spawn.log"
    : > "$SPAWN_LOG"
    daemon_spawn_pipeline() { echo "issue=$1 title=$2 retry=${DAEMON_RETRY_ATTEMPT:-unset}" >> "$SPAWN_LOG"; }
    sleep() { :; }
    MODEL="sonnet"
    PIPELINE_TEMPLATE="autonomous"
    echo '{"retry_counts":{"801":1}}' > "$STATE_FILE"
    echo "some unclassified failure" > "$LOG_DIR/issue-801.log"
    daemon_on_failure 801 1 "" >/dev/null 2>&1
    cat "$SPAWN_LOG"
    # Checked inside the subshell, where daemon_on_failure ran
    echo "after=${DAEMON_RETRY_ATTEMPT:-unset}"
) > "$TEST_TEMP_DIR/retry_spawn_result" 2>/dev/null || true
assert_eq "second retry spawns with DAEMON_RETRY_ATTEMPT=2" \
    "issue=801 title=retry-2 retry=2" "$(head -1 "$TEST_TEMP_DIR/retry_spawn_result")"
assert_eq "DAEMON_RETRY_ATTEMPT does not leak past the retry spawn" \
    "after=unset" "$(tail -1 "$TEST_TEMP_DIR/retry_spawn_result")"

# ═══════════════════════════════════════════════════════════════════════════════
# A retry refused by the safety gates is a final failure (no re-poll past the cap)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Refused retry is a final failure"

# run_refused_failure <issue> <gh-mock-script> — daemon_on_failure with a refused retry spawn,
# real state updates and a gh mock; everything lands in $TEST_TEMP_DIR/refuse.log.
run_refused_failure() {
    local issue="$1" gh_script="$2"
    (
        REFUSE_LOG="$TEST_TEMP_DIR/refuse.log"
        : > "$REFUSE_LOG"
        export REFUSE_LOG
        mock_binary "gh" "$gh_script"
        SCRIPT_DIR="$TEST_TEMP_DIR/refuse-scripts"
        mkdir -p "$SCRIPT_DIR"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$SCRIPT_DIR/sw-tracker.sh"
        chmod +x "$SCRIPT_DIR/sw-tracker.sh"
        NO_GITHUB=false
        daemon_spawn_pipeline() { echo "spawn $1 retry=${DAEMON_RETRY_ATTEMPT:-unset} repo=${3:-}" >> "$REFUSE_LOG"; return "${RETRY_SPAWN_RC:-75}"; }
        daemon_log() { echo "log $1 ${*:2}" >> "$REFUSE_LOG"; }
        locked_state_update() {
            local tmp
            tmp=$(mktemp)
            jq "$@" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
        }
        sleep() { :; }
        MODEL="sonnet"
        PIPELINE_TEMPLATE="autonomous"
        _retry_spawned_for=""
        jq -n --arg n "$issue" '{retry_counts: {($n): 1}}' > "$STATE_FILE"
        echo "${RUN_LOG_TEXT:-some unclassified failure}" > "$LOG_DIR/issue-${issue}.log"
        daemon_on_failure "$issue" 1 "" "${REFUSE_REPO:-}" >/dev/null 2>&1
        echo "spawned_for=${_retry_spawned_for:-none} template=${PIPELINE_TEMPLATE} model=${MODEL}" >> "$REFUSE_LOG"
    ) 2>/dev/null || true
}

run_refused_failure 802 'printf "gh %s\n" "$*" >> "$REFUSE_LOG"'
refuse_log="$(cat "$TEST_TEMP_DIR/refuse.log")"
assert_contains "the retry spawn was attempted" "$refuse_log" "spawn 802 retry=2"
assert_contains "a gate/budget refusal (75) is logged as a final failure" "$refuse_log" \
    "Retry #2 refused by gates/budget — final failure"
assert_contains "final failure adds the failure label" "$refuse_log" "gh issue edit 802 --add-label pipeline/failed"
assert_contains "final failure removes the watch label in its own call" "$refuse_log" "gh issue edit 802 --remove-label shipwright"
assert_contains "no retry is recorded as spawned; template and model restored" "$refuse_log" \
    "spawned_for=none template=autonomous model=sonnet"
assert_contains "the failure comment says the retry was refused, not exhausted" "$refuse_log" \
    "| Retries | 2 / 2 (refused by gates/budget) |"
assert_eq "a final failure whose watch label was removed leaves no final_failed entry" "false" \
    "$(jq '(.final_failed // {}) | has("802")' "$STATE_FILE")"

RETRY_SPAWN_RC=1 run_refused_failure 804 'printf "gh %s\n" "$*" >> "$REFUSE_LOG"'
refuse_log="$(cat "$TEST_TEMP_DIR/refuse.log")"
assert_contains "any other spawn failure names its rc" "$refuse_log" \
    "Retry #2 failed: retry spawn failed (rc=1) — final failure"
assert_contains "the failure comment names the spawn rc" "$refuse_log" \
    "| Retries | 2 / 2 (retry spawn failed (rc=1)) |"

print_test_section "Final failure when the watch label cannot be removed"

run_refused_failure 805 'printf "gh %s\n" "$*" >> "$REFUSE_LOG"; [[ "$*" == *--remove-label* ]] && exit 1; exit 0'
refuse_log="$(cat "$TEST_TEMP_DIR/refuse.log")"
assert_contains "a failed watch-label removal is logged at ERROR" "$refuse_log" \
    "log ERROR Could not remove 'shipwright' from failed issue #805"
assert_contains "it falls back to the shipwright-stuck label" "$refuse_log" \
    "gh issue edit 805 --add-label shipwright-stuck"
assert_eq "the entry records the labels that were applied" "pipeline/failed shipwright-stuck" \
    "$(jq -r '.final_failed["805"].marked | sort | join(" ")' "$STATE_FILE")"
assert_eq "the entry records when" "true" "$(jq '.final_failed["805"].ts | type == "string"' "$STATE_FILE")"

print_test_section "Org-mode retry that fails for good is keyed by repo and issue"
REFUSE_REPO="acme/api" run_refused_failure 807 'printf "gh %s\n" "$*" >> "$REFUSE_LOG"; [[ "$*" == *--remove-label* ]] && exit 1; exit 0'
refuse_log="$(cat "$TEST_TEMP_DIR/refuse.log")"
assert_contains "the retry is spawned into the job's repo" "$refuse_log" "spawn 807 retry=2 repo=acme/api"
assert_contains "the final failure edits the issue in that repo" "$refuse_log" "gh issue edit 807 --repo acme/api --add-label pipeline/failed"
assert_eq "the org-mode tombstone is keyed by repo and issue" "pipeline/failed shipwright-stuck" \
    "$(jq -r '.final_failed["acme/api:807"].marked | sort | join(" ")' "$STATE_FILE")"
assert_eq "and is not written under the bare number" "false" "$(jq '.final_failed | has("807")' "$STATE_FILE")"

run_refused_failure 803 'printf "gh %s\n" "$*" >> "$REFUSE_LOG"; [[ "${1:-} ${2:-}" == "issue edit" ]] && exit 1; exit 0'
assert_eq "when every edit fails the entry has no marked labels (fail closed)" "0" \
    "$(jq '.final_failed["803"].marked | length' "$STATE_FILE")"

# ─── W2-04: classify_failure behaviour (typed classifier with bash fallback) ───
print_test_section "classify_failure: typed classifier bridge (W2-04)"
printf '%s\n' "::error::Claude Code authentication failed — check CLAUDE_CODE_OAUTH_TOKEN secret" > "$LOG_DIR/issue-42.log"
assert_eq "pre-flight auth text is auth_error" "auth_error" "$(classify_failure 42)"
assert_eq "the bash fallback still says auth_error when Bun is missing" "auth_error" \
    "$(SW_BUN=/nonexistent/bun classify_failure 42)"
printf '%s\n' "build failed: test suite red" > "$LOG_DIR/issue-43.log"
assert_eq "a build failure keeps the bash class" "build_failure" "$(classify_failure 43)"
printf '%s\n' "OAuth token is invalid" > "$LOG_DIR/issue-44.log"
assert_eq "'OAuth token is invalid' is auth_error (same with or without Bun)" "auth_error" "$(classify_failure 44)"
# No Bun: SW_BUN points at nothing, so the bridge is skipped whatever PATH holds. The regex alone must
# classify each auth form the TS rule catches, so a host without Bun does not retry an auth failure.
for auth_text in "OAuth token is invalid" "OAuth token revoked" "Error: invalid api key provided" \
    "invalid x-api-key" "Error 401: authentication_error" "Not logged in"; do
    printf '%s\n' "$auth_text" > "$LOG_DIR/issue-46.log"
    assert_eq "no Bun: '$auth_text' is auth_error" "auth_error" "$(SW_BUN=/nonexistent/bun classify_failure 46)"
done
printf '%s\n' "benign build output" > "$LOG_DIR/issue-45.log"
assert_eq "a typed transient verdict is not mapped to api_error (trust rule, #8674)" "unknown" \
    "$(_daemon_classify_ts() { echo transient; }; classify_failure 45)"

# ─── Escalations never retry; a slow classifier cannot stall the failure path (ADR-0009, #8674) ───
print_test_section "Contamination is never retried (no Bun and with Bun)"
printf '%s\n' "⚠ Skipping integration tests: refusing to run inside a build-loop test gate" > "$LOG_DIR/issue-47.log"
assert_eq "contamination is classified with Bun" "contamination" "$(classify_failure 47)"
assert_eq "contamination is classified with no Bun (regex)" "contamination" "$(SW_BUN=/nonexistent/bun classify_failure 47)"
assert_eq "contamination has a retry limit of 0" "0" "$(get_max_retries_for_class contamination)"
RUN_LOG_TEXT="⚠ Skipping integration tests: refusing to run inside a build-loop test gate" run_refused_failure 811 'printf "gh %s\n" "$*" >> "$REFUSE_LOG"'
contam_log="$(cat "$TEST_TEMP_DIR/refuse.log")"
assert_contains "a contamination failure is logged as skipped" "$contam_log" "Contamination for issue #811 — skipping retry"
assert_eq "no retry is spawned for contamination" "0" "$(grep -c 'spawn 811 retry' <<<"$contam_log" || true)"

print_test_section "A slow classifier falls back to the regex (bounded)"
printf '%s\n' '#!/usr/bin/env bash' 'sleep 30' > "$TEST_TEMP_DIR/slow-bun"
chmod +x "$TEST_TEMP_DIR/slow-bun"
printf '%s\n' "::error::Claude Code authentication failed" > "$LOG_DIR/issue-48.log"
SECONDS=0
slow_result="$(SW_BUN="$TEST_TEMP_DIR/slow-bun" SW_CLASSIFY_TIMEOUT=1 classify_failure 48)"
assert_eq "a classifier that does not answer falls back to the regex" "auth_error" "$slow_result"
assert_eq "the fallback returns within the timeout, not after the 30 s sleep" "true" "$([[ $SECONDS -lt 15 ]] && echo true || echo false)"

# ─── Escalations come only from structured error lines (#8696) ───
print_test_section "False escalations do not block dispatch; structured escalations still do"
esc_class() { printf '%s\n' "$1" > "$LOG_DIR/issue-901.log"; classify_failure 901; }
ESC=$(printf '\033')
assert_eq "a bare refusal sentence is not contamination" "unknown" "$(esc_class "refusing to run inside a build-loop test gate")"
assert_eq "a forged CONTAMINATION line in test output is not contamination" "unknown" \
    "$(esc_class 'CONTAMINATION: x')"
assert_eq "a DNS failure is not invalid_issue" "unknown" "$(esc_class "Could not resolve host: api.github.com")"
assert_eq "a dependency resolution failure is not invalid_issue" "build_failure" \
    "$(esc_class "npm ERR! could not resolve dependencies: peer react@18")"
assert_eq "a bare HTTP 404 is not invalid_issue" "unknown" "$(esc_class "HTTP 404 Not Found")"
assert_eq "a model 404 is not invalid_issue" "unknown" "$(esc_class "API Error: 404 model not found")"
assert_eq "the structured refusal is contamination" "contamination" \
    "$(esc_class "⚠ Skipping integration tests: refusing to run inside a build-loop test gate")"
assert_eq "the gh-prefixed structured refusal is contamination" "contamination" \
    "$(esc_class "build	Test	2026-10-24T13:51:24.7812544Z ⚠ Skipping integration tests: refusing to run inside a build-loop test gate")"
assert_eq "a coloured structured refusal is contamination (ANSI stripped first)" "contamination" \
    "$(esc_class "${ESC}[33m⚠ Skipping integration tests: refusing to run inside a build-loop test gate${ESC}[0m")"
assert_eq "a coloured CONTAMINATION line is contamination" "contamination" \
    "$(esc_class "${ESC}[31mCONTAMINATION: branch-switched a -> b${ESC}[0m")"
assert_eq "a gh issue lookup failure is invalid_issue" "invalid_issue" \
    "$(esc_class "gh: Could not resolve to an Issue with the number 999")"
assert_eq "an issue HTTP 404 with its URL is invalid_issue" "invalid_issue" \
    "$(esc_class "HTTP 404 Not Found (https://api.github.com/repos/o/r/issues/999)")"

print_test_results

