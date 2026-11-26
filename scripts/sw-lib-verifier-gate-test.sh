#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/verifier-gate test — the merge verifier before a PR       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: bun is a mock that prints a canned verdict; no network, temp HOME.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: verifier-gate Tests"

setup_test_env "lib-verifier-gate"
trap 'cleanup_test_env; sw_test_teardown' EXIT

export BUN_LOG="$TEST_TEMP_DIR/bun.log"
export BUN_EXIT=0
export BUN_OUT='{"probability":0.62,"decision":{"verdict":"pass","wouldBe":"pass","reasons":[]}}'
# Logs each argument on its own line and copies the body file so tests can read it.
mock_binary "bun" 'printf "%s\n" "$@" >> "$BUN_LOG"; prev=""; for a in "$@"; do [[ "$prev" == "--body-file" ]] && cp "$a" "$BUN_LOG.body"; prev="$a"; done; printf "%s" "$BUN_OUT"; exit "$BUN_EXIT"'

source "$SCRIPT_DIR/lib/verifier-gate.sh"

print_test_section "verifier_gate"

assert_file_exists "CLI path resolves to src/cli.ts" "$VERIFIER_TS_CLI"

: > "$BUN_LOG"
rc=0
verifier_gate "origin/main" "fix: a (#1)" 'body with $(touch /tmp/pwned) and "quotes"' pass 2>/dev/null || rc=$?
assert_eq "a pass opens the PR" "0" "$rc"
assert_eq "the PR note carries the chance" "Merge verifier: 62% predicted chance to merge (pass)." "$VERIFIER_PR_NOTE"
assert_contains "the title is one argv element" "$(cat "$BUN_LOG")" "fix: a (#1)"
assert_contains "the CLI is asked for json in advisory mode by default" "$(tr '\n' ' ' < "$BUN_LOG")" "--tests pass --mode advisory --format json"
assert_eq "the body reaches the CLI verbatim, through a file" 'body with $(touch /tmp/pwned) and "quotes"' "$(cat "$BUN_LOG.body")"
assert_file_not_exists "the body is never run" "/tmp/pwned"

: > "$BUN_LOG"
export BUN_EXIT=3
export BUN_OUT='{"probability":0.1,"decision":{"verdict":"block","wouldBe":"block","reasons":["no change beyond plans or run output"]}}'
rc=0
SHIPWRIGHT_VERIFIER=enforce verifier_gate "origin/main" "t" "b" 2>/dev/null || rc=$?
assert_eq "exit 3 stops the PR" "1" "$rc"
assert_contains "enforce mode is passed to the CLI" "$(tr '\n' ' ' < "$BUN_LOG")" "--mode enforce"

: > "$BUN_LOG"
rc=0
SHIPWRIGHT_VERIFIER=off verifier_gate "origin/main" "t" "b" 2>/dev/null || rc=$?
assert_eq "off never calls the CLI" "0" "$rc"
assert_eq "off: no CLI call" "" "$(cat "$BUN_LOG")"

export BUN_EXIT=1
export BUN_OUT=""
rc=0
SHIPWRIGHT_VERIFIER=enforce verifier_gate "origin/main" "t" "b" 2>/dev/null || rc=$?
assert_eq "a verifier that cannot run does not block" "0" "$rc"
assert_eq "and leaves no PR note" "" "$VERIFIER_PR_NOTE"

export BUN_EXIT=0
export BUN_OUT="not json"
rc=0
verifier_gate "origin/main" "t" "b" 2>/dev/null || rc=$?
assert_eq "unreadable output does not block" "0" "$rc"

rc=0
SW_BUN="no-such-bun-binary" verifier_gate "origin/main" "t" "b" 2>/dev/null || rc=$?
assert_eq "missing Bun does not block" "0" "$rc"

: > "$BUN_LOG"
export BUN_OUT='{"probability":0.3,"decision":{"verdict":"warn","wouldBe":"warn","reasons":["x"]}}'
verifier_gate "origin/main" "t" "b" bogus 2>/dev/null || true
assert_contains "an unknown test status becomes unknown" "$(tr '\n' ' ' < "$BUN_LOG")" "--tests unknown"
SHIPWRIGHT_VERIFIER=loud verifier_gate "origin/main" "t" "b" 2>/dev/null || true
assert_contains "an unknown mode falls back to advisory" "$(tr '\n' ' ' < "$BUN_LOG")" "--mode advisory"

print_test_section "pipeline wiring"
assert_contains "stage_pr calls the verifier before creating the PR" \
    "$(cat "$SCRIPT_DIR/lib/pipeline-stages-delivery.sh")" 'verifier_gate "origin/$BASE_BRANCH" "$pr_title" "$pr_body"'
assert_contains "pipeline stages source the verifier library" \
    "$(cat "$SCRIPT_DIR/lib/pipeline-stages.sh")" "lib/verifier-gate.sh"

print_test_results
