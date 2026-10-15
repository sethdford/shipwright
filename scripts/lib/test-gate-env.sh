#!/usr/bin/env bash
# lib/test-gate-env.sh — run a test command without credentials (#8608, #8616, #8617).
#
# The build loop's test gate runs the project's whole test suite. Inside a pipeline the
# environment holds the GitHub token and the Claude token, so any suite that talks to real
# services (sw-e2e-integration-test.sh did) would file real issues, start nested pipelines in
# the agent's working tree and spend money. Tests get no credentials: GitHub and Claude
# tokens are removed, gh is pointed at an empty config dir (so a keyring login on a dev
# machine is not used either), git's saved credentials are reset, and
# SHIPWRIGHT_IN_TEST_GATE=1 lets real-service suites refuse.
#
# Git's saved credentials are reset globally (http.extraheader, credential.helper) and for every
# remote URL the repo configures (http.<url>.extraheader, credential.<url>.helper, #8617): the
# token actions/checkout saves can be scoped to a URL. Not covered: submodule URLs and URLs that
# url.<base>.insteadOf rewrites, which are not read as remotes. The Claude CLI gets an empty config dir
# (CLAUDE_CONFIG_DIR): the login is not found from an empty dir (`claude auth status` reports
# loggedIn false for an empty dir; no model call is made, #8616). On macOS the login may live in the keychain;
# with the empty dir the CLI reports no login. The agent env (agent-exec.sh) keeps the Claude login and
# does not do this.
#
# Not covered: credentials a tool reads from the OS keychain other than claude's own login (gh
# uses none when its config dir is empty), and ~/.netrc, which curl reads from $HOME with no
# environment variable to redirect it (#8616). Real-service suites must also check
# SHIPWRIGHT_IN_TEST_GATE themselves.
#
#   sw_test_gate_env bash -c "$test_cmd"          # a command
#   ( sw_test_gate_scrub && eval "$TEST_CMD" )      # an eval'd command string, in a subshell
#
# Always `&&` after the scrub: if it fails, the command must not run (fail closed).

[[ -n "${_SW_TEST_GATE_ENV_LOADED:-}" ]] && return 0
_SW_TEST_GATE_ENV_LOADED=1

# _sw_scrub_github_creds — drop GitHub, fleet and git credentials from the current shell. Shared
# with agent-exec.sh. It does not check for a subshell: each caller must (see sw_test_gate_scrub).
# Returns 1 if the remote list cannot be read, so the caller can refuse to run.
_sw_scrub_github_creds() {
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN \
        SHIPWRIGHT_FLEET_TOKEN SHIPWRIGHT_FLEET_TOKEN_FILE
    # Everything that needs no I/O first, so a later failure still leaves the shell locked down.
    # An empty value resets each saved header or helper (global scope first).
    export GIT_TERMINAL_PROMPT=0 GH_CONFIG_DIR=/nonexistent/sw-no-gh-config
    export GIT_CONFIG_COUNT=3 \
        GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0='' \
        GIT_CONFIG_KEY_1=http.extraheader GIT_CONFIG_VALUE_1='' \
        GIT_CONFIG_KEY_2=credential.helper GIT_CONFIG_VALUE_2=''
    local remotes rc=0 line url n=3
    remotes="$(git config --get-regexp '^remote\..*\.(url|pushurl)$' 2>/dev/null)" || rc=$?
    # Status 1 means no remote is configured. Anything else (git missing, unreadable config) is not safe.
    [[ "$rc" -eq 0 || "$rc" -eq 1 ]] || return 1
    while IFS= read -r line; do
        url="${line#* }"
        [[ -n "$url" ]] || continue
        export "GIT_CONFIG_KEY_$n=http.$url.extraheader" "GIT_CONFIG_VALUE_$n="
        n=$((n + 1))
        export "GIT_CONFIG_KEY_$n=credential.$url.helper" "GIT_CONFIG_VALUE_$n="
        n=$((n + 1))
    done <<<"$remotes"
    export GIT_CONFIG_COUNT=$n
}

# sw_test_gate_scrub — drop credentials from the current shell and lock the gate down. Only inside
# a subshell: it refuses (returns 1) in the top-level shell, whose credentials the pipeline still
# needs. BASH_SUBSHELL guards against mistakes, not misuse (it can be assigned).
sw_test_gate_scrub() {
    if [[ "${BASH_SUBSHELL:-0}" -eq 0 ]]; then
        echo "sw_test_gate_scrub: call it inside a subshell: ( sw_test_gate_scrub && cmd )" >&2
        return 1
    fi
    export SHIPWRIGHT_IN_TEST_GATE=1
    unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    _sw_scrub_github_creds || return 1
    # Empty temp dirs for gh and for the Claude CLI, removed when the subshell exits.
    local tmp_gh tmp_claude
    tmp_gh="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-gate-gh.XXXXXX")" || return 1
    tmp_claude="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-gate-claude.XXXXXX")" || { rm -rf "$tmp_gh"; return 1; }
    # shellcheck disable=SC2064  # expand now: the paths are fixed for this subshell
    trap "rm -rf '$tmp_gh' '$tmp_claude'" EXIT
    export GH_CONFIG_DIR="$tmp_gh" CLAUDE_CONFIG_DIR="$tmp_claude"
}

# sw_test_gate_env <cmd> [args...] — run cmd without credentials; returns its exit status.
sw_test_gate_env() {
    ( sw_test_gate_scrub && "$@" )
}
