#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fix test — Unit tests for bulk fix across repos                   ║
# ║  Mock pipelines · Arg parsing · Dry run · Status · Parallel limits      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SCRIPT="$SCRIPT_DIR/cct-fix.sh"

# ─── Colors (matches cct theme) ──────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cct-fix-test.XXXXXX")

    # Create directory structure
    mkdir -p "$TEMP_DIR/home/.claude-teams"
    mkdir -p "$TEMP_DIR/bin"

    # Create mock repos with git
    for repo in api web mobile; do
        mkdir -p "$TEMP_DIR/repos/$repo/.git/refs/remotes/origin"
        echo "ref: refs/remotes/origin/main" > "$TEMP_DIR/repos/$repo/.git/refs/remotes/origin/HEAD"
        echo "[core]" > "$TEMP_DIR/repos/$repo/.git/config"
        echo "ref: refs/heads/main" > "$TEMP_DIR/repos/$repo/.git/HEAD"
        mkdir -p "$TEMP_DIR/repos/$repo/.git/refs/heads"
    done

    # Create mock git binary
    cat > "$TEMP_DIR/bin/git" << 'MOCK_GIT'
#!/usr/bin/env bash
MOCK_LOG="${MOCK_GIT_LOG:-/tmp/mock-git.log}"
echo "git $*" >> "$MOCK_LOG"
case "$1" in
    symbolic-ref)
        echo "refs/remotes/origin/main"
        ;;
    checkout)
        exit 0
        ;;
    status)
        echo "On branch main"
        ;;
esac
exit 0
MOCK_GIT
    chmod +x "$TEMP_DIR/bin/git"

    # Create mock cct-pipeline.sh
    cat > "$TEMP_DIR/bin/cct-pipeline.sh" << 'MOCK_PIPELINE'
#!/usr/bin/env bash
MOCK_LOG="${MOCK_PIPELINE_LOG:-/tmp/mock-pipeline.log}"
echo "pipeline $*" >> "$MOCK_LOG"
# Simulate quick pipeline run
sleep 0.1
echo "https://github.com/test/repo/pull/42"
exit 0
MOCK_PIPELINE
    chmod +x "$TEMP_DIR/bin/cct-pipeline.sh"

    # Also place it where fix_start looks for it ($SCRIPT_DIR/cct-pipeline.sh)
    cp "$TEMP_DIR/bin/cct-pipeline.sh" "$SCRIPT_DIR/cct-pipeline.sh.mock" 2>/dev/null || true

    # Set environment
    export MOCK_GIT_LOG="$TEMP_DIR/git-calls.log"
    export MOCK_PIPELINE_LOG="$TEMP_DIR/pipeline-calls.log"
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export EVENTS_FILE="$TEMP_DIR/home/.claude-teams/events.jsonl"
    export NO_GITHUB=true
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    # Clean up mock pipeline if we placed one
    rm -f "$SCRIPT_DIR/cct-pipeline.sh.mock" 2>/dev/null || true
}
trap cleanup_env EXIT

# Reset between tests
reset_test() {
    rm -f "$MOCK_GIT_LOG"
    rm -f "$MOCK_PIPELINE_LOG"
    rm -f "$EVENTS_FILE"
    rm -f "$TEMP_DIR/home/.claude-teams"/fix-*.json
    rm -rf "$TEMP_DIR/home/.claude-teams"/fix-*-logs
    touch "$MOCK_GIT_LOG"
    touch "$MOCK_PIPELINE_LOG"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERTIONS
# ═══════════════════════════════════════════════════════════════════════════════

assert_equals() {
    local expected="$1" actual="$2" label="${3:-value}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected '$expected', got '$actual' ($label)"
    return 1
}

assert_contains() {
    local haystack="$1" needle="$2" label="${3:-contains}"
    if printf '%s\n' "$haystack" | grep -qE -- "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $needle ($label)"
    echo -e "    ${DIM}Got: $(printf '%s\n' "$haystack" | head -3 2>/dev/null)${RESET}"
    return 1
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-not contains}"
    if ! printf '%s\n' "$haystack" | grep -qE -- "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output unexpectedly contains: $needle ($label)"
    return 1
}

assert_file_exists() {
    local filepath="$1" label="${2:-file exists}"
    if [[ -f "$filepath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
    return 1
}

assert_exit_code() {
    local expected="$1" actual="$2" label="${3:-exit code}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected exit code $expected, got $actual ($label)"
    return 1
}

assert_gt() {
    local actual="$1" threshold="$2" label="${3:-greater than}"
    if [[ "$actual" -gt "$threshold" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected $actual > $threshold ($label)"
    return 1
}

assert_json_key() {
    local json="$1" key="$2" expected="$3" label="${4:-json key}"
    local actual
    actual=$(echo "$json" | jq -r "$key" 2>/dev/null)
    assert_equals "$expected" "$actual" "$label"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    reset_test

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Help output contains expected sections
# ──────────────────────────────────────────────────────────────────────────────
test_help_output() {
    local output
    output=$(bash "$FIX_SCRIPT" help 2>&1) || true

    assert_contains "$output" "shipwright fix" "mentions fix" &&
    assert_contains "$output" "USAGE" "has USAGE section" &&
    assert_contains "$output" "OPTIONS" "has OPTIONS section" &&
    assert_contains "$output" "--repos" "mentions --repos" &&
    assert_contains "$output" "--repos-from" "mentions --repos-from" &&
    assert_contains "$output" "--pipeline" "mentions --pipeline" &&
    assert_contains "$output" "--max-parallel" "mentions --max-parallel" &&
    assert_contains "$output" "--dry-run" "mentions --dry-run" &&
    assert_contains "$output" "--status" "mentions --status" &&
    assert_contains "$output" "EXAMPLES" "has EXAMPLES section"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Help via --help flag
# ──────────────────────────────────────────────────────────────────────────────
test_help_flag() {
    local output
    output=$(bash "$FIX_SCRIPT" --help 2>&1) || true

    assert_contains "$output" "USAGE" "--help shows usage"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Missing goal shows error
# ──────────────────────────────────────────────────────────────────────────────
test_missing_goal() {
    local output exit_code=0
    output=$(bash "$FIX_SCRIPT" --repos "$TEMP_DIR/repos/api" 2>&1) || exit_code=$?

    assert_contains "$output" "Goal is required" "reports missing goal" &&
    assert_exit_code "1" "$exit_code" "exits with 1"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Missing repos shows error
# ──────────────────────────────────────────────────────────────────────────────
test_missing_repos() {
    local output exit_code=0
    output=$(bash "$FIX_SCRIPT" "Update deps" 2>&1) || exit_code=$?

    assert_contains "$output" "No repos specified" "reports missing repos" &&
    assert_exit_code "1" "$exit_code" "exits with 1"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Arg parsing — --repos comma-separated
# ──────────────────────────────────────────────────────────────────────────────
test_arg_repos_comma() {
    local output
    output=$(bash "$FIX_SCRIPT" "Update deps" \
        --repos "$TEMP_DIR/repos/api,$TEMP_DIR/repos/web" \
        --dry-run 2>&1) || true

    assert_contains "$output" "Repos:.*2" "parsed 2 repos" &&
    assert_contains "$output" "api" "includes api repo" &&
    assert_contains "$output" "web" "includes web repo"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Arg parsing — --repos-from file
# ──────────────────────────────────────────────────────────────────────────────
test_arg_repos_from_file() {
    local repos_file="$TEMP_DIR/repos.txt"
    echo "$TEMP_DIR/repos/api" > "$repos_file"
    echo "$TEMP_DIR/repos/web" >> "$repos_file"
    echo "# this is a comment" >> "$repos_file"
    echo "" >> "$repos_file"

    local output
    output=$(bash "$FIX_SCRIPT" "Update deps" \
        --repos-from "$repos_file" \
        --dry-run 2>&1) || true

    assert_contains "$output" "Repos:.*2" "parsed 2 repos from file" &&
    assert_contains "$output" "api" "includes api" &&
    assert_contains "$output" "web" "includes web"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Arg parsing — --repos-from missing file
# ──────────────────────────────────────────────────────────────────────────────
test_arg_repos_from_missing() {
    local output exit_code=0
    output=$(bash "$FIX_SCRIPT" "Update deps" \
        --repos-from /nonexistent/repos.txt 2>&1) || exit_code=$?

    assert_contains "$output" "Repos file not found" "reports missing file" &&
    assert_exit_code "1" "$exit_code" "exits with 1"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Arg parsing — --pipeline template
# ──────────────────────────────────────────────────────────────────────────────
test_arg_pipeline() {
    local output
    output=$(bash "$FIX_SCRIPT" "Update deps" \
        --repos "$TEMP_DIR/repos/api" \
        --pipeline hotfix \
        --dry-run 2>&1) || true

    assert_contains "$output" "Pipeline:.*hotfix" "pipeline set to hotfix"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Arg parsing — --max-parallel
# ──────────────────────────────────────────────────────────────────────────────
test_arg_max_parallel() {
    local output
    output=$(bash "$FIX_SCRIPT" "Update deps" \
        --repos "$TEMP_DIR/repos/api" \
        --max-parallel 5 \
        --dry-run 2>&1) || true

    assert_contains "$output" "Parallel:.*5" "max_parallel set to 5"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Arg parsing — --branch-prefix
# ──────────────────────────────────────────────────────────────────────────────
test_arg_branch_prefix() {
    local output
    output=$(bash "$FIX_SCRIPT" "Update deps" \
        --repos "$TEMP_DIR/repos/api" \
        --branch-prefix "hotfix/" \
        --dry-run 2>&1) || true

    assert_contains "$output" "Branch:.*hotfix/" "branch prefix set"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Dry run — shows what would happen
# ──────────────────────────────────────────────────────────────────────────────
test_dry_run() {
    local output
    output=$(bash "$FIX_SCRIPT" "Update lodash to 4.17.21" \
        --repos "$TEMP_DIR/repos/api,$TEMP_DIR/repos/web" \
        --dry-run 2>&1) || true

    assert_contains "$output" "Dry run" "says dry run" &&
    assert_contains "$output" "git checkout" "shows git checkout command" &&
    assert_contains "$output" "cct-pipeline" "shows pipeline command" &&
    assert_contains "$output" "update-lodash-to-4-17-21" "shows sanitized branch name"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Dry run does not create state file
# ──────────────────────────────────────────────────────────────────────────────
test_dry_run_no_state() {
    bash "$FIX_SCRIPT" "Update deps" \
        --repos "$TEMP_DIR/repos/api" \
        --dry-run > /dev/null 2>&1 || true

    local fix_files
    fix_files=$(find "$TEMP_DIR/home/.claude-teams" -name 'fix-*.json' -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')

    assert_equals "0" "$fix_files" "no state file created in dry run"
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Fix status — no sessions
# ──────────────────────────────────────────────────────────────────────────────
test_fix_status_empty() {
    local output
    output=$(bash "$FIX_SCRIPT" --status 2>&1) || true

    assert_contains "$output" "No fix sessions" "reports no sessions"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Fix status — shows existing sessions
# ──────────────────────────────────────────────────────────────────────────────
test_fix_status_with_sessions() {
    mkdir -p "$TEMP_DIR/home/.claude-teams"
    # Create a mock fix state file
    jq -n '{
        goal: "Update lodash",
        branch: "fix/update-lodash",
        template: "fast",
        started: "2025-01-01T00:00:00Z",
        session_id: "fix-12345",
        status: "completed",
        repos: [
            {"name": "api", "path": "/tmp/api", "status": "pass", "pr_url": "https://github.com/test/api/pull/1", "duration": "5m"},
            {"name": "web", "path": "/tmp/web", "status": "fail", "pr_url": "-", "duration": "3m"}
        ]
    }' > "$TEMP_DIR/home/.claude-teams/fix-12345.json"

    local output
    output=$(bash "$FIX_SCRIPT" --status 2>&1) || true

    assert_contains "$output" "Fix Sessions" "shows sessions header" &&
    assert_contains "$output" "Update lodash" "shows goal" &&
    assert_contains "$output" "completed" "shows status" &&
    assert_contains "$output" "api" "shows api repo" &&
    assert_contains "$output" "web" "shows web repo"
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Invalid repo directory shows error
# ──────────────────────────────────────────────────────────────────────────────
test_invalid_repo() {
    local output exit_code=0
    output=$(bash "$FIX_SCRIPT" "Update deps" \
        --repos "/nonexistent/path" 2>&1) || exit_code=$?

    assert_contains "$output" "not found" "reports missing repo" &&
    assert_exit_code "1" "$exit_code" "exits with 1"
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. Fix start creates state file
# ──────────────────────────────────────────────────────────────────────────────
test_fix_start_state() {
    local output
    output=$(bash "$FIX_SCRIPT" "Update deps" \
        --repos "$TEMP_DIR/repos/api" 2>&1) || true

    local fix_files
    fix_files=$(find "$TEMP_DIR/home/.claude-teams" -name 'fix-*.json' -maxdepth 1 2>/dev/null)

    if [[ -z "$fix_files" ]]; then
        echo -e "    ${RED}✗${RESET} No state file created"
        return 1
    fi

    local state_file
    state_file=$(echo "$fix_files" | head -1)
    assert_file_exists "$state_file" "state file created" &&
    local goal
    goal=$(jq -r '.goal' "$state_file" 2>/dev/null)
    assert_equals "Update deps" "$goal" "goal recorded in state"
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. Fix start emits events
# ──────────────────────────────────────────────────────────────────────────────
test_fix_start_events() {
    bash "$FIX_SCRIPT" "Update deps" \
        --repos "$TEMP_DIR/repos/api" > /dev/null 2>&1 || true

    assert_file_exists "$EVENTS_FILE" "events file created" &&
    local events
    events=$(cat "$EVENTS_FILE")
    assert_contains "$events" "fix.started" "fix.started event" &&
    assert_contains "$events" "fix.completed" "fix.completed event"
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. Fix start — summary output
# ──────────────────────────────────────────────────────────────────────────────
test_fix_start_summary() {
    local output
    output=$(bash "$FIX_SCRIPT" "Update deps" \
        --repos "$TEMP_DIR/repos/api" 2>&1) || true

    assert_contains "$output" "Fix Complete" "shows completion header" &&
    assert_contains "$output" "Success:" "shows success count" &&
    assert_contains "$output" "Duration:" "shows duration"
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. Fix start — branch sanitization
# ──────────────────────────────────────────────────────────────────────────────
test_branch_sanitization() {
    local output
    output=$(bash "$FIX_SCRIPT" "Update lodash to 4.17.21!" \
        --repos "$TEMP_DIR/repos/api" \
        --dry-run 2>&1) || true

    # Branch should be lowercase, special chars replaced with hyphens
    assert_contains "$output" "fix/update-lodash-to-4-17-21" "branch sanitized correctly" &&
    assert_not_contains "$output" "fix/Update" "no uppercase in branch" &&
    # Check that the Branch: line doesn't contain special chars (exclude goal text which has the raw goal)
    local branch_line
    branch_line=$(echo "$output" | grep -E "Branch:" || echo "")
    assert_not_contains "$branch_line" "!" "no special chars in branch"
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. Fix start — header shows configuration
# ──────────────────────────────────────────────────────────────────────────────
test_fix_header() {
    local output
    output=$(bash "$FIX_SCRIPT" "Upgrade React" \
        --repos "$TEMP_DIR/repos/api,$TEMP_DIR/repos/web" \
        --pipeline hotfix \
        --max-parallel 5 \
        --model sonnet \
        --dry-run 2>&1) || true

    assert_contains "$output" "Goal:.*Upgrade React" "header shows goal" &&
    assert_contains "$output" "Repos:.*2" "header shows repo count" &&
    assert_contains "$output" "Pipeline:.*hotfix" "header shows pipeline" &&
    assert_contains "$output" "Parallel:.*5" "header shows parallel" &&
    assert_contains "$output" "Model:.*sonnet" "header shows model"
}

# ──────────────────────────────────────────────────────────────────────────────
# 21. Fix start — non-git repo warning
# ──────────────────────────────────────────────────────────────────────────────
test_non_git_repo_warning() {
    mkdir -p "$TEMP_DIR/repos/nongit"
    # No .git dir

    local output
    output=$(bash "$FIX_SCRIPT" "Update deps" \
        --repos "$TEMP_DIR/repos/nongit" \
        --dry-run 2>&1) || true

    assert_contains "$output" "Not a git repo" "warns about non-git dir"
}

# ──────────────────────────────────────────────────────────────────────────────
# 22. Fix per-repo event tracking
# ──────────────────────────────────────────────────────────────────────────────
test_fix_repo_events() {
    bash "$FIX_SCRIPT" "Update deps" \
        --repos "$TEMP_DIR/repos/api,$TEMP_DIR/repos/web" > /dev/null 2>&1 || true

    assert_file_exists "$EVENTS_FILE" "events file exists" &&
    local events
    events=$(cat "$EVENTS_FILE")
    assert_contains "$events" "fix.repo.started" "fix.repo.started events" &&
    assert_contains "$events" "fix.repo.completed" "fix.repo.completed events"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright fix test — Unit Tests                                  ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Verify the fix script exists
    if [[ ! -f "$FIX_SCRIPT" ]]; then
        echo -e "${RED}✗ Fix script not found: $FIX_SCRIPT${RESET}"
        exit 1
    fi

    # Verify jq is available
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗ jq is required. Install it: brew install jq${RESET}"
        exit 1
    fi

    echo -e "${DIM}Setting up test environment...${RESET}"
    setup_env
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEMP_DIR${RESET}"
    echo ""

    # Define all tests
    local -a tests=(
        "test_help_output:Help output contains expected sections"
        "test_help_flag:Help via --help flag"
        "test_missing_goal:Missing goal shows error"
        "test_missing_repos:Missing repos shows error"
        "test_arg_repos_comma:Arg parsing — --repos comma-separated"
        "test_arg_repos_from_file:Arg parsing — --repos-from file"
        "test_arg_repos_from_missing:Arg parsing — --repos-from missing file"
        "test_arg_pipeline:Arg parsing — --pipeline template"
        "test_arg_max_parallel:Arg parsing — --max-parallel"
        "test_arg_branch_prefix:Arg parsing — --branch-prefix"
        "test_dry_run:Dry run shows what would happen"
        "test_dry_run_no_state:Dry run does not create state file"
        "test_fix_status_empty:Fix status — no sessions"
        "test_fix_status_with_sessions:Fix status shows existing sessions"
        "test_invalid_repo:Invalid repo directory shows error"
        "test_fix_start_state:Fix start creates state file"
        "test_fix_start_events:Fix start emits events"
        "test_fix_start_summary:Fix start — summary output"
        "test_branch_sanitization:Branch name sanitization"
        "test_fix_header:Fix header shows configuration"
        "test_non_git_repo_warning:Non-git repo warning"
        "test_fix_repo_events:Per-repo event tracking"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        if [[ -n "$filter" && "$fn" != "$filter" ]]; then
            continue
        fi

        run_test "$desc" "$fn"
    done

    # ── Summary ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}Passed:${RESET} $PASS"
    echo -e "  ${RED}Failed:${RESET} $FAIL"
    echo -e "  ${DIM}Total:${RESET}  $TOTAL"
    echo ""

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${RED}${BOLD}Failed tests:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi

    echo -e "${GREEN}${BOLD}All $PASS tests passed!${RESET}"
    echo ""
    exit 0
}

main "$@"
