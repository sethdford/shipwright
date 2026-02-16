#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright github-checks test — Validate Checks API wrapper           ║
# ║  Create/update/annotate/list · Pipeline integration · NO_GITHUB guard  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# Prevent inherited NO_GITHUB from breaking mock-gh tests;
# the specific NO_GITHUB guard test re-exports it.
unset NO_GITHUB 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-github-checks-test.XXXXXX")
    mkdir -p "$TEMP_DIR/repo/scripts/lib"
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/repo/.claude/pipeline-artifacts"
    mkdir -p "$TEMP_DIR/bin"

    # Copy the script under test into repo/scripts/ so REPO_DIR auto-resolves to repo/
    cp "$SCRIPT_DIR/sw-github-checks.sh" "$TEMP_DIR/repo/scripts/"

    # Create compat.sh stub
    touch "$TEMP_DIR/repo/scripts/lib/compat.sh"

    # Create a mock git config for _gh_detect_repo
    git -C "$TEMP_DIR/repo" init --quiet 2>/dev/null || true
    git -C "$TEMP_DIR/repo" remote add origin "https://github.com/testowner/testrepo.git" 2>/dev/null || true

    # Create mock gh binary — default: success with a check run response
    cat > "$TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
# Mock gh — logs calls and returns configurable responses
echo "$@" >> "${MOCK_GH_LOG:-/dev/null}"

# Read the full stdin if any (to capture --input -)
if [[ " $* " == *" --input "* ]]; then
    cat > "${MOCK_GH_STDIN:-/dev/null}" 2>/dev/null || true
fi

# Check for forced failure
if [[ "${MOCK_GH_FAIL:-}" == "true" ]]; then
    echo '{"message":"Resource not accessible by integration"}' >&2
    exit 1
fi

# Return configured response
if [[ -n "${MOCK_GH_RESPONSE:-}" ]]; then
    echo "$MOCK_GH_RESPONSE"
else
    echo '{"id": 12345, "name": "test-check", "status": "in_progress"}'
fi
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock jq — use real jq
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}${BOLD}✗${RESET} jq is required for checks tests"
        exit 1
    fi
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# Helper: source the checks script in test context
source_checks() {
    # Override paths so the script uses our temp dirs
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_STDIN="$TEMP_DIR/gh-stdin.log"

    # Reset logs
    : > "$MOCK_GH_LOG"
    : > "$MOCK_GH_STDIN"

    # Source with overridden REPO_DIR
    (
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
    )
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

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
# 1. _gh_checks_available: returns true when API accessible
# ──────────────────────────────────────────────────────────────────────────────
test_checks_available_success() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='{"check_runs":[],"total_count":0}'
    : > "$MOCK_GH_LOG"

    (
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        _GH_CHECKS_AVAILABLE=""
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        _gh_checks_available "testowner" "testrepo"
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. _gh_checks_available: returns false on 403
# ──────────────────────────────────────────────────────────────────────────────
test_checks_available_fail() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL="true"
    : > "$MOCK_GH_LOG"

    local result=0
    (
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        _GH_CHECKS_AVAILABLE=""
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        _gh_checks_available "testowner" "testrepo"
    ) || result=$?

    # Should return non-zero
    [[ "$result" -ne 0 ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. gh_checks_create_run: returns run ID from response
# ──────────────────────────────────────────────────────────────────────────────
test_create_run_returns_id() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_STDIN="$TEMP_DIR/gh-stdin.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='{"id": 99887, "name": "shipwright/build", "status": "in_progress"}'
    : > "$MOCK_GH_LOG"

    local run_id
    run_id=$(
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        gh_checks_create_run "testowner" "testrepo" "abc123" "shipwright/build" "in_progress"
    )

    [[ "$run_id" == "99887" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. gh_checks_create_run: handles 403 gracefully
# ──────────────────────────────────────────────────────────────────────────────
test_create_run_handles_403() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL="true"
    : > "$MOCK_GH_LOG"

    local run_id
    run_id=$(
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        gh_checks_create_run "testowner" "testrepo" "abc123" "test-check" "in_progress"
    )

    # Should return empty string, not fail
    [[ -z "$run_id" || "$run_id" == "" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. gh_checks_update_run: sends correct PATCH request
# ──────────────────────────────────────────────────────────────────────────────
test_update_run_sends_patch() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_STDIN="$TEMP_DIR/gh-stdin.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='{}'
    : > "$MOCK_GH_LOG"
    : > "$MOCK_GH_STDIN"

    (
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        gh_checks_update_run "testowner" "testrepo" "12345" "completed" "success" "Build passed" "All tests green" ""
    ) >/dev/null 2>&1

    # Verify PATCH was called with correct endpoint
    grep -q "repos/testowner/testrepo/check-runs/12345" "$MOCK_GH_LOG"
    grep -q "PATCH" "$MOCK_GH_LOG"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. gh_checks_update_run: skips when run_id empty
# ──────────────────────────────────────────────────────────────────────────────
test_update_run_skips_empty_id() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL=""
    : > "$MOCK_GH_LOG"

    (
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        gh_checks_update_run "testowner" "testrepo" "" "completed" "success"
    ) >/dev/null 2>&1

    # No gh calls should have been made
    local call_count
    call_count=$(wc -l < "$MOCK_GH_LOG" | tr -d ' ')
    [[ "$call_count" -eq 0 ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. gh_checks_annotate: respects 50-annotation limit
# ──────────────────────────────────────────────────────────────────────────────
test_annotate_batches_at_50() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_STDIN="$TEMP_DIR/gh-stdin.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='{}'
    : > "$MOCK_GH_LOG"

    # Create 75 annotations (should require 2 API calls)
    local annotations="["
    local i
    for i in $(seq 1 75); do
        [[ "$i" -gt 1 ]] && annotations="${annotations},"
        annotations="${annotations}{\"path\":\"file${i}.ts\",\"start_line\":${i},\"end_line\":${i},\"annotation_level\":\"warning\",\"message\":\"Issue ${i}\"}"
    done
    annotations="${annotations}]"

    (
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        gh_checks_annotate "testowner" "testrepo" "12345" "$annotations"
    ) >/dev/null 2>&1

    # Should have made exactly 2 API calls (50 + 25)
    local call_count
    call_count=$(grep -c "check-runs/12345" "$MOCK_GH_LOG" || true)
    [[ "$call_count" -eq 2 ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. gh_checks_list_runs: parses response correctly
# ──────────────────────────────────────────────────────────────────────────────
test_list_runs_parses() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='{"check_runs":[{"id":111,"name":"build","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:05:00Z"},{"id":222,"name":"test","status":"in_progress","conclusion":null,"started_at":"2026-01-01T00:00:00Z","completed_at":null}]}'
    : > "$MOCK_GH_LOG"

    local result
    result=$(
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        gh_checks_list_runs "testowner" "testrepo" "abc123"
    )

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
    [[ "$count" -eq 2 ]]

    local first_name
    first_name=$(echo "$result" | jq -r '.[0].name' 2>/dev/null || true)
    [[ "$first_name" == "build" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. gh_checks_complete: convenience wrapper works
# ──────────────────────────────────────────────────────────────────────────────
test_complete_wrapper() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_STDIN="$TEMP_DIR/gh-stdin.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='{}'
    : > "$MOCK_GH_LOG"

    (
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        gh_checks_complete "testowner" "testrepo" "12345" "success" "All good"
    ) >/dev/null 2>&1

    # Should have called PATCH on the check run
    grep -q "repos/testowner/testrepo/check-runs/12345" "$MOCK_GH_LOG"
    grep -q "PATCH" "$MOCK_GH_LOG"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. gh_checks_pipeline_start: creates runs for all stages
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_start_creates_all() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL=""
    # Each create call returns a unique ID based on a counter file
    cat > "$TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "$@" >> "${MOCK_GH_LOG:-/dev/null}"
if [[ " $* " == *" --input "* ]]; then
    cat > /dev/null 2>/dev/null || true
fi
# Increment a counter for unique IDs
COUNTER_FILE="${MOCK_COUNTER_FILE:-/tmp/gh-counter}"
if [[ ! -f "$COUNTER_FILE" ]]; then echo "1000" > "$COUNTER_FILE"; fi
ID=$(cat "$COUNTER_FILE")
echo "$(( ID + 1 ))" > "$COUNTER_FILE"
echo "{\"id\": ${ID}, \"name\": \"test\", \"status\": \"queued\"}"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/gh"

    export MOCK_COUNTER_FILE="$TEMP_DIR/counter"
    echo "1000" > "$MOCK_COUNTER_FILE"
    : > "$MOCK_GH_LOG"

    local result
    result=$(
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        REPO_DIR="$TEMP_DIR/repo"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        gh_checks_pipeline_start "testowner" "testrepo" "abc123" '["build","test","review"]'
    )

    # Should have 3 entries in the result
    local count
    count=$(echo "$result" | jq 'keys | length' 2>/dev/null || echo "0")
    [[ "$count" -eq 3 ]]

    # check-run-ids.json should exist
    [[ -f "$TEMP_DIR/repo/.claude/pipeline-artifacts/check-run-ids.json" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. gh_checks_stage_update: looks up stored run IDs
# ──────────────────────────────────────────────────────────────────────────────
test_stage_update_uses_stored_ids() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='{}'
    : > "$MOCK_GH_LOG"

    # Pre-create the check-run-ids.json
    echo '{"build":"55555","test":"66666","review":"77777"}' > "$TEMP_DIR/repo/.claude/pipeline-artifacts/check-run-ids.json"

    (
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"
        REPO_DIR="$TEMP_DIR/repo"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        gh_checks_stage_update "test" "completed" "success" "Tests passed"
    ) >/dev/null 2>&1

    # Should have called PATCH on run ID 66666
    grep -q "check-runs/66666" "$MOCK_GH_LOG"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. NO_GITHUB: all functions return early
# ──────────────────────────────────────────────────────────────────────────────
test_no_github_guard() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export NO_GITHUB="true"
    : > "$MOCK_GH_LOG"

    (
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/repo/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        _GH_CHECKS_AVAILABLE=""
        source "$TEMP_DIR/repo/scripts/sw-github-checks.sh"

        # All of these should return early without calling gh
        gh_checks_create_run "testowner" "testrepo" "abc123" "test" "in_progress"
        gh_checks_update_run "testowner" "testrepo" "12345" "completed" "success"
        gh_checks_annotate "testowner" "testrepo" "12345" '[{"path":"f.ts","start_line":1,"end_line":1,"annotation_level":"warning","message":"x"}]'
        gh_checks_complete "testowner" "testrepo" "12345" "success"
        gh_checks_pipeline_start "testowner" "testrepo" "abc123" '["build","test"]'
        gh_checks_stage_update "build" "completed" "success"
    ) >/dev/null 2>&1

    # No gh calls should have been made
    local call_count
    call_count=$(wc -l < "$MOCK_GH_LOG" | tr -d ' ')
    [[ "$call_count" -eq 0 ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright github-checks — Test Suite            ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for checks tests"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# Availability tests
echo -e "${PURPLE}${BOLD}Checks API Availability${RESET}"
run_test "_gh_checks_available: returns true when API accessible" test_checks_available_success
run_test "_gh_checks_available: returns false on 403" test_checks_available_fail
echo ""

# CRUD tests
echo -e "${PURPLE}${BOLD}Check Run CRUD${RESET}"
run_test "gh_checks_create_run: returns run ID from response" test_create_run_returns_id
run_test "gh_checks_create_run: handles 403 gracefully" test_create_run_handles_403
run_test "gh_checks_update_run: sends correct PATCH request" test_update_run_sends_patch
run_test "gh_checks_update_run: skips when run_id empty" test_update_run_skips_empty_id
run_test "gh_checks_annotate: respects 50-annotation limit" test_annotate_batches_at_50
run_test "gh_checks_list_runs: parses response correctly" test_list_runs_parses
run_test "gh_checks_complete: convenience wrapper works" test_complete_wrapper
echo ""

# Pipeline integration tests
echo -e "${PURPLE}${BOLD}Pipeline Integration${RESET}"
run_test "gh_checks_pipeline_start: creates runs for all stages" test_pipeline_start_creates_all
run_test "gh_checks_stage_update: looks up stored run IDs" test_stage_update_uses_stored_ids
echo ""

# Guard tests
echo -e "${PURPLE}${BOLD}NO_GITHUB Guard${RESET}"
run_test "NO_GITHUB: all functions return early" test_no_github_guard
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
else
    echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo ""

exit "$FAIL"
