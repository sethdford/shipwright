#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline credential helper test — github.com over https only, get only   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: fake tokens, no git network, no credential store. The helper under test is the value of
# GIT_CONFIG_VALUE_0 in the pipeline workflow, run the way git runs a `!` helper.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "CI: git credential helper Tests"
setup_test_env "ci-git-token-credential"
trap cleanup_test_env EXIT

WORKFLOW="$SCRIPT_DIR/../.github/workflows/shipwright-pipeline.yml"
pipeline_job="$(sed -n '/^  pipeline:/,$p' "$WORKFLOW")"
# The helper: the single-quoted YAML value of GIT_CONFIG_VALUE_0 in the pipeline job ('' is a quote).
helper_value="$(sed -n "s/^      GIT_CONFIG_VALUE_0: '\\(.*\\)'\$/\\1/p" <<<"$pipeline_job" | sed "s/''/'/g")"
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
assert_eq "the pipeline job configures exactly one credential helper" "1" \
    "$(grep -c '^      GIT_CONFIG_KEY_0: credential.helper$' <<<"$pipeline_job" || true)"
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
    "$(sed -n "s/^ *GIT_CONFIG_VALUE_0: '\(.*\)'\$/\1/p" "$REMEDIATION" | sed "s/''/'/g")"
assert_eq "review-remediation checkout does not persist credentials" "1" \
    "$(grep -A4 'uses: actions/checkout' "$REMEDIATION" | grep -c 'persist-credentials: false' || true)"
assert_eq "review-remediation runs its agent through agent-exec (no bare claude -p)" "0" \
    "$(grep -E '^ *claude -p' "$REMEDIATION" | grep -vc 'agent-exec' || true)"

print_test_results
