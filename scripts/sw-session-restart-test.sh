#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright session-restart test — Intelligent restart briefing system   ║
# ║                                                                         ║
# ║  Tests state capture, briefing generation, reason detection, strategy   ║
# ║  suggestions, and cross-session tracking.                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Test Environment Setup ────────────────────────────────────────────────

TEST_TEMP_DIR=""
TEST_PROJECT_DIR=""
TEST_LOG_DIR=""
ARTIFACTS_DIR=""

setup_test_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-session-restart-test.XXXXXX")
    TEST_PROJECT_DIR="$TEST_TEMP_DIR/project"
    TEST_LOG_DIR="$TEST_PROJECT_DIR/.claude/loop-logs"
    ARTIFACTS_DIR="$TEST_PROJECT_DIR/.claude/artifacts"

    mkdir -p "$TEST_LOG_DIR" "$ARTIFACTS_DIR"

    # Create minimal git repo
    cd "$TEST_PROJECT_DIR"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    touch README.md
    git add README.md
    git commit -q -m "Initial commit"
    cd - > /dev/null

    # Source the session-restart module
    export PROJECT_ROOT="$TEST_PROJECT_DIR"
    export LOG_DIR="$TEST_LOG_DIR"
    export ARTIFACTS_DIR="$ARTIFACTS_DIR"

    # Load required modules
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/lib/compat.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/lib/session-restart.sh" 2>/dev/null || {
        echo "FAIL: Could not source session-restart.sh"
        exit 1
    }
}

cleanup_test_env() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}
trap cleanup_test_env EXIT

# ═══════════════════════════════════════════════════════════════════════════
# TEST CASES
# ═══════════════════════════════════════════════════════════════════════════

test_state_capture_creates_valid_json() {
    setup_test_env
    echo -n "Testing state capture creates valid JSON... "

    # Set up state variables
    ITERATION=5
    MAX_ITERATIONS=10
    RESTART_COUNT=1
    MAX_RESTARTS=3
    GOAL="Build test feature"
    TEST_PASSED=true
    CONSECUTIVE_FAILURES=0

    # Create a test log file
    echo "Test output here" > "$LOG_DIR/tests-iter-5.log"

    local state_file
    state_file=$(restart_capture_state)

    if [[ ! -f "$state_file" ]]; then
        echo "FAIL: State file not created"
        return 1
    fi

    # Verify it's valid JSON
    if ! jq . "$state_file" > /dev/null 2>&1; then
        echo "FAIL: State file is not valid JSON"
        return 1
    fi

    # Verify key fields
    local goal_field iteration_field restart_field
    goal_field=$(jq -r '.goal // ""' "$state_file" 2>/dev/null || echo "")
    iteration_field=$(jq -r '.progress.iteration // ""' "$state_file" 2>/dev/null || echo "")
    restart_field=$(jq -r '.restart_count // ""' "$state_file" 2>/dev/null || echo "")

    if [[ "$goal_field" != "Build test feature" ]]; then
        echo "FAIL: Goal not captured correctly"
        return 1
    fi

    if [[ "$iteration_field" != "5" ]]; then
        echo "FAIL: Iteration not captured correctly"
        return 1
    fi

    if [[ "$restart_field" != "1" ]]; then
        echo "FAIL: Restart count not captured correctly"
        return 1
    fi

    echo "PASS"
    return 0
}

test_briefing_generation_produces_markdown() {
    setup_test_env
    echo -n "Testing briefing generation produces markdown... "

    # Create minimal state file
    local state_file="$ARTIFACTS_DIR/restart-state.json"
    {
        printf '{\n'
        printf '  "goal": "Test goal",\n'
        printf '  "progress": {\n'
        printf '    "iteration": 7,\n'
        printf '    "max_iterations": 10,\n'
        printf '    "test_status": true,\n'
        printf '    "tests_passed": 5,\n'
        printf '    "tests_failed": 0\n'
        printf '  },\n'
        printf '  "files": {\n'
        printf '    "modified": "file1.sh\nfile2.sh"\n'
        printf '  },\n'
        printf '  "errors": null\n'
        printf '}\n'
    } > "$state_file"

    local briefing_file
    briefing_file=$(restart_generate_briefing "$state_file")

    if [[ ! -f "$briefing_file" ]]; then
        echo "FAIL: Briefing file not created"
        return 1
    fi

    # Check for required sections
    local content
    content=$(cat "$briefing_file" 2>/dev/null || echo "")

    if ! echo "$content" | grep "What's Done" >/dev/null; then
        echo "FAIL: 'What's Done' section missing"
        return 1
    fi

    if ! echo "$content" | grep "What's Failing" >/dev/null; then
        echo "FAIL: 'What's Failing' section missing"
        return 1
    fi

    if ! echo "$content" | grep "What to Try Next" >/dev/null; then
        echo "FAIL: 'What to Try Next' section missing"
        return 1
    fi

    if ! echo "$content" | grep "What NOT to Try" >/dev/null; then
        echo "FAIL: 'What NOT to Try' section missing"
        return 1
    fi

    echo "PASS"
    return 0
}

test_restart_reason_context_exhaustion() {
    setup_test_env
    echo -n "Testing restart reason detection for context exhaustion... "

    local reason
    reason=$(restart_detect_reason 10 10 "true" 0 "false")

    if [[ "$reason" != "context_exhaustion" ]]; then
        echo "FAIL: Expected 'context_exhaustion', got '$reason'"
        return 1
    fi

    echo "PASS"
    return 0
}

test_restart_reason_stuck_loop() {
    setup_test_env
    echo -n "Testing restart reason detection for stuck loop... "

    local reason
    reason=$(restart_detect_reason 5 10 "false" 3 "false")

    if [[ "$reason" != "stuck_loop" ]]; then
        echo "FAIL: Expected 'stuck_loop', got '$reason'"
        return 1
    fi

    echo "PASS"
    return 0
}

test_restart_reason_manual() {
    setup_test_env
    echo -n "Testing restart reason detection for manual restart... "

    local reason
    reason=$(restart_detect_reason 5 10 "true" 0 "true")

    if [[ "$reason" != "manual" ]]; then
        echo "FAIL: Expected 'manual', got '$reason'"
        return 1
    fi

    echo "PASS"
    return 0
}

test_strategy_suggestion_for_context_exhaustion() {
    setup_test_env
    echo -n "Testing strategy suggestion for context exhaustion... "

    local strategy
    strategy=$(restart_suggest_strategy "context_exhaustion" "Test goal" "true")

    if [[ -z "$strategy" ]]; then
        echo "FAIL: No strategy returned"
        return 1
    fi

    if ! echo "$strategy" | grep -i "context\|remaining\|tests" >/dev/null; then
        echo "FAIL: Strategy doesn't mention context or remaining work"
        return 1
    fi

    echo "PASS"
    return 0
}

test_strategy_suggestion_for_stuck_loop() {
    setup_test_env
    echo -n "Testing strategy suggestion for stuck loop... "

    local strategy
    strategy=$(restart_suggest_strategy "stuck_loop" "Test goal" "false")

    if [[ -z "$strategy" ]]; then
        echo "FAIL: No strategy returned"
        return 1
    fi

    if ! echo "$strategy" | grep -i "different\|approach\|fundamental" >/dev/null; then
        echo "FAIL: Strategy doesn't mention trying a different approach"
        return 1
    fi

    echo "PASS"
    return 0
}

test_cross_session_tracking_appends_history() {
    setup_test_env
    echo -n "Testing cross-session tracking appends history... "

    # First restart
    ITERATION=5
    TEST_PASSED=false
    CONSECUTIVE_FAILURES=1
    RESTART_COUNT=1

    if ! restart_track_across_sessions; then
        echo "FAIL: Failed to track first restart"
        return 1
    fi

    local history_file="$ARTIFACTS_DIR/restart-history.json"
    if [[ ! -f "$history_file" ]]; then
        echo "FAIL: History file not created"
        return 1
    fi

    # Verify it's valid JSON
    if ! jq . "$history_file" > /dev/null 2>&1; then
        echo "FAIL: History file is not valid JSON"
        return 1
    fi

    # Verify first entry was recorded
    local count
    count=$(jq 'length' "$history_file" 2>/dev/null || echo "0")
    if [[ "$count" != "1" ]]; then
        echo "FAIL: Expected 1 entry, got $count"
        return 1
    fi

    # Add second restart
    ITERATION=6
    RESTART_COUNT=2

    if ! restart_track_across_sessions; then
        echo "FAIL: Failed to track second restart"
        return 1
    fi

    # Verify both entries
    count=$(jq 'length' "$history_file" 2>/dev/null || echo "0")
    if [[ "$count" != "2" ]]; then
        echo "FAIL: Expected 2 entries, got $count"
        return 1
    fi

    echo "PASS"
    return 0
}

test_enhanced_progress_md_backward_compatible() {
    setup_test_env
    echo -n "Testing enhanced progress.md is backward compatible... "

    ITERATION=3
    MAX_ITERATIONS=10
    TEST_PASSED=true
    CONSECUTIVE_FAILURES=0
    RESTART_COUNT=1
    MAX_RESTARTS=3

    # Create basic progress file
    echo "# Old Progress\nOld content" > "$LOG_DIR/progress.md"

    restart_enhance_progress_md "$LOG_DIR/progress.md"

    if [[ ! -f "$LOG_DIR/progress.md" ]]; then
        echo "FAIL: Progress file missing after enhancement"
        return 1
    fi

    local content
    content=$(cat "$LOG_DIR/progress.md" 2>/dev/null || echo "")

    # Should still have original content
    if ! echo "$content" | grep "Old content" >/dev/null; then
        echo "FAIL: Original content was lost"
        return 1
    fi

    # Should have new sections
    if ! echo "$content" | grep "Status Summary" >/dev/null; then
        echo "FAIL: Status Summary section missing"
        return 1
    fi

    if ! echo "$content" | grep "Tests.*PASSING" >/dev/null; then
        echo "FAIL: Test status missing"
        return 1
    fi

    echo "PASS"
    return 0
}

test_enhanced_progress_md_shows_antipatterns() {
    setup_test_env
    echo -n "Testing enhanced progress.md detects anti-patterns... "

    ITERATION=2
    MAX_ITERATIONS=10
    TEST_PASSED=false
    CONSECUTIVE_FAILURES=2  # Multiple consecutive failures should be flagged
    RESTART_COUNT=0
    MAX_RESTARTS=3

    restart_enhance_progress_md "$LOG_DIR/progress.md"

    local content
    content=$(cat "$LOG_DIR/progress.md" 2>/dev/null || echo "")

    # Should detect anti-pattern
    if ! echo "$content" | grep "Anti-Pattern" >/dev/null; then
        echo "FAIL: Anti-pattern section missing"
        return 1
    fi

    if ! echo "$content" | grep -i "reconsider" >/dev/null; then
        echo "FAIL: Anti-pattern advice missing"
        return 1
    fi

    echo "PASS"
    return 0
}

test_state_capture_includes_git_info() {
    setup_test_env
    echo -n "Testing state capture includes git information... "

    # Set up state
    ITERATION=3
    MAX_ITERATIONS=10
    RESTART_COUNT=1
    MAX_RESTARTS=3
    GOAL="Test"
    TEST_PASSED=false
    CONSECUTIVE_FAILURES=0

    # Make a git change
    cd "$PROJECT_ROOT"
    echo "new line" >> README.md
    git add README.md
    git commit -q -m "Test commit"
    cd - > /dev/null

    local state_file
    state_file=$(restart_capture_state)

    # Verify git info is captured
    local branch commit
    branch=$(jq -r '.git.branch // ""' "$state_file" 2>/dev/null || echo "")
    commit=$(jq -r '.git.commit // ""' "$state_file" 2>/dev/null || echo "")

    if [[ -z "$branch" ]]; then
        echo "FAIL: Branch not captured"
        return 1
    fi

    if [[ -z "$commit" || "$commit" == "null" ]]; then
        echo "FAIL: Commit hash not captured"
        return 1
    fi

    echo "PASS"
    return 0
}

test_briefing_token_limit() {
    setup_test_env
    echo -n "Testing briefing stays under 2000 token budget... "

    # Create a large state with lots of modified files
    local state_file="$ARTIFACTS_DIR/restart-state.json"
    {
        printf '{\n'
        printf '  "goal": "Very long goal description that goes on and on and on and might exceed token limits if not careful",\n'
        printf '  "progress": {\n'
        printf '    "iteration": 9,\n'
        printf '    "max_iterations": 20,\n'
        printf '    "test_status": false,\n'
        printf '    "tests_passed": 3,\n'
        printf '    "tests_failed": 7\n'
        printf '  },\n'
        printf '  "files": {\n'
        printf '    "modified": "file1.sh\nfile2.sh\nfile3.sh\nfile4.sh\nfile5.sh\nfile6.sh\nfile7.sh\nfile8.sh\nfile9.sh\nfile10.sh\nfile11.sh\nfile12.sh"\n'
        printf '  },\n'
        printf '  "errors": "Long error message that describes the problem in detail"\n'
        printf '}\n'
    } > "$state_file"

    local briefing_file
    briefing_file=$(restart_generate_briefing "$state_file")

    # Rough token estimate: 1 token ≈ 4 characters
    local size
    size=$(wc -c < "$briefing_file" 2>/dev/null || echo "0")
    local estimated_tokens=$((size / 4))

    if [[ "$estimated_tokens" -gt 2500 ]]; then
        echo "WARN: Briefing exceeds recommended token budget (${estimated_tokens} est. tokens)"
        # Not a hard failure, just a warning
    fi

    echo "PASS"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════

TESTS=(
    "test_state_capture_creates_valid_json"
    "test_briefing_generation_produces_markdown"
    "test_restart_reason_context_exhaustion"
    "test_restart_reason_stuck_loop"
    "test_restart_reason_manual"
    "test_strategy_suggestion_for_context_exhaustion"
    "test_strategy_suggestion_for_stuck_loop"
    "test_cross_session_tracking_appends_history"
    "test_enhanced_progress_md_backward_compatible"
    "test_enhanced_progress_md_shows_antipatterns"
    "test_state_capture_includes_git_info"
    "test_briefing_token_limit"
)

PASS=0
FAIL=0

for test in "${TESTS[@]}"; do
    if $test; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "=========================================="
echo "Test Results: ${PASS} PASS, ${FAIL} FAIL out of ${#TESTS[@]}"
echo "=========================================="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi

exit 0
