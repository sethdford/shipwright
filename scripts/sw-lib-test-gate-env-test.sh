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
export SHIPWRIGHT_FLEET_TOKEN="fleet-secret" GITHUB_ENTERPRISE_TOKEN="ghe2-secret" ANTHROPIC_AUTH_TOKEN="anth-auth-secret"
export GH_CONFIG_DIR="$TEST_TEMP_DIR/real-gh-config"
mkdir -p "$GH_CONFIG_DIR" && echo "oauth_token: real" > "$GH_CONFIG_DIR/hosts.yml"
export KEEP_ME="still-here"

child_env="$(sw_test_gate_env bash -c 'env')"

print_test_section "credentials removed"
for var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN SHIPWRIGHT_FLEET_TOKEN; do
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

print_test_section "sw_test_gate_scrub (for eval call sites)"
scrub_env="$( ( sw_test_gate_scrub && eval 'env' ) )"
if grep -q 'secret' <<<"$scrub_env"; then
    assert_fail "eval inside a scrubbed subshell sees no credential"
else
    assert_pass "eval inside a scrubbed subshell sees no credential"
fi
assert_eq "the scrubbed subshell is marked" "1" "$(sed -n 's/^SHIPWRIGHT_IN_TEST_GATE=//p' <<<"$scrub_env")"
scrub_gh_dir="$(sed -n 's/^GH_CONFIG_DIR=//p' <<<"$scrub_env")"
assert_eq "the scrubbed subshell's gh config dir is removed afterwards" "gone" "$([[ -d "$scrub_gh_dir" ]] && echo present || echo gone)"
rc=0; sw_test_gate_scrub 2>/dev/null || rc=$?
assert_eq "sw_test_gate_scrub refuses to run outside a subshell" "1" "$rc"
assert_eq "a refused scrub leaves the caller's credentials alone" "gh-secret" "${GH_TOKEN:-}"
rc=0; ( sw_test_gate_scrub && eval 'exit 5' ) || rc=$?
assert_eq "the eval'd command's exit status is returned" "5" "$rc"

print_test_section "fail closed when the scrub cannot complete"
ran="$TEST_TEMP_DIR/ran-marker"
rm -f "$ran"
( export TMPDIR=/nonexistent/sw-test-gate; ( sw_test_gate_scrub && eval 'touch "$ran"' ) ) 2>/dev/null || true
assert_eq "eval form: the command does not run when the scrub fails" "no" "$([[ -e "$ran" ]] && echo yes || echo no)"
( export TMPDIR=/nonexistent/sw-test-gate; sw_test_gate_env touch "$ran" ) 2>/dev/null || true
assert_eq "command form: the command does not run when the scrub fails" "no" "$([[ -e "$ran" ]] && echo yes || echo no)"
early_env="$( ( export TMPDIR=/nonexistent/sw-test-gate; sw_test_gate_scrub 2>/dev/null; env ) )"
assert_eq "even a failed scrub has already marked the gate" "1" "$(sed -n 's/^SHIPWRIGHT_IN_TEST_GATE=//p' <<<"$early_env")"
assert_eq "even a failed scrub has already reset git's saved header" "3" "$(sed -n 's/^GIT_CONFIG_COUNT=//p' <<<"$early_env")"

print_test_section "git credentials saved by actions/checkout are not usable"
git_repo="$TEST_TEMP_DIR/repo"
git init -q "$git_repo"
git -C "$git_repo" config http.https://github.com/.extraheader "AUTHORIZATION: basic SECRET"
git -C "$git_repo" config credential.helper "store"
assert_eq "the extraheader resolves to empty inside the gate" "" \
    "$(sw_test_gate_env git -C "$git_repo" config --get http.https://github.com/.extraheader)"
assert_eq "the credential helper resolves to empty inside the gate" "" \
    "$(sw_test_gate_env git -C "$git_repo" config --get credential.helper)"
assert_eq "git never prompts for credentials inside the gate" "0" \
    "$(sed -n 's/^GIT_TERMINAL_PROMPT=//p' <<<"$child_env")"
# "Outside" means without a gate's overrides. This suite itself runs inside the build loop's test
# gate in every pipeline, so drop the inherited GIT_CONFIG_* before reading (#8631).
outside_gate() { env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 -u GIT_CONFIG_KEY_1 \
    -u GIT_CONFIG_VALUE_1 -u GIT_CONFIG_KEY_2 -u GIT_CONFIG_VALUE_2 -u SHIPWRIGHT_IN_TEST_GATE "$@"; }
assert_eq "outside the gate the saved header is untouched" "AUTHORIZATION: basic SECRET" \
    "$(outside_gate git -C "$git_repo" config --get http.https://github.com/.extraheader)"

if [[ -z "${SW_GATE_ENV_TEST_NESTED:-}" ]]; then
    print_test_section "the suite passes when run inside a test gate (as pipelines run it)"
    rc=0
    sw_test_gate_env env SW_GATE_ENV_TEST_NESTED=1 bash "$SCRIPT_DIR/sw-lib-test-gate-env-test.sh" \
        > "$TEST_TEMP_DIR/nested.log" 2>&1 || rc=$?
    assert_eq "nested run exits 0 (log: nested.log)" "0" "$rc"
    [[ "$rc" -eq 0 ]] || tail -20 "$TEST_TEMP_DIR/nested.log" >&2
fi

print_test_section "every test-command call site goes through the gate"
# Any line that runs a test-command variable (bash -c / eval / timeout … bash -c) must use
# sw_test_gate_env or run inside ( sw_test_gate_scrub && … ), and every file with such a line must
# load the lib itself.
gated_files=(sw-loop.sh lib/pipeline-stages-build.sh lib/pipeline-stages-review.sh
    lib/pipeline-quality-checks.sh lib/test-holdout.sh lib/mutation-executor.sh)
run_re='(bash -c|eval) "\$\{?(test_cmd|TEST_CMD|_vg_cmd|test_wrapper|extra_wrapper)'
for f in "${gated_files[@]}"; do
    calls="$(grep -E "$run_re" "$SCRIPT_DIR/$f" | grep -c . || true)"
    ungated="$(grep -E "$run_re" "$SCRIPT_DIR/$f" | grep -vcE 'sw_test_gate_env|\( sw_test_gate_scrub && ' || true)"
    assert_eq "$f: no test command runs outside the gate (${calls:-0} call sites)" "0" "${ungated:-0}"
    if grep -qE '^source "\$(SCRIPT_DIR|\(dirname "\$\{BASH_SOURCE\[0\]\}"\))(/lib)?/test-gate-env.sh"' "$SCRIPT_DIR/$f"; then
        assert_pass "$f loads test-gate-env.sh unconditionally"
    else
        assert_fail "$f loads test-gate-env.sh unconditionally"
    fi
done
loop_calls="$(grep -cE "$run_re" "$SCRIPT_DIR/sw-loop.sh" || true)"
assert_eq "sw-loop.sh has its four test-command call sites" "4" "${loop_calls:-0}"

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

cp "$SCRIPT_DIR/sw-integration-claude-test.sh" "$e2e_tree/scripts/"
out="$(env CLAUDE_CODE_OAUTH_TOKEN=fake SHIPWRIGHT_IN_TEST_GATE=1 bash "$e2e_tree/scripts/sw-integration-claude-test.sh" 2>&1)" && rc=0 || rc=$?
assert_eq "integration-claude exits 0 inside a test gate" "0" "$rc"
assert_contains "integration-claude says it skipped inside a test gate" "$out" "Skipping integration-claude: inside a build-loop test gate"

print_test_results
