#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright github-deploy test — Validate Deployments API wrapper      ║
# ║  Create/update/list/rollback · Pipeline integration · NO_GITHUB guard  ║
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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-github-deploy-test.XXXXXX")
    mkdir -p "$TEMP_DIR/scripts/lib"
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/repo/.claude/pipeline-artifacts"
    mkdir -p "$TEMP_DIR/bin"

    # Copy the script under test
    cp "$SCRIPT_DIR/sw-github-deploy.sh" "$TEMP_DIR/scripts/"

    # Create compat.sh stub
    touch "$TEMP_DIR/scripts/lib/compat.sh"

    # Create a mock git repo for _gh_detect_repo
    git -C "$TEMP_DIR/repo" init --quiet 2>/dev/null || true
    git -C "$TEMP_DIR/repo" remote add origin "https://github.com/testowner/testrepo.git" 2>/dev/null || true

    # Create mock gh binary — default: success with deployment response
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
    echo '{"message":"Not Found"}' >&2
    exit 1
fi

# Return configured response
if [[ -n "${MOCK_GH_RESPONSE:-}" ]]; then
    echo "$MOCK_GH_RESPONSE"
else
    echo '{"id": 54321, "ref": "main", "environment": "production"}'
fi
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock jq — use real jq
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}${BOLD}✗${RESET} jq is required for deploy tests"
        exit 1
    fi
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

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
# 1. gh_deploy_create: returns deployment ID
# ──────────────────────────────────────────────────────────────────────────────
test_deploy_create_returns_id() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_STDIN="$TEMP_DIR/gh-stdin.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='{"id": 77001, "ref": "feat-branch", "environment": "staging"}'
    : > "$MOCK_GH_LOG"

    local deploy_id
    deploy_id=$(
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/scripts/sw-github-deploy.sh"
        gh_deploy_create "testowner" "testrepo" "feat-branch" "staging" "Test deployment"
    )

    [[ "$deploy_id" == "77001" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. gh_deploy_create: handles 403 gracefully
# ──────────────────────────────────────────────────────────────────────────────
test_deploy_create_handles_403() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL="true"
    : > "$MOCK_GH_LOG"

    local deploy_id
    deploy_id=$(
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/scripts/sw-github-deploy.sh"
        gh_deploy_create "testowner" "testrepo" "main" "production" "Test"
    )

    # Should return empty, not fail
    [[ -z "$deploy_id" || "$deploy_id" == "" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. gh_deploy_update_status: sends correct POST
# ──────────────────────────────────────────────────────────────────────────────
test_deploy_update_status_post() {
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
        SCRIPT_DIR="$TEMP_DIR/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/scripts/sw-github-deploy.sh"
        gh_deploy_update_status "testowner" "testrepo" "77001" "success" "https://app.example.com" "Deployed successfully"
    ) >/dev/null 2>&1

    # Verify POST was called on the correct endpoint
    grep -q "repos/testowner/testrepo/deployments/77001/statuses" "$MOCK_GH_LOG"
    grep -q "POST" "$MOCK_GH_LOG"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. gh_deploy_update_status: skips when deploy_id empty
# ──────────────────────────────────────────────────────────────────────────────
test_deploy_update_status_skips_empty() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL=""
    : > "$MOCK_GH_LOG"

    (
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/scripts/sw-github-deploy.sh"
        gh_deploy_update_status "testowner" "testrepo" "" "success"
    ) >/dev/null 2>&1

    # No gh calls should have been made
    local call_count
    call_count=$(wc -l < "$MOCK_GH_LOG" | tr -d ' ')
    [[ "$call_count" -eq 0 ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. gh_deploy_list: parses deployment list
# ──────────────────────────────────────────────────────────────────────────────
test_deploy_list_parses() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='[{"id":100,"ref":"main","environment":"production","description":"Deploy 1","created_at":"2026-01-01T00:00:00Z"},{"id":101,"ref":"feat","environment":"staging","description":"Deploy 2","created_at":"2026-01-02T00:00:00Z"}]'
    : > "$MOCK_GH_LOG"

    local result
    result=$(
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/scripts/sw-github-deploy.sh"
        gh_deploy_list "testowner" "testrepo" "" 10
    )

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
    [[ "$count" -eq 2 ]]

    local first_ref
    first_ref=$(echo "$result" | jq -r '.[0].ref' 2>/dev/null || true)
    [[ "$first_ref" == "main" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. gh_deploy_latest: returns first result
# ──────────────────────────────────────────────────────────────────────────────
test_deploy_latest_returns_first() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='[{"id":200,"ref":"v2.0","environment":"production","description":"Latest","created_at":"2026-02-01T00:00:00Z"}]'
    : > "$MOCK_GH_LOG"

    local result
    result=$(
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/scripts/sw-github-deploy.sh"
        gh_deploy_latest "testowner" "testrepo" "production"
    )

    local dep_id
    dep_id=$(echo "$result" | jq -r '.id' 2>/dev/null || true)
    [[ "$dep_id" == "200" ]]

    local dep_ref
    dep_ref=$(echo "$result" | jq -r '.ref' 2>/dev/null || true)
    [[ "$dep_ref" == "v2.0" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. gh_deploy_rollback: creates new deployment with prev ref
# ──────────────────────────────────────────────────────────────────────────────
test_deploy_rollback() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_STDIN="$TEMP_DIR/gh-stdin.log"
    export MOCK_GH_FAIL=""
    : > "$MOCK_GH_LOG"
    : > "$MOCK_GH_STDIN"

    # Create a smart mock that returns different responses per call
    cat > "$TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "$@" >> "${MOCK_GH_LOG:-/dev/null}"
if [[ " $* " == *" --input "* ]]; then
    cat > "${MOCK_GH_STDIN:-/dev/null}" 2>/dev/null || true
fi

CALL_FILE="${MOCK_CALL_COUNTER:-/tmp/gh-call-counter}"
if [[ ! -f "$CALL_FILE" ]]; then echo "0" > "$CALL_FILE"; fi
CALL_NUM=$(cat "$CALL_FILE")
echo "$(( CALL_NUM + 1 ))" > "$CALL_FILE"

# First call: list deployments (returns 2)
if [[ "$CALL_NUM" -eq 0 ]]; then
    echo '[{"id":300,"ref":"v3.0","environment":"production"},{"id":299,"ref":"v2.9","environment":"production"}]'
# Second call: update status (mark current as inactive)
elif [[ "$CALL_NUM" -eq 1 ]]; then
    echo '{}'
# Third call: create new deployment (rollback)
elif [[ "$CALL_NUM" -eq 2 ]]; then
    echo '{"id":301,"ref":"v2.9","environment":"production"}'
# Fourth call: update status (mark new as success)
elif [[ "$CALL_NUM" -eq 3 ]]; then
    echo '{}'
fi
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/gh"

    export MOCK_CALL_COUNTER="$TEMP_DIR/call-counter"
    echo "0" > "$MOCK_CALL_COUNTER"

    local result
    result=$(
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/scripts/sw-github-deploy.sh"
        gh_deploy_rollback "testowner" "testrepo" "production" "Rolling back"
    )

    # Should return the new deployment ID
    [[ "$result" == "301" ]]

    # Should have made multiple API calls
    local call_count
    call_count=$(wc -l < "$MOCK_GH_LOG" | tr -d ' ')
    [[ "$call_count" -ge 3 ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. gh_deploy_pipeline_start: stores deployment ID
# ──────────────────────────────────────────────────────────────────────────────
test_deploy_pipeline_start() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_STDIN="$TEMP_DIR/gh-stdin.log"
    export MOCK_GH_FAIL=""
    : > "$MOCK_GH_LOG"

    # Smart mock: first call creates deployment, second updates status
    cat > "$TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "$@" >> "${MOCK_GH_LOG:-/dev/null}"
if [[ " $* " == *" --input "* ]]; then
    cat > /dev/null 2>/dev/null || true
fi

CALL_FILE="${MOCK_CALL_COUNTER:-/tmp/gh-call-counter}"
if [[ ! -f "$CALL_FILE" ]]; then echo "0" > "$CALL_FILE"; fi
CALL_NUM=$(cat "$CALL_FILE")
echo "$(( CALL_NUM + 1 ))" > "$CALL_FILE"

if [[ "$CALL_NUM" -eq 0 ]]; then
    echo '{"id":88888,"ref":"main","environment":"staging"}'
else
    echo '{}'
fi
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/gh"

    export MOCK_CALL_COUNTER="$TEMP_DIR/call-counter2"
    echo "0" > "$MOCK_CALL_COUNTER"

    local deploy_id
    deploy_id=$(
        source "$TEMP_DIR/scripts/sw-github-deploy.sh"
        REPO_DIR="$TEMP_DIR/repo"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        gh_deploy_pipeline_start "testowner" "testrepo" "main" "staging"
    )

    [[ "$deploy_id" == "88888" ]]

    # deployment.json should exist
    [[ -f "$TEMP_DIR/repo/.claude/pipeline-artifacts/deployment.json" ]]

    # Verify contents
    local stored_id
    stored_id=$(jq -r '.deploy_id' "$TEMP_DIR/repo/.claude/pipeline-artifacts/deployment.json" 2>/dev/null || true)
    [[ "$stored_id" == "88888" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. gh_deploy_pipeline_complete: updates status correctly
# ──────────────────────────────────────────────────────────────────────────────
test_deploy_pipeline_complete() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export MOCK_GH_FAIL=""
    export MOCK_GH_RESPONSE='{}'
    : > "$MOCK_GH_LOG"

    # Restore default mock
    cat > "$TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "$@" >> "${MOCK_GH_LOG:-/dev/null}"
if [[ " $* " == *" --input "* ]]; then
    cat > /dev/null 2>/dev/null || true
fi
echo '{}'
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/gh"

    # Pre-create the deployment.json
    echo '{"deploy_id":"99999","environment":"production","ref":"main","started_at":"2026-01-01T00:00:00Z"}' \
        > "$TEMP_DIR/repo/.claude/pipeline-artifacts/deployment.json"

    (
        source "$TEMP_DIR/scripts/sw-github-deploy.sh"
        REPO_DIR="$TEMP_DIR/repo"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        gh_deploy_pipeline_complete "testowner" "testrepo" "production" "true" "https://app.example.com"
    ) >/dev/null 2>&1

    # Should have called POST on deployments/99999/statuses
    grep -q "deployments/99999/statuses" "$MOCK_GH_LOG"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. NO_GITHUB: all functions return early
# ──────────────────────────────────────────────────────────────────────────────
test_no_github_guard() {
    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export MOCK_GH_LOG="$TEMP_DIR/gh-calls.log"
    export NO_GITHUB="true"
    : > "$MOCK_GH_LOG"

    # Pre-create deployment.json for pipeline_complete test
    echo '{"deploy_id":"11111","environment":"production","ref":"main","started_at":"2026-01-01T00:00:00Z"}' \
        > "$TEMP_DIR/repo/.claude/pipeline-artifacts/deployment.json"

    (
        REPO_DIR="$TEMP_DIR/repo"
        SCRIPT_DIR="$TEMP_DIR/scripts"
        ARTIFACTS_DIR="$TEMP_DIR/repo/.claude/pipeline-artifacts"
        source "$TEMP_DIR/scripts/sw-github-deploy.sh"

        # All of these should return early without calling gh
        gh_deploy_create "testowner" "testrepo" "main" "production" "Test"
        gh_deploy_update_status "testowner" "testrepo" "12345" "success"
        gh_deploy_list "testowner" "testrepo" "" 10
        gh_deploy_latest "testowner" "testrepo" "production"
        gh_deploy_rollback "testowner" "testrepo" "production"
        gh_deploy_pipeline_start "testowner" "testrepo" "main" "staging"
        gh_deploy_pipeline_complete "testowner" "testrepo" "production" "true"
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
echo -e "${CYAN}${BOLD}║  shipwright github-deploy — Test Suite            ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for deploy tests"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# CRUD tests
echo -e "${PURPLE}${BOLD}Deployment CRUD${RESET}"
run_test "gh_deploy_create: returns deployment ID" test_deploy_create_returns_id
run_test "gh_deploy_create: handles 403 gracefully" test_deploy_create_handles_403
run_test "gh_deploy_update_status: sends correct POST" test_deploy_update_status_post
run_test "gh_deploy_update_status: skips when deploy_id empty" test_deploy_update_status_skips_empty
run_test "gh_deploy_list: parses deployment list" test_deploy_list_parses
run_test "gh_deploy_latest: returns first result" test_deploy_latest_returns_first
echo ""

# Rollback tests
echo -e "${PURPLE}${BOLD}Rollback${RESET}"
run_test "gh_deploy_rollback: creates new deployment with prev ref" test_deploy_rollback
echo ""

# Pipeline integration tests
echo -e "${PURPLE}${BOLD}Pipeline Integration${RESET}"
run_test "gh_deploy_pipeline_start: stores deployment ID" test_deploy_pipeline_start
run_test "gh_deploy_pipeline_complete: updates status correctly" test_deploy_pipeline_complete
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
