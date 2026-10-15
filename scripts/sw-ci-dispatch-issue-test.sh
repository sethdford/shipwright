#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/ci/dispatch-issue.sh test — marker first, then dispatch          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: gh is a mock that appends its argv to $GH_CALLS and fails on demand via FAIL_ON.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "CI: dispatch-issue Tests"

setup_test_env "ci-dispatch-issue"
trap cleanup_test_env EXIT
unset NO_GITHUB

export GITHUB_REPOSITORY="o/r"
export GH_CALLS="$TEST_TEMP_DIR/gh.calls"
export GH_ARGS="$TEST_TEMP_DIR/gh.args"
export FAIL_ON=""
mock_binary "gh" 'echo "$1 $2" >> "$GH_CALLS"
echo "$*" >> "$GH_ARGS"
if [[ -n "$FAIL_ON" && "$1 $2" == "$FAIL_ON" ]]; then exit 1; fi
exit 0'

DISPATCH="$SCRIPT_DIR/ci/dispatch-issue.sh"
run_dispatch() { : > "$GH_CALLS"; : > "$GH_ARGS"; "$DISPATCH" "$@" >/dev/null 2>&1 || return $?; }
expect_exit() { # <desc> <code> <cmd...>
    local desc="$1" want="$2" rc=0
    shift 2
    "$@" >/dev/null 2>&1 || rc=$?
    assert_eq "$desc" "$want" "$rc"
}

print_test_section "order and arguments"
run_dispatch 42
assert_eq "posts the marker, then dispatches (two gh calls, in order)" "issue comment
workflow run" "$(cat "$GH_CALLS")"
grep -q -- "^issue comment 42 --repo o/r " "$GH_ARGS" && assert_pass "first call posts the marker on #42" || assert_fail "first call posts the marker on #42"
grep -q -- "^workflow run shipwright-pipeline.yml --repo o/r -f issue_number=42 -f template=standard$" "$GH_ARGS" && assert_pass "second call dispatches shipwright-pipeline.yml for #42" || assert_fail "second call dispatches shipwright-pipeline.yml for #42"

print_test_section "fails closed"
export FAIL_ON="issue comment"
expect_exit "a failed marker: exit 1" 1 run_dispatch 42
assert_eq "a failed marker means no dispatch" "issue comment" "$(cat "$GH_CALLS")"
export FAIL_ON="workflow run"
expect_exit "a failed dispatch: exit 1" 1 run_dispatch 42
export FAIL_ON=""
expect_exit "a non-numeric issue: exit 2" 2 run_dispatch abc
expect_exit "issue 0: exit 2" 2 run_dispatch 0
assert_eq "bad input calls nothing" "" "$(cat "$GH_CALLS")"

print_test_results
