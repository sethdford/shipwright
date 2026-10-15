#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/ci/issue-dispatch-state.sh test — ready, active, handled, fails   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: gh is a mock. `gh run list` prints $RUNS_JSON; `gh api` prints $COMMENTS_JSON.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "CI: issue-dispatch-state Tests"

setup_test_env "ci-issue-dispatch-state"
trap cleanup_test_env EXIT
unset NO_GITHUB

export GITHUB_REPOSITORY="o/r"
export RUNS_JSON="[]" COMMENTS_JSON="[]" GH_FAIL=""
mock_binary "gh" 'case "$1 $2" in
  "run list") [[ "$GH_FAIL" == "run" ]] && exit 1; echo "$RUNS_JSON" ;;
  "api --paginate") [[ "$GH_FAIL" == "api" ]] && exit 1; echo "$COMMENTS_JSON" ;;
  *) exit 99 ;;
esac'

STATE="$SCRIPT_DIR/ci/issue-dispatch-state.sh"
state() { "$STATE" "$@" 2>/dev/null; }
expect_exit() { # <desc> <code> <cmd...>
    local desc="$1" want="$2" rc=0
    shift 2
    "$@" >/dev/null 2>&1 || rc=$?
    assert_eq "$desc" "$want" "$rc"
}
bot() { jq -cn --arg b "$1" '[{createdAt: "2026-10-15T00:00:00Z", body: $b, user: {login: "github-actions[bot]", type: "Bot"}}]'; }
human() { jq -cn --arg b "$1" '[{createdAt: "2026-10-15T00:00:00Z", body: $b, user: {login: "mallory", type: "User"}}]'; }

print_test_section "the first dispatch"
assert_eq "no runs, no comments: ready" "ready" "$(state 7)"
COMMENTS_JSON="$(human 'SHIPWRIGHT-DISPATCHED: run-request x')"
assert_eq "a human's DISPATCHED text does not count: ready" "ready" "$(state 7)"

print_test_section "active and handled"
RUNS_JSON='[{"displayTitle":"Shipwright Pipeline #7"}]'
assert_eq "a queued pipeline run for #7: active" "active" "$(state 7)"
RUNS_JSON="[]"
COMMENTS_JSON="$(bot 'Shipwright dispatch requested. <!-- SHIPWRIGHT-DISPATCHED: run-request x -->')"
assert_eq "a bot DISPATCHED marker: handled" "handled" "$(state 7)"
COMMENTS_JSON="$(bot '⚓ **Shipwright Pipeline Starting**')"
assert_eq "a bot Pipeline comment: handled" "handled" "$(state 7)"
COMMENTS_JSON="$(bot 'Pipeline Auth Failure')"
assert_eq "a bot auth-failure comment: handled" "handled" "$(state 7)"
COMMENTS_JSON="$(bot '<!-- SHIPWRIGHT-RETRY: 2 -->')"
assert_eq "a bot RETRY marker: handled" "handled" "$(state 7)"

print_test_section "fails closed"
COMMENTS_JSON="[]"
GH_FAIL="run"; expect_exit "a failed run listing: exit 1" 1 "$STATE" 7; GH_FAIL=""
GH_FAIL="api"; expect_exit "a failed comment read: exit 1" 1 "$STATE" 7; GH_FAIL=""
COMMENTS_JSON='{"message":"Not Found"}'
expect_exit "a non-array comment page: exit 1" 1 "$STATE" 7
expect_exit "a non-numeric issue: exit 2" 2 "$STATE" abc
assert_eq "a failed read prints nothing" "" "$(GH_FAIL=run state 7 || true)"

print_test_results
