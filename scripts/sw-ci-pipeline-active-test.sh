#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/ci/pipeline-active.sh test — is a pipeline running for an issue  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: gh is a mock that prints $RUNS_DIR/<status>.json for `--status <status>`.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "CI: pipeline-active Tests"

setup_test_env "ci-pipeline-active"
trap cleanup_test_env EXIT
unset NO_GITHUB

export GITHUB_REPOSITORY="o/r"
export RUNS_DIR="$TEST_TEMP_DIR/runs"
export GH_ARGS="$TEST_TEMP_DIR/gh.args"
mkdir -p "$RUNS_DIR"
mock_binary "gh" 'echo "$*" >> "$GH_ARGS"
status=""
while [[ $# -gt 0 ]]; do [[ "$1" == "--status" ]] && status="$2"; shift; done
if [[ -f "$RUNS_DIR/$status.json" ]]; then cat "$RUNS_DIR/$status.json"; else echo "[]"; fi'

ACTIVE="$SCRIPT_DIR/ci/pipeline-active.sh"
active() { "$ACTIVE" "$@" 2>/dev/null; }
runs() { printf '%s' "$2" > "$RUNS_DIR/$1.json"; }
expect_exit() { # <desc> <code> <cmd...>
    local desc="$1" want="$2" rc=0
    shift 2
    "$@" >/dev/null 2>&1 || rc=$?
    assert_eq "$desc" "$want" "$rc"
}

print_test_section "detection"
assert_eq "no runs: false" "false" "$(active 7)"
grep -q -- "--workflow shipwright-pipeline.yml" "$GH_ARGS" && assert_pass "lists shipwright-pipeline.yml runs" \
    || assert_fail "lists shipwright-pipeline.yml runs"
for s in in_progress queued waiting pending requested; do
    rm -f "$RUNS_DIR"/*.json
    runs "$s" '[{"displayTitle":"Shipwright: fix the thing #7"}]'
    assert_eq "a ${s} run titled ...#7: true" "true" "$(active 7)"
done
rm -f "$RUNS_DIR"/*.json
runs in_progress '[{"displayTitle":"Pipeline #7 (retry 2)"}]'
assert_eq "#7 followed by a space: true" "true" "$(active 7)"
runs in_progress '[{"displayTitle":"Pipeline #77"},{"displayTitle":"Pipeline #17"},{"displayTitle":"7"}]'
assert_eq "#77, #17 and a bare 7 do not match #7" "false" "$(active 7)"

print_test_section "fails closed"
expect_exit "rejects a non-numeric issue" 2 "$ACTIVE" "7|x"
expect_exit "rejects a missing issue" 2 "$ACTIVE"
expect_exit "rejects a bad GITHUB_REPOSITORY" 2 env GITHUB_REPOSITORY="o" "$ACTIVE" 7
expect_exit "NO_GITHUB=true: exit 1" 1 env NO_GITHUB=true "$ACTIVE" 7
mock_binary "gh" 'echo "HTTP 502" >&2; exit 1'
expect_exit "gh failure: exit 1" 1 "$ACTIVE" 7
assert_eq "gh failure prints nothing" "" "$(active 7 || true)"
mock_binary "gh" 'echo "{\"message\":\"Not Found\"}"'
expect_exit "a non-array response: exit 1" 1 "$ACTIVE" 7
mock_binary "gh" 'echo "[{\"displayTitle\":"'
expect_exit "malformed JSON: exit 1" 1 "$ACTIVE" 7
mock_binary "gh" 'true'
expect_exit "empty output: exit 1" 1 "$ACTIVE" 7

print_test_results
