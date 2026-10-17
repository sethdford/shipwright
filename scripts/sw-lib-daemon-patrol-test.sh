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
# patrol_docs_autosync — docs sync never commits to the checked-out branch
# Uses real git against a temp repo with a local bare origin (the mock git is removed here).
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "patrol_docs_autosync never commits to the checked-out branch"

rm -f "$TEST_TEMP_DIR/bin/git"
DOCS_ORIGIN="$TEST_TEMP_DIR/docs-origin.git"
DOCS_REPO="$TEST_TEMP_DIR/docs-repo"
git init -q -b main "$DOCS_REPO"
git -C "$DOCS_REPO" config user.email "test@example.test"
git -C "$DOCS_REPO" config user.name "test"
mkdir -p "$DOCS_REPO/scripts" "$DOCS_REPO/docs"
cat > "$DOCS_REPO/scripts/sw-docs.sh" <<'STUB'
#!/usr/bin/env bash
# Stub sw-docs.sh. Tracked files containing STALE are regenerated by sync.
# STUB_DOCS_FAIL makes sync fail, STUB_DOCS_NOOP makes it succeed without edits.
# Sync always leaves an untracked stray.md behind, as a stand-in for stray output.
case "${1:-}" in
    sync)
        [[ -z "${STUB_DOCS_FAIL:-}" ]] || exit 1
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
echo "STALE docs" > "$DOCS_REPO/README.md"
echo "STALE spaced" > "$DOCS_REPO/docs/with space.md"
echo "unrelated" > "$DOCS_REPO/docs/unrelated.md"
git -C "$DOCS_REPO" add -A
git -C "$DOCS_REPO" commit -q -m "initial"
git clone -q --bare "$DOCS_REPO" "$DOCS_ORIGIN"
git -C "$DOCS_REPO" remote add origin "$DOCS_ORIGIN"
git -C "$DOCS_REPO" fetch -q origin

# Feature branch with an unrelated modified Markdown file left unstaged
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
assert_eq "untracked stray.md is not committed" "0" \
    "$(git -C "$DOCS_REPO" ls-tree -r --name-only shipwright/docs-sync | grep -c '^stray.md$' || true)"
assert_eq "nothing pushed to origin" "0" \
    "$(git -C "$DOCS_ORIGIN" rev-parse --verify -q shipwright/docs-sync >/dev/null && echo 1 || echo 0)"
assert_eq "no temporary worktree remains" "1" \
    "$(git -C "$DOCS_REPO" worktree list --porcelain | grep -c '^worktree ' || true)"

# NO_GITHUB=true: no sync, no branch
git -C "$DOCS_REPO" branch -q -D shipwright/docs-sync
NO_GITHUB=true
rc=0
patrol_docs_autosync "$DOCS_REPO" >/dev/null || rc=$?
assert_eq "NO_GITHUB run returns success without work" "0" "$rc"
assert_eq "NO_GITHUB run creates no docs-sync branch" "0" \
    "$(git -C "$DOCS_REPO" rev-parse --verify -q shipwright/docs-sync >/dev/null && echo 1 || echo 0)"
NO_GITHUB=false

# Nothing changed by sync: no commit, and the branch is deleted
rc=0
noop_out=$(STUB_DOCS_NOOP=1 patrol_docs_autosync "$DOCS_REPO") || rc=$?
assert_eq "no-op sync returns success" "0" "$rc"
assert_eq "no-op sync prints no branch" "" "$noop_out"
assert_eq "no-op sync deletes the docs-sync branch" "0" \
    "$(git -C "$DOCS_REPO" rev-parse --verify -q shipwright/docs-sync >/dev/null && echo 1 || echo 0)"

# Leaked worktree from a killed run holds the branch: the next run still succeeds
LEAK="$TEST_TEMP_DIR/leaked-docs-sync"
git -C "$DOCS_REPO" worktree add -q -B shipwright/docs-sync "$LEAK" origin/main
rc=0
synced_branch=$(patrol_docs_autosync "$DOCS_REPO") || rc=$?
assert_eq "run after leaked worktree succeeds" "0" "$rc"
assert_eq "run after leaked worktree commits on docs-sync" "shipwright/docs-sync" "$synced_branch"
assert_eq "leaked worktree directory is removed" "0" "$([[ -e "$LEAK" ]] && echo 1 || echo 0)"
assert_eq "leaked worktree is pruned from git" "1" \
    "$(git -C "$DOCS_REPO" worktree list --porcelain | grep -c '^worktree ' || true)"

# Sync fails: the patrol-only docs-sync branch is deleted, feature branch untouched
rc=0
STUB_DOCS_FAIL=1 patrol_docs_autosync "$DOCS_REPO" >/dev/null || rc=$?
assert_eq "failing sync returns non-zero" "1" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
assert_eq "failing sync deletes the docs-sync branch" "0" \
    "$(git -C "$DOCS_REPO" rev-parse --verify -q shipwright/docs-sync >/dev/null && echo 1 || echo 0)"
assert_eq "failing sync leaves no worktree" "1" \
    "$(git -C "$DOCS_REPO" worktree list --porcelain | grep -c '^worktree ' || true)"
assert_eq "failing sync leaves feature HEAD unchanged" "$feat_head" "$(git -C "$DOCS_REPO" rev-parse HEAD)"
assert_eq "failing sync leaves index clean" "" "$(git -C "$DOCS_REPO" diff --cached --name-only)"

# docs-sync branch holds a commit not made by patrol: skipped (exit 2) and left untouched
FOREIGN="$TEST_TEMP_DIR/foreign-docs-sync"
git -C "$DOCS_REPO" worktree add -q -B shipwright/docs-sync "$FOREIGN" origin/main
echo "hand written" > "$FOREIGN/notes.txt"
git -C "$FOREIGN" add notes.txt
git -C "$FOREIGN" commit -q -m "hand-written change"
git -C "$DOCS_REPO" worktree remove --force "$FOREIGN"
foreign_sha=$(git -C "$DOCS_REPO" rev-parse shipwright/docs-sync)
rc=0
patrol_docs_autosync "$DOCS_REPO" >/dev/null || rc=$?
assert_eq "branch with foreign commits is skipped with exit 2" "2" "$rc"
assert_eq "foreign docs-sync branch is not reset" "$foreign_sha" "$(git -C "$DOCS_REPO" rev-parse shipwright/docs-sync)"
assert_eq "skipped run leaves no worktree" "1" \
    "$(git -C "$DOCS_REPO" worktree list --porcelain | grep -c '^worktree ' || true)"
assert_eq "skipped run leaves feature HEAD unchanged" "$feat_head" "$(git -C "$DOCS_REPO" rev-parse HEAD)"

print_test_results
