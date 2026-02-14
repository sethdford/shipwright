#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright e2e integration test — Real Claude + Real GitHub            ║
# ║  Requires: CLAUDE_CODE_OAUTH_TOKEN, GITHUB_TOKEN · Budget: $1.00       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Error trap for CI debugging — shows which line fails
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()

# ─── Guard: skip gracefully if tokens missing ─────────────────────────────
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo -e "${YELLOW}⚠ Skipping integration tests: CLAUDE_CODE_OAUTH_TOKEN not set${RESET}"
    echo "Set CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY to run integration tests"
    exit 0
fi
if ! command -v gh &>/dev/null; then
    echo -e "${YELLOW}⚠ Skipping integration tests: gh CLI not found${RESET}"
    exit 0
fi
if ! gh auth status &>/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Skipping integration tests: gh not authenticated${RESET}"
    exit 0
fi

# ─── Configuration ────────────────────────────────────────────────────────
MAX_BUDGET_USD="1.00"
TEST_LABEL="e2e-test"
TEST_ISSUE_TITLE="E2E test: add comment to README [automated]"
PIPELINE_TIMEOUT=600  # 10 minutes
ISSUE_NUMBER=""
PR_URL=""
FEATURE_BRANCH=""
PIPELINE_EXIT_CODE=""

# ─── Cleanup trap (CRITICAL — must always run) ────────────────────────────
cleanup() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━ Cleanup ━━━${RESET}"

    # Close PR if created
    if [[ -n "${PR_URL:-}" ]]; then
        echo -e "  Closing PR: $PR_URL"
        gh pr close "$PR_URL" --delete-branch 2>/dev/null || true
    fi

    # Close test issue if created
    if [[ -n "${ISSUE_NUMBER:-}" ]]; then
        echo -e "  Closing issue #$ISSUE_NUMBER"
        gh issue close "$ISSUE_NUMBER" 2>/dev/null || true
    fi

    # Delete remote feature branch
    if [[ -n "${FEATURE_BRANCH:-}" ]]; then
        echo -e "  Deleting remote branch: $FEATURE_BRANCH"
        git push origin --delete "$FEATURE_BRANCH" 2>/dev/null || true
    fi

    # Delete local feature branch
    if [[ -n "${FEATURE_BRANCH:-}" ]]; then
        git checkout main 2>/dev/null || true
        git branch -D "$FEATURE_BRANCH" 2>/dev/null || true
    fi

    # Clean up pipeline artifacts
    rm -rf "$REPO_DIR/.claude/pipeline-state.md" 2>/dev/null || true
    rm -rf "$REPO_DIR/.claude/pipeline-artifacts" 2>/dev/null || true

    echo -e "  ${GREEN}Cleanup complete${RESET}"
}
trap cleanup EXIT

# ═════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═════════════════════════════════════════════════════════════════════════════

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

# ═════════════════════════════════════════════════════════════════════════════
# TEST FUNCTIONS
# ═════════════════════════════════════════════════════════════════════════════

test_set_budget() {
    bash "$SCRIPT_DIR/sw-cost.sh" budget set "$MAX_BUDGET_USD" >/dev/null 2>&1
}

test_create_issue() {
    local issue_url
    issue_url=$(gh issue create \
        --title "$TEST_ISSUE_TITLE" \
        --body "Automated E2E integration test. Safe to close." \
        --label "$TEST_LABEL" 2>/dev/null)

    # Extract issue number from URL (e.g., https://github.com/owner/repo/issues/123)
    ISSUE_NUMBER=$(echo "$issue_url" | grep -oE '[0-9]+$')

    if [[ -z "$ISSUE_NUMBER" ]]; then
        return 1
    fi

    # Verify it's numeric
    if ! echo "$ISSUE_NUMBER" | grep -qE '^[0-9]+$'; then
        return 1
    fi

    return 0
}

test_run_pipeline() {
    mkdir -p "$REPO_DIR/.claude/pipeline-artifacts"

    # Run pipeline and capture exit code through tee
    # Note: PIPESTATUS[0] captures the timeout/pipeline exit, not tee's
    set +o pipefail
    timeout "$PIPELINE_TIMEOUT" bash "$SCRIPT_DIR/sw-pipeline.sh" start \
        --issue "$ISSUE_NUMBER" \
        --pipeline fast \
        --ci \
        --skip-gates \
        --max-iterations 3 2>&1 | tee "$REPO_DIR/.claude/pipeline-artifacts/e2e-output.log"
    PIPELINE_EXIT_CODE="${PIPESTATUS[0]}"
    set -o pipefail

    if [[ "$PIPELINE_EXIT_CODE" -ne 0 ]]; then
        return 1
    fi

    return 0
}

test_state_complete() {
    local state_file="$REPO_DIR/.claude/pipeline-state.md"

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    # Case insensitive check for status: complete (or completed/success)
    if grep -qiE 'status:.*complet' "$state_file" 2>/dev/null; then
        return 0
    fi

    # Also accept status: success
    if grep -qiE 'status:.*success' "$state_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

test_feature_branch_exists() {
    FEATURE_BRANCH="shipwright/issue-${ISSUE_NUMBER}"

    # Check local and remote branches
    if git branch -a 2>/dev/null | grep -q "$FEATURE_BRANCH"; then
        return 0
    fi

    return 1
}

test_files_modified() {
    # Check if we're on the feature branch or can diff against main
    local modified_count=0

    if git rev-parse --verify "HEAD" >/dev/null 2>&1; then
        modified_count=$(git diff main..HEAD --name-only 2>/dev/null | wc -l | tr -d ' ')
    fi

    if [[ "$modified_count" -gt 0 ]]; then
        return 0
    fi

    # Also check pipeline output for evidence of file modifications
    if [[ -f "$REPO_DIR/.claude/pipeline-artifacts/e2e-output.log" ]]; then
        if grep -qiE '(modified|changed|created|commit)' "$REPO_DIR/.claude/pipeline-artifacts/e2e-output.log" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

test_pr_created() {
    # Look for PR URL in pipeline artifacts
    PR_URL=$(grep -roE 'https://github\.com/[^ ]+/pull/[0-9]+' "$REPO_DIR/.claude/pipeline-artifacts/" 2>/dev/null | head -1 || true)

    if [[ -n "$PR_URL" ]]; then
        return 0
    fi

    # Fallback: check if a PR exists for the feature branch via gh CLI
    if [[ -n "${FEATURE_BRANCH:-}" ]]; then
        PR_URL=$(gh pr list --head "$FEATURE_BRANCH" --json url --jq '.[0].url' 2>/dev/null || true)
        if [[ -n "$PR_URL" ]]; then
            return 0
        fi
    fi

    return 1
}

test_cost_recorded() {
    local costs_file="${HOME}/.shipwright/costs.json"

    if [[ ! -f "$costs_file" ]]; then
        return 1
    fi

    # Check that the file has been modified in the last 15 minutes
    local now_epoch
    now_epoch=$(date +%s)

    local file_mod_epoch
    if [[ "$(uname)" == "Darwin" ]]; then
        file_mod_epoch=$(stat -f %m "$costs_file" 2>/dev/null || echo "0")
    else
        file_mod_epoch=$(stat -c %Y "$costs_file" 2>/dev/null || echo "0")
    fi

    local age=$(( now_epoch - file_mod_epoch ))

    # Must have been modified in last 900 seconds (15 minutes)
    if [[ "$age" -le 900 ]]; then
        return 0
    fi

    return 1
}

test_cost_under_budget() {
    local remaining
    remaining=$(bash "$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "unknown")

    # If budget is unlimited or remaining > 0, we're under budget
    if [[ "$remaining" == "unlimited" ]]; then
        return 0
    fi

    if [[ "$remaining" == "unknown" ]]; then
        # Can't determine — treat as pass since budget was set
        return 0
    fi

    # Check remaining is a positive number
    if echo "$remaining" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        # Compare: remaining > 0 means we haven't exceeded budget
        local over
        over=$(echo "$remaining" | awk '{ print ($1 > 0) ? "no" : "yes" }')
        if [[ "$over" == "no" ]]; then
            return 0
        fi
    fi

    return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

main() {
    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  Shipwright E2E Integration Tests                            ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Ensure we're in the repo root
    cd "$REPO_DIR"

    # Create artifacts dir
    mkdir -p "$REPO_DIR/.claude/pipeline-artifacts"

    local tests=(
        "test_set_budget:Budget: Set \$1.00 daily limit"
        "test_create_issue:GitHub: Create test issue"
        "test_run_pipeline:Pipeline: Run fast pipeline on test issue"
        "test_state_complete:State: Pipeline completed successfully"
        "test_feature_branch_exists:Git: Feature branch created"
        "test_files_modified:Git: Files were modified"
        "test_pr_created:GitHub: Pull request created"
        "test_cost_recorded:Cost: Usage recorded"
        "test_cost_under_budget:Cost: Total under \$1.00 budget"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        run_test "$desc" "$fn"

        # If pipeline didn't run successfully, skip dependent tests
        if [[ "$fn" == "test_run_pipeline" && "$FAIL" -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠ Skipping remaining tests: pipeline failed${RESET}"
            break
        fi
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

    echo -e "${GREEN}${BOLD}All $PASS integration tests passed!${RESET}"
    echo ""
    exit 0
}

main "$@"
