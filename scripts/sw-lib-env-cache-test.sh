#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/env-cache test — bash callers of `env hydrate` (ADR-0020) ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: bun is a mock (the TypeScript side has its own tests); temp HOME, no network.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: env-cache Tests"

setup_test_env "sw-lib-env-cache-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

export BUN_LOG="$TEST_TEMP_DIR/bun.log" BUN_EXIT=0
mock_binary "bun" 'printf "%s\n" "$*" >> "$BUN_LOG"; exit "$BUN_EXIT"'
export SW_TS_CLI="$TEST_TEMP_DIR/cli.ts"
: > "$SW_TS_CLI"
_SW_ENV_CACHE_LOADED=""
source "$SCRIPT_DIR/lib/env-cache.sh"
export SW_ENV_CACHE=1

print_test_section "sw_env_hydrate"
: > "$BUN_LOG"
sw_env_hydrate /repo /repo/wt --ref main --quiet
assert_eq "calls the CLI with root, dir and the extra flags" \
    "$SW_TS_CLI env hydrate --root /repo --dir /repo/wt --ref main --quiet" "$(cat "$BUN_LOG")"
rc=0; BUN_EXIT=1 sw_env_hydrate /repo /repo/wt || rc=$?
assert_eq "returns the CLI's status (setup failed)" "1" "$rc"
rc=0; sw_env_hydrate /repo 2>/dev/null || rc=$?
assert_eq "a missing DIR is a usage error" "2" "$rc"

print_test_section "disabled and missing Bun never fail"
: > "$BUN_LOG"
rc=0; SW_ENV_CACHE=0 sw_env_hydrate /repo /repo/wt || rc=$?
assert_eq "SW_ENV_CACHE=0 returns 0" "0" "$rc"
assert_eq "SW_ENV_CACHE=0 does not call the CLI" "" "$(cat "$BUN_LOG")"
rc=0; (unset SW_ENV_CACHE; SHIPWRIGHT_TEST_MODE=1 sw_env_hydrate /repo /repo/wt) || rc=$?
assert_eq "off by default in test mode" "" "$(cat "$BUN_LOG")"
rc=0; err="$(SW_BUN=/nonexistent/bun sw_env_hydrate /repo /repo/wt 2>&1)" || rc=$?
assert_eq "a missing Bun returns 0" "0" "$rc"
assert_contains "and says it skipped" "$err" "skipping hydrate"
rc=0; SW_TS_CLI="$TEST_TEMP_DIR/missing.ts" sw_env_hydrate /repo /repo/wt 2>/dev/null || rc=$?
assert_eq "a missing CLI returns 0" "0" "$rc"

print_test_section "test_sandbox_hydrate"
: > "$BUN_LOG"
test_sandbox_hydrate /repo /tmp/box
assert_eq "restores only, never builds" \
    "$SW_TS_CLI env hydrate --root /repo --dir /tmp/box --restore-only" "$(cat "$BUN_LOG")"
mock_binary "bun" 'printf "%s\n" "$*" >> "$BUN_LOG"; echo "· no cached environment for this checkout"; exit 0'
out="$(test_sandbox_hydrate /repo /tmp/box 2>/dev/null)"
assert_eq "prints nothing on stdout (test_sandbox_open's stdout is the sandbox path)" "" "$out"
mock_binary "bun" 'printf "%s\n" "$*" >> "$BUN_LOG"; exit "$BUN_EXIT"'

print_test_section "env-exec.sh"
# One name per printenv: BSD printenv (macOS) takes a single argument.
out="$(cd "$TEST_TEMP_DIR" && GH_TOKEN=secret SW_ENV_NO_JAIL=1 bash "$SCRIPT_DIR/lib/env-exec.sh" printenv GH_TOKEN || true)"
assert_eq "strips credentials" "" "$out"
out="$(cd "$TEST_TEMP_DIR" && SW_ENV_NO_JAIL=1 bash "$SCRIPT_DIR/lib/env-exec.sh" printenv SHIPWRIGHT_IN_TEST_GATE || true)"
assert_eq "and marks the test gate" "1" "$out"
rc=0; bash "$SCRIPT_DIR/lib/env-exec.sh" 2>/dev/null || rc=$?
assert_eq "no command is a usage error" "2" "$rc"
rc=0; SW_ENV_NO_JAIL=1 bash "$SCRIPT_DIR/lib/env-exec.sh" false || rc=$?
assert_eq "passes the command's status through" "1" "$rc"

rc=0; err="$(cd "$TEST_TEMP_DIR" && SW_ENV_REQUIRE_JAIL=1 bash "$SCRIPT_DIR/lib/env-exec.sh" true 2>&1)" || rc=$?
if [[ -f "$SCRIPT_DIR/lib/test-sandbox.sh" ]]; then
    assert_eq "an unreviewed recipe outside a sandbox dir is refused" "126" "$rc"
else
    assert_eq "an unreviewed recipe without a jail is refused" "126" "$rc"
fi
assert_contains "and says why" "$err" "unreviewed"

print_test_section "pipeline_prepare_env (daemon worktrees, --worktree runs only)"
sed -n '/^pipeline_prepare_env() {/,/^}/p' "$SCRIPT_DIR/lib/pipeline-commands.sh" > "$TEST_TEMP_DIR/prepare.sh"
info() { :; }
warn() { printf 'warn: %s\n' "$*"; }
source "$TEST_TEMP_DIR/prepare.sh"
: > "$BUN_LOG"
(unset SW_ENV_HYDRATE_ROOT; AUTO_WORKTREE=false; pipeline_prepare_env)
assert_eq "the operator's own checkout is never touched" "" "$(cat "$BUN_LOG")"
(cd "$TEST_TEMP_DIR" && SW_ENV_HYDRATE_ROOT=/repo SW_ENV_HYDRATE_REF=main pipeline_prepare_env)
assert_eq "a daemon worktree is hydrated from the base branch's recipe" \
    "$SW_TS_CLI env hydrate --root /repo --dir $(cd "$TEST_TEMP_DIR" && pwd) --ref main" "$(cat "$BUN_LOG")"
: > "$BUN_LOG"
(cd "$TEST_TEMP_DIR" && unset SW_ENV_HYDRATE_ROOT && AUTO_WORKTREE=true ORIGINAL_REPO_DIR=/orig pipeline_prepare_env)
assert_contains "a --worktree run hydrates from the original checkout" "$(cat "$BUN_LOG")" "--root /orig"
: > "$BUN_LOG"
(cd "$TEST_TEMP_DIR" && SW_ENV_HYDRATE_ROOT=/clone SW_ENV_HYDRATE_RESTORE_ONLY=1 pipeline_prepare_env)
assert_contains "an org-mode clone (reused across issues) only restores" "$(cat "$BUN_LOG")" "--restore-only"
rc=0; out="$(cd "$TEST_TEMP_DIR" && BUN_EXIT=1 SW_ENV_HYDRATE_ROOT=/repo pipeline_prepare_env)" || rc=$?
assert_eq "a setup failure does not stop the pipeline" "0" "$rc"
assert_contains "but warns" "$out" "Environment setup failed"

print_test_results
