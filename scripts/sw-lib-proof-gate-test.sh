#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/proof-gate test — run-the-app proof before a PR           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: bun is a mock that prints a canned report; no network, no app, temp HOME.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: proof-gate Tests"

setup_test_env "lib-proof-gate"
trap 'cleanup_test_env; sw_test_teardown' EXIT

export BUN_LOG="$TEST_TEMP_DIR/bun.log"
export BUN_EXIT=0
export BUN_OUT='{"verdict":{"status":"pass","failures":[],"warnings":[]},"section":"### Proof it runs\n\nok"}'
mock_binary "bun" 'printf "%s\n" "$@" >> "$BUN_LOG"; printf "%s" "$BUN_OUT"; exit "$BUN_EXIT"'

source "$SCRIPT_DIR/lib/proof-gate.sh"

print_test_section "proof_gate"

assert_file_exists "CLI path resolves to src/cli.ts" "$PROOF_TS_CLI"

: > "$BUN_LOG"
rc=0
NO_GITHUB=false proof_gate "origin/main" 'feat/x$(touch /tmp/pwned-proof)' "$TEST_TEMP_DIR/out" 2>/dev/null || rc=$?
assert_eq "a pass opens the PR" "0" "$rc"
assert_contains "the PR section comes from the report" "$PROOF_PR_SECTION" "### Proof it runs"
args="$(tr '\n' ' ' < "$BUN_LOG")"
assert_contains "advisory by default, json, published" "$args" "proof run --base origin/main --mode advisory"
assert_contains "artifacts are published by default" "$args" "--publish"
assert_contains "the out dir is passed" "$args" "--out $TEST_TEMP_DIR/out"
case "$args" in *'$(touch'*) assert_fail "the label is sanitised" "$args" ;; *) assert_pass "the label is sanitised" ;; esac
assert_file_not_exists "the label is never run" "/tmp/pwned-proof"

: > "$BUN_LOG"
NO_GITHUB=false SHIPWRIGHT_PROOF_PUBLISH=off proof_gate "origin/main" "b" 2>/dev/null || true
assert_contains "SHIPWRIGHT_PROOF_PUBLISH=off keeps artifacts local" "$(cat "$BUN_LOG")" "--no-publish"
: > "$BUN_LOG"
NO_GITHUB=true proof_gate "origin/main" "b" 2>/dev/null || true
assert_contains "NO_GITHUB keeps artifacts local" "$(cat "$BUN_LOG")" "--no-publish"

: > "$BUN_LOG"
rc=0
SHIPWRIGHT_PROOF=off proof_gate "origin/main" "b" 2>/dev/null || rc=$?
assert_eq "off never runs the CLI" "0" "$(wc -c < "$BUN_LOG" | tr -d ' ')"
assert_eq "off opens the PR" "0" "$rc"

rc=0
BUN_EXIT=3 BUN_OUT='{"verdict":{"status":"fail","failures":["app did not start"],"warnings":[]},"section":"x"}' \
    SHIPWRIGHT_PROOF=enforce proof_gate "origin/main" "b" 2>/dev/null || rc=$?
assert_eq "enforce blocks on exit 3" "1" "$rc"

rc=0
BUN_EXIT=0 BUN_OUT='{"verdict":{"status":"fail","failures":["x"],"warnings":[]},"section":"failed section"}' \
    proof_gate "origin/main" "b" 2>/dev/null || rc=$?
assert_eq "advisory never blocks a failure" "0" "$rc"
assert_eq "and still reports it in the PR" "failed section" "$PROOF_PR_SECTION"

rc=0
BUN_EXIT=1 BUN_OUT='not json' SHIPWRIGHT_PROOF=enforce proof_gate "origin/main" "b" 2>/dev/null || rc=$?
assert_eq "a proof that cannot run never blocks" "0" "$rc"
assert_eq "and adds nothing to the PR" "" "$PROOF_PR_SECTION"

print_test_section "pipeline wiring"
assert_contains "stage_pr runs the proof before creating the PR" \
    "$(cat "$SCRIPT_DIR/lib/pipeline-stages-delivery.sh")" 'proof_gate "origin/$BASE_BRANCH"'
assert_contains "pipeline stages source the proof library" \
    "$(cat "$SCRIPT_DIR/lib/pipeline-stages.sh")" "lib/proof-gate.sh"

print_test_results
