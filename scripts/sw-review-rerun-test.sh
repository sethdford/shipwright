#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright review-rerun test — SHA-deduped rerun comment writer         ║
# ║  Tests: get_rerun_marker, rerun_already_requested, request_rerun,         ║
# ║  check_rerun_state, missing issue number, gh failures                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-review-rerun-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/config"
    mkdir -p "$REPO_DIR/config"  # Ensure config exists for policy.json

    # Mock gh — gh pr view uses --jq '.comments[].body' so we output that directly
    cat > "$TEMP_DIR/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_CALLS_FILE:-/dev/null}" 2>/dev/null || true
if [[ "${MOCK_GH_FAIL:-0}" == "1" ]]; then
    echo "gh: failed" >&2
    exit 1
fi
case "${1:-}" in
    pr)
        case "${2:-}" in
            view)
                # Third arg is pr number (gh pr view N); if empty, check_rerun_state fails
                if [[ -z "${3:-}" ]]; then
                    printf ''
                    exit 0
                fi
                # gh pr view N --json comments --jq '.comments[].body' or --jq '.headRefOid'
                if [[ -n "${MOCK_GH_PR_VIEW_BODIES:-}" ]]; then
                    printf '%s' "$MOCK_GH_PR_VIEW_BODIES"
                elif grep -q "headRefOid" <<< "$*" 2>/dev/null; then
                    printf '%s' "${MOCK_GH_HEAD_SHA:-abc123def}"
                else
                    printf 'no marker'
                fi
                ;;
            comment)
                exit 0
                ;;
            *)
                echo "{}"
                ;;
        esac
        ;;
    *)
        echo "{}"
        ;;
esac
exit 0
GH_EOF
    chmod +x "$TEMP_DIR/bin/gh"

    ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq" 2>/dev/null || true

    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export REPO_DIR="$REPO_DIR"
    export SCRIPT_DIR="$SCRIPT_DIR"
    export GH_CALLS_FILE="$TEMP_DIR/gh-calls.log"
    : > "$GH_CALLS_FILE"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

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
# TESTS — Source and test sw-review-rerun.sh functions
# sw-review-rerun has: get_rerun_marker, rerun_already_requested, request_rerun,
# check_rerun_state. Main is invoked when run as script.
# ═══════════════════════════════════════════════════════════════════════════════

test_sources_correctly() {
    (
        export REPO_DIR="$REPO_DIR"
        source "$SCRIPT_DIR/sw-review-rerun.sh"
        type get_rerun_marker >/dev/null 2>&1 || return 1
        type rerun_already_requested >/dev/null 2>&1 || return 1
        type request_rerun >/dev/null 2>&1 || return 1
        type check_rerun_state >/dev/null 2>&1 || return 1
    )
}

test_get_rerun_marker_default() {
    rm -f "$REPO_DIR/config/policy.json"
    marker=$(export REPO_DIR="$REPO_DIR"; source "$SCRIPT_DIR/sw-review-rerun.sh" 2>/dev/null; get_rerun_marker)
    [[ "$marker" == *"shipwright-review-rerun"* ]] || return 1
}

test_get_rerun_marker_from_policy() {
    mkdir -p "$REPO_DIR/config"
    echo '{"codeReviewAgent":{"rerunMarker":"<!-- custom-marker -->"}}' > "$REPO_DIR/config/policy.json"
    marker=$(export REPO_DIR="$REPO_DIR"; source "$SCRIPT_DIR/sw-review-rerun.sh" 2>/dev/null; get_rerun_marker)
    [[ "$marker" == *"custom-marker"* ]] || return 1
}

test_rerun_already_requested_true() {
    rm -f "$REPO_DIR/config/policy.json"
    (
        export REPO_DIR="$REPO_DIR"
        export MOCK_GH_PR_VIEW_BODIES='<!-- shipwright-review-rerun -->

**Review Rerun Requested**

sha:abc123def

---'
        source "$SCRIPT_DIR/sw-review-rerun.sh"
        rerun_already_requested "1" "abc123def"
    )
}

test_rerun_already_requested_false() {
    (
        export REPO_DIR="$REPO_DIR"
        export MOCK_GH_PR_VIEW_BODIES='Some other comment'
        source "$SCRIPT_DIR/sw-review-rerun.sh"
        ! rerun_already_requested "1" "abc123def"
    )
}

test_rerun_different_comments_different_shas() {
    rm -f "$REPO_DIR/config/policy.json"
    # SHA abc123: already requested
    # SHA xyz789: not requested
    (
        export REPO_DIR="$REPO_DIR"
        export MOCK_GH_PR_VIEW_BODIES='<!-- shipwright-review-rerun -->

sha:abc123

---'
        source "$SCRIPT_DIR/sw-review-rerun.sh"
        rerun_already_requested "1" "abc123" || return 1
        ! rerun_already_requested "1" "xyz789" || return 1
    )
}

test_request_rerun_missing_pr_number() {
    local output
    output=$(export REPO_DIR="$REPO_DIR"; source "$SCRIPT_DIR/sw-review-rerun.sh" 2>/dev/null; request_rerun "" "abc123" 2>&1) || true
    echo "$output" | grep -q "Usage\|pr_number\|Missing" || return 1
}

test_request_rerun_missing_sha() {
    local output
    output=$(export REPO_DIR="$REPO_DIR"; source "$SCRIPT_DIR/sw-review-rerun.sh" 2>/dev/null; request_rerun "42" "" 2>&1) || true
    echo "$output" | grep -q "Usage\|head_sha\|Missing" || return 1
}

test_request_rerun_skips_when_already_requested() {
    : > "$GH_CALLS_FILE"
    rm -f "$REPO_DIR/config/policy.json"
    (
        export REPO_DIR="$REPO_DIR"
        export MOCK_GH_PR_VIEW_BODIES='<!-- shipwright-review-rerun -->

sha:abc12345

---'
        export GH_CALLS_FILE="$GH_CALLS_FILE"
        source "$SCRIPT_DIR/sw-review-rerun.sh"
        request_rerun "1" "abc12345" 2>/dev/null
    )
    ! grep -q "pr comment" "$GH_CALLS_FILE" 2>/dev/null || return 1
}

test_request_rerun_posts_when_not_requested() {
    : > "$GH_CALLS_FILE"
    (
        export REPO_DIR="$REPO_DIR"
        export MOCK_GH_PR_VIEW_BODIES='random comment'
        export GH_CALLS_FILE="$GH_CALLS_FILE"
        source "$SCRIPT_DIR/sw-review-rerun.sh"
        request_rerun "1" "deadbeef123" 2>/dev/null
    )
    grep -q "pr comment" "$GH_CALLS_FILE" 2>/dev/null || return 1
}

test_request_rerun_gh_failure_graceful() {
    local output
    output=$(export REPO_DIR="$REPO_DIR" MOCK_GH_PR_VIEW_BODIES='other' MOCK_GH_FAIL=1; source "$SCRIPT_DIR/sw-review-rerun.sh" 2>/dev/null; request_rerun "1" "abc123" 2>&1) || true
    echo "$output" | grep -q "Failed\|error\|Error" || return 1
}

test_check_rerun_state_missing_pr() {
    local output
    output=$(export REPO_DIR="$REPO_DIR"; source "$SCRIPT_DIR/sw-review-rerun.sh" 2>/dev/null; check_rerun_state "" 2>&1) || true
    echo "$output" | grep -q "Could not get head SHA\|error\|Usage" || return 1
}

test_main_help() {
    output=$(bash "$SCRIPT_DIR/sw-review-rerun.sh" help 2>&1)
    echo "$output" | grep -q "request\|check\|wait" || return 1
}

test_main_unknown_subcommand() {
    output=$(bash "$SCRIPT_DIR/sw-review-rerun.sh" unknown_cmd 2>&1) || ec=$?
    echo "$output" | grep -q "Unknown\|unknown" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    echo ""
    echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  shipwright review-rerun — Test Suite (14 tests)          ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    echo -e "${DIM}Setting up test environment...${RESET}"
    setup_env
    echo ""

    echo -e "${PURPLE}${BOLD}Core functions${RESET}"
    run_test "Sources correctly and exports expected functions" test_sources_correctly
    run_test "get_rerun_marker returns default when no policy" test_get_rerun_marker_default
    run_test "get_rerun_marker reads from policy.json" test_get_rerun_marker_from_policy
    echo ""

    echo -e "${PURPLE}${BOLD}SHA deduplication${RESET}"
    run_test "rerun_already_requested returns true when marker+sha present" test_rerun_already_requested_true
    run_test "rerun_already_requested returns false when no marker" test_rerun_already_requested_false
    run_test "Different SHAs get different dedup results" test_rerun_different_comments_different_shas
    run_test "request_rerun skips when same SHA already requested" test_request_rerun_skips_when_already_requested
    run_test "request_rerun posts when SHA not yet requested" test_request_rerun_posts_when_not_requested
    echo ""

    echo -e "${PURPLE}${BOLD}Error handling${RESET}"
    run_test "request_rerun handles missing PR number" test_request_rerun_missing_pr_number
    run_test "request_rerun handles missing SHA" test_request_rerun_missing_sha
    run_test "request_rerun handles gh failure gracefully" test_request_rerun_gh_failure_graceful
    run_test "check_rerun_state handles missing issue number" test_check_rerun_state_missing_pr
    echo ""

    echo -e "${PURPLE}${BOLD}Main entry${RESET}"
    run_test "main help shows subcommands" test_main_help
    run_test "main unknown subcommand errors" test_main_unknown_subcommand
    echo ""

    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${RESET}"
    if [[ "$FAIL" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
    else
        echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
    fi
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${RESET}"
    echo ""
    exit "$FAIL"
}

main "$@"
