#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/test-gate-env test — the loop's test gate has no creds   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: no tmux, no network, temp HOME. Regression test for #8608: the build
# loop's test gate inherited the pipeline's GitHub and Claude credentials, so a
# real-service suite started nested pipelines and filed real issues.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: test-gate-env Tests"

setup_test_env "lib-test-gate-env"
trap cleanup_test_env EXIT

source "$SCRIPT_DIR/lib/test-gate-env.sh"

export GH_TOKEN="gh-secret" GITHUB_TOKEN="github-secret" GH_ENTERPRISE_TOKEN="ghe-secret"
export CLAUDE_CODE_OAUTH_TOKEN="claude-secret" ANTHROPIC_API_KEY="anthropic-secret"
export SHIPWRIGHT_FLEET_TOKEN="fleet-secret"
export GH_CONFIG_DIR="$TEST_TEMP_DIR/real-gh-config"
mkdir -p "$GH_CONFIG_DIR" && echo "oauth_token: real" > "$GH_CONFIG_DIR/hosts.yml"
export KEEP_ME="still-here"

child_env="$(sw_test_gate_env bash -c 'env')"

print_test_section "credentials removed"
for var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY SHIPWRIGHT_FLEET_TOKEN; do
    if grep -q "^${var}=" <<<"$child_env"; then
        assert_fail "$var is not visible to the test command"
    else
        assert_pass "$var is not visible to the test command"
    fi
done
if grep -q 'secret' <<<"$child_env"; then
    assert_fail "no credential value reaches the test command"
else
    assert_pass "no credential value reaches the test command"
fi

print_test_section "gh sees no stored login"
child_gh_dir="$(sed -n 's/^GH_CONFIG_DIR=//p' <<<"$child_env")"
assert_eq "GH_CONFIG_DIR is replaced" "true" "$([[ -n "$child_gh_dir" && "$child_gh_dir" != "$GH_CONFIG_DIR" ]] && echo true || echo false)"
assert_eq "the replacement gh config dir is empty" "0" "$(find "$child_gh_dir" -type f 2>/dev/null | wc -l | tr -d ' ')"

print_test_section "marker and passthrough"
assert_eq "SHIPWRIGHT_IN_TEST_GATE is set" "1" "$(sed -n 's/^SHIPWRIGHT_IN_TEST_GATE=//p' <<<"$child_env")"
assert_eq "unrelated variables pass through" "still-here" "$(sed -n 's/^KEEP_ME=//p' <<<"$child_env")"
assert_eq "the caller's own environment is unchanged" "gh-secret" "$GH_TOKEN"

print_test_section "exit status"
rc=0; sw_test_gate_env bash -c 'exit 7' || rc=$?
assert_eq "the test command's exit status is returned" "7" "$rc"

print_test_section "the loop uses it"
loop_src="$SCRIPT_DIR/sw-loop.sh"
calls="$(grep -cE 'bash -c "\$(test|extra)_wrapper"' "$loop_src" || true)"
gated="$(grep -cE 'sw_test_gate_env bash -c "\$(test|extra)_wrapper"' "$loop_src" || true)"
assert_eq "both test-gate commands run without credentials" "${calls:-0}" "${gated:-0}"
assert_eq "the loop has two test-gate commands" "2" "${calls:-0}"
if grep -qE '^source "\$SCRIPT_DIR/lib/test-gate-env.sh"' "$loop_src"; then
    assert_pass "the loop sources test-gate-env.sh unconditionally (missing lib fails loudly)"
else
    assert_fail "the loop sources test-gate-env.sh unconditionally (missing lib fails loudly)"
fi

print_test_section "real-service suites refuse without opt-in"
# Run a copy of the suite in a temp tree with gh, git and claude mocked, so even a broken
# guard cannot reach this repo or real GitHub.
e2e_tree="$TEST_TEMP_DIR/e2e-tree"
mkdir -p "$e2e_tree/scripts/lib"
cp "$SCRIPT_DIR/sw-e2e-integration-test.sh" "$e2e_tree/scripts/"
cp "$SCRIPT_DIR/lib/test-helpers.sh" "$e2e_tree/scripts/lib/"
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && cp "$SCRIPT_DIR/lib/compat.sh" "$e2e_tree/scripts/lib/"
export E2E_GH_LOG="$TEST_TEMP_DIR/e2e-gh.log"
: > "$E2E_GH_LOG"
mock_binary "gh" 'printf "%s\n" "$*" >> "$E2E_GH_LOG"; exit 0'
mock_binary "git" 'exit 0'
mock_binary "claude" 'exit 0'

run_e2e() { # VAR=value... — run the copied suite with credentials present, opt-in unset unless given
    env -u SHIPWRIGHT_E2E_REAL -u SHIPWRIGHT_IN_TEST_GATE CLAUDE_CODE_OAUTH_TOKEN=fake GH_TOKEN=fake "$@" bash "$e2e_tree/scripts/sw-e2e-integration-test.sh" 2>&1
}
out="$(run_e2e)" && rc=0 || rc=$?
assert_eq "without SHIPWRIGHT_E2E_REAL=1 it exits 0" "0" "$rc"
assert_contains "without SHIPWRIGHT_E2E_REAL=1 it says why it skipped" "$out" "SHIPWRIGHT_E2E_REAL"
out="$(run_e2e SHIPWRIGHT_E2E_REAL=1 SHIPWRIGHT_IN_TEST_GATE=1)" && rc=0 || rc=$?
assert_eq "inside a test gate it exits 0 even when opted in" "0" "$rc"
assert_contains "inside a test gate it says why it refused" "$out" "test gate"
if grep -qE 'issue create|pr create|workflow run' "$E2E_GH_LOG"; then
    assert_fail "no GitHub write was attempted"
else
    assert_pass "no GitHub write was attempted"
fi

print_test_results
