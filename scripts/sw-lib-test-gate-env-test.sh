#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/test-gate-env test — the loop's test gate has no creds   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: no tmux, no network, temp HOME. Regression test for #8608: the build
# loop's test gate inherited the pipeline's GitHub and Claude credentials, so a
# real-service suite started nested pipelines and filed real issues.
set -euo pipefail

# Agents run without GitHub credentials (#8614): claude is launched through agent-exec.sh.
SW_AGENT_EXEC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/agent-exec.sh"
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: test-gate-env Tests"

setup_test_env "lib-test-gate-env"
trap cleanup_test_env EXIT

source "$SCRIPT_DIR/lib/test-gate-env.sh"
# GIT_CONFIG_* this suite inherited (set when it runs inside a pipeline's test gate). Taken before
# any gate call, so a gate that leaked its overrides into the caller is caught below (#8631).
inherited_git_cfg="$(env | grep '^GIT_CONFIG_' | sort || true)"

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
assert_eq "even a failed scrub has already reset git's saved header" "http.https://github.com/.extraheader" "$(sed -n 's/^GIT_CONFIG_KEY_0=//p' <<<"$early_env")"
assert_eq "even a failed scrub has already dropped the Claude login" "" "$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' <<<"$early_env")"

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
# "Outside" means the caller's own shell, minus only the overrides this suite inherited from an outer
# gate (every pipeline runs it inside one). Anything a gate call leaked into this shell stays and fails.
outside_gate() {
    local unset_args=() name
    while IFS='=' read -r name _; do
        [[ -n "$name" ]] && unset_args+=(-u "$name")
    done <<<"$inherited_git_cfg"
    env ${unset_args[@]+"${unset_args[@]}"} "$@"
}
assert_eq "the gate leaves the caller's GIT_CONFIG_* unchanged" "$inherited_git_cfg" \
    "$(env | grep '^GIT_CONFIG_' | sort || true)"
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
    lib/pipeline-quality-checks.sh lib/test-holdout.sh lib/mutation-executor.sh sw-evidence.sh)
run_re='(bash -c|eval) "\$\{?(test_cmd|TEST_CMD|_vg_cmd|test_wrapper|extra_wrapper|command_str|property_cmd|check_cmd)'
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

print_test_section "test gate: Claude CLI points at an empty config dir (#8616)"
gate_cfg="$(sw_test_gate_env bash -c 'printf "%s\n" "$CLAUDE_CONFIG_DIR"; find "$CLAUDE_CONFIG_DIR" -mindepth 1 | wc -l')"
claude_cfg="$(sed -n 1p <<<"$gate_cfg")"
assert_eq "the gate sets CLAUDE_CONFIG_DIR" "true" "$([[ -n "$claude_cfg" ]] && echo true || echo false)"
assert_eq "the gate's Claude config dir is empty" "0" "$(sed -n 2p <<<"$gate_cfg" | tr -d ' ')"
gone_cfg="$( ( sw_test_gate_scrub && eval 'printf %s "$CLAUDE_CONFIG_DIR"' ) )"
assert_eq "the scrubbed subshell's Claude config dir is removed afterwards" "gone" "$([[ -d "$gone_cfg" ]] && echo present || echo gone)"

print_test_section "path-scoped git credentials are reset (#8617)"
git -C "$git_repo" remote add origin https://example.invalid/acme/repo.git
git -C "$git_repo" config http.https://example.invalid/acme/repo.git.extraheader "AUTHORIZATION: basic SECRET2"
git -C "$git_repo" config credential.https://example.invalid/acme/repo.git.helper "store"
assert_eq "outside the gate the remote-scoped header is set" "AUTHORIZATION: basic SECRET2" \
    "$(env -i PATH="$PATH" HOME="$HOME" git -C "$git_repo" config --get http.https://example.invalid/acme/repo.git.extraheader)"
scoped_gate="$(cd "$git_repo" && sw_test_gate_env bash -c 'printf "[%s]" "$(git config --get http.https://example.invalid/acme/repo.git.extraheader)"; printf "[%s]" "$(git config --get credential.https://example.invalid/acme/repo.git.helper)"')"
assert_eq "the remote-scoped extraheader and helper resolve to empty inside the gate" "[][]" "$scoped_gate"
if grep -q SECRET2 <<<"$scoped_gate"; then assert_fail "no remote-scoped secret reaches the gate"; else assert_pass "no remote-scoped secret reaches the gate"; fi

print_test_section "agent exec: GitHub credentials removed, Claude login kept (#8614)"
SW_AGENT_EXEC="$SCRIPT_DIR/lib/agent-exec.sh"
assert_eq "agent-exec.sh exists and is executable" "yes" "$([[ -x "$SW_AGENT_EXEC" ]] && echo yes || echo no)"
mock_binary "claude" 'env'
agent_env="$(cd "$git_repo" && unset SHIPWRIGHT_IN_TEST_GATE && "$SW_AGENT_EXEC" claude 2>&1)"
for var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN SHIPWRIGHT_FLEET_TOKEN; do
    if grep -q "^${var}=" <<<"$agent_env"; then assert_fail "agent: $var is removed"; else assert_pass "agent: $var is removed"; fi
done
assert_eq "agent keeps CLAUDE_CODE_OAUTH_TOKEN" "claude-secret" "$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' <<<"$agent_env")"
assert_eq "agent keeps ANTHROPIC_API_KEY" "anthropic-secret" "$(sed -n 's/^ANTHROPIC_API_KEY=//p' <<<"$agent_env")"
assert_eq "agent is marked as a test gate (real-service suites refuse inside an agent)" "1" "$(sed -n 's/^SHIPWRIGHT_IN_TEST_GATE=//p' <<<"$agent_env")"
assert_eq "agent drops variables that are not on the allowlist" "" "$(sed -n 's/^KEEP_ME=//p' <<<"$agent_env")"
agent_gh_dir="$(sed -n 's/^GH_CONFIG_DIR=//p' <<<"$agent_env")"
assert_eq "agent gh config dir is not the caller's" "true" "$([[ "$agent_gh_dir" != "$GH_CONFIG_DIR" ]] && echo true || echo false)"
mock_binary "claude" 'git config --get http.https://example.invalid/acme/repo.git.extraheader; echo "rc=$?"'
agent_scoped="$(cd "$git_repo" && "$SW_AGENT_EXEC" claude 2>&1)"
assert_eq "agent: the remote-scoped extraheader is reset" "rc=0" "$(tail -n 1 <<<"$agent_scoped")"
if grep -q SECRET2 <<<"$agent_scoped"; then assert_fail "agent: no remote-scoped secret"; else assert_pass "agent: no remote-scoped secret"; fi
git -C "$git_repo" config http.https://ghe.example.com/acme.extraheader "AUTHORIZATION: basic SECRET3"
mock_binary "claude" 'git config --get http.https://ghe.example.com/acme.extraheader; echo "rc=$?"'
agent_ghes="$(cd "$git_repo" && "$SW_AGENT_EXEC" claude 2>&1)"
assert_eq "agent: a GHES extraheader is reset too" "rc=0" "$(tail -n 1 <<<"$agent_ghes")"
if grep -q SECRET3 <<<"$agent_ghes"; then assert_fail "agent: no GHES secret"; else assert_pass "agent: no GHES secret"; fi
print_test_section "agent exec: environment allowlist (SSH, askpass, PAT and unknown tokens never reach the agent)"
mock_binary "claude" 'env'
fake_token="fake-$RANDOM$RANDOM"
allow_env="$(cd "$git_repo" && SSH_AUTH_SOCK=/tmp/sw-fake-agent.sock GIT_ASKPASS=/tmp/sw-fake-askpass GIT_SSH_COMMAND=/tmp/sw-fake-ssh SSH_ASKPASS=/tmp/sw-fake-ssh-askpass GITHUB_PAT=fake-pat FOO_TOKEN="$fake_token" NPM_CONFIG_TOKEN=fake-npm AWS_SECRET_ACCESS_KEY=fake-aws SHIPWRIGHT_FLEET_TOKEN_FILE=/tmp/sw-fake-fleet "$SW_AGENT_EXEC" claude 2>&1)"
for var in SSH_AUTH_SOCK GIT_ASKPASS GIT_SSH_COMMAND SSH_ASKPASS GITHUB_PAT FOO_TOKEN NPM_CONFIG_TOKEN AWS_SECRET_ACCESS_KEY SHIPWRIGHT_FLEET_TOKEN_FILE; do
    if grep -q "^${var}=" <<<"$allow_env"; then assert_fail "allowlist: $var does not reach the agent"; else assert_pass "allowlist: $var does not reach the agent"; fi
done
if grep -q "$fake_token" <<<"$allow_env"; then assert_fail "allowlist: the random FOO_TOKEN value does not reach the agent"; else assert_pass "allowlist: the random FOO_TOKEN value does not reach the agent"; fi
assert_eq "allowlist: PATH reaches the agent" "yes" "$(grep -q '^PATH=' <<<"$allow_env" && echo yes || echo no)"
assert_eq "allowlist: a SHIPWRIGHT_* run variable reaches the agent" "fake-run" "$( (cd "$git_repo" && SHIPWRIGHT_PIPELINE_ID=fake-run "$SW_AGENT_EXEC" claude 2>&1) | sed -n 's/^SHIPWRIGHT_PIPELINE_ID=//p')"

print_test_section "agent exec: the allowlist covers what agents need, and nothing else"
mock_binary "claude" 'env'
allow2="$(cd "$git_repo" && env SSH_AUTH_SOCK=/tmp/x GITHUB_PAT=fake-pat FOO_TOKEN=fake-foo \
    ANTHROPIC_AUTH_TOKEN=auth-ok ANTHROPIC_MODEL=model-ok HTTPS_PROXY=http://u:p@proxy:3128 https_proxy=http://proxy \
    NODE_EXTRA_CA_CERTS=/ca.pem SSL_CERT_DIR=/cas CLAUDE_CODE_USE_VERTEX=1 CLOUD_ML_REGION=us-east5 \
    ANTHROPIC_VERTEX_PROJECT_ID=proj AWS_REGION=us-east-1 CI=true XDG_CONFIG_HOME=/xdg \
    AWS_SECRET_ACCESS_KEY=aws-secret-no-bedrock SHIPWRIGHT_GH_PAT=fake-pat-2 SHIPWRIGHT_BEARER=fake-bearer \
    SHIPWRIGHT_DIR=/sw-dir SHIPWRIGHT_GITHUB_REPO=o/r "$SW_AGENT_EXEC" claude 2>&1)"
for var in ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL HTTPS_PROXY https_proxy NODE_EXTRA_CA_CERTS SSL_CERT_DIR \
    CLAUDE_CODE_USE_VERTEX CLOUD_ML_REGION ANTHROPIC_VERTEX_PROJECT_ID AWS_REGION CI XDG_CONFIG_HOME \
    SHIPWRIGHT_DIR SHIPWRIGHT_GITHUB_REPO; do
    assert_eq "allowlist: $var reaches the agent" "yes" "$(grep -q "^${var}=" <<<"$allow2" && echo yes || echo no)"
done
assert_eq "allowlist: a proxy value passes through unchanged" "http://u:p@proxy:3128" \
    "$(sed -n 's/^HTTPS_PROXY=//p' <<<"$allow2")"
for var in SSH_AUTH_SOCK GITHUB_PAT FOO_TOKEN AWS_SECRET_ACCESS_KEY SHIPWRIGHT_GH_PAT SHIPWRIGHT_BEARER; do
    assert_eq "allowlist: $var does not reach the agent (no Bedrock)" "no" "$(grep -q "^${var}=" <<<"$allow2" && echo yes || echo no)"
done
bedrock2="$(cd "$git_repo" && env CLAUDE_CODE_USE_BEDROCK=1 AWS_ACCESS_KEY_ID=fake-id AWS_SECRET_ACCESS_KEY=fake-aws-secret "$SW_AGENT_EXEC" claude 2>&1)"
assert_eq "allowlist: AWS secret key reaches the agent only with Bedrock selected" "fake-aws-secret" "$(sed -n 's/^AWS_SECRET_ACCESS_KEY=//p' <<<"$bedrock2")"

print_test_section "agent exec: remote URL userinfo never reaches the agent"
git -C "$git_repo" remote set-url origin "https://x-access-token:SECRET-REMOTE@github.com/acme/repo.git"
mock_binary "claude" 'env'
remote_env="$(cd "$git_repo" && "$SW_AGENT_EXEC" claude 2>&1)"
if grep -q SECRET-REMOTE <<<"$remote_env"; then assert_fail "a remote's password is not in the agent's environment"; else assert_pass "a remote's password is not in the agent's environment"; fi
assert_eq "the remote's reset key is built from the URL without userinfo" "yes" \
    "$(grep -q '^GIT_CONFIG_KEY_[0-9]*=http.https://github.com/acme/repo.git.extraheader$' <<<"$remote_env" && echo yes || echo no)"
git -C "$git_repo" remote set-url origin https://example.invalid/acme/repo.git

print_test_section "agent exec: a credential in url.insteadOf makes the launcher refuse to run the agent"
git -C "$git_repo" config "url.https://x:SECRET-INSTEAD@github.com/.insteadOf" "https://github.com/"
marker_insteadof="$TEST_TEMP_DIR/agent-ran-insteadof"
mock_binary "claude" "touch '$marker_insteadof'"
rc=0; (cd "$git_repo" && "$SW_AGENT_EXEC" claude >/dev/null 2>&1) || rc=$?
assert_eq "the agent does not run while a credential insteadOf is configured" "no" "$([[ -e "$marker_insteadof" ]] && echo yes || echo no)"
assert_eq "the refusal exits non-zero" "true" "$([[ "$rc" -ne 0 ]] && echo true || echo false)"
rc=0; (cd "$git_repo" && sw_test_gate_env bash -c 'exit 0') >/dev/null 2>&1 || rc=$?
assert_eq "the test gate refuses too (fail closed)" "true" "$([[ "$rc" -ne 0 ]] && echo true || echo false)"
git -C "$git_repo" config --unset "url.https://x:SECRET-INSTEAD@github.com/.insteadOf"

print_test_section "agent exec: exit status and process identity"
mock_binary "claude" 'exit 7'
rc=0; "$SW_AGENT_EXEC" claude >/dev/null 2>&1 || rc=$?
assert_eq "agent exec returns the command's exit status" "7" "$rc"
mock_binary "claude" 'echo "$$"'
pid_file="$TEST_TEMP_DIR/agent-pid"
"$SW_AGENT_EXEC" claude > "$pid_file" 2>&1 &
bg_pid=$!
wait "$bg_pid" 2>/dev/null || true
assert_eq "the agent process is the caller's background pid (signals reach it)" "$bg_pid" "$(cat "$pid_file")"

print_test_section "agent exec: fails closed when the scrub cannot complete"
marker="$TEST_TEMP_DIR/agent-ran"
mock_binary "claude" "touch '$marker'"
mock_binary "git" 'exit 128'
rc=0; "$SW_AGENT_EXEC" claude >/dev/null 2>&1 || rc=$?
rm -f "$TEST_TEMP_DIR/bin/git"
assert_eq "the agent command does not run when the scrub fails" "no" "$([[ -e "$marker" ]] && echo yes || echo no)"
assert_eq "a failed scrub exits non-zero" "true" "$([[ "$rc" -ne 0 ]] && echo true || echo false)"

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

print_test_section "every agent claude call site goes through agent-exec (#8580)"
# A line that runs claude as a command must route it through "$SW_AGENT_EXEC", with the helper in
# command position before the claude word: "$SW_AGENT_EXEC" claude …, "$SW_AGENT_EXEC" $TIMEOUT_CMD n
# claude …, or timeout n "$SW_AGENT_EXEC" claude …. A line that only mentions the helper elsewhere
# (x=$(claude -p "$SW_AGENT_EXEC")) is not routed. A command word is one at a line start or after
# | ( ; & $( then/do/else/if !, optionally behind timeout N or $VAR. Every file with such a line must
# define SW_AGENT_EXEC. Comments, probes, quoted text and `command -v claude` are not invocations.
claude_run_re='(^|[|;&(]|\$\(|then|do|else|if|!)[[:space:]]*((timeout|gtimeout)[[:space:]]+[^[:space:]]+|\$[A-Za-z_]+([[:space:]]+("[^"]*"|[^[:space:]"]+))?)?[[:space:]]*claude([[:space:]]|$)'
routed_re='(^|[|;&(]|\$\(|then|do|else|if|!)[[:space:]]*(timeout[[:space:]]+[^[:space:]]+[[:space:]]+|gtimeout[[:space:]]+[^[:space:]]+[[:space:]]+)?"?\$\{?SW_AGENT_EXEC\}?"?[[:space:]]+([^|;&]*[[:space:]])?claude([[:space:]]|$)'
unrouted_total=0
agent_files=("$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/sw" "$SCRIPT_DIR"/lib/*.sh)
for hook_dir in "$SCRIPT_DIR/../.claude/hooks" "$SCRIPT_DIR/../claude-code/hooks"; do
    [[ -d "$hook_dir" ]] && agent_files+=("$hook_dir"/*.sh)
done
[[ -f "$SCRIPT_DIR/../install.sh" ]] && agent_files+=("$SCRIPT_DIR/../install.sh")
for f in "${agent_files[@]}"; do
    [[ -f "$f" ]] || continue
    name="${f#"$SCRIPT_DIR"/}"
    name="${name#"$SCRIPT_DIR"/../}"
    calls="$(grep -nE "$claude_run_re" "$f" || true)"
    calls="$(grep -vE '^[0-9]+:[[:space:]]*#' <<<"$calls" || true)"
    [[ -n "$calls" ]] || continue
    unrouted="$(grep -vE "$routed_re" <<<"$calls" | grep -vE '(command -v|which|type|hash) claude|grep .*'"'"'[^'"'"']*claude' || true)"
    if [[ -n "$unrouted" ]]; then
        unrouted_total=$((unrouted_total + $(grep -c . <<<"$unrouted")))
        echo "    unrouted in $name: $(head -1 <<<"$unrouted" | cut -c1-120)"
    fi
    if grep -q 'SW_AGENT_EXEC' <<<"$calls" && ! grep -q '^SW_AGENT_EXEC=' "$f"; then
        assert_fail "$name routes claude through SW_AGENT_EXEC but does not define it"
    fi
done
assert_eq "no agent claude invocation bypasses agent-exec (scripts, hooks, install.sh)" "0" "$unrouted_total"
# Heredoc launchers (sw-session.sh) are templates: ast-grep and the regex above cannot see them. They
# must name the helper through the placeholder that awk fills with SW_AGENT_EXEC.
assert_eq "session launchers run claude through agent-exec (both templates)" "2" "$(grep -c "^__AGENT_EXEC__ claude __CLAUDE_FLAGS__" "$SCRIPT_DIR/sw-session.sh")"
assert_eq "session launchers fill the placeholder from SW_AGENT_EXEC (both fill calls)" "2" "$(grep -c '_sw_fill_launcher "\$LAUNCHER"' "$SCRIPT_DIR/sw-session.sh")"
assert_eq "session launchers fill through the literal helper (no gsub or awk -v)" "0" "$(grep -cE 'gsub\(/__|awk -v' "$SCRIPT_DIR/sw-session.sh" || true)"
assert_eq "no session hint tells the user to type bare claude" "0" "$(grep -c "Type 'claude' to restart" "$SCRIPT_DIR/sw-session.sh" || true)"
# The fill is tested on the real function, with paths holding & and " (gsub() mangled them).
fill_fn="$TEST_TEMP_DIR/fill-fn.sh"
sed -n '/^_sw_fill_launcher() {/,/^}/p' "$SCRIPT_DIR/sw-session.sh" > "$fill_fn"
printf '%s\n' 'cd __DIR__ || exit 1' 'PROMPT=$(cat __PROMPT__)' '"__AGENT_EXEC__" claude __CLAUDE_FLAGS__' > "$TEST_TEMP_DIR/fill-tpl.sh"
hostile_dir='/x&y"q'
hostile_prompt='/p&q'
filled="$(SW_DIR="$hostile_dir" SW_PROMPT="$hostile_prompt" SW_FLAGS="--f" SW_AGENT_EXEC="/s/agent.sh" bash -c 'source "$1"; _sw_fill_launcher "$2"' _ "$fill_fn" "$TEST_TEMP_DIR/fill-tpl.sh")"
# printf %q values survive the shell: a filled template that prints the helper path prints it back as
# one argument (the template is run as a file, not built into a string).
odd_exec="/tmp/sw odd dir/agent-exec's.sh"
odd_q="$(printf '%q' "$odd_exec")"
printf '%s\n' 'printf "%s\n" __AGENT_EXEC__' > "$TEST_TEMP_DIR/fill-odd.sh"
SW_AGENT_EXEC="$odd_q" bash -c 'source "$1"; _sw_fill_launcher "$2" > "$3"' _ "$fill_fn" "$TEST_TEMP_DIR/fill-odd.sh" "$TEST_TEMP_DIR/fill-odd-out.sh"
assert_eq "a %q helper path splits back into one word" "$odd_exec" "$(bash "$TEST_TEMP_DIR/fill-odd-out.sh")"
assert_eq "the fill writes a path with & and \" literally" "cd $hostile_dir || exit 1" "$(sed -n 1p <<<"$filled")"
assert_eq "the fill writes a prompt path with & literally" "PROMPT=\$(cat $hostile_prompt)" "$(sed -n 2p <<<"$filled")"
assert_eq "the fill writes the agent-exec path" '"/s/agent.sh" claude --f' "$(sed -n 3p <<<"$filled")"

print_test_results
