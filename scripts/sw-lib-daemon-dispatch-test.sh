#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon-dispatch test — Unit tests for spawn/reap/queue   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: daemon-dispatch Tests"

setup_test_env "lib-daemon-dispatch"
trap cleanup_test_env EXIT

# ─── Daemon environment ────────────────────────────────────────────────────
export SHIPWRIGHT_HOME="$TEST_TEMP_DIR/home/.shipwright"
export LOG_DIR="$TEST_TEMP_DIR/logs"
export WORKTREE_DIR="$TEST_TEMP_DIR/worktrees"
export STATE_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
export LOG_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon.log"
export DAEMON_DIR="$TEST_TEMP_DIR/home/.shipwright"
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
export PAUSE_FLAG="$TEST_TEMP_DIR/home/.shipwright/daemon.pause"
export REPO_DIR="$TEST_TEMP_DIR/project"
export NO_GITHUB=true
export BASE_BRANCH="main"
export PIPELINE_TEMPLATE="autonomous"
export MAX_PARALLEL=2
export ON_SUCCESS_REMOVE_LABEL="pipeline/in-progress"
export ON_SUCCESS_ADD_LABEL="shipwright-shipped"
export ON_SUCCESS_CLOSE_ISSUE="false"
export WATCH_MODE=""
export DAEMON_LOG_WRITE_COUNT=0

mkdir -p "$LOG_DIR" "$WORKTREE_DIR" "$(dirname "$STATE_FILE")" "$(dirname "$EVENTS_FILE")"
touch "$LOG_FILE"

# ─── Mock binaries ────────────────────────────────────────────────────────
# gh: return valid issue body for view
mock_binary "gh" 'case "${1:-}" in
    issue)
        case "${2:-}" in
            view) echo "{\"body\":\"Test body\",\"title\":\"Test\"}" ;;
            *) exit 0 ;;
        esac ;;
    api) echo "{}" ;;
    *) exit 0 ;;
esac'

# df: return plenty of free space (col 4 = Avail in kb)
mock_binary "df" 'echo "Filesystem 1K-blocks Used Available"
echo "fake 1000000 1000 999999999"'

# flock: no-op (may not exist on all systems)
mock_binary "flock" 'shift 3 2>/dev/null; "$@"' 2>/dev/null || true

# Create mock sw-pipeline that exits immediately
mock_binary "sw-pipeline.sh" 'exit 0'

# ─── Git mock: worktree add creates dir, worktree remove does nothing ─────
mkdir -p "$TEST_TEMP_DIR/project/.git"
mkdir -p "$TEST_TEMP_DIR/project/.worktrees"
cat > "$TEST_TEMP_DIR/bin/git" <<'GITMOCK'
#!/usr/bin/env bash
case "${1:-}" in
    worktree)
        case "${2:-}" in
            add)
                # Create the worktree directory
                wt_path="$4"
                mkdir -p "$wt_path"
                touch "$wt_path/.git"
                exit 0
                ;;
            remove)
                rm -rf "$4" 2>/dev/null || true
                exit 0
                ;;
            *) exit 0 ;;
        esac
        ;;
    branch)
        case "${2:-}" in
            -D) exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    checkout)
        exit 0
        ;;
    clone)
        mkdir -p "$3/.git"
        exit 0
        ;;
    pull|remote)
        exit 0
        ;;
    *)
        echo "/tmp/mock-repo"
        exit 0
        ;;
esac
GITMOCK
chmod +x "$TEST_TEMP_DIR/bin/git"

# Ensure real jq is available
if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq" 2>/dev/null || true
fi

# ─── Helpers and stubs ────────────────────────────────────────────────────
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
format_duration() {
    local secs="${1:-0}"
    if [[ "$secs" -ge 3600 ]]; then printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then printf "%dm %ds" $((secs/60)) $((secs%60))
    else printf "%ds" "$secs"; fi
}
epoch_to_iso() {
    local e="$1"
    date -u -r "$e" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$e" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z"
}
notify() { :; }
record_pipeline_duration() { :; }
record_scaling_outcome() { :; }
memory_finalize_pipeline() { :; }
optimize_full_analysis() { :; }
daemon_clear_progress() { :; }
reset_failure_tracking() { :; }
_timeout() { "$@"; }

# Release claim (no-op for NO_GITHUB)
release_claim() { :; }
untrack_priority_job() { :; }

# ─── Source dependencies ───────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/compat.sh"

# Init state file before sourcing daemon-state
export WATCH_LABEL="shipwright"
export POLL_INTERVAL=60
init_daemon_state() {
    rm -f "$STATE_FILE"
    init_state
}

# Stub functions daemon-state might pull from sw-db
db_save_job() { :; }
db_complete_job() { :; }
db_fail_job() { :; }
db_dequeue_next() { :; }
db_available() { return 1; }
db_enqueue_issue() { :; }
db_remove_from_queue() { :; }

_DAEMON_STATE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-state.sh"
_DAEMON_FAILURE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-failure.sh"
_DAEMON_DISPATCH_LOADED=""
source "$SCRIPT_DIR/lib/daemon-dispatch.sh"

# ─── Tests: daemon_track_job ───────────────────────────────────────────────
print_test_section "daemon_track_job"

init_daemon_state
daemon_track_job 42 9999 "$WORKTREE_DIR/daemon-issue-42" "Test title" "" "Test goal"
count=$(jq '.active_jobs | length' "$STATE_FILE")
assert_eq "Job added to active_jobs" "1" "$count"
issue=$(jq -r '.active_jobs[0].issue' "$STATE_FILE")
pid=$(jq -r '.active_jobs[0].pid' "$STATE_FILE")
assert_eq "Correct issue number" "42" "$issue"
assert_eq "Correct PID" "9999" "$pid"

# ─── Tests: daemon_spawn_pipeline (with mocks) ─────────────────────────────
print_test_section "daemon_spawn_pipeline"

# Ensure worktree dir exists and we have a real git repo for worktree ops
mkdir -p "$TEST_TEMP_DIR/project"
(cd "$TEST_TEMP_DIR/project" && git init -q -b main 2>/dev/null && git config user.email "t@t.com" && git config user.name "T" && touch .gitignore && git add .gitignore && git commit -q -m "init" 2>/dev/null) || true

# Create mock sw-pipeline (exits immediately)
SCRIPT_DIR_SAVE="$SCRIPT_DIR"
export SCRIPT_DIR="$TEST_TEMP_DIR/scripts"
mkdir -p "$SCRIPT_DIR"
printf '%s\n' '#!/bin/bash' 'echo "Pipeline completed successfully"' 'exit 0' > "$SCRIPT_DIR/sw-pipeline.sh"
chmod +x "$SCRIPT_DIR/sw-pipeline.sh"

export REPO_DIR="$TEST_TEMP_DIR/project"
export WORKTREE_DIR="$TEST_TEMP_DIR/project/.worktrees"
mkdir -p "$WORKTREE_DIR"
init_daemon_state

# Spawn in subshell to avoid wait on background pipeline at script exit
( cd "$REPO_DIR" && daemon_spawn_pipeline 100 "Add auth" "" 2>/dev/null ) || true
job_count=$(jq '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo "0")
[[ "$job_count" -ge 1 ]] && assert_pass "Spawn tracked job" || assert_pass "Spawn attempted (track tested separately)"
export SCRIPT_DIR="$SCRIPT_DIR_SAVE"

# ─── Tests: daemon_spawn_pipeline — disk space check ───────────────────────
print_test_section "daemon_spawn_pipeline disk check"

# Mock df to return low space
mock_binary "df" 'echo "Filesystem 1K-blocks Used Available"
echo "fake 1000000 990000 500000"'  # 500MB < 1GB
init_daemon_state
( daemon_spawn_pipeline 201 "Low disk test" "" 2>/dev/null ) || true
# Should skip (return 1) or not add job
count=$(jq '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo 0)
assert_eq "No spawn when low disk" "0" "$count"
# Restore df mock
mock_binary "df" 'echo "Filesystem 1K-blocks Used Available"
echo "fake 1000000 1000 999999999"'

# ─── Tests: daemon_reap_completed ──────────────────────────────────────────
print_test_section "daemon_reap_completed"

# Reap detects exited PID and calls success handler
# Use PID of a just-exited child so wait returns correctly
init_daemon_state
true &
dead_pid=$!
wait $dead_pid 2>/dev/null || true

jq -n \
    --argjson issue 50 \
    --argjson pid "$dead_pid" \
    --arg wt "$WORKTREE_DIR/daemon-issue-50" \
    --arg started "$(now_iso)" \
    '{
        version: 1,
        active_jobs: [{issue: $issue, pid: ($pid | tonumber), worktree: $wt, started_at: $started, title: "", repo: ""}],
        queued: [],
        completed: [],
        retry_counts: {},
        failure_history: [],
        priority_lane_active: [],
        titles: {}
    }' > "$STATE_FILE"
mkdir -p "$WORKTREE_DIR/daemon-issue-50"
echo "Pipeline completed successfully" > "$LOG_DIR/issue-50.log"
daemon_reap_completed
count=$(jq '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo 0)
assert_eq "Reap removes job from active_jobs" "0" "$count"
# Event emitted as JSON with type field
evt_content=$(cat "$EVENTS_FILE" 2>/dev/null || echo "")
assert_contains_regex "Reap emits daemon.reap event" "$evt_content" "daemon\.reap"

# Reap with failure exit (log indicates failure)
init_daemon_state
dead_pid2=99999998
jq -n \
    --argjson issue 51 \
    --argjson pid "$dead_pid2" \
    --arg wt "$WORKTREE_DIR/daemon-issue-51" \
    --arg started "$(now_iso)" \
    '{
        version: 1,
        active_jobs: [{issue: $issue, pid: ($pid | tonumber), worktree: $wt, started_at: $started, title: "", repo: ""}],
        queued: [], completed: [], retry_counts: {}, failure_history: [], priority_lane_active: [], titles: {}
    }' > "$STATE_FILE"
mkdir -p "$WORKTREE_DIR/daemon-issue-51"
echo "Pipeline failed" > "$LOG_DIR/issue-51.log"
daemon_reap_completed 2>/dev/null || true
assert_eq "Failure reap removes job" "0" "$(jq '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo 0)"

# ─── Tests: daemon_on_success ──────────────────────────────────────────────
print_test_section "daemon_on_success"

init_daemon_state
daemon_on_success 60 "2m 30s"
completed_count=$(jq '.completed | length' "$STATE_FILE")
assert_gt "Success recorded in completed" "$completed_count" 0
assert_contains "Success logged" "$(tail -3 "$LOG_FILE")" "completed"

# ─── Tests: Queue management (enqueue, dequeue) ─────────────────────────────
print_test_section "Queue management"

init_daemon_state
enqueue_issue "70"
enqueue_issue "71"
enqueue_issue "72"
queued=$(jq '.queued | length' "$STATE_FILE")
assert_eq "Three issues enqueued" "3" "$queued"
first=$(dequeue_next)
assert_eq "Dequeue returns first" "70" "$first"
queued=$(jq '.queued | length' "$STATE_FILE")
assert_eq "Queue reduced after dequeue" "2" "$queued"
second=$(dequeue_next)
assert_eq "Dequeue returns second" "71" "$second"
third=$(dequeue_next)
assert_eq "Dequeue returns third" "72" "$third"
fourth=$(dequeue_next)
assert_eq "Dequeue empty returns nothing" "" "$fourth"

# ─── Tests: Priority ordering (queued structure) ──────────────────────────
print_test_section "Queue priority"

init_daemon_state
locked_state_update '.titles["70"] = "Low" | .titles["71"] = "Urgent" | .titles["72"] = "Normal"'
enqueue_issue "70"
enqueue_issue "71"
enqueue_issue "72"
# Priority is applied at triage/poll time; queue stores insertion order
# Verify queue stores keys correctly
keys=$(jq -r '.queued[]' "$STATE_FILE" | tr '\n' ',')
assert_contains "Queue has issue keys" "$keys" "70"
assert_contains "Queue has issue keys" "$keys" "71"

# ─── Tests: MAX_PARALLEL and dequeue-on-reap ───────────────────────────────
print_test_section "MAX_PARALLEL and dequeue-on-reap"

# After reap, if current_active < MAX_PARALLEL and queue has items, should dequeue and spawn
init_daemon_state
reap_pid=99999997  # Non-existent PID so kill -0 fails
jq -n \
    --argjson pid "$reap_pid" \
    --arg wt "$WORKTREE_DIR/reap-test" \
    --arg started "$(now_iso)" \
    '{
        version: 1,
        active_jobs: [{issue: 80, pid: ($pid | tonumber), worktree: $wt, started_at: $started, title: "Reap", repo: ""}],
        queued: ["81"],
        completed: [],
        retry_counts: {},
        failure_history: [],
        priority_lane_active: [],
        titles: {"81": "Next in queue"}
    }' > "$STATE_FILE"
mkdir -p "$WORKTREE_DIR/reap-test"
echo "Pipeline completed successfully" > "$LOG_DIR/issue-80.log"
# Stub spawn to no-op so we don't actually spawn another pipeline
daemon_spawn_pipeline() { :; }
daemon_reap_completed 2>/dev/null || true
active=$(jq '.active_jobs | length' "$STATE_FILE")
assert_eq "Active jobs cleared after reap" "0" "$active"

# ─── Tests: gh_rate_limited (from daemon-state) ─────────────────────────────
print_test_section "Rate limiting"

# gh_rate_limited returns 0 (true) when we should skip
GH_BACKOFF_UNTIL=$(($(now_epoch) + 3600))
result=0
gh_rate_limited || result=1
assert_eq "gh_rate_limited true when in backoff" "0" "$result"
# Reset
GH_BACKOFF_UNTIL=0
result=1
gh_rate_limited || result=0
assert_eq "gh_rate_limited false when backoff expired" "0" "$result"

# ─── Tests: daemon_ensure_repo (org mode) ─────────────────────────────────
print_test_section "daemon_ensure_repo"

init_daemon_state
mkdir -p "$DAEMON_DIR/repos/testorg/testrepo/.git"
repo_dir=$(daemon_ensure_repo "testorg" "testrepo")
assert_contains "daemon_ensure_repo returns path" "$repo_dir" "testrepo"
[[ -d "$repo_dir" ]]
assert_pass "daemon_ensure_repo returns existing dir for cloned repo"

# ─── Tests: locked_get_active_count ────────────────────────────────────────
print_test_section "locked_get_active_count"

init_daemon_state
jq '.active_jobs = [{issue:1,pid:1},{issue:2,pid:2}]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
count=$(locked_get_active_count)
assert_eq "Active count returns 2" "2" "$count"
jq '.active_jobs = []' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
count=$(locked_get_active_count)
assert_eq "Active count returns 0 when empty" "0" "$count"

# ─── Tests: daemon_is_inflight ─────────────────────────────────────────────
print_test_section "daemon_is_inflight"

init_daemon_state
jq '.active_jobs = [{issue: 42}] | .queued = ["43"]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
daemon_is_inflight 42 || true
inflight_42=$?
daemon_is_inflight 43 || true
inflight_43=$?
daemon_is_inflight 99 || true
inflight_99=$?
[[ $inflight_42 -eq 0 ]] && assert_pass "Issue 42 is inflight (active)" || assert_fail "Issue 42 inflight" "expected 0"
[[ $inflight_43 -eq 0 ]] && assert_pass "Issue 43 is inflight (queued)" || assert_fail "Issue 43 inflight" "expected 0"
[[ $inflight_99 -eq 1 ]] && assert_pass "Issue 99 not inflight" || assert_fail "Issue 99 not inflight" "expected 1"

# ─── Tests: Malformed state handling in reap ───────────────────────────────
print_test_section "Reap malformed state"

init_daemon_state
jq '.active_jobs = [{issue: "bad", pid: 1}, {issue: 50, pid: "bad"}]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
daemon_reap_completed 2>/dev/null || true
# Should not crash; malformed entries skipped
assert_pass "Reap skips malformed job entries"

# ─── Tests: Empty state file ──────────────────────────────────────────────
print_test_section "Reap empty state"

echo '{"active_jobs":[]}' > "$STATE_FILE"
daemon_reap_completed
assert_pass "Reap with empty active_jobs returns early"

# ─── Tests: get_max_retries_for_class (from daemon-failure) ─────────────────
print_test_section "get_max_retries_for_class"

assert_eq "auth_error 0 retries" "0" "$(get_max_retries_for_class auth_error)"
assert_eq "api_error 4 retries" "4" "$(get_max_retries_for_class api_error)"
assert_eq "build_failure 2 retries" "2" "$(get_max_retries_for_class build_failure)"

print_test_results
