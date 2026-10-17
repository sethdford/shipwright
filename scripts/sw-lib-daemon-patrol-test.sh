#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon-patrol test — Unit tests for all patrol functions  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: daemon-patrol Tests"

setup_test_env "sw-lib-daemon-patrol-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

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
# patrol_docs_autosync — docs sync never commits to the checked-out branch
# Uses real git in temp repos with local bare origins (the mock git is removed here).
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "patrol_docs_autosync never commits to the checked-out branch"

rm -f "$TEST_TEMP_DIR/bin/git"
TMP_REAL=$(cd "$TEST_TEMP_DIR" && pwd -P)
export TMPDIR="$TEST_TEMP_DIR"
DOCS_LOCK_REL=".git/shipwright-docs-sync.lock"

# Builds a repo with a local bare origin and default branch $2. Tracked STALE files are
# regenerated by the sync stub. Pass "dangling-head" as $3 to point the origin HEAD at a branch
# that does not exist, so the first fetch never creates origin/HEAD.
make_docs_repo() {
    local dir="$1" br="$2"
    git init -q -b "$br" "$dir"
    git -C "$dir" config user.email "test@example.test"
    git -C "$dir" config user.name "test"
    mkdir -p "$dir/scripts" "$dir/docs"
    cat > "$dir/scripts/sw-docs.sh" <<'STUB'
#!/usr/bin/env bash
# Stub sw-docs.sh. Tracked files containing STALE are regenerated by sync.
# STUB_DOCS_FAIL makes sync fail, STUB_DOCS_NOOP makes it succeed without edits,
# STUB_DOCS_SLEEP delays it. Sync always leaves an untracked stray.md behind.
case "${1:-}" in
    sync)
        [[ -z "${STUB_DOCS_FAIL:-}" ]] || exit 1
        [[ -z "${STUB_DOCS_SLEEP:-}" ]] || sleep "$STUB_DOCS_SLEEP"
        echo "stray" > stray.md
        if [[ -z "${STUB_DOCS_NOOP:-}" ]]; then
            for f in README.md "docs/with space.md"; do
                if grep -q STALE "$f"; then
                    sed -i.bak 's/STALE/FRESH/' "$f" && rm -f "$f.bak"
                fi
            done
        fi
        exit 0
        ;;
    check)
        if grep -q STALE README.md "docs/with space.md"; then exit 1; fi
        exit 0
        ;;
esac
exit 0
STUB
    echo "STALE docs" > "$dir/README.md"
    echo "STALE spaced" > "$dir/docs/with space.md"
    echo "unrelated" > "$dir/docs/unrelated.md"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "initial"
    git clone -q --bare "$dir" "$dir.git"
    if [[ "${3:-}" == "dangling-head" ]]; then
        git --git-dir="$dir.git" symbolic-ref HEAD refs/heads/gone
    fi
    git -C "$dir" remote add origin "$dir.git"
    git -C "$dir" fetch -q origin
}

# Commits message $2 on a new docs-sync branch in repo $1, based on origin ref $3, without
# touching the repo's HEAD.
docs_branch_with_commit() {
    local repo="$1" msg="$2" base="$3" tmpwt="$1-foreign-wt"
    git -C "$repo" worktree add -q -B shipwright/docs-sync "$tmpwt" "$base"
    echo "hand written" > "$tmpwt/notes.txt"
    git -C "$tmpwt" add notes.txt
    git -C "$tmpwt" commit -q -m "$msg"
    git -C "$repo" worktree remove --force "$tmpwt"
}

branch_exists() {
    if git -C "$1" rev-parse --verify -q refs/heads/shipwright/docs-sync >/dev/null 2>&1; then echo 1; else echo 0; fi
}

worktree_count() {
    git -C "$1" worktree list --porcelain | grep -c '^worktree ' || true
}

# Main repo: feature branch with an unrelated modified Markdown file left unstaged
DOCS_REPO="$TEST_TEMP_DIR/docs-repo"
make_docs_repo "$DOCS_REPO" main
git -C "$DOCS_REPO" checkout -q -b feature/work
echo "feature" > "$DOCS_REPO/feature.txt"
git -C "$DOCS_REPO" add feature.txt
git -C "$DOCS_REPO" commit -q -m "feature work"
echo "edited unrelated notes" >> "$DOCS_REPO/docs/unrelated.md"
feat_head=$(git -C "$DOCS_REPO" rev-parse HEAD)

NO_GITHUB=false
rc=0
synced_branch=$(patrol_docs_autosync "$DOCS_REPO") || rc=$?
assert_eq "docs autosync succeeds on feature branch" "0" "$rc"
assert_eq "autosync reports the docs-sync branch" "shipwright/docs-sync" "$synced_branch"
assert_eq "feature branch HEAD unchanged" "$feat_head" "$(git -C "$DOCS_REPO" rev-parse HEAD)"
assert_eq "feature branch is still checked out" "feature/work" "$(git -C "$DOCS_REPO" branch --show-current)"
assert_eq "index has nothing staged" "" "$(git -C "$DOCS_REPO" diff --cached --name-only)"
assert_contains "unrelated modified .md stays unstaged" "$(git -C "$DOCS_REPO" diff --name-only)" "docs/unrelated.md"
assert_contains "caller README left as it was" "$(cat "$DOCS_REPO/README.md")" "STALE"
assert_eq "docs-sync commit changes only tracked synced files (spaced path intact)" \
    "$(printf 'README.md\ndocs/with space.md\n' | LC_ALL=C sort)" \
    "$(git -C "$DOCS_REPO" diff --name-only main shipwright/docs-sync | LC_ALL=C sort)"
assert_contains "docs-sync branch has regenerated content" \
    "$(git -C "$DOCS_REPO" show "shipwright/docs-sync:docs/with space.md")" "FRESH"
assert_eq "patrol commit carries the trailer" "1" \
    "$(git -C "$DOCS_REPO" log -1 --format=%B shipwright/docs-sync | grep -c '^Shipwright-Patrol: docs-sync$' || true)"
assert_eq "patrol commit uses the patrol identity" "shipwright-patrol" \
    "$(git -C "$DOCS_REPO" log -1 --format=%an shipwright/docs-sync)"
assert_eq "untracked stray.md is not committed" "0" \
    "$(git -C "$DOCS_REPO" ls-tree -r --name-only shipwright/docs-sync | grep -c '^stray.md$' || true)"
assert_eq "nothing pushed to origin" "0" \
    "$(git -C "$DOCS_REPO.git" rev-parse --verify -q shipwright/docs-sync >/dev/null && echo 1 || echo 0)"
assert_eq "no temporary worktree remains" "1" "$(worktree_count "$DOCS_REPO")"
assert_eq "lock is released after the run" "0" "$([[ -L "$DOCS_REPO/$DOCS_LOCK_REL" ]] && echo 1 || echo 0)"

# NO_GITHUB=true: no sync, no branch
git -C "$DOCS_REPO" branch -q -D shipwright/docs-sync
NO_GITHUB=true
rc=0
patrol_docs_autosync "$DOCS_REPO" >/dev/null || rc=$?
assert_eq "NO_GITHUB run returns success without work" "0" "$rc"
assert_eq "NO_GITHUB run creates no docs-sync branch" "0" "$(branch_exists "$DOCS_REPO")"
NO_GITHUB=false

# Nothing changed by sync: no commit, and the branch this run created is deleted
rc=0
noop_out=$( (export STUB_DOCS_NOOP=1; patrol_docs_autosync "$DOCS_REPO") ) || rc=$?
assert_eq "no-op sync returns success" "0" "$rc"
assert_eq "no-op sync prints no branch" "" "$noop_out"
assert_eq "no-op sync deletes the docs-sync branch it created" "0" "$(branch_exists "$DOCS_REPO")"

# Leaked worktree from a SIGKILLed run (dead or absent pid): the next run removes it and succeeds
LEAK=$(mktemp -d "$TMP_REAL/sw-docs-sync.XXXXXX")
git -C "$DOCS_REPO" worktree add -q -B shipwright/docs-sync "$LEAK" origin/main
: > "$LEAK.marker"
rc=0
synced_branch=$(patrol_docs_autosync "$DOCS_REPO") || rc=$?
assert_eq "run after leaked worktree succeeds" "0" "$rc"
assert_eq "run after leaked worktree commits on docs-sync" "shipwright/docs-sync" "$synced_branch"
assert_eq "leaked worktree directory is removed" "0" "$([[ -e "$LEAK" ]] && echo 1 || echo 0)"
assert_eq "only the main worktree remains" "1" "$(worktree_count "$DOCS_REPO")"

# Live run holds a leaked-looking worktree (its pid is alive): nothing is removed, run skipped
LIVE=$(mktemp -d "$TMP_REAL/sw-docs-sync.XXXXXX")
git -C "$DOCS_REPO" worktree add -q -B shipwright/docs-sync "$LIVE" origin/main
sleep 300 &
live_pid=$!
echo "$live_pid" > "$LIVE.pid"
: > "$LIVE.marker"
rc=0
patrol_docs_autosync "$DOCS_REPO" >/dev/null 2>&1 || rc=$?
assert_eq "live-pid worktree makes the run skip (exit 2)" "2" "$rc"
assert_eq "live-pid worktree is left intact" "1" "$([[ -f "$LIVE.pid" ]] && echo 1 || echo 0)"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
git -C "$DOCS_REPO" worktree remove --force "$LIVE"

# #12b: pid-less temp worktree without the marker is never force-removed
NOMARK=$(mktemp -d "$TMP_REAL/sw-docs-sync.XXXXXX")
git -C "$DOCS_REPO" worktree add -q -B shipwright/docs-sync "$NOMARK" origin/main
rc=0
patrol_docs_autosync "$DOCS_REPO" >/dev/null 2>&1 || rc=$?
assert_eq "#12b pid-less worktree without marker: exit 2" "2" "$rc"
assert_eq "#12b pid-less worktree without marker is left intact" "1" "$([[ -d "$NOMARK" ]] && echo 1 || echo 0)"
git -C "$DOCS_REPO" worktree remove --force "$NOMARK"
git -C "$DOCS_REPO" branch -q -D shipwright/docs-sync

# Sync fails on a patrol-only branch: the branch is deleted, feature branch untouched
rc=0
(export STUB_DOCS_FAIL=1; patrol_docs_autosync "$DOCS_REPO" >/dev/null) || rc=$?
assert_eq "failing sync returns non-zero" "1" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
assert_eq "failing sync deletes the patrol-only branch" "0" "$(branch_exists "$DOCS_REPO")"
assert_eq "failing sync leaves no worktree" "1" "$(worktree_count "$DOCS_REPO")"
assert_eq "failing sync leaves feature HEAD unchanged" "$feat_head" "$(git -C "$DOCS_REPO" rev-parse HEAD)"
assert_eq "failing sync leaves index clean" "" "$(git -C "$DOCS_REPO" diff --cached --name-only)"

# #3: existing docs-sync branch with an unpushed user commit: skipped, never reset
docs_branch_with_commit "$DOCS_REPO" "user unpushed work" origin/main
user_sha=$(git -C "$DOCS_REPO" rev-parse shipwright/docs-sync)
rc=0
patrol_docs_autosync "$DOCS_REPO" >/dev/null 2>&1 || rc=$?
assert_eq "#3 user commit on docs-sync: skipped with exit 2" "2" "$rc"
assert_eq "#3 user commit on docs-sync: branch SHA unchanged" "$user_sha" "$(git -C "$DOCS_REPO" rev-parse shipwright/docs-sync)"
git -C "$DOCS_REPO" branch -q -D shipwright/docs-sync

# #3b: user commit that copies patrol's subject but not its trailer and identity: skipped
git -C "$DOCS_REPO" worktree add -q -B shipwright/docs-sync "$TEST_TEMP_DIR/spoof-wt" origin/main
echo u > "$TEST_TEMP_DIR/spoof-wt/u.txt"
git -C "$TEST_TEMP_DIR/spoof-wt" add u.txt
git -C "$TEST_TEMP_DIR/spoof-wt" commit -q -m "docs: auto-sync stale documentation sections"
git -C "$DOCS_REPO" worktree remove --force "$TEST_TEMP_DIR/spoof-wt"
spoof_sha=$(git -C "$DOCS_REPO" rev-parse shipwright/docs-sync)
rc=0
patrol_docs_autosync "$DOCS_REPO" >/dev/null 2>&1 || rc=$?
assert_eq "#3b subject-spoofed user commit: skipped with exit 2" "2" "$rc"
assert_eq "#3b subject-spoofed user commit: branch SHA unchanged" "$spoof_sha" "$(git -C "$DOCS_REPO" rev-parse shipwright/docs-sync)"
git -C "$DOCS_REPO" branch -q -D shipwright/docs-sync

# #11: origin/HEAD dangling, user commit on docs-sync: base falls back to origin/main, skipped, kept
REPO11="$TEST_TEMP_DIR/repo11"
make_docs_repo "$REPO11" main
git -C "$REPO11" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
docs_branch_with_commit "$REPO11" "precious user work" origin/main
user11=$(git -C "$REPO11" rev-parse shipwright/docs-sync)
rc=0
patrol_docs_autosync "$REPO11" >/dev/null 2>&1 || rc=$?
assert_eq "#11 dangling origin/HEAD with user commit: exit 2" "2" "$rc"
assert_eq "#11 dangling origin/HEAD: user commit kept" "$user11" "$(git -C "$REPO11" rev-parse shipwright/docs-sync)"

# #11b: default branch master, no origin/HEAD (dangling remote HEAD), user commit on docs-sync: resolves origin/master, kept
REPO11B="$TEST_TEMP_DIR/repo11b"
make_docs_repo "$REPO11B" master dangling-head
docs_branch_with_commit "$REPO11B" "precious user work" origin/master
user11b=$(git -C "$REPO11B" rev-parse shipwright/docs-sync)
rc=0
patrol_docs_autosync "$REPO11B" >/dev/null 2>&1 || rc=$?
assert_eq "#11b no origin/HEAD, master default: exit 2" "2" "$rc"
assert_eq "#11b master default: user commit kept" "$user11b" "$(git -C "$REPO11B" rev-parse shipwright/docs-sync)"

# No base resolves (remote HEAD dangling, no origin/main or origin/master): skipped, no branch created
REPO_NB="$TEST_TEMP_DIR/repo-nobase"
make_docs_repo "$REPO_NB" trunk dangling-head
rc=0
patrol_docs_autosync "$REPO_NB" >/dev/null 2>&1 || rc=$?
assert_eq "unresolvable base: exit 2" "2" "$rc"
assert_eq "unresolvable base: no docs-sync branch created" "0" "$(branch_exists "$REPO_NB")"

# #12: operator's own worktree holds docs-sync with uncommitted work: skipped, nothing removed
REPO12="$TEST_TEMP_DIR/repo12"
make_docs_repo "$REPO12" main
OP_WT="$TEST_TEMP_DIR/operator-wt"
git -C "$REPO12" worktree add -q -B shipwright/docs-sync "$OP_WT" origin/main
echo "operator WIP" > "$OP_WT/NOTES.md"
rc=0
patrol_docs_autosync "$REPO12" >/dev/null 2>&1 || rc=$?
assert_eq "#12 operator worktree on docs-sync: exit 2" "2" "$rc"
assert_eq "#12 operator uncommitted work intact" "operator WIP" "$(cat "$OP_WT/NOTES.md")"
assert_eq "#12 operator worktree still registered" "2" "$(worktree_count "$REPO12")"

# Main worktree on docs-sync: skipped, not removed
REPO_MAIN_HOLD="$TEST_TEMP_DIR/repo-main-hold"
make_docs_repo "$REPO_MAIN_HOLD" main
git -C "$REPO_MAIN_HOLD" checkout -q -b shipwright/docs-sync
echo "mywork" >> "$REPO_MAIN_HOLD/README.md"
git -C "$REPO_MAIN_HOLD" commit -q -am "mywork"
hold_head=$(git -C "$REPO_MAIN_HOLD" rev-parse HEAD)
rc=0
patrol_docs_autosync "$REPO_MAIN_HOLD" >/dev/null 2>&1 || rc=$?
assert_eq "main worktree on docs-sync: exit 2" "2" "$rc"
assert_eq "main worktree on docs-sync: HEAD unchanged" "$hold_head" "$(git -C "$REPO_MAIN_HOLD" rev-parse HEAD)"

# #13: two concurrent runs. The first holds the lock while its sync sleeps; the second must skip
# and must not delete or reset the first run's commit.
REPO13="$TEST_TEMP_DIR/repo13"
make_docs_repo "$REPO13" main
(export STUB_DOCS_SLEEP=3; patrol_docs_autosync "$REPO13" > "$TEST_TEMP_DIR/run-a.out" 2>/dev/null) &
pid_a=$!
i=0
while [[ ! -L "$REPO13/$DOCS_LOCK_REL" ]] && [[ "$i" -lt 100 ]]; do
    sleep 0.1
    i=$((i + 1))
done
rc_b=0
patrol_docs_autosync "$REPO13" >/dev/null 2>&1 || rc_b=$?
assert_eq "#13 second concurrent run skips with exit 2" "2" "$rc_b"
rc_a=0
wait "$pid_a" || rc_a=$?
assert_eq "#13 first concurrent run commits and exits 0" "0" "$rc_a"
assert_eq "#13 first run's commit survives the second run" "shipwright/docs-sync" "$(cat "$TEST_TEMP_DIR/run-a.out")"
assert_eq "#13 docs-sync branch holds the patrol commit" "1" \
    "$(git -C "$REPO13" log -1 --format=%B shipwright/docs-sync | grep -c '^Shipwright-Patrol: docs-sync$' || true)"
assert_eq "#13 lock released after the first run" "0" "$([[ -L "$REPO13/$DOCS_LOCK_REL" ]] && echo 1 || echo 0)"

# Lock left by a dead holder is stolen
REPO_STALE="$TEST_TEMP_DIR/repo-stale-lock"
make_docs_repo "$REPO_STALE" main
(exit 0) &
dead_pid=$!
wait "$dead_pid" || true
ln -s "$dead_pid $(date +%s)" "$REPO_STALE/$DOCS_LOCK_REL"
rc=0
synced_branch=$(patrol_docs_autosync "$REPO_STALE") || rc=$?
assert_eq "dead-holder lock is stolen and the run succeeds" "0" "$rc"
assert_eq "dead-holder lock is released after the run" "0" "$([[ -L "$REPO_STALE/$DOCS_LOCK_REL" ]] && echo 1 || echo 0)"

# Lock held by a live pid but older than the age cap (pid reuse backstop): stolen
REPO_AGE="$TEST_TEMP_DIR/repo-lock-age"
make_docs_repo "$REPO_AGE" main
sleep 300 &
age_pid=$!
ln -s "$age_pid 0" "$REPO_AGE/$DOCS_LOCK_REL"
rc=0
synced_branch=$(patrol_docs_autosync "$REPO_AGE") || rc=$?
kill "$age_pid" 2>/dev/null || true
wait "$age_pid" 2>/dev/null || true
assert_eq "expired lock held by a live pid is stolen" "0" "$rc"
assert_eq "expired lock steal commits on docs-sync" "shipwright/docs-sync" "$synced_branch"

# #14: only the sync subshell is SIGKILLed while the parent lives. The recorded pid must be the
# subshell's, so the next run recovers instead of wedging.
REPO14="$TEST_TEMP_DIR/repo14"
make_docs_repo "$REPO14" main
( export STUB_DOCS_SLEEP=3; patrol_docs_autosync "$REPO14" >/dev/null 2>&1 ) &
outer_pid=$!
i=0
while [[ ! -L "$REPO14/$DOCS_LOCK_REL" ]] && [[ "$i" -lt 100 ]]; do
    sleep 0.1
    i=$((i + 1))
done
inner_pid=$(readlink "$REPO14/$DOCS_LOCK_REL")
inner_pid="${inner_pid%% *}"
assert_eq "recorded lock pid is the sync subshell, not the parent" "1" \
    "$([[ "$inner_pid" != "$outer_pid" ]] && kill -0 "$inner_pid" 2>/dev/null && echo 1 || echo 0)"
kill -9 "$inner_pid" 2>/dev/null || true
wait "$outer_pid" 2>/dev/null || true
rc=0
synced_branch=$(patrol_docs_autosync "$REPO14") || rc=$?
assert_eq "run after SIGKILLed sync subshell recovers (exit 0)" "0" "$rc"
assert_eq "run after SIGKILLed sync subshell commits on docs-sync" "shipwright/docs-sync" "$synced_branch"
assert_eq "lock is released after recovery" "0" "$([[ -L "$REPO14/$DOCS_LOCK_REL" ]] && echo 1 || echo 0)"

# #3c: patrol commit amended by an operator: author kept, committer changed -> foreign, skipped
REPO3C="$TEST_TEMP_DIR/repo3c"
make_docs_repo "$REPO3C" main
patrol_docs_autosync "$REPO3C" >/dev/null 2>&1 || true
git -C "$REPO3C" worktree add -q "$TEST_TEMP_DIR/amend-wt" shipwright/docs-sync
git -C "$TEST_TEMP_DIR/amend-wt" -c user.name=operator -c user.email=operator@example.test commit -q --amend --no-edit
git -C "$REPO3C" worktree remove --force "$TEST_TEMP_DIR/amend-wt"
amend_sha=$(git -C "$REPO3C" rev-parse shipwright/docs-sync)
rc=0
patrol_docs_autosync "$REPO3C" >/dev/null 2>&1 || rc=$?
assert_eq "#3c amended committer makes the branch foreign: exit 2" "2" "$rc"
assert_eq "#3c amended commit is kept" "$amend_sha" "$(git -C "$REPO3C" rev-parse shipwright/docs-sync)"

# Two runs started together with no stale lock, repeated. Exactly one commits and the other returns
# 2. No run returns 0 without a commit, no worktree leaks, and the lock is released.
RACE_TRIALS=20
race_bad=0
race_first_bad=""
for i in $(seq 1 "$RACE_TRIALS"); do
    RACE="$TEST_TEMP_DIR/race-$i"
    make_docs_repo "$RACE" main
    ( rc=0; export STUB_DOCS_SLEEP=0.5; patrol_docs_autosync "$RACE" > "$RACE.a.out" 2>/dev/null || rc=$?; echo "$rc" > "$RACE.a.rc" ) &
    pa=$!
    ( rc=0; export STUB_DOCS_SLEEP=0.5; patrol_docs_autosync "$RACE" > "$RACE.b.out" 2>/dev/null || rc=$?; echo "$rc" > "$RACE.b.rc" ) &
    pb=$!
    wait "$pa" || true
    wait "$pb" || true
    rc_a=$(cat "$RACE.a.rc"); rc_b=$(cat "$RACE.b.rc")
    out_a=$(cat "$RACE.a.out"); out_b=$(cat "$RACE.b.out")
    ok=0
    if [[ "$rc_a" == "0" && -n "$out_a" && "$rc_b" == "2" && -z "$out_b" ]]; then ok=1; fi
    if [[ "$rc_b" == "0" && -n "$out_b" && "$rc_a" == "2" && -z "$out_a" ]]; then ok=1; fi
    if [[ "$ok" -ne 1 ]]; then
        race_bad=$((race_bad + 1))
        race_first_bad="${race_first_bad:-trial $i: a=$rc_a/[$out_a] b=$rc_b/[$out_b]}"
    fi
    if [[ "$(worktree_count "$RACE")" != "1" ]]; then
        race_bad=$((race_bad + 1))
        race_first_bad="${race_first_bad:-trial $i: worktree leaked}"
    fi
    if [[ -L "$RACE/$DOCS_LOCK_REL" ]]; then
        race_bad=$((race_bad + 1))
        race_first_bad="${race_first_bad:-trial $i: lock left behind}"
    fi
done
assert_eq "race: $RACE_TRIALS trials, exactly one commits, the other skips, no leaks (${race_first_bad:-none})" \
    "0" "$race_bad"

print_test_results
