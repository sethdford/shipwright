#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline credential helper test — github.com over https only, get only   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: fake tokens, no git network, no credential store. The helper under test is the value of
# GIT_CONFIG_VALUE_2 in the pipeline workflow, run the way git runs a `!` helper.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "CI: git credential helper Tests"
setup_test_env "ci-git-token-credential"
trap 'cleanup_test_env; sw_test_teardown' EXIT

WORKFLOW="$SCRIPT_DIR/../.github/workflows/shipwright-pipeline.yml"
pipeline_job="$(sed -n '/^  pipeline:/,$p' "$WORKFLOW")"
# The helper: the single-quoted YAML value of GIT_CONFIG_VALUE_2 in the pipeline job ('' is a quote).
helper_value="$(sed -n "s/^      GIT_CONFIG_VALUE_2: '\\(.*\\)'\$/\\1/p" <<<"$pipeline_job" | sed "s/''/'/g")"
# git runs a `!` helper as: sh -c "<command> \"\$@\"" <name> <operation>. The same command is
# written to a file here and run as `sh file <operation>`: no code is built from a string.
HELPER_FILE="$TEST_TEMP_DIR/credential-helper.sh"
printf '%s "$@"\n' "${helper_value#!}" > "$HELPER_FILE"
run_helper() { # protocol host operation  (env: GITHUB_TOKEN / GH_TOKEN as set by the caller)
    local request="$TEST_TEMP_DIR/request.txt"
    printf 'protocol=%s\nhost=%s\n\n' "$1" "$2" > "$request"
    sh "$HELPER_FILE" "$3" < "$request"
}

print_test_section "the configured helper is present"
assert_eq "the pipeline job resets the global helper list (KEY_0), then the github.com list (KEY_1)" "1" \
    "$(grep -c '^      GIT_CONFIG_KEY_0: credential.helper$' <<<"$pipeline_job" || true)"
assert_eq "the github.com-scoped helper list is reset before the helper is added" "1" \
    "$(grep -c '^      GIT_CONFIG_KEY_1: credential.https://github.com.helper$' <<<"$pipeline_job" || true)"
assert_eq "the inline helper is added last (KEY_2)" "1" \
    "$(grep -c '^      GIT_CONFIG_KEY_2: credential.helper$' <<<"$pipeline_job" || true)"
assert_eq "the helper value is a shell function invocation" "true" \
    "$([[ "$helper_value" == '!f() {'*'}; f' ]] && echo true || echo false)"

print_test_section "answers https github.com from the token"
assert_eq "get for https github.com prints x-access-token and the token" \
    "$(printf 'username=x-access-token\npassword=fake-run-token')" \
    "$(GITHUB_TOKEN=fake-run-token run_helper https github.com get)"
assert_eq "GH_TOKEN is used when GITHUB_TOKEN is unset" "password=fake-gh" \
    "$(GITHUB_TOKEN='' GH_TOKEN=fake-gh run_helper https github.com get | sed -n 2p)"

print_test_section "answers nothing else"
assert_eq "no answer over plain http" "" "$(GITHUB_TOKEN=fake-run-token run_helper http github.com get)"
assert_eq "no answer for another host" "" "$(GITHUB_TOKEN=fake-run-token run_helper https example.com get)"
assert_eq "no answer for a GHES host" "" "$(GITHUB_TOKEN=fake-run-token run_helper https ghe.example.com get)"
assert_eq "no answer for store" "" "$(GITHUB_TOKEN=fake-run-token run_helper https github.com store)"
assert_eq "no answer for erase" "" "$(GITHUB_TOKEN=fake-run-token run_helper https github.com erase)"
assert_eq "no answer without a token" "" "$(printf 'protocol=https\nhost=github.com\n\n' | env -u GITHUB_TOKEN -u GH_TOKEN sh "$HELPER_FILE" get)"

print_test_section "the helper is not a file in the workspace"
assert_eq "the helper value names no path (no file an agent could rewrite)" "0" \
    "$(grep -c 'GITHUB_WORKSPACE\|scripts/' <<<"$helper_value" || true)"
assert_eq "no helper script remains under scripts/ci" "0" \
    "$(ls "$SCRIPT_DIR"/ci/git-token-credential*.sh 2>/dev/null | wc -l | tr -d ' ')"

print_test_section "pipeline workflow wiring"
assert_eq "the pipeline checkout does not persist credentials" "1" \
    "$(grep -A4 'uses: actions/checkout' <<<"$pipeline_job" | grep -c 'persist-credentials: false' || true)"
assert_eq "the pipeline job does not embed a token in a remote URL" "0" \
    "$(grep -c 'x-access-token:${GITHUB_TOKEN}@' <<<"$pipeline_job" || true)"

print_test_section "review-remediation workflow: same helper, no persisted credentials, agent through agent-exec"
REMEDIATION="$SCRIPT_DIR/../.github/workflows/review-remediation.yml"
assert_eq "review-remediation pushes through the same inline helper" "$helper_value" \
    "$(sed -n "s/^ *GIT_CONFIG_VALUE_2: '\(.*\)'\$/\1/p" "$REMEDIATION" | sed "s/''/'/g")"
assert_eq "review-remediation checkout does not persist credentials" "1" \
    "$(grep -A4 'uses: actions/checkout' "$REMEDIATION" | grep -c 'persist-credentials: false' || true)"
assert_eq "review-remediation runs its agent through agent-exec (no bare claude -p)" "0" \
    "$(grep -E '^ *claude -p' "$REMEDIATION" | grep -vc 'agent-exec' || true)"

print_test_section "orchestrator git: a helper the agent adds to repo config never receives the token"
# Each workflow's git environment, parsed from the file itself, so the test runs what CI runs.
# Values: 'single-quoted' ('' is a quote), "double-quoted", or plain.
orch_env_of() { # workflow file -> NAME=VALUE lines for its GIT_CONFIG_* entries
    local line name value
    while IFS= read -r line; do
        name="$(sed 's/^ *//; s/:.*$//' <<<"$line")"
        value="${line#*: }"
        case "$value" in
            \'*\') value="${value#\'}"; value="${value%\'}"; value="${value//\'\'/\'}" ;;
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
        esac
        printf '%s=%s\n' "$name" "$value"
    done < <(grep -E '^ *GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+): ' "$1")
}
pipeline_job_file="$TEST_TEMP_DIR/pipeline-job.yml"
sed -n '/^  pipeline:/,$p' "$WORKFLOW" > "$pipeline_job_file"
pipeline_git_env="$(orch_env_of "$pipeline_job_file")"
remediation_git_env="$(orch_env_of "$SCRIPT_DIR/../.github/workflows/review-remediation.yml")"
work="$TEST_TEMP_DIR/orch-repo"
git init -q "$work"
log="$TEST_TEMP_DIR/repo-helper.log"
# The agent's addition: credential helpers in the workspace repo config. They log what they receive.
git -C "$work" config credential.helper "!f() { echo \"REPO-HELPER-RAN \$1\" >> '$log'; cat >> '$log'; }; f"
git -C "$work" config "credential.https://github.com.helper" "!f() { echo \"REPO-HELPER-URL-RAN \$1\" >> '$log'; cat >> '$log'; }; f"
fake_token="fake-orch-token-$RANDOM"
orch_home="$TEST_TEMP_DIR/orch-home"
mkdir -p "$orch_home"
# git runs with an empty HOME, no system config, and the fake token only: no real credential is read.
run_orch_git() { # env-lines operation [extra-env]
    local -a envs=() extra=()
    local l
    while IFS= read -r l; do [[ -n "$l" ]] && envs+=("$l"); done <<<"$1"
    [[ -n "${3:-}" ]] && extra=("$3")
    (cd "$work" && printf 'protocol=https\nhost=github.com\n\n' | env -i PATH="$PATH" HOME="$orch_home" \
        GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GITHUB_TOKEN="$fake_token" ${extra[@]+"${extra[@]}"} \
        ${envs[@]+"${envs[@]}"} git credential "$2")
}
# Control: without the orchestrator's environment, the repo-config helper does run (the test can see it).
rm -f "$log"
(cd "$work" && printf 'protocol=https\nhost=github.com\n\n' | env -i PATH="$PATH" HOME="$orch_home" \
    GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 git credential fill >/dev/null 2>&1 || true)
assert_eq "control: with no orchestrator env the repo-config helper runs" "yes" \
    "$(grep -q 'REPO-HELPER-RAN get' "$log" 2>/dev/null && echo yes || echo no)"
for env_name in pipeline remediation; do
    if [[ "$env_name" == pipeline ]]; then orch_lines="$pipeline_git_env"; else orch_lines="$remediation_git_env"; fi
    rm -f "$log"
    fill_out="$(run_orch_git "$orch_lines" fill)"
    assert_eq "$env_name: fill is answered by the inline helper only" \
        "$(printf 'username=x-access-token\npassword=%s' "$fake_token")" "$(grep -E '^(username|password)=' <<<"$fill_out")"
    trace="$(run_orch_git "$orch_lines" fill "GIT_TRACE=1" 2>&1)"
    assert_eq "$env_name: the inline helper runs exactly once for fill (git trace)" "1" \
        "$(grep -c 'run_command.*x-access-token' <<<"$trace" || true)"
    assert_eq "$env_name: the repo-config helpers do not run for fill" "no" \
        "$(grep -q 'REPO-HELPER' "$log" 2>/dev/null && echo yes || echo no)"
    run_orch_git "$orch_lines" approve >/dev/null
    assert_eq "$env_name: approve (store) does not hand the token to a repo-config helper" "no" \
        "$(grep -q "$fake_token" "$log" 2>/dev/null && echo yes || echo no)"
    assert_eq "$env_name: approve runs no repo-config helper" "no" \
        "$(grep -q 'REPO-HELPER' "$log" 2>/dev/null && echo yes || echo no)"
done
assert_eq "the orchestrator environment disables repo hooks and fsmonitor" "yes" \
    "$(grep -q '^GIT_CONFIG_VALUE_3=/dev/null$' <<<"$pipeline_git_env" && grep -q '^GIT_CONFIG_VALUE_4=false$' <<<"$pipeline_git_env" && echo yes || echo no)"

print_test_section "review-remediation rerun writer: from the base branch, never PR-head code"
assert_eq "the rerun writer is fetched as the base branch tarball" "1" \
    "$(grep -c 'gh api "repos/${GITHUB_REPOSITORY}/tarball/${BASE_REF}"' "$REMEDIATION" || true)"
assert_eq "the trusted CI scripts (#8673) are fetched as the default branch tarball" "1" \
    "$(grep -c 'gh api "repos/${GITHUB_REPOSITORY}/tarball/${DEFAULT_BRANCH}"' "$REMEDIATION" || true)"
assert_eq "the rerun step does not read the PR head to build the writer (no HEAD_SHA)" "0" \
    "$(grep -c 'HEAD_SHA' <<<"$(sed -n '/name: Request review rerun/,$p' "$REMEDIATION")" || true)"
assert_eq "the rerun step never archives the agent-edited tree or a git remote" "0" \
    "$(grep -c 'git archive\|git fetch' <<<"$(sed -n '/name: Request review rerun/,$p' "$REMEDIATION")" || true)"

print_test_results
