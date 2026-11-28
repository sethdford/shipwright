#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  merge stage CI state — _merge_ci_state never reads an error as "pass"    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: gh is a mock that prints $GH_OUT and exits $GH_RC.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: merge CI state Tests"

setup_test_env "sw-lib-merge-ci-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

export GH_OUT="" GH_RC=0
mock_binary "gh" 'printf "%s" "$GH_OUT"; exit "$GH_RC"'
source "$SCRIPT_DIR/lib/pipeline-stages-delivery.sh"

state() { GH_OUT="$1" GH_RC="${2:-0}" _merge_ci_state 42; }

print_test_section "check buckets"
assert_eq "all pass" "pass" "$(state '[{"bucket":"pass"},{"bucket":"pass"}]')"
assert_eq "pass and skipping is pass" "pass" "$(state '[{"bucket":"pass"},{"bucket":"skipping"}]')"
assert_eq "any fail is fail" "fail" "$(state '[{"bucket":"pass"},{"bucket":"fail"}]' 1)"
assert_eq "a cancelled check is fail" "fail" "$(state '[{"bucket":"pass"},{"bucket":"cancel"}]')"
assert_eq "pending with passes is pending" "pending" "$(state '[{"bucket":"pass"},{"bucket":"pending"}]' 8)"
assert_eq "pending is pending even when gh exits 8" "pending" "$(state '[{"bucket":"pending"}]' 8)"

print_test_section "no answer is never pass"
assert_eq "no checks reported (gh error text) is none" "none" "$(state 'no checks reported on the branch' 1)"
assert_eq "an empty list is none" "none" "$(state '[]')"
assert_eq "gh failing with no output is none" "none" "$(state '' 1)"
assert_eq "two JSON values (the old fallback) is none, not judged by the last" "none" "$(state '[{"bucket":"fail"}]["pass"]' 1)"

print_test_results
