#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon gates test — safety gates at the daemon call sites ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: safety_gates_ok, spawn, claim and gh are stubs or mocks. No tmux, no network,
# temp HOME. Covers daemon_spawn_pipeline's gate, the poll loop (cycle gate, eligibility,
# claim release, queue drain) and the reaper's queue hand-off.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPT_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: daemon safety-gate call sites"

setup_test_env "lib-daemon-gates"
trap cleanup_test_env EXIT

export DAEMON_DIR="$TEST_TEMP_DIR/home/.shipwright"
export STATE_FILE="$DAEMON_DIR/daemon-state.json"
export LOG_FILE="$DAEMON_DIR/daemon.log"
export LOG_DIR="$TEST_TEMP_DIR/logs"
export EVENTS_FILE="$DAEMON_DIR/events.jsonl"
export PAUSE_FLAG="$DAEMON_DIR/daemon.pause"
export WORKTREE_DIR="$TEST_TEMP_DIR/worktrees"
export REPO_DIR="$TEST_TEMP_DIR/project"
export WATCH_LABEL="shipwright"
export WATCH_MODE="repo"
export MAX_PARALLEL=4
export PRIORITY_LANE="false"
export SPAWN_STAGGER_SECONDS=7
export GH_RETRY_ENABLED="false"
export DAEMON_LOG_WRITE_COUNT=0
export CALLS="$TEST_TEMP_DIR/calls.log"
mkdir -p "$LOG_DIR" "$WORKTREE_DIR" "$DAEMON_DIR" "$REPO_DIR"
touch "$LOG_FILE" "$CALLS"

mock_binary "flock" 'shift 3 2>/dev/null; "$@"'
mock_binary "gh" 'printf "gh %s\n" "$*" >> "$CALLS"
if [[ "${1:-} ${2:-}" == "issue list" ]]; then cat "$TEST_TEMP_DIR/issues.json"; fi'
export TEST_TEMP_DIR

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
epoch_to_iso() { echo "1970-01-01T00:00:00Z"; }
notify() { :; }
db_available() { return 1; }

source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/compat.sh"
_DAEMON_STATE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-state.sh"
_DAEMON_FAILURE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-failure.sh"
_DAEMON_DISPATCH_LOADED=""
source "$SCRIPT_DIR/lib/daemon-dispatch.sh"
_DAEMON_POLL_GITHUB_LOADED=""
source "$SCRIPT_DIR/lib/daemon-poll-github.sh"
_DAEMON_PATROL_LOADED=""
source "$SCRIPT_DIR/lib/daemon-patrol.sh"

# Stubs recorded to $CALLS (defined after sourcing so they override the libraries).
daemon_log() { printf 'log %s %s\n' "$1" "${*:2}" >> "$CALLS"; }
emit_event() { printf 'event %s\n' "$*" >> "$CALLS"; }
sleep() { printf 'sleep %s\n' "$*" >> "$CALLS"; }
triage_score_issue() { echo 50; }
select_pipeline_template() { echo "standard"; }
extract_issue_dependencies() { :; }
claim_issue() { printf 'claim %s %s\n' "$1" "$2" >> "$CALLS"; }
release_claim() { printf 'release %s %s\n' "$1" "$2" >> "$CALLS"; }
GATE_RC=0
safety_gates_ok() { printf 'gate %s\n' "$*" >> "$CALLS"; return "$GATE_RC"; }
SPAWN_RC=1
daemon_spawn_pipeline() { printf 'spawn %s\n' "$1" >> "$CALLS"; return "$SPAWN_RC"; }

reset_state() {
    rm -f "$STATE_FILE"
    init_state
    : > "$CALLS"
}
calls() { cat "$CALLS"; }
count_calls() { local n; n=$(grep -c "$1" "$CALLS" || true); echo "${n:-0}"; }

# ─── daemon_spawn_pipeline: the per-spawn gate ───────────────────────────
print_test_section "daemon_spawn_pipeline gate"

(
    unset -f daemon_spawn_pipeline
    _DAEMON_DISPATCH_LOADED=""
    source "$REAL_SCRIPT_DIR/lib/daemon-dispatch.sh"
    safety_gates_ok() { printf 'gate %s\n' "$*" >> "$CALLS"; return 127; }
    : > "$CALLS"
    rc=0
    DAEMON_RETRY_ATTEMPT=2 daemon_spawn_pipeline 5 "t" "" || rc=$?
    echo "rc=$rc" >> "$CALLS"
) 2>/dev/null
assert_contains "the retry count reaches the gate" "$(calls)" "gate 2"
assert_contains "a refused spawn returns 1" "$(calls)" "rc=1"
assert_contains "a missing Bun (127) is logged at ERROR with the rc" "$(calls)" "log ERROR Safety gates closed (rc=127)"
assert_contains "the event carries the rc" "$(calls)" "event daemon.gates_closed issue=5 rc=127"

(
    unset -f daemon_spawn_pipeline
    _DAEMON_DISPATCH_LOADED=""
    source "$REAL_SCRIPT_DIR/lib/daemon-dispatch.sh"
    safety_gates_ok() { return 1; }
    : > "$CALLS"
    daemon_spawn_pipeline 6 "t" "" || true
) 2>/dev/null
assert_contains "a blocked gate (1) is logged at WARN" "$(calls)" "log WARN Safety gates closed (rc=1)"

(
    unset -f daemon_spawn_pipeline
    _DAEMON_DISPATCH_LOADED=""
    source "$REAL_SCRIPT_DIR/lib/daemon-dispatch.sh"
    safety_gates_ok() { return 0; }
    # A child process after the gate: the budget check. It records the env it inherits and
    # reports an exhausted budget so the spawn stops there.
    SCRIPT_DIR="$TEST_TEMP_DIR/child-scripts"
    mkdir -p "$SCRIPT_DIR"
    printf '#!/usr/bin/env bash\necho "child_retry=${DAEMON_RETRY_ATTEMPT:-unset}" >> "$CALLS"\necho 0\n' > "$SCRIPT_DIR/sw-cost.sh"
    chmod +x "$SCRIPT_DIR/sw-cost.sh"
    : > "$CALLS"
    DAEMON_RETRY_ATTEMPT=2 daemon_spawn_pipeline 7 "t" "" || true
) 2>/dev/null
assert_contains "DAEMON_RETRY_ATTEMPT is not passed to child processes" "$(calls)" "child_retry=unset"

# ─── daemon_poll_issues: one gate per cycle ──────────────────────────────
print_test_section "daemon_poll_issues cycle gate"

export NO_GITHUB=false
echo '[{"number":3,"title":"t3","labels":[{"name":"shipwright"}]}]' > "$TEST_TEMP_DIR/issues.json"

reset_state
GATE_RC=1
rc=0
daemon_poll_issues 2>/dev/null || rc=$?
assert_eq "a closed cycle gate returns 0" "0" "$rc"
assert_contains "the cycle gate checks a first dispatch" "$(calls)" "gate 0"
assert_eq "no issues are listed when gates are closed" "0" "$(count_calls 'gh issue list')"
assert_eq "nothing is claimed or spawned" "0" "$(count_calls '^claim\|^spawn')"
assert_eq "no stagger sleep" "0" "$(count_calls '^sleep')"
assert_eq "last_poll is updated" "true" "$(jq '.last_poll != null' "$STATE_FILE")"
GATE_RC=0

# ─── daemon_poll_issues: eligibility, claim release, stagger ─────────────
print_test_section "daemon_poll_issues eligibility and refused spawns"

cat > "$TEST_TEMP_DIR/issues.json" <<'JSON'
[{"number":1,"title":"no labels","labels":[]},
 {"number":2,"title":"auto","labels":[{"name":"shipwright"},{"name":"Auto-Patrol"}]},
 {"number":3,"title":"human","labels":[{"name":"shipwright"}]},
 {"number":4,"title":"stuck","labels":[{"name":"shipwright"},{"name":"shipwright-stuck"}]}]
JSON
echo '{"machines":[{"name":"m1","role":"primary"}]}' > "$HOME/.shipwright/machines.json"

reset_state
SPAWN_RC=1
daemon_poll_issues 2>/dev/null || true
assert_eq "only the eligible issue is spawned" "spawn 3" "$(grep '^spawn' "$CALLS" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "ineligible issues are never claimed" "claim 3 m1" "$(grep '^claim' "$CALLS" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "a refused spawn releases its claim" "$(calls)" "release 3 m1"
assert_eq "no stagger sleep after a refused spawn" "0" "$(count_calls '^sleep 7')"

reset_state
SPAWN_RC=0
daemon_poll_issues 2>/dev/null || true
assert_eq "a successful spawn keeps its claim" "0" "$(count_calls '^release')"
assert_eq "a successful spawn staggers" "1" "$(count_calls '^sleep 7')"
rm -f "$HOME/.shipwright/machines.json"

# ─── daemon_poll_issues: queue drain ─────────────────────────────────────
print_test_section "daemon_poll_issues queue drain"

cat > "$TEST_TEMP_DIR/issues.json" <<'JSON'
[{"number":11,"title":"a","labels":[{"name":"shipwright"}]},
 {"number":12,"title":"b","labels":[{"name":"shipwright"}]},
 {"number":13,"title":"c","labels":[{"name":"shipwright"},{"name":"auto-patrol"}]}]
JSON

reset_state
locked_state_update '.queued = ["10","13","11","12"]'
: > "$CALLS"
SPAWN_RC=1
daemon_poll_issues 2>/dev/null || true
assert_eq "drain spawns only eligible queued issues and stops at the first refusal" \
    "spawn 11" "$(grep '^spawn' "$CALLS" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "refused issue is re-queued; ineligible ones are dropped" \
    "11 12" "$(jq -r '.queued | sort | join(" ")' "$STATE_FILE")"

reset_state
locked_state_update '.queued = ["11","12"]'
: > "$CALLS"
SPAWN_RC=0
daemon_poll_issues 2>/dev/null || true
assert_eq "drain spawns eligible issues while it has capacity" \
    "spawn 11 spawn 12" "$(grep '^spawn' "$CALLS" | tr '\n' ' ' | sed 's/ $//')"

# ─── daemon_reap_completed: the queue is left to the next poll ───────────
print_test_section "daemon_reap_completed defers the queue"

export NO_GITHUB=true
reset_state
jq -n --arg wt "$WORKTREE_DIR/reap" --arg started "$(now_iso)" '{
    version: 1,
    active_jobs: [{issue: 80, pid: 99999997, worktree: $wt, started_at: $started, title: "Reap", repo: ""}],
    queued: ["81"], completed: [], retry_counts: {}, failure_history: [],
    priority_lane_active: [], titles: {"81": "Next"}
}' > "$STATE_FILE"
echo "Pipeline completed successfully" > "$LOG_DIR/issue-80.log"
daemon_on_success() { printf 'success %s\n' "$1" >> "$CALLS"; }
daemon_on_failure() { printf 'failure %s\n' "$1" >> "$CALLS"; }
daemon_clear_progress() { :; }
untrack_priority_job() { :; }
SPAWN_RC=0
daemon_reap_completed 2>/dev/null || true
assert_eq "the reaper never spawns from the queue" "0" "$(count_calls '^spawn')"
assert_eq "the queued issue stays queued for the next poll" "81" "$(jq -r '.queued | join(" ")' "$STATE_FILE")"

# ─── daemon_patrol: a refused filing is not counted as created ───────────
print_test_section "daemon_patrol security site and the intake gate"

PATROL_PROJECT="$TEST_TEMP_DIR/patrol-project"
mkdir -p "$PATROL_PROJECT" "$TEST_TEMP_DIR/patrol-scripts"
echo '{"name":"x"}' > "$PATROL_PROJECT/package.json"
echo 0 > "$TEST_TEMP_DIR/issues.json"   # patrol's duplicate check: no open issues
mock_binary "npm" 'if [[ "${1:-}" == "audit" ]]; then
echo "{\"auditReportVersion\":2,\"vulnerabilities\":{\"lodash\":{\"name\":\"lodash\",\"severity\":\"critical\",\"via\":[{\"url\":\"u\",\"title\":\"Prototype pollution\"}]}}}"
fi'

run_patrol() {
    (
        cd "$PATROL_PROJECT"
        SCRIPT_DIR="$TEST_TEMP_DIR/patrol-scripts"
        NO_GITHUB=false
        PATROL_DRY_RUN=false
        DECISION_ENGINE_ENABLED=false
        PATROL_DORA_ENABLED=false
        PATROL_UNTESTED_ENABLED=false
        PATROL_RETRY_ENABLED=false
        _sw_ts() { printf 'intake %s\n' "$*" >> "$CALLS"; return "$INTAKE_RC"; }
        daemon_patrol --once
    ) >/dev/null 2>&1 || true
}

: > "$CALLS"
INTAKE_RC=1
run_patrol
assert_contains "the security finding asks the intake gate" "$(calls)" \
    "intake intake check --title Security: Prototype pollution in lodash --label auto-patrol"
assert_eq "a refused finding is not filed" "0" "$(count_calls 'gh issue create')"
assert_contains "a refused finding emits patrol.issue_refused" "$(calls)" "event patrol.issue_refused check=security package=lodash"
assert_eq "a refused finding is not counted as created" "0" "$(count_calls 'patrol.issue_created check=security')"
assert_contains "the refusal reason reaches the daemon log" "$(calls)" "intake gate refused (rc=1)"

: > "$CALLS"
INTAKE_RC=0
run_patrol
assert_eq "an allowed finding is filed" "1" "$(count_calls 'gh issue create --title Security: Prototype pollution in lodash')"
assert_contains "an allowed finding emits patrol.issue_created" "$(calls)" "event patrol.issue_created check=security package=lodash"

# ─── sw-patrol-meta / sw-strategic: filings go through the intake gate ───
print_test_section "meta-patrol and strategic filings use the intake gate"

echo "" > "$TEST_TEMP_DIR/issues.json"   # duplicate checks: no open issues
for INTAKE_RC in 1 0; do
    : > "$CALLS"
    (
        NO_GITHUB=false
        issues_created=0
        total_findings=0
        source "$REAL_SCRIPT_DIR/sw-patrol-meta.sh"
        _sw_ts() { printf 'intake %s\n' "$*" >> "$CALLS"; return "$INTAKE_RC"; }
        patrol_meta_create_issue "Meta: add tests" "body" "testing" || echo "meta_rc=$?" >> "$CALLS"
    ) >/dev/null 2>&1 || true
    assert_contains "meta: intake gate asked with the auto-patrol label (intake rc=${INTAKE_RC})" "$(calls)" \
        "intake intake check --title Meta: add tests --label auto-patrol"
    if [[ "$INTAKE_RC" -eq 0 ]]; then
        assert_eq "meta: allowed issue is filed" "1" "$(count_calls 'gh issue create --title Meta: add tests')"
    else
        assert_eq "meta: refused issue is not filed" "0" "$(count_calls 'gh issue create')"
        assert_contains "meta: refusal returns 1 and emits an event" "$(calls)" "meta_rc=1"
    fi

    : > "$CALLS"
    (
        NO_GITHUB=false
        source "$REAL_SCRIPT_DIR/sw-strategic.sh"
        _sw_ts() { printf 'intake %s\n' "$*" >> "$CALLS"; return "$INTAKE_RC"; }
        strategic_create_issue "Strategic: faster builds" "P1" "standard" "speed" "d" "a" \
            || echo "strategic_rc=$?" >> "$CALLS"
    ) >/dev/null 2>&1 || true
    assert_contains "strategic: intake gate asked with the auto-patrol label (intake rc=${INTAKE_RC})" "$(calls)" \
        "intake intake check --title Strategic: faster builds --label auto-patrol"
    if [[ "$INTAKE_RC" -eq 0 ]]; then
        assert_eq "strategic: allowed issue is filed" "1" "$(count_calls 'gh issue create --title Strategic: faster builds')"
    else
        assert_eq "strategic: refused issue is not filed" "0" "$(count_calls 'gh issue create')"
        assert_contains "strategic: refusal returns 1" "$(calls)" "strategic_rc=1"
    fi
done

print_test_results
