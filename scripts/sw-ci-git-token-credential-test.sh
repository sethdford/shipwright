#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/ci/git-token-credential.sh test — github.com only, get only      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Hermetic: fake tokens, no git network, no real credential store. Also checks the pipeline
# workflow wiring: the checkout persists no token and the job points git at the helper.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "CI: git-token-credential Tests"
setup_test_env "ci-git-token-credential"
trap cleanup_test_env EXIT

HELPER="$SCRIPT_DIR/ci/git-token-credential.sh"
WORKFLOW="$SCRIPT_DIR/../.github/workflows/shipwright-pipeline.yml"
request() { printf 'protocol=https\nhost=%s\n\n' "$1"; }

print_test_section "answers github.com from the token"
assert_eq "get for github.com prints the token as x-access-token" \
    "$(printf 'username=x-access-token\npassword=fake-run-token')" \
    "$(request github.com | GITHUB_TOKEN=fake-run-token bash "$HELPER" get)"
assert_eq "GH_TOKEN is used when GITHUB_TOKEN is unset" \
    "password=fake-gh" "$(request github.com | env -u GITHUB_TOKEN GH_TOKEN=fake-gh bash "$HELPER" get | sed -n 2p)"

print_test_section "answers nothing else"
assert_eq "no answer for another host" "" "$(request example.com | GITHUB_TOKEN=fake-run-token bash "$HELPER" get)"
assert_eq "no answer for a GHES host" "" "$(request ghe.example.com | GITHUB_TOKEN=fake-run-token bash "$HELPER" get)"
assert_eq "no answer for store" "" "$(request github.com | GITHUB_TOKEN=fake-run-token bash "$HELPER" store)"
assert_eq "no answer for erase" "" "$(request github.com | GITHUB_TOKEN=fake-run-token bash "$HELPER" erase)"
assert_eq "no answer without a token" "" "$(request github.com | env -u GITHUB_TOKEN -u GH_TOKEN bash "$HELPER" get)"
rc=0; request github.com | env -u GITHUB_TOKEN -u GH_TOKEN bash "$HELPER" get >/dev/null 2>&1 || rc=$?
assert_eq "a request without a token exits 0 (git then fails the auth itself)" "0" "$rc"

print_test_section "pipeline workflow wiring"
pipeline_job="$(sed -n '/^  pipeline:/,$p' "$WORKFLOW")"
assert_eq "the pipeline checkout does not persist credentials" "1" \
    "$(grep -A4 'uses: actions/checkout' <<<"$pipeline_job" | grep -c 'persist-credentials: false' || true)"
assert_eq "the pipeline job points git's credential helper at the helper" "1" \
    "$(grep -c "GIT_CONFIG_VALUE_0: '!bash \"\$GITHUB_WORKSPACE/scripts/ci/git-token-credential.sh\"'" <<<"$pipeline_job" || true)"
assert_eq "the pipeline job does not embed a token in a remote URL" "0" \
    "$(grep -c 'x-access-token:${GITHUB_TOKEN}@' <<<"$pipeline_job" || true)"

print_test_results
