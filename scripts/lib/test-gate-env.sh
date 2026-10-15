#!/usr/bin/env bash
# lib/test-gate-env.sh — run a test command without credentials (#8608).
#
# The build loop's test gate runs the project's whole test suite. Inside a pipeline the
# environment holds the GitHub token and the Claude token, so any suite that talks to real
# services (sw-e2e-integration-test.sh did) would file real issues, start nested pipelines in
# the agent's working tree and spend money. Tests get no credentials: GitHub and Claude
# tokens are removed, gh is pointed at an empty config dir (so a keyring login on a dev
# machine is not used either), git's saved credentials are reset, and
# SHIPWRIGHT_IN_TEST_GATE=1 lets real-service suites refuse. Not covered: credentials a tool
# reads from the OS keychain (claude on macOS) or ~/.netrc; real-service suites must also
# check SHIPWRIGHT_IN_TEST_GATE themselves.
#
#   sw_test_gate_env bash -c "$test_cmd"          # a command
#   ( sw_test_gate_scrub && eval "$TEST_CMD" )      # an eval'd command string, in a subshell
#
# Always `&&` after the scrub: if it fails, the command must not run (fail closed).

[[ -n "${_SW_TEST_GATE_ENV_LOADED:-}" ]] && return 0
_SW_TEST_GATE_ENV_LOADED=1

# sw_test_gate_scrub — drop credentials from the current shell. Only inside a subshell: it
# refuses (returns 1) in the top-level shell, whose credentials the pipeline still needs.
# BASH_SUBSHELL guards against mistakes, not misuse (it can be assigned).
sw_test_gate_scrub() {
    if [[ "${BASH_SUBSHELL:-0}" -eq 0 ]]; then
        echo "sw_test_gate_scrub: call it inside a subshell: ( sw_test_gate_scrub && cmd )" >&2
        return 1
    fi
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN \
        CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN \
        SHIPWRIGHT_FLEET_TOKEN SHIPWRIGHT_FLEET_TOKEN_FILE
    # Everything that needs no I/O first, so a later failure still leaves the subshell locked
    # down. The token actions/checkout saves as an http extraheader in the repo's git config (and
    # any credential helper) would still let a test push; an empty value resets each.
    export SHIPWRIGHT_IN_TEST_GATE=1 GIT_TERMINAL_PROMPT=0 GH_CONFIG_DIR=/nonexistent/sw-test-gate-gh
    export GIT_CONFIG_COUNT=3 \
        GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0='' \
        GIT_CONFIG_KEY_1=http.extraheader GIT_CONFIG_VALUE_1='' \
        GIT_CONFIG_KEY_2=credential.helper GIT_CONFIG_VALUE_2=''
    _sw_test_gate_gh_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-gate-gh.XXXXXX")" || return 1
    # shellcheck disable=SC2064  # expand now: the path is fixed for this subshell
    trap "rm -rf '$_sw_test_gate_gh_dir'" EXIT
    export GH_CONFIG_DIR="$_sw_test_gate_gh_dir"
}

# sw_test_gate_env <cmd> [args...] — run cmd without credentials; returns its exit status.
sw_test_gate_env() {
    ( sw_test_gate_scrub && "$@" )
}
