#!/usr/bin/env bash
# lib/test-gate-env.sh — run a test command without credentials (#8608).
#
# The build loop's test gate runs the project's whole test suite. Inside a pipeline the
# environment holds the GitHub token and the Claude token, so any suite that talks to real
# services (sw-e2e-integration-test.sh did) would file real issues, start nested pipelines in
# the agent's working tree and spend money. Tests get no credentials: GitHub and Claude
# tokens are removed, gh is pointed at an empty config dir (so a keyring login on a dev
# machine is not used either), and SHIPWRIGHT_IN_TEST_GATE=1 lets real-service suites refuse.

[[ -n "${_SW_TEST_GATE_ENV_LOADED:-}" ]] && return 0
_SW_TEST_GATE_ENV_LOADED=1

# sw_test_gate_env <cmd> [args...] — run cmd without credentials; returns its exit status.
sw_test_gate_env() {
    local gh_dir rc=0
    gh_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-gate-gh.XXXXXX")" || return 1
    env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
        -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
        -u SHIPWRIGHT_FLEET_TOKEN -u SHIPWRIGHT_FLEET_TOKEN_FILE \
        GH_CONFIG_DIR="$gh_dir" SHIPWRIGHT_IN_TEST_GATE=1 "$@" || rc=$?
    rm -rf "$gh_dir"
    return "$rc"
}
